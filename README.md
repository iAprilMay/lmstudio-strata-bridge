# lmstudio-strata-bridge

Make a model **already served by Strata** appear as a genuine, loaded LM Studio
instance — without loading any weights and without patching any LM Studio app
file. The bridge sits on top of Strata: it proxies LM Studio's engine-protocol
calls to the Strata gateway that is already running.

> **Description (per spec):** *Bridge to strata engine.*
> Engine picker name: **Strata (Linux)** (manifest `name` is a full-pattern
> `strata-linux-x86_64-avx2` / `strata-linux-x86_64-vulkan-avx2`, which LM
> Studio prettifies to "Strata (Linux)" and offers in the engine dropdown).
> Custom RAG component: **vLLM RAG** (a separate plugin, `vllm-rag`).

## What this is

LM Studio 0.4.x lets you drop an *engine extension* into
`~/.lmstudio/extensions/backends/`. A correctly-shaped backend manifest makes
LM Studio index, "load", and serve a model as a real loaded instance. The
shim is an engine-protocol server that answers LM Studio's readiness
dial (`/health → /v1/models → /tokenize → /v1/chat/completions`) by forwarding
to Strata's OpenAI-compatible gateway. No weights are loaded in LM Studio
(the model dir is a tiny stub); RAM stays flat.

**Any Strata-served model works.** The bridge discovers the served model id
from the gateway at runtime, so it adapts to whichever model Strata is
serving. Tested with `IQ3_S` and `IQ1_M`; Strata's catalog has many more.

Two runtime routes coexist, both prettified to **Strata (Linux)** (full-pattern
manifest names so LM Studio recognizes them as selectable engines):

| Route | `runtime_kind` | Model format |
| --- | --- | --- |
| [PT / vLLM](engines/pt/) | `vllm` | `torchSafetensors` |
| [GGUF / llama-server](engines/gguf/) | `llama-server` | `gguf` |

Manifest `name` + `version` (both `1.0.0`): PT = `strata-linux-x86_64-avx2`,
GGUF = `strata-linux-x86_64-vulkan-avx2`. The PT route binds the passed
`--port` **and** `:8000`; the GGUF route implements `POST /apply-template` so
LM Studio's **built-in** `rag-v1` works.

### Why both a PT and a GGUF route exist

They are two ways to make the *same* Strata-served model show up as a loaded
instance, each good at a different thing — keep whichever fits your use case:

- **PT (`torchSafetensors` / vLLM kind)** — the simplest, fastest-to-load
  route. It keeps LM Studio's **original GGUF backend selection** (CPU,
  Vulkan, CUDA, ROCm — whatever this box already uses) and just loads the
  Strata shim without touching runtime settings each time. Use it for a
  quick, stable loaded instance when you don't need built-in document plugins.
- **GGUF (`gguf` / llama-server kind)** — the route that lets LM Studio's
  **built-in plugins** work, notably the built-in `rag-v1` document
  preprocessor (its `applyPromptTemplate` reaches the shim as a real RPC on
  this kind, instead of the vLLM driver's client-side throw). Use it when you
  want "Chat with Files" / `rag-v1` to work out of the box.

The two routes carry distinct full-pattern manifest names (`...avx2` vs
`...vulkan-avx2`), so LM Studio lists both as separate selectable engines.
Version is no longer the dedup key, so both can share `1.0.0`. The picker
shows both as "Strata (Linux)".

## Confirmed working versions

The bridge is version-sensitive on both sides (the engine-extension layer and
the gateway shape). These combinations are confirmed working end-to-end —
load, chat, reasoning, vision, tool calls, file attachments, and LM Link from
remote devices:

| Component | Confirmed versions |
| --- | --- |
| LM Studio | `0.4.28` (Build 2) and `0.4.26+4` |
| Strata (app) | `0.2.12` and `0.2.11` |
| Strata engine | `0.1.58` and `0.1.57` |
| Bionic | `1.1.9+6` |
| Bridge engine extensions | `1.0.0` (both routes) |
| vLLM RAG plugin | revision `1` (`vllm-rag`) |
| llama.cpp donor (`.node`/`.so`) | latest installed (`2.71.0` tested) |

Notes:

- The manifests declare `minimum_lmstudio_version` `0.4.0+15`.
- The shim reads the gateway SSE stream, its final-chunk `timings` block, and
  Strata's `native-tune` files; those shapes are unchanged across the Strata
  versions above. On `0.2.12` the tok/s figures become stricter (request
  admission time is now counted) — cosmetic, no shim change needed.
- The llama `.node`/`.so` files are NOT shipped in this repo. Install picks
  the NEWEST llama.cpp backend already in `~/.lmstudio/extensions/backends/`
  (GPU-capable preferred) and copies its `.node`/`.so` closure into the ext
  dir, so a llama.cpp engine update never dangles the extension.

If a future LM Studio or Strata update breaks the bridge, start by diffing
against this table — the usual culprits are the engine-protocol readiness dial
(LM Studio side) or the gateway SSE/`timings` shape (Strata side).

## Which backends / hardware this works on

The bridge performs **no inference** — the shim proxies Strata's gateway, and
Strata's own engine uses whatever GPU/CPU it was configured with. The LM
Studio backend layers matter only for indexing + the survey gate:

- **The extensions index on:** Linux x86_64 with AVX2 (both manifests pin
  `platform: linux`, `architecture: x86_64`, `AVX2`). Windows, macOS, and ARM
  builds are NOT indexed today — the shim itself is pure Node stdlib and
  portable, but the manifests + donor picker would need porting + testing.
- **Donor picker (`scripts/pick-donor.sh`):** uses the newest installed
  `llama.cpp-linux-x86_64-*-avx2-*` backend — **CPU, ROCm, Vulkan, CUDA 12,
  CUDA 13 all work**. Preference order is vulkan → cuda → rocm → cpu,
  because on AMD only the Vulkan bindings report the `deviceUUID` the vLLM
  driver's survey gate requires. At least one GPU-capable donor is strongly
  preferred (the vLLM driver demands an enabled GPU).
- **Not used as donors:** oMLX, LM Studio MLX, Metal, and Splash are separate
  engine families (`omlx` / `mlx-llm` / `splash`) — the picker never matches
  them, and the manifests don't index on Apple Silicon at all.
- **Loading the model:** neither of the above. The PT extension wins the
  `torchSafetensors` preference and the GGUF extension wins `gguf` while
  installed; the chat then runs entirely through the shim -> Strata gateway,
  so the box's GPU backend choice does not affect answer speed or quality.

## Ground rules

- **Gateway-only.** Never load weights; the Strata gateway must keep running.
- **RAM flat.** The model dir is a stub; nothing is loaded in LM Studio.
- **No proprietary code.** Everything here is original. Neither LM Studio's nor Strata's
  source or binaries are included or shipped -- app libraries are
  referenced in place by path, never copied or vendored.
- **No app-file patching.** Everything lives in LM Studio's own extension
  dirs (`extensions/backends/`, `extensions/plugins/`), installed by copy,
  removable by deleting what was added.
- **Restarts are user-driven.** Nothing here starts or stops LM Studio.
- **Strata serves one concurrent prediction by default** The shim forwards every
  request concurrently, so the number of predictions that actually run in
  parallel is whatever you set in Strata's app under **Concurrent requests**
  (e.g. 4). Set it to 1 and they queue; set it higher and the shim already
  handles them — at any slot count.

## Layout

```text
lmstudio-strata-bridge/
  Makefile                       # `make verify` = type check + tests + env
  engines/
    pt/                          # vllm-kind route (strata-shim, strata-launch)
    gguf/                        # llama-server-kind route (strata-shim-llama)
  scripts/                       # install / rollback / stub / reload helpers
  tools/                         # env probe, smoke test, MCP + REST demos
  docs/                          # docs only (shim, install, matrix)
  img/                           # screenshots in the LM Studio + Strata GUIs
```

## Quick start

```bash
# Verify the tree is healthy (read-only; touches no app):
make verify

# Install the engine extensions + stub model dirs (asks which route:
# GGUF / PT / both; or pass pt|gguf|both), then restart LM Studio:
bash scripts/install.sh

# Install the custom vLLM RAG prompt-preprocessor plugin (a separate plugin;
# restart LM Studio after):
bash "../vLLM RAG/scripts/install.sh"

# Roll everything back (deletes only the bridge's dirs):
bash scripts/remove-engine-extension.sh --force
```

The Strata gateway port + key are discovered at runtime from `~/.strata`
(never logged). If the CLI process name isn't auto-detected, set
`STRATA_GATEWAY_BASE` (e.g. `http://127.0.0.1:8080/v1`).

## Chat from anywhere — LM Link + phone apps

Because the bridge registers a **genuine loaded instance** (not a generator),
LM Studio's **LM Link** can share it with your other devices over the network.
That means you can chat with your own big Strata-served model from:

- **LM Studio on another PC** in the same local network, or over the internet
  via LM Link.
- **Phone apps** that speak the LM Studio / OpenAI-compatible API — e.g.
  **Locally** on an iPhone — pointed at the linked instance.

**Images and file attachments are supported and tested** through the bridge
(the custom `vllm-rag` preprocessor on the PT route, or LM Studio's built-in
`rag-v1` on the GGUF route). The bridge has been tested from an iPhone (via
Locally) and from remote PCs in the local network and over the internet, all
through LM Studio's LM Link.

Screenshots of how the bridge looks in the LM Studio and Strata GUIs live in
[`img/`](img/).

## Credits

- [LM Studio](https://github.com/lmstudio-ai) — the host application and its
  engine-extension + LM Link layers. LM Studio is a trademark of its owners;
  this bridge is unofficial.
- [Strata](https://github.com/Niko1221/Strata) — the inference engine whose
  already-running serving gateway this bridge proxies.

## Honesty rule

**Visible in the dropdown ≠ native loaded model ≠ custom icon ≠ Link-shared.**
Nothing here implies otherwise. A custom model icon is still not achieved.

## License

See [LICENSE](LICENSE).
