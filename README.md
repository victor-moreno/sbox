# sbox

Sandbox scripts for Linux (bubblewrap) and macOS (sandbox-exec, arm & x64).
Run a coding assistant isolated to the current directory.

```
DIR=/path/to/sbox

alias aicode='$DIR/aicode'   # starts a coder inside a sandbox
alias sbox='$DIR/sbox'       # starts a sandboxed shell
alias claude='$DIR/claude'   # backward compat: same as `aicode claude`
alias claude-share='$DIR/claude-share'  # share ~/.claude with ~/.claudeUB
```

```
# Usage
aicode claude        # Claude Code in a sandbox
aicode hermes        # Hermes Agent in a sandbox
aicode <any-cmd>     # any command on PATH or in homebrew
claude -sl -c        # slurm via the broker for this launch (Linux): jobs run
                     # sandboxed, see SLURM.md; other args go to claude
claude -slurm        # direct slurm/munge access (unsandboxed jobs, advisory
                     # network filter); both override ENABLE_SLURM
claude -local        # use a model served at localhost:8000 instead of the
                     # API; fails if nothing is serving
claude -docker       # docker via a colima VM that mounts only this folder
                     # (macOS, see Docker below)
sbox                 # interactive sandboxed shell
```

## Two Claude accounts on one computer

Each account gets its own config dir, selected with `CLAUDE_CONFIG_DIR`:
`~/.claude` (default account) and `~/.claudeUB` (second account). Log in once
in each with `/login`.

1. Give the sandbox RW access to the second dir in `paths.conf`
   (and RO to its `CLAUDE.md`, like the default one; already in
   `paths.conf.example`):

```
CODER_RW_CLAUDE="$(printf '%s\n%s\n' "$HOME/.claude" "$HOME/.claude.json" "$HOME/.claudeUB")"
RO=( ... "$HOME/.claude/CLAUDE.md" "$HOME/.claudeUB/CLAUDE.md" ... )
```

2. Share everything except the login between both accounts:

```
claude-share             # symlinks each entry of ~/.claude into ~/.claudeUB
```

   History, projects, settings, skills, plugins, hooks and `CLAUDE.md` become
   common. Kept per account: `.credentials.json`, `.claude.json` (+ `backups`),
   `policy-limits.json`, `remote-settings.json`. Real files already in
   `~/.claudeUB` are moved to `<name>.pre-share.bak`. Re-run it after Claude
   adds new entries to `~/.claude`.

3. Add the aliases to `~/.bashrc` / `~/.zshrc`. Minimal version, one alias
   per account (the default account needs no variable):

```
alias claude='$HOME/bin/sbox/claude'
alias claudeUB='CLAUDE_CONFIG_DIR=$HOME/.claudeUB $HOME/bin/sbox/claude'
```

4. Optional: run each launch in a tmux session, so it survives a closed
   terminal or ssh disconnect. Needs `tmux`; where it isn't installed and you
   have no admin rights (e.g. a cluster), a conda environment works:
   `conda create -n tmux -c conda-forge tmux`, then add its `bin` to `PATH`.
   These functions replace the aliases above; each opens (or re-attaches to)
   a tmux session running the sandboxed claude with the chosen account:

```bash
claude() {
  local name
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    name="$1"; shift
  else
    name="$(basename "$PWD")"
  fi
  local args=""
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  if [ -n "$TMUX" ]; then
    # already inside tmux: nesting is refused, so create detached and switch to it
    name="${name//[.:]/_}"  # tmux rewrites . and : in session names
    tmux has-session -t "=$name" 2>/dev/null || tmux new-session -d -s "$name" -n claude "CLAUDE_CONFIG_DIR=\"\$HOME/.claude\" \$HOME/bin/sbox/claude$args"
    # on exit, return to the calling session: the default detach closes the terminal
    tmux set-option -t "=$name" detach-on-destroy off
    tmux switch-client -t "=$name"
  else
    tmux new-session -A -s "$name" -n claude "CLAUDE_CONFIG_DIR=\"\$HOME/.claude\" \$HOME/bin/sbox/claude$args"
  fi
}

claudeUB() {
  local name
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    name="$1"; shift
  else
    name="$(basename "$PWD")"
  fi
  local args=""
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  if [ -n "$TMUX" ]; then
    # already inside tmux: nesting is refused, so create detached and switch to it
    name="${name//[.:]/_}"  # tmux rewrites . and : in session names
    tmux has-session -t "=$name" 2>/dev/null || tmux new-session -d -s "$name" -n claudeUB "CLAUDE_CONFIG_DIR=\"\$HOME/.claudeUB\" \$HOME/bin/sbox/claude$args"
    # on exit, return to the calling session: the default detach closes the terminal
    tmux set-option -t "=$name" detach-on-destroy off
    tmux switch-client -t "=$name"
  else
    tmux new-session -A -s "$name" -n claudeUB "CLAUDE_CONFIG_DIR=\"\$HOME/.claudeUB\" \$HOME/bin/sbox/claude$args"
  fi
}
```

```
# Usage (tmux functions)
claude                 # default account, tmux session named after the folder
claudeUB               # second account, same naming
claude work -c         # session "work", extra args (-c) passed to claude
claudeUB --resume      # args starting with "-" keep the folder name as session
```

   With the tmux functions:
   - The first argument, if it does not start with `-`, is the tmux session
     name, not a prompt. `claude "fix the bug"` names a session; use
     `claude main "fix the bug"` to pass a prompt.
   - Session names don't include the account, by design: one tmux session per
     folder. `tmux new-session -A` attaches if the session exists, so whichever
     account started it keeps running; the other function just re-attaches.
     Give an explicit name to run both accounts side by side.

## VS Code extension

The Claude Code extension normally runs its own bundled binary, unsandboxed.
Point it at `claude-vscode` in VS Code **User** settings (the setting is
machine-scoped, so workspace settings ignore it):

```json
"claudeCode.claudeProcessWrapper": "/Users/<you>/bin/sbox/claude-vscode"
```

Each chat panel then runs the brew `claude` through `aicode`, sandboxed to the
workspace folder plus `paths.conf`. For the second account, also set
`"claudeCode.environmentVariables": [{"name": "CLAUDE_CONFIG_DIR", "value": "/Users/<you>/.claudeUB"}]`.

Notes:
- Linux: `env -i` clears the environment inside bubblewrap, so `lib/linux.sh`
  forwards `CLAUDE_CONFIG_DIR` explicitly. Per-project history isolation
  (`CODER_PROJECT_ISOLATION`) bind-mounts over `~/.claude/projects`,
  `session-env` and `tasks`; after `claude-share` those are symlinks from
  `~/.claudeUB`, so both accounts get the same per-project history.

```
paths.conf   define which paths the sandbox gets RO or RW
             CODER_RW_<coder> variables map coder → config dirs (RW)
             SHARED_RW lists RW paths that are opt-in per project: a project
             only gets one if it contains a symlink resolving to it
             CODER_PROJECT_ISOLATION sets coders with per-project history
             NET_FILTER / NET_ALLOW configure the network filter
             no changes to lib/* needed for new coders
net-allow.conf  "Always allow" answers from the network dialog (local, editable)
```

## Network filter

With `NET_FILTER=1` (the default), the sandbox reaches the internet only
through `lib/netproxy.py`, a small HTTP proxy that runs outside the sandbox
and is started by each `aicode`/`sbox` launch (`HTTP(S)_PROXY` point at it).

- Hosts in `NET_ALLOW` (paths.conf) or `net-allow.conf` connect directly.
- Any other host opens a dialog: **Deny**, **Allow** (this session) or
  **Always allow** (appended to `net-allow.conf`). No answer in 60 s, or no
  display (SSH session, headless Linux), means deny; the 403 tells the coder
  which file to edit. Both files are read-only inside the sandbox and
  re-read live.
- Linux without a display (ssh, cluster): if the coder was launched inside
  tmux, the question opens as a tmux popup over its screen instead:
  `a` Allow, `A` Always allow, any other key Deny (keys typed in the first
  0.6 s are ignored, so typing meant for the coder can't answer it). Launched
  outside tmux, it is still a 403.
- Patterns: `host`, `*.host` (subdomains), `host:port` (that port only, e.g.
  `10.10.0.2:22`), `!host` (deny, don't ask).
- HTTPS is tunnelled, not decrypted, so allowing a host allows any traffic
  to it, uploads included.
- Enforcement: on macOS, Seatbelt blocks every outbound connection except
  localhost, unix sockets outside the project, and DNS lookups. On Linux,
  bwrap gets `--unshare-net`, and a forwarder inside the sandbox links
  `127.0.0.1:3128` to the proxy socket. With `-local`, the model server's
  localhost port is bridged the same way (and only that port). With direct slurm (`-slurm`), Linux keeps the
  host network (slurmctld needs direct TCP), so only tools that honour
  `*_PROXY` are filtered.
- Tools that ignore `*_PROXY` get no network (raw sockets, some node apps).
  `ssh` is the exception: see below.
- Log: `~/.local/state/sbox/net.log` (one line per host and session, plus
  every refusal).

## ssh (Linux)

The sandbox home is a fresh tmpfs, so there is no `~/.ssh` in it unless
`SSH_DIR` is set in paths.conf. That directory is bound read-only both at its
own path and as `~/.ssh`, so its config, keys and `known_hosts` are what `ssh`
and `git` use — read-only, so the coder can use the key but can't rewrite it
or add host keys.

`~/.ssh/config` inside the sandbox is generated per launch: it `Include`s the
real config first (per-host settings there win) and then adds a global
`ProxyCommand` that tunnels through netproxy (`netproxy.py connect`), since
with `--unshare-net` the proxy is both the only route out and the only
resolver. The target host therefore needs to be in `NET_ALLOW` /
`net-allow.conf` like any other, and it is logged the same way
(`git.iconcologia.net:22`). Without the filter, or with direct slurm (`-slurm`),
connections are direct and no `ProxyCommand` is added.

`/etc/ssh/ssh_config` is shadowed with an empty file at the same time: bwrap
maps only your own uid, so root-owned files look like `nobody` inside and ssh
would abort with "Bad owner or permissions" before reading anything else.

On macOS no config is generated; ssh to an allowed host goes through the proxy
by hand:
`ssh -o ProxyCommand='nc -X connect -x ${HTTPS_PROXY#http://} %h %p' 10.10.0.2`

- GPU: with `ENABLE_GPU=1` (paths.conf, Linux) the `/dev/nvidia*` devices,
  `/sys/module` (read-only) and a `/dev/shm` tmpfs are bound in when the host
  has NVIDIA devices, so CUDA works inside the sandbox; `CUDA_VISIBLE_DEVICES`
  is forwarded. `ENABLE_GPU=0` hides the GPUs.

## Docker (macOS)

`aicode <coder> -docker` (`SBOX_DOCKER=1` for `sbox` or the VS Code wrapper)
gives the sandbox a docker daemon that only sees the project folder.

- A container is root in its VM, so what the VM mounts is the real
  boundary. OrbStack (whole Mac filesystem), your own colima (`~`) and lima
  (`~`) would undo the sandbox: sockets under `~/.orbstack`, `~/.colima` and
  `~/.lima` are denied, also with `NET_FILTER=0` (`/var/run/docker.sock`
  may point into `~/.orbstack`). They keep working outside the sandbox.
- Two VMs: yours (e.g. colima's `default` profile, mounting `~`) and colima
  profile `sbox`, shared by all sandboxed projects. Images can't be shared
  between two VMs, so an image used on both sides is stored twice, not once
  per project. Copy it instead of pulling it again:
  `docker save IMG | DOCKER_HOST=unix://$HOME/.colima/sbox/docker.sock docker load`
- `-docker` starts `sbox`, outside the sandbox, with the project as its only
  mount (rw, same path, virtiofs) and sets `DOCKER_HOST` to its socket.
  virtiofs is pinned because with sshfs a root guest can read any host
  file; it needs vz (macOS 13+), so older Intel Macs fail to start (qemu
  would need 9p). The sandbox gets that socket only, never `~/.colima`, so
  it can't change the mounts; don't add `~/.colima` to `paths.conf`.
  `docker run -v "$PWD:/w"` works; other host paths (symlinked `SHARED_RW`
  dirs too) appear empty in containers.
- One project at a time: `-docker` in another project restarts `sbox` with
  that mount (about 20 s, its running containers stop). While a `-docker`
  session of a different project is still open it starts without docker
  instead, with a message at launch and again at exit. Sessions are
  tracked in `~/.colima/sbox/sessions`.
- The VM keeps running after the session: `colima stop -p sbox`. Size: colima
  defaults (2 CPUs, 2 GB) unless your colima template says otherwise.
- `~/.docker` stays hidden (credentials): each session gets a temporary
  `DOCKER_CONFIG` linking the CLI plugins (compose, buildx, from
  `~/.docker/cli-plugins` or Homebrew), so a `docker login` inside lasts one
  session.
- The VM has its own network: containers bypass the network filter.
- Linux: `-docker` is ignored.

```
sandbox method:
  linux:  bwrap (bubblewrap)
  macos:  sandbox-exec; writes are allowlisted everywhere (project, paths.conf
          RW, temp dirs), so /usr/local, /Applications, /Volumes stay
          read-only or hidden; Apple Events are denied (no osascript
          control of Terminal, VS Code, Finder)
```
