# sbox: guide for agents running inside it

You are running inside **sbox**, a sandbox that limits what you can read,
write and reach on the network. This guide says what works, what doesn't,
and what to ask the user when you need more. Read it before you use Slurm,
the network, ssh, GPUs, containers or paths outside the project.

- Inside sbox when `SANDBOX_DIR` is set (it is the project directory).
- This file: `$SBOX_GUIDE` (`/run/sbox/GUIDE.md` on Linux).
- **What this session has enabled**: `$SBOX_STATUS` (`/run/sbox/status`,
  Linux). Check it before assuming a feature is on or off.
- Inside a Slurm job: `SBOX_JOB=1` (no guide or status file there).

You can't change the sandbox from inside: `paths.conf`, `net-allow.conf`
and the approval store are read-only, and paths can't be added to a running
session. When you need something, **stop and ask the user**, giving the
exact line to add (templates in "Asking for more" below). Don't try to work
around the sandbox: it fails, and it costs the user's trust.

## Filesystem

| path | access |
|---|---|
| project dir (`$SANDBOX_DIR`) | read-write |
| system (`/usr`, `/etc`, `/opt`), conda | read-only |
| `RO` / `RW` entries of paths.conf, `-ro`/`-rw` launch flags, approved `.paths.local.conf` | as listed (see `$SBOX_STATUS`) |
| `NODE_RO` / `NODE_RW` (Linux) | node-local paths such as `/scratch`: bound where they exist, also in Slurm jobs on nodes the login host doesn't share |
| `SHARED_RW` | read-write, only in projects that contain a symlink into it |
| `$HOME` (Linux) | a fresh empty tmpfs plus the binds above: writes elsewhere in `$HOME` **vanish** at exit |
| `$HOME` (macOS) | hidden except the listed paths |
| `/tmp` (Linux) | private tmpfs (RAM), gone at exit. Use `<project>/.tmp/` for scratch files that must survive or are large |
| `/var/tmp` (Linux) | private tmpfs |
| agent config (`~/.claude` ...) | read-write for the agent; per-project history on Linux |

- Missing file that the user says exists → it's probably outside the
  sandbox. Ask (see below); don't search the disk.
- `Read-only file system` / `Permission denied` on a listed path → it's in
  `RO`. Ask for `RW` if you really need to write there.
- Symlinks in the project that point outside resolve only if the target is
  bound.

## Network

All outbound traffic goes through a filtering HTTP proxy (`lib/netproxy.py`),
when `net_filter=1` in `$SBOX_STATUS`.

- `HTTP(S)_PROXY`/`ALL_PROXY` are set; `NO_PROXY=localhost,127.0.0.1,::1`.
  curl, wget, pip, uv, conda, git (https), R, python `requests`/`urllib`,
  node >= 24 (`NODE_USE_ENV_PROXY=1`) all honour them.
- Linux: the sandbox has its own network namespace with **only loopback**
  and **no DNS**. Name resolution happens in the proxy. Tools that ignore
  `*_PROXY` (raw sockets, some node/go binaries, `ping`, `nslookup`) get no
  network at all. `curl --noproxy '*'` always fails.
- Allowed hosts: `NET_ALLOW` in paths.conf + `net-allow.conf`. Patterns:
  `host`, `*.host`, `host:port`, `!host` (deny).
- Unknown host: the user may get a dialog (desktop) or tmux popup. Otherwise
  the proxy answers **403** with a hint. Then ask the user to allow it (exact
  host); don't retry in a loop.
- HTTPS isn't decrypted: allowing a host allows all traffic to it.
- Log of verdicts: `<project>/.tmp/sbox-net.log`.
- Services on the host's localhost (Linux) are **not** reachable: the
  sandbox's 127.0.0.1 is its own. Servers you start inside the sandbox are
  reachable from inside. Exception: `-local` bridges the model server's port.
- Other cluster nodes (e.g. a server in a Slurm job): through the proxy,
  e.g. `curl http://compute-cuda-02:8000/v1/models`; the node name must be
  allowed.
- macOS: Seatbelt blocks everything except localhost; same proxy rules.

## ssh and git over ssh (Linux)

- Only if `SSH_DIR` is set (`ssh=` in `$SBOX_STATUS`). Keys, config and
  `known_hosts` are read-only: you can use the key, not add host keys.
  Unknown host keys fail: ask the user to connect once outside.
- ssh goes through the proxy (generated `ProxyCommand`), so `host:22` must be
  allowed like any host.
- No ssh agent forwarding. Prefer https remotes (`gh`, git with a token
  helper) when they work.

## GPU and containers (Linux)

- `gpu=1` and devices present: `/dev/nvidia*`, `/sys/module` (RO) and a
  `/dev/shm` tmpfs are bound; CUDA works. `CUDA_VISIBLE_DEVICES` is passed
  through. The login node (compute-01) has no GPU: run GPU work as Slurm jobs.
- Apptainer (unprivileged): `/dev/fuse` and a private `/var/tmp` are
  provided, so `.sif` images mount with squashfuse. `--nv` needs the GPU binds.
  Without `/dev/fuse` apptainer extracts the whole image into `/tmp`.
- Docker: **none on Linux**, use apptainer. macOS only, see below.

## Slurm (Linux)

Check `slurm=` in `$SBOX_STATUS`:

| value | meaning |
|---|---|
| `0` | no Slurm. Ask the user to relaunch with `-sl` |
| `broker` | `sbatch` & co are shims to a broker outside; jobs run **inside bwrap** on the node. Everything below applies |
| `1` | direct munge access, jobs run unsandboxed (user's explicit choice). Normal Slurm rules |

### What the broker allows

- `sbatch` only: batch scripts and job arrays, **one node**. No `srun`,
  `salloc`, MPI, interactive jobs or job steps.
- Allowed options (CLI or `#SBATCH`, long names exactly, no abbreviations):
  `-p/--partition -t/--time --time-min -n/--ntasks -c/--cpus-per-task
  --ntasks-per-node --mem --mem-per-cpu --mem-per-gpu -G/--gpus
  --gpus-per-node --gpus-per-task --gres --exclusive -A/--account -q/--qos
  --reservation --nice -N 1 -C/--constraint -x/--exclude -w/--nodelist
  -J/--job-name -a/--array -d/--dependency -H/--hold -b/--begin --deadline
  --requeue --no-requeue --mail-type --mail-user --parsable -Q/--quiet
  -W/--wait --test-only -o/--output -e/--error -i/--input --open-mode
  -D/--chdir --wrap --signal=B:<USR1|USR2|HUP|TERM>[@secs] --publish=PORT`.
  `sbatch --help` lists them.
- Refused: `--export`, `--export-file`, `--get-user-env`, `--uid`, `--gid`,
  `--container`, everything not listed. **The job environment is cleared**:
  pass settings in a file in the project or as script arguments
  (`sbatch job.sh arg1 arg2`), not via the environment.
- The script must start with `#!`. `-J` can't contain `/`.
- `scancel`: only explicit IDs of jobs submitted from **this project**
  (`123`, `123_4`, `123_[1-5]`), with `-s/--signal -Q -v -b -f`. No `-u`,
  `--name`, `--state`.
- `scontrol`: only `scontrol [-o|-d] show <entity> [id]`.
- `squeue`, `sinfo`, `sacct`, `sstat`, `sprio`, `sshare`: as usual.
- Budget: `slurm_max_running` jobs + array tasks (running or pending), shared
  by all sbox sessions of the user. Arrays get a `%N` throttle to fit; when
  it's full, sbatch is refused: wait or scancel.

### Inside a job

- Same paths as the interactive sandbox (project RW, paths.conf binds,
  `NODE_RO/NODE_RW` if the node has them), no agent config, no ssh.
- `$HOME` is a tmpfs; `/tmp` is a per-job dir on the node's disk.
- Env: `PATH`, `HOME`, `USER`, `LANG`, `TMPDIR=/tmp`, `SANDBOX_DIR`, conda
  vars, `SLURM_*`, `CUDA_VISIBLE_DEVICES`, `SBOX_JOB=1`,
  `SLURM_SUBMIT_DIR` = the directory you submitted from. Nothing else.
- `module` isn't defined: `source /etc/profile.d/lmod.sh` first. conda:
  `source "$(dirname "$(dirname "$CONDA_EXE")")/etc/profile.d/conda.sh"`.
- GPUs: request them (`--gres=gpu:1`, typed `gpu:L40S:2`, `-p odap-gpu`);
  only the allocated ones are usable.
- Network: if `slurm_net=1`, jobs get the same proxy and allowlist (no
  dialog: unknown hosts are denied). If `0`, jobs have **no network**.
  Prefer offline jobs (pre-download models/packages from the session).
- Inbound: nothing can connect to a job unless it uses `--publish` (below).

### Serving from a job (`--publish`)

For a server that other jobs or the session must reach (vLLM, an API
gateway, a database):

```bash
#!/bin/bash
#SBATCH -p odap-gpu --gres=gpu:1 -t 08:00:00
#SBATCH --publish=8000
vllm serve /scratch/models/X --host 127.0.0.1 --port "$SBOX_PUBLISH_PORT" --api-key "$(cat key.txt)"
```

- The port must be in `slurm_publish_ports` (`$SBOX_STATUS`); empty = off,
  ask the user. One port per job; not with `--array`.
- The server listens on `127.0.0.1:PORT` (or `0.0.0.0`) **inside** the job;
  the node exposes it as `<node>:PORT` to the whole cluster network. **Always
  set an API key**: other users can reach it.
- Several processes in one job talk over the job's own localhost (any port).
- Find the node: `squeue -j <id> -h -o %N`. Wait until it answers:
  `curl -s http://<node>:PORT/health` (from the session, through the proxy;
  the node must be allowed, see Network).
- Port already taken on that node: the job fails with exit 95 before
  running. Pick another port or pin the node with `-w`.

### Debugging jobs

- Your `-o/-e` files (default `slurm-%j.out` in the submit dir) hold the
  script's output.
- Launcher errors (before your script starts) go to
  `~/.local/state/sbox/slurm/logs/<project>-<hash>/<jobid>.log`, readable
  from the session.
- Exit codes from the launcher: **95** `--publish` port in use, **96** could
  not create the job's temp dir, **97** bwrap unusable on the node (ask the
  user to add it to `SLURM_EXCLUDE`), **98** could not open `-o/-e/-i`.
- A path that exists on the node but not in the job → it's not in
  `RO/RW/NODE_RO/NODE_RW`; `RO/RW` entries that don't exist on the login
  host are dropped (use `NODE_*` for node-local paths).

## Docker (macOS)

- Only with the `-docker` launch flag: `DOCKER_HOST` points to a colima VM
  (profile `sbox`) that mounts **only the project**. `docker run -v
  "$PWD:/w"` works; other host paths appear empty in containers.
- Containers bypass the network filter (the VM has its own network).
- `docker login` lasts one session. One project at a time uses the VM.
- Not set (`DOCKER_HOST` empty) → ask the user to relaunch with `-docker`.

## Local model (`-local`)

The user can run the agent against a model served at `localhost:8000`
(`claude -local`). Then `ANTHROPIC_BASE_URL` points there and only that port
is bridged into the sandbox. Nothing for you to do.

## Asking for more

Paths and network can't be granted from inside. Tell the user exactly what
to do; they'll relaunch, and `claude -c` keeps the conversation.

| you need | ask the user to |
|---|---|
| a path for this launch only | relaunch with `claude -c -ro PATH` (or `-rw PATH`) |
| a path for this project, every launch | you may write `<project>/.paths.local.conf` with lines `ro PATH` / `rw PATH`; the user approves it at the next launch |
| a path for all projects | add it to `RO=(...)` / `RW=(...)` in `paths.conf` |
| a path that only compute nodes have (`/scratch`) | add it to `NODE_RO=(...)` / `NODE_RW=(...)` in `paths.conf` |
| a shared folder writable in some projects | add it to `SHARED_RW` and symlink it into the project |
| a host on the network | add `host` (or `*.domain`, `host:port`) to `net-allow.conf` or `NET_ALLOW` in `paths.conf` (live, no relaunch) |
| Slurm | relaunch with `-sl` |
| network inside jobs | `SLURM_NET=1` in `paths.conf` (and the host allowed), relaunch |
| to publish a port from a job | `SLURM_PUBLISH_PORTS="8000-8009"` in `paths.conf`, relaunch |
| more concurrent jobs | raise `SLURM_MAX_RUNNING` in `paths.conf` |
| a node excluded / bwrap failing (exit 97) | add it to `SLURM_EXCLUDE` |
| GPUs in the interactive session | `ENABLE_GPU=1` in `paths.conf`, on a host with GPUs |
| ssh | `SSH_DIR=<dir with key, config, known_hosts>` in `paths.conf` |
| docker (macOS) | relaunch with `-docker` |
| something the broker refuses (srun, MPI, `--export`) | rethink the job first. Last resort: the user's own unsandboxed `-slurm-no-sandbox` mode; it's their call, don't push it |

`paths.conf` and `net-allow.conf` are in the sbox install dir
(`paths_conf=` in `$SBOX_STATUS`). Changes to `paths.conf` take effect at the
next launch; `net-allow.conf` is re-read live.

## Launch flags (for the user)

```
claude [-sl] [-local] [-docker] [-ro PATH] [-rw PATH] [claude args]
aicode <coder> ...      same flags, any coder (hermes, ...)
sbox [-ro PATH] [-rw PATH]   sandboxed shell
-slurm-no-sandbox       direct Slurm, jobs unsandboxed (user only)
```
