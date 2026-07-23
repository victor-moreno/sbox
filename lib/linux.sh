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

# ── workspace pre-trust ──────────────────────────────────────────────────────
# Pi stores project trust decisions in ~/.pi/agent/trust.json keyed by the
# canonical project path. Since the sandbox itself is the trust boundary here,
# auto-trust the sandboxed working directory so pi can load project-local .pi
# resources without prompting on every first launch inside a new folder.
if [ "$CODER" = "pi" ] && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$HOME/.pi/agent"
  python3 - "$HOME/.pi/agent/trust.json" "$SANDBOX_DIR" <<'PY'
import json, os, sys
cfg, proj = sys.argv[1], sys.argv[2]
proj = os.path.realpath(proj)
try:
    with open(cfg) as f: d = json.load(f)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
if d.get(proj) is not True:
    d[proj] = True
    with open(cfg, "w") as f: json.dump(dict(sorted(d.items())), f, indent=2)
    with open(cfg, "a") as f: f.write("\n")
PY
fi

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
  [ -d "$HOME/.conda" ] && CONDA_BWRAP+=(--ro-bind "$HOME/.conda" "$HOME/.conda")
  CONDA_ENV_VARS=(
    CONDA_EXE="$CONDA_BASE/bin/conda"
    CONDA_PYTHON_EXE="$CONDA_BASE/bin/python"
  )
  CONDA_PATH_PREFIX="${CONDA_ENV_PATH:+$CONDA_ENV_PATH/bin:}$CONDA_BASE/condabin:"
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

trap 'rm -f "$RC_FILE"' EXIT INT TERM

# ── bwrap mount layout ───────────────────────────────────────────────────────
BWRAP_BASE=(
  --tmpfs /
  "${DIR_CHAIN[@]}"
  --ro-bind /usr /usr
  --ro-bind /etc /etc
  --symlink usr/bin /bin
  --symlink usr/lib /lib
  --symlink usr/lib64 /lib64
  --symlink usr/sbin /sbin
  --ro-bind /opt /opt
  --bind "$SANDBOX_DIR" "$SANDBOX_DIR"
  --dir "$HOME"
  "${USER_BINDS[@]}"
  "${CODER_BWRAP[@]}"
  "${CONDA_BWRAP[@]}"
  "${PROJECT_BWRAP[@]}"
  --proc /proc
)

# Minimal /dev — only essential devices instead of full /dev exposure
BWRAP_BASE+=(--dir /dev)
[ -d /dev/pts ] && BWRAP_BASE+=(--bind /dev/pts /dev/pts)
for _d in /dev/null /dev/zero /dev/random /dev/urandom /dev/tty; do
  # --dev-bind (not --bind) required for char devices: --bind sets MS_NODEV
  # which blocks device file access on older kernels (e.g. 4.18).
  [ -e "$_d" ] && BWRAP_BASE+=(--dev-bind "$_d" "$_d")
done

BWRAP_BASE+=(
  --tmpfs /tmp
  --tmpfs /run
  --bind "$RC_FILE" /tmp/sandbox-rc
  --chdir "$SANDBOX_DIR"
  --die-with-parent
)

# ── env passed to the sandboxed process ──────────────────────────────────────
CODER_ENV=()

# Coder tunnel: read from paths.conf CODER_TUNNEL_<CODER> (uppercase key)
_tunnel_upper="$(printf '%s' "$CODER" | tr '[:lower:]' '[:upper:]')"
_tunnel_var="CODER_TUNNEL_${_tunnel_upper}"
_tunnel_config="${!_tunnel_var:-}"
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
  PATH="${_extra_path}${CONDA_PATH_PREFIX}/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin"
)

# ── exec ─────────────────────────────────────────────────────────────────────
if [ "$CODER" != "shell" ]; then
  # Write a wrapper script to avoid injecting CODER into bash -c string
  WRAPPER="$(mktemp /tmp/sbox-wrap-XXXXXX)"
  cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
source /tmp/sandbox-rc
exec "$CODER" "\$@"
WRAPEOF
  chmod +x "$WRAPPER"
  trap 'rm -f "$RC_FILE" "$WRAPPER"' EXIT INT TERM

  # /tmp is a fresh tmpfs inside the sandbox, so the wrapper must be bound in
  BWRAP_BASE+=(--ro-bind "$WRAPPER" /tmp/sandbox-wrap)
  exec bwrap "${BWRAP_BASE[@]}" /usr/bin/env -i "${ENV_BASE[@]}" \
    /tmp/sandbox-wrap "$@"
fi

exec bwrap "${BWRAP_BASE[@]}" /usr/bin/env -i "${ENV_BASE[@]}" \
  /usr/bin/bash --rcfile /tmp/sandbox-rc
