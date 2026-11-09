#!/usr/bin/env python3
"""MCP delivery-vehicle demo: expose Strata to LM Studio's agent as a TOOL.

This is an EVALUATION artifact, not a shipped feature. It answers one question:

    Can Strata be reached from LM Studio's Bionic agent through MCP - the one
    fully-supported, documented integration surface - as a *tool* rather than a
    *model*?

NOTE: the "existing Strata MCP leg" assumed by the project notes does not
exist on disk. `~/.lmstudio/mcp.json` contains only `comfyui`; there is no
`strata_mcp.py` and no Strata entry in any mcp.json. So this is a fresh, minimal
server, not a reuse.

Protocol: MCP over stdio - newline-delimited JSON-RPC 2.0 (one message per line,
no embedded newlines). Implements initialize, tools/list, tools/call.

Safety (ground rules):
  * Talks to the Strata gateway only (127.0.0.1:47831). Never the engine :18500.
  * API key read at runtime from ~/.strata/data/state.json -> serving.apiKey.
    Never printed, logged, or echoed.
  * max_tokens clamped <= 64 so inference bursts stay short.
  * Never writes to ~/.lmstudio/mcp.json - registering it is a manual UI/CLI step.

Stdlib only. To try it (manual):
  LM Studio -> installed -> MCP servers -> Add, command:
    python3  args: <path-to-this-project>/tools/strata_mcp_server.py
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request

STATE_JSON = os.environ.get("STATE_JSON", os.path.expanduser("~/.strata/data/state.json"))
STRATA_BASE = os.environ.get("STRATA_BASE", "http://127.0.0.1:47831/v1")
MODEL = os.environ.get("EXPECTED_MODEL", "iq3_s")
PROTOCOL_VERSION = "2024-11-05"
MAX_TOKENS_CAP = 64


def load_key() -> str:
    with open(STATE_JSON, "r", encoding="utf-8") as fh:
        return (json.load(fh).get("serving") or {}).get("apiKey") or ""


def strata_chat(prompt: str, max_tokens: int) -> str:
    key = load_key()
    if not key:
        raise RuntimeError("Strata serving key not found")
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": min(max(1, max_tokens), MAX_TOKENS_CAP),
        "temperature": 0,
        "stream": False,
    }
    req = urllib.request.Request(
        f"{STRATA_BASE.rstrip('/')}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"content-type": "application/json", "authorization": f"Bearer {key}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)
    choice = (data.get("choices") or [{}])[0]
    content = (choice.get("message") or {}).get("content") or ""
    return content


TOOLS = [
    {
        "name": "strata_chat",
        "description": (
            "Ask the locally-served Strata model a question. Use for "
            "general reasoning/vision-free chat. Returns a short text answer."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "The question to ask Strata."},
                "max_tokens": {"type": "integer", "description": "Max tokens (<= 64).", "default": 64},
            },
            "required": ["prompt"],
        },
    }
]


def handle(msg: dict) -> dict | None:
    method = msg.get("method")
    msg_id = msg.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "strata-mcp", "version": "0.1.0"},
            },
        }
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        if name != "strata_chat":
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"content": [{"type": "text", "text": f"unknown tool: {name}"}], "isError": True},
            }
        try:
            answer = strata_chat(str(args.get("prompt", "")), int(args.get("max_tokens", 64)))
            return {"jsonrpc": "2.0", "id": msg_id, "result": {"content": [{"type": "text", "text": answer}]}}
        except Exception as exc:  # noqa: BLE001 - never leak the key; type name only
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"content": [{"type": "text", "text": f"strata error: {type(exc).__name__}"}], "isError": True},
            }
    if method and msg_id is not None:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"method not found: {method}"}}
    return None


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        reply = handle(msg)
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
