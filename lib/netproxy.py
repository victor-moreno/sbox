#!/usr/bin/env python3
"""netproxy — domain-filtering HTTP proxy for sbox.

Runs OUTSIDE the sandbox. The sandbox itself may only reach localhost (macOS
Seatbelt) or has no network at all (Linux bwrap --unshare-net), so every
outbound connection has to come through here, via HTTP(S)_PROXY.

  serve    CONNECT tunnels + plain http:// forwarding, filtered by host:
           allowed (NET_ALLOW / always-file) -> connect
           denied  ("!host" entries)         -> 403
           unknown                           -> ask (dialog), else 403
  forward  Linux only, runs INSIDE the sandbox: 127.0.0.1:PORT -> unix socket,
           bridging the private network namespace to the proxy outside.
  relay    Linux only, runs OUTSIDE: unix socket -> one fixed host:port (the
           `aicode -local` model server), the other end of a forward.
  publish  Linux only, runs OUTSIDE on a compute node: 0.0.0.0:PORT -> the
           socket a slurm job's relay listens on (sbatch --publish), opened
           without following anything the job may have planted there.
  connect  Linux only, runs INSIDE: one CONNECT tunnel on stdin/stdout, used
           as ssh's ProxyCommand (ssh speaks neither HTTP proxy nor DNS).
  ask      the question itself, run by `serve` in a tmux popup (Linux, when
           the coder was launched inside tmux): one keypress answers.

Patterns: "host:port" one port of a host (e.g. ssh: "10.10.0.2:22"), "host" exact, "*.host" any subdomain, "*" everything, "!pattern"
deny without asking (checked first). HTTPS is tunnelled, not decrypted, so
only the host name is known — allowing a host allows any traffic to it.
"""
import argparse
import asyncio
import os
import re
import select
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import termios
import time
import tty
from urllib.parse import urlsplit

DIALOG_TIMEOUT = 60
HOST_RE = re.compile(r"^[a-z0-9._:\[\]-]{1,253}$")


def match(pattern, host, port=None):
    # "host:port" pattern (e.g. 10.10.0.2:22) only matches that port
    h, sep, pt = pattern.rpartition(":")
    if sep and pt.isdigit() and pattern.count(":") == 1:
        return port is not None and pt == str(port) and match(h, host)
    if pattern == "*":
        return True
    if pattern.startswith("*."):
        return host.endswith(pattern[1:])
    return host == pattern


def read_patterns(path):
    try:
        with open(path) as f:
            lines = [l.split("#", 1)[0].strip().lower() for l in f]
    except FileNotFoundError:
        return []
    return [l for l in lines if l]


def open_in(root, rel):
    """Append fd for root/rel, which the sandbox can write: no component may
    be a symlink, and the file must be a plain single-link file, or this
    process (outside the sandbox) could be steered into writing elsewhere."""
    *dirs, name = rel.split("/")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for d in dirs:
            try:
                os.mkdir(d, 0o755, dir_fd=fd)
            except FileExistsError:
                pass
            nfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nfd
        # O_NONBLOCK: a FIFO planted there fails instead of blocking the proxy
        lfd = os.open(name, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                      0o644, dir_fd=fd)
    finally:
        os.close(fd)
    st = os.fstat(lfd)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        os.close(lfd)
        raise OSError("not a plain file: %s/%s" % (root, rel))
    return lfd


class Policy:
    def __init__(self, static, always_file, project, log_file, log_root=None):
        self.static = [p.strip().lower() for p in static if p.strip()]
        self.always_file = always_file
        self.project = project
        self.log_file = log_file
        self.log_root = log_root
        self.always, self.mtime = [], None
        # per-session answers, so one dialog covers every request to a host
        self.session = {}
        self.pending = {}
        # one dialog on screen at a time
        self.dialog_lock = asyncio.Lock()

    def log(self, verdict, host, port):
        line = "%s %s %s:%s %s\n" % (time.strftime("%F %T"), verdict, host, port, self.project)
        try:
            if self.log_root:
                fd = open_in(self.log_root, self.log_file)
            else:
                fd = os.open(self.log_file, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            with os.fdopen(fd, "a") as f:
                f.write(line)
        except OSError:
            pass

    def patterns(self):
        # re-read the always-file when it changes, so edits (or "Always"
        # answers from other sessions) apply without a restart
        try:
            m = os.stat(self.always_file).st_mtime
        except FileNotFoundError:
            m = None
        if m != self.mtime:
            self.mtime, self.always = m, read_patterns(self.always_file)
        return self.static + self.always

    def listed(self, host, port):
        pats = self.patterns()
        if any(match(p[1:], host, port) for p in pats if p.startswith("!")):
            return False
        if any(match(p, host, port) for p in pats if not p.startswith("!")):
            return True
        return None

    async def allowed(self, host, port):
        verdict = self.listed(host, port)
        if verdict is not None:
            # own key: a port-specific entry must not cover the host's other ports
            if (host, port) not in self.session:
                self.session[(host, port)] = verdict
                self.log("allow" if verdict else "deny-listed", host, port)
            return verdict
        if host in self.session:
            return self.session[host]
        if host not in self.pending:
            self.pending[host] = asyncio.ensure_future(self.ask(host, port))
        return await self.pending[host]

    async def ask(self, host, port):
        async with self.dialog_lock:
            answer = await asyncio.get_running_loop().run_in_executor(None, dialog, host, port, self.project)
        if answer == "always":
            with open(self.always_file, "a") as f:
                f.write("%s\n" % host)
        self.session[host] = answer in ("allow", "always")
        self.pending.pop(host, None)
        self.log("ask-" + answer, host, port)
        return self.session[host]


def dialog(host, port, project):
    """Return allow / always / deny / timeout / nogui."""
    text = "sbox: %s\n\nwants to connect to\n\n%s:%s" % (project, host, port)
    if sys.platform == "darwin":
        # text goes in via argv, never spliced into AppleScript source
        script = [
            "on run argv",
            'display dialog (item 1 of argv) with title "sbox network" '
            'buttons {"Deny", "Allow", "Always allow"} default button "Deny" '
            "giving up after %d with icon caution" % DIALOG_TIMEOUT,
            "end run",
        ]
        cmd = ["osascript"] + sum([["-e", l] for l in script], []) + [text]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=DIALOG_TIMEOUT + 10)
        except (OSError, subprocess.TimeoutExpired):
            return "nogui"
        if r.returncode != 0:
            return "nogui"
        if "gave up:true" in r.stdout:
            return "timeout"
        if "Always allow" in r.stdout:
            return "always"
        return "allow" if "button returned:Allow" in r.stdout else "deny"
    # a terminal-only Linux session (ssh, cluster) has no dialog to show, but
    # a coder launched inside tmux can be asked in a popup over its own screen
    if os.environ.get("TMUX") and shutil.which("tmux"):
        return tmux_popup(host, port, project)
    if (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) and shutil.which("zenity"):
        cmd = ["zenity", "--question", "--title=sbox network", "--text=" + text,
               "--ok-label=Allow", "--cancel-label=Deny", "--extra-button=Always allow",
               "--timeout=%d" % DIALOG_TIMEOUT]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=DIALOG_TIMEOUT + 10)
        except (OSError, subprocess.TimeoutExpired):
            return "nogui"
        if "Always allow" in r.stdout:
            return "always"
        if r.returncode == 5:
            return "timeout"
        return "allow" if r.returncode == 0 else "deny"
    return "nogui"


def tmux_popup(host, port, project):
    # the answer comes back through a private dir outside the sandbox: NETDIR
    # is writable from inside, so an answer file there could be forged
    d = tempfile.mkdtemp(prefix="sbox-ask-")
    answer = os.path.join(d, "answer")
    cmd = [sys.executable, os.path.abspath(__file__), "ask", "--answer", answer,
           "--host", host, "--port", str(port), "--project", project]
    popup = ["tmux", "display-popup", "-E", "-w", "72", "-h", "13", "-T", " sbox network "]
    # $TMUX_PANE (inherited from the launcher) puts it on the coder's client
    if os.environ.get("TMUX_PANE"):
        popup += ["-t", os.environ["TMUX_PANE"]]
    popup.append(" ".join(shlex.quote(c) for c in cmd))
    deadline = time.time() + DIALOG_TIMEOUT + 10
    try:
        r = subprocess.run(popup, capture_output=True, timeout=DIALOG_TIMEOUT + 10)
        if r.returncode != 0:
            return "nogui"  # e.g. no client attached to the session
        # display-popup may return before the popup closes
        while time.time() < deadline:
            try:
                with open(answer) as f:
                    got = f.read().strip()
                return got if got in ("allow", "always", "deny", "timeout") else "deny"
            except FileNotFoundError:
                time.sleep(0.2)
        return "timeout"
    except (OSError, subprocess.TimeoutExpired):
        return "nogui"
    finally:
        shutil.rmtree(d, ignore_errors=True)


def ask(a):
    print("\n  %s\n\n  wants to connect to\n\n    %s:%s\n" % (a.project, a.host, a.port))
    print("  [a] Allow   [A] Always allow   any other key: Deny")
    print("  (deny in %d s)" % DIALOG_TIMEOUT, end="", flush=True)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        # keystrokes meant for the coder, typed as the popup opened, must not
        # answer it: drop whatever arrives in the first moment
        time.sleep(0.6)
        termios.tcflush(fd, termios.TCIFLUSH)
        ready = select.select([fd], [], [], DIALOG_TIMEOUT)[0]
        key = os.read(fd, 1) if ready else b""
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    answer = {b"a": "allow", b"A": "always"}.get(key, "deny" if ready else "timeout")
    with open(a.answer + ".tmp", "w") as f:
        f.write(answer + "\n")
    os.rename(a.answer + ".tmp", a.answer)


def split_hostport(s, default):
    if s.startswith("["):
        host, _, rest = s[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    else:
        host, _, port = s.rpartition(":") if s.count(":") == 1 else (s, "", "")
    return host.lower().rstrip("."), int(port) if port else default


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()


def reply(writer, status, body=""):
    body = body.encode()
    writer.write(("HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n"
                  "Connection: close\r\n\r\n" % (status, len(body))).encode() + body)
    writer.close()


class Proxy:
    def __init__(self, policy, hint):
        self.policy = policy
        self.hint = hint

    async def handle(self, reader, writer):
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
            line, _, headers = head.decode("latin-1").partition("\r\n")
            method, target, version = line.split(" ", 2)
        except (ValueError, OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError):
            writer.close()
            return
        if method == "CONNECT":
            host, port = split_hostport(target, 443)
        else:
            u = urlsplit(target)
            if u.scheme != "http" or not u.hostname:
                return reply(writer, "400 Bad Request", "sbox proxy: absolute http:// URL expected\n")
            host, port = split_hostport(u.netloc.rpartition("@")[2], 80)
            path = (u.path or "/") + ("?" + u.query if u.query else "")
        if not HOST_RE.match(host) or not await self.policy.allowed(host, port):
            return reply(writer, "403 Forbidden",
                         "sbox network filter: %s is not allowed.\n%s\n" % (host, self.hint))
        try:
            up_r, up_w = await asyncio.wait_for(asyncio.open_connection(host, port), 30)
        except (OSError, asyncio.TimeoutError) as e:
            return reply(writer, "502 Bad Gateway", "sbox proxy: cannot reach %s:%s (%s)\n" % (host, port, e))
        if method == "CONNECT":
            # 1.0: macOS nc -X connect (ssh ProxyCommand) rejects 1.1
            writer.write(b"HTTP/1.0 200 Connection established\r\n\r\n")
        else:
            # origin-form request line; one request per connection keeps a
            # keep-alive client from reusing this tunnel for another host
            drop = ("proxy-connection", "proxy-authorization", "connection", "keep-alive")
            kept = [h for h in headers.split("\r\n") if h and h.split(":", 1)[0].strip().lower() not in drop]
            up_w.write(("%s %s %s\r\n%s\r\nConnection: close\r\n\r\n"
                        % (method, path, version, "\r\n".join(kept))).encode("latin-1"))
        await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))


async def watch(pid, cleanup):
    # exit with the sandbox launcher, even if it was killed without cleanup
    while True:
        await asyncio.sleep(2)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            if cleanup:
                shutil.rmtree(cleanup, ignore_errors=True)
            os._exit(0)
        except PermissionError:
            pass


async def serve(a):
    policy = Policy(a.allow, a.always_file, a.project, a.log, a.log_root)
    proxy = Proxy(policy, a.hint)
    if a.unix:
        server = await asyncio.start_unix_server(proxy.handle, a.unix)
    else:
        server = await asyncio.start_server(proxy.handle, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        tmp = a.port_file + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d\n" % port)
        os.rename(tmp, a.port_file)
    if a.watch_pid:
        asyncio.ensure_future(watch(a.watch_pid, a.cleanup))
    async with server:
        await server.serve_forever()


async def forward(a):
    async def handle(reader, writer):
        try:
            up_r, up_w = await asyncio.open_unix_connection(a.unix)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))

    server = await asyncio.start_server(handle, "127.0.0.1", a.listen)
    async with server:
        await server.serve_forever()


async def relay(a):
    # the reverse of forward, run OUTSIDE: one fixed host port (the -local
    # model server) exposed as a unix socket, unfiltered, so the sandbox gets
    # that port and nothing else on the host's loopback
    host, port = split_hostport(a.connect, 80)

    async def handle(reader, writer):
        try:
            up_r, up_w = await asyncio.open_connection(host, port)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))

    server = await asyncio.start_unix_server(handle, a.unix)
    if a.watch_pid:
        asyncio.ensure_future(watch(a.watch_pid, None))
    async with server:
        await server.serve_forever()


def open_job_socket(dir_fd):
    # the job owns the socket's directory: refuse a symlink (it would resolve
    # on the node, e.g. to munge's socket) or a hard link (e.g. of its own
    # netproxy socket); connect through the O_PATH fd, so no name is followed
    fd = os.open("sock", os.O_PATH | os.O_NOFOLLOW, dir_fd=dir_fd)
    st = os.fstat(fd)
    if not stat.S_ISSOCK(st.st_mode) or st.st_nlink != 1:
        os.close(fd)
        raise OSError("not a plain socket")
    return fd


async def publish(a):
    dir_fd = os.open(a.dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    async def handle(reader, writer):
        try:
            fd = open_job_socket(dir_fd)
            try:
                up_r, up_w = await asyncio.open_unix_connection("/proc/self/fd/%d" % fd)
            finally:
                os.close(fd)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))

    # fails here (port in use) before the port file exists: the launcher waits on it
    server = await asyncio.start_server(handle, "0.0.0.0", a.listen)
    with open(a.port_file, "w") as f:
        f.write("%d\n" % a.listen)
    if a.watch_pid:
        asyncio.ensure_future(watch(a.watch_pid, None))
    async with server:
        await server.serve_forever()


def connect(a):
    # ssh's ProxyCommand inside the sandbox: talk to the proxy's unix socket
    # directly (no dependency on the 127.0.0.1:3128 forwarder) and hand ssh
    # the resulting tunnel on stdin/stdout. The name is resolved outside, by
    # the proxy — the private network namespace has no DNS.
    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.connect(a.unix)
        sock.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n"
                      % (a.host, a.port, a.host, a.port)).encode("latin-1"))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(65536)
            if not chunk:
                sys.exit("sbox: proxy closed the connection")
            head += chunk
        head, _, rest = head.partition(b"\r\n\r\n")
        status, _, _ = head.partition(b"\r\n")
        if b" 200" not in status:
            sys.exit("sbox: %s\n%s" % (status.decode("latin-1"), rest.decode("latin-1", "replace")))
    except OSError as e:
        sys.exit("sbox: cannot reach the proxy (%s)" % e)
    out = sys.stdout.buffer
    if rest:
        out.write(rest)
        out.flush()
    fds = [0, sock]
    while fds:
        ready, _, _ = select.select(fds, [], [])
        if 0 in ready:
            data = os.read(0, 65536)
            if data:
                sock.sendall(data)
            else:
                fds.remove(0)
                sock.shutdown(socket.SHUT_WR)
        if sock in ready:
            data = sock.recv(65536)
            if not data:
                break
            out.write(data)
            out.flush()


def main():
    p = argparse.ArgumentParser()
    # not add_subparsers(required=True): that needs 3.7, and `connect` runs as
    # ssh's ProxyCommand, which may pick up an older system python3
    sub = p.add_subparsers(dest="mode")
    s = sub.add_parser("serve")
    s.add_argument("--allow", action="append", default=[])
    s.add_argument("--always-file", required=True)
    s.add_argument("--log", required=True)
    # --log is then relative to it and opened without following symlinks
    # (the project dir, writable by the sandbox)
    s.add_argument("--log-root")
    s.add_argument("--project", default="?")
    s.add_argument("--hint", default="")
    s.add_argument("--watch-pid", type=int)
    # Linux execs bwrap, so no shell trap is left to remove the temp dir
    s.add_argument("--cleanup")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--port-file")
    g.add_argument("--unix")
    f = sub.add_parser("forward")
    f.add_argument("--listen", type=int, required=True)
    f.add_argument("--unix", required=True)
    r = sub.add_parser("relay")
    r.add_argument("--unix", required=True)
    r.add_argument("--connect", required=True)
    r.add_argument("--watch-pid", type=int)
    u = sub.add_parser("publish")
    u.add_argument("--listen", type=int, required=True)
    u.add_argument("--dir", required=True, help="holds the job's socket, named sock")
    u.add_argument("--port-file", required=True)
    u.add_argument("--watch-pid", type=int)
    c = sub.add_parser("connect")
    c.add_argument("--unix", required=True)
    c.add_argument("host")
    c.add_argument("port", type=int)
    k = sub.add_parser("ask")
    k.add_argument("--answer", required=True)
    k.add_argument("--host", required=True)
    k.add_argument("--port", required=True)
    k.add_argument("--project", default="?")
    a = p.parse_args()
    if not a.mode:
        p.error("a mode is required")
    if a.mode == "ask":
        return ask(a)
    if a.mode == "connect":
        return connect(a)
    # Ctrl-C in the sandboxed terminal must not take the proxy down
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    asyncio.run({"serve": serve, "forward": forward, "relay": relay,
                 "publish": publish}[a.mode](a))


if __name__ == "__main__":
    main()
