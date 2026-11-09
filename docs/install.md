# Install + rollback

Everything the bridge installs lives in LM Studio's own extension dirs and is
removable by deleting only what was added. It never patches an app file, never
touches `~/.strata`, and never loads weights.

## Install the engine extensions + stub model dirs

```bash
bash scripts/install.sh          # asks which route: GGUF / PT / both
bash scripts/install.sh gguf     # or pick a route directly (pt | gguf | both)
```

This creates, under `~/.lmstudio/`:

- `extensions/backends/strata-linux-x86_64-avx2-1.0.0/` — the PT (vLLM)
  engine extension: `backend-manifest.json`, the vendored `.node`/`.so` closure
  (copied from the app's own llama.cpp donor build so the extension is
  independent of any donor version), `strata-shim`, and the `strata-launch`
  wrapper.
- `extensions/backends/strata-linux-x86_64-vulkan-avx2-1.0.0/` — the GGUF
  (llama-server) engine extension: `backend-manifest.json`, the same vendored
  closure, `strata-shim` + `strata-shim-llama`, and the `strata-launch-llama`
  wrapper.
- `models/local/strata-bridge-987b/` — the generated PT stub model dir.
- `models/local/strata-bridge-gguf/` — the generated GGUF stub model dir.

The LM Studio home is resolved the same way the app/CLI does (honouring
`~/.lmstudio-home-pointer`), so install / rollback / stub generators all
target one home.

## Restart to index

The backends scan runs at startup, so **restart LM Studio** after installing.
Adding the dirs while the app runs is harmless — they simply are not indexed
until the next scan.

## Install the vLLM RAG prompt preprocessor (optional)

The GGUF route makes LM Studio's **built-in** `rag-v1` work. If you want
document attachments on the PT route instead, install the custom preprocessor
plugin:

```bash
bash "../vLLM RAG/scripts/install.sh"
```

## Rollback

```bash
bash scripts/remove-engine-extension.sh --force
```

Deletes only the bridge's own extension dirs + stub model dirs.
Strata is untouched.

## Strata gateway discovery

The gateway port + key are discovered at runtime from `~/.strata` (the key is
never logged). If the CLI process name is not auto-detected, set
`STRATA_GATEWAY_BASE` (e.g. `http://127.0.0.1:8080/v1`).

## Verify the tree (read-only, touches no app)

```bash
make verify   # type check + unit tests + read-only environment probe
```
