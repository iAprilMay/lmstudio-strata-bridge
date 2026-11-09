# Metadata badges

LM Studio derives picker badges (arch / params / context / quant / tool-use /
reasoning / vision) from the **indexed model representation on disk**, not
from a loaded instance. So badges render from the stub model dir regardless of
whether the model loads. The two routes fill the badges differently.

## PT (torchSafetensors) — `engines/pt/`

The PT stub dir is named with a `-987b` token and carries a `config.json` +
`chat_template.jinja`. Badges come from:

| Badge | Source on the PT path |
| --- | --- |
| format | `torchSafetensors` |
| arch | `config.json` top-level `model_type` (e.g. `qwen3`) |
| params | the `\d+[mMbB]` token in the dir name (e.g. `-987b` → `987B`) |
| quant | `config.json` `quantization` = `{bits,mode}` |
| context | `config.json` `max_position_embeddings` |
| vision | top-level `vision_config` in `config.json` |
| reasoning | `chat_template.jinja` referencing `enable_thinking` |
| tool-use | `chat_template.jinja` with the full tool-call signature |

## GGUF — `engines/gguf/`

The GGUF stub carries the badges in the GGUF header + filename:

| Badge | Source on the GGUF path |
| --- | --- |
| format | `gguf` |
| arch | `general.architecture` |
| params | `general.size_label` |
| quant | parsed from the **filename** token (e.g. `...-IQ3_S.gguf` → `IQ3_S`) |
| context | `<arch>.context_length` |
| vision | a paired `mmproj-<basename>.gguf` companion (see note below) |
| reasoning | `tokenizer.chat_template` referencing `enable_thinking` |
| tool-use | `tokenizer.chat_template` tool-call grammar |

The `mmproj-` **prefix** (not a suffix) is what pairs the companion as the
main model's vision adapter.

## Why the GGUF quant can show the real quant name

The quant superscript is a llama.cpp GGUF quant name (e.g. `IQ3_S`). The GGUF
path renders it verbatim from the filename; the safetensors path has no such
name in its fixed HF-mode recognizer, so its closest honest label is `Nbit`.
The GGUF route is the one that shows the true quant name.

## Any Strata model is supported

The bridge discovers the served model id from the gateway at runtime, so it
works with **any** model Strata is serving — not one fixed model. Tested with
`IQ3_S` and `IQ1_M`; Strata's catalog has many more (sizes and quants), and
the bridge adapts to whichever one is live.

## Caveat

While the GGUF extension is installed it **hijacks the gguf preference**, so all
`gguf` loads (including a real GGUF model) route to the bridge shim rather than
real llama.cpp. Remove it (`scripts/remove-engine-extension.sh --force`) to
restore native llama.cpp for GGUF models.
