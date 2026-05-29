#!/bin/zsh
# macos.sh — sandbox implementation for macOS (sandbox-exec).
# Works on both Apple Silicon (arm64) and Intel (x86_64) — homebrew prefix
# is auto-detected. Called by ../claude or ../sbox with mode = claude|shell.

MODE="$1"; shift

SANDBOX_DIR="$(pwd -P)"
SBOX_ROOT="${SBOX_ROOT:-${0:A:h:h}}"

# load user-editable whitelist (RW + RO arrays)
. "$SBOX_ROOT/paths.conf"

# homebrew prefix differs by arch
if [[ -d /opt/homebrew ]]; then
  BREW="/opt/homebrew"
else
  BREW="/usr/local"
fi

# ── build sandbox-exec policy ────────────────────────────────────────────────
POLICY="$(mktemp /tmp/sbox-policy-XXXXXX)"
{
  echo "(version 1)"
  echo "(allow default)"
  # deny everything in $HOME by default
  printf '(deny file-read* file-write* (subpath "%s"))\n' "$HOME"
  # re-allow traversal so realpath() on $HOME and $HOME/.local works
  printf '(allow file-read* (literal "%s") (literal "%s/.local"))\n' "$HOME" "$HOME"
  # current project dir — full read+write
  printf '(allow file-read* file-write* (subpath "%s"))\n' "$SANDBOX_DIR"

  for p in "${RO[@]}"; do
    [[ -e "$p" ]] || continue
    if [[ -d "$p" ]]; then
      printf '(allow file-read* (subpath "%s"))\n' "$p"
    else
      printf '(allow file-read* (literal "%s"))\n' "$p"
    fi
  done

  for p in "${RW[@]}"; do
    [[ -e "$p" ]] || continue
    if [[ -d "$p" ]]; then
      printf '(allow file-read* file-write* (subpath "%s"))\n' "$p"
    else
      printf '(allow file-read* file-write* (literal "%s"))\n' "$p"
    fi
  done
  
  # allow read keychain to get claude credentials
  echo "(allow mach-lookup (global-name \"com.apple.SecurityServer\"))"
  printf '(allow file-read* file-write* (subpath "%s/Library/Keychains"))\n' "$HOME"

  # allow the history file if configured (may be outside the RW subpaths above)
  [[ -n "${SANDBOX_HISTFILE:-}" ]] && \
    printf '(allow file-read* file-write* (literal "%s"))\n' "$SANDBOX_HISTFILE"
} > "$POLICY"

ZDOT=""
cleanup() {
  rm -f "$POLICY"
  [[ -n "$ZDOT" ]] && rm -rf "$ZDOT"
}
trap cleanup EXIT INT TERM

# site-specific: route Anthropic traffic through local tunnel on mmini-ICO
ANTHROPIC_TUNNEL=""
if [[ "$(hostname)" == "mmini-ICO.local" ]]; then
  ANTHROPIC_TUNNEL="http://localhost:9443"
fi

# ── claude mode ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "claude" ]]; then
  CLAUDE_BIN="$BREW/bin/claude"
  [[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="$(command -v claude)"
  [[ -x "$CLAUDE_BIN" ]] || { echo "sbox: claude binary not found" >&2; exit 1; }
  export SANDBOX_DIR
  [[ -n "$ANTHROPIC_TUNNEL" ]] && export ANTHROPIC_BASE_URL="$ANTHROPIC_TUNNEL"
  exec sandbox-exec -f "$POLICY" "$CLAUDE_BIN" "$@"
fi

# ── shell mode ───────────────────────────────────────────────────────────────

# Build PATH from paths.conf PATH_EXTRA + homebrew + system dirs
_sandbox_path="${(j[:])PATH_EXTRA}"
_sandbox_path="${_sandbox_path:+${_sandbox_path}:}${BREW}/bin:${BREW}/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

ZDOT="$(mktemp -d /tmp/sbox-zdot-XXXXXX)"
cat > "$ZDOT/.zshrc" <<RCEOF
export PS1='%F{red}[sandbox:%1~]%f%# '
${PYTHON_VENV:+[ -f "${PYTHON_VENV}" ] && source "${PYTHON_VENV}"}
export EDITOR=nano
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONPYCACHEPREFIX=/tmp
export PATH="${_sandbox_path}"
alias ll='ls -la'
alias lh='ll -h'
alias top='top -o cpu'
alias R='R --no-save --no-restore'
${SANDBOX_HISTFILE:+export HISTFILE="${SANDBOX_HISTFILE}"}
${SANDBOX_HISTFILE:+export HISTSIZE=1000}
export SANDBOX_DIR="$SANDBOX_DIR"
${ANTHROPIC_TUNNEL:+export ANTHROPIC_BASE_URL="$ANTHROPIC_TUNNEL"}
setopt NO_HUP
echo ""
echo "  [sandbox] $SANDBOX_DIR"
echo "  python: \$(which python 2>/dev/null || echo 'not in PATH')"
echo "  type 'exit' to leave"
echo ""
RCEOF

ZDOTDIR="$ZDOT" sandbox-exec -f "$POLICY" /bin/zsh --no-globalrcs -i
