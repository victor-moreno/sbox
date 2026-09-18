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

Patterns: "host" exact, "*.host" any subdomain, "*" everything, "!pattern"
deny without asking (checked first). HTTPS is tunnelled, not decrypted, so
only the host name is known — allowing a host allows any traffic to it.
"""
import argparse
import asyncio
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import urlsplit

DIALOG_TIMEOUT = 60
HOST_RE = re.compile(r"^[a-z0-9._:\[\]-]{1,253}$")


def match(pattern, host):
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


class Policy:
    def __init__(self, static, always_file, project, log_file):
        self.static = [p.strip().lower() for p in static if p.strip()]
        self.always_file = always_file
        self.project = project
        self.log_file = log_file
        self.always, self.mtime = [], None
        # per-session answers, so one dialog covers every request to a host
        self.session = {}
        self.pending = {}
        # one dialog on screen at a time
        self.dialog_lock = asyncio.Lock()

    def log(self, verdict, host, port):
        line = "%s %s %s:%s %s\n" % (time.strftime("%F %T"), verdict, host, port, self.project)
        try:
            with open(self.log_file, "a") as f:
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

    def listed(self, host):
        pats = self.patterns()
        if any(match(p[1:], host) for p in pats if p.startswith("!")):
            return False
        if any(match(p, host) for p in pats if not p.startswith("!")):
            return True
        return None

    async def allowed(self, host, port):
        verdict = self.listed(host)
        if verdict is not None:
            if host not in self.session:
                self.session[host] = verdict
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
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
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
    policy = Policy(a.allow, a.always_file, a.project, a.log)
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


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--allow", action="append", default=[])
    s.add_argument("--always-file", required=True)
    s.add_argument("--log", required=True)
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
    a = p.parse_args()
    # Ctrl-C in the sandboxed terminal must not take the proxy down
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    asyncio.run({"serve": serve, "forward": forward, "relay": relay}[a.mode](a))


if __name__ == "__main__":
    main()
