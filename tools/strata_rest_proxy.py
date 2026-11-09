#!/usr/bin/env python3
"""REST-proxy route demo (exposing Strata in "LM Studio API" shape).

This is an EVALUATION artifact, not a shipped feature. It answers one question:

    Can a local, loopback-only OpenAI/LM-Studio-shaped server front Strata, so a
    client that speaks LM Studio's REST dialect sees the served model as a *loaded
    model* and can chat with it - without touching any LM Studio app file?

It serves three shapes on one loopback port:

  * GET  /v1/models            -> OpenAI model list (Strata ids)
  * POST /v1/chat/completions  -> proxied to Strata (stream + non-stream)
  * GET  /api/v1/models        -> LM Studio "loaded models" shape, with the served
                                  model reported as a LOADED INSTANCE (loaded_instances
                                  non-empty). This is the part a generator plugin can
                                  NEVER produce.

Safety (ground rules):
  * Binds 127.0.0.1 only. Never 0.0.0.0. Strata is never exposed to the network.
  * Talks to the Strata gateway only (127.0.0.1:47831). Never the engine :18500.
  * API key read at runtime from ~/.strata/data/state.json -> serving.apiKey.
    Never printed, logged, or echoed.
  * Test prompts stay tiny; this proxy does not add tokens, it forwards them.

Stdlib only. Run:  python3 tools/strata_rest_proxy.py [--port 47900]
Then in another shell:
  curl -s http://127.0.0.1:47900/api/v1/models
  curl -s http://127.0.0.1:47900/v1/chat/completions -H 'content-type: application/json' \
       -d '{"model":"iq3_s","messages":[{"role":"user","content":"say OK"}],"max_tokens":8}'
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_JSON = os.environ.get("STATE_JSON", os.path.expanduser("~/.strata/data/state.json"))
STRATA_BASE = os.environ.get("STRATA_BASE", "http://127.0.0.1:47831/v1")
MODEL = os.environ.get("EXPECTED_MODEL", "iq3_s")


def load_key() -> str:
    with open(STATE_JSON, "r", encoding="utf-8") as fh:
        return (json.load(fh).get("serving") or {}).get("apiKey") or ""


def strata_request(path: str, payload: dict | None, key: str, method: str, stream: bool):
    headers = {"content-type": "application/json", "authorization": f"Bearer {key}"}
    if stream:
        headers["accept"] = "text/event-stream"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(f"{STRATA_BASE.rstrip('/')}/{path}", data=data, headers=headers, method=method)
    return urllib.request.urlopen(req, timeout=120)


def strata_models(key: str) -> list[dict]:
    with strata_request("models", None, key, "GET", stream=False) as resp:
        return json.load(resp).get("data", [])


class Handler(BaseHTTPRequestHandler):
    key: str  # injected on the class

    def log_message(self, fmt, *args):  # keep stdout clean; never echo bodies
        sys.stderr.write("[proxy] %s\n" % (fmt % args))

    def _send_json(self, code: int, obj: dict):
        body = json.dumps(obj, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            try:
                self._send_json(200, {"object": "list", "data": strata_models(self.key)})
            except Exception as exc:  # noqa: BLE001
                self._send_json(502, {"error": {"message": f"strata unreachable: {type(exc).__name__}"}})
            return
        if self.path.rstrip("/") == "/api/v1/models":
            # LM Studio's loaded-models shape. The whole point of this route:
            # here the served model shows up as a LOADED INSTANCE, which a generator
            # plugin can never do (verified: LM Studio's own /api/v1/models has empty
            # loaded_instances for every entry, and no strata entry at all).
            try:
                models = strata_models(self.key)
            except Exception as exc:  # noqa: BLE001
                self._send_json(502, {"error": {"message": f"strata unreachable: {type(exc).__name__}"}})
                return
            entries = []
            for m in models:
                mid = m.get("id", "")
                entries.append(
                    {
                        "type": "llm",
                        "publisher": "strata",
                        "key": mid,
                        "display_name": (m.get("meta") or {}).get("label", mid),
                        "architecture": "unknown",
                        "quantization": {"name": "IQ1_M", "bits_per_weight": 1},
                        "size_bytes": 0,
                        "params_string": "",
                        "max_context_length": 262144,
                        "format": "gguf",
                        "capabilities": {"vision": True, "reasoning": True, "tools": False, "split": False, "audio": False},
                        "loaded_instances": [{"id": "strata-proxy", "config": {}}],
                    }
                )
            self._send_json(200, {"models": entries})
            return
        self._send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            self._send_json(404, {"error": {"message": "not found"}})
            return
        length = int(self.headers.get("content-length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": {"message": "invalid json"}})
            return
        stream = bool(payload.get("stream"))
        try:
            upstream = strata_request("chat/completions", payload, self.key, "POST", stream)
        except urllib.error.HTTPError as exc:
            self._send_json(exc.code, {"error": {"message": f"strata http {exc.code}"}})
            return
        except Exception as exc:  # noqa: BLE001
            self._send_json(502, {"error": {"message": f"strata unreachable: {type(exc).__name__}"}})
            return
        if not stream:
            with upstream:
                body = upstream.read()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # stream: relay SSE bytes verbatim
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        try:
            for raw in upstream:
                self.wfile.write(raw)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            upstream.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=47900)
    ap.add_argument("--once", action="store_true", help="serve a single request then exit (for CI smoke)")
    args = ap.parse_args()

    key = load_key()
    if not key:
        print("no Strata serving key found; is Strata running?", file=sys.stderr)
        return 1
    Handler.key = key

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[proxy] loopback-only on http://127.0.0.1:{args.port}  (Ctrl-C to stop)", file=sys.stderr)
    try:
        if args.once:
            httpd.handle_request()
        else:
            httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
