# Spike: kagent and Agent Sandbox on iximiuz Labs

Run on 2026-10-01 on a stock `k8s-omni` playground (Kubernetes v1.37.0, containerd 2.3.4, flannel,
Firecracker backend; dev-machine 2 CPU/4 GB, cplane-01 4 CPU/4 GB, two workers at 2 CPU/4 GB).
Every manifest and script used is in `dev/spikes/kagent/`.

## Verdict

| Idea | Verdict |
|---|---|
| kagent tutorial on stock k8s-omni, no API key | **Go**, with a stub model and a StorageClass |
| kagent challenge: debug broken agents | **Go**, four distinct failure modes found |
| kagent challenge: lock down the tool server | **Go, strongest idea**. Needs Calico or Cilium for NetworkPolicy |
| Agent Sandbox tutorial with gVisor | **Go**. Works without nested virtualization |
| Real local model (Ollama) | Not tested. The stub covers everything the checks need |

## Versions

- kagent **v0.10.2** (stable, 2026-09-23). **v1.0.0 is in alpha** (alpha6 on 2026-09-30) and changes the API
  group from `kagent.dev` to `api.kagent.dev`, replaces `ToolServer`/`Memory`/`SandboxAgent` with `Harness` and
  `SandboxTemplate`, and adds `AgentTemplate`. A tutorial written against v0.10.2 will need a rewrite when v1
  ships. Pin v0.10.2 now and plan a v1 update, or wait for v1.0.0 GA.
- Agent Sandbox **v1.0.4** (`agents.x-k8s.io/v1beta1`).
- gVisor **release-20260928.0**, from the apt repo. The loose-binary URLs in older guides now 404.
- local-path-provisioner: used v0.0.32 in the spike, pin v0.0.37 (latest) in content.

## kagent

### Install

`helm install` of `kagent-crds` and `kagent` (OCI, `ghcr.io/kagent-dev/kagent/helm/*`) takes about 3 s; images pull
in well under a minute.

- **Gotcha 1: no StorageClass on k8s-omni.** The bundled Postgres needs a PVC, stays Pending, and the controller
  crash-loops on `database migration failed ... connection refused`. The chart has no emptyDir option. Fix:
  local-path-provisioner as the default StorageClass, installed before kagent.
- The bundled agents (k8s, istio, cilium x3, helm, argo, promql, observability, kgateway) and grafana-mcp are on by
  default. Turn them all off (`kagent-values.yaml`) so the learner builds their own agent and the cluster stays light.
- With kagent, the stub model, Agent Sandbox and one sandbox running, the busiest worker had 1.2 GiB of 3.6 GiB
  requested and about 700 MiB actually used. Each agent Pod requests 100m/384Mi. Plenty of room.

### What the controller builds

`kubectl apply` of a 15-line `Agent` (`keeper.yaml`) produced, within 3 s, a Deployment, Service, ServiceAccount
and a Secret holding `config.json` and `agent-card.json`, all owned by the Agent. The Agent reports `Accepted` and
`Ready` conditions; `Ready=True` arrived after 10 s. `config.json` is the compiled agent: the model endpoint and the
filtered list of MCP tools. This is a direct continuation of the operator tutorial (an operator turning a custom
resource into Deployments and reporting conditions).

### The stub model

kagent's OpenAI provider takes a `baseUrl`, so a ~100-line Python server (`stub-llm.py`) can stand in for a model.
kagent v0.10.2 (Go runtime, `OpenAI/Go 3.46.0`) only ever sent **non-streaming `POST /v1/chat/completions`** with
`tools` and `tool_choice: auto`, plus a built-in `ask_user` tool it adds to every agent. No `/models` call, no
streaming. The stub requires nothing more than that.

A full round trip worked: `curl` to the controller's A2A endpoint
(`/api/a2a/<ns>/<agent>/`, JSON-RPC `message/send`), agent asks the stub, stub requests `k8s_get_resources`, the
tool server runs it, the stub summarizes, the answer comes back as a completed A2A task. Same answer every run, so
task checks can assert on it. The stub's own request log is also a great teaching tool: it shows exactly what the
agent sends a model.

For the published version, rewrite the stub in Go (the job asks for Go) and give it pet-aware rules if the tutorial
reuses the zoo.

### Calling an agent

Everything goes through the controller's HTTP server (`svc/kagent-controller`, port 8083); from the dev machine,
`kubectl -n kagent port-forward svc/kagent-controller 8083`. Tested:

| Way in | How | Result |
|---|---|---|
| A2A over HTTP | `POST /api/a2a/<ns>/<agent>/`, JSON-RPC `message/send` with a non-empty `messageId` | Works. Returns a task with `status.state` and `artifacts` |
| MCP | `POST /mcp` on the controller: tools `list_agents` and `invoke_agent` (`{"agent":"kagent/keeper","task":"..."}`) | Works. Any MCP client (Claude Code, Cursor) can call kagent agents |
| Another agent | `tools: [{type: Agent, agent: {name: keeper}}]` | Works. The calling agent sees the other as a tool named `kagent__NS__keeper` with one `request` argument |
| kagent CLI v0.10.2 | `kagent invoke --agent keeper --task ...` | **Fails**: it sends `"messageId": ""`, the agent rejects it, and the error surfaces as `failed to decode response ... errordetails.Typed`. The same request with any `messageId` works. An upstream bug, so the tutorial uses `curl` |
| UI | `kubectl -n kagent port-forward svc/kagent-ui 8080:8080` | Not tried in the spike |

### Failure modes (`broken.yaml`)

| Break | Agent says | Where the truth is |
|---|---|---|
| B1 `ModelConfig` names a missing key Secret | `Accepted=True`, `Ready=False DeploymentNotReady` | Pod in `CreateContainerConfigError`; the **ModelConfig** has `Accepted=False ... Secret "no-such-secret" not found`. Two levels deep. |
| B2 Agent names a missing `ModelConfig` | `Accepted=False ReconcileFailed: ... ModelConfig "no-such-model" not found` | Right there. The easy one. |
| B3 `toolNames` has a tool the server doesn't have | **`Ready=True`** | Silent. The agent runs with only `ask_user`; the model is never offered the tool. Only the agent's startup log (`tools: [k8s_get_pets]`) or the model's request log show it. |
| B4 `RemoteMCPServer` URL is wrong | `Ready=False DeploymentNotReady` | Pod Running but never Ready: it hangs connecting to the MCP server before it serves the agent card, so the readiness probe gets `connection refused`. No error in the log. |

B3 and B4 make a good medium/hard challenge; B1 and B2 are the warm-up.

### Security finding: the tool server is cluster-admin and unauthenticated

- `kagent-tools` runs as a ServiceAccount bound to `kagent-tools-cluster-admin-role`: it can read Secrets, delete
  Deployments and create ClusterRoleBindings.
- The agent's own ServiceAccount can do nothing (`can-i get pods`: no).
- So an agent's `toolNames` list is the only thing making it "read-only", and it's enforced inside the agent
  runtime, not by the server.
- A Pod in an unrelated namespace, with no credentials, ran the MCP handshake against
  `http://kagent-tools.kagent:8084/mcp` and listed Secrets in `kagent`.

This is the default install, not a bug in the spike setup. But it's the best challenge here: "agents are
going to production; make the tool server safe", solved with a scoped ClusterRole for the tool server and a
NetworkPolicy that only admits agent Pods. Flannel (k8s-omni's default) doesn't enforce NetworkPolicy, so the
challenge starts k8s-omni with Calico or Cilium (a start-time option on k8s-omni). Not yet tested on those.

## Agent Sandbox

- gVisor installs on both workers in about 40 s (`install-gvisor.sh`, run as root) and runs Pods with **no KVM**:
  `uname -r` is `4.19.0-gvisor`, dmesg shows `Starting gVisor...`. The nested-virtualization recipe being disabled
  since 2026-07-13 doesn't matter for gVisor. Kata stays out.
- Agent Sandbox v1.0.4 (`sandbox-with-extensions.yaml`) installs `Sandbox` and `SandboxClaim` and is up in 2 s.
- **Gotcha 2: k8s-omni's control plane takes workloads and has no gVisor.** The first Sandbox landed on cplane-01
  and failed with `unable to get OCI runtime`. Fix: label the gVisor nodes and set `scheduling.nodeSelector` on
  the RuntimeClass (`sandbox.yaml`). That's the right way to do it anyway, and worth a paragraph in the tutorial.
- A `Sandbox` with a PVC workspace was Ready in 6 s. `operatingMode: Suspended` deleted the Pod and kept the PVC;
  `Running` brought it back with the workspace file intact. That's the feature the tutorial would be built around.

## How kagent and Agent Sandbox meet

kagent v0.10.2 already has a `SandboxAgent` resource and a "substrate" worker pool with `sandboxClass: gvisor`;
v1 turns this into `SandboxTemplate` and `Harness`. Not explored in this spike: it's off by default and in flux.
A later piece could connect the two once v1 settles.

## Proposed content, in order

1. **Tutorial: How kagent Works: Running an AI Agent as a Kubernetes Resource.** Install (with the StorageClass
   step), stub model, one Agent, trace what the controller builds, talk to it over A2A with `curl`, read the stub's
   request log to see what an agent sends a model. Optional section: swap in a real `ModelConfig` with your own key.
2. **Challenge: Fix the Broken Agents** (medium). B1 to B4 in one namespace; checks use the A2A endpoint and the
   stub's log.
3. **Challenge: Lock Down the Agent Tool Server** (hard). Scoped RBAC plus NetworkPolicy, on Calico or Cilium.
   Checks: an outsider Pod can't reach the MCP port, the tool server can't read Secrets, the keeper agent still works.
4. **Tutorial: Isolating Agent Code with Agent Sandbox and gVisor.** RuntimeClass with scheduling, Sandbox,
   suspend and resume, link Ivan's Firecracker course for the VM side.

## Open questions

- Ollama with a small model on a worker: not tested. Only worth it if a real model adds something the stub can't.
- Calico or Cilium on k8s-omni plus kagent: does everything still fit, and does a NetworkPolicy behave as expected?
- kagent v1.0.0 GA date: decides whether to write the tutorial against v0.10.2 now or wait.
- Docker Hub: the bundled Postgres pulls `docker.io/library/postgres`. Shared Labs IPs have hit Docker Hub rate
  limits before, so point it at `public.ecr.aws/docker/library/postgres` in the published values.

## Round 2: integrations (2026-10-01)

Same playground, kagent v0.10.2. Artifacts: `dev/spikes/kagent/alert-bridge/`, `ci-check.sh`, `real-model.yaml`.

| Integration | Result |
|---|---|
| **Claude Code → kagent over MCP** | **Works.** `claude -p --mcp-config` pointing at the controller's `/mcp` (via `labctl port-forward`) listed the agents and asked `kagent/keeper` a question; 4 turns, $0.03. `invoke_agent` also takes a `context_id` for multi-turn. MCP Inspector CLI works too. `list_agents` only returns Ready agents |
| **Alertmanager → alert bridge → agent → chat** | **Works.** A 170-line stdlib Go service (`alert-bridge/main.go`, run with `go run` from a ConfigMap) takes an Alertmanager v4 webhook, answers 202 at once, asks the agent with `contextId = alert-<fingerprint>`, and posts the answer to a Slack-compatible webhook: 58 ms end to end with the stub. Tested with a simulated webhook, not a real Alertmanager |
| **Streaming** | **Works.** `message/stream` returns SSE: submitted, working ×4, artifact-update, completed (final) |
| **Polling** | **Works.** `tasks/get` by task id returns the stored task with its history |
| **Multi-turn** | **Works.** A second `message/send` with the same `contextId` reached the model with the first exchange in its messages |
| **Outbound credentials** | **Works.** `RemoteMCPServer.spec.headersFrom` with `valueFrom: {type: Secret, name, key}` and plain `value` both arrive as HTTP headers at the tool server |

### With a real model: `claude-haiku-4-5`

`real-model.yaml`: a `ModelConfig` on `claude-haiku-4-5` (kagent's own chart default for Anthropic; `claude-sonnet-5-5`
is the step up) and a read-only `oncall` agent (`k8s_get_resources`, `k8s_describe_resource`, `k8s_get_events`,
`k8s_get_pod_logs`) whose system prompt fixes the answer shape: `WHAT`, `CAUSE`, `NEXT`, `VERDICT: HEALTHY|UNHEALTHY`.
The key lives only in the `kagent-anthropic` Secret. No API errors from kagent's Anthropic client. The scenario is a
bare Pod `payments/payments-api` that prints `FATAL: DATABASE_URL not set` and exits 1.

| Test | Result |
|---|---|
| Direct A2A question | Correct diagnosis in **5 s**, quoting the log line, `VERDICT: UNHEALTHY`. 8 tool calls; the first (`k8s_get_resources` for a *deployment*) failed because it's a bare Pod, and the model recovered via pods, events and logs |
| Alert bridge | Webhook 202 at once, answer posted to the chat webhook **4.4 s** later, naming the cause and noticing the container command prints the error itself |
| CI check | `checkout` (healthy nginx Deployment): `VERDICT: HEALTHY`, exit 0, 4 s. `payments-api`: `VERDICT: UNHEALTHY`, exit 1, ~4 s |
| Claude Code → MCP → `oncall` | 3 turns, $0.08 on the Claude Code side. It relayed the cause and wrote the `env:` fix, noting the agent couldn't know the real connection string. (It assumed a Deployment's `spec.template`; the scenario is a bare Pod, so a talk scenario should use a Deployment) |

### Auth: trusted-proxy mode doesn't verify tokens

`controller.auth.mode: trusted-proxy` (the mode meant for oauth2-proxy) parses the bearer JWT **without verifying its
signature** (`go/core/internal/httpserver/auth/proxy_authn.go`: "Parse JWT without validation (oauth2-proxy or k8s
service account already validated)"). Tested: no token and a garbage token get 401; an unsigned hand-made JWT with
`sub: ceo@example.com` is accepted, `/api/me` returns that identity, and the session is stored under it. Consequences:

- In trusted-proxy mode the controller must only be reachable through oauth2-proxy: a NetworkPolicy that admits only
  the proxy (and the agents' own calls back) is not optional. The same applies to `unsecure` mode, which trusts
  `X-User-Id`.
- In-cluster callers can use their projected ServiceAccount token as the bearer: kagent records them as
  `system:serviceaccount:<ns>:<name>` (the alert bridge showed up exactly like that). Useful for audit, but it's an
  unverified claim too, so it's only as trustworthy as the network path.
- Identity is used to own sessions; the spike found no per-user authorization on which agents a caller may invoke.
  Not exhaustively checked.

Full oauth2-proxy + OIDC (Dex) end-to-end: not done yet.
