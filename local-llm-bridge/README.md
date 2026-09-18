# local-llm-bridge

Scratch scaffolding for pointing Claude Code at a locally served model, for
trying ideas — not for real work.

The backend must expose the Anthropic Messages API at `/v1/messages`
(vLLM >= 0.26 and SGLang do). OpenAI-only servers such as llama.cpp or Ollama need a
translating proxy in front; the LiteLLM setup that used to live here was
removed because the vLLM endpoint makes it unnecessary.

- `claude -local` — the normal path: sandboxed, via `aicode`/`lib/local-llm.sh`.
  Detects the served model and its context window, and refuses to start if
  nothing answers on `localhost:8000` so it never falls back to the paid API.
- `claude-local-direct.sh` — the same thing unsandboxed, to check whether a
  problem comes from sbox or from the model.

Override the endpoint with `LOCAL_LLM_BASE_URL`, or pin a model with
`LOCAL_LLM_MODEL_ID` if the server lists more than one.

## Gotchas found while testing

- `CLAUDE_CODE_EFFORT_LEVEL=medium` is required: vLLM rejects effort `high`
  (it accepts `xhigh`, `medium`, `low`) and the user settings default to high.
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is required: the model is not in Claude
  Code's catalog, so it otherwise assumes a 200k window.
- Linux: the sandbox uses `--unshare-net`, so `lib/linux.sh` bridges the
  model's localhost port in (netproxy `relay` outside, `forward` inside);
  other host loopback ports stay unreachable. Tested with SGLang serving
  deepseek-v4-flash on compute-cuda-04.
