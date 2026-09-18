#!/usr/bin/env bash
# Runs `claude` UNSANDBOXED against a local server that exposes the Anthropic
# Messages API at /v1/messages (vLLM >= 0.26). The sandboxed equivalent is
# `claude -local`, which is what you normally want; this script exists to test
# the same setup with sbox out of the picture.
#
# Only affects this process/terminal - other terminals running plain `claude`
# keep using your normal Anthropic login.
set -euo pipefail

: "${LOCAL_LLM_BASE_URL:=http://localhost:8000}"

# Read the served id and context window rather than hardcoding them: the id
# changes whenever the server loads a different model.
read -r M CTX <<<"$(curl -sf -m 5 "$LOCAL_LLM_BASE_URL/v1/models" | python3 -c '
import json, sys
m = json.load(sys.stdin)["data"][0]
print(m["id"], m.get("max_model_len", 200000))
')"

export ANTHROPIC_BASE_URL="$LOCAL_LLM_BASE_URL"
export ANTHROPIC_AUTH_TOKEN="localhost"
# claude sends the small/fast and default-family ids straight through, so each
# must name a model the server serves.
export ANTHROPIC_MODEL="$M"
export ANTHROPIC_SMALL_FAST_MODEL="$M"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$M"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$M"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$M"
# not in claude's model catalog, so the real window has to be stated or it
# assumes 200k and auto-compacts early
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CTX"
# vLLM 400s on effort "high" (accepts xhigh, medium, low)
export CLAUDE_CODE_EFFORT_LEVEL=medium
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

echo "local: $M at $LOCAL_LLM_BASE_URL (${CTX} ctx)" >&2
exec /opt/homebrew/bin/claude "$@"
