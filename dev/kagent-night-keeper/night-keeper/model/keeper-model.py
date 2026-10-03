"""The night keeper's "brain": a scripted stand-in for an OpenAI-compatible chat model.

It is not a real language model. It follows three rules, so every answer is the same every time:

1. You asked a question, and it has a tool that can list resources: it asks to call that tool for the Pets.
2. The last message is a tool result: it reads the Pets table and writes a night report.
3. Anything else (for example, no tools at all): it says what it can't do.

Every request and reply is printed, so `kubectl logs` shows exactly what the agent sends a model.
It only speaks the one endpoint kagent uses: POST /v1/chat/completions (no streaming).
"""
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def text_of(content):
    if isinstance(content, list):
        return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content or ""


def night_report(table):
    """Turn `kubectl get pets` output into a short report."""
    lines = [line for line in table.replace("\\n", "\n").splitlines() if line.strip()]
    header = next((line for line in lines if line.startswith("NAME")), None)
    if header is None:
        return "I tried to look at the Pets, but got this instead:\n" + table[:300]
    columns = header.split()
    mood_at = columns.index("MOOD") if "MOOD" in columns else None
    hungry, gone, fine = [], [], []
    for row in lines[lines.index(header) + 1:]:
        cells = row.split()
        if mood_at is None or len(cells) <= mood_at:
            continue
        name, species, mood = cells[0], cells[1], cells[mood_at]
        {"Hungry": hungry, "RanAway": gone}.get(mood, fine).append(f"{name} the {species}")
    report = []
    if hungry:
        report.append("Hungry: " + ", ".join(hungry) + ".")
    if gone:
        report.append("Ran away: " + ", ".join(gone) + "!")
    report.append("Everyone else is fine: " + (", ".join(fine) if fine else "nobody") + ".")
    return " ".join(report)


def decide(request):
    messages = request.get("messages") or []
    tools = [t.get("function", {}).get("name", "") for t in request.get("tools") or []]
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        output = text_of(last.get("content"))
        try:
            output = json.loads(output).get("output", output)
        except (ValueError, AttributeError):
            pass
        return {"content": night_report(str(output))}
    if last.get("role") == "user":
        lister = next((name for name in tools if name.endswith("get_resources")), None)
        if lister:
            return {"tool_call": {"name": lister, "arguments": json.dumps({"resource_type": "pets", "namespace": "zoo"})}}
        return {"content": "I can't see the zoo from here. Nobody gave me a tool to look at the Pets with."}
    return {"content": "I'm not sure what you're asking."}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        request = json.loads(self.rfile.read(length) or b"{}")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self.reply(404, {"error": {"message": f"keeper-model only serves /v1/chat/completions, not {self.path}"}})
        roles = [m.get("role") for m in request.get("messages") or []]
        tools = [t.get("function", {}).get("name") for t in request.get("tools") or []]
        print(f"<- asked: messages={roles} tools={tools}", flush=True)
        decision = decide(request)
        if "tool_call" in decision:
            call = {"id": "call_" + uuid.uuid4().hex[:8], "type": "function", "function": decision["tool_call"]}
            message, finish = {"role": "assistant", "content": None, "tool_calls": [call]}, "tool_calls"
            print(f"-> reply: call {call['function']['name']} {call['function']['arguments']}", flush=True)
        else:
            message, finish = {"role": "assistant", "content": decision["content"]}, "stop"
            print(f"-> reply: {decision['content']}", flush=True)
        self.reply(200, {
            "id": "chatcmpl-" + uuid.uuid4().hex[:12], "object": "chat.completion", "created": int(time.time()),
            "model": request.get("model", "keeper-model"),
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        })


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"keeper-model listening on :{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
