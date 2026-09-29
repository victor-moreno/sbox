# Slurm jobs under the sandbox (broker design)

Status: design only, nothing implemented yet. Written 2026-09-29 on macOS;
implementation and testing continue on the HPC login node (Linux, bwrap).
While developing there, keep working notes in `task_plan.md`, `findings.md`,
`progress.md` (plan-with-files, gitignored, local only).

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
- Listens on `$SLURMDIR/sock` (`SLURMDIR=$(mktemp -d /tmp/sbox-slurm-XXXXXX)`,
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

### 2. Shims: `lib/slurm-shim.py`

One Python file, dispatches on `basename(argv[0])`. `linux.sh` finds the real
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
dev=(); for d in /dev/nvidia* /dev/nvidia-caps; do [ -e "$d" ] && dev+=(--dev-bind "$d" "$d"); done
jt=$(mktemp -d "${TMPDIR:-/tmp}/sbox-job-XXXXXX")      # node-local disk as /tmp, not RAM tmpfs
env=(<snapshot env>)                                     # + SLURM_*, CUDA_VISIBLE_DEVICES, ...
exec 8< <(base64 -d <<<'<inner wrapper>')                # fixed, trusted
exec 9< <(base64 -d <<<'<user script>')                  # snapshot at submit, like sbatch
"$B" <layout> --bind "$jt" /tmp --tmpfs /dev/shm "${dev[@]}" \
     --ro-bind-data 8 /run/sbox-job/inner --ro-bind-data 9 /run/sbox-job/script \
     --chdir <cwd> /usr/bin/env -i "${env[@]}" \
     /bin/bash /run/sbox-job/inner <out> <err> <in> <open-mode> -- <script args>
rc=$?; rm -rf "$jt"; exit $rc
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
| system RO, paths.conf RO/RW, SHARED_RW, conda, project RW | yes | same (`-try` variants for paths.conf entries, a node may lack some; project must exist) |
| `~/.claude*`, per-project coder isolation | yes | **no** (jobs get no agent credentials) |
| network | netproxy via unix socket | none (`--unshare-net`, proxy unreachable from nodes) |
| `/tmp` | tmpfs | per-job dir on node disk |
| `/dev` | minimal + tty/pts | minimal + GPU devices + `/dev/shm` tmpfs |
| munge / broker socket | broker socket only | neither: no submission from inside a job |
| env | ENV_BASE + proxy + coder vars | ENV_BASE without proxy/coder vars, + `SLURM_*`, `CUDA_VISIBLE_DEVICES`, `ROCR_VISIBLE_DEVICES`, `GPU_DEVICE_ORDINAL`, `TMPDIR=/tmp`, `SBOX_JOB=1` |

### 4. `lib/linux.sh` changes

- Refactor the bwrap arg building into a function used for both layouts, so
  interactive and job layouts can't drift apart.
- `ENABLE_SLURM` values: `0` off, `1` direct (current), `broker` (new, dev);
  `aicode` `-slb` sets `SBOX_SLURM=broker`. `sbox` (shell) uses paths.conf.
- Broker mode:
  - no `/run/munge`, no `/run/slurm/conf` binds;
  - network block takes the strict branch (`--unshare-net`), as without slurm;
  - write `$SLURMDIR/layout` and `$SLURMDIR/env`, start the broker, wait for
    the socket (like netproxy), bind `$SLURMDIR` at `/run/sbox-slurm`;
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
| refused | `--export` `--export-file` `--get-user-env` `--uid` `--gid` `--container` `--bb` `--bbf` `--signal` `--comment` `--wckey`, everything not listed | `--signal` could come later (bwrap signal forwarding untested) |

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

Phase 0: facts (record in `findings.md`)
- [ ] Slurm version; paths of `sbatch srun salloc squeue scancel sacct sinfo scontrol sstat sprio sshare`
- [ ] bwrap version; `--ro-bind-data` supported? (fallback `--file`)
- [ ] which nodes have usable bwrap (probe above) → `SLURM_EXCLUDE`; ask admins about a feature tag
- [ ] in a job: `TMPDIR`, job_container plugin, `/dev/shm`, GPU device nodes, `MaxArraySize`, default partition
- [ ] project dir, `/share`, conda, `~/.local` visible on compute nodes at the same paths

Phase 1: launcher by hand (real sbatch from the `-sl` dev session)
- [ ] hand-written launcher + inner wrapper; simple job, array, GPU job, conda/R job
- [ ] containment inside the job (see acceptance tests), exit codes in `sacct`, timeout and scancel kill everything
- [ ] output patterns, open-mode, default output names; fail closed on a non-bwrap node
- [ ] check whether CUDA needs `/sys` or `/proc/driver/nvidia` (then add RO binds)

Phase 2: broker + shim
- [ ] option parser + array-spec counter (`1-10`, `1-10:2`, `1,3,5-7`, `%N`) with unit tests (no Slurm needed)
- [ ] `#SBATCH` extraction, `--wrap`, stdin script, re-serialization
- [ ] launcher generation, command table, minimal env for sbatch
- [ ] functional test inside the dev session (broker running there has munge)

Phase 3: `linux.sh` integration behind `ENABLE_SLURM=broker` / `-slb`
- [ ] layout function refactor (interactive layout unchanged: compare bwrap argv before/after)
- [ ] broker start, socket, shim binds, strict network, RO state dir, LOGDIR bind

Phase 4: budget + ledger (locking, pruning, clamping, refusal)

Phase 5: acceptance, from a session the user starts with `claude -slb`, in a
**separate scratch project** (not this repo, which the sandbox can edit)

Phase 6: switch `-sl` to the broker; README + `paths.conf.example`; decide
whether direct mode stays (e.g. `ENABLE_SLURM=direct`) or goes.

## Acceptance tests (from inside a `-slb` sandbox)

Must fail or be refused:
- [ ] `ls /run/munge`, `munge -n` → not there
- [ ] `sbatch --wrap 'touch ~/pwned'` → no `~/pwned` on the host
- [ ] `sbatch --wrap 'cat ~/.ssh/id_*; ls ~/.claude'` → nothing readable
- [ ] `sbatch -o ~/.bashrc --wrap 'echo x'` → `~/.bashrc` untouched
- [ ] `ln -s ~/.bashrc out.log; sbatch -o out.log --wrap 'echo x'` → untouched
- [ ] `-J ../../x -o %x.out` → refused (`/` in the job name)
- [ ] `--export=ALL`, `--get-user-env`, `--container=...`, `--uid=0`, `--part=x` (abbreviation) → refused
- [ ] the same options as `#SBATCH` lines in the script → refused
- [ ] `scancel <job not submitted via sbox>`, `scancel -u $USER` → refused
- [ ] `scontrol update ...`, `scontrol hold ...` → refused; `srun`, `salloc` → refused
- [ ] inside a job: `sbatch`, `squeue` → fail (no munge, no broker)
- [ ] inside a job: `curl https://example.com` → fails
- [ ] interactive: `curl --noproxy '*' https://example.com` fails, via proxy works
- [ ] array `1-1000` without `%` → throttle added; budget exhausted → refused
- [ ] job on a node without bwrap → FAILED, exit 97, payload not executed
- [ ] editing `lib/slurmproxy.py` from the sandbox doesn't change jobs of the running session

Must work:
- [ ] plain job, array with `%N`, dependency chain, `-W`, `--test-only`
- [ ] GPU job sees only its allocated GPU(s)
- [ ] `squeue`, `sacct`, `sinfo`, `scontrol show job` output as usual
- [ ] `scancel` on own sbox jobs (plain and array tasks)
- [ ] launcher errors readable in LOGDIR from the sandbox

## Known limits

- No MPI / multi-node, no interactive jobs, no job steps (`srun` inside a job).
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
