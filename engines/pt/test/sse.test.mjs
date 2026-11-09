// SSE-mapping test for strata-shim — pins the reasoning-preservation and
// dialect re-shaping behaviour without a live app or gateway. Run: node test/sse.test.mjs
import { reshapeEvent, rewriteEvent, tokenize, detokenize, MAX_MODEL_LEN, aggregateEvents, stripSseComments, injectMetrics, buildMetrics, eventHasDelta, eventFinishReason, eventHasUsage, eventTimings } from "../strata-shim";

let failures = 0;
function check(name, cond) {
  if (cond) { console.log(`  ok   ${name}`); }
  else { failures++; console.log(`  FAIL ${name}`); }
}

// A representative gateway chat chunk carrying reasoning_content.
const chatChunk = 'data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{"reasoning_content":"think"},"finish_reason":null}]}';

// 1. chat path: reasoning_content preserved, model rewritten to served name.
const chatOut = rewriteEvent(chatChunk, "served-ref");
check("chat: reasoning_content preserved", chatOut.includes('"reasoning_content":"think"'));
check("chat: model rewritten to served name", chatOut.includes('"model":"served-ref"'));
check("chat: object stays chat.completion.chunk", chatOut.includes('"object":"chat.completion.chunk"'));

// 2. completions path: re-shaped into the completions dialect, reasoning kept.
const compOut = reshapeEvent(chatChunk, "served-ref", true);
check("completions: object is completions", compOut.includes('"object":"completions"'));
check("completions: reasoning_content preserved", compOut.includes('"reasoning_content":"think"'));
check("completions: model is served name", compOut.includes('"model":"served-ref"'));
check("completions: no delta field leaked", !compOut.includes('"delta"'));

// 3. [DONE] and comment lines pass through unchanged.
check("[DONE] passthrough", rewriteEvent("data: [DONE]", "x") === "data: [DONE]");
check("keep-alive comment passthrough", rewriteEvent(": keep-alive", "x") === ": keep-alive");

// 4. tokenizer round-trips (used only to size the raw path).
const s = "hello 世界";
check("tokenize/detokenize round-trip", detokenize(tokenize(s)) === s);
// With no CLI args the shim falls back to the small fast-load default (not the
// full 262144), so the readiness AutoFit probe + warmup stay small and the fake
// load finishes in seconds.
check("max_model_len reported (real Strata ctx when auto/absent)", MAX_MODEL_LEN === 262144);

// 5. tool_calls: fragmented streaming deltas reassemble into message.tool_calls[].
const toolEvents = [
  'data: {"id":"t1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"calculator","arguments":""}}]},"finish_reason":null}]}',
  'data: {"id":"t1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"expression\\":"}}]},"finish_reason":null}]}',
  'data: {"id":"t1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"21 * 2\\"}"}}]},"finish_reason":null}]}',
  'data: {"id":"t1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
];
const agg = aggregateEvents(toolEvents, "served-ref", false);
const msg = agg.choices?.[0]?.message;
const tc = msg?.tool_calls;
check("tool_calls: present in aggregated message", Array.isArray(tc) && tc.length === 1);
check("tool_calls: id preserved", tc?.[0]?.id === "call_1");
check("tool_calls: function name preserved", tc?.[0]?.function?.name === "calculator");
check("tool_calls: arguments concatenated", tc?.[0]?.function?.arguments === '{"expression":"21 * 2"}');
check("tool_calls: finish_reason is tool_calls", agg.choices?.[0]?.finish_reason === "tool_calls");

// 6. multiple parallel tool_calls (Bionic emits several run_command calls at once),
//    interleaved with a preamble content delta. Must reassemble each by index.
const multiEvents = [
  'data: {"id":"m1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{"role":"assistant","content":"I will run things.","tool_calls":[{"index":0,"id":"c0","type":"function","function":{"name":"run_command","arguments":""}}]},"finish_reason":null}]}',
  'data: {"id":"m1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"uname\\"}"}}]},"finish_reason":null}]}',
  'data: {"id":"m1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"c1","type":"function","function":{"name":"run_command","arguments":"{\\"command\\":\\"free\\"}"}}]},"finish_reason":null}]}',
  'data: {"id":"m1","object":"chat.completion.chunk","created":1,"model":"coder-iq1_m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
];
const agg2 = aggregateEvents(multiEvents, "served-ref", false);
const msg2 = agg2.choices?.[0]?.message;
const tc2 = msg2?.tool_calls;
check("multi tool_calls: two calls present", Array.isArray(tc2) && tc2.length === 2);
check("multi tool_calls: ids distinct", tc2?.[0]?.id === "c0" && tc2?.[1]?.id === "c1");
check("multi tool_calls: args valid JSON each", (() => { try { JSON.parse(tc2?.[0]?.function?.arguments); JSON.parse(tc2?.[1]?.function?.arguments); return true; } catch { return false; } })());
check("multi tool_calls: preamble content kept", msg2?.content === "I will run things.");

// 7. SSE comment lines (": keep-alive") stripped so the stream matches a native
//    engine's framing (the remote peer's RPC parser rejects comment lines -> teardown).
const withComments = ': keep-alive\ndata: {"a":1}\n\n: keep-alive\ndata: {"b":2}';
const stripped = stripSseComments(withComments);
check("stripSseComments: no comment lines remain", !stripped.split("\n").some((l) => l.startsWith(":")));
check("stripSseComments: data lines preserved", stripped.includes('data: {"a":1}') && stripped.includes('data: {"b":2}'));
// 8. tokens/sec metrics: buildMetrics synthesizes the vLLM metrics object from real
//    timing; injectMetrics attaches it to the final chunk's data payload.
const m = buildMetrics(1000, 1100, 1600, 6); // ttfb=100ms, gen=500ms, 5 gaps -> mean_itl=100
check("buildMetrics: time_to_first_token_ms", m.time_to_first_token_ms === 100);
check("buildMetrics: generation_time_ms", m.generation_time_ms === 500);
check("buildMetrics: mean_itl_ms", m.mean_itl_ms === 100);
const finalChunk = 'data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}';
const withMetrics = injectMetrics(finalChunk, m);
check("injectMetrics: metrics attached", withMetrics.includes('"metrics":'));
check("injectMetrics: mean_itl_ms present", withMetrics.includes('"mean_itl_ms":100'));
check("injectMetrics: choices preserved", withMetrics.includes('"finish_reason":"stop"'));
// eventHasDelta / eventFinishReason gate the timing + metrics injection.
check("eventHasDelta: content delta true", eventHasDelta('data: {"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}'));
check("eventHasDelta: empty delta false", !eventHasDelta('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'));
check("eventFinishReason: stop true", eventFinishReason('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'));
check("eventFinishReason: null false", !eventFinishReason('data: {"choices":[{"delta":{"content":"x"},"finish_reason":null}]}'));// 9. usage-chunk injection + gateway timings mapping (the real LM Studio path).
const usageChunk = 'data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"x","choices":[],"usage":{"completion_tokens":625}}';
check("eventHasUsage: usage chunk true", eventHasUsage(usageChunk));
check("eventHasUsage: finish chunk false", !eventHasUsage('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'));
const gwTimings = { prompt_ms: 948.5, predicted_ms: 264.2, predicted_n: 16, predicted_per_second: 60.6 };
const m2 = buildMetrics(1000, 1100, 1600, 6, gwTimings);
check("buildMetrics: timings mean_itl_ms = 1000/perSec", Math.abs(m2.mean_itl_ms - 1000/60.6) < 1e-6);
check("buildMetrics: timings time_to_first_token_ms = prompt_ms", m2.time_to_first_token_ms === 948.5);
check("buildMetrics: timings generation_time_ms = predicted_ms", m2.generation_time_ms === 264.2);
check("eventTimings: extracts timings", (() => { const t = eventTimings('data: {"choices":[],"usage":{},"timings":{"predicted_per_second":60.6}}'); return t && t.predicted_per_second === 60.6; })());
const usageWithMetrics = injectMetrics(usageChunk, m2);
check("injectMetrics: usage chunk gets metrics", usageWithMetrics.includes('"metrics":'));console.log(failures === 0 ? "sse.test: all green" : `sse.test: ${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
