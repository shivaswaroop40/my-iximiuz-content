"""A scripted stand-in for an OpenAI-compatible chat model. Logs every request.

kagent v0.10.2's Go runtime only needs non-streaming POST /v1/chat/completions with tool calls.
Rules, checked on the last message:
- a user message and another agent offered as a tool (kagent names it <ns>__NS__<agent>): delegate to it
- a user message and a tool whose name contains a word from PREFERRED: call that tool
- a tool result: answer with a short summary of it
- anything else: echo the question

Run: python3 stub-llm.py 8080
"""
import json, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFERRED = ["get_resources", "get_pets", "k8s_get"]


def log(kind, obj):
    print(json.dumps({"ts": time.time(), "kind": kind, **obj}), flush=True)


def text_of(content):
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content if isinstance(c, dict))
    return content


def decide(req):
    msgs = req.get("messages", [])
    tools = [t.get("function", {}).get("name", "") for t in req.get("tools") or []]
    last = msgs[-1] if msgs else {}
    if last.get("role") == "tool":
        return {"content": "Here is what the tool returned:\n" + str(text_of(last.get("content")))[:800]}
    if last.get("role") == "user":
        for name in tools:
            if "__NS__" in name:
                return {"tool_call": {"name": name, "arguments": json.dumps({"request": text_of(last.get("content"))})}}
        for want in PREFERRED:
            for name in tools:
                if want in name:
                    args = {"resource_type": "pods", "all_namespaces": "true"} if "resources" in name else {}
                    return {"tool_call": {"name": name, "arguments": json.dumps(args)}}
    return {"content": f"(stub model) You said: {text_of(last.get('content'))}"}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        log("GET", {"path": self.path})
        if self.path.rstrip("/").endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": "zoo-stub", "object": "model", "owned_by": "stub"}]})
        self._json(200, {"ok": True})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            req = json.loads(raw or b"{}")
        except Exception:
            req = {}
        log("POST", {"path": self.path, "headers": {k: v for k, v in self.headers.items() if k.lower() != "authorization"},
                     "auth_present": "authorization" in {k.lower() for k in self.headers}, "body": req})
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._json(404, {"error": {"message": f"stub: unsupported path {self.path}"}})
        d = decide(req)
        cid, model, now = "chatcmpl-" + uuid.uuid4().hex[:12], req.get("model", "zoo-stub"), int(time.time())
        if "tool_call" in d:
            tc = {"id": "call_" + uuid.uuid4().hex[:8], "type": "function", "function": d["tool_call"]}
            msg, finish = {"role": "assistant", "content": None, "tool_calls": [tc]}, "tool_calls"
        else:
            msg, finish = {"role": "assistant", "content": d["content"]}, "stop"
        log("REPLY", {"stream": bool(req.get("stream")), "message": msg})
        usage = {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}
        if not req.get("stream"):
            return self._json(200, {"id": cid, "object": "chat.completion", "created": now, "model": model,
                                    "choices": [{"index": 0, "message": msg, "finish_reason": finish}], "usage": usage})
        # Streaming wasn't exercised by kagent v0.10.2, kept for other clients.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def chunk(delta, fin=None):
            c = {"id": cid, "object": "chat.completion.chunk", "created": now, "model": model,
                 "choices": [{"index": 0, "delta": delta, "finish_reason": fin}]}
            self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
            self.wfile.flush()

        chunk({"role": "assistant", "content": ""})
        if msg.get("tool_calls"):
            tc = msg["tool_calls"][0]
            chunk({"tool_calls": [{"index": 0, "id": tc["id"], "type": "function",
                                   "function": {"name": tc["function"]["name"], "arguments": tc["function"]["arguments"]}}]})
        else:
            for i in range(0, len(msg["content"]), 40):
                chunk({"content": msg["content"][i:i + 40]})
        chunk({}, finish)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    log("START", {"port": port})
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
