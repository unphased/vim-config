"""Local-only Claude Messages SSE fixture; prints its ephemeral port."""
import argparse
import json
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_TEXT = "MARKDOWN src/target.ts:7:3\nRAWOSC src/target.ts:8:1"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        if "count_tokens" in self.path:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"input_tokens":10}')
            return
        message = {"id": "msg_" + uuid.uuid4().hex, "type": "message",
                   "role": "assistant", "model": request.get("model", "fixture"),
                   "content": [], "stop_reason": None, "stop_sequence": None,
                   "usage": {"input_tokens": 10, "output_tokens": 0}}
        self.send_response(200)
        if not request.get("stream"):
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            message.update(content=[{"type": "text", "text": self.server.text}],
                           stop_reason="end_turn")
            self.wfile.write(json.dumps(message).encode())
            return
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        def event(kind, **fields):
            data = json.dumps({"type": kind, **fields})
            self.wfile.write(f"event: {kind}\ndata: {data}\n\n".encode())
            self.wfile.flush()
        event("message_start", message=message)
        event("content_block_start", index=0, content_block={"type": "text", "text": ""})
        for chunk in ["MARKDOWN src/", "target.ts:7:3\n", "RAWOSC src/", "target.ts:8:1"]:
            event("content_block_delta", index=0,
                  delta={"type": "text_delta", "text": chunk})
            time.sleep(0.1)
        if self.server.text.endswith("\n"):
            event("content_block_delta", index=0,
                  delta={"type": "text_delta", "text": "\n"})
        event("content_block_stop", index=0)
        event("message_delta", delta={"stop_reason": "end_turn", "stop_sequence": None},
              usage={"output_tokens": 30})
        event("message_stop")

parser = argparse.ArgumentParser()
parser.add_argument("--no-newline", action="store_true", help="omit final newline")
parser.add_argument("--port", type=int, default=0)
args = parser.parse_args()
server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
server.text = BASE_TEXT + ("" if args.no_newline else "\n")
print(server.server_port, flush=True)
server.serve_forever()
