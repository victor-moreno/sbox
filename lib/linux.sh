#!/usr/bin/env bash
# linux.sh — sandbox implementation for Linux (bubblewrap).
# Called by ../aicode or ../sbox with first arg = coder name | "shell".
set -e

CODER="$1"; shift

SANDBOX_DIR="$(pwd -P)"
SBOX_ROOT="${SBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)}"

# load user-editable whitelist
# shellcheck disable=SC1091
. "$SBOX_ROOT/paths.conf"
# per-launch extras from aicode/sbox: -ro/-rw, .paths.local.conf (lib/extra-paths.sh)
while IFS= read -r _p; do [ -n "$_p" ] && RO+=("$_p"); done <<< "${SBOX_RO:-}"
while IFS= read -r _p; do [ -n "$_p" ] && RW+=("$_p"); done <<< "${SBOX_RW:-}"
# `aicode <coder> -sl` sets SBOX_SLURM=broker, `-slurm-no-sandbox` SBOX_SLURM=1
# (direct munge); either wins over paths.conf's value
[ -n "${SBOX_SLURM:-}" ] && ENABLE_SLURM="$SBOX_SLURM"
# missing in paths.conf = no slurm (it used to mean direct munge access)
ENABLE_SLURM="${ENABLE_SLURM:-0}"
# direct mode hands the sandbox munge: say so on every launch
if [ "${ENABLE_SLURM:-0}" = "1" ]; then
  echo "aicode: slurm WITHOUT sandbox (-slurm-no-sandbox / ENABLE_SLURM=1): jobs run unsandboxed with your full access; use -sl for sandboxed jobs" >&2
fi

# ── helper: get newline-delimited coder paths from CODER_RW_<CODER> ──────────
# Config uses uppercase keys (CODER_RW_CLAUDE), coder name is lowercased.
get_coder_paths() {
  local _upper
  _upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  local varname="CODER_RW_$_upper"
  local value="${!varname:-}"
  if [ -n "$value" ]; then
    echo "$value"
  else
    printf '%s\n%s\n' "$HOME/.$1" "$HOME/.$1.json"
  fi
}

# ── conda (optional) ─────────────────────────────────────────────────────────
if [ -z "${CONDA_BASE+x}" ]; then
  if command -v conda &>/dev/null; then
    CONDA_BASE="$(conda info --base 2>/dev/null)"
  else
    CONDA_BASE=""
  fi
fi

CONDA_ENV_NAME=""
CONDA_ENV_PATH=""
if [ -n "$CONDA_BASE" ]; then
  if [ -z "${CONDA_ENV+x}" ]; then
    CONDA_ENV_NAME="${CONDA_DEFAULT_ENV:-}"
  elif [ -d "$CONDA_ENV" ]; then
    CONDA_ENV_NAME="$(basename "$CONDA_ENV")"
  else
    CONDA_ENV_NAME="$CONDA_ENV"
  fi
  if [ -n "$CONDA_ENV_NAME" ]; then
    CONDA_ENV_PATH="$(conda env list 2>/dev/null | awk -v n="$CONDA_ENV_NAME" '$1==n{print $NF; exit}')"
    CONDA_ENV_PATH="${CONDA_ENV_PATH:-$HOME/.conda/envs/$CONDA_ENV_NAME}"
  fi
fi

# ── per-project isolation (if coder is listed in CODER_PROJECT_ISOLATION) ────
# Bind-mounts per-project dirs over ~/.<coder>/projects|session-env|tasks and
# ~/.cache/<coder> so each project has its own conversation history. The rest
# of ~/.<coder> (including credentials) remains the real HOME copy untouched,
# so API auth works normally inside the sandbox.
PROJECT_BWRAP=()
if [ "$CODER" != "shell" ]; then
  for _isolate_coder in $CODER_PROJECT_ISOLATION; do
    if [ "$_isolate_coder" = "$CODER" ]; then
      mkdir -p "$HOME/.$CODER"
      mkdir -p "$SANDBOX_DIR/.$CODER/projects"
      mkdir -p "$SANDBOX_DIR/.$CODER/session-env"
      mkdir -p "$SANDBOX_DIR/.$CODER/tasks"
      mkdir -p "$SANDBOX_DIR/.cache/$CODER"
      [ -f "$HOME/.$CODER.json" ] || echo '{}' > "$HOME/.$CODER.json"
      PROJECT_BWRAP=(
        --bind "$SANDBOX_DIR/.cache/$CODER" "$HOME/.cache/$CODER"
        --bind "$HOME/.$CODER.json" "$HOME/.$CODER.json"
        --bind "$SANDBOX_DIR/.$CODER/projects" "$HOME/.$CODER/projects"
        --bind "$SANDBOX_DIR/.$CODER/session-env" "$HOME/.$CODER/session-env"
        --bind "$SANDBOX_DIR/.$CODER/tasks" "$HOME/.$CODER/tasks"
      )
      break
    fi
  done
fi

# ── coder-specific RW binds from paths.conf CODER_RW ─────────────────────────
# After the isolation block, which may create ~/.<coder> and ~/.<coder>.json
CODER_BWRAP=()
if [ "$CODER" != "shell" ]; then
  while IFS= read -r _p; do
    [ -e "$_p" ] || continue
    CODER_BWRAP+=(--bind "$_p" "$_p")
  done < <(get_coder_paths "$CODER")
fi

# ── shared resources: opt-in per-project via symlink (see SHARED_RW in paths.conf) ─
# Walks the project tree up to a few levels deep (pruning .git/node_modules/.venv,
# since a symlink can live at any depth, e.g. tools/TTS), not just the top level.
# Skipped entirely when SHARED_RW is empty, and depth-capped otherwise, since an
# unbounded walk is slow in projects with many descendants.
if [ "${#SHARED_RW[@]}" -gt 0 ]; then
  while IFS= read -r entry; do
    target="$(readlink -f -- "$entry" 2>/dev/null)" || continue
    for allowed in "${SHARED_RW[@]}"; do
      [ -e "$allowed" ] || continue
      allowed_real="$(readlink -f -- "$allowed" 2>/dev/null)" || continue
      # match the shared path itself or anything under it, since a symlink
      # may point deeper (e.g. jamovi/jamovi-src inside a shared jamovi dir)
      case "$target" in
        "$allowed_real" | "$allowed_real"/*) RW+=("$allowed") ;;
      esac
    done
  done < <(find "$SANDBOX_DIR" -maxdepth 2 \( -name .git -o -name node_modules -o -name .venv \) -prune -o -type l -print 2>/dev/null)
fi

# ── build --dir chain so every parent of SANDBOX_DIR exists inside the tmpfs ─
DIR_CHAIN=()
PART=""
IFS='/' read -ra SEGMENTS <<< "$SANDBOX_DIR"
for SEG in "${SEGMENTS[@]}"; do
  [ -z "$SEG" ] && continue
  PART="$PART/$SEG"
  DIR_CHAIN+=(--dir "$PART")
done

# ── translate paths.conf entries to bwrap binds ──────────────────────────────
USER_BINDS=()
for p in "${RO[@]}"; do
  [ -e "$p" ] || continue
  USER_BINDS+=(--ro-bind "$p" "$p")
done
for p in "${RW[@]}"; do
  [ -e "$p" ] || continue
  USER_BINDS+=(--bind "$p" "$p")
done

# ── conda bwrap args + env ──────────────────────────────────────────────────
CONDA_BWRAP=()
CONDA_ENV_VARS=()
CONDA_PATH_PREFIX=""
if [ -n "$CONDA_BASE" ]; then
  # This ro-bind runs after USER_BINDS/CODER_BWRAP, and --ro-bind recursively
  # remounts read-only, so any RW path added later under $HOME/.conda (e.g.
  # via paths.conf's RW array) would get silently clamped back to read-only
  # — same ordering hazard as the SANDBOX_DIR bind below.
  [ -d "$HOME/.conda" ] && CONDA_BWRAP+=(--ro-bind "$HOME/.conda" "$HOME/.conda")
  CONDA_ENV_VARS=(
    CONDA_EXE="$CONDA_BASE/bin/conda"
    CONDA_PYTHON_EXE="$CONDA_BASE/bin/python"
  )
  CONDA_PATH_PREFIX="${CONDA_ENV_PATH:+$CONDA_ENV_PATH/bin:}$CONDA_BASE/condabin:"
fi

# ── network filter: netproxy runs outside the sandbox ────────────────────────
# Allowlist = NET_ALLOW (paths.conf) + net-allow.conf ("Always allow" answers);
# other hosts pop a zenity dialog if there is a display, else are refused.
# --unshare-net leaves the sandbox only its own loopback: netproxy listens on
# a unix socket bound into /run/sbox-net and a forwarder inside the sandbox
# (started from the rc file) bridges 127.0.0.1:3128 to it. Slurm reaches
# slurmctld over plain TCP, which a private namespace would cut, so with slurm
# enabled the proxy is advisory: *_PROXY is set, direct connections still work.
NET_BWRAP=()
NET_ENV=()
NET_FORWARD=0
if [ "${NET_FILTER:-1}" = "1" ]; then
  NETDIR="$(mktemp -d /tmp/sbox-net-XXXXXX)"
  _netlog="$HOME/.local/state/sbox/net.log"
  mkdir -p "$(dirname "$_netlog")"
  touch "$SBOX_ROOT/net-allow.conf"
  _net_args=(serve --watch-pid $$ --cleanup "$NETDIR" --project "$SANDBOX_DIR"
    --log "$_netlog" --always-file "$SBOX_ROOT/net-allow.conf"
    --hint "Allow it outside the sandbox: add it to NET_ALLOW in $SBOX_ROOT/paths.conf or to $SBOX_ROOT/net-allow.conf")
  for _h in "${NET_ALLOW[@]+"${NET_ALLOW[@]}"}"; do _net_args+=(--allow="$_h"); done
  if [ "${ENABLE_SLURM:-0}" = "1" ]; then
    echo "aicode: slurm without sandbox, network filter is advisory only (direct connections not blocked)" >&2
    python3 "$SBOX_ROOT/lib/netproxy.py" "${_net_args[@]}" --port-file "$NETDIR/port" \
      </dev/null >/dev/null 2>>"$_netlog" &
    for _i in $(seq 50); do [ -s "$NETDIR/port" ] && break; sleep 0.1; done
    [ -s "$NETDIR/port" ] || { echo "aicode: netproxy did not start, see $_netlog" >&2; exit 1; }
    _proxy="http://127.0.0.1:$(cat "$NETDIR/port")"
  else
    python3 "$SBOX_ROOT/lib/netproxy.py" "${_net_args[@]}" --unix "$NETDIR/proxy.sock" \
      </dev/null >/dev/null 2>>"$_netlog" &
    for _i in $(seq 50); do [ -S "$NETDIR/proxy.sock" ] && break; sleep 0.1; done
    [ -S "$NETDIR/proxy.sock" ] || { echo "aicode: netproxy did not start, see $_netlog" >&2; exit 1; }
    NET_BWRAP=(
      --unshare-net
      --bind "$NETDIR" /run/sbox-net
      --ro-bind "$SBOX_ROOT/lib/netproxy.py" /run/sbox-netproxy.py
    )
    NET_FORWARD=1
    _proxy="http://127.0.0.1:3128"
    # -local on the host's loopback: the private namespace can't see it, and
    # NO_PROXY keeps claude off netproxy for localhost, so bridge just that
    # port (relay here, forward in the rc file) at the same address inside
    if [ -n "${SBOX_LOCAL:-}" ]; then
      _llm_hp="${ANTHROPIC_BASE_URL#*://}"; _llm_hp="${_llm_hp%%/*}"
      case "${_llm_hp%:*}" in
        localhost|127.0.0.1)
          LLM_PORT="${_llm_hp##*:}"
          [ "$LLM_PORT" = "$_llm_hp" ] && LLM_PORT=80
          python3 "$SBOX_ROOT/lib/netproxy.py" relay --unix "$NETDIR/llm.sock" \
            --connect "127.0.0.1:$LLM_PORT" --watch-pid $$ \
            </dev/null >/dev/null 2>>"$_netlog" &
          for _i in $(seq 50); do [ -S "$NETDIR/llm.sock" ] && break; sleep 0.1; done
          [ -S "$NETDIR/llm.sock" ] || { echo "aicode: -local relay did not start, see $_netlog" >&2; exit 1; }
          ;;
      esac
    fi
  fi
  NET_ENV=(
    HTTP_PROXY="$_proxy" HTTPS_PROXY="$_proxy" ALL_PROXY="$_proxy"
    http_proxy="$_proxy" https_proxy="$_proxy" all_proxy="$_proxy"
    NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
    # node >= 24 ignores *_PROXY unless asked
    NODE_USE_ENV_PROXY=1
  )
fi

# ── ssh (SSH_DIR in paths.conf) ─────────────────────────────────────────────
# The sandbox home is a fresh tmpfs, so ssh finds no ~/.ssh at all: no key, no
# config, no known_hosts. Expose SSH_DIR read-only at its own path (the user's
# config refers to its files by absolute path) and generate the ~/.ssh/config
# ssh actually reads. It includes the real config first, so per-host settings
# there win, then adds a global ProxyCommand: with --unshare-net the proxy is
# the only way out, and it is also the only resolver (the private namespace
# has no DNS). Without the filter, or in slurm mode, connections are direct.
SSH_BWRAP=()
if [ -n "${SSH_DIR:-}" ] && [ -d "$SSH_DIR" ]; then
  SSH_TMP="$(mktemp -d /tmp/sbox-ssh-XXXXXX)"
  : > "$SSH_TMP/config"
  # ssh rejects a group- or world-writable config, which the default umask gives
  chmod 600 "$SSH_TMP/config"
  if [ -f "$SSH_DIR/config" ]; then
    printf 'Include %s/config\n' "$SSH_DIR" >> "$SSH_TMP/config"
  fi
  if [ "$NET_FORWARD" = "1" ]; then
    printf 'Host *\n  ProxyCommand python3 /run/sbox-netproxy.py connect --unix /run/sbox-net/proxy.sock %%h %%p\n' \
      >> "$SSH_TMP/config"
  fi
  # bwrap maps only our own uid, so every root-owned file shows up as nobody
  # and ssh refuses to read /etc/ssh/ssh_config{,.d/*} ("Bad owner or
  # permissions") — which kills it before it reads anything else. Shadow the
  # system config with an empty file we own; ours is the per-user one.
  : > "$SSH_TMP/empty"
  SSH_BWRAP=(
    --ro-bind "$SSH_DIR" "$SSH_DIR"
    --ro-bind "$SSH_TMP/config" "$HOME/.ssh/config"
    --ro-bind "$SSH_TMP/empty" /etc/ssh/ssh_config
  )
fi

# ── rc file (shared by both modes) ──────────────────────────────────────────
RC_FILE="$(mktemp /tmp/sbox-rc-XXXXXX)"
{
  echo 'export PS1="[sandbox:\w]\$ "'
  if [ -n "$CONDA_BASE" ]; then
    printf 'source "%s/etc/profile.d/conda.sh"\n' "$CONDA_BASE"
    [ -n "$CONDA_ENV_NAME" ] && printf 'conda activate "%s" 2>/dev/null || true\n' "$CONDA_ENV_NAME"
  fi
  if [ -n "${SANDBOX_HISTFILE:-}" ]; then
    printf 'HISTFILE="%s"\nHISTSIZE=1000\n' "$SANDBOX_HISTFILE"
  fi
  cat <<'RCEOF'
alias ll='ls -la'
RCEOF
  # Lmod: env -i drops what the login shell set up (module, MODULEPATH,
  # BASH_ENV); re-run the site init. It exports the module function and
  # BASH_ENV, so the coder's own bash subshells get `module` too.
  if [ -f /etc/profile.d/lmod.sh ]; then
    echo '. /etc/profile.d/lmod.sh >/dev/null 2>&1 || true'
  fi
  if [ "$NET_FORWARD" = "1" ]; then
    # bridge the private loopback to netproxy; ( & ) keeps it out of job control
    cat <<'RCEOF'
if ! (exec 3<>/dev/tcp/127.0.0.1/3128) 2>/dev/null; then
  ( python3 /run/sbox-netproxy.py forward --listen 3128 --unix /run/sbox-net/proxy.sock >/dev/null 2>&1 & )
  for _i in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
fi
RCEOF
  fi
  if [ -n "${LLM_PORT:-}" ]; then
    printf 'if ! (exec 3<>/dev/tcp/127.0.0.1/%s) 2>/dev/null; then\n' "$LLM_PORT"
    printf '  ( python3 /run/sbox-netproxy.py forward --listen %s --unix /run/sbox-net/llm.sock >/dev/null 2>&1 & )\n' "$LLM_PORT"
    printf '  for _i in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/%s) 2>/dev/null && break; sleep 0.1; done\nfi\n' "$LLM_PORT"
  fi
  if [ "$CODER" = "shell" ]; then
    cat <<'RCEOF'
echo ""
echo "  [sandbox] $(pwd)"
if [ -n "$CONDA_DEFAULT_ENV" ]; then
  echo "  conda env: $CONDA_DEFAULT_ENV  |  python: $(which python)"
else
  echo "  python: $(which python 2>/dev/null || echo 'not in PATH')"
fi
echo "  type 'exit' to leave"
echo ""
RCEOF
  fi
} > "$RC_FILE"

trap 'rm -rf "$RC_FILE" "${SSH_TMP:-}"' EXIT INT TERM

# ── bwrap mount layout ───────────────────────────────────────────────────────
# bwrap_fs <interactive|job> sets FS: the filesystem view, shared with the
# slurm jobs of broker mode so the two can't drift apart. Jobs (SLURM.md,
# "Job layout") get the same paths minus agent config, ssh and the terminal,
# with -try binds since a compute node may lack some paths.conf entries.
bwrap_fs() {
  FS=(
    --tmpfs /
    "${DIR_CHAIN[@]}"
    --ro-bind /usr /usr
    --ro-bind /etc /etc
    --symlink usr/bin /bin
    --symlink usr/lib /lib
    --symlink usr/lib64 /lib64
    --symlink usr/sbin /sbin
    --ro-bind /opt /opt
    --dir "$HOME"
  )
  if [ "$1" = job ]; then
    for _p in "${RO[@]}"; do FS+=(--ro-bind-try "$_p" "$_p"); done
    for _p in "${RW[@]}"; do FS+=(--bind-try "$_p" "$_p"); done
    [ "${#CONDA_BWRAP[@]}" -gt 0 ] && FS+=(--ro-bind-try "$HOME/.conda" "$HOME/.conda")
  else
    FS+=(
      "${USER_BINDS[@]}"
      "${CODER_BWRAP[@]}"
      "${CONDA_BWRAP[@]}"
      "${PROJECT_BWRAP[@]}"
      # after the coder binds: SSH_DIR stays read-only even when it sits inside a
      # coder's RW config dir (e.g. ~/.claude/.ssh), so the key can't be rewritten
      "${SSH_BWRAP[@]}"
    )
  fi
  FS+=(--proc /proc)

  # Minimal /dev — only essential devices instead of full /dev exposure
  FS+=(--dir /dev)
  # The /proc-backed links every real /dev has, which a bare --dir /dev lacks:
  # without /dev/fd, bash process substitution (`cmd <(cmd)`) fails inside the
  # sandbox. They expose nothing new — /proc is already mounted.
  FS+=(
    --symlink /proc/self/fd /dev/fd
    --symlink /proc/self/fd/0 /dev/stdin
    --symlink /proc/self/fd/1 /dev/stdout
    --symlink /proc/self/fd/2 /dev/stderr
  )
  # batch jobs have no terminal
  [ "$1" != job ] && [ -d /dev/pts ] && FS+=(--bind /dev/pts /dev/pts)
  for _d in /dev/null /dev/zero /dev/random /dev/urandom /dev/tty; do
    [ "$1" = job ] && [ "$_d" = /dev/tty ] && continue
    # --dev-bind (not --bind) required for char devices: --bind sets MS_NODEV
    # which blocks device file access on older kernels (e.g. 4.18).
    [ -e "$_d" ] && FS+=(--dev-bind "$_d" "$_d")
  done
  return 0
}

bwrap_fs interactive
BWRAP_BASE=(
  # Without this, the sandbox shares the host PID namespace: every host
  # process is visible under /proc (leaking other processes' cmdlines) and
  # signalable (e.g. kill -0 succeeds against host PIDs owned by this user).
  --unshare-pid
  "${FS[@]}"
)

# NVIDIA/CUDA (toggled by ENABLE_GPU in paths.conf, and only when the host
# has the devices): the char devices plus
# /sys/module/nvidia, which the tmpfs root hides — NVML reads
# /sys/module/nvidia/initstate and otherwise fails with "GPU access blocked
# by the operating system" even with the devices bound. /dev/shm is needed by
# torch dataloader workers and NCCL, and /dev is a bare --dir here.
GPU_BWRAP=()
if [ "${ENABLE_GPU:-1}" = "1" ]; then
  for _d in /dev/nvidia*; do
    [ -e "$_d" ] && GPU_BWRAP+=(--dev-bind "$_d" "$_d")
  done
fi
if [ "${#GPU_BWRAP[@]}" -gt 0 ] && [ -d /sys/module/nvidia ]; then
  BWRAP_BASE+=(
    "${GPU_BWRAP[@]}"
    --tmpfs /dev/shm
    --dir /sys
    --ro-bind /sys/module /sys/module
  )
fi

BWRAP_BASE+=(
  --tmpfs /tmp
  --tmpfs /run
)

# Slurm/munge (optional, toggled by ENABLE_SLURM in paths.conf): sbatch reads
# configless config from /run/slurm/conf and authenticates via the munge
# socket at /var/run/munge (a symlink to /run on the host). Both live under
# /run, which is a private empty tmpfs above — bind them back in, and
# recreate the /var/run -> /run symlink, so job submission works the same as
# outside the sandbox. sbatch itself is still on PATH either way (it's just
# /usr/bin/sbatch, always ro-bound); this only blocks it from reaching a
# working slurm/munge config, so it fails instead of submitting.
if [ "${ENABLE_SLURM:-0}" = "1" ]; then
  [ -d /run/slurm/conf ] && BWRAP_BASE+=(--ro-bind /run/slurm/conf /run/slurm/conf)
  if [ -d /run/munge ]; then
    BWRAP_BASE+=(
      --ro-bind /run/munge /run/munge
      --dir /var
      --symlink /run /var/run
    )
  fi
fi

# after --tmpfs /run, which would hide these mounts
BWRAP_BASE+=("${NET_BWRAP[@]+"${NET_BWRAP[@]}"}")

# also the tail of the job layout (broker mode)
PROJECT_TAIL=(
  # SANDBOX_DIR bound last (after /tmp and /run are remounted, and after every
  # other bind above) so it always wins RW: bwrap remounts recursively, so an
  # earlier SANDBOX_DIR bind would get shadowed back by a later mount over
  # one of its ancestors — an RO path from paths.conf (e.g. this repo lives
  # under $HOME/bin, which is RO), or the private tmpfs /tmp above when a
  # project dir sits under /tmp.
  --bind "$SANDBOX_DIR" "$SANDBOX_DIR"
  # the allowlists stay read-only even when the project is sbox itself
  --ro-bind-try "$SBOX_ROOT/paths.conf" "$SBOX_ROOT/paths.conf"
  --ro-bind-try "$SBOX_ROOT/net-allow.conf" "$SBOX_ROOT/net-allow.conf"
  # same for .paths.local.conf approvals, or a coder could approve its own edits
  --ro-bind-try "$SBOX_APPROVED" "$SBOX_APPROVED"
)
BWRAP_BASE+=(
  "${PROJECT_TAIL[@]}"
  # Bound after SANDBOX_DIR so this stays visible even in the edge case where
  # SANDBOX_DIR is /tmp itself (which would otherwise shadow it).
  --bind "$RC_FILE" /tmp/sandbox-rc
  --chdir "$SANDBOX_DIR"
  --die-with-parent
)

# ── env passed to the sandboxed process ──────────────────────────────────────
CODER_ENV=()

# Forward CLAUDE_CONFIG_DIR (e.g. from the claudeUB alias) — env -i below
# wipes the outer environment, so without this the sandboxed claude always
# falls back to ~/.claude regardless of what the caller set.
if [ "$CODER" = "claude" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CODER_ENV+=(CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR")
fi

# env -i also drops the GPU allocation of an enclosing slurm job / manual
# selection, which would let the sandbox see every GPU on the node
[ -n "${CUDA_VISIBLE_DEVICES:-}" ] && CODER_ENV+=(CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES")

# Coder tunnel: read from paths.conf CODER_TUNNEL_<CODER> (uppercase key)
_tunnel_upper="$(printf '%s' "$CODER" | tr '[:lower:]' '[:upper:]')"
_tunnel_var="CODER_TUNNEL_${_tunnel_upper}"
_tunnel_config="${!_tunnel_var:-}"
# -local supplies its own ANTHROPIC_BASE_URL; env -i would drop it and every
# other var lib/local-llm.sh exported, so pass them on explicitly
if [ -n "${SBOX_LOCAL:-}" ]; then
  _tunnel_config=""
  for _v in SBOX_LOCAL ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL \
      ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
      ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
      CLAUDE_CODE_MAX_CONTEXT_TOKENS CLAUDE_CODE_EFFORT_LEVEL \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC; do
    [ -n "${!_v:-}" ] && CODER_ENV+=("$_v=${!_v}")
  done
fi
if [ -n "$_tunnel_config" ]; then
  _tunnel_host="${_tunnel_config%%=*}"
  _tunnel_url="${_tunnel_config#*=}"
  if [ "$(hostname)" = "$_tunnel_host" ]; then
    CODER_ENV+=(ANTHROPIC_BASE_URL="$_tunnel_url")
  fi
fi

_extra_path=""
for _p in "${PATH_EXTRA[@]+"${PATH_EXTRA[@]}"}"; do
  _extra_path="${_extra_path}${_p}:"
done

ENV_BASE=(
  HOME="$HOME"
  USER="$(whoami)"
  LOGNAME="$(whoami)"
  SHELL=/usr/bin/bash
  TERM="${TERM:-xterm-256color}"
  LANG="C.UTF-8"
  LC_ALL="C.UTF-8"
  TMPDIR=/tmp
  SANDBOX_DIR="$SANDBOX_DIR"
  "${CODER_ENV[@]}"
  "${CONDA_ENV_VARS[@]}"
  "${NET_ENV[@]+"${NET_ENV[@]}"}"
  PATH="${_extra_path}${CONDA_PATH_PREFIX}/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin"
  DISABLE_TELEMETRY="1"
  DISABLE_ERROR_REPORTING="1" 
)

# ── slurm broker (ENABLE_SLURM=broker, design in SLURM.md) ───────────────────
# The sandbox never gets munge: sbatch & co are shims (lib/slurmproxy.py
# bound over each client) talking over a unix socket to the broker outside,
# which submits each script wrapped in bwrap with the job layout below. Only
# the socket's dir is bound in; the layout/env snapshots and the temp
# launchers stay out of reach, so they can't be swapped before sbatch reads
# them. The network takes the strict branch above, as without slurm.
if [ "${ENABLE_SLURM:-0}" = "broker" ]; then
  _state="$HOME/.local/state/sbox"
  # Slurm's own -o/-e (launcher messages) go here, never into the project:
  # slurmstepd opens them on the host before bwrap and follows symlinks
  _logdir="$_state/slurm/logs/$(basename "$SANDBOX_DIR")-$(printf '%s' "$SANDBOX_DIR" | sha256sum | cut -c1-8)"
  mkdir -p "$_logdir"
  # after the mkdir above, so a failure there leaves no temp dir behind
  SLURMDIR="$(mktemp -d /tmp/sbox-slurm-XXXXXX)"
  mkdir "$SLURMDIR/sock" "$SLURMDIR/launch"
  bwrap_fs job
  printf '%s\0' --unshare-pid --unshare-net --new-session --die-with-parent \
    "${FS[@]}" --tmpfs /run "${PROJECT_TAIL[@]}" > "$SLURMDIR/layout"
  # no proxy, coder or terminal vars: jobs have no network and no agent
  _job_env=(SBOX_JOB=1)
  for _e in "${ENV_BASE[@]}"; do
    case "${_e%%=*}" in
      HOME|USER|LOGNAME|SHELL|LANG|LC_ALL|TMPDIR|SANDBOX_DIR|PATH|CONDA_EXE|CONDA_PYTHON_EXE|DISABLE_*)
        _job_env+=("$_e") ;;
    esac
  done
  printf '%s\0' "${_job_env[@]}" > "$SLURMDIR/env"
  _sl_args=(serve --unix "$SLURMDIR/sock/sock" --layout "$SLURMDIR/layout" --env "$SLURMDIR/env"
    --inner "$SBOX_ROOT/lib/slurm-inner.sh" --project "$SANDBOX_DIR" --logdir "$_logdir"
    --statedir "$SLURMDIR/launch" --ledger "$_state/slurm/ledger.json"
    --exclude "${SLURM_EXCLUDE:-}" --constraint "${SLURM_CONSTRAINT:-}"
    --max-running "${SLURM_MAX_RUNNING:-20}"
    --watch-pid $$ --cleanup "$SLURMDIR")
  _bw="$(command -v bwrap)" && _sl_args+=(--bwrap "$_bw")
  [ "${ENABLE_GPU:-1}" = "1" ] && _sl_args+=(--gpu)
  python3 "$SBOX_ROOT/lib/slurmproxy.py" "${_sl_args[@]}" \
    </dev/null >/dev/null 2>>"$_state/slurm/broker.log" &
  for _i in $(seq 50); do [ -S "$SLURMDIR/sock/sock" ] && break; sleep 0.1; done
  [ -S "$SLURMDIR/sock/sock" ] || { rm -rf "$SLURMDIR"; echo "aicode: slurm broker did not start, see $_state/slurm/broker.log" >&2; exit 1; }
  BWRAP_BASE+=(
    --bind "$SLURMDIR/sock" /run/sbox-slurm
    # after USER_BINDS (later binds win): ledger and logs stay read-only even
    # if paths.conf makes ~/.local RW; the logs are readable for launcher errors
    --ro-bind "$_state" "$_state"
  )
  for _c in sbatch scancel scontrol squeue sinfo sacct sstat sprio sshare srun salloc; do
    _p="$(command -v "$_c")" && BWRAP_BASE+=(--ro-bind "$SBOX_ROOT/lib/slurmproxy.py" "$_p")
  done
fi

# ── exec ─────────────────────────────────────────────────────────────────────
if [ "$CODER" != "shell" ]; then
  # Write a wrapper script to avoid injecting CODER into bash -c string
  WRAPPER="$(mktemp /tmp/sbox-wrap-XXXXXX)"
  # Unquoted heredoc expands $CODER now (validated name, safe), but $@ must
  # reach the wrapper verbatim or it expands here and all extra args bake
  # into one word (observed: aicode hermes --model x --message y collapsed).
  cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
source /tmp/sandbox-rc
exec "$CODER" "\$@"
WRAPEOF
  chmod +x "$WRAPPER"
  trap 'rm -rf "$RC_FILE" "${SSH_TMP:-}" "$WRAPPER"' EXIT INT TERM

  # /tmp is a fresh tmpfs inside the sandbox, so the wrapper must be bound in
  BWRAP_BASE+=(--ro-bind "$WRAPPER" /tmp/sandbox-wrap)
  exec bwrap "${BWRAP_BASE[@]}" /usr/bin/env -i "${ENV_BASE[@]}" \
    /tmp/sandbox-wrap "$@"
fi

exec bwrap "${BWRAP_BASE[@]}" /usr/bin/env -i "${ENV_BASE[@]}" \
  /usr/bin/bash --rcfile /tmp/sandbox-rc
