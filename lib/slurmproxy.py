#!/usr/bin/env python3
"""slurmproxy — Slurm broker for sbox (design and rationale: SLURM.md).

The sandbox never holds a munge credential. Instead:

  serve   runs OUTSIDE the sandbox (has munge): answers one JSON request per
          connection on a unix socket bound into the sandbox. sbatch is
          validated against an allowlist, re-serialized, and its script is
          wrapped in a launcher that runs it inside bwrap on the compute node.
  shim    this same file, bound over sbatch/squeue/... INSIDE the sandbox
          (dispatch on argv[0]): forwards argv, cwd and the script content.

Protocol: request {"cmd", "argv", "cwd", "script_b64"} (one line), reply
{"rc", "stdout", "stderr"} (one line). The broker never opens a path sent by
the sandbox; -o/-e/-i/-D are only used inside the job's bwrap.

Stays python 3.6 compatible: the shim may run on the system python3.
"""
import argparse
import base64
import fcntl
import json
import os
import posixpath
import re
import select
import shlex
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

SOCK = "/run/sbox-slurm/sock"
SHIM_CMDS = ("sbatch", "scancel", "scontrol", "squeue", "sinfo", "sacct",
             "sstat", "sprio", "sshare", "srun", "salloc")
READONLY = ("squeue", "sinfo", "sacct", "sstat", "sprio", "sshare")
MAX_REQUEST = 8 << 20
MAX_SCRIPT = 2 << 20          # base64 in the launcher must stay under sbatch's 4 MB
MAX_ARRAY = 10001             # MaxArraySize on odap (SLURM.md phase 0)
CTRL = re.compile(r"[\x00-\x1f\x7f]")
SIGNAL_RE = re.compile(r"^B:(SIG)?(USR1|USR2|HUP|TERM)(@[0-9]{1,5})?$")


class Refused(Exception):
    pass


# ── sbatch option allowlist: long -> (short, kind, class) ────────────────────
# kind: arg (required value), flag (none), opt (value only as --x=value)
# class: pass = re-serialized to sbatch; io = handled by the launcher; others special
OPTS = {
    "partition": ("p", "arg", "pass"), "time": ("t", "arg", "pass"),
    "time-min": (None, "arg", "pass"), "ntasks": ("n", "arg", "pass"),
    "cpus-per-task": ("c", "arg", "pass"), "ntasks-per-node": (None, "arg", "pass"),
    "mem": (None, "arg", "pass"), "mem-per-cpu": (None, "arg", "pass"),
    "mem-per-gpu": (None, "arg", "pass"), "gpus": ("G", "arg", "pass"),
    "gpus-per-node": (None, "arg", "pass"), "gpus-per-task": (None, "arg", "pass"),
    "gres": (None, "arg", "pass"), "exclusive": (None, "opt", "pass"),
    "account": ("A", "arg", "pass"), "qos": ("q", "arg", "pass"),
    "reservation": (None, "arg", "pass"), "nice": (None, "opt", "pass"),
    "nodes": ("N", "arg", "nodes"), "constraint": ("C", "arg", "constraint"),
    "exclude": ("x", "arg", "exclude"), "nodelist": ("w", "arg", "pass"),
    "job-name": ("J", "arg", "jobname"), "array": ("a", "arg", "array"),
    "dependency": ("d", "arg", "pass"), "hold": ("H", "flag", "pass"),
    "begin": ("b", "arg", "pass"), "deadline": (None, "arg", "pass"),
    "requeue": (None, "flag", "pass"), "no-requeue": (None, "flag", "pass"),
    "mail-type": (None, "arg", "pass"), "mail-user": (None, "arg", "pass"),
    "parsable": (None, "flag", "reply"), "quiet": ("Q", "flag", "reply"),
    "wait": ("W", "flag", "wait"), "test-only": (None, "flag", "test"),
    "output": ("o", "arg", "io"), "error": ("e", "arg", "io"),
    "input": ("i", "arg", "io"), "open-mode": (None, "arg", "io"),
    "chdir": ("D", "arg", "io"), "wrap": (None, "arg", "wrap"),
    "help": ("h", "flag", "help"), "usage": (None, "flag", "help"),
    "version": ("V", "flag", "version"),
    "signal": (None, "arg", "signal"),
    # sbox's own: expose one port of the job on its node (SLURM_PUBLISH_PORTS)
    "publish": (None, "arg", "publish"),
}
SHORT = dict((v[0], k) for k, v in OPTS.items() if v[0])


def allowed_text():
    return "allowed sbatch options: " + " ".join(
        ("-%s/--%s" % (OPTS[k][0], k)) if OPTS[k][0] else "--" + k for k in sorted(OPTS))


def parse_opts(argv, table=OPTS, short=SHORT):
    """getopt_long-like, stops at the first positional. Long names must match
    exactly (no abbreviations). Returns ([(long, value)], rest)."""
    out, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if a.startswith("--"):
            name, eq, val = a[2:].partition("=")
            if name not in table:
                raise Refused("option --%s is not allowed in the sandbox" % name)
            kind = table[name][1]
            if kind == "flag":
                if eq:
                    raise Refused("option --%s takes no value" % name)
                val = None
            elif kind == "opt":
                val = val if eq else None
            elif not eq:
                i += 1
                if i >= len(argv):
                    raise Refused("option --%s needs a value" % name)
                val = argv[i]
            out.append((name, val))
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            j = 1
            while j < len(a):
                name = short.get(a[j])
                if not name:
                    raise Refused("option -%s is not allowed in the sandbox" % a[j])
                if table[name][1] == "arg":
                    val = a[j + 1:]
                    if not val:
                        i += 1
                        if i >= len(argv):
                            raise Refused("option -%s needs a value" % a[j])
                        val = argv[i]
                    out.append((name, val))
                    break
                out.append((name, None))
                j += 1
            i += 1
            continue
        break
    for name, val in out:
        if val is not None and CTRL.search(val):
            raise Refused("control character in the value of --%s" % name)
    return out, argv[i:]


def array_count(spec):
    """'1-10:2,15%4' -> (number of tasks, throttle or None)."""
    body, pct, thr = spec.partition("%")
    throttle = None
    if pct:
        if not thr.isdigit():
            raise Refused("bad array throttle in %r" % spec)
        throttle = int(thr)
    idx = set()
    for item in body.split(","):
        m = re.match(r"^(\d+)(?:-(\d+)(?::(\d+))?)?$", item)
        if not m:
            raise Refused("bad array spec %r" % spec)
        lo = int(m.group(1))
        hi = int(m.group(2)) if m.group(2) else lo
        step = int(m.group(3)) if m.group(3) else 1
        if hi < lo or step < 1 or hi >= MAX_ARRAY:
            raise Refused("bad array range %r (max index %d)" % (item, MAX_ARRAY - 1))
        idx.update(range(lo, hi + 1, step))
    return len(idx), throttle


def sbatch_directives(script):
    """#SBATCH lines up to the first command line, as sbatch reads them."""
    args = []
    for line in script.split("\n")[1:]:
        if line.startswith("#SBATCH") and (len(line) == 7 or line[7].isspace()):
            try:
                args += shlex.split(line[7:], comments=True)
            except ValueError as e:
                raise Refused("bad #SBATCH line %r: %s" % (line, e))
        elif line.strip() and not line.lstrip().startswith("#"):
            break
    return args


# ── launcher (the script sbatch actually gets) ───────────────────────────────
LAUNCHER_HEAD = r'''#!/bin/bash
# generated by sbox: runs the user script inside bwrap; fails closed without it
B=%(bwrap)s
if ! "$B" --unshare-pid --unshare-net --ro-bind / / --proc /proc /bin/true 2>/dev/null; then
  echo "sbox: bwrap unusable on $(hostname -s): job NOT run; add it to SLURM_EXCLUDE" >&2
  exit 97
fi
dev=()
'''
LAUNCHER_GPU = r'''# GPUs decided on the node; access is still gated by the job's device cgroup
for d in /dev/nvidia*; do [ -e "$d" ] && dev+=(--dev-bind "$d" "$d"); done
[ ${#dev[@]} -gt 0 ] && [ -d /sys/module/nvidia ] && dev+=(--tmpfs /dev/shm --dir /sys --ro-bind /sys/module /sys/module)
'''
LAUNCHER_BODY = r'''# scancel/timeout SIGKILL this script (no TERM seen), so the trap only covers
# normal ends: sweep dirs of this user's jobs whose cgroup is gone (v1 layout;
# unknown layout = sweep nothing)
cg=$(sed -n 's|^[0-9]*:freezer:\(/.*\)/job_[0-9]*/.*|\1|p' /proc/self/cgroup)
if [ -n "$cg" ] && [ -d "/sys/fs/cgroup/freezer$cg" ]; then
  for d in "${TMPDIR:-/tmp}"/sbox-job-*; do
    id=${d##*/sbox-job-}; id=${id%%.*}
    [ -O "$d" ] && [[ $id =~ ^[0-9]+$ ]] && [ ! -d "/sys/fs/cgroup/freezer$cg/job_$id" ] && rm -rf "$d"
  done
fi
jt=$(mktemp -d "${TMPDIR:-/tmp}/sbox-job-$SLURM_JOB_ID.XXXXXX") || exit 96
np= pp=
trap 'for p in $np $pp; do kill "$p" 2>/dev/null && wait "$p"; done; rm -rf "$jt" "$jt.info" "$jt.net" "$jt.pub"' EXIT
env=(%(env)s)
while IFS= read -r -d '' kv; do
  case $kv in SLURM_*|SLURMD_NODENAME=*|CUDA_VISIBLE_DEVICES=*|ROCR_VISIBLE_DEVICES=*|GPU_DEVICE_ORDINAL=*) env+=("$kv") ;; esac
done < <(env -0)
# Slurm's submit dir is the broker's log dir; scripts expect the caller's cwd
env+=(%(submit_dir)s)
net=() pub=()
%(net)s%(pub)sexec 8< <(base64 -d <<<'%(inner)s')
exec 9< <(base64 -d <<<'%(script)s')
# In the background so signals for the batch shell (--signal=B:..., scancel -b -s)
# can be passed on: bwrap doesn't forward them, and its pid-1 helper ignores
# them, so they go to the helper's children, i.e. the user script (B: = only
# the batch script, as without sbox). INT/QUIT can't be: bash ignores them in
# background commands, and a script can't trap what was ignored at its start.
"$B" --info-fd 7 %(layout)s --bind "$jt" /tmp "${dev[@]}" "${net[@]}" "${pub[@]}" \
  --dir /run/sbox-job --ro-bind-data 8 /run/sbox-job/inner --ro-bind-data 9 /run/sbox-job/script \
  --chdir %(chdir)s /usr/bin/env -i "${env[@]}" \
  /bin/bash /run/sbox-job/inner %(inner_args)s 7>"$jt.info" &
bp=$!
fwd() {
  local c
  c=$(sed -n 's/.*"child-pid": *\([0-9][0-9]*\).*/\1/p' "$jt.info" 2>/dev/null)
  [ -n "$c" ] && pkill -"$1" -P "$c"
}
for s in USR1 USR2 HUP TERM; do trap "fwd $s" "$s"; done
# a trapped signal interrupts wait; keep waiting until bwrap has been reaped
while :; do
  wait "$bp"; rc=$?
  kill -0 "$bp" 2>/dev/null || break
done
exit $rc
'''

# netproxy on the node, outside bwrap, for SLURM_NET and --publish. Its source
# is the broker's snapshot, so edits made from a sandbox never run outside
# one. Both ends run on the broker's python (netproxy needs >= 3.7; the
# node's may be older).
LAUNCHER_NPY = r'''mkdir -p "$jt.net/sock" || exit 96
base64 -d <<<'%(netproxy)s' > "$jt.net/netproxy.py"
'''
# SLURM_NET: the session's allowlist (no dialog on a node: unknown hosts are
# denied). The job keeps --unshare-net and reaches it only through the socket.
LAUNCHER_NET = r'''%(python)s "$jt.net/netproxy.py" serve --unix "$jt.net/sock/proxy.sock" --watch-pid $$ %(net_args)s \
  </dev/null >/dev/null 2>>"$jt.net/err" &
np=$!
for i in $(seq 50); do [ -S "$jt.net/sock/proxy.sock" ] && break; sleep 0.1; done
if [ -S "$jt.net/sock/proxy.sock" ]; then
  net=(--bind "$jt.net/sock" /run/sbox-net --ro-bind "$jt.net/netproxy.py" /run/sbox-netproxy.py)
  env+=(SBOX_PYTHON=%(python)s)
else
  echo "sbox: netproxy did not start on $(hostname -s), job runs without network:" >&2
  cat "$jt.net/err" >&2
fi
'''
# --publish: 0.0.0.0:PORT on the node -> $jt.pub/sock, where the job's relay
# (slurm-inner.sh) forwards to its own 127.0.0.1:PORT. Inbound only: the job
# keeps --unshare-net. A port already taken on the node fails the job.
LAUNCHER_PUB = r'''mkdir "$jt.pub" || exit 96
%(python)s "$jt.net/netproxy.py" publish --listen %(port)s --dir "$jt.pub" \
  --port-file "$jt.net/pub.port" --watch-pid $$ </dev/null >/dev/null 2>>"$jt.net/pub.err" &
pp=$!
for i in $(seq 50); do [ -s "$jt.net/pub.port" ] && break; kill -0 "$pp" 2>/dev/null || break; sleep 0.1; done
if [ ! -s "$jt.net/pub.port" ]; then
  echo "sbox: can't publish port %(port)s on $(hostname -s) (in use?): job NOT run" >&2
  cat "$jt.net/pub.err" >&2
  exit 95
fi
pub=(--bind "$jt.pub" /run/sbox-pub --ro-bind "$jt.net/netproxy.py" /run/sbox-netproxy.py)
env+=(SBOX_PYTHON=%(python)s SBOX_PUBLISH_PORT=%(port)s)
'''


def q(args):
    return " ".join(shlex.quote(a) for a in args)


def make_launcher(cfg, script, submit_dir, chdir, out, err, inp, mode, sargs, port=None):
    b64 = lambda b: base64.b64encode(b).decode()
    py = shlex.quote(sys.executable)
    npy = LAUNCHER_NPY % {"netproxy": b64(cfg.netproxy)} if cfg.net_args is not None or port else ""
    return (LAUNCHER_HEAD % {"bwrap": shlex.quote(cfg.bwrap)}
            + (LAUNCHER_GPU if cfg.gpu else "")
            + LAUNCHER_BODY % {
                "env": q(cfg.env), "submit_dir": q(["SLURM_SUBMIT_DIR=" + submit_dir]),
                "inner": b64(cfg.inner), "script": b64(script),
                "layout": q(cfg.layout), "chdir": shlex.quote(chdir),
                "net": npy + (LAUNCHER_NET % {"net_args": q(cfg.net_args), "python": py}
                              if cfg.net_args is not None else ""),
                "pub": LAUNCHER_PUB % {"port": port, "python": py} if port else "",
                "inner_args": q([out, err, inp, mode, "--"] + sargs)})


# ── ledger: jobs submitted through sbox, all sessions of this user ───────────
class Ledger:
    def __init__(self, path):
        self.path = path

    def lock(self):
        # held through squeue -> budget -> sbatch -> ledger write, across all
        # sbox sessions of the user (flock is per open file, so also per thread)
        fd = os.open(self.path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd

    def load(self):
        try:
            with open(self.path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return []

    def save(self, entries):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(entries, f)
        os.replace(tmp, self.path)

    def owns(self, jobid, project):
        return any(e["id"] == jobid and e["project"] == project for e in self.load())


# ── running slurm commands ───────────────────────────────────────────────────
def client_gone(conn):
    # the shim keeps its end open until the reply: readable here means EOF
    if conn is None:
        return False
    try:
        r, _, _ = select.select([conn], [], [], 0)
        return bool(r) and conn.recv(1, socket.MSG_PEEK) == b""
    except OSError:
        return True


def run(cfg, argv, conn=None, timeout=300, on_first_line=None):
    """Run a slurm client with a minimal env (no tokens, no SBATCH_*); killed
    on timeout or when the caller disconnects."""
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=cfg.run_env, cwd=cfg.logdir)
    bufs = ([], [])

    def reader(f, buf, cb):
        for line in iter(f.readline, b""):
            if cb and not buf:
                cb(line)
            buf.append(line)

    ts = [threading.Thread(target=reader, args=(p.stdout, bufs[0], on_first_line)),
          threading.Thread(target=reader, args=(p.stderr, bufs[1], None))]
    for t in ts:
        t.start()
    start = time.time()
    while True:
        try:
            p.wait(timeout=1)
            break
        except subprocess.TimeoutExpired:
            if (timeout and time.time() - start > timeout) or client_gone(conn):
                p.kill()
                p.wait()
                break
    for t in ts:
        t.join()
    return (p.returncode, b"".join(bufs[0]).decode("utf-8", "replace"),
            b"".join(bufs[1]).decode("utf-8", "replace"))


def reply(rc, stdout="", stderr=""):
    return {"rc": rc, "stdout": stdout, "stderr": stderr}


def refuse(msg):
    return reply(1, "", "sbox: %s\n" % msg)


# ── sbatch ───────────────────────────────────────────────────────────────────
def plan_sbatch(cfg, argv, script, cwd):
    """Validate and turn a request into (sbatch argv w/o binary, launcher, info)."""
    cli, rest = parse_opts(argv)
    wrap = dict(cli).get("wrap")
    if wrap is not None:
        if rest:
            raise Refused("a script and --wrap together")
        script, sargs, name = ("#!/bin/sh\n%s\n" % wrap).encode(), [], "wrap"
    else:
        if script is None:
            raise Refused("no batch script")
        sargs = rest[1:]
        name = posixpath.basename(rest[0]) if rest else "sbatch"
    if len(script) > MAX_SCRIPT:
        raise Refused("batch script larger than %d bytes" % MAX_SCRIPT)
    if not script.startswith(b"#!"):
        raise Refused("this does not look like a batch script: the first line "
                      "must start with #! followed by the path to an interpreter")
    dopts, drest = parse_opts(sbatch_directives(script.decode("utf-8", "replace")))
    if drest:
        raise Refused("unexpected argument %r in an #SBATCH line" % drest[0])
    if any(n in ("wrap", "help", "usage", "version") for n, _ in dopts):
        raise Refused("#SBATCH lines can't use --wrap/--help/--version")
    opts = dict(dopts)
    opts.update(dict(cli))            # CLI wins over #SBATCH, last one wins

    sb = ["--parsable"]
    info = {"parsable": "parsable" in opts, "quiet": "quiet" in opts,
            "wait": "wait" in opts, "test": "test-only" in opts,
            "array": None, "weight": 1}
    for n, v in sorted(opts.items()):
        cls = OPTS[n][2]
        if cls == "pass":
            sb.append("--" + n if v is None else "--%s=%s" % (n, v))
        elif cls == "nodes":
            if v not in ("1", "1-1"):
                raise Refused("--nodes must be 1 (no multi-node jobs in the sandbox)")
            sb.append("--nodes=1")
        elif cls == "jobname":
            if "/" in v:
                raise Refused("'/' is not allowed in the job name")
            name = v
        elif cls == "array":
            info["array"] = v
            info["count"], info["throttle"] = array_count(v)
            sb.append("--array=" + v)
        elif cls == "signal":
            # only B: (the batch script, which the launcher forwards to the user
            # script): without it Slurm signals job steps, and there are none
            if not SIGNAL_RE.match(v):
                raise Refused("--signal must be B:<sig>[@seconds], sig one of USR1 USR2 HUP TERM")
            sb.append("--signal=" + v)
        elif cls == "publish":
            lo, hi = cfg.publish or (1, 0)
            if not cfg.publish:
                raise Refused("--publish is off: set SLURM_PUBLISH_PORTS in paths.conf")
            if not (v.isdigit() and lo <= int(v) <= hi):
                raise Refused("--publish must be one port in %d-%d (SLURM_PUBLISH_PORTS)" % (lo, hi))
            # the node-side listener is netproxy: a broker started without it can't publish
            if not cfg.netproxy:
                raise Refused("--publish: this session's broker has no netproxy; relaunch the session")
            info["port"] = str(int(v))
        elif cls == "wait":
            sb.append("--wait")
        elif cls == "test":
            sb.append("--test-only")
    if info.get("port") and info["array"]:
        raise Refused("--publish and --array together: one port per job")
    if not name or CTRL.search(name):
        name = "sbatch"
    sb.append("--job-name=" + name)
    con = opts.get("constraint")
    if cfg.constraint:
        con = "%s&(%s)" % (cfg.constraint, con) if con else cfg.constraint
    if con:
        sb.append("--constraint=" + con)
    exc = ",".join(x for x in (cfg.exclude, opts.get("exclude")) if x)
    if exc:
        sb.append("--exclude=" + exc)

    mode = opts.get("open-mode", "truncate")
    if mode not in ("truncate", "append"):
        raise Refused("--open-mode must be truncate or append")
    if not posixpath.isabs(cwd):
        raise Refused("cwd must be absolute")
    chdir = posixpath.normpath(posixpath.join(cwd, opts.get("chdir", ".")))
    out = opts.get("output") or ("slurm-%A_%a.out" if info["array"] else "slurm-%j.out")
    log = posixpath.join(cfg.logdir, "%A_%a.log" if info["array"] else "%j.log")
    sb += ["--output=" + log, "--error=" + log, "--chdir=" + cfg.logdir]
    launcher = make_launcher(cfg, script, cwd, chdir, out, opts.get("error", ""),
                             opts.get("input", ""), mode, sargs, info.get("port"))
    return sb, launcher, info


def apply_budget(cfg, sb, info):
    """Call with the ledger lock held. Prunes the ledger to jobs still in
    squeue and fits this submission into cfg.max_running (jobs + array tasks,
    pending ones included): arrays get a %N throttle added or clamped, and a
    full budget refuses. Returns (pruned entries, message for the caller)."""
    rc, out, err = run(cfg, [cfg.bin["squeue"], "--me", "-h", "-r", "-o", "%F"], timeout=60)
    if rc != 0:
        raise Refused("can't check the job budget, squeue failed: %s" % err.strip())
    live = {}
    for jid in out.split():        # one line per task: count per base job id
        live[jid] = live.get(jid, 0) + 1
    entries = [e for e in cfg.ledger.load() if e["id"] in live]
    used = sum(min(live[e["id"]], e.get("throttle") or live[e["id"]]) for e in entries)
    left = cfg.max_running - used
    if left <= 0:
        raise Refused("job budget full (%d/%d running or pending via sbox): wait or scancel"
                      % (used, cfg.max_running))
    msg = ""
    if info["array"]:
        count, thr = info["count"], info["throttle"]
        new = min(count if thr is None else thr, left)
        if new != thr:
            sb[sb.index("--array=" + info["array"])] = "--array=%s%%%d" % (info["array"].partition("%")[0], new)
            if new < count:
                msg = ("sbox: array limited to %d tasks at a time (budget %d/%d in use)\n"
                       % (new, used, cfg.max_running))
        info["throttle"] = new
        info["weight"] = min(count, new)
    return entries, msg


def do_sbatch(cfg, req, conn):
    argv = req["argv"]
    try:
        names = [n for n, _ in parse_opts(argv)[0]]
    except Refused as e:
        return refuse("%s\n%s" % (e, allowed_text()))
    if "help" in names:
        return reply(0, "sbatch in the sbox sandbox: batch jobs and arrays only, "
                        "single node, no network inside jobs.\n%s\n" % allowed_text())
    if "version" in names:
        return reply(*run(cfg, [cfg.bin["sbatch"], "--version"], conn))
    script = req.get("script_b64")
    script = base64.b64decode(script) if script is not None else None
    try:
        sb, launcher, info = plan_sbatch(cfg, argv, script, req["cwd"])
    except Refused as e:
        return refuse(e)
    lock, jobid = [], []

    def release():
        while lock:
            os.close(lock.pop())

    def record(line):
        # with --wait the id comes long before sbatch exits: record it now,
        # and unlock, so a waiting job doesn't hold up other submissions
        jid = line.decode().strip().split(";")[0]
        if jid.isdigit() and lock:
            jobid.append(jid)
            entries.append({"id": jid, "project": cfg.project, "weight": info["weight"],
                            "throttle": info.get("throttle"), "time": int(time.time())})
            cfg.ledger.save(entries)
        release()

    entries, msg, path = [], "", None
    # one try for everything after taking the lock: a leaked lock fd would
    # block every later submission of the user
    try:
        if not info["test"]:       # --test-only creates no job
            lock.append(cfg.ledger.lock())
            try:
                entries, msg = apply_budget(cfg, sb, info)
            except Refused as e:
                return refuse(e)
        fd, path = tempfile.mkstemp(prefix="launch-", dir=cfg.statedir)
        with os.fdopen(fd, "w") as f:
            f.write(launcher)
        rc, out, err = run(cfg, [cfg.bin["sbatch"]] + sb + [path], conn,
                           timeout=None if info["wait"] else 300, on_first_line=record)
    finally:
        release()
        if path:
            os.unlink(path)
    if jobid and not info["parsable"]:
        out = "" if info["quiet"] else "Submitted batch job %s\n" % jobid[0]
    return reply(rc, out, msg + err)


# ── scancel / scontrol ───────────────────────────────────────────────────────
SCANCEL_OPTS = {"signal": ("s", "arg", ""), "quiet": ("Q", "flag", ""),
                "verbose": ("v", "flag", ""), "batch": ("b", "flag", ""),
                "full": ("f", "flag", "")}
JOBID_RE = re.compile(r"^(\d+)(?:_(?:\d+|\[[0-9,\-]+\]))?$")


def do_scancel(cfg, req, conn):
    try:
        opts, ids = parse_opts(req["argv"], SCANCEL_OPTS,
                               dict((v[0], k) for k, v in SCANCEL_OPTS.items()))
    except Refused as e:
        return refuse("scancel: %s (allowed: -s/--signal -Q -v -b -f and job IDs)" % e)
    if not ids:
        return refuse("scancel: give explicit job IDs of jobs submitted from this project")
    args = []
    for n, v in opts:
        if n == "signal" and not re.match(r"^[A-Za-z0-9]+$", v):
            return refuse("scancel: bad signal %r" % v)
        args.append("--" + n if v is None else "--%s=%s" % (n, v))
    for i in ids:
        m = JOBID_RE.match(i)
        if not m:
            return refuse("scancel: bad job ID %r" % i)
        if not cfg.ledger.owns(m.group(1), cfg.project):
            return refuse("scancel: job %s was not submitted from this sbox project" % m.group(1))
    return reply(*run(cfg, [cfg.bin["scancel"]] + args + ids, conn, timeout=60))


SCONTROL_FLAGS = ("-o", "-d", "-a", "--oneliner", "--details", "--all")


def do_scontrol(cfg, req, conn):
    argv = list(req["argv"])
    flags = []
    while argv and argv[0].startswith("-"):
        if argv[0] not in SCONTROL_FLAGS:
            return refuse("scontrol: option %s not allowed (%s)" % (argv[0], " ".join(SCONTROL_FLAGS)))
        flags.append(argv.pop(0))
    if not argv or argv[0] != "show" or len(argv) > 3 or any(a.startswith("-") for a in argv):
        return refuse("scontrol: only 'scontrol [-o|-d] show <entity> [<id>]' is available in the sandbox")
    return reply(*run(cfg, [cfg.bin["scontrol"]] + flags + argv, conn))


def handle(cfg, req, conn):
    cmd, argv, cwd = req.get("cmd"), req.get("argv"), req.get("cwd")
    if not (isinstance(argv, list) and all(isinstance(a, str) and "\0" not in a for a in argv)
            and isinstance(cwd, str)):
        return refuse("malformed request")
    if cmd == "sbatch":
        return do_sbatch(cfg, req, conn)
    if cmd == "scancel":
        return do_scancel(cfg, req, conn)
    if cmd == "scontrol":
        return do_scontrol(cfg, req, conn)
    if cmd in READONLY:
        return reply(*run(cfg, [cfg.bin[cmd]] + argv, conn))
    return refuse("%s is not available in the sandbox, use sbatch" % cmd)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(MAX_REQUEST)
        try:
            resp = handle(self.server.cfg, json.loads(line.decode()), self.connection)
        except Exception as e:     # a bad request must not take the broker down
            resp = refuse("broker error: %s: %s" % (type(e).__name__, e))
        try:
            self.wfile.write((json.dumps(resp) + "\n").encode())
        except OSError:
            pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def watch(pid, cleanup):
    # exit with the sandbox launcher, even if it was killed without cleanup
    while True:
        time.sleep(2)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            if cleanup:
                shutil.rmtree(cleanup, ignore_errors=True)
            os._exit(0)
        except PermissionError:
            pass


def read_nul(path):
    with open(path, "rb") as f:
        return [x.decode() for x in f.read().split(b"\0") if x]


def serve(a):
    # snapshots: later edits to these files (or to sbox itself) don't change this session's jobs
    cfg = a
    cfg.layout = read_nul(a.layout)
    cfg.env = read_nul(a.env)
    with open(a.inner, "rb") as f:
        cfg.inner = f.read()
    # cfg is a: replace each path with its content, never reset before reading
    if a.netproxy:
        with open(a.netproxy, "rb") as f:
            cfg.netproxy = f.read()
    # job network only with --net-args (SLURM_NET); netproxy alone serves --publish
    cfg.net_args = read_nul(a.net_args) if a.net_args else None
    cfg.publish = None
    if a.publish_ports:
        lo, _, hi = a.publish_ports.partition("-")
        cfg.publish = (int(lo), int(hi or lo))
    cfg.bwrap = a.bwrap or shutil.which("bwrap") or "/usr/bin/bwrap"
    cfg.bin = dict((c, shutil.which(c) or "/usr/bin/" + c) for c in SHIM_CMDS)
    cfg.run_env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8",
                   "HOME": os.environ.get("HOME", "/"), "USER": os.environ.get("USER", "")}
    for d in (a.logdir, a.statedir):
        os.makedirs(d, mode=0o700, exist_ok=True)
    cfg.ledger = Ledger(a.ledger)
    if os.path.exists(a.unix):
        os.unlink(a.unix)
    server = Server(a.unix, Handler)
    server.cfg = cfg
    if a.watch_pid:
        threading.Thread(target=watch, args=(a.watch_pid, a.cleanup), daemon=True).start()
    server.serve_forever()


# ── shim (inside the sandbox) ────────────────────────────────────────────────
def shim(cmd, argv):
    if cmd in ("srun", "salloc"):
        sys.stderr.write("sbox: %s is not available in the sandbox, use sbatch\n" % cmd)
        return 1
    req = {"cmd": cmd, "argv": argv, "cwd": os.getcwd()}
    if cmd == "sbatch":
        try:
            opts, rest = parse_opts(argv)
        except Refused:
            opts, rest = None, []      # the broker reports it
        if opts is not None and not any(n in ("wrap", "help", "usage", "version") for n, _ in opts):
            try:
                if rest:
                    with open(rest[0], "rb") as f:
                        data = f.read(MAX_SCRIPT + 1)
                else:
                    data = sys.stdin.buffer.read(MAX_SCRIPT + 1)
            except OSError as e:
                sys.stderr.write("sbatch: error: Unable to open file %s: %s\n" % (rest[0], e.strerror))
                return 1
            req["script_b64"] = base64.b64encode(data).decode()
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect(os.environ.get("SBOX_SLURM_SOCK", SOCK))
    except OSError as e:
        sys.stderr.write("sbox: slurm broker not reachable (%s)\n" % e)
        return 1
    s.sendall((json.dumps(req) + "\n").encode())
    resp = json.loads(s.makefile("rb").readline().decode() or '{"rc": 1, "stderr": "sbox: no reply from the slurm broker\\n"}')
    sys.stdout.write(resp.get("stdout", ""))
    sys.stderr.write(resp.get("stderr", ""))
    return resp.get("rc", 1)


def main():
    cmd = os.path.basename(sys.argv[0])
    if cmd in SHIM_CMDS:
        sys.exit(shim(cmd, sys.argv[1:]))
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode")
    s = sub.add_parser("serve")
    s.add_argument("--unix", required=True)
    s.add_argument("--layout", required=True, help="NUL-separated bwrap args of the job layout")
    s.add_argument("--env", required=True, help="NUL-separated K=V of the job env")
    s.add_argument("--inner", required=True, help="slurm-inner.sh")
    s.add_argument("--project", required=True)
    s.add_argument("--logdir", required=True, help="Slurm's own -o/-e, not writable by the sandbox")
    s.add_argument("--statedir", required=True, help="temp launchers")
    s.add_argument("--ledger", required=True)
    s.add_argument("--bwrap")
    s.add_argument("--gpu", action="store_true")
    s.add_argument("--netproxy", help="netproxy.py: give jobs filtered network (SLURM_NET)")
    s.add_argument("--net-args", help="NUL-separated args for netproxy serve (allowlist, log)")
    s.add_argument("--publish-ports", default="", help="SLURM_PUBLISH_PORTS: LO-HI allowed for --publish")
    s.add_argument("--exclude", default="")
    s.add_argument("--constraint", default="")
    s.add_argument("--max-running", type=int, default=20,
                   help="SLURM_MAX_RUNNING: sbox jobs + array tasks, all sessions of the user")
    s.add_argument("--watch-pid", type=int)
    s.add_argument("--cleanup")
    a = p.parse_args()
    if a.mode != "serve":
        p.error("a mode is required")
    serve(a)


if __name__ == "__main__":
    main()
