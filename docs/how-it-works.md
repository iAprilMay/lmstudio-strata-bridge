# How the bridge works

The goal: make a model that **Strata is already serving** appear as a genuine,
loaded LM Studio instance — without loading any weights and without patching
any LM Studio application file. The bridge sits on top of Strata: it answers
LM Studio's engine-protocol calls by forwarding them to the Strata serving
gateway ([Strata](https://github.com/Niko1221/Strata), OpenAI-compatible).

**Any Strata-served model works.** The bridge reads the served model id from
the gateway at runtime, so it adapts to whichever model Strata is serving.
Tested with `IQ3_S` and `IQ1_M`; Strata's catalog has many more (sizes and
quants), and the bridge supports whichever one is live.

## The seam: engine extensions

LM Studio has two extension layers:

- **Plugins** (`extensions/plugins/`) — shallow; a generator plugin only
  replaces generation for one chat. A generator entry identifies the *plugin*,
  never a model, so it is invisible to every loaded-model surface (`lms ps`,
  the loaded-instances API, the picker's model cards).
- **Engine / backend extensions**
  (`extensions/backends/<dir>/backend-manifest.json`) — these own **loaded
  models**. A correctly-shaped backend manifest makes LM Studio index, "load",
  and serve a model as a real loaded instance. This is the seam the bridge
  uses.

A backend manifest is scanned at startup and drives real model loading. The
shim is a plain HTTP server that speaks the engine-protocol dialect; LM
Studio does not care what binary answers it. Nothing is loaded into RAM — the
model dir is a tiny generated stub — so there is no second model and no OOM
risk.

## Two routes, both prettified to `Strata (Linux)`

The two routes carry distinct full-pattern manifest names (`...avx2` vs
`...vulkan-avx2`), so LM Studio lists both as separate selectable engines.
Version is no longer the dedup key, so both can share `1.0.0`. Both show
as "Strata (Linux)" in the picker.

| Route | Folder | `version` | `runtime_kind` | Format | Why |
| --- | --- | --- | --- | --- | --- |
| PT | `engines/pt/` | `1.0.0` | `vllm` | `torchSafetensors` | Loaded instance |
| GGUF | `engines/gguf/` | `1.0.0` | `llama-server` | `gguf` | rag-v1 works |

### Why the PT route binds two ports

The vLLM driver dials readiness on **two** ports: the readiness poll uses the
runtime handle `baseUrl = "http://host:<--port>"` (the `--port` LM Studio
passed on the spawn line), while the load-info / loaded-model reads use a
static resolver that answers `127.0.0.1:8000`. Serving only one of them leaves
the other dial failing, so the PT shim binds **both** (`[passedPort, 8000]`)
and returns valid JSON on `/health`.

### Why the GGUF route exists

The vLLM driver's `applyPromptTemplate` is an **unconditional client-side
throw** (a `promptTemplating` capability gap) — it never reaches the shim, so
LM Studio's built-in `rag-v1` preprocessor is a dead end on the vLLM kind. The
`llama-server` driver has **no** such override: it inherits the generic
engine-protocol client, so `applyPromptTemplate` dispatches as an RPC → `POST
/apply-template` reaches the GGUF shim, which renders the chat template and
returns `{prompt}`. That is the whole point of the GGUF route: make the
built-in `rag-v1` work without patching app code, by moving the fake model to
a `llama-server`-kind (GGUF) engine. The GGUF shim binds **only** the passed
`--port` (the llama-server kind honours it; there is no static `:8000`
resolver).

## What is honest about a "loaded instance"

A loaded instance in LM Studio does **not** mean the weights run inside LM
Studio. The served model is a large quantized model in a Strata-specific
architecture that stock llama.cpp cannot load. Every route here proxies to the
Strata gateway, which must keep running. "Loaded instance" ≠ "weights resident
in LM Studio" ≠ "custom icon".

## Ground rules

- **Gateway-only.** Never load weights; the Strata gateway must keep running.
- **RAM flat.** The model dir is a generated stub; nothing is materialized in
  LM Studio.
- **No proprietary code.** Original implementation; neither LM Studio's nor Strata's
  proprietary source or binaries are shared. An app library may be referenced
  in place by path, never copied.
- **No app-file patching.** Everything lives in LM Studio's own extension
  dirs, installed by copy, removable by deleting what was added.
- **Restarts are user-driven.** Nothing here starts or stops LM Studio.
- **Strata serves one concurrent prediction by default.** The shim forwards
  every request concurrently; how many predictions run in parallel is
  whatever you set in Strata's app under **Concurrent requests** (e.g. 4).
