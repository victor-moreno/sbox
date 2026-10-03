# extra-paths.sh — per-project / per-launch RO and RW paths on top of
# paths.conf. Sourced (bash) by ../aicode and ../sbox before they dispatch.
#
# Sources, both added to paths.conf's RO/RW by lib/macos.sh and lib/linux.sh
# through SBOX_RO / SBOX_RW (newline-separated):
#   -ro PATH / -rw PATH on the command line (parsed by the caller)
#   .paths.local.conf in the project, one "ro PATH" or "rw PATH" per line
#     (~ and paths relative to the project are expanded, # starts a comment line)
#
# The project is writable from inside the sandbox, so a coder could edit
# .paths.local.conf to grant itself more on the next launch. The file is only
# used after you approve its content at launch (y/N on the terminal); the
# approval is a hash of project path + content in SBOX_APPROVED, which the
# platform scripts keep read-only inside the sandbox. Any edit asks again.
# Parsed, never sourced: approving it grants paths, it can't run code.

SBOX_APPROVED="$HOME/.local/state/sbox/approved"
export SBOX_APPROVED
mkdir -p "$SBOX_APPROVED"

# mode (ro|rw), path: resolved to its real path, since Seatbelt matches
# resolved paths and "../data" would never match anything
_sbox_add_path() {
  local p="$2"
  [[ "$p" == "~" || "$p" == "~/"* ]] && p="$HOME${p:1}"
  [[ "$p" == /* ]] || p="$(pwd -P)/$p"
  if [[ ! -e "$p" ]]; then
    echo "sbox: $1 $2: no such path, skipped" >&2
    return 0
  fi
  p="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p")"
  if [[ "$1" == ro ]]; then
    SBOX_RO+="$p"$'\n'
  else
    SBOX_RW+="$p"$'\n'
  fi
}

# args: mode path pairs from the command line (-ro/-rw without the dash)
sbox_extra_paths() {
  SBOX_RO="" SBOX_RW=""
  while [ $# -ge 2 ]; do _sbox_add_path "$1" "$2"; shift 2; done

  # physical path, as the sandbox's SANDBOX_DIR: approvals don't depend on
  # which symlinked path the project was opened through
  local dir conf content hash ans mode path
  dir="$(pwd -P)"
  conf="$dir/.paths.local.conf"
  if [[ -f "$conf" ]]; then
    # read once: what gets hashed is exactly what gets parsed
    content="$(cat "$conf")"
    hash="$(printf '%s\n%s' "$dir" "$content" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
    if [[ ! -f "$SBOX_APPROVED/$hash" ]]; then
      if [[ -t 0 && -t 2 ]]; then
        echo "sbox: $conf is new or changed:" >&2
        printf '%s\n' "$content" | sed 's/^/    /' >&2
        read -r -p "sbox: grant these paths (asked again if the file changes)? [y/N] " ans
        if [[ "$ans" == [yY]* ]]; then
          : > "$SBOX_APPROVED/$hash"
        else
          content=""
        fi
      else
        echo "sbox: ignoring $conf: new or changed, launch from a terminal to approve it" >&2
        content=""
      fi
    fi
    while read -r mode path; do
      case "$mode" in
        ''|'#'*) ;;
        ro|rw) _sbox_add_path "$mode" "$path" ;;
        *) echo "sbox: $conf: ignored line '$mode $path' (use: ro PATH / rw PATH)" >&2 ;;
      esac
    done <<< "$content"
  fi
  export SBOX_RO SBOX_RW
}
