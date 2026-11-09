#!/usr/bin/env python3
"""Tiny streaming smoke test through the Strata OpenAI-compatible gateway.

Answers, with evidence, the questions this smoke test targets:

1. Does the gateway stream `delta.reasoning_content` BEFORE `delta.content`?
   (The gateway emits reasoning_content; surfacing it is the bridge's job.)
2. Does the gateway forward `tools` and return `delta.tool_calls`?
3. Does the gateway accept OpenAI `image_url` message parts (vision)?

Safety (ground rules):
  * Gateway only (127.0.0.1:47831). Never the engine port 18500.
  * max_tokens <= 32 so inference bursts stay short.
  * API key read at runtime from ~/.strata/data/state.json -> serving.apiKey.
    Never printed, logged, or echoed. Output contains only field NAMES and
    counts, plus at most a few characters of the prompt echo.

Stdlib only. Exit 0 on success, 1 on transport/auth failure.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

STATE_JSON = os.environ.get("STATE_JSON", os.path.expanduser("~/.strata/data/state.json"))
BASE = os.environ.get("STRATA_BASE", "http://127.0.0.1:47831/v1")
MODEL = os.environ.get("EXPECTED_MODEL", "iq3_s")


def redact(text: str, key: str) -> str:
    return text.replace(key, "<redacted>") if key else text


def load_key() -> str:
    with open(STATE_JSON, "r", encoding="utf-8") as fh:
        return (json.load(fh).get("serving") or {}).get("apiKey") or ""


def post(path: str, payload: dict, key: str, timeout: int = 120):
    req = urllib.request.Request(
        f"{BASE.rstrip('/')}/{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "content-type": "application/json",
            "accept": "text/event-stream",
            "authorization": f"Bearer {key}",
        },
        method="POST",
    )
    return urllib.request.urlopen(req, timeout=timeout)


def sse_events(resp):
    """Yield parsed JSON objects from an SSE stream, plus the [DONE] marker."""
    data_lines: list[str] = []
    for raw in resp:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if line == "":
            if data_lines:
                payload = "\n".join(data_lines)
                data_lines = []
                if payload == "[DONE]":
                    yield None
                    return
                try:
                    yield json.loads(payload)
                except json.JSONDecodeError:
                    yield {"__malformed__": payload[:120]}
            continue
        if line.startswith("data:"):
            data_lines.append(line[5:].lstrip())


def probe_stream(key: str, payload: dict, label: str) -> dict:
    print(f"\n== {label} ==")
    t0 = time.monotonic()
    try:
        resp = post("chat/completions", payload, key)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:400]
        print(f"HTTP {e.code}: {redact(body, key)}")
        return {"http_error": e.code, "body": redact(body, key)}
    except Exception as e:  # noqa: BLE001
        print(f"transport failure: {type(e).__name__}: {redact(str(e), key)}")
        return {"error": f"{type(e).__name__}: {redact(str(e), key)}"}

    field_order: list[str] = []          # first-seen order of delta field names
    counts: dict[str, int] = {}
    first_reasoning_at = None
    first_content_at = None
    tool_call_deltas = 0
    finish_reason = None
    chunks = 0
    usage = None
    try:
        for obj in sse_events(resp):
            if obj is None:
                continue
            if "__malformed__" in obj:
                print("malformed SSE payload:", obj["__malformed__"])
                continue
            if "error" in obj:
                print("gateway error object:", redact(json.dumps(obj), key)[:300])
            usage = obj.get("usage") or usage
            choices = obj.get("choices") or []
            if not choices:
                continue
            ch = choices[0]
            delta = ch.get("delta") or {}
            for name, value in delta.items():
                counts[name] = counts.get(name, 0) + 1
                if name not in field_order:
                    field_order.append(name)
                    if name == "reasoning_content":
                        first_reasoning_at = chunks
                    if name == "content":
                        first_content_at = chunks
                if name == "tool_calls":
                    tool_call_deltas += 1
            if ch.get("finish_reason"):
                finish_reason = ch["finish_reason"]
            chunks += 1
    finally:
        resp.close()

    dt = time.monotonic() - t0
    print(f"chunks={chunks} in {dt:.1f}s  finish_reason={finish_reason}")
    print("delta field names, first-seen order:", field_order)
    print("per-field delta counts:", counts)
    print(f"first reasoning_content delta index: {first_reasoning_at}")
    print(f"first content delta index:           {first_content_at}")
    print(f"tool_calls deltas: {tool_call_deltas}")
    if usage:
        print("usage:", usage)
    return {
        "chunks": chunks,
        "usage": usage,
        "field_order": field_order,
        "counts": counts,
        "first_reasoning_at": first_reasoning_at,
        "first_content_at": first_content_at,
        "tool_call_deltas": tool_call_deltas,
        "finish_reason": finish_reason,
    }


def make_png_b64(size: int, rgb: tuple[int, int, int]) -> str:
    """Build a solid-colour PNG with stdlib only, so the vision probe can vary
    image size and observe whether prompt_tokens scale (proof the vision tower
    actually encoded the image, rather than the part being silently dropped)."""
    import base64
    import struct
    import zlib

    row = b"\x00" + bytes(rgb) * size
    raw = row * size

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    return base64.b64encode(png).decode("ascii")


def probe_nonstream(key: str, payload: dict, label: str) -> dict:
    """Non-streaming call; reports the KEYS of the returned assistant message
    (does a `tool_calls` field appear?) without echoing generated text."""
    print(f"\n== {label} ==")
    payload = dict(payload, stream=False)
    try:
        resp = post("chat/completions", payload, key)
        body = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        txt = e.read().decode("utf-8", "replace")[:300]
        print(f"HTTP {e.code}: {redact(txt, key)}")
        return {"http_error": e.code}
    except Exception as e:  # noqa: BLE001
        print(f"failure: {type(e).__name__}: {redact(str(e), key)}")
        return {"error": str(e)}
    choices = body.get("choices") or []
    msg = (choices[0].get("message") or {}) if choices else {}
    print("assistant message keys:", sorted(msg.keys()))
    print("finish_reason:", choices[0].get("finish_reason") if choices else None)
    print("has tool_calls:", "tool_calls" in msg)
    if "tool_calls" in msg:
        tc = msg["tool_calls"]
        print("tool_calls count:", len(tc), "| first function name:", (tc[0].get("function") or {}).get("name"))
    return {"message_keys": sorted(msg.keys()), "has_tool_calls": "tool_calls" in msg}


def probe_models_endpoint(key: str) -> None:
    print("\n== GET /v1/models raw entries (capability fields?) ==")
    req = urllib.request.Request(f"{BASE.rstrip('/')}/models", headers={"authorization": f"Bearer {key}"})
    try:
        body = json.loads(urllib.request.urlopen(req, timeout=10).read())
    except Exception as e:  # noqa: BLE001
        print("failure:", type(e).__name__, redact(str(e), key))
        return
    for m in body.get("data", []):
        print(json.dumps(m)[:400])


def probe_vision_quality(key: str, max_tokens: int) -> dict:
    """Distinguishable-image check: does the model answer correctly about an image?

    The gateway encodes pixels (prompt_tokens scale with image size). This checks answer
    quality. Only the short answer text is printed (a colour word), never the
    reasoning stream.
    """
    print("\n== 4. vision quality (solid red 256x256 PNG, expect 'red') ==")
    url = "data:image/png;base64," + make_png_b64(256, (220, 30, 30))
    payload = {
        "model": MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "What colour is this image? Answer with exactly one word."},
                {"type": "image_url", "image_url": {"url": url}},
            ],
        }],
        "stream": True,
        "max_tokens": max_tokens,
    }
    try:
        resp = post("chat/completions", payload, key)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {redact(e.read().decode('utf-8', 'replace')[:300], key)}")
        return {"http_error": e.code}
    except Exception as e:  # noqa: BLE001
        print(f"failure: {type(e).__name__}: {redact(str(e), key)}")
        return {"error": str(e)}

    answer: list[str] = []
    reasoning_len = 0
    finish_reason = None
    try:
        for obj in sse_events(resp):
            if obj is None:
                continue
            choices = obj.get("choices") or []
            if not choices:
                continue
            ch = choices[0]
            delta = ch.get("delta") or {}
            r = delta.get("reasoning_content")
            if isinstance(r, str):
                reasoning_len += len(r)
            c = delta.get("content")
            if isinstance(c, str):
                answer.append(c)
            if ch.get("finish_reason"):
                finish_reason = ch["finish_reason"]
    finally:
        resp.close()

    text = "".join(answer).strip()
    print(f"reasoning chars: {reasoning_len}  finish_reason={finish_reason}")
    print(f"ANSWER (first 120 chars): {text[:120]}")
    looks_right = "red" in text.lower()
    print("colour correct:", looks_right)
    return {"answer_len": len(text), "finish_reason": finish_reason, "correct": looks_right}


def probe_vision_quality(key: str, max_tokens: int) -> dict:
    """Distinguishable-image check: does the model answer correctly about an image?

    The gateway encodes pixels (prompt_tokens scale with image size). This checks answer
    quality. Only the short answer text is printed (a colour word), never the
    reasoning stream.
    """
    print("\n== 4. vision quality (solid red 256x256 PNG, expect 'red') ==")
    url = "data:image/png;base64," + make_png_b64(256, (220, 30, 30))
    payload = {
        "model": MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "What colour is this image? Answer with exactly one word."},
                {"type": "image_url", "image_url": {"url": url}},
            ],
        }],
        "stream": True,
        "max_tokens": max_tokens,
    }
    try:
        resp = post("chat/completions", payload, key)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {redact(e.read().decode('utf-8', 'replace')[:300], key)}")
        return {"http_error": e.code}
    except Exception as e:  # noqa: BLE001
        print(f"failure: {type(e).__name__}: {redact(str(e), key)}")
        return {"error": str(e)}

    answer: list[str] = []
    reasoning_len = 0
    finish_reason = None
    try:
        for obj in sse_events(resp):
            if obj is None:
                continue
            choices = obj.get("choices") or []
            if not choices:
                continue
            ch = choices[0]
            delta = ch.get("delta") or {}
            r = delta.get("reasoning_content")
            if isinstance(r, str):
                reasoning_len += len(r)
            c = delta.get("content")
            if isinstance(c, str):
                answer.append(c)
            if ch.get("finish_reason"):
                finish_reason = ch["finish_reason"]
    finally:
        resp.close()

    text = "".join(answer).strip()
    print(f"reasoning chars: {reasoning_len}  finish_reason={finish_reason}")
    print(f"ANSWER (first 120 chars): {text[:120]}")
    looks_right = "red" in text.lower()
    print("colour correct:", looks_right)
    return {"answer_len": len(text), "finish_reason": finish_reason, "correct": looks_right}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", default="Reply with exactly: PONG")
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--skip-tools", action="store_true")
    ap.add_argument("--skip-vision", action="store_true")
    ap.add_argument("--vision-quality", action="store_true",
                    help="run only the answer-quality vision check (larger burst, prints the answer)")
    args = ap.parse_args()
    ceiling = 512 if args.vision_quality else 64
    if args.max_tokens > ceiling:
        print(f"refusing max_tokens > {ceiling} (ground rule: keep bursts tiny)", file=sys.stderr)
        return 2

    key = load_key()
    if not key:
        print("no serving.apiKey found - aborting", file=sys.stderr)
        return 1

    if args.vision_quality:
        result = probe_vision_quality(key, max(256, args.max_tokens))
        return 0 if result.get("correct") else 1

    # 1. baseline reasoning-vs-content ordering defect
    base = probe_stream(key, {
        "model": MODEL,
        "messages": [{"role": "user", "content": args.prompt}],
        "stream": True,
        "max_tokens": args.max_tokens,
    }, "1. plain streaming call (reasoning_content ordering)")

    # 2. tool-call forwarding probe: register one trivial tool, ask the model to use it
    tools_result = None
    if not args.skip_tools:
        tools_result = probe_stream(key, {
            "model": MODEL,
            "messages": [{"role": "user", "content": "What is 12+30? Use the add tool."}],
            "stream": True,
            "max_tokens": args.max_tokens,
            "tools": [{
                "type": "function",
                "function": {
                    "name": "add",
                    "description": "Add two integers.",
                    "parameters": {
                        "type": "object",
                        "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                        "required": ["a", "b"],
                    },
                },
            }],
            "tool_choice": "auto",
        }, "2. tool-call forwarding probe (one trivial tool registered)")

    # 3. vision probe: 1x1 black PNG data URL
    vision_result = None
    if not args.skip_vision:
        png_1x1 = (
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
            "AAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )
        # control: identical text without the image, so the prompt_tokens delta is
        # attributable to image tokens (proves the vision path was reached).
        control = probe_stream(key, {
            "model": MODEL,
            "messages": [{"role": "user", "content": "One word: what color?"}],
            "stream": True,
            "max_tokens": args.max_tokens,
        }, "3a. vision control (same text, no image)")
        vision_result = probe_stream(key, {
            "model": MODEL,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "text", "text": "One word: what color?"},
                    {"type": "image_url", "image_url": {"url": png_1x1}},
                ],
            }],
            "stream": True,
            "max_tokens": args.max_tokens,
        }, "3. vision probe (1x1 image part)")

    # 3b. vision scaling: does prompt_tokens grow with image resolution?
    #     A silently-dropped image part would leave prompt_tokens flat.
    #     max_tokens stays at 32 (burst limit); only prompt_tokens is read, so the
    #     reasoning burst cutting off at `length` does not affect the measurement.
    scaling: list[tuple[int, int | None]] = []
    if not args.skip_vision:
        for size in (8, 64, 256):
            url = "data:image/png;base64," + make_png_b64(size, (255, 0, 0))
            res = probe_stream(key, {
                "model": MODEL,
                "messages": [{
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "One word: what color?"},
                        {"type": "image_url", "image_url": {"url": url}},
                    ],
                }],
                "stream": True,
                "max_tokens": args.max_tokens,
            }, f"3b. vision scaling ({size}x{size} solid red PNG)")
            scaling.append((size, (res.get("usage") or {}).get("prompt_tokens") if res else None))

    # 2b. non-streaming + forced tool_choice: does a tool_calls field ever appear?
    forced = None
    if not args.skip_tools:
        forced = probe_nonstream(key, {
            "model": MODEL,
            "messages": [{"role": "user", "content": "Use the add tool to compute 12+30."}],
            "max_tokens": args.max_tokens,
            "tools": [{
                "type": "function",
                "function": {
                    "name": "add",
                    "description": "Add two integers.",
                    "parameters": {
                        "type": "object",
                        "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                        "required": ["a", "b"],
                    },
                },
            }],
            "tool_choice": {"type": "function", "function": {"name": "add"}},
        }, "2b. non-streaming, tool_choice forced to function 'add'")

    probe_models_endpoint(key)

    # ---- verdicts ----
    print("\n== VERDICTS ==")
    if "error" in base or "http_error" in base:
        print("BASELINE CALL FAILED - gateway unreachable or auth broken")
        return 1
    if base["first_reasoning_at"] is not None:
        if base["first_content_at"] is None:
            print("DEFECT CONFIRMED: reasoning_content streamed, content never arrived within max_tokens")
        elif base["first_reasoning_at"] < base["first_content_at"]:
            print("DEFECT CONFIRMED: reasoning_content deltas arrive BEFORE content deltas")
        else:
            print("UNEXPECTED: content arrived before reasoning_content")
    else:
        print("no reasoning_content deltas observed for this prompt (model may not have reasoned)")
    if tools_result is not None and "error" not in tools_result and "http_error" not in tools_result:
        if tools_result["tool_call_deltas"] > 0:
            print("TOOLS(streamed): gateway forwards tools AND streams delta.tool_calls -> tool calling is implementable")
        else:
            print("TOOLS(streamed): request accepted but NO delta.tool_calls seen")
    elif tools_result is not None:
        print("TOOLS(streamed): request rejected outright -> gateway does not accept tools parameter")
    if forced is not None and "error" not in forced and "http_error" not in forced:
        print("TOOLS(forced tool_choice, non-streaming): message keys =", forced["message_keys"],
              "| tool_calls present:", forced["has_tool_calls"])
        if not forced["has_tool_calls"]:
            print("TOOLS: gateway produces NO tool_calls even with tool_choice forced -> tool "
                  "calling is NOT implementable through the gateway")
    if vision_result is not None and "error" not in vision_result and "http_error" not in vision_result:
        pt_v = (vision_result.get("usage") or {}).get("prompt_tokens")
        pt_b = (control.get("usage") or {}).get("prompt_tokens")
        print(f"VISION: image part accepted (HTTP 200, streamed). prompt_tokens {pt_b} text-only -> {pt_v} with image")
        print("VISION: gateway does not reject image parts; whether the vision tower encoded it needs a "
              "distinguishable-image test")
    elif vision_result is not None:
        print("VISION: gateway rejected the image part -> keep the explicit text-only error")
    if scaling:
        print("VISION scaling prompt_tokens by image size:", scaling)
        vals = [v for _, v in scaling if v is not None]
        if len(vals) >= 2 and vals[-1] > vals[0]:
            print(f"VISION: prompt_tokens scale with image resolution ({vals[0]} -> {vals[-1]}) -> "
                  "the gateway/vision tower IS encoding images. Vision is implementable.")
        else:
            print("VISION: prompt_tokens flat across image sizes -> image parts likely dropped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
