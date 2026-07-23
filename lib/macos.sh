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

# ── workspace pre-trust ──────────────────────────────────────────────────────
# Claude gates the global permissions.allow list behind a per-project-path trust
# flag, so every new folder otherwise prints "Ignoring N permissions.allow
# entries: workspace not trusted" until you accept the dialog there. The sandbox
# itself is the trust boundary, so any dir opened via sbox is trusted by
# construction. Runs pre-launch (claude not yet writing the file); keyed on the
# real path claude sees ($SANDBOX_DIR).
#
# No per-project CLAUDE_CONFIG_DIR isolation here: claude already namespaces
# history per folder (~/.claude/projects/<path-slug>, session-env/<uuid>) and
# handles concurrent sessions in different dirs against one shared ~/.claude.
# Pointing it at $PWD/.claude instead made macOS fork a config-dir-namespaced
# Keychain entry per project, each rotating its own OAuth token off one shared
# seed — and since refresh tokens are single-use, the first project to refresh
# invalidated every other copy, so each new folder hit /login. Sharing ~/.claude
# keeps a single token chain. (Linux still isolates via bind-mounts, which leave
# the real ~/.claude credentials untouched; see lib/linux.sh.)
if [[ "$CODER" == "claude" ]]; then
  [[ -f "$HOME/.$CODER.json" ]] || echo '{}' > "$HOME/.$CODER.json"
  python3 - "$HOME/.$CODER.json" "$SANDBOX_DIR" <<'PY'
import json, sys
cfg, proj = sys.argv[1], sys.argv[2]
try:
    with open(cfg) as f: d = json.load(f)
except Exception:
    d = {}
entry = d.setdefault("projects", {}).setdefault(proj, {})
if entry.get("hasTrustDialogAccepted") is not True:
    entry["hasTrustDialogAccepted"] = True
    with open(cfg, "w") as f: json.dump(d, f, indent=2)
PY
fi

# Pi stores project trust decisions in ~/.pi/agent/trust.json keyed by the
# canonical project path. Since the sandbox itself is the trust boundary here,
# auto-trust the sandboxed working directory so pi can load project-local .pi
# resources without prompting on every first launch inside a new folder.
if [[ "$CODER" == "pi" ]] && command -v python3 >/dev/null 2>&1; then
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
# clear any ANTHROPIC_BASE_URL inherited from the invoking shell so the
# sandbox only ever sees it when paths.conf configures a tunnel for this host
unset ANTHROPIC_BASE_URL

# ── coder mode ───────────────────────────────────────────────────────────────
if [[ "$CODER" != "shell" ]]; then
  CODER_BIN="$BREW/bin/$CODER"
  [[ -x "$CODER_BIN" ]] || CODER_BIN="$(command -v "$CODER")"
  [[ -x "$CODER_BIN" ]] || { echo "aicode: $CODER binary not found" >&2; exit 1; }

  export SANDBOX_DIR
  [[ -n "$_CODER_TUNNEL_URL" ]] && export ANTHROPIC_BASE_URL="$_CODER_TUNNEL_URL"

  # no exec: the EXIT trap must run afterwards to delete the policy temp file.
  # Ctrl-C is the coder's to handle; ignoring it here keeps cleanup deferred
  # until the coder itself exits.
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
