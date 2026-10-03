"""The detective's "brain": a scripted stand-in for an OpenAI-compatible chat model.

It is not a real language model. It follows the clues a person would follow, one rule per step,
so it gives the same answer every time and needs no API key:

1. A new question: list the Pods in the zoo.
2. Got the Pods: if one isn't Running, read its logs. If they're all Running, say so.
3. Got the logs: if they name a ConfigMap, look at it. Otherwise report the logs.
4. Got the ConfigMap: write up what happened.

Every request, the rule it used and its reply are printed, so `kubectl logs` reads like a notebook.
It only speaks the one endpoint kagent uses: POST /v1/chat/completions (no streaming).
"""
import json
import re
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def text_of(content):
    if isinstance(content, list):
        content = " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    content = content or ""
    try:
        return str(json.loads(content).get("output", content))
    except (ValueError, AttributeError):
        return content


def tool_named(tools, suffix):
    return next((name for name in tools if name.endswith(suffix)), None)


def tool_results(messages):
    """Every tool call so far, in order, as (name, arguments, result)."""
    pending, results = {}, []
    for m in messages:
        for c in m.get("tool_calls") or []:
            pending[c["id"]] = (c["function"]["name"], json.loads(c["function"].get("arguments") or "{}"))
        if m.get("role") == "tool" and m.get("tool_call_id") in pending:
            name, args = pending[m["tool_call_id"]]
            results.append((name, args, text_of(m.get("content"))))
    return results


def animal_of(pod):
    """smaug-644b8bf964-v24j5 -> smaug (a Deployment's Pods are <deployment>-<hash>-<id>)."""
    return pod.rsplit("-", 2)[0]


def first_unhappy_pod(table):
    """(pod, status) for an animal with no Running Pod, or (None, [every animal])."""
    lines = [l for l in table.splitlines() if l.strip()]
    if not lines or not lines[0].startswith("NAME"):
        return None, []
    status_at = lines[0].split().index("STATUS")
    pods = [(cells[0], cells[status_at]) for cells in (l.split() for l in lines[1:]) if len(cells) > status_at]
    # During a rollout an animal briefly has two Pods. If one of them is Running, the animal is home.
    home = {animal_of(pod) for pod, status in pods if status == "Running"}
    for pod, status in pods:
        if animal_of(pod) not in home and status not in ("Completed", "Terminating"):
            return pod, status
    return None, sorted({animal_of(pod) for pod, _ in pods})


def call(name, **args):
    return {"tool_call": {"name": name, "arguments": json.dumps(args)}}


def decide(request):
    """Returns (the rule it used, its reply)."""
    messages = request.get("messages") or []
    tools = [t.get("function", {}).get("name", "") for t in request.get("tools") or []]
    lister, logs = tool_named(tools, "get_resources"), tool_named(tools, "get_pod_logs")
    last = messages[-1] if messages else {}

    if last.get("role") == "user":
        if not lister:
            return "rule 1: no tool to look with", {"content": "I can't see the zoo from here. Nobody gave me a tool to look with."}
        return "rule 1: new question, list the Pods", call(lister, resource_type="pods", namespace="zoo")
    results = tool_results(messages)
    if last.get("role") != "tool" or not results:
        return "no rule", {"content": "I'm not sure what you're asking."}
    name, args, result = results[-1]

    if name == lister and args.get("resource_type") == "pods":
        pod, status = first_unhappy_pod(result)
        if pod is None:
            names = ", ".join(status) or "nobody"
            return "rule 2: every Pod is Running", {"content": f"Everyone's home. All Pods in the zoo are Running: {names}."}
        if not logs:
            return "rule 2: no tool to read logs", {"content": f"{pod} is in {status}, but I have no tool to read its logs."}
        return f"rule 2: {pod} is in {status}, read its logs", call(logs, pod_name=pod, namespace="zoo", tail_lines=20)

    if name == logs:
        configmap = re.search(r"ConfigMap ([a-z0-9-]+)", result)
        if configmap:
            return f"rule 3: the logs mention ConfigMap {configmap.group(1)}, look at it", call(
                lister, resource_type="configmap", resource_name=configmap.group(1), namespace="zoo", output="yaml")
        return "rule 3: the logs don't point anywhere else", {"content": "Its logs say: " + result.strip()[-300:]}

    pod, status = first_unhappy_pod(results[0][2])
    last_words = next((r for n, _, r in results if n == logs), "").strip().splitlines()[-1:] or [""]
    data = re.search(r"\ndata:\n((?:  .*\n?)+)", "\n" + result)
    settings = " ".join(data.group(1).split()) if data else "nothing I could read"
    animal = animal_of(pod).capitalize() if pod else "The animal"
    return "rule 4: write it up", {"content": (
        f"Found {animal}. Pod {pod} is in {status}: it keeps starting and leaving. "
        f"Its last words: \"{last_words[0]}\" "
        f"The ConfigMap it reads has {settings}. "
        f"Fix that, and {animal} should come home on the next restart.")}


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
            return self.reply(404, {"error": {"message": f"detective-model only serves /v1/chat/completions, not {self.path}"}})
        roles = [m.get("role") for m in request.get("messages") or []]
        print(f"<- asked: messages={roles}", flush=True)
        rule, decision = decide(request)
        print(f"   {rule}", flush=True)
        if "tool_call" in decision:
            tool_call = {"id": "call_" + uuid.uuid4().hex[:8], "type": "function", "function": decision["tool_call"]}
            message, finish = {"role": "assistant", "content": None, "tool_calls": [tool_call]}, "tool_calls"
            print(f"-> reply: call {tool_call['function']['name']} {tool_call['function']['arguments']}", flush=True)
        else:
            message, finish = {"role": "assistant", "content": decision["content"]}, "stop"
            print(f"-> reply: {decision['content']}", flush=True)
        self.reply(200, {
            "id": "chatcmpl-" + uuid.uuid4().hex[:12], "object": "chat.completion", "created": int(time.time()),
            "model": request.get("model", "detective-model"),
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        })


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"detective-model listening on :{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
