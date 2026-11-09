#!/usr/bin/env bash
# pick-donor.sh — shared donor picker, sourced by install-pt.sh / install-gguf.sh.
#
# Picks a llama.cpp donor dir whose liblmstudio bindings can survey THIS box's GPU.
# The vLLM driver's "requires at least one enabled GPU" guard (and its deviceUUID
# check) runs against the vendored bindings, so the donor MUST be a GPU-enabled
# build. The GPU frameworks map to vendors: CUDA = NVIDIA, ROCm = AMD, Vulkan =
# cross-vendor (works on AMD/Intel/other, incl. this box's AMD via radv). Vulkan is
# tried first, then CUDA, then ROCm -- see the deviceUUID note below -- falling
# back to the plain CPU avx2 build only if no GPU build exists.
#
# Sets: DONOR (dir), DONOR_KIND (vulkan|cuda|rocm|cpu), LIB_NAME, ENG_NAME (the donor
# .node filenames to copy). Aborts (exit 1) if no donor exists.
#
# Assumes nothing — resolves LMSTUDIO_HOME itself.
source "$(dirname "$0")/lmstudio-home.sh"

pick_donor() {
  local want="$1"
  # prefer the HIGHEST version donor (sort -V, take last) to match the app's llama.cpp
  local chosen=""
  for d in "${LMSTUDIO_HOME}"/extensions/backends/llama.cpp-linux-x86_64-*"${want}"*-avx2-*; do
    [ -e "${d}/liblmstudio_bindings_${want}.node" ] && [ -e "${d}/llm_engine_${want}.node" ] && chosen="$d"
  done
  [ -n "$chosen" ] && { echo "$chosen"; return 0; }
  return 1
}

# The vLLM driver requires the selected GPU to report gpu.otherInfo.deviceUUID (a
# CUDA-style device UUID). On AMD/radv only the VULKAN bindings survey reports
# deviceUUID (ROCm reports only gcnArchName -> vLLM throws "Selected vLLM GPU 0
# does not report a CUDA device UUID"). So prefer vulkan, then cuda, then rocm.
DONOR=""; DONOR_KIND=""
for want in vulkan cuda rocm; do
  if DONOR="$(pick_donor "$want")" && [ -n "$DONOR" ]; then DONOR_KIND="$want"; break; fi
done
if [ -z "$DONOR" ]; then
  for d in "${LMSTUDIO_HOME}"/extensions/backends/llama.cpp-linux-x86_64-avx2-*; do
    [ -e "${d}/liblmstudio_bindings.node" ] && [ -e "${d}/llm_engine.node" ] && DONOR="$d" && DONOR_KIND="cpu" && break
  done
fi
if [ -z "$DONOR" ]; then
  echo "no donor .node dir found — cannot vendor the .node closure." >&2
  exit 1
fi

# The donor .node filenames to copy (vendor-prefixed for GPU builds, plain for CPU).
if [ "$DONOR_KIND" = "cpu" ]; then
  LIB_NAME="liblmstudio_bindings.node"; ENG_NAME="llm_engine.node"
else
  LIB_NAME="liblmstudio_bindings_${DONOR_KIND}.node"; ENG_NAME="llm_engine_${DONOR_KIND}.node"
fi

echo "donor: $DONOR (kind=$DONOR_KIND)"
