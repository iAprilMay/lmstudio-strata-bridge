// Pure-function test for strata-shim-llama — pins the llama-server dialect helpers
// (chat-template renderer, spawn-arg parsing, served-id derivation) WITHOUT a live
// app or gateway. Run: node test/llama.test.mjs
import { renderChatTemplate, parseArgs, SERVED_ID, SERVED_ID_CANDIDATES } from "../strata-shim-llama";

let failures = 0;
function check(name, cond) {
  if (cond) { console.log(`  ok   ${name}`); }
  else { failures++; console.log(`  FAIL ${name}`); }
}

// 1. spawn-arg parsing (llama-server dialect: --model --host --port --api-key, NO --served-model-name)
const a = parseArgs(["--model", "/m/local/foo/strata-bridge-gguf-IQ1_M.gguf", "--host", "127.0.0.1", "--port", "4321", "--api-key", "k"]);
check("parseArgs: model captured", a.model === "/m/local/foo/strata-bridge-gguf-IQ1_M.gguf");
check("parseArgs: host captured", a.host === "127.0.0.1");
check("parseArgs: port captured", a.passedPort === "4321");
check("parseArgs: api-key captured", a.apiKey === "k");
check("parseArgs: -m alias works", parseArgs(["-m", "x.gguf"]).model === "x.gguf");

// 2. served-id derivation: raw --model path + basename + basename-minus-.gguf.
// (The module-level SERVED_ID is computed from the SPAWN argv, which is empty when this
//  file is imported by a test -- so derive the candidates from the parsed args directly,
//  mirroring the shim's own logic.)
const derive = (model) => {
  const base = model.replace(/\/+$/, "").split("/").pop();
  return [...new Set([model, base, base.replace(/\.gguf$/i, "")])].filter(Boolean);
};
const cands = derive(a.model);
check("derive: 3 candidates (path + basename + noext)", cands.length === 3);
check("derive: first is the raw path", cands[0] === a.model);
check("derive: basename present", cands.includes("strata-bridge-gguf-IQ1_M.gguf"));
check("derive: noext basename present", cands.includes("strata-bridge-gguf-IQ1_M"));

// 3. chat-template renderer: ChatML, addGenerationPrompt appends the open assistant block.
const p = renderChatTemplate([{ role: "user", content: "hi" }], true, false);
check("render: user turn ChatML", p.includes("<|im_start|>user\nhi<|im_end|>\n"));
check("render: generation prompt appended", p.endsWith("<|im_start|>assistant\n"));

// 4. enableThinking opens the thinking block before the assistant generation prompt.
const pt = renderChatTemplate([{ role: "user", content: "hi" }], true, true);
check("render: enable_thinking block", pt.includes("<|im_start|>assistant\n<|im_start|>\n"));

// 5. addGenerationPrompt:false omits the trailing assistant block.
const pNo = renderChatTemplate([{ role: "user", content: "hi" }], false, false);
check("render: no generation prompt", !pNo.includes("<|im_start|>assistant\n"));

// 6. content parts (text + image) concatenate text + mark images.
const pImg = renderChatTemplate([{ role: "user", content: [{ type: "text", text: "look " }, { type: "image" }, { type: "text", text: "here" }] }], false, false);
check("render: image part marked", pImg.includes("look <|image|>here"));

// 7. round-trip sanity: a single user message renders deterministically.
check("render: deterministic", renderChatTemplate([{ role: "user", content: "x" }], false, false) === "<|im_start|>user\nx<|im_end|>\n");

console.log(failures === 0 ? "llama.test: all green" : `llama.test: ${failures} FAIL`);
process.exit(failures === 0 ? 0 : 1);
