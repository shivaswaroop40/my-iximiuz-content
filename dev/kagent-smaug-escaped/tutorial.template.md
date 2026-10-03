---
kind: tutorial

title: "How AI Agents Run on Kubernetes: Solving a Zoo Mystery With kagent"

description: |
  Smaug the dragon has gone missing from the zoo. Hire an AI agent with kagent, ask it where Smaug went,
  and watch it work the case one tool call at a time: the Pods, then the logs, then the ConfigMap the logs point to.
  No API key needed.

categories:
- kubernetes
- gen-ai

tagz:
- kagent
- ai-agents
- mcp
- operator

createdAt: 2026-10-02
updatedAt: 2026-10-02

cover: __static__/detective-overview.png

playground:
  name: k8s-omni
  startupFiles:
  - path: /home/laborant/detective
    source: __static__/detective.tar.gz
    extract: true
    owner: laborant
    machines: [dev-machine]
  - path: /opt/zoo-setup
    source: __static__/setup.tar.gz
    extract: true
    owner: laborant
    machines: [dev-machine]
  - path: /etc/default/code-server
    content: |
      CODE_SERVER_PATH=/home/laborant/detective
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
      bash /opt/zoo-setup/init-zoo.sh

  verify_kagent_running:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    run: |
      [ "$(kubectl get deploy -n kagent kagent-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" = "1" ]
    hintcheck: |
      if ! kubectl get deploy -n kagent kagent-controller >/dev/null 2>&1; then
        echo "kagent isn't installed yet. Run both helm install commands from this section."
      else
        echo "The controller is still starting. It restarts a few times while its database comes up, so give it a minute or two."
      fi
      exit 0

  verify_detective_hired:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_kagent_running
    run: |
      [ "$(kubectl get agent -n kagent detective -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
    hintcheck: |
      if ! kubectl get deploy -n kagent detective-model >/dev/null 2>&1; then
        echo "The detective's model isn't running. Create its ConfigMap and apply model/deploy.yaml first."
      elif ! kubectl get agent -n kagent detective >/dev/null 2>&1; then
        echo "There's no detective Agent yet. Apply ~/detective/detective.yaml."
      else
        echo "The Agent exists but isn't Ready yet. Check its conditions: kubectl describe agent -n kagent detective"
      fi
      exit 0

  verify_case_solved:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_detective_hired
    run: |
      kubectl logs -n kagent deploy/detective-model 2>/dev/null | grep -q 'rule 4: write it up'
    hintcheck: |
      echo "The detective hasn't solved the case yet. Start the port-forward and ask it: ./radio detective \"Where is Smaug?\""
      exit 0

  verify_smaug_home:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_case_solved
    run: |
      [ "$(kubectl get deploy -n zoo smaug -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" = "1" ] || exit 1
      kubectl logs -n kagent deploy/detective-model 2>/dev/null | grep -q 'rule 2: every Pod is Running'
    hintcheck: |
      t=$(kubectl get configmap -n zoo smaug-cave -o jsonpath='{.data.temperature}' 2>/dev/null)
      if [ "${t:-0}" -lt 40 ]; then
        echo "The cave is still ${t}°C. Smaug needs at least 40°C."
      elif [ "$(kubectl get deploy -n zoo smaug -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" != "1" ]; then
        echo "The cave is warm, but Smaug hasn't restarted since. Try: kubectl rollout restart deploy/smaug -n zoo"
      else
        echo "Smaug is home. Ask the detective again, so it can see that for itself."
      fi
      exit 0
---

Welcome wanderer!

If you've landed on this tutorial, you've probably watched a demo of an AI agent fixing a Kubernetes cluster,
and you want to know what one is.

An agent is a program that sends your question to a language model (LLM), along with a list of tools the model may use.
The model doesn't have to answer straight away. It can ask the program to run a tool, read the result, ask for another one,
and answer only when it has seen enough.
[kagent](https://kagent.dev) is a CNCF project that runs agents like that on Kubernetes:
you describe an agent in YAML, and a controller turns it into a running Pod.

Is that worth it for `kubectl get pods`? No. Agents earn their keep on vague questions that take several steps to answer.
So here's one: **Smaug the dragon has gone missing from the zoo. Where is Smaug?**

By the end of this tutorial, you'll have hired a detective agent, watched it work the case one tool call at a time,
and checked that it really looks at the cluster instead of making things up.

::image-box
---
:src: __static__/detective-overview.png
:alt: 'You ask the detective "Where is Smaug?" through the kagent controller. The detective Pod asks the model what to do, and the model asks for one tool at a time: list the Pods in the zoo, read the logs of the one that is failing, read the ConfigMap the logs mention. The tool server runs each one against the cluster. Then the model writes up what happened.'
---
::

One thing up front: **the model in this tutorial is a script, not a real LLM.**
It follows four fixed rules, so it gives the same answer every time and you don't need an API key.
It still decides from what the tools return, so it only finds Smaug because the clues are really there.
At the end, I'll show you how to swap in a real model.

## Prerequisites

You'll need to know your way around `kubectl` and to have run a `helm install` before. No AI or Python knowledge needed.

The playground has a Kubernetes cluster with the zoo already open. Everything for this tutorial is in `~/detective`, which is where the IDE tab opens.

## The missing dragon

Here's the zoo:

```sh
kubectl get pods -n zoo
```

```text
NAME                      READY   STATUS    RESTARTS      AGE
mochi-6b7f7f9445-kvzjk    1/1     Running   0             39s
prickles-ddbc4956-sg9z2   1/1     Running   0             39s
rex-544dd7c76b-p7q9d      1/1     Running   0             39s
smaug-644b8bf964-shb89    0/1     Error     2 (35s ago)   39s
```

Everyone's here except Smaug, who keeps starting and leaving.
You could probably find out why in a few commands. Don't. Let's hire someone to do it.

## Installing kagent

kagent comes as two Helm charts: one with its CRDs, one with everything else.
The values file in `~/detective` turns off the example agents kagent installs by default and points kagent at our scripted model:

```yaml [~/detective/kagent-values.yaml]
{{excerpt:detective/kagent-values.yaml#from=^providers:#to=baseUrl}}
```

```sh
cd ~/detective
helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version 0.10.2 --namespace kagent --create-namespace
helm install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 0.10.2 --namespace kagent -f kagent-values.yaml
kubectl wait -n kagent --for=condition=Available deploy --all --timeout=180s
kubectl get pods -n kagent
```

```text
NAME                                 READY   STATUS    RESTARTS      AGE
kagent-controller-75744fddf5-nqbdw   1/1     Running   3 (46s ago)   61s
kagent-postgresql-f4c97f6d6-tcdf2    1/1     Running   0             61s
kagent-tools-54959b659c-4l7tq        1/1     Running   0             61s
kagent-ui-fdd4745f4-s7ggb            1/1     Running   0             61s
```

The controller restarting a few times is normal: it waits for its database. Here's who's who:

- `kagent-controller` is an operator. It watches `Agent` resources and builds what they need, and it's also the front door you'll talk to agents through.
- `kagent-tools` is a tool server with about a hundred Kubernetes tools, like `k8s_get_resources` and `k8s_get_pod_logs`.
  It speaks MCP, the Model Context Protocol, the standard way to offer tools to agents.
- `kagent-postgresql` keeps conversations. (The playground came with a StorageClass for its volume. On your own cluster, check that you have one.)
- `kagent-ui` is a chat page we won't need.

::simple-task
---
:tasks: tasks
:name: verify_kagent_running
---
#active
Waiting for the kagent controller to start...

#completed
kagent is running.
::

## The detective's brain

The model is `~/detective/model/detective-model.py`. It's short, so open it in the IDE tab.
Its four rules are what a person would do:

```python [~/detective/model/detective-model.py]
{{excerpt:detective/model/detective-model.py#from=^    if last.get\("role"\) == "user":#to=Fix that, and}}
```

It speaks the one endpoint kagent uses, `POST /v1/chat/completions`, and it prints every step to its log.
Start it:

```sh
kubectl -n kagent create configmap detective-model --from-file=model/detective-model.py
kubectl apply -f model/deploy.yaml
kubectl -n kagent rollout status deploy/detective-model
```

```text
configmap/detective-model created
deployment.apps/detective-model created
service/detective-model created
deployment "detective-model" successfully rolled out
```

## Hiring the detective

Here's the whole agent:

```yaml [~/detective/detective.yaml]
{{file:detective/detective.yaml}}
```

`systemMessage` is the job description the model gets with every question.
`modelConfig` picks the brain, and `toolNames` picks four read-only tools from kagent's tool server.

```sh
kubectl apply -f detective.yaml
kubectl get agents -n kagent
```

```text
agent.kagent.dev/detective created
NAME        TYPE          RUNTIME   READY   ACCEPTED
detective   Declarative   go        True    True
```

If you've done [How Kubernetes Operators Work](/tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c), this will look familiar.
The `Agent` is a custom resource, and the kagent controller turned it into ordinary objects:

```sh
kubectl get deploy,service,secret,serviceaccount -n kagent -l app.kubernetes.io/name=detective
```

```text
NAME                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/detective   1/1     1            1           4s

NAME                TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
service/detective   ClusterIP   10.101.158.107   <none>        8080/TCP   4s

NAME               TYPE     DATA   AGE
secret/detective   Opaque   2      4s

NAME                       AGE
serviceaccount/detective   4s
```

The Deployment runs kagent's agent runtime, the program that does the asking and the tool calling.
The Secret holds its config: where the model lives and which tools it may use.

::simple-task
---
:tasks: tasks
:name: verify_detective_hired
---
#active
Waiting for the detective Agent to be Ready...

#completed
The detective is hired.
::

## Where is Smaug?

You talk to agents through the controller, so forward its port in a **second terminal tab** and leave it running:

```sh
kubectl -n kagent port-forward svc/kagent-controller 8083:8083
```

`~/detective/radio` sends your question to an agent and prints the answer.
Under the hood, it's one `curl` using A2A, the Agent2Agent protocol: JSON over HTTP.
Back in the first tab:

```sh
./radio detective "Where is Smaug?"
```

```text
Found Smaug. Pod smaug-644b8bf964-shb89 is in Error: it keeps starting and leaving. Its last words: "Brr. The cave is 12°C (ConfigMap smaug-cave, key temperature). Dragons need at least 40°C. Smaug is leaving." The ConfigMap it reads has temperature: "12". Fix that, and Smaug should come home on the next restart.
```

Case closed, and you didn't run a single `kubectl` command for it.

::simple-task
---
:tasks: tasks
:name: verify_case_solved
---
#active
Waiting for the detective to solve the case...

#completed
The detective followed the clues and found out what happened to Smaug.
::

### Reading the detective's notebook

So how did it get there? The model printed its side of the investigation:

```sh
kubectl logs -n kagent deploy/detective-model
```

```text
detective-model listening on :8080
<- asked: messages=['system', 'user']
   rule 1: new question, list the Pods
-> reply: call k8s_get_resources {"resource_type": "pods", "namespace": "zoo"}
<- asked: messages=['system', 'user', 'assistant', 'tool']
   rule 2: smaug-644b8bf964-shb89 is in Error, read its logs
-> reply: call k8s_get_pod_logs {"pod_name": "smaug-644b8bf964-shb89", "namespace": "zoo", "tail_lines": 20}
<- asked: messages=['system', 'user', 'assistant', 'tool', 'assistant', 'tool']
   rule 3: the logs mention ConfigMap smaug-cave, look at it
-> reply: call k8s_get_resources {"resource_type": "configmap", "resource_name": "smaug-cave", "namespace": "zoo", "output": "yaml"}
<- asked: messages=['system', 'user', 'assistant', 'tool', 'assistant', 'tool', 'assistant', 'tool']
   rule 4: write it up
-> reply: Found Smaug. Pod smaug-644b8bf964-shb89 is in Error: it keeps starting and leaving. Its last words: "Brr. The cave is 12°C (ConfigMap smaug-cave, key temperature). Dragons need at least 40°C. Smaug is leaving." The ConfigMap it reads has temperature: "12". Fix that, and Smaug should come home on the next restart.
```

One question, four trips to the model. Watch the `messages` list grow:

1. The detective sent the job description (`system`) and your question (`user`). The model didn't answer. It asked for a tool: list the Pods.
2. The detective ran that tool on the tool server and went back to the model with everything so far, plus the result (`assistant`, `tool`).
   The model saw Smaug failing and asked for the next tool: Smaug's logs.
3. The logs named a ConfigMap, so the model asked to see it.
4. With all three results in hand, the model answered.

That loop is what makes something an agent. The model only ever writes text: either "run this tool" or the answer.
The detective's runtime does the running, and it keeps going until the model stops asking for tools.

Nothing is remembered between trips, either. Each time, the detective sends the whole conversation again,
which is why the list keeps getting longer.

## Bringing Smaug home

The detective only looks. Fixing things is your job. Warm the cave, and restart Smaug so it reads the new temperature:

```sh
kubectl patch configmap smaug-cave -n zoo --type=merge -p '{"data":{"temperature":"45"}}'
kubectl rollout restart deploy/smaug -n zoo
kubectl rollout status deploy/smaug -n zoo
kubectl logs -n zoo deploy/smaug
```

```text
configmap/smaug-cave patched
deployment.apps/smaug restarted
deployment "smaug" successfully rolled out
Found 2 pods, using pod/smaug-58bc58c74d-k9c84
The cave is 45°C. Smaug is asleep on the gold.
```

Now ask the same question again:

```sh
./radio detective "Where is Smaug?"
```

```text
Everyone's home. All Pods in the zoo are Running: mochi, prickles, rex, smaug.
```

Same question, different answer, because the cluster is different.
The detective knows nothing about the zoo on its own. Everything it says, it looked up just now.

::simple-task
---
:tasks: tasks
:name: verify_smaug_home
---
#active
Waiting for Smaug to come home, and for the detective to notice...

#completed
Smaug is home, and the detective saw it for itself.
::

## Bringing a real model

The scripted model only knows how to follow this one trail. A real LLM decides on its own which tools to call and when to stop.
If you have an Anthropic API key, store it in a Secret (`read -s` keeps it off your screen and out of your shell history),
then give the detective a Claude brain:

```sh
read -rs KEY && kubectl -n kagent create secret generic kagent-anthropic \
  --from-literal=ANTHROPIC_API_KEY="$KEY"; unset KEY
kubectl apply -f claude.yaml
kubectl patch agent detective -n kagent --type merge \
  -p '{"spec":{"declarative":{"modelConfig":"claude"}}}'
kubectl rollout status deploy/detective -n kagent
```

Break the cave again (set the temperature back to `12` and restart Smaug), then ask the detective anything:
"Where is Smaug?", "Which animal needs attention, and why?", or "Explain CrashLoopBackOff to a new zookeeper, using Smaug as the example".

Then try a follow-up, like "can you fix it for me?", and see what happens.
Each `./radio` call starts a brand-new conversation, and that turns out to be a whole topic of its own.

## Common points to debug

If something doesn't behave the way you expect:

- If `kubectl wait` times out while installing kagent, run it again. On a fresh cluster, pulling the images can take a minute or two.
- If `./radio` prints nothing or `curl: (7)`, the port-forward in the second tab isn't running. Start it again.
- If the Agent never gets Ready, look at `kubectl describe agent -n kagent detective` and at its Pod: `kubectl get pods -n kagent -l app.kubernetes.io/name=detective`.
- If the detective says it can't see the zoo, check that the tool names in `detective.yaml` match real ones:
  `kubectl get remotemcpserver kagent-tool-server -n kagent -o json | jq -r '.status.discoveredTools[].name'`.
- If Smaug is still missing after you warm the cave, check that you restarted it. A running Pod only reads the ConfigMap when it starts.

## Wrapping up

That's it! The zoo has a detective.

An agent in kagent is a custom resource. The controller turns it into a Deployment, a Service, a ServiceAccount and a config Secret.
Inside, it's a loop: ask the model, run the tool it asks for, ask again, answer.
Text is all the model produces. The tools do the looking, and the answer is only as good as what they return.

If you want to keep going:

- Give the detective a real model and see how differently it works the same case.
- Look at what kagent's tool server may do in your cluster: `kubectl auth can-i --list --as=system:serviceaccount:kagent:kagent-tools`. You might not like the answer.
- Connect a coding agent like Claude Code to your agents. The controller also speaks MCP, at `/mcp`.

### References

- [kagent documentation](https://kagent.dev/docs/kagent)
- [kagent on GitHub](https://github.com/kagent-dev/kagent)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [Agent2Agent (A2A) protocol](https://a2a-protocol.org)
- [How Kubernetes Operators Work: Building a Controller From Scratch](/tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c)
