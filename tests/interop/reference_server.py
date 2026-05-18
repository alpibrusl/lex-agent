"""Minimal A2A reference server for cross-framework interop tests.

A `examples/04_calls_public_agent.lex` Lex client points at this
server, exercises both `fetch_agent_card` (GET /.well-known/agent.json)
and `send_task` (POST /), and asserts on the response. The server is
deliberately tiny — its job is to **answer with the canonical A2A
wire shape via the same a2a-sdk types CI's `validate_with_a2a_sdk.py`
checks**, so any drift between Lex's emit and Python's parse surfaces
in two directions:

  - Python side: a2a-sdk's `compat.v0_3` types validate every payload
    on the way out (or fail loudly).
  - Lex side: the example asserts on parsed fields (`status.state`,
    skill `name`).

The handler implements a single inbound capability — `echo` — that
returns "pong: <input text>" with state TASK_STATE_COMPLETED. Empty
input gets a JSON-RPC `-32099 spec-denied` error so the Lex client
sees the same gate semantics it would get from a peer Lex server.

Usage:
  python3 tests/interop/reference_server.py [--port 4041]

The script writes "ready" to stdout once the listener is bound, then
serves until killed. Tests should `kill $PID` after the assertions
pass.
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from a2a.compat.v0_3 import types as v3  # type: ignore


SPEC_DENIED = -32099
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL = -32603


def _new_message_id() -> str:
    return "msg_" + secrets.token_hex(8)


def _card() -> dict:
    """Build the AgentCard, validate via a2a-sdk, return the JSON-able dict."""
    raw = {
        "name": "py-echo",
        "description": "Reference A2A echo agent (Python).",
        "version": "0.1.0",
        "url": "http://localhost:4041",
        "provider": {"organization": "", "url": ""},
        "capabilities": {
            "streaming": False,
            "pushNotifications": False,
            "stateTransitionHistory": True,
        },
        "defaultInputModes": ["text"],
        "defaultOutputModes": ["text"],
        "skills": [{
            "id": "echo",
            "name": "echo",
            "description": "Echo the input text back with a 'pong: ' prefix.",
            "tags": [],
            "inputSchema": {
                "type": "object",
                "properties": {"text": {"type": "string", "minLength": 1}},
                "required": ["text"],
            },
        }],
    }
    # Round-trip through a2a-sdk so we never serve a card the SDK can't parse.
    v3.AgentCard.model_validate(raw)
    return raw


def _rpc_error(rpc_id, code: int, message: str) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": rpc_id,
        "error": {"code": code, "message": message},
    }


def _rpc_ok(rpc_id, result: dict) -> dict:
    return {"jsonrpc": "2.0", "id": rpc_id, "result": result}


def _handle_tasks_send(req: dict) -> dict:
    rpc_id = req.get("id")
    params = req.get("params") or {}
    task_id = params.get("id")
    context_id = params.get("contextId") or params.get("sessionId")
    msg_in = params.get("message")
    if not task_id or not context_id or not msg_in:
        return _rpc_error(rpc_id, INVALID_PARAMS,
                          "tasks/send requires id, contextId, and message")

    # Validate the inbound Message through a2a-sdk — this is the
    # "Python A2A client / our server" interop check.
    try:
        m = v3.Message.model_validate(msg_in)
    except Exception as e:
        return _rpc_error(rpc_id, INVALID_PARAMS,
                          f"message did not pass a2a-sdk validation: {e}")

    # Extract the first TextPart's text.
    text = ""
    for part in m.parts:
        kind = getattr(part.root, "kind", None) if hasattr(part, "root") else None
        if hasattr(part, "root"):
            inner = part.root
        else:
            inner = part
        if getattr(inner, "text", None) is not None:
            text = inner.text
            break

    if not text.strip():
        return _rpc_error(rpc_id, SPEC_DENIED,
                          'spec-denied: predicate false: (args.text != "")')

    reply_msg = {
        "kind": "message",
        "messageId": _new_message_id(),
        "role": "agent",
        "parts": [{"type": "text", "text": f"pong: {text}"}],
    }
    task = {
        "kind": "task",
        "id": task_id,
        "contextId": context_id,
        "status": {"state": "completed"},
        "artifacts": [],
        "history": [
            msg_in,
            reply_msg,
        ],
        "message": reply_msg,
    }
    # Validate before serving.
    v3.Task.model_validate(task)
    return _rpc_ok(rpc_id, task)


class Handler(BaseHTTPRequestHandler):
    # Quiet the per-request stderr logging from BaseHTTPRequestHandler.
    def log_message(self, format, *args):  # noqa: A002
        pass

    def _send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path == "/.well-known/agent.json":
            self._send_json(200, _card())
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(n).decode("utf-8") if n else ""
        try:
            req = json.loads(body)
        except Exception as e:
            self._send_json(200, _rpc_error(None, PARSE_ERROR, f"parse error: {e}"))
            return
        method = req.get("method")
        if method == "tasks/send":
            self._send_json(200, _handle_tasks_send(req))
        else:
            self._send_json(200, _rpc_error(req.get("id"), METHOD_NOT_FOUND,
                                            f"method not supported: {method}"))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=int(os.environ.get("A2A_REF_PORT", "4041")))
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args(argv)

    server = HTTPServer((args.host, args.port), Handler)
    # Validate the card once at startup — fail fast on any wire-shape regression.
    _card()
    print(f"ready http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
