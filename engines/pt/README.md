# engines/pt — PT / vLLM route

The `vllm`-kind engine extension. This is the route that delivers the
**loaded-instance payoff**: LM Studio indexes, "loads", and serves the model as
a genuine loaded instance, and `lms load` exits 0.

- `backend-manifest.json` — `name: "strata-linux-x86_64-avx2"`, `version: "1.0.0"`,
  `engine: "vllm"`, `runtime_kind: "vllm"`, `supported_model_formats:
  ["torchSafetensors"]`, `executable_relative_path: "strata-launch"`.
- `strata-shim` — engine-protocol server (vLLM dialect). Binds **both**
  the `--port` LM Studio passed on the spawn line **and** `:8000` (readiness
  dials `healthCheck` on the passed port; `getRuntimeLoadInfo`/`readLoadedModel`
  dial `:8000`). Streams SSE incrementally so LM Link never idles.
- `strata-launch` — launcher wrapper (argv[0] in the activity feed).
- `test/sse.test.mjs` — 42 assertions on the SSE→metrics mapping (green).

The vLLM driver's `applyPromptTemplate` is an **unconditional client-side throw**
(`EngineProtocolCapabilityError{capability:'promptTemplating'}`), so LM Studio's
built-in `rag-v1` is a dead end on this kind — attachments work via the custom
`vllm-rag` preprocessor instead. See [`../gguf/`](../gguf/) for the route
where the *built-in* `rag-v1` works.
