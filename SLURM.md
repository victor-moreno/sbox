# Slurm jobs under the sandbox (broker design)

Status: implemented and accepted 2026-09-29 (phases 0-6 below): `aicode -sl` /
`ENABLE_SLURM=broker`. Code: `lib/slurmproxy.py` (broker + shim),
`lib/slurm-inner.sh`, broker block in `lib/linux.sh`. Designed on macOS, built and
tested on the odap cluster (Linux, bwrap). Working notes: `task_plan.md`,
`findings.md`, `progress.md` (plan-with-files, gitignored, local only).

## Problem

`ENABLE_SLURM=1` / `-sl` binds `/run/munge` and `/run/slurm/conf` into bwrap
(`lib/linux.sh`, "Slurm/munge" block). That breaks the sandbox three ways:

1. The job runs on the compute node as the user, outside any bwrap, with full
   access to `$HOME`, `/scratch`, everything.
2. The munge socket makes the sandbox *be* the user for Slurm: it can submit
   anything, `scancel`/`scontrol update` any of the user's jobs, `srun --pty`
   onto a node unsandboxed. A wrapper around `sbatch` or a `cli_filter` can't
   fix this: anything that reaches the munge socket can talk to slurmctld
   directly.
3. The network filter becomes advisory (host network namespace kept for
   slurmctld TCP).

Rule that drives the design: **the sandbox never holds a munge credential.**

## Decisions (user, 2026-09-29)

- Broker approach, as first implementation.
- No MPI, no multi-node, no `srun`/`salloc`/`srun --pty`. Batch jobs and job
  arrays only.
- A limit on the number of concurrent tasks is required.
- bwrap exists on the compute nodes, at least on some: jobs must fail closed
  on nodes where it is missing or unusable, and it must be possible to keep
  jobs off those nodes.
- During development: new mode `ENABLE_SLURM=broker` (flag `-slb`).
  Once it works, `-sl` switches to the broker.
- The user launches the dev session with `-sl` (direct munge) so real jobs can
  be submitted while developing.
- Flags (user, 2026-09-29, phase 3): `-sl` = broker, `-slurm-no-sandbox` = direct
  munge (the former `-sl`; named in phase 6 to make the risk explicit). No separate `-slb`.

## Architecture

```
 login node                                           compute node
 ┌─────────────────────────────┐                      ┌───────────────────────────┐
 │ bwrap sandbox (--unshare-net│                      │ slurmstepd (as user)      │
 │   no /run/munge)            │                      │  └ generated launcher     │
 │  sbatch/squeue/... = shims ─┼─ unix socket ─┐      │     (fail closed if no    │
 └─────────────────────────────┘               │      │      bwrap)               │
                                               ▼      │     └ bwrap: job layout   │
 lib/slurmproxy.py (outside, has munge) ── sbatch ──► │        └ user script      │
   validates, re-serializes, budget, ledger           └───────────────────────────┘
```

## Components

### 1. Broker: `lib/slurmproxy.py`

- Python 3 stdlib only, same style as `lib/netproxy.py`. Started by
  `linux.sh` outside bwrap with `--watch-pid $$`, dies with the session.
  Jobs already submitted keep running (they are self-contained).
- Listens on `$SLURMDIR/sock/sock` (`SLURMDIR=$(mktemp -d /tmp/sbox-slurm-XXXXXX)`,
  mode 700), bound into the sandbox at `/run/sbox-slurm/`.
- Protocol: one JSON line per connection.
  Request `{"cmd", "argv", "cwd", "script"}`, reply `{"rc", "stdout", "stderr"}`.
- Snapshots at startup (so a sandbox that can edit sbox itself, e.g. when the
  project *is* this repo, can't change what later jobs of this session run):
  the job layout written by `linux.sh` (`$SLURMDIR/layout`, NUL-separated
  bwrap args), the job env (`$SLURMDIR/env`), config values, and its own
  launcher template (in memory).
- **Never opens a path supplied by the sandbox.** The shim reads the script
  inside the sandbox and sends its content. `cwd`, `-o/-e/-i` are only used
  inside the job's bwrap, never on the host.
- Runs `sbatch` & co with a minimal env (PATH, HOME, USER, LANG), so the
  user's login env (tokens, `SBATCH_*`) never reaches the job or slurmctld.
- Always submits with `--parsable` (to learn the job ID for the ledger) and
  reformats the reply to what the caller asked for.

Commands:

| command | handling |
|---|---|
| `sbatch` | full validation (below), budget, ledger |
| `scancel` | only explicit IDs (`123`, `123_4`, `123_[1-5]`) that are in the ledger for this project; `-s/--signal` allowed; `-u`, `--name`, `--state`, ... refused |
| `scontrol` | only `show ...` (with `-o`, `-d`) |
| `squeue`, `sinfo`, `sacct`, `sstat`, `sprio`, `sshare` | read-only, argv passed as-is (no shell) |
| `srun`, `salloc`, anything else | refused: "not available in the sandbox, use sbatch" |

### 2. Shims (`lib/slurmproxy.py` itself)

The broker file, dispatching on `basename(argv[0])`. `linux.sh` finds the real
paths on the host (`command -v sbatch squeue ...`, may be `/usr/bin` or
`/opt/slurm/bin`) and `--ro-bind`s the shim over each, so both `sbatch` and
`/usr/bin/sbatch` hit the shim. For `sbatch` it locates the script argument
(or `--wrap`, or stdin when there is no script), reads it and sends the
content.

### 3. Job launcher (generated per job by the broker)

The script actually given to `sbatch`. Everything user-controlled is quoted
(`shlex.quote`) or base64; nothing is interpolated raw. Outline:

```bash
#!/bin/bash
B=<absolute bwrap path found on the login node>
if ! "$B" --unshare-pid --ro-bind / / --proc /proc /bin/true 2>/dev/null; then
  echo "sbox: bwrap unusable on $(hostname -s): job NOT run; add it to SLURM_EXCLUDE" >&2
  exit 97                               # fail closed: payload never runs unsandboxed
fi
# GPUs detected on the node at run time (the login node may have none), if ENABLE_GPU=1,
# same binds as interactive: /dev/nvidia*, /dev/shm tmpfs, /sys/module RO (NVML needs it)
dev=(); for d in /dev/nvidia*; do [ -e "$d" ] && dev+=(--dev-bind "$d" "$d"); done
[ ${#dev[@]} -gt 0 ] && [ -d /sys/module/nvidia ] && dev+=(--tmpfs /dev/shm --dir /sys --ro-bind /sys/module /sys/module)
# scancel/timeout SIGKILL the batch shell (no TERM first), so the EXIT trap only covers
# normal ends: first remove this user's sbox-job-<id>.* dirs whose job cgroup
# (/sys/fs/cgroup/freezer/slurm_<node>/uid_<uid>/job_<id>) is gone
<sweep stale job dirs>
jt=$(mktemp -d "${TMPDIR:-/tmp}/sbox-job-$SLURM_JOB_ID.XXXXXX"); trap 'rm -rf "$jt"' EXIT  # node disk, not RAM
env=(<snapshot env>)                                     # + SLURM_*, CUDA_VISIBLE_DEVICES, ...
exec 8< <(base64 -d <<<'<inner wrapper>')                # fixed, trusted
exec 9< <(base64 -d <<<'<user script>')                  # snapshot at submit, like sbatch
"$B" <layout> --bind "$jt" /tmp "${dev[@]}" \
     --ro-bind-data 8 /run/sbox-job/inner --ro-bind-data 9 /run/sbox-job/script \
     --chdir <cwd> /usr/bin/env -i "${env[@]}" \
     /bin/bash /run/sbox-job/inner <out> <err> <in> <open-mode> -- <script args>
```

The inner wrapper (inside bwrap) expands `%j %A %a %x %u %N %%` (and
`%3a`-style padding) from `SLURM_*`, opens the user's `-o/-e/-i` there (so a
symlink planted in the project resolves inside the sandbox), then
`exec bash /run/sbox-job/script "$@"`. Defaults as in sbatch:
`slurm-%j.out` (`slurm-%A_%a.out` for arrays) in the job cwd; stderr to the
same file when `-e` is absent.

Job layout vs interactive layout:

| | interactive | job |
|---|---|---|
| system RO, paths.conf RO/RW, SHARED_RW, `-ro`/`-rw`/`.paths.local.conf`, conda, project RW | yes | same, and only the paths that existed at launch (`-try` variants, a node may lack some; project must exist) |
| `~/.local/state/sbox` (ledger, logs, path approvals) | RO | RO (even if paths.conf makes `~/.local` RW) |
| `~/.claude*`, per-project coder isolation | yes | **no** (jobs get no agent credentials) |
| `SSH_DIR`, generated `~/.ssh/config` | if set | **no** (no network in jobs) |
| network | netproxy via unix socket | none (`--unshare-net`, proxy unreachable from nodes) |
| `/tmp` | tmpfs | per-job dir on node disk |
| `/dev` | minimal + `/dev/fd` links + tty/pts; GPU binds if `ENABLE_GPU=1` and the host has GPUs | same without tty/pts; GPU binds decided on the node at run time |
| munge / broker socket | broker socket only | neither: no submission from inside a job |
| env | ENV_BASE + proxy + coder vars | ENV_BASE without proxy/coder vars, + `SLURM_*`, `CUDA_VISIBLE_DEVICES`, `ROCR_VISIBLE_DEVICES`, `GPU_DEVICE_ORDINAL`, `TMPDIR=/tmp`, `SBOX_JOB=1` |

### 4. `lib/linux.sh` changes

- Refactor the bwrap arg building into a function used for both layouts, so
  interactive and job layouts can't drift apart.
- `ENABLE_SLURM` values: `0` off, `1` direct, `broker`;
  `aicode -sl` sets `SBOX_SLURM=broker`, `-slurm-no-sandbox` sets `1`. `sbox` (shell) uses paths.conf.
- Broker mode:
  - no `/run/munge`, no `/run/slurm/conf` binds;
  - network block takes the strict branch (`--unshare-net`, `NET_FORWARD=1`), as
    without slurm, so the `SSH_DIR` ssh config also gets the netproxy
    `ProxyCommand` again (today slurm mode leaves ssh direct);
  - write `$SLURMDIR/layout` and `$SLURMDIR/env`, start the broker, wait for
    the socket (like netproxy), bind only `$SLURMDIR/sock` at `/run/sbox-slurm` (snapshots and temp launchers stay out of reach);
  - bind the shim over each slurm client binary;
  - bind `~/.local/state/sbox` **RO, after USER_BINDS** (later binds win), so
    the ledger stays read-only even if paths.conf makes `~/.local` RW.

### 5. Config (`paths.conf`, RO inside the sandbox)

```bash
ENABLE_SLURM=0            # 0 | 1 (direct, current) | broker
SLURM_MAX_RUNNING=20      # concurrency budget: jobs + array tasks, all sbox sessions of this user
SLURM_EXCLUDE=""          # nodes without usable bwrap (Slurm hostlist), added as --exclude
SLURM_CONSTRAINT=""       # node feature, if the admins tag bwrap nodes; ANDed with the user's -C
```

## sbatch validation

- CLI options and `#SBATCH` lines of the script (up to the first
  non-comment, non-blank line, as sbatch does; CLI wins) go through the same
  parser.
- **Allowlist.** Unknown options are refused, with a message listing the
  allowed ones. Abbreviated long options (getopt accepts `--part=`) are
  refused. The broker **re-serializes** accepted options as `--long=value`
  and never passes the user's tokens through.
- The user's script is embedded base64 in the launcher, so its own `#SBATCH`
  (or `#PBS`) lines are never seen by sbatch.

| class | options | notes |
|---|---|---|
| resources | `-p/--partition` `-t/--time` `--time-min` `-n/--ntasks` `-c/--cpus-per-task` `--ntasks-per-node` `--mem` `--mem-per-cpu` `--mem-per-gpu` `-G/--gpus` `--gpus-per-node` `--gpus-per-task` `--gres` `--exclusive` `-A/--account` `-q/--qos` `--reservation` `--nice` | |
| placement | `-N/--nodes` | only `1` (no srun: extra nodes would sit idle) |
| | `-C/--constraint` | ANDed with `SLURM_CONSTRAINT` |
| | `-x/--exclude` | merged with `SLURM_EXCLUDE` |
| | `-w/--nodelist` | allowed; `--exclude` still added |
| control | `-J/--job-name` (no `/`) `-a/--array` `-d/--dependency` `-H/--hold` `--begin` `--deadline` `--requeue` `--no-requeue` `--mail-type` `--mail-user` `--parsable` `-Q/--quiet` `-W/--wait` `--test-only` | `--test-only` isn't recorded in the ledger |
| I/O (handled by the launcher, inside bwrap) | `-o/--output` `-e/--error` `-i/--input` `--open-mode` `-D/--chdir` `--wrap` | Slurm itself gets `--output/--error=<LOGDIR>/%j.log` (`%A_%a.log` for arrays) and `--chdir=<LOGDIR>` |
| signals | `--signal=B:<USR1\|USR2\|HUP\|TERM>[@secs]` | only `B:`: without it Slurm signals job steps, and there are none. The launcher forwards these signals (also from `scancel -b -s`) to the user script (added 2026-09-29) |
| refused | `--export` `--export-file` `--get-user-env` `--uid` `--gid` `--container` `--bb` `--bbf` `--comment` `--wckey`, everything not listed | |

Why Slurm's own output goes to a broker dir: slurmstepd opens `-o/-e` as the
user **before** bwrap starts and follows symlinks, so `-o ~/.bashrc`, or a
symlink `out.log -> ~/.bashrc` planted in the project after submission, would
write outside the sandbox. `LOGDIR=~/.local/state/sbox/slurm/logs/<basename>-<hash8>/`
is not writable from the sandbox; it gets bound RO into this project's
sandbox so the agent can read launcher errors ("bwrap unusable on nodeX").
Only launcher messages land there; the job's output goes where the user asked.

## Concurrency budget

- Budget `SLURM_MAX_RUNNING`, global per user across all sbox sessions and
  projects. It counts jobs and array tasks (not CPUs; a CPU cap could come
  later).
- Weight of a live job: plain job = 1; array =
  `min(throttle, tasks still in squeue)`. Pending jobs count too
  (conservative: anything that may start counts).
- On `sbatch --array` with no `%N`, the broker adds `%min(ntasks, remaining)`.
  If `%N` exceeds what remains, it is clamped. Either way the caller is told
  on stderr. With `remaining == 0`, the submission is refused:
  "budget full (20/20): wait or scancel".
- Ledger `~/.local/state/sbox/slurm/ledger.json` (`id, project, weight, time`),
  locked with `fcntl` across sessions. The lock is held through
  squeue → budget check → sbatch → ledger write. Pruning uses one
  `squeue --me -h -r -o %F` call per submission (one line per task; count per
  base ID, drop IDs that are gone).
- The sandbox can't raise its budget: no `scontrol update`
  (`ArrayTaskThrottle`), and the ledger and paths.conf are RO.

## Nodes without bwrap

- Probe once (phase 0) and put the failing nodes in `SLURM_EXCLUDE`. Better:
  ask the admins for a node feature (e.g. `bwrap`) and use `SLURM_CONSTRAINT`.
- Probe loop (from the `-sl` dev session). Down or drained nodes would hang,
  so only probe idle/mixed/allocated ones, and use `--immediate`:
  ```bash
  for n in $(sinfo -h -N -t idle,mix,alloc -o %N | sort -u); do
    srun -w "$n" -N1 -n1 -t 2 --immediate=60 --quiet \
      "$(command -v bwrap)" --unshare-pid --ro-bind / / --proc /proc /bin/true \
      && echo "$n ok" || echo "$n FAIL"
  done
  ```
- Whatever the config says, the launcher checks bwrap first and exits 97
  without running the payload.

## Implementation phases

Phase 0: facts (record in `findings.md`) — done 2026-09-29
- [x] Slurm version; paths of `sbatch srun salloc squeue scancel sacct sinfo scontrol sstat sprio sshare`
  (23.11.11, all in `/usr/bin`)
- [x] bwrap version; `--ro-bind-data` supported? (fallback `--file`)
  (0.4.0 unprivileged, same on all nodes; `--ro-bind-data` works)
- [x] which nodes have usable bwrap (probe above) → `SLURM_EXCLUDE`; ask admins about a feature tag
  (all 17 nodes ok → `SLURM_EXCLUDE=""`; no tag needed for now, re-probe when nodes are added)
- [x] in a job: `TMPDIR`, job_container plugin, `/dev/shm`, GPU device nodes, `MaxArraySize`, default partition
  (`TMPDIR=/tmp` node-local ext4, no job_container, `/dev/shm` tmpfs, all `/dev/nvidia*` present
  but gated by `ConstrainDevices=yes`, `MaxArraySize=10001`, default `odap`)
- [x] project dir, `/share`, conda, `~/.local` visible on compute nodes at the same paths
  (yes; `/scratch` only on compute-cuda-[02-04] → `-try` binds needed)

Phase 1: launcher by hand (real sbatch from the `-sl` dev session) — done 2026-09-29
(prototype generator `.tmp/phase1/mklauncher.sh`, inner wrapper `lib/slurm-inner.sh`)
- [x] hand-written launcher + inner wrapper; simple job, array, GPU job, conda/R job
- [x] containment inside the job (see acceptance tests), exit codes in `sacct`, timeout and scancel kill everything
  (no process survives; but the launcher is SIGKILLed without any TERM, so its
  cleanup trap never runs → stale-dir sweep, see launcher outline)
- [x] output patterns, open-mode, default output names; fail closed on a non-bwrap node
  (fail closed simulated with a missing bwrap path: FAILED 97, payload not run, message in LOGDIR)
- [x] GPU job: the interactive GPU binds (`/dev/nvidia*`, `/dev/shm`, `/sys/module` RO) are enough on a compute node
  (`nvidia-smi` sees only the allocated GPU; other `/dev/nvidia*` are bound but the device cgroup denies them)

Phase 2: broker + shim — done 2026-09-29 (`lib/slurmproxy.py` is both: `serve` = broker,
invoked as sbatch/squeue/... = shim, so they share the option parser; python 3.6 compatible,
the cluster's system python3)
- [x] option parser + array-spec counter (`1-10`, `1-10:2`, `1,3,5-7`, `%N`) with unit tests (no Slurm needed)
- [x] `#SBATCH` extraction, `--wrap`, stdin script, re-serialization
- [x] launcher generation, command table, minimal env for sbatch
  (inner wrapper honours the shebang, scripts without `#!` refused like sbatch;
  `SLURM_SUBMIT_DIR` reset to the caller's cwd; default job name = script basename)
- [x] functional test inside the dev session (broker running there has munge)

Phase 3: `linux.sh` integration behind `ENABLE_SLURM=broker` / `-sl` — done 2026-09-29
- [x] layout function refactor (interactive layout unchanged: compare bwrap argv before/after)
  (`bwrap_fs interactive|job` + `PROJECT_TAIL`; argv byte-identical for shell/claude ×
  off/direct, checked with a fake bwrap on PATH)
- [x] broker start, socket, shim binds, strict network, RO state dir, LOGDIR bind
  (only `$SLURMDIR/sock` is bound in, at `/run/sbox-slurm`; layout/env snapshots and temp
  launchers stay in `$SLURMDIR`, out of the sandbox's reach. End to end in a nested
  sandbox: no munge, shim, ledger RO, jobs 206370/206371 ok, broker exits and cleans up)

Phase 4: budget + ledger (locking, pruning, clamping, refusal) — done 2026-09-29
(`apply_budget` in `lib/slurmproxy.py`; `SLURM_MAX_RUNNING` passed as `--max-running`.
Ledger entries also keep the array `throttle`. Lock released as soon as the job ID is
recorded, so `sbatch -W` doesn't block other submissions; any error path releases it.
9 unit tests; real jobs with limit 3/4: array `1-10` → `ArrayTaskThrottle=2`, full budget
refused, 3 parallel submissions for 1 free slot → exactly 1 accepted)

Phase 5: acceptance, from a session the user starts with `claude -sl`, in a
**separate scratch project** (not this repo, which the sandbox can edit)
— run 2026-09-29 in `~/app/claude` on compute-01: 45 passed, 0 failed
(script `.tmp/phase5/acceptance.sh`, local; `~/.bashrc` replaced by a canary file,
`scancel` of a foreign job tested with a fake ID); host check (`hostcheck.sh verify`): canary
unchanged, no `~/sbox-pwned`. Done.

Phase 6: README + `paths.conf.example`; direct mode — done 2026-09-29: direct mode stays
(user) as `-slurm-no-sandbox` / `ENABLE_SLURM=1`, for MPI/srun/interactive jobs, with a
warning at every launch; README "Slurm (Linux)" section.

## Acceptance tests (from inside a `-sl` sandbox)

Must fail or be refused:
- [x] `ls /run/munge`, `munge -n` → not there
- [x] `sbatch --wrap 'touch ~/pwned'` → no `~/pwned` on the host
- [x] `sbatch --wrap 'cat ~/.ssh/id_*; ls ~/.claude'` → nothing readable
- [x] `sbatch -o ~/.bashrc --wrap 'echo x'` → `~/.bashrc` untouched
- [x] `ln -s ~/.bashrc out.log; sbatch -o out.log --wrap 'echo x'` → untouched
- [x] `-J ../../x -o %x.out` → refused (`/` in the job name)
- [x] `--export=ALL`, `--get-user-env`, `--container=...`, `--uid=0`, `--part=x` (abbreviation) → refused
- [x] the same options as `#SBATCH` lines in the script → refused
- [x] `scancel <job not submitted via sbox>`, `scancel -u $USER` → refused
- [x] `scontrol update ...`, `scontrol hold ...` → refused; `srun`, `salloc` → refused
- [x] inside a job: `sbatch`, `squeue` → fail (no munge, no broker)
- [x] inside a job: `curl https://example.com` → fails
- [x] interactive: `curl --noproxy '*' https://example.com` fails, via proxy works
  (with `NET_FILTER=1`: direct by name and IP blocked, allowed host via proxy ok, denied host
  refused, slurm still works in the private network namespace; full run 50/50)
- [x] array `1-1000` without `%` → throttle added; budget exhausted → refused
- [x] job on a node without bwrap → FAILED, exit 97, payload not executed
  (phase 1, simulated with a missing bwrap path: every node has bwrap)
- [x] editing `lib/slurmproxy.py` from the sandbox doesn't change jobs of the running session
  (marker lines added to the launcher template and `slurm-inner.sh` under a running broker: not in the job)

Must work:
- [x] plain job, array with `%N`, dependency chain, `-W`, `--test-only`
- [x] GPU job sees only its allocated GPU(s)
- [x] `squeue`, `sacct`, `sinfo`, `scontrol show job` output as usual
- [x] `scancel` on own sbox jobs (plain and array tasks)
- [x] launcher errors readable in LOGDIR from the sandbox

## Known limits

- No MPI / multi-node, no interactive jobs, no job steps (`srun` inside a job).
- Signals to the batch script: only USR1, USR2, HUP, TERM reach the user script
  (the launcher runs bwrap in the background, where bash ignores INT/QUIT).
- Jobs have no network.
- `$HOME` inside a job is a tmpfs plus the paths.conf binds, like the
  interactive sandbox: writes elsewhere in `$HOME` vanish.
- `module` (Lmod) isn't defined under `env -i`; scripts source
  `/etc/profile.d/lmod.sh` (or equivalent) themselves.
- Code changes to sbox made from inside a sandbox take effect at the next
  session the user launches, as with `linux.sh` today.
- Strongest alternative, if admin help is available: a dedicated Unix account
  for the agent, with ACL access only to project dirs. Slurm/munge are then
  harmless without per-job wrapping.
