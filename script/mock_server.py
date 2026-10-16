#!/usr/bin/env python3
"""Deterministic local upstream. Test secrets only; no enterprise traffic."""
import datetime
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    quota_used = 850000

    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/fixture/quota95":
            Handler.quota_used = 960000
            return self.send_json(200, {"ok": True})
        if self.path == "/usage":
            if self.headers.get("Authorization") != "Bearer integration-quota-key":
                return self.send_json(401, {"error": "wrong quota key"})
            return self.send_json(200, {"data": {"used_tokens": Handler.quota_used, "total_tokens": 1000000,
                "month": datetime.datetime.now().strftime("%Y-%m")}})
        self.send_json(404, {})

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            if self.headers.get("Authorization") != "Bearer integration-upstream-key":
                return self.send_json(401, {"error": "wrong upstream key"})
            model = body.get("model", "")
            if model == "fail":
                return self.send_json(429, {"error": {"message": "rate limit"}})
            if model == "redirect":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:19877/must-not-follow")
                self.send_header("Content-Length", "0")
                return self.end_headers()
            if body.get("stream") is False:
                return self.send_json(200, {"choices": [{"message": {"content": "fixture reply"}}],
                    "usage": {"prompt_tokens": 100, "completion_tokens": 50}})
            if self.path == "/v1/chat/completions" and not body.get("stream_options", {}).get("include_usage"):
                return self.send_json(400, {"error": "include_usage was not forwarded"})
            native = self.path.startswith("/api/")
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson" if native else "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def emit(obj):
                text = json.dumps(obj, ensure_ascii=False) if not isinstance(obj, str) else obj
                packet = ((text + "\n") if native else ("data: " + text + "\r\n\r\n")).encode()
                # Split inside UTF-8 and line boundaries; forward byte-for-byte.
                for i in range(0, len(packet), 11):
                    self.wfile.write(packet[i:i+11]); self.wfile.flush()

            if model == "malformed":
                emit("not-json"); return
            for _ in range(30 if model in ["slow", "cancel"] else 4):
                if native:
                    emit({"message": {"content": "你好 world "}, "done": False})
                elif self.path == "/v1/responses":
                    emit({"type": "response.output_text.delta", "delta": "你好 world "})
                else:
                    emit({"choices": [{"delta": {"content": "你好 world "}}]})
                time.sleep(0.15 if model in ["slow", "cancel"] else 0.025)
            if model == "incomplete":
                return
            if native:
                emit({"done": True, "prompt_eval_count": 100, "eval_count": 50,
                    "prompt_eval_duration": 500000000, "eval_duration": 2000000000})
            elif self.path == "/v1/responses":
                emit({"type": "response.completed", "response": {"usage": {"input_tokens": 100, "output_tokens": 50}}})
            else:
                emit({"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 50}})
                emit("[DONE]")
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 19877), Handler).serve_forever()
