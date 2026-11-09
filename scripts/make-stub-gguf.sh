#!/usr/bin/env bash
# Generate a FAKE GGUF model dir so LM Studio indexes a GGUF and shows the metadata
# badges (arch / params / context / quant / tool-use / reasoning / vision) that the
# safetensors stub could NOT advertise. Those badges are what gate LM Studio's built-in
# Reasoning / vision / tool-use dropdowns.
#
# Additive: writes ONLY under ~/.lmstudio/models/local/. Never touches ~/.strata or app
# files. Idempotent: re-running rewrites the same few-KB stubs.
#
# WHY GGUF: the indexer derives badges from the GGUF HEADER (confirmed against the
# model-index-cache for the real Gemma GGUFs):
#   arch badge        <- general.architecture (known enum: qwen3, gemma4, ...)
#   displayName       <- general.name (title-cased)
#   context badge     <- <arch>.context_length (e.g. qwen3.context_length)
#   params badge      <- SUM over tensors of PRODUCT(shape) (same shape trick as safetensors)
#   quant superscript <- parsed from the FILENAME token (...-IQ3_S.gguf -> IQ3_S)
#   tool-use badge    <- chat_template carries the FULL qwen parser SIGNATURE (the GGUF
#                        branch uses the SAME isTrainedForToolUse detector as PT: if tools,
#                        message.tool_calls, message.content, tool_call.function, <tool_call>,
#                        role/name/argument literals) -- a single marker is NOT enough
#   reasoning badge   <- chat_template references enable_thinking (bundle: "thinking for
#                        chat templates that support enable_thinking")
#   vision badge      <- an mmproj COMPANION file present (a second *.gguf named *mmproj*)
#
# The dynamic values are PARSED from Strata at runtime (no hardcoding): context from
# ~/.strata/data/native-tune/<id>.json (--max-context), vision from ui_vision_enabled.
# arch/params/quant are not in Strata native-tune -> env-overridable. Any Strata
# model is supported (the bridge reads the served id at runtime); defaults here
# are just a sample (iq3_s).
set -euo pipefail

# Resolve the SAME LM Studio home the running app scans (honours ~/.lmstudio-home-pointer),
# so install / remove / make-stub-* all target one home.
# shellcheck disable=SC1091
source "$(dirname "$0")/lmstudio-home.sh"

# The GGUF FILENAME drives displayName + quant superscript. The reported model NAME is
# "Strata Bridge", so the basename is that + a quant token (e.g. IQ3_S; filename token ->
# quant badge). The dir name is the model container.
#
# ABANDONED 2026-11-04: the GGUF route is no longer installed into LM Studio (it collides
# with the built-in llama.cpp backend on load and indexes a stray "Mmproj" row). The GGUF
# stub + its output are KEPT in the PROJECT (so it can be revisited later) but written to a
# project-local dir, NOT ~/.lmstudio/models/local/, so it is never indexed. Override via
# STRATA_STUB_GGUF_DIR to place it under models/local if you want to bake it off again.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# MODEL_DIR is an OUTPUT dir (the stubs are generated here, never read from it).
# A bare run writes to a throwaway project-local dir so it never touches the app;
# install.sh overrides this with STRATA_STUB_GGUF_DIR to index it.
MODEL_DIR="${STRATA_STUB_GGUF_DIR:-${REPO_DIR}/.generated/gguf-stub}"
GGUF_NAME="${STRATA_STUB_GGUF_NAME:-strata-bridge-FP32.gguf}"
# The mmproj COMPANION must carry the literal "mmproj-" PREFIX to PAIR with the main GGUF.
# LM Studio's vision-companion detector matches files whose basename INCLUDES "mmproj-"
# (token "mmproj" + a HYPHEN AFTER it). A suffix form ("...-mmproj.gguf") has "mmproj."
# (a dot) -> NOT matched -> the mmproj indexes as a SEPARATE "... Mmproj" model row (the
# bug seen in the picker). So name it mmproj-<main-basename>.gguf (same form real Gemma uses).
MMPROJ_NAME="${STRATA_STUB_MMPROJ_NAME:-mmproj-${GGUF_NAME%.gguf}.gguf}"

# Strata's OWN model id (native-tune lookup for vision + context), NOT the LM Studio key.
STRATA_MODEL_ID="${STRATA_STUB_STRATA_ID:-iq3_s}"
ARCH_LABEL="${STRATA_STUB_ARCH:-qwen3}"
PARAMS_LABEL="${STRATA_STUB_PARAMS:-987B}"
QUANT_LABEL="${STRATA_STUB_QUANT:-FP32}"
# Param shape product = real param count (987e9 -> "987B"), data stays tiny.
PARAM_SHAPE="${STRATA_STUB_PARAM_SHAPE:-987,1000,1000,1000}"

echo "stub GGUF dir: $MODEL_DIR"
mkdir -p "$MODEL_DIR"

STRATA_HOME_DIR="${STRATA_HOME:-$HOME/.strata}"

python3 - "$MODEL_DIR/$GGUF_NAME" "$MODEL_DIR/$MMPROJ_NAME" "$STRATA_HOME_DIR" "$STRATA_MODEL_ID" "$ARCH_LABEL" "$PARAMS_LABEL" "$QUANT_LABEL" "$PARAM_SHAPE" <<'PY'
import sys, struct, json, os
gguf_path, mmproj_path, shome, strata_id, arch, params, quant, shape_str = sys.argv[1:9]

# ---- parse Strata native-tune for context + vision (dynamic, not hardcoded) ----
# Distinguish MISSING config (intentional -> fallback, say so) from MALFORMED (JSON error
# -> warn loudly, do not silently claim a value). Print the source used for each value.
nt_path = f"{shome}/data/native-tune/{strata_id}.json"
ctx = None
vision = False
ctx_src = vision_src = "MISSING-default"
if not os.path.exists(nt_path):
    ctx, vision = 262144, True  # intentional fallback
else:
    try:
        nt = json.load(open(nt_path))
    except Exception as e:
        sys.stderr.write(f"WARN native-tune {nt_path} malformed: {e}\n")
        ctx, vision = 262144, True  # fallback but flagged
    else:
        vision = bool(nt.get("ui_vision_enabled")) if ("ui_vision_enabled" in nt) else ("vision" in nt and bool(nt["vision"]))
        vision_src = "native-tune" if ("ui_vision_enabled" in nt or "vision" in nt) else "MISSING-default-true"
        for i, a in enumerate(nt.get("args", [])):
            if a == "--max-context":
                try: ctx = int(nt["args"][i + 1])
                except Exception: ctx = None
                break
        if ctx is None or ctx <= 0:
            sys.stderr.write("WARN native-tune has no valid --max-context\n")
            ctx = 262144
        else:
            ctx_src = "native-tune"

# ---- GGUF primitives ----
def w_str(s):
    b = s.encode("utf-8")
    return struct.pack("<Q", len(b)) + b

# LM Studio's GGUF reader uses a 4-BYTE (u32) TYPE FIELD per KV pair, NOT the standard
# 1-byte gguf type. Verified by parsing a real Gemma GGUF on disk: general.architecture's
# type field is 08 00 00 00 (u32 8). Value-type codes: STRING=8, UINT32=4, BOOL=9.
def kv_str(k, v):
    return w_str(k) + struct.pack("<I", 8) + w_str(v)   # 8 = string type

def kv_u32(k, v):
    return w_str(k) + struct.pack("<I", 4) + struct.pack("<I", v)  # 4 = uint32

def kv_bool(k, v):
    return w_str(k) + struct.pack("<I", 9) + struct.pack("<B", 1 if v else 0)  # 9 = bool

# chat_template: include BOTH a tool-call grammar (tool-use badge) AND enable_thinking
# (reasoning badge). The real Gemma GGUF uses Gemma-style markers <|tool_call|> / <|tool_response|>
# (NOT <tool_call>) -- the indexer's tool-use detector greps for those. Keep enable_thinking for
# the reasoning hint. Kept short but Jinja-ish; the indexer only greps for markers.
# Qwen3-style Jinja template carrying the FULL qwen tool-use parser signature (the GGUF
# branch uses the SAME isTrainedForToolUse detector as PT) + enable_thinking (reasoning).
# Render-safe for the summary path (tools block uses the loop var, content null-guarded).
chat_template = (
    "{%- if tools %}{%- for tool_call in tools %}"
    "{{ tool_call.function.name }}: {{ tool_call.function.description }}"
    "{%- endfor %}{%- endif %}"
    "{%- for message in messages %}"
    "{{ message.role }}"
    "{%- if message.content is not none %}"
    "{%- if message.content is string %}{{ message.content }}"
    "{%- else %}{%- for part in message.content %}{{ part.text }}{%- endfor %}{%- endif %}"
    "{%- endif %}"
    "{%- if message.role == 'assistant' and message.tool_calls %}"
    "{%- for tool_call in message.tool_calls %}"
    "<tool_call>{{ tool_call.name }}{{ tool_call.arguments }}</tool_call>"
    "{%- endfor %}{%- endif %}"
    "{%- if message.role == 'tool' %}{{ message.content }}{%- endif %}"
    "{%- endfor %}"
    "{%- if enable_thinking %}<think>{%- endif %}"
)

# ---- main GGUF: metadata + ONE tiny consistent tensor ----
# The params badge comes from general.size_label (confirmed on the real Gemma GGUF: it carries
# general.size_label = "7.5B"), NOT from tensor shapes. So the tensor can be a single [1] F32
# (offset 0, 4 bytes) -> the file stays internally consistent (no huge-shape data-bounds reject).
n_tensors = 1
# KV metadata (order: general.*, <arch>.*, tokenizer.*, chat_template)
kv_pairs = []
kv_pairs.append(kv_str("general.architecture", arch))
kv_pairs.append(kv_str("general.name", "Strata Bridge"))
kv_pairs.append(kv_str("general.type", "model"))
kv_pairs.append(kv_str("general.file_type", quant))          # quant hint (filename is primary)
kv_pairs.append(kv_str("general.size_label", params))        # params badge (e.g. "987B")
kv_pairs.append(kv_u32(f"{arch}.block_count", 1))
kv_pairs.append(kv_u32(f"{arch}.context_length", ctx))       # context badge
kv_pairs.append(kv_u32(f"{arch}.embedding_length", 8))
kv_pairs.append(kv_u32(f"{arch}.feed_forward_length", 32))
# llama.cpp qwen3 arch key names (the real Gemma GGUF used gemma4.attention.head_count etc.)
kv_pairs.append(kv_u32(f"{arch}.attention.head_count", 8))
kv_pairs.append(kv_u32(f"{arch}.attention.head_count_kv", 8))
kv_pairs.append(kv_str("tokenizer.ggml.model", "gpt2"))
# The real Gemma GGUF uses the llama.cpp key `tokenizer.chat_template` (NOT `llm.chat_template`).
# The indexer extracts chatTemplate from this key and derives tool-use (tool-call grammar) +
# reasoning (enable_thinking) badges from it.
kv_pairs.append(kv_str("tokenizer.chat_template", chat_template))  # tool-use + reasoning badges
kv_blob = b"".join(kv_pairs)

# tensor info: name, n_dims, dims[], dtype(F32=0), offset -- minimal [1] F32, internally consistent
tname = "token_embd.weight"
dtype = 0  # F32
tdims = [1]
tensor_info = w_str(tname) + struct.pack("<I", len(tdims)) + b"".join(struct.pack("<Q", d) for d in tdims) + struct.pack("<I", dtype) + struct.pack("<Q", 0)

header = b"GGUF" + struct.pack("<I", 3) + struct.pack("<Q", n_tensors) + struct.pack("<Q", len(kv_pairs)) + kv_blob + tensor_info
# tensor data: 4 bytes (one F32) at offset 0 -> matches the [1] F32 tensor.
data = struct.pack("<f", 0.0)
with open(gguf_path, "wb") as f:
    f.write(header + data)

# ---- mmproj companion (vision badge): ONLY when vision is enabled ----
# The indexer pairs an mmproj to the GGUF whose basename equals the mmproj minus "-mmproj"
# and sets visionAdapter iff that companion exists. A zero-tensor clip header is a METADATA
# stub (it advertises the vision badge; it is NOT a working image projector). Do NOT emit it
# when Strata reports vision disabled -- otherwise a vision badge is advertised that the model cannot serve.
if vision:
    mm_kv = kv_str("general.architecture", "clip") + kv_str("general.name", "Strata Bridge vision")
    mm_header = b"GGUF" + struct.pack("<I", 3) + struct.pack("<Q", 0) + struct.pack("<Q", 2) + mm_kv
    with open(mmproj_path, "wb") as f:
        f.write(mm_header)
else:
    # Remove a stale companion from a previous run so it does not index as a phantom vision model.
    try:
        os.remove(mmproj_path)
    except FileNotFoundError:
        pass

print(f"GGUF: arch={arch} ctx={ctx} (ctx_src={ctx_src}) size_label={params} quant={quant} vision={vision} (vision_src={vision_src})")
PY

echo "wrote: $MODEL_DIR/$GGUF_NAME (fake GGUF: arch/params/ctx/quant/tool/reasoning metadata)"
echo "wrote: $MODEL_DIR/$MMPROJ_NAME (mmproj companion -> vision badge)"
echo "done."
