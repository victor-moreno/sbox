# sbox

Sandbox scripts for Linux (bubblewrap) and macOS (sandbox-exec, arm & x64).
Run a coding assistant isolated to the current directory.

```
DIR=/path/to/sbox

alias aicode='$DIR/aicode'   # starts a coder inside a sandbox
alias sbox='$DIR/sbox'       # starts a sandboxed shell
alias claude='$DIR/claude'   # backward compat: same as `aicode claude`
```

```
# Usage
aicode claude        # Claude Code in a sandbox
aicode opencode      # OpenCode in a sandbox
aicode qwen          # Qwen Code in a sandbox
aicode <any-cmd>     # any command on PATH or in homebrew
sbox                 # interactive sandboxed shell
```

```
paths.conf   define which paths the sandbox gets RO or RW
             CODER_RW_<coder> variables map coder → config dirs (RW)
             CODER_PROJECT_ISOLATION sets coders with per-project history
             no changes to lib/* needed for new coders
```

```
sandbox method:
  linux:  bwrap (bubblewrap)
  macos:  sandbox-exec
```
