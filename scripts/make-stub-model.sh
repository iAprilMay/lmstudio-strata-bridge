#!/usr/bin/env bash
# Generate the stub torchSafetensors (PT) model dir LM Studio indexes so the vllm
# engine-extension route has a loadable model to advertise. Additive: writes
# ONLY under $LMSTUDIO_HOME/models/local/. Never touches ~/.strata or app files.
#
# Badge sources for a LOCAL torchSafetensors dir (the safetensors __metadata__ block
# does NOT feed the picker badges):
#   format badge   <- the model format (torchSafetensors -> "PT")
#   displayName    <- title-cased from the DIR NAME (trailing quant token stripped)
#   params badge   <- regex /(\d+(?:\.\d+)?)[mMbB]/ on the displayName (dir-name token)
#   quant superscript <- config.json "quantization" {bits,mode} (renders "Nbit"; the
#                        literal IQ3_S is a llama.cpp GGUF name, impossible on safetensors)
#   context badge  <- config.json max_position_embeddings (HF standard input key)
#   vision badge   <- config.json has a top-level "vision_config" key -> visionAdapter
#   reasoning badge<- chat_template.jinja / tokenizer_config.json contains "enable_thinking"
#   tool-use badge <- chat template carries the FULL qwen parser SIGNATURE (if tools,
#                     message.tool_calls, message.content, tool_call.function, <tool_call>,
#                     role/name/argument literals) -- a single marker is NOT enough
#   arch badge     <- config.json "model_type" (a valid safetensors zod key -> fills arch)
#
# Idempotent: re-running rewrites the same few-KB stubs.
set -euo pipefail

# Resolve the SAME LM Studio home the running app scans (honours ~/.lmstudio-home-pointer).
# shellcheck disable=SC1091
source "$(dirname "$0")/lmstudio-home.sh"

# The DIR NAME drives displayName + params. A `\d+[mMbB]` token (987b) is embedded so the
# params badge renders. dir `strata-bridge-987b` -> displayName "Strata Bridge 987B".
MODEL_DIR="${STRATA_STUB_MODEL_DIR:-${LMSTUDIO_HOME}/models/local/strata-bridge-987b}"

echo "stub model dir: $MODEL_DIR"
mkdir -p "$MODEL_DIR"

# Strata's OWN model id (native-tune lookup for vision + context), NOT the LM Studio key.
# Any Strata-served model is supported; this default is just a sample id.
STRATA_MODEL_ID="${STRATA_STUB_STRATA_ID:-iq3_s}"
QUANT_LABEL="${STRATA_STUB_QUANT:-FP32}"
# arch badge <- config.json model_type (valid safetensors zod key). quant badge <-
# config.json quantization {bits,mode}; int2 matches the int([2-8]) HF mode -> renders
# "Nbit", the closest honest label to a real GGUF quant (e.g. IQ3_S). The literal
# "IQ3_S" is a llama.cpp GGUF name and cannot render on the safetensors path.
ARCH_LABEL="${STRATA_STUB_ARCH:-qwen3}"
QUANT_BITS="${STRATA_STUB_QUANT_BITS:-32}"
QUANT_MODE="${STRATA_STUB_QUANT_MODE:-fp32}"

# ---- parse Strata native-tune for context + vision (dynamic, not hardcoded) ----
# Distinguish MISSING config (intentional -> use fallback, say so) from MALFORMED
# (JSON error -> warn loudly, do not silently claim a value). Prints the source used.
STRATA_HOME_DIR="${STRATA_HOME:-$HOME/.strata}"
read -r CTX VISION CTX_SRC VISION_SRC < <(python3 - "$STRATA_HOME_DIR" "$STRATA_MODEL_ID" <<'PY'
import sys, json, os
shome, sid = sys.argv[1:3]
p = f"{shome}/data/native-tune/{sid}.json"
if not os.path.exists(p):
    print("262144 true MISSING MISSING"); raise SystemExit
try:
    nt = json.load(open(p))
except Exception as e:
    sys.stderr.write(f"WARN native-tune {p} malformed: {e}\n")
    print("262144 true MALFORMED MALFORMED"); raise SystemExit
ctx = None
for i, a in enumerate(nt.get("args", [])):
    if a == "--max-context":
        try: ctx = int(nt["args"][i+1])
        except Exception: ctx = None
        break
if ctx is None or ctx <= 0:
    sys.stderr.write("WARN native-tune has no valid --max-context\n"); ctx = 262144; src = "FALLBACK"
else:
    src = "native-tune"
vision = bool(nt.get("ui_vision_enabled")) if "ui_vision_enabled" in nt else ("vision" in nt and bool(nt["vision"]))
print(f"{ctx} {str(vision).lower()} {src} {'native-tune' if ('ui_vision_enabled' in nt or 'vision' in nt) else 'MISSING-default-true'}")
PY
)
echo "context source: $CTX_SRC (ctx=$CTX) | vision source: $VISION_SRC (vision=$VISION)"

# hf_quant_config.json forces the torchSafetensors classification AND carries the
# quant SUPERSCRIPT badge (quant_algo). quant_method stays "generic" so the
# torchSafetensors classification is preserved (a quantization_config in config.json
# would push it to plain 'safetensors' -> mlx-llm, the wrong engine).
cat > "$MODEL_DIR/hf_quant_config.json" <<JSON
{
  "quant_method": "generic",
  "quant_algo": "${QUANT_LABEL}",
  "format": "safetensors",
  "version": 1
}
JSON

# A minimal *valid* safetensors file with ONE tiny tensor. A zero-tensor file is
# rejected by the indexer. One F32 scalar is the smallest valid model file. The
# __metadata__ block is kept ONLY as inert test metadata (it does NOT feed the
# picker badges — verified); the real badge sources are config.json + dir name +
# hf_quant_config.json + chat_template.jinja.
python3 - "$MODEL_DIR/model.safetensors" <<'PY'
import struct, json, sys
out = sys.argv[1]
header = {
    "__strata_stub__": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]},
    "__metadata__": {"quantization": "IQ1_M", "inert": "true"},
}
raw = json.dumps(header, separators=(",", ":")).encode("utf-8")
with open(out, "wb") as f:
    f.write(struct.pack("<Q", len(raw)))
    f.write(raw)
    f.write(struct.pack("<f", 0.0))
PY

# config.json (EXACT filename) is REQUIRED for the indexer to even consider the dir
# a model candidate (classify()'s safetensors branch is gated on a file named exactly
# config.json + a safetensors file). The configJson zod schema is STRICT: only a small
# key set validates. max_position_embeddings + vision_config validate; arch/architectures/
# parameters do NOT (adding them makes the WHOLE config.json fall back to defaults).
# So config.json stays MINIMAL: max_position_embeddings (context input key) + vision_config
# (only when vision enabled).
if [ "$VISION" = "true" ]; then
  VISION_JSON=',
  "vision_config": { "hidden_size": 4096, "num_attention_heads": 16, "num_hidden_layers": 27 }'
else
  VISION_JSON=''
fi
cat > "$MODEL_DIR/config.json" <<JSON
{
  "max_position_embeddings": ${CTX},
  "model_type": "${ARCH_LABEL}",
  "quantization": { "bits": ${QUANT_BITS}, "mode": "${QUANT_MODE}" }${VISION_JSON}
}
JSON

# chat_template.jinja (or tokenizer_config.json chat_template) carries the reasoning
# (enable_thinking) + tool-use (recognized tool-call grammar) badges. Use a COMPLETE
# marker grammar (Gemma-style <|tool_call|> / <|tool_response|>, no malformed close).
# Qwen3-style Jinja template carrying the FULL qwen tool-use parser signature (the
# detector matches these literals, NOT a single marker) + enable_thinking (reasoning).
# Render-safe for the summary path: tools block uses the loop var, content is null-guarded
# with `is not none` (minja-safe), so applyPromptTemplate never throws.
cat > "$MODEL_DIR/chat_template.jinja" <<'JINJA'
{%- if tools %}
{%- for tool_call in tools %}
{{ tool_call.function.name }}: {{ tool_call.function.description }}
{%- endfor %}
{%- endif %}
{%- for message in messages %}
{{ message.role }}
{%- if message.content is not none %}
{%- if message.content is string %}{{ message.content }}{%- else %}{%- for part in message.content %}{{ part.text }}{%- endfor %}{%- endif %}
{%- endif %}
{%- if message.role == 'assistant' and message.tool_calls %}
{%- for tool_call in message.tool_calls %}
<tool_call>{{ tool_call.name }}{{ tool_call.arguments }}</tool_call>
{%- endfor %}
{%- endif %}
{%- if message.role == 'tool' %}{{ message.content }}{%- endif %}
{%- endfor %}
{%- if enable_thinking %}<think>{%- endif %}
JINJA

echo "wrote: $MODEL_DIR/model.safetensors (1 tensor, valid header)"
echo "wrote: $MODEL_DIR/hf_quant_config.json (quant_algo -> quant badge; forces torchSafetensors)"
echo "wrote: $MODEL_DIR/config.json (max_position_embeddings -> ctx; model_type -> arch; vision_config -> vision if enabled)"
echo "wrote: $MODEL_DIR/chat_template.jinja (enable_thinking -> reasoning; qwen tool-call signature -> tool-use)"
echo "done. arch badge now filled from config.json model_type (was '??' before)."
