#!/bin/zsh
# macos.sh — sandbox implementation for macOS (sandbox-exec).
# Works on both Apple Silicon (arm64) and Intel (x86_64).
# Called by ../aicode or ../sbox with first arg = coder name | "shell".

CODER="$1"; shift

SANDBOX_DIR="$(pwd -P)"
SBOX_ROOT="${SBOX_ROOT:-${0:A:h:h}}"

# load user-editable whitelist (RW + RO + CODER_RW variables)
. "$SBOX_ROOT/paths.conf"

# homebrew prefix differs by arch
if [[ -d /opt/homebrew ]]; then
  BREW="/opt/homebrew"
else
  BREW="/usr/local"
fi

# ── helper: get newline-delimited coder paths from CODER_RW_<CODER> ──────────
# Config uses uppercase keys (CODER_RW_CLAUDE), coder name is lowercased.
get_coder_paths() {
  local _upper="${(U)1}"
  local varname="CODER_RW_$_upper"
  local value="${(P)varname:-}"
  if [[ -n "$value" ]]; then
    echo "$value"
  else
    printf '%s\n%s\n' "$HOME/.$1" "$HOME/.$1.json"
  fi
}

# ── per-project isolation ────────────────────────────────────────────────────
# Uses CLAUDE_CONFIG_DIR (claude-code) to point claude at $SANDBOX_DIR/.<coder>
# instead of ~/.<coder>. Global settings (CLAUDE.md, settings.json, commands,
# agents, plugins, ...) are inherited via per-entry symlinks; projects/
# session-env/tasks are real dirs under the project so they isolate per
# project. Nothing in $HOME is mutated at runtime, so concurrent sbox
# sessions in different terminals don't race on shared symlinks.
ISOLATE=0
CONFIG_DIR=""

# Best-effort migration: undo legacy ~/.claude/{projects,session-env,tasks}
# symlinks left by the older isolation scheme and restore originals from
# its backup dir. Safe to call repeatedly.
_legacy_restore() {
  local _backup="$HOME/.$CODER.__sbox_backup" _subdir
  for _subdir in projects session-env tasks; do
    [[ -L "$HOME/.$CODER/$_subdir" ]] && rm -f "$HOME/.$CODER/$_subdir"
    if [[ -e "$_backup/$_subdir" && ! -e "$HOME/.$CODER/$_subdir" ]]; then
      mv "$_backup/$_subdir" "$HOME/.$CODER/$_subdir"
    fi
  done
  [[ -L "$HOME/.cache/$CODER" ]] && rm -f "$HOME/.cache/$CODER"
  if [[ -e "$_backup/.cache_$CODER" && ! -e "$HOME/.cache/$CODER" ]]; then
    mv "$_backup/.cache_$CODER" "$HOME/.cache/$CODER"
  fi
  rmdir "$_backup" 2>/dev/null || true
}

if [[ "$CODER" != "shell" ]]; then
  # ${=..}: zsh needs explicit word-splitting of the space-separated list
  for _isolate_coder in ${=CODER_PROJECT_ISOLATION}; do
    [[ "$_isolate_coder" == "$CODER" ]] || continue
    # Only claude is supported here (uses CLAUDE_CONFIG_DIR). Other coders
    # would need their own equivalent env var.
    [[ "$CODER" == "claude" ]] || continue
    ISOLATE=1
    CONFIG_DIR="$SANDBOX_DIR/.$CODER"

    _legacy_restore
    mkdir -p "$HOME/.$CODER" "$CONFIG_DIR"
    [ -f "$HOME/.$CODER.json" ] || echo '{}' > "$HOME/.$CODER.json"

    # Mirror ~/.<coder> entries into CONFIG_DIR as symlinks so claude still
    # sees global settings/CLAUDE.md/commands/plugins/etc. Per-project
    # subdirs override the symlinks with real dirs below.
    setopt local_options null_glob
    for _item in "$HOME/.$CODER"/*(DN); do
      _name="${_item:t}"
      case "$_name" in
        projects | session-env | tasks) continue ;;
      esac
      _link="$CONFIG_DIR/$_name"
      [[ -L "$_link" ]] && rm -f "$_link"   # refresh in case target moved
      [[ -e "$_link" ]] && continue          # don't clobber real entries
      ln -s "$_item" "$_link"
    done

    mkdir -p "$CONFIG_DIR/projects" "$CONFIG_DIR/session-env" "$CONFIG_DIR/tasks"
    break
  done
fi

# ── resolve coder-specific RW paths from paths.conf ──────────────────────────
# After the isolation block, which may create ~/.<coder> and ~/.<coder>.json
CODER_RW_PATHS=()
if [[ "$CODER" != "shell" ]]; then
  while IFS= read -r _p; do
    [[ -e "$_p" ]] && CODER_RW_PATHS+=("$_p")
  done < <(get_coder_paths "$CODER")
fi

# ── build sandbox-exec policy ────────────────────────────────────────────────
POLICY="$(mktemp /tmp/sbox-policy-XXXXXX)"
{
  echo "(version 1)"
  echo "(allow default)"
  printf '(deny file-read* file-write* (subpath "%s"))\n' "$HOME"
  printf '(allow file-read* (literal "%s"))\n' "$HOME"
  printf '(allow file-read* file-write* (subpath "%s"))\n' "$SANDBOX_DIR"

  # ancestors of the project dir must be stat-able or getcwd() and git's
  # repo discovery fail with EPERM in nested dirs (e.g. ~/Downloads/x).
  # metadata only: stat works but listing entry names stays denied.
  _anc="$SANDBOX_DIR"
  while [[ "$_anc" != "/" ]]; do
    _anc="${_anc:h}"
    printf '(allow file-read-metadata (literal "%s"))\n' "$_anc"
  done

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

  # coder-specific config dirs (from CODER_RW in paths.conf)
  for p in "${CODER_RW_PATHS[@]}"; do
    if [[ -d "$p" ]]; then
      printf '(allow file-read* file-write* (subpath "%s"))\n' "$p"
    else
      printf '(allow file-read* file-write* (literal "%s"))\n' "$p"
    fi
  done

  # per-project isolation: CONFIG_DIR lives under $SANDBOX_DIR, which is
  # already RW. Symlinks inside it target $HOME/.<coder>/* which is RW via
  # CODER_RW_PATHS above. No extra rules needed.

  # keychain access itself is granted via RW in paths.conf (~/Library/Keychains)
  echo "(allow mach-lookup (global-name \"com.apple.SecurityServer\"))"

  [[ -n "${SANDBOX_HISTFILE:-}" ]] && \
    printf '(allow file-read* file-write* (literal "%s"))\n' "$SANDBOX_HISTFILE"
} > "$POLICY"

ZDOT=""
cleanup() {
  rm -f "$POLICY"
  [[ -n "$ZDOT" ]] && rm -rf "$ZDOT"
  return 0
}
trap cleanup EXIT INT TERM

# ── coder tunnel: read from paths.conf CODER_TUNNEL_<CODER> (uppercase key) ──
_CODER_TUNNEL_URL=""
_tunnel_var="CODER_TUNNEL_${(U)CODER}"
_tunnel_config="${(P)_tunnel_var:-}"
if [[ -n "$_tunnel_config" ]]; then
  _tunnel_host="${_tunnel_config%%=*}"
  _tunnel_url="${_tunnel_config#*=}"
  if [[ "$(hostname)" == "$_tunnel_host" ]]; then
    _CODER_TUNNEL_URL="$_tunnel_url"
  fi
fi

# ── coder mode ───────────────────────────────────────────────────────────────
if [[ "$CODER" != "shell" ]]; then
  CODER_BIN="$BREW/bin/$CODER"
  [[ -x "$CODER_BIN" ]] || CODER_BIN="$(command -v "$CODER")"
  [[ -x "$CODER_BIN" ]] || { echo "aicode: $CODER binary not found" >&2; exit 1; }

  export SANDBOX_DIR
  [[ -n "$_CODER_TUNNEL_URL" ]] && export ANTHROPIC_BASE_URL="$_CODER_TUNNEL_URL"
  [[ "$ISOLATE" == 1 && "$CODER" == "claude" ]] && export CLAUDE_CONFIG_DIR="$CONFIG_DIR"

  # no exec: the EXIT trap must run afterwards to clean up the policy file.
  trap '' INT TERM
  sandbox-exec -f "$POLICY" "$CODER_BIN" "$@"
  exit $?
fi

# ── shell mode ───────────────────────────────────────────────────────────────

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
${_CODER_TUNNEL_URL:+export ANTHROPIC_BASE_URL="$_CODER_TUNNEL_URL"}
export SANDBOX_DIR="$SANDBOX_DIR"
setopt NO_HUP
echo ""
echo "  [sandbox] $SANDBOX_DIR"
echo "  python: \$(which python 2>/dev/null || echo 'not in PATH')"
echo "  type 'exit' to leave"
echo ""
RCEOF

ZDOTDIR="$ZDOT" sandbox-exec -f "$POLICY" /bin/zsh --no-globalrcs -i
