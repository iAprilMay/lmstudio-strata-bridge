#!/usr/bin/env bash
# install-pt.sh — install ONLY the PT / vllm route (strata-linux 1.0.0) + its stub model.
#
# Additive only: creates the backend extension dir (manifest + self-contained vendored
# .node/.so copied from the app's own llama.cpp donor) and the PT stub model dir. It
# never patches/swaps/replaces an app file, never touches ~/.strata, never loads weights.
# Idempotent.
#
# The PT route keeps LM Studio's ORIGINAL backend selection (CPU/Vulkan/CUDA/ROCm) and
# loads the Strata shim fast, without you touching runtime settings each time.
#
# Usage:
#   scripts/install-pt.sh
#
# After installing, LM Studio must be RESTARTED for the backends scan to index it.
set -euo pipefail

# Shared donor picker (also resolves LMSTUDIO_HOME; sets DONOR/DONOR_KIND/LIB_NAME/ENG_NAME).
source "$(dirname "$0")/pick-donor.sh"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXT_NAME="strata-linux-x86_64-avx2-1.0.0"
EXT_DIR="${LMSTUDIO_HOME}/extensions/backends/${EXT_NAME}"
PT_MODEL_DIR="${LMSTUDIO_HOME}/models/local/strata-bridge-987b"

# ---------------------------------------------------------------------------
# Route — PT / vllm (strata-linux 1.0.0)
# ---------------------------------------------------------------------------
echo "backend ext dir (PT/vllm): $EXT_DIR"
mkdir -p "$EXT_DIR"

# Manifest (original file). NO description/title key — the backend manifest
# zod schema is strict and rejects extra keys; the description ("Bridge to
# strata engine") lives in the README, not here.
cat > "${EXT_DIR}/backend-manifest.json" <<'JSON'
{
  "name": "strata-linux-x86_64-avx2",
  "domains": ["llm"],
  "version": "1.0.0",
  "engine": "vllm",
  "target_libraries": [
    { "name": "llm_engine.node", "type": "llm_engine", "version": "0.1.2" },
    { "name": "liblmstudio_bindings.node", "type": "liblmstudio", "version": "0.2.26" }
  ],
  "platform": "linux",
  "cpu": { "architecture": "x86_64", "instruction_set_extensions": ["AVX2"] },
  "supported_model_formats": ["torchSafetensors"],
  "manifest_version": "4",
  "extension_type": "engine",
  "minimum_lmstudio_version": "0.4.0+15",
  "minimum_llmster_version": "0.0.1+9",
  "engine_protocol_server": {
    "runtime_kind": "vllm",
    "executable_relative_path": "strata-launch"
  }
}
JSON

# Vendor the donor .node closure (renamed to the manifest target_libraries names)
# + every .so the two .node files transitively need, so $ORIGIN RUNPATH resolves.
cp "${DONOR}/${LIB_NAME}" "${EXT_DIR}/liblmstudio_bindings.node"
cp "${DONOR}/${ENG_NAME}" "${EXT_DIR}/llm_engine.node"
cp -a "${DONOR}"/*.so* "${EXT_DIR}/" 2>/dev/null || true
chmod +x "${EXT_DIR}/liblmstudio_bindings.node" "${EXT_DIR}/llm_engine.node"

# Shim (copying original code is fine; only app binaries are never vendored).
cp "${REPO_DIR}/engines/pt/strata-shim" "${EXT_DIR}/strata-shim"
chmod +x "${EXT_DIR}/strata-shim"

# Launcher wrapper: LM Studio's activity feed labels each request with the engine
# process's SPAWN-TIME argv[0]. A `#!/usr/bin/env node` script gets argv[0]="node"
# (the shebang interpreter), which the shim's later process.title cannot change.
# This wrapper exec -a's the bridge name so argv[0] (and comm) are correct AT spawn.
cat > "${EXT_DIR}/strata-launch" <<'LAUNCH'
#!/bin/bash
HERE=$(dirname "$0")
VER=$(sed -n 's/.*"version"[^:]*:[^"]*"\([^"]*\)".*/\1/p' "$HERE/backend-manifest.json" | head -1)
NAME="lm-studio-bridge-v${VER:-1.0.0}"
exec -a "$NAME" node "$HERE/strata-shim" "$@"
LAUNCH
chmod +x "${EXT_DIR}/strata-launch"

# ---------------------------------------------------------------------------
# Stub model dir (few KB of fake files; generated, never committed).
# ---------------------------------------------------------------------------
STRATA_STUB_MODEL_DIR="$PT_MODEL_DIR" bash "${REPO_DIR}/scripts/make-stub-model.sh"

echo "PT route installed. Restart LM Studio to index it (backends scan runs at startup)."
echo "  PT stub dir: $PT_MODEL_DIR  (served by strata-shim via the vllm ext)"
