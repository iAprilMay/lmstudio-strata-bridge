# engines/gguf — GGUF / llama-server route

The `llama-server`-kind engine extension. Its whole point: make LM Studio's
**built-in** `lmstudio/rag-v1` preprocessor work without patching app code. The
llama-server driver has no client-side `applyPromptTemplate` override, so the
template call dispatches as an RPC → `POST /apply-template` reaches this shim,
which renders the chat template and returns `{prompt}`.

- `backend-manifest.json` — `name: "strata-linux-x86_64-vulkan-avx2"`, `version: "1.0.0"`,
  `engine: "llama.cpp"`, `runtime_kind: "llama-server"`,
  `supported_model_formats: ["gguf"]`, `gpu.framework: "Vulkan"`,
  `executable_relative_path: "strata-launch-llama"`. The distinct full-pattern
  name (vs the PT route's `...avx2`) is what makes the picker list both as
  "Strata (Linux)"; version is no longer the dedup key.
- `strata-shim-llama` — llama-server-dialect server. Endpoints:
  `/health`, `/v1/models`, `/props` (must carry `default_generation_settings.n_ctx`),
  `/apply-template`, `/tokenize` (nonneg integer IDs, `count == tokens.length`),
  `/detokenize`, `/v1/chat/completions`, `/v1/completions`. Imports the shared
  `strata-shim` from `../pt/strata-shim` in this split layout (at deploy time both
  shims sit side-by-side in one ext dir, so the same-dir import wins).
- `strata-launch-llama` — launcher wrapper.
- `test/llama.test.mjs` — 15 assertions (arg parse, model-derive, ChatML render).

Installs a generated GGUF stub (written by `scripts/make-stub-gguf.sh` into
`~/.lmstudio/models/local/strata-bridge-gguf`) so the gguf preference is
hijacked by a name-distinct engine. Tradeoff accepted: per-turn token counts
work; the conversation-summary block does not summarize (count 0).
