---
kind: tutorial

title: "How AI Agents Run on Kubernetes: Hiring a Night Keeper With kagent"

description: |
  Run an AI agent on Kubernetes the way you run everything else: as a custom resource that a controller turns into a Deployment.
  The zoo needs someone on the night shift. Hire a kagent agent that checks on the Pets, see what the controller builds for it, follow one question through the model and the tools, and find out who really holds the keys.

categories:
- kubernetes
- gen-ai

tagz:
- kagent
- ai-agents
- mcp
- a2a
- operator

createdAt: 2026-10-01
updatedAt: 2026-10-01

cover: __static__/night-shift-overview.png

playground:
  name: k8s-omni
  startupFiles:
  - path: /home/laborant/night-keeper
    source: __static__/night-keeper.tar.gz
    extract: true
    owner: laborant
    machines: [dev-machine]
  - path: /opt/night-keeper-setup
    source: __static__/setup.tar.gz
    extract: true
    owner: laborant
    machines: [dev-machine]
  - path: /etc/default/code-server
    content: |
      CODE_SERVER_PATH=/home/laborant/night-keeper
    owner: root
    mode: "644"
    machines: [dev-machine]

tasks:
  init_zoo:
    init: true
    machine: dev-machine
    user: laborant
    timeout_seconds: 600
    run: |
      bash /opt/night-keeper-setup/init-zoo.sh

  verify_kagent_running:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    run: |
      [ "$(kubectl get deploy -n kagent kagent-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" = "1" ] || exit 1
      [ "$(kubectl get pvc -n kagent kagent-postgresql -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ]
    hintcheck: |
      if ! kubectl get deploy -n kagent kagent-controller >/dev/null 2>&1; then
        echo "kagent isn't installed yet. Run the two helm install commands from this section."
      elif [ "$(kubectl get pvc -n kagent kagent-postgresql -o jsonpath='{.status.phase}' 2>/dev/null)" != "Bound" ]; then
        echo "The database volume is still Pending. Does the cluster have a default StorageClass? Check with: kubectl get storageclass"
      else
        echo "The controller is still restarting. It retries with a growing delay, so give it a minute or two."
      fi
      exit 0

  verify_keeper_hired:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_kagent_running
    run: |
      [ "$(kubectl get agent -n kagent night-keeper -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
    hintcheck: |
      if ! kubectl get deploy -n kagent keeper-model >/dev/null 2>&1; then
        echo "The keeper model isn't running. Create its ConfigMap and apply model/deploy.yaml first."
      elif ! kubectl get agent -n kagent night-keeper >/dev/null 2>&1; then
        echo "There's no night-keeper Agent yet. Apply ~/night-keeper/night-keeper.yaml."
      else
        echo "The Agent exists but isn't Ready. Check its conditions: kubectl describe agent -n kagent night-keeper"
      fi
      exit 0

  verify_keeper_reports:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_keeper_hired
    run: |
      kubectl logs -n kagent deploy/keeper-model 2>/dev/null | grep -q -- '-> reply: call k8s_get_resources'
    hintcheck: |
      echo "The keeper hasn't looked at the Pets yet. Start the port-forward and radio it: ./radio night-keeper \"Who's hungry?\""
      exit 0

  verify_tool_server_read_only:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_keeper_reports
    run: |
      SA=system:serviceaccount:kagent:kagent-tools
      [ "$(kubectl auth can-i list secrets -n kagent --as=$SA)" = "no" ] || exit 1
      [ "$(kubectl auth can-i delete deployments -A --as=$SA)" = "no" ] || exit 1
      [ "$(kubectl auth can-i list pets.zoo.example.com -n zoo --as=$SA)" = "yes" ] || exit 1
      answer=$(kubectl exec -n kagent deploy/keeper-model -- python -c '
      import json, urllib.request
      body = {"jsonrpc": "2.0", "id": 1, "method": "message/send", "params": {"message": {
          "role": "user", "messageId": "checkpoint", "parts": [{"kind": "text", "text": "Who is hungry?"}]}}}
      req = urllib.request.Request("http://kagent-controller.kagent:8083/api/a2a/kagent/night-keeper/",
          json.dumps(body).encode(), {"content-type": "application/json"})
      print(json.load(urllib.request.urlopen(req, timeout=50))["result"]["artifacts"][0]["parts"][0]["text"])
      ' 2>/dev/null)
      echo "$answer" | grep -q "smaug the dragon"
    hintcheck: |
      SA=system:serviceaccount:kagent:kagent-tools
      if [ "$(kubectl auth can-i list secrets -n kagent --as=$SA)" = "yes" ]; then
        echo "The tool server can still read Secrets. Upgrade the release with tool-server-read-only.yaml (and then tool-server-read-pets.yaml)."
      elif [ "$(kubectl auth can-i list pets.zoo.example.com -n zoo --as=$SA)" = "no" ]; then
        echo "The tool server can't read Pets, so the keeper is blind. The built-in read-only role doesn't know about CRDs: use tool-server-read-pets.yaml."
      else
        echo "The permissions look right. Is the night keeper answering? Try: ./radio night-keeper \"Who's hungry?\""
      fi
      exit 0
---

Welcome wanderer!

If you've landed on this tutorial, you've probably seen a demo of an AI agent fixing a cluster,
and you want to know what one is once it runs in yours.

Here's the short version. An agent is a program that sends your question to a language model (LLM),
together with a list of tools the model may use.
The model doesn't answer straight away. It asks the program to call a tool, reads the result, and only then answers.
[kagent](https://kagent.dev) is a CNCF project that runs agents like that on Kubernetes.
You describe an agent in YAML, and a controller builds and runs it, the same way the Deployment controller runs your Pods.

By the end of this tutorial, the zoo will have a night keeper.
When the day staff go home, they radio it with questions like "Who's hungry?",
and it looks at the Pets in the cluster and reports back.
Along the way, you'll see what kagent builds for an agent, what an agent sends a model, how an agent can be Ready and still useless,
and why the most powerful thing in this setup isn't the agent at all.

Here's the whole picture of what you'll end up with:

::image-box
---
:src: __static__/night-shift-overview.png
:alt: 'The night shift: a keeper on the dev machine radios the night-keeper Agent through the kagent controller. The controller has turned the Agent resource into a Deployment, a Service, a ServiceAccount and a config Secret. The agent Pod asks the keeper-model for a decision, calls the k8s_get_resources tool on the kagent tool server, which reads the Pets in the zoo namespace, and sends the result back to the model, which writes the night report.'
---
::

I'm reusing the Pet zoo from [How Kubernetes CRDs Work](/tutorials/open-a-kubernetes-zoo-9ad54ae8)
and [How Kubernetes Operators Work](/tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c).
You don't need to have done either. The playground starts with the zoo already open: four Pets, each with a mood.

There's one thing I want to be upfront about: **the model in this tutorial isn't a real LLM.**
It's a 100-line script that follows three fixed rules, so it gives the same answer every time and needs no API key.
That's on purpose. Everything interesting about running agents on Kubernetes happens around the model, not inside it,
and a scripted model lets us watch all of it. At the end, I'll show you how to swap in a real one.

## Prerequisites

You'll need to be comfortable with `kubectl` and with Helm installs.
It helps to know what a controller is (it watches resources and changes the cluster to match), but I'll explain what we need.
No AI or Python knowledge needed.

The playground has a multi-node Kubernetes cluster, and `kubectl` and `helm` on the `dev-machine` are set up to talk to it.
Everything we use is in `~/night-keeper`, which is also where the IDE tab opens.
The checkpoints turn green on their own when the cluster gets to the right state.

## Opening the zoo at night

Let's see who's in the zoo tonight:

```sh
kubectl get pets -n zoo
```

```text
NAME       SPECIES   FACE   MOOD      TOY     LAST FED   AGE
mochi      cat       🙀      Hungry    yarn               1s
prickles   cactus    🌵      Happy                        1s
rex        dog       🐶      Happy     stick              1s
smaug      dragon    💨      RanAway                      1s
```

`mochi` is hungry, and `smaug` has run away. Somebody should be keeping an eye on this.
Let's hire that somebody.

## Installing kagent

kagent ships as two Helm charts: one with its CRDs, one with everything else.
Before installing, have a look at `~/night-keeper/kagent-values.yaml`.
It turns off the ten example agents kagent installs by default, because we're going to build our own.
It also points kagent's default model at `keeper-model`, which we'll start in a minute:

```yaml [~/night-keeper/kagent-values.yaml]
{{excerpt:night-keeper/kagent-values.yaml#from=^providers:#to=baseUrl}}
```

Install both charts:

```sh
helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version 0.10.2 --namespace kagent --create-namespace
helm install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 0.10.2 --namespace kagent -f ~/night-keeper/kagent-values.yaml
```

Give it a minute, then look at what came up:

```sh
kubectl get pods -n kagent
```

```text
NAME                                 READY   STATUS    RESTARTS      AGE
kagent-controller-75744fddf5-fnc2j   0/1     Error     2 (27s ago)   45s
kagent-postgresql-f4c97f6d6-mj25l    0/1     Pending   0             45s
kagent-tools-54959b659c-sj5dn        1/1     Running   0             45s
kagent-ui-fdd4745f4-r8sws            1/1     Running   0             45s
```

Not a great start. Here's what each of these is:

| Pod | What it does |
|-----|--------------|
| `kagent-controller` | The operator. It watches `Agent` resources and builds what they need. It also serves the API we'll talk to agents through |
| `kagent-postgresql` | Where kagent keeps conversations |
| `kagent-tools` | A tool server with about a hundred Kubernetes tools agents can use. Remember this one |
| `kagent-ui` | A web chat page. We won't need it |

The controller is crashing, so let's ask it why:

```sh
kubectl logs -n kagent deploy/kagent-controller --tail=1 | jq -r .error
```

```text
core migrations: create migration driver for core: failed to connect to `user=kagent database=kagent`: 10.108.85.21:5432 (kagent-postgresql.kagent.svc): dial error: dial tcp 10.108.85.21:5432: connect: connection refused
```

It can't reach the database, and the database is `Pending`. Pending Pods are usually waiting for something:

```sh
kubectl get pvc -n kagent
kubectl get storageclass
```

```text
NAME                STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
kagent-postgresql   Pending                                                     <unset>                 51s
No resources found
```

The database asked for a volume, and this cluster has no StorageClass to make one from.
Plenty of real clusters are like this, especially ones built with `kubeadm`, which is how this playground was built.
The usual fix for a lab cluster is Rancher's local-path provisioner, which makes volumes out of a directory on the node.
We'll mark it as the default, so claims that don't name a StorageClass get this one:

```sh
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

You don't need to recreate the waiting claim.
Since Kubernetes v1.28, a new default StorageClass is also given to claims that are still waiting for one:

```sh
kubectl get pvc -n kagent
```

```text
NAME                STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
kagent-postgresql   Bound    pvc-4fe1681a-715d-469e-ab20-4f54b950a198   500Mi      RWO            local-path     <unset>                 90s
```

The controller restarts with a growing delay, so it may take another minute to notice:

```sh
kubectl wait -n kagent --for=condition=Available deploy --all --timeout=180s
kubectl get pods -n kagent
```

```text
NAME                                 READY   STATUS    RESTARTS      AGE
kagent-controller-75744fddf5-fnc2j   1/1     Running   4 (69s ago)   2m1s
kagent-postgresql-f4c97f6d6-mj25l    1/1     Running   0             2m1s
kagent-tools-54959b659c-sj5dn        1/1     Running   0             2m1s
kagent-ui-fdd4745f4-r8sws            1/1     Running   0             2m1s
```

::simple-task
---
:tasks: tasks
:name: verify_kagent_running
---
#active
Waiting for the kagent controller to run with its database on a bound volume...

#completed
kagent is running, and its database has a volume.
::

kagent added a handful of resource types to the API, and two objects already exist: the model we pointed at in the values file, and the tool server:

```sh
kubectl api-resources --api-group=kagent.dev
kubectl get modelconfigs,remotemcpservers -n kagent
```

```text
NAME                   SHORTNAMES   APIVERSION            NAMESPACED   KIND
agentharnesses         ahr          kagent.dev/v1alpha2   true         AgentHarness
agents                              kagent.dev/v1alpha2   true         Agent
mcpservers                          kagent.dev/v1alpha1   true         MCPServer
memories                            kagent.dev/v1alpha1   true         Memory
modelconfigs           mc           kagent.dev/v1alpha2   true         ModelConfig
modelproviderconfigs   mprov        kagent.dev/v1alpha2   true         ModelProviderConfig
remotemcpservers       rmcps        kagent.dev/v1alpha2   true         RemoteMCPServer
sandboxagents                       kagent.dev/v1alpha2   true         SandboxAgent
toolservers            ts           kagent.dev/v1alpha1   true         ToolServer

NAME                                          PROVIDER   MODEL
modelconfig.kagent.dev/default-model-config   OpenAI     keeper-model

NAME                                            PROTOCOL          URL                                   ACCEPTED
remotemcpserver.kagent.dev/kagent-tool-server   STREAMABLE_HTTP   http://kagent-tools.kagent:8084/mcp   True
```

We only need three of them:

- A **`ModelConfig`** says which model to use and where it lives. Ours says "an OpenAI-compatible model called `keeper-model`".
  Lots of model servers speak OpenAI's API, which is why that provider is the one to use for anything self-hosted.
- A **`RemoteMCPServer`** is a tool server. MCP, the Model Context Protocol, is the standard way to offer tools to agents.
  An MCP server lists its tools and runs them when asked.
- An **`Agent`** ties the two together and adds instructions. We'll write one shortly.

## Giving the keeper a brain

The model is `~/night-keeper/model/keeper-model.py`. Open it in the IDE tab. It's short, and it's the only Python in this tutorial.
The part that matters is the three rules it follows:

```python [~/night-keeper/model/keeper-model.py]
{{excerpt:night-keeper/model/keeper-model.py#from=^def decide#to=I'm not sure}}
```

A real LLM would decide what to do by itself. Ours always makes the same choice,
which is exactly what a capable model would do for "Who's hungry?" with one tool to look at the cluster.
It speaks the one endpoint kagent uses, `POST /v1/chat/completions`, and it prints every request and reply, so we can watch it think.

Load it into a ConfigMap and run it:

```sh
cd ~/night-keeper
kubectl -n kagent create configmap keeper-model --from-file=model/keeper-model.py
kubectl apply -f model/deploy.yaml
kubectl -n kagent rollout status deploy/keeper-model
```

```text
configmap/keeper-model created
deployment.apps/keeper-model created
service/keeper-model created
Waiting for deployment "keeper-model" rollout to finish: 0 of 1 updated replicas are available...
deployment "keeper-model" successfully rolled out
```

## Hiring the night keeper

Here's the whole agent:

```yaml [~/night-keeper/night-keeper.yaml]
{{file:night-keeper/night-keeper.yaml}}
```

The `systemMessage` is the job description the model gets with every question.
`modelConfig` picks the brain, and `tools` gives the keeper exactly one tool from kagent's tool server: `k8s_get_resources`, which works like `kubectl get`.

Apply it, and watch it get hired:

```sh
kubectl apply -f night-keeper.yaml
kubectl get agents -n kagent
```

```text
agent.kagent.dev/night-keeper created
NAME           TYPE          RUNTIME   READY   ACCEPTED
night-keeper   Declarative   go                True
```

A few seconds later:

```text
NAME           TYPE          RUNTIME   READY   ACCEPTED
night-keeper   Declarative   go        True    True
```

::simple-task
---
:tasks: tasks
:name: verify_keeper_hired
---
#active
Waiting for the night-keeper Agent to be Ready...

#completed
The night keeper is hired and ready for its shift.
::

### What the controller built

If you've done the operator tutorial, this will feel familiar. The `Agent` is a custom resource, and the kagent controller turned it into ordinary Kubernetes objects:

```sh
kubectl get all,secret,serviceaccount -n kagent -l app.kubernetes.io/name=night-keeper
```

```text
NAME                               READY   STATUS    RESTARTS   AGE
pod/night-keeper-8d9db4499-wll9d   1/1     Running   0          13s

NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/night-keeper   ClusterIP   10.107.206.28   <none>        8080/TCP   13s

NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/night-keeper   1/1     1            1           13s

NAME                                     DESIRED   CURRENT   READY   AGE
replicaset.apps/night-keeper-8d9db4499   1         1         1       13s

NAME                  TYPE     DATA   AGE
secret/night-keeper   Opaque   2      13s

NAME                          AGE
serviceaccount/night-keeper   13s
```

The Deployment runs kagent's agent runtime, the program that runs the question, tool, answer loop.
They're all owned by the Agent, so deleting the Agent cleans them up:

```sh
kubectl get deploy night-keeper -n kagent -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

```text
Agent/night-keeper
```

The most interesting one is the Secret. It's the agent's compiled configuration, everything the runtime needs in one file:

```sh
kubectl get secret night-keeper -n kagent -o jsonpath='{.data.config\.json}' | base64 -d \
  | jq '{model, http_tools, instruction}'
```

```json
{
  "model": {
    "type": "openai",
    "model": "keeper-model",
    "base_url": "http://keeper-model.kagent:8080/v1",
    "api_format": "chatCompletions"
  },
  "http_tools": [
    {
      "params": {
        "url": "http://kagent-tools.kagent:8084/mcp",
        "headers": {},
        "timeout": 30,
        "sse_read_timeout": 300,
        "terminate_on_close": true
      },
      "tools": [
        "k8s_get_resources"
      ]
    }
  ],
  "instruction": "You are the zoo's night keeper. When a keeper radios in, look at the Pets in the zoo namespace\nand report who is hungry and who has run away. You only look; you never change anything.\n"
}
```

The controller looked up the `ModelConfig` and the `RemoteMCPServer` by name and wrote down their addresses.
The agent Pod never reads a kagent resource. It reads this file, and that matters later.

## Radioing the keeper

kagent's controller is also the front door to every agent.
It speaks [A2A](https://a2a-protocol.org), the Agent2Agent protocol, which is JSON-RPC over HTTP.
Each agent gets its own URL, `/api/a2a/<namespace>/<agent>/`.
Forward the controller's port in a second terminal tab and leave it running:

```sh
kubectl -n kagent port-forward svc/kagent-controller 8083:8083
```

Every A2A agent describes itself on an "agent card":

```sh
curl -s http://localhost:8083/api/a2a/kagent/night-keeper/.well-known/agent-card.json \
  | jq '{name, description, url}'
```

```json
{
  "name": "night_keeper",
  "description": "Watches the zoo at night and reports on the Pets.",
  "url": "http://kagent-controller.kagent.svc:8083/api/a2a/kagent/night-keeper/"
}
```

Now the question. Here's the raw request once, so you can see there's nothing magic in it:

```sh
curl -s http://localhost:8083/api/a2a/kagent/night-keeper/ \
  -H 'content-type: application/json' \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "message/send",
       "params": {"message": {"role": "user", "messageId": "radio-1",
         "parts": [{"kind": "text", "text": "Who is hungry tonight?"}]}}}' \
  | jq '{kind: .result.kind, state: .result.status.state, answer: .result.artifacts[0].parts[0].text}'
```

```json
{
  "kind": "task",
  "state": "completed",
  "answer": "Hungry: mochi the cat. Ran away: smaug the dragon! Everyone else is fine: prickles the cactus, rex the dog."
}
```

The keeper looked at the zoo and got it right.
From now on, we'll use `~/night-keeper/radio`, which sends the same request and prints only the answer:

```sh
./radio night-keeper "Anything I should know about tonight?"
```

```text
Hungry: mochi the cat. Ran away: smaug the dragon! Everyone else is fine: prickles the cactus, rex the dog.
```

::simple-task
---
:tasks: tasks
:name: verify_keeper_reports
---
#active
Waiting for the night keeper to look at the Pets...

#completed
The night keeper used its tool and reported on the Pets.
::

### Following one question

So what happened between the question and the answer? The model printed its side of the conversation.
These lines are the first question:

```sh
kubectl logs -n kagent deploy/keeper-model | head -n 5
```

```text
keeper-model listening on :8080
<- asked: messages=['system', 'user'] tools=['ask_user', 'k8s_get_resources']
-> reply: call k8s_get_resources {"resource_type": "pets", "namespace": "zoo"}
<- asked: messages=['system', 'user', 'assistant', 'tool'] tools=['ask_user', 'k8s_get_resources']
-> reply: Hungry: mochi the cat. Ran away: smaug the dragon! Everyone else is fine: prickles the cactus, rex the dog.
```

Each question took two round trips to the model:

1. The agent sent the job description (`system`), your question (`user`) and the list of tools.
   The model didn't answer. It replied with a **tool call**: "run `k8s_get_resources` for `pets` in `zoo`".
2. The agent called that tool on the tool server, which ran the equivalent of `kubectl get pets -n zoo`.
   Then it went back to the model with everything so far plus the tool's output (`tool`). This time, the model answered.

That loop is what makes something an agent. The model only ever writes text. The agent runtime is the part that acts.
(`ask_user` is a tool kagent adds to every agent, so it can ask you a follow-up question. Ours never does.)

The keeper reads the live cluster every time, too. Pretend a keeper just fed `mochi`:

```sh
kubectl patch pet -n zoo mochi --subresource=status --type=merge \
  -p '{"status":{"mood":"Happy","face":"😺"}}'
./radio night-keeper "Is everyone fed now?"
```

```text
pet.zoo.example.com/mochi patched
Ran away: smaug the dragon! Everyone else is fine: mochi the cat, prickles the cactus, rex the dog.
```

## A keeper who can't see

Let's break something on purpose, the kind of typo that happens in a real repo.
Change the tool name to one that sounds right but doesn't exist:

```sh
sed -i 's/k8s_get_resources/k8s_get_pets/' night-keeper.yaml
kubectl apply -f night-keeper.yaml
kubectl rollout status deploy/night-keeper -n kagent
kubectl get agents -n kagent
```

```text
agent.kagent.dev/night-keeper configured
deployment "night-keeper" successfully rolled out
NAME           TYPE          RUNTIME   READY   ACCEPTED
night-keeper   Declarative   go        True    True
```

Accepted and Ready. Now radio it:

```sh
./radio night-keeper "Who is hungry?"
```

```text
I can't see the zoo from here. Nobody gave me a tool to look at the Pets with.
```

The model's log shows why. The tool list it received is empty, apart from `ask_user`:

```sh
kubectl logs -n kagent deploy/keeper-model --tail=2
```

```text
<- asked: messages=['system', 'user'] tools=['ask_user']
-> reply: I can't see the zoo from here. Nobody gave me a tool to look at the Pets with.
```

kagent passes the tool names on as a filter, and a filter that matches nothing isn't an error.
The night-keeper Pod's log shows the name it was given:

```sh
kubectl logs -n kagent deploy/night-keeper | grep "Adding HTTP MCP tool" | jq -c '{msg, url, tools}'
```

```text
{"msg":"Adding HTTP MCP tool","url":"http://kagent-tools.kagent:8084/mcp","tools":["k8s_get_pets"]}
```

And the `RemoteMCPServer` lists the tools that really exist. All 124 of them are in its status:

```sh
kubectl get remotemcpserver kagent-tool-server -n kagent -o json \
  | jq -r '.status.discoveredTools[].name' | grep get_res
```

```text
k8s_get_resource_yaml
k8s_get_resources
```

Put the right name back:

```sh
sed -i 's/k8s_get_pets/k8s_get_resources/' night-keeper.yaml
kubectl apply -f night-keeper.yaml
kubectl rollout status deploy/night-keeper -n kagent
./radio night-keeper "Who is hungry?"
```

```text
agent.kagent.dev/night-keeper configured
deployment "night-keeper" successfully rolled out
Ran away: smaug the dragon! Everyone else is fine: mochi the cat, prickles the cactus, rex the dog.
```

`Ready` means the agent's Pod is up. It doesn't mean the agent can do its job.
With a real LLM, this failure is even quieter: the model answers anyway, from what it already knows, and sounds sure of itself.

## Who holds the keys?

The keeper's job description says "You only look; you never change anything."
So what stops it from changing things? First, what can the agent's own ServiceAccount do?

```sh
for v in "list pets.zoo.example.com -n zoo" "list secrets -n kagent" "delete deployments -A"; do
  echo "night-keeper: $v -> $(kubectl auth can-i $v --as=system:serviceaccount:kagent:night-keeper)"
done
```

```text
night-keeper: list pets.zoo.example.com -n zoo -> no
night-keeper: list secrets -n kagent -> no
night-keeper: delete deployments -A -> no
```

Nothing at all, not even list the Pets it just reported on.
That's because the agent never talks to the API server. The tool server does. So what can the tool server do?

```sh
for v in "list pets.zoo.example.com -n zoo" "list secrets -n kagent" "delete deployments -A"; do
  echo "kagent-tools: $v -> $(kubectl auth can-i $v --as=system:serviceaccount:kagent:kagent-tools)"
done
kubectl get clusterrole kagent-tools-cluster-admin-role -o jsonpath='{.rules}{"\n"}'
```

```text
kagent-tools: list pets.zoo.example.com -n zoo -> yes
kagent-tools: list secrets -n kagent -> yes
kagent-tools: delete deployments -A -> yes
[{"apiGroups":["*"],"resources":["*"],"verbs":["*"]},{"nonResourceURLs":["*"],"verbs":["*"]}]
```

Everything. By default, kagent's tool server runs as cluster-admin.
The only thing keeping our keeper read-only is the `toolNames` list in its YAML, and that list is enforced by the agent runtime, not by the tool server.

So who else can talk to the tool server? `~/night-keeper/intruder.sh` is a short script that does what any Pod could do:
it connects to the tool server, with no credentials, and asks it to list the Secrets in the `kagent` namespace.
Run it from a namespace that has nothing to do with kagent:

```sh
kubectl create namespace visitors
kubectl -n visitors create configmap intruder --from-file=intruder.sh
kubectl apply -f intruder-pod.yaml
kubectl wait -n visitors pod/intruder --for=jsonpath='{.status.phase}'=Succeeded
kubectl logs -n visitors intruder
```

```text
NAME                                TYPE                 DATA   AGE
kagent-openai                       Opaque               1      3m49s
kagent-postgresql                   Opaque               1      3m49s
night-keeper                        Opaque               2      98s
sh.helm.release.v1.kagent-crds.v1   helm.sh/release.v1   1      3m50s
sh.helm.release.v1.kagent.v1        helm.sh/release.v1   1      3m49s
```

A Pod in `visitors` just listed the Secrets in `kagent`, including the model's API key Secret, through a door that was supposed to be for agents.
It could have deleted Deployments the same way.

### Taking the keys away

The tool server's chart has a switch for this, `kagent-tools.rbac.readOnly`.
It replaces cluster-admin with `get`, `list` and `watch` on the built-in resources, and no Secrets at all:

```sh
helm upgrade kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version 0.10.2 -n kagent \
  -f kagent-values.yaml -f tool-server-read-only.yaml
for v in "list secrets -n kagent" "delete deployments -A" "list pods -n zoo" "list pets.zoo.example.com -n zoo"; do
  echo "kagent-tools: $v -> $(kubectl auth can-i $v --as=system:serviceaccount:kagent:kagent-tools)"
done
```

```text
kagent-tools: list secrets -n kagent -> no
kagent-tools: delete deployments -A -> no
kagent-tools: list pods -n zoo -> yes
kagent-tools: list pets.zoo.example.com -n zoo -> no
```

Secrets and deletes are gone. But look at the last line. Radio the keeper:

```sh
./radio night-keeper "Who is hungry?"
```

```text
I tried to look at the Pets, but got this instead:
{"error":"Tool execution failed. Details: [Kubernetes] get pets -n zoo -o wide failed: exit status 1"}
```

The read-only role only knows about Kubernetes' own resources. Pets are ours, so we have to list them ourselves:

```yaml [~/night-keeper/tool-server-read-pets.yaml]
{{file:night-keeper/tool-server-read-pets.yaml|strip-comments}}
```

```sh
helm upgrade kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version 0.10.2 -n kagent \
  -f kagent-values.yaml -f tool-server-read-pets.yaml
./radio night-keeper "Who is hungry?"
```

```text
Ran away: smaug the dragon! Everyone else is fine: mochi the cat, prickles the cactus, rex the dog.
```

And the intruder?

```sh
kubectl delete pod -n visitors intruder
kubectl apply -f intruder-pod.yaml
kubectl wait -n visitors pod/intruder --for=jsonpath='{.status.phase}'=Succeeded
kubectl logs -n visitors intruder
```

```text
[Kubernetes] get secrets -n kagent -o wide failed: exit status 1
```

::simple-task
---
:tasks: tasks
:name: verify_tool_server_read_only
---
#active
Waiting for the tool server to lose its cluster-admin role, while the night keeper can still see the Pets...

#completed
The tool server can read Pets, Pods and Events, but no Secrets, and it can't change anything. The night keeper still works.
::

The intruder can still connect, though. It can't do much anymore.
Closing the door itself takes a NetworkPolicy that lets only agent Pods reach the tool server's port,
and a CNI plugin that enforces it. This playground's default, flannel, doesn't. That's a good next step if you start the playground with Calico or Cilium.

## Bringing a real model

Everything so far works the same with a real LLM. Only the `ModelConfig` changes.
If you have an Anthropic API key, store it in a Secret (`read -s` keeps it off your screen and out of your shell history),
then point the default model at Claude:

```sh
read -rs KEY && kubectl -n kagent create secret generic kagent-anthropic \
  --from-literal=ANTHROPIC_API_KEY="$KEY"; unset KEY
kubectl apply -f - <<'EOF'
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: kagent
spec:
  provider: Anthropic
  model: claude-haiku-4-5
  apiKeySecret: kagent-anthropic
  apiKeySecretKey: ANTHROPIC_API_KEY
EOF
```

The controller rebuilds the agent's config Secret and rolls its Deployment, so there's nothing to restart by hand.
Radio it again, and try questions the scripted model could never handle, like "Which Pet should I look for first, and why?"
OpenAI, Gemini, Ollama and others work the same way: see [kagent's provider docs](https://kagent.dev/docs/kagent/supported-providers).

`default-model-config` came from the Helm chart, so the next `helm upgrade` would put the scripted model back.
For anything longer-lived, set the provider in the Helm values instead, or give the agent its own `ModelConfig`.

## Common points to debug

If something doesn't behave the way you expect:

- If `kagent-postgresql` stays `Pending`, check `kubectl get storageclass`. There has to be one marked `(default)`.
- If the controller keeps restarting after the database is up, wait. It backs off between restarts, and the next one usually works.
  `kubectl logs -n kagent deploy/kagent-controller --tail=1 | jq -r .error` shows why the last one failed.
- If `./radio` prints nothing or `curl: (7)`, the port-forward isn't running. Start it again in another tab.
- If an Agent is `Accepted=False`, `kubectl describe agent` says why, for example a `ModelConfig` that doesn't exist.
  If it's `Accepted=True` but not `Ready`, look at its Pod: `kubectl get pods -n kagent -l app.kubernetes.io/name=<agent>`.
- If an agent answers without using its tools, compare its `toolNames` with `.status.discoveredTools` on the `RemoteMCPServer`.
- If a tool fails with `exit status 1`, check what the tool server is allowed to do with `kubectl auth can-i ... --as=system:serviceaccount:kagent:kagent-tools`.

## Wrapping up

That's it! The zoo has a night keeper.

An agent in kagent is a custom resource. The controller turns it into a Deployment, a Service, a ServiceAccount and a config Secret,
and reports `Accepted` and `Ready` like any well-behaved operator.
The agent itself is a loop: ask the model, run the tool it asks for, ask again, answer.
Text is all the model produces. The tools are what touch the cluster, so whoever runs the tools holds the keys.
In kagent, that's the tool server, and out of the box it can do anything in the cluster.

A real setup usually adds:

- A real model in the `ModelConfig`, with its key in a Secret managed the way you manage other secrets.
- Read-only tool servers by default, with `additionalRules` for the CRDs agents should see, and NetworkPolicies so only agents can reach them.
- Agents defined in Git and deployed with the rest of your manifests.
- Something other than `curl` on the other end: a chat bot, an alert webhook, a CI step, or a coding agent like Claude Code,
  which can call kagent agents through the controller's MCP endpoint.

### References

- [kagent documentation](https://kagent.dev/docs/kagent)
- [kagent on GitHub](https://github.com/kagent-dev/kagent)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [Agent2Agent (A2A) protocol](https://a2a-protocol.org)
- [Rancher local-path provisioner](https://github.com/rancher/local-path-provisioner)
- [Kubernetes v1.28: Retroactive Default StorageClass move to GA](https://kubernetes.io/blog/2023/08/18/retroactive-default-storage-class-ga/)
- [How Kubernetes CRDs Work: Designing a Validated API From Scratch](/tutorials/open-a-kubernetes-zoo-9ad54ae8)
- [How Kubernetes Operators Work: Building a Controller From Scratch](/tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c)
