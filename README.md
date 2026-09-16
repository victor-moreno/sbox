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
aicode opencode      # OpenCode in a sandbox
aicode hermes        # Hermes Agent in a sandbox
aicode qwen          # Qwen Code in a sandbox
aicode <any-cmd>     # any command on PATH or in homebrew
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

3. Add these functions to `~/.bashrc` / `~/.zshrc`. Each opens (or re-attaches
   to) a tmux session running the sandboxed claude with the chosen account:

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
  tmux new-session -A -s "$name" -n claude "CLAUDE_CONFIG_DIR=\"\$HOME/.claude\" \$HOME/bin/sbox/claude$args"
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
  tmux new-session -A -s "$name" -n claudeUB "CLAUDE_CONFIG_DIR=\"\$HOME/.claudeUB\" \$HOME/bin/sbox/claude$args"
}
```

```
# Usage
claude                 # default account, tmux session named after the folder
claudeUB               # second account, same naming
claude work -c         # session "work", extra args (-c) passed to claude
claudeUB --resume      # args starting with "-" keep the folder name as session
```

Notes:
- The first argument, if it does not start with `-`, is the tmux session
  name, not a prompt. `claude "fix the bug"` names a session; use
  `claude main "fix the bug"` to pass a prompt.
- Session names don't include the account, by design: one tmux session per
  folder. `tmux new-session -A` attaches if the session exists, so whichever
  account started it keeps running; the other function just re-attaches.
  Give an explicit name to run both accounts side by side.
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
             no changes to lib/* needed for new coders
```

```
sandbox method:
  linux:  bwrap (bubblewrap)
  macos:  sandbox-exec
```
