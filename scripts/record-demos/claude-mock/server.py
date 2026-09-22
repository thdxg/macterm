#!/usr/bin/env python3
"""A stand-in for the Anthropic API, so demo 7 can run Claude Code offline.

Claude Code is pointed here with ANTHROPIC_BASE_URL. Every `POST /v1/messages`
gets an answer: the request whose latest user message mentions "tour" gets the
canned project tour in tour.md, streamed as the same server-sent events the
real API emits; anything else (Claude Code makes small side requests of its
own) gets a one-word reply. Nothing leaves the machine and the transcript is
the same on every take.

    server.py <port> [tour.md] [-v]
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ARGS = [a for a in sys.argv[1:] if not a.startswith("-")]
VERBOSE = "-v" in sys.argv
PORT = int(ARGS[0]) if ARGS else 8765
TOUR = Path(ARGS[1] if len(ARGS) > 1 else Path(__file__).with_name("tour.md")).read_text()
# Seconds between streamed chunks. The reply finishes before the camera rolls,
# so this only has to look like streaming to Claude Code, not to a viewer.
CHUNK_DELAY = 0.004


def chunks(text, size=12):
    for i in range(0, len(text), size):
        yield text[i:i + size]


def reply_for(body):
    """Pick the canned reply: the tour for the demo's question, else a nod."""
    msgs = body.get("messages") or []
    for m in reversed(msgs):
        if m.get("role") != "user":
            continue
        content = m.get("content")
        if isinstance(content, list):
            content = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
        return TOUR if "tour" in str(content).lower() else "Okay."
    return "Okay."


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet unless asked
        if VERBOSE:
            super().log_message(fmt, *args)

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self):  # Claude Code probes reachability with HEAD /api/hello
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/health"):
            return self._json(200, {"ok": True, "mock": "macterm-demo"})
        self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "mock"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = {}
        if self.path.startswith("/v1/messages/count_tokens"):
            return self._json(200, {"input_tokens": 42})
        if not self.path.startswith("/v1/messages"):
            return self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "mock"}})

        text = reply_for(body)
        model = body.get("model", "claude-demo")
        usage = {"input_tokens": 64, "output_tokens": max(1, len(text) // 4)}
        if not body.get("stream"):
            return self._json(200, {
                "id": "msg_macterm_demo", "type": "message", "role": "assistant", "model": model,
                "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn", "stop_sequence": None, "usage": usage,
            })

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def event(name, data):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        event("message_start", {"type": "message_start", "message": {
            "id": "msg_macterm_demo", "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": usage["input_tokens"], "output_tokens": 1}}})
        event("content_block_start", {"type": "content_block_start", "index": 0,
                                      "content_block": {"type": "text", "text": ""}})
        for piece in chunks(text):
            event("content_block_delta", {"type": "content_block_delta", "index": 0,
                                          "delta": {"type": "text_delta", "text": piece}})
            time.sleep(CHUNK_DELAY)
        event("content_block_stop", {"type": "content_block_stop", "index": 0})
        event("message_delta", {"type": "message_delta",
                                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                "usage": {"output_tokens": usage["output_tokens"]}})
        event("message_stop", {"type": "message_stop"})


if __name__ == "__main__":
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
