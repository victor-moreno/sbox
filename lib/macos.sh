#!/bin/zsh
# macos.sh — sandbox implementation for macOS (sandbox-exec).
# Works on both Apple Silicon (arm64) and Intel (x86_64).
# Called by ../aicode or ../sbox with first arg = coder name | "shell".

CODER="$1"; shift

SANDBOX_DIR="$(pwd -P)"
SBOX_ROOT="${SBOX_ROOT:-${0:A:h:h}}"

# load user-editable whitelist (RW + RO + CODER_RW variables)
. "$SBOX_ROOT/paths.conf"
# per-launch extras from aicode/sbox: -ro/-rw, .paths.local.conf (lib/extra-paths.sh)
RO+=(${(f)SBOX_RO})
RW+=(${(f)SBOX_RW})

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

# ── resolve coder-specific RW paths from paths.conf ──────────────────────────
# After the isolation block, which may create ~/.<coder> and ~/.<coder>.json
CODER_RW_PATHS=()
if [[ "$CODER" != "shell" ]]; then
  while IFS= read -r _p; do
    [[ -e "$_p" ]] && CODER_RW_PATHS+=("$_p")
  done < <(get_coder_paths "$CODER")
fi

# ── shared resources: opt-in per-project via symlink (see SHARED_RW in paths.conf) ─
# Walks the project tree up to a few levels deep (pruning .git/node_modules/.venv,
# since a symlink can live at any depth, e.g. tools/TTS), not just the top level.
# Skipped entirely when SHARED_RW is empty, and depth-capped otherwise, since an
# unbounded walk is slow in projects with many descendants.
# Resolved via python3 rather than zsh's ${:A}, which needs stat access on
# every ancestor of the target and silently returns the unresolved path
# otherwise (observed for symlinks into ~/Downloads/claude while sandboxed).
if (( ${#SHARED_RW[@]} > 0 )); then
  _realpath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
  while IFS= read -r entry; do
    target="$(_realpath "$entry")"
    for allowed in "${SHARED_RW[@]}"; do
      [[ -e "$allowed" ]] || continue
      allowed_real="$(_realpath "$allowed")"
      # match the shared path itself or anything under it, since a symlink
      # may point deeper (e.g. jamovi/jamovi-src inside a shared jamovi dir)
      [[ "$target" == "$allowed_real" || "$target" == "$allowed_real"/* ]] && RW+=("$allowed")
    done
  done < <(find "$SANDBOX_DIR" -maxdepth 2 \( -name .git -o -name node_modules -o -name .venv \) -prune -o -type l -print 2>/dev/null)
fi

# ── docker via colima: one shared VM, mounting only the current project ─────
# docker = root in its VM, so the VM's mounts are the real boundary: OrbStack
# shares the whole host filesystem, a default colima mounts ~. -docker uses
# colima profile "sbox" with $SANDBOX_DIR as its only mount. One VM keeps one
# image store for all projects; the price is one project at a time: another
# project restarts the VM with its own mount, and runs without docker while a
# -docker session of a different project is open (that one would see the mount).
# The sandbox gets the socket, never ~/.colima (editing colima.yaml from
# inside could add mounts), so the session/mount state lives there too.
# The VM keeps running after exit: colima stop -p sbox.
COLIMA_DIR="${COLIMA_HOME:-$HOME/.colima}"
DOCKER_SOCK=""
if [[ -n "${SBOX_DOCKER:-}" ]]; then
  command -v colima >/dev/null || { echo "aicode: -docker needs colima (brew install colima)" >&2; exit 1; }
  _vm="$COLIMA_DIR/sbox"
  mkdir -p "$_vm/sessions"
  # sessions/<launcher pid> holds its project; dead pids are leftovers
  for f in "$_vm"/sessions/*(N); do
    kill -0 "${f:t}" 2>/dev/null || { rm -f "$f"; continue; }
    # busy with another project: carry on without docker rather than exit
    [[ "$(<"$f")" == "$SANDBOX_DIR" ]] || { DOCKER_BUSY="$(<"$f")"; break; }
  done
fi
if [[ -n "${DOCKER_BUSY:-}" ]]; then
  DOCKER_BUSY_MSG="aicode: -docker off for this session: the docker VM is in use by $DOCKER_BUSY (close that session, then relaunch with -docker)"
  echo "$DOCKER_BUSY_MSG" >&2
  # the coder's UI draws over it at once: wait for a key so it is noticed
  # (terminal only, scripted launches go on); Ctrl-C quits before any setup
  if [[ -t 0 && -t 2 ]]; then
    read -rs -k1 "?aicode: press any key to continue without docker, Ctrl-C to quit "
    echo >&2
  fi
elif [[ -n "${SBOX_DOCKER:-}" ]]; then
  DOCKER_SESSION="$_vm/sessions/$$"
  print -r -- "$SANDBOX_DIR" > "$DOCKER_SESSION"
  _running=0
  colima status -p sbox >/dev/null 2>&1 && _running=1
  if (( _running )) && [[ "$(cat "$_vm/mount" 2>/dev/null)" != "$SANDBOX_DIR" ]]; then
    echo "aicode: restarting colima profile sbox to mount $SANDBOX_DIR" >&2
    colima stop -p sbox || exit 1
    _running=0
  fi
  if (( ! _running )); then
    echo "aicode: starting colima profile sbox (mount: $SANDBOX_DIR)" >&2
    # --activate=false: leave the host's docker context alone (your own VM)
    # --mount-type virtiofs: the hypervisor enforces the mount; sshfs (qemu
    # default, or a colima template) lets a root guest read any host path.
    # Needs vz (macOS 13+): fails instead of falling back; for qemu use 9p.
    colima start -p sbox --mount "$SANDBOX_DIR:w" --mount-type virtiofs --ssh-agent=false --activate=false || exit 1
    print -r -- "$SANDBOX_DIR" > "$_vm/mount"
  fi
  DOCKER_SOCK="$_vm/docker.sock"
  [[ -S "$DOCKER_SOCK" ]] || { echo "aicode: no docker socket at $DOCKER_SOCK" >&2; exit 1; }
  export DOCKER_HOST="unix://$DOCKER_SOCK"
  # ~/.docker stays hidden (registry credentials, other contexts); a session
  # config dir links the CLI plugins (compose, buildx) and silences the
  # "Error loading config file" warning
  DOCKDIR="$(mktemp -d /tmp/sbox-docker-XXXXXX)"
  mkdir "$DOCKDIR/cli-plugins"
  # brew's docker-compose/buildx install into $BREW/lib; ~/.docker wins
  for p in "$BREW"/lib/docker/cli-plugins/*(N) "$HOME"/.docker/cli-plugins/*(N); do ln -sf "${p:A}" "$DOCKDIR/cli-plugins/${p:t}"; done
  export DOCKER_CONFIG="$DOCKDIR"
fi

# ── build sandbox-exec policy ────────────────────────────────────────────────
POLICY="$(mktemp /tmp/sbox-policy-XXXXXX)"
{
  echo "(version 1)"
  echo "(allow default)"
  # no Apple Events: osascript could otherwise drive Terminal/VS Code/Finder,
  # which run unsandboxed (e.g. `tell app "Terminal" to do script ...`)
  echo "(deny appleevent-send)"
  # (allow default) alone left everything outside $HOME writable: /usr/local
  # (Homebrew on Intel is user-owned, so its binaries could be swapped),
  # /Applications (admin group), /Volumes, /Users/Shared. Writes are now
  # allowlisted too: temp dirs and devices here, the rest re-allowed below.
  echo "(deny file-write*)"
  echo '(allow file-write* (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/private/var/tmp") (subpath "/dev"))'
  # external/network drives hold data, not tools: opt in via paths.conf RO/RW
  echo '(deny file-read* (subpath "/Volumes"))'
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

  # same for parents of RO/RW entries under $HOME (e.g. ~/Library for
  # ~/Library/R): realpath() stats every component, so R's normalizePath()
  # failed with EPERM. Metadata only, no listing or reading.
  for p in "${RO[@]}" "${RW[@]}"; do
    [[ -e "$p" && "$p" == "$HOME"/* ]] || continue
    _anc="$p"
    while [[ "${_anc:h}" != "$HOME" && "${_anc:h}" != "/" ]]; do
      _anc="${_anc:h}"
      printf '(allow file-read-metadata (literal "%s"))\n' "$_anc"
    done
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

  # network filter: only localhost (dev servers, the IDE websocket, the
  # netproxy below) is reachable directly; the internet goes through netproxy.
  # Unix sockets only inside the project: /private/tmp holds the tmux server
  # socket (send-keys to an unsandboxed shell) and $TMPDIR VS Code's IPC.
  # No mDNSResponder socket either, so no DNS lookups (and no DNS tunnelling).
  if [[ "${NET_FILTER:-1}" == "1" ]]; then
    echo "(deny network-outbound)"
    echo '(allow network-outbound (remote ip "localhost:*"))'
    printf '(allow network-outbound (remote unix-socket (subpath "%s")))\n' "$SANDBOX_DIR"
    # extra unix sockets from paths.conf (e.g. docker); file access + connect
    for p in "${UNIX_SOCKETS[@]}"; do
      [[ -S "$p" ]] || continue
      printf '(allow file-read* file-write* (literal "%s"))\n' "$p"
      printf '(allow network-outbound (remote unix-socket (literal "%s")))\n' "$p"
    done
  fi
  # container VMs share host dirs with root containers: OrbStack (all of it,
  # also behind /var/run/docker.sock), other colima profiles, lima (~ by
  # default; its ssh ControlMaster sockets give a shell in the VM). Denied
  # even with NET_FILTER=0; only the sbox profile's socket gets through.
  printf '(deny network-outbound (remote unix-socket (subpath "%s")))\n' "$HOME/.orbstack" "$COLIMA_DIR" "$HOME/.lima"
  if [[ -n "$DOCKER_SOCK" ]]; then
    printf '(allow file-read* file-write* (literal "%s"))\n' "$DOCKER_SOCK"
    printf '(allow network-outbound (remote unix-socket (literal "%s")))\n' "$DOCKER_SOCK"
  fi
  # the allowlists must stay read-only even when the project is sbox itself
  # same for .paths.local.conf approvals, or a coder could approve its own edits
  printf '(deny file-write* (literal "%s") (literal "%s") (subpath "%s"))\n' "$SBOX_ROOT/paths.conf" "$SBOX_ROOT/net-allow.conf" "$SBOX_APPROVED"
  # the agent guide (GUIDE.md, $SBOX_GUIDE): sbox's dir is otherwise hidden under $HOME
  printf '(allow file-read* (literal "%s"))\n' "$SBOX_ROOT/GUIDE.md"
} > "$POLICY"
export SBOX_GUIDE="$SBOX_ROOT/GUIDE.md"

ZDOT=""
cleanup() {
  [[ -n "${NETPID:-}" ]] && kill "$NETPID" 2>/dev/null
  [[ -n "${NETDIR:-}" ]] && rm -rf "$NETDIR"
  [[ -n "${DOCKDIR:-}" ]] && rm -rf "$DOCKDIR"
  [[ -n "${DOCKER_SESSION:-}" ]] && rm -f "$DOCKER_SESSION"
  # repeated at exit: the coder's UI may have drawn over the one at launch
  [[ -n "${DOCKER_BUSY_MSG:-}" ]] && echo "$DOCKER_BUSY_MSG" >&2
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
# sandbox only ever sees it when paths.conf configures a tunnel for this host.
# -local is the other legitimate source: without this guard it was wiped here
# and claude silently fell back to api.anthropic.com (401, "Please run /login").
if [[ -z "${SBOX_LOCAL:-}" ]]; then
  unset ANTHROPIC_BASE_URL
fi

# ── network filter: netproxy runs outside the sandbox ────────────────────────
# Allowlist = NET_ALLOW (paths.conf) + net-allow.conf ("Always allow" answers);
# other hosts pop a dialog. Both files are read-only inside the sandbox.
if [[ "${NET_FILTER:-1}" == "1" ]]; then
  NETDIR="$(mktemp -d /tmp/sbox-net-XXXXXX)"
  _netlog="$HOME/.local/state/sbox/net.log"
  mkdir -p "${_netlog:h}"
  python3 "$SBOX_ROOT/lib/netproxy.py" serve --port-file "$NETDIR/port" \
    --watch-pid $$ --project "$SANDBOX_DIR" --log-root "$SANDBOX_DIR" --log .tmp/sbox-net.log \
    --always-file "$SBOX_ROOT/net-allow.conf" \
    --hint "Allow it outside the sandbox: add it to NET_ALLOW in $SBOX_ROOT/paths.conf or to $SBOX_ROOT/net-allow.conf" \
    "${NET_ALLOW[@]/#/--allow=}" </dev/null >/dev/null 2>>"$_netlog" &
  NETPID=$!
  for _i in {1..50}; do [[ -s "$NETDIR/port" ]] && break; sleep 0.1; done
  [[ -s "$NETDIR/port" ]] || { echo "aicode: netproxy did not start, see $_netlog" >&2; exit 1; }
  _proxy="http://127.0.0.1:$(<"$NETDIR/port")"
  export HTTP_PROXY="$_proxy" HTTPS_PROXY="$_proxy" ALL_PROXY="$_proxy"
  export http_proxy="$_proxy" https_proxy="$_proxy" all_proxy="$_proxy"
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
  # node >= 24 ignores *_PROXY unless asked
  export NODE_USE_ENV_PROXY=1
fi

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
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
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
