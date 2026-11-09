#!/usr/bin/env bash
# install.sh — main entry point: choose which bridge route(s) to install.
#
# Offers three choices:
#   1) GGUF  — install the GGUF / llama-server extension + its stub model. Lets LM
#       Studio's BUILT-IN plugins (rag-v1 "Chat with Files") work.
#   2) PT    — install the PT / vllm extension + its stub model. Keeps LM Studio's
#       ORIGINAL backend (CPU/Vulkan/CUDA/ROCm) and loads the Strata shim fast.
#   3) both  — install both routes + both stub models.
#
# Additive only; never patches an app file, never touches ~/.strata, never loads
# weights. Restart LM Studio after installing to index the new extensions.
#
# Usage:
#   scripts/install.sh              # interactive: asks which to install
#   scripts/install.sh pt           # non-interactive
#   scripts/install.sh gguf
#   scripts/install.sh both
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

choice="${1:-}"
if [ -z "$choice" ]; then
  echo "Which bridge route do you want to install?"
  echo "  1) GGUF  — built-in plugins (rag-v1 / Chat with Files) work"
  echo "  2) PT    — keep original backend (CPU/Vulkan/CUDA/ROCm), fast load"
  echo "  3) both  — install both routes"
  printf "Choose [1/2/3] (default 3): "
  read -r choice
fi

case "$choice" in
  1|gguf)
    echo "-> installing GGUF route"
    bash "${HERE}/install-gguf.sh"
    ;;
  2|pt)
    echo "-> installing PT route"
    bash "${HERE}/install-pt.sh"
    ;;
  3|both|"")
    echo "-> installing both routes"
    bash "${HERE}/install-pt.sh"
    bash "${HERE}/install-gguf.sh"
    ;;
  *)
    echo "unrecognized choice: $choice (use 1/2/3 or pt/gguf/both)" >&2
    exit 1
    ;;
esac

echo "Done. Restart LM Studio to index the new extensions (backends scan runs at startup)."
