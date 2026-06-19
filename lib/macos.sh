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
# Points claude at $PWD/.<coder> via CLAUDE_CONFIG_DIR instead of mutating the
# shared ~/.<coder>. The env var is per-process, so concurrent sbox sessions in
# different terminals never collide (the old symlink-swap shared a single global
# ~/.<coder>/session-env pointer, which broke under parallel use). Global config
# (settings, CLAUDE.md, commands, agents, plugins, ...) is inherited via
# symlinks; projects/session-env/tasks are real per-project dirs. With
# CLAUDE_CONFIG_DIR set claude reads account state from $CONFIG_DIR/.<coder>.json
# and credentials from $CONFIG_DIR/.credentials.json (a file, NOT the Keychain),
# so both are provisioned from the real ~/.<coder>.json + Keychain at launch.
ISOLATE=0
CONFIG_DIR=""
_BACKUP_DIR="$HOME/.$CODER.__sbox_backup"

# One-time recovery for users upgrading from the old symlink-swap scheme: if
# ~/.<coder>/{projects,session-env,tasks} was left as a symlink and a backup
# exists, restore the real dir. No-op on a clean install.
_repair_legacy_swap() {
  local _subdir
  for _subdir in projects session-env tasks; do
    [[ -L "$HOME/.$CODER/$_subdir" ]] && rm -f "$HOME/.$CODER/$_subdir"
    if [[ -e "$_BACKUP_DIR/$_subdir" && ! -e "$HOME/.$CODER/$_subdir" ]]; then
      mv "$_BACKUP_DIR/$_subdir" "$HOME/.$CODER/$_subdir"
    fi
  done
  [[ -L "$HOME/.cache/$CODER" ]] && rm -f "$HOME/.cache/$CODER"
  if [[ -e "$_BACKUP_DIR/.cache_$CODER" && ! -e "$HOME/.cache/$CODER" ]]; then
    mv "$_BACKUP_DIR/.cache_$CODER" "$HOME/.cache/$CODER"
  fi
  rmdir "$_BACKUP_DIR" 2>/dev/null || true
}

if [[ "$CODER" != "shell" ]]; then
  # ${=..}: zsh needs explicit word-splitting of the space-separated list
  for _isolate_coder in ${=CODER_PROJECT_ISOLATION}; do
    [[ "$_isolate_coder" == "$CODER" ]] || continue
    [[ "$CODER" == "claude" ]] || continue   # CLAUDE_CONFIG_DIR is claude-specific
    ISOLATE=1
    CONFIG_DIR="$SANDBOX_DIR/.$CODER"

    _repair_legacy_swap
    mkdir -p "$CONFIG_DIR/projects" "$CONFIG_DIR/session-env" "$CONFIG_DIR/tasks"

    # Inherit global config entries as symlinks (skip per-project dirs and the
    # auth files, which are provisioned below).
    setopt local_options null_glob
    for _item in "$HOME/.$CODER"/*(DN); do
      _name="${_item:t}"
      case "$_name" in projects | session-env | tasks) continue ;; esac
      _link="$CONFIG_DIR/$_name"
      [[ -L "$_link" ]] && rm -f "$_link"   # refresh in case target moved
      [[ -e "$_link" ]] && continue          # don't clobber a real entry
      ln -s "$_item" "$_link"
    done

    # Auth state: oauthAccount lives in ~/.<coder>.json — share it.
    [[ -f "$HOME/.$CODER.json" ]] || echo '{}' > "$HOME/.$CODER.json"
    ln -sfn "$HOME/.$CODER.json" "$CONFIG_DIR/.$CODER.json"

    # Credentials: export the current Keychain token into the config dir each
    # launch (claude uses this file, not the Keychain, when CLAUDE_CONFIG_DIR set).
    if security find-generic-password -s "Claude Code-credentials" -w \
         > "$CONFIG_DIR/.credentials.json" 2>/dev/null; then
      chmod 600 "$CONFIG_DIR/.credentials.json"
    else
      rm -f "$CONFIG_DIR/.credentials.json"
    fi
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

  # per-project isolation: CONFIG_DIR lives under $SANDBOX_DIR (already RW) and
  # its symlinks resolve to ~/.<coder> + ~/.<coder>.json (RW via CODER_RW_PATHS)
  # and ~/.cache (RW via the RW array). No extra rules needed.

  # keychain access itself is granted via RW in paths.conf (~/Library/Keychains)
  echo "(allow mach-lookup (global-name \"com.apple.SecurityServer\"))"

  [[ -n "${SANDBOX_HISTFILE:-}" ]] && \
    printf '(allow file-read* file-write* (literal "%s"))\n' "$SANDBOX_HISTFILE"
} > "$POLICY"

ZDOT=""
cleanup() {
  rm -f "$POLICY"
  [[ -n "$ZDOT" ]] && rm -rf "$ZDOT"
  # Persist any token refreshed/rotated during the session back to the Keychain
  # before deleting the project-dir copy. Claude writes refreshed tokens to this
  # file (not the Keychain) when CLAUDE_CONFIG_DIR is set; without this write-back
  # the rotated refresh token is lost and the stale Keychain copy forces a
  # re-login next launch. Then remove the file so the OAuth token isn't left at
  # rest in the project dir.
  if [[ "$ISOLATE" == 1 ]]; then
    if [[ -s "$CONFIG_DIR/.credentials.json" ]]; then
      # -A: allow any app silent access. Without it the default ACL only
      # trusts /usr/bin/security, so the claude binary itself can't read its
      # own token back and silently mints a fresh throwaway keychain entry,
      # forcing /login next launch.
      security add-generic-password -U -A -s "Claude Code-credentials" \
        -a "${USER:-$(whoami)}" -w "$(cat "$CONFIG_DIR/.credentials.json")" 2>/dev/null
    fi
    rm -f "$CONFIG_DIR/.credentials.json"
  fi
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
  [[ "$ISOLATE" == 1 ]] && export CLAUDE_CONFIG_DIR="$CONFIG_DIR"

  # no exec: the EXIT trap must run afterwards to delete the policy temp file
  # and the exported credentials. Ctrl-C is the coder's to handle; ignoring it
  # here keeps cleanup deferred until the coder itself exits.
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
