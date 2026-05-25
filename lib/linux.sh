#!/usr/bin/env bash
# linux.sh — sandbox implementation for Linux (bubblewrap).
# Called by ../claude or ../sbox with mode = claude|shell.
set -e

MODE="$1"; shift

SANDBOX_DIR="$(pwd)"
SBOX_ROOT="${SBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)}"

# load user-editable whitelist (RW + RO arrays)
# shellcheck disable=SC1091
. "$SBOX_ROOT/paths.conf"

# ── conda (optional) ─────────────────────────────────────────────────────────
# Auto-detected if `conda` is on PATH. Override before running:
#   CONDA_BASE=/path/to/miniconda CONDA_ENV=myenv sbox
#   CONDA_BASE="" sbox       # disable conda entirely
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

# ── per-project claude dirs (created on host, bind-mounted into sandbox) ─────
mkdir -p "$HOME/.claude"
mkdir -p "$SANDBOX_DIR/.claude/projects"
mkdir -p "$SANDBOX_DIR/.claude/session-env"
mkdir -p "$SANDBOX_DIR/.claude/tasks"
mkdir -p "$SANDBOX_DIR/.cache/claude"
[ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"

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
# ~/.claude.json is skipped here and bound below (essentials), so the same
# rule applies on every host regardless of paths.conf edits.
USER_BINDS=()
for p in "${RO[@]}"; do
  [ -e "$p" ] || continue
  USER_BINDS+=(--ro-bind "$p" "$p")
done
for p in "${RW[@]}"; do
  [ -e "$p" ] || continue
  [ "$p" = "$HOME/.claude.json" ] && continue
  USER_BINDS+=(--bind "$p" "$p")
done

# ── conda bwrap args + env (only if conda configured) ────────────────────────
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

# ── rc file (shared by both modes; claude mode sources it before exec) ───────
RC_FILE="$(mktemp /tmp/sbox-rc-XXXXXX)"
{
  echo 'export PS1="[sandbox:\w]\$ "'
  if [ -n "$CONDA_BASE" ]; then
    printf 'source "%s/etc/profile.d/conda.sh"\n' "$CONDA_BASE"
    [ -n "$CONDA_ENV_NAME" ] && printf 'conda activate "%s" 2>/dev/null || true\n' "$CONDA_ENV_NAME"
  fi
  cat <<'RCEOF'
HISTFILE="$SANDBOX_DIR/.sandbox_history"
HISTSIZE=1000
alias ll='ls -la'
RCEOF
  if [ "$MODE" = "shell" ]; then
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
  "${CONDA_BWRAP[@]}"
  # per-project claude overlays (must come after USER_BINDS to shadow ~/.claude)
  --bind "$SANDBOX_DIR/.cache/claude" "$HOME/.cache/claude"
  --bind "$HOME/.claude.json" "$HOME/.claude.json"
  --bind "$SANDBOX_DIR/.claude/projects" "$HOME/.claude/projects"
  --bind "$SANDBOX_DIR/.claude/session-env" "$HOME/.claude/session-env"
  --bind "$SANDBOX_DIR/.claude/tasks" "$HOME/.claude/tasks"
  --proc /proc
  --dev /dev
  --tmpfs /tmp
  --tmpfs /run
  --bind "$RC_FILE" /tmp/sandbox-rc
  --chdir "$SANDBOX_DIR"
  --die-with-parent
)

# /share is site-specific — bind RO if present
[ -d /share ] && BWRAP_BASE+=(--ro-bind /share /share)

# ── env passed to the sandboxed process ──────────────────────────────────────
ANTHROPIC_ENV=()
[ -n "${ANTHROPIC_BASE_URL:-}" ] && ANTHROPIC_ENV=(ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL")

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
  "${ANTHROPIC_ENV[@]}"
  "${CONDA_ENV_VARS[@]}"
  PATH="$HOME/.local/bin:$HOME/bin:${CONDA_PATH_PREFIX}/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin"
)

# ── exec ─────────────────────────────────────────────────────────────────────
if [ "$MODE" = "claude" ]; then
  # non-interactive bash: source rc (for conda activation), then exec claude
  exec bwrap "${BWRAP_BASE[@]}" /usr/bin/env -i "${ENV_BASE[@]}" \
    /usr/bin/bash -c 'source /tmp/sandbox-rc; exec claude "$@"' bash "$@"
fi

# shell mode — interactive bash
exec bwrap "${BWRAP_BASE[@]}" /usr/bin/env -i "${ENV_BASE[@]}" \
  /usr/bin/bash --rcfile /tmp/sandbox-rc
