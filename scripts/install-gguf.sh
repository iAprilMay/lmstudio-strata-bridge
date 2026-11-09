#!/usr/bin/env bash
# install-gguf.sh — install ONLY the GGUF / llama-server route (strata-linux 1.0.0) + its stub.
#
# Additive only: creates the backend extension dir (manifest + self-contained vendored
# .node/.so copied from the app's own llama.cpp donor) and the GGUF stub model dir. It
# never patches/swaps/replaces an app file, never touches ~/.strata, never loads weights.
# Idempotent.
#
# The GGUF route is the one that lets LM Studio's BUILT-IN plugins work — notably the
# built-in rag-v1 document preprocessor (its applyPromptTemplate reaches the shim as a
# real RPC on the llama-server kind, instead of the vLLM driver's client-side throw).
#
# Usage:
#   scripts/install-gguf.sh
#
# After installing, LM Studio must be RESTARTED for the backends scan to index it.
set -euo pipefail

# Shared donor picker (also resolves LMSTUDIO_HOME; sets DONOR/DONOR_KIND/LIB_NAME/ENG_NAME).
source "$(dirname "$0")/pick-donor.sh"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_EXT_NAME="strata-linux-x86_64-vulkan-avx2-1.0.0"
LLAMA_EXT_DIR="${LMSTUDIO_HOME}/extensions/backends/${LLAMA_EXT_NAME}"
GGUF_MODEL_DIR="${LMSTUDIO_HOME}/models/local/strata-bridge-gguf"

# ---------------------------------------------------------------------------
# Route — GGUF / llama-server (strata-linux 1.0.0)
# ---------------------------------------------------------------------------
# The llama-server runtime kind inherits the generic engine-protocol client, so
# applyPromptTemplate dispatches as an RPC -> POST /apply-template reaches the
# shim, which renders the chat template and returns {prompt}. That makes LM
# Studio's BUILT-IN lmstudio/rag-v1 preprocessor work without patching app code.
echo "backend ext dir (GGUF/llama-server): $LLAMA_EXT_DIR"
mkdir -p "$LLAMA_EXT_DIR"

cat > "${LLAMA_EXT_DIR}/backend-manifest.json" <<'JSON'
{
  "name": "strata-linux-x86_64-vulkan-avx2",
  "domains": ["llm"],
  "version": "1.0.0",
  "engine": "llama.cpp",
  "target_libraries": [
    { "name": "llm_engine.node", "type": "llm_engine", "version": "0.1.2" },
    { "name": "liblmstudio_bindings.node", "type": "liblmstudio", "version": "0.2.26" }
  ],
  "platform": "linux",
  "cpu": { "architecture": "x86_64", "instruction_set_extensions": ["AVX2"] },
  "gpu": { "framework": "Vulkan" },
  "supported_model_formats": ["gguf"],
  "vendor_lib_package_names": ["linux-llama-vulkan-vendor-v1"],
  "manifest_version": "4",
  "extension_type": "engine",
  "minimum_lmstudio_version": "0.4.0+15",
  "minimum_llmster_version": "0.0.1+9",
  "engine_protocol_server": {
    "runtime_kind": "llama-server",
    "executable_relative_path": "strata-launch-llama"
  }
}
JSON

# Vendor the same donor .node closure into the llama ext dir (it is name-distinct
# from the built-in llama.cpp backend, so it WINS the gguf preference and routes
# GGUF loads to the shim).
cp "${DONOR}/${LIB_NAME}" "${LLAMA_EXT_DIR}/liblmstudio_bindings.node"
cp "${DONOR}/${ENG_NAME}" "${LLAMA_EXT_DIR}/llm_engine.node"
cp -a "${DONOR}"/*.so* "${LLAMA_EXT_DIR}/" 2>/dev/null || true
chmod +x "${LLAMA_EXT_DIR}/liblmstudio_bindings.node" "${LLAMA_EXT_DIR}/llm_engine.node"

# Both shims sit side-by-side in this ext dir, so strata-shim-llama's same-dir
# import of ./strata-shim resolves at deploy time (the split source layout's
# ../pt/strata-shim fallback is only for running the test from engines/gguf/).
cp "${REPO_DIR}/engines/pt/strata-shim" "${LLAMA_EXT_DIR}/strata-shim"
cp "${REPO_DIR}/engines/gguf/strata-shim-llama" "${LLAMA_EXT_DIR}/strata-shim-llama"
chmod +x "${LLAMA_EXT_DIR}/strata-shim" "${LLAMA_EXT_DIR}/strata-shim-llama"

cat > "${LLAMA_EXT_DIR}/strata-launch-llama" <<'LAUNCH'
#!/bin/bash
HERE=$(dirname "$0")
VER=$(sed -n 's/.*"version"[^:]*:[^"]*"\([^"]*\)".*/\1/p' "$HERE/backend-manifest.json" | head -1)
NAME="lm-studio-bridge-v${VER:-1.0.0}"
exec -a "$NAME" node "$HERE/strata-shim-llama" "$@"
LAUNCH
chmod +x "${LLAMA_EXT_DIR}/strata-launch-llama"

# ---------------------------------------------------------------------------
# Stub model dir (few KB of fake files; generated, never committed).
# ---------------------------------------------------------------------------
# GGUF stub — indexed so the llama-server ext has a gguf to advertise (and the
# built-in rag-v1 has a chatTemplate to apply). STRATA_STUB_GGUF_DIR points it at
# the models/local dir so it IS indexed (not just the project-local default).
STRATA_STUB_GGUF_DIR="$GGUF_MODEL_DIR" bash "${REPO_DIR}/scripts/make-stub-gguf.sh"

echo "GGUF route installed. Restart LM Studio to index it (backends scan runs at startup)."
echo "  GGUF stub dir: $GGUF_MODEL_DIR (served by strata-shim-llama via the llama-server ext)"
echo "  NOTE: while the GGUF ext is installed it HIJACKS the gguf preference, so ALL"
echo "        gguf loads (incl a real gemma-4-e4b) route to the shim, not real llama.cpp."
