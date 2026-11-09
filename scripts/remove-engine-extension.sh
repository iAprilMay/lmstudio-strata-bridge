#!/usr/bin/env bash
# Rollback: remove the Strata engine-extension routes + stub model dirs that
# install.sh created. Deletes ONLY the bridge's dirs — never an app
# file, never ~/.strata, never the bridge's engine extensions. Safe even while LM Studio is
# live (the backends scan simply stops seeing them on the next restart).
#
# Refuses to run unless --force is passed, so a bare invocation is a no-op guard.
#
# Usage:
#   scripts/remove-engine-extension.sh --force
set -euo pipefail

# Resolve LM Studio home the same way the app/CLI does (honour the home pointer).
# Shared resolver so install / remove / make-stub-* all target one home.
# shellcheck disable=SC1091
source "$(dirname "$0")/lmstudio-home.sh"

if [ "${1:-}" != "--force" ]; then
  echo "Refusing to remove anything. Pass --force to remove anyway (deletes only the bridge's dirs, safe even while live)." >&2
  [ "${1:-}" = "--force" ] || exit 1
fi

# Current install (both routes; full-pattern engine names so LM Studio prettifies them).
EXT_DIR="${LMSTUDIO_HOME}/extensions/backends/strata-linux-x86_64-avx2-1.0.0"
LLAMA_EXT_DIR="${LMSTUDIO_HOME}/extensions/backends/strata-linux-x86_64-vulkan-avx2-1.0.0"

# Stub model dirs.
PT_MODEL_DIR="${LMSTUDIO_HOME}/models/local/strata-bridge-987b"
GGUF_MODEL_DIR="${LMSTUDIO_HOME}/models/local/strata-bridge-gguf"

removed=0
for dir in "$EXT_DIR" "$LLAMA_EXT_DIR" "$PT_MODEL_DIR" "$GGUF_MODEL_DIR"; do
  if [ -d "$dir" ]; then
    rm -rf -- "$dir"
    echo "removed: $dir"
    removed=1
  else
    echo "not present: $dir"
  fi
done

# Drop the now-empty models/local parent if it exists and is empty.
[ -d "${LMSTUDIO_HOME}/models/local" ] && rmdir "${LMSTUDIO_HOME}/models/local" 2>/dev/null || true

echo "rollback done (removed=$removed). Only the bridge's own dirs are removed; Strata is untouched."
