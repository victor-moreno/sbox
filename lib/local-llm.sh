#!/usr/bin/env bash
# local-llm.sh — point claude at a locally served model instead of the real API.
# Sourced by aicode when -local is given; exits rather than letting the launch
# fall through to the paid API when nothing is serving.
#
# The backend must expose the Anthropic Messages API at /v1/messages (vLLM
# >= 0.26 does). OpenAI-only servers (llama.cpp, Ollama) need a translating
# proxy in front and are not handled here.

: "${LOCAL_LLM_BASE_URL:=http://localhost:8000}"

# On Linux the sandbox unshares the network namespace; lib/linux.sh bridges
# the port of a localhost URL into it (netproxy relay/forward).

_local_models="$(curl -sf -m 5 "$LOCAL_LLM_BASE_URL/v1/models")" || {
  echo "aicode: -local: no model server responding at $LOCAL_LLM_BASE_URL" >&2
  exit 1
}

# Take the served model id and its real context window from /v1/models, so a
# model swap on the server needs no edit here (LOCAL_LLM_MODEL_ID overrides,
# for a server that lists more than one).
read -r _local_id _local_ctx <<<"$(printf '%s' "$_local_models" | python3 -c '
import json, sys
m = json.load(sys.stdin)["data"][0]
print(m["id"], m.get("max_model_len", 200000))
')" || {
  echo "aicode: -local: could not read a model id from $LOCAL_LLM_BASE_URL/v1/models" >&2
  exit 1
}
if [ -n "${LOCAL_LLM_MODEL_ID:-}" ]; then _local_id="$LOCAL_LLM_MODEL_ID"; fi

export ANTHROPIC_BASE_URL="$LOCAL_LLM_BASE_URL"
export ANTHROPIC_AUTH_TOKEN="localhost"
# claude sends the small/fast and default-family ids straight through, so each
# must name a model the server actually serves or the session dies mid-run
# with "There's an issue with the selected model".
export ANTHROPIC_MODEL="$_local_id"
export ANTHROPIC_SMALL_FAST_MODEL="$_local_id"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$_local_id"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$_local_id"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$_local_id"
# the model is not in claude's catalog, so without this it assumes a 200k
# window and auto-compacts early
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$_local_ctx"
# vLLM rejects effort "high" (it accepts xhigh, medium, low); the user
# settings default to high, which 400s on the first request
export CLAUDE_CODE_EFFORT_LEVEL=medium
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

echo "aicode: -local: $_local_id at $LOCAL_LLM_BASE_URL (${_local_ctx} ctx)" >&2
