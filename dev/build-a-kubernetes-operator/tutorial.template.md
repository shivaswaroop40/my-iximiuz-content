---
kind: tutorial

title: "Build a Kubernetes Operator From Scratch: A Pet That Gets Hungry"

description: |
  Design a Pet API with a CustomResourceDefinition, then bring it to life:
  first with a 15-line bash loop, then with a real Go controller built on controller-runtime.
  Your pet lives in a Pod, gets hungry as time passes, and runs away if you forget to feed it.
  Along the way you'll see the reconcile loop create, heal, report status, wake itself up, survive restarts, and clean up after itself.

categories:
- kubernetes
- programming

tagz:
- crd
- custom-resources
- operators
- controllers
- controller-runtime
- go

createdAt: 2026-09-26
updatedAt: 2026-09-26

cover: __static__/cover.png

playground:
  name: k8s-omni

tasks:
  init_go:
    init: true
    machine: dev-machine
    user: root
    run: |
      set -euo pipefail
      if ! /usr/local/go/bin/go version 2>/dev/null | grep -q 'go1\.26'; then
        case "$(uname -m)" in
          x86_64) arch=amd64 ;;
          aarch64|arm64) arch=arm64 ;;
          *) echo "unsupported arch $(uname -m)"; exit 1 ;;
        esac
        rm -rf /usr/local/go
        curl -fsSL "https://go.dev/dl/go1.26.8.linux-${arch}.tar.gz" | tar -C /usr/local -xz
      fi
      echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' > /etc/profile.d/go.sh
      grep -q '/usr/local/go/bin' /home/laborant/.bashrc \
        || echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> /home/laborant/.bashrc

  init_cluster:
    init: true
    machine: dev-machine
    user: laborant
    run: |
      set -euo pipefail
      until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
      kubectl get namespace zoo >/dev/null 2>&1 || kubectl create namespace zoo
      mkdir -p "$HOME/pet-operator/config"

  verify_crd_minimal:
    machine: dev-machine
    user: laborant
    run: |
      [ "$(kubectl get crd pets.zoo.example.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" = "True" ] || exit 1
      kubectl get pets -n zoo mochi >/dev/null 2>&1

  verify_crd_full:
    machine: dev-machine
    user: laborant
    needs:
    - verify_crd_minimal
    run: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -f - -o "${2:-name}" 2>/dev/null
      }
      [ "$(try '{"species":"cat"}' 'jsonpath={.spec.diet.food}/{.spec.diet.feedEvery}')" = "snacks/10m" ] || exit 1
      try '{"species":"unicorn"}' >/dev/null && exit 1
      try '{"species":"cactus","toy":"ball"}' >/dev/null && exit 1
      try '{"species":"dragon","diet":{"feedEvery":"15m"}}' >/dev/null && exit 1
      try '{"species":"cat","diet":{"feedEvery":"whenever"}}' >/dev/null && exit 1
      [ -n "$(kubectl get crd pets.zoo.example.com -o jsonpath='{.spec.versions[0].subresources.status}')" ]

  verify_naive_controller:
    machine: dev-machine
    user: laborant
    needs:
    - verify_crd_full
    run: |
      kubectl get pod -n zoo mochi >/dev/null 2>&1

  verify_operator_adopted:
    machine: dev-machine
    user: laborant
    needs:
    - verify_naive_controller
    run: |
      [ "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}' 2>/dev/null)" = "Pet" ] || exit 1
      [ "$(kubectl get configmap -n zoo mochi-card -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}' 2>/dev/null)" = "Pet" ] || exit 1
      [ -n "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)" ] || exit 1
      gen=$(kubectl get pet -n zoo mochi -o jsonpath='{.metadata.generation}')
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.observedGeneration}')" = "$gen" ]

  verify_ran_away:
    machine: dev-machine
    user: laborant
    needs:
    - verify_operator_adopted
    run: |
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)" = "RanAway" ] || exit 1
      # The Pod is gone, or on its way out.
      [ -z "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.name}' 2>/dev/null)" ] \
        || [ -n "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]

  verify_came_home:
    machine: dev-machine
    user: laborant
    needs:
    - verify_ran_away
    run: |
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)" = "Happy" ] || exit 1
      [ "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}' 2>/dev/null)" = "Pet" ] || exit 1
      [ -z "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]

  verify_second_pet:
    machine: dev-machine
    user: laborant
    needs:
    - verify_operator_adopted
    run: |
      [ "$(kubectl get pod -n zoo smaug -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}' 2>/dev/null)" = "smaug" ] || exit 1
      [ "$(kubectl get configmap -n zoo smaug-card -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}' 2>/dev/null)" = "smaug" ]

  verify_garbage_collected:
    machine: dev-machine
    user: laborant
    needs:
    - verify_second_pet
    run: |
      kubectl get pet -n zoo mochi >/dev/null 2>&1 || exit 1
      ! kubectl get pet -n zoo smaug >/dev/null 2>&1 || exit 1
      ! kubectl get configmap -n zoo smaug-card >/dev/null 2>&1 || exit 1
      [ -z "$(kubectl get pod -n zoo smaug -o jsonpath='{.metadata.name}' 2>/dev/null)" ] \
        || [ -n "$(kubectl get pod -n zoo smaug -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]
---

Most interesting things in Kubernetes today aren't built into Kubernetes.
Certificates (cert-manager), GitOps (Argo CD), databases (CloudNativePG), whole clusters (Cluster API):
they all follow the same recipe. **A CustomResourceDefinition** teaches the API server a new noun,
and **a controller** keeps turning that noun into reality.
Together they're called an *operator*.

In this tutorial you'll build one from scratch, and it'll take care of a pet.
You describe a `Pet` in YAML. The operator gives it a Pod to live in and keeps track of how hungry it is.
Forget to feed it, and it runs away.

You'll build it one layer at a time, and see every layer work before adding the next:

1. **The API.** A `Pet` CRD with validation, house rules, defaults, and a status. No code yet.
2. **The loop, by hand.** A 15-line bash script that already acts like a controller, and shows you why it isn't enough.
3. **The real controller.** Go and [controller-runtime](https://github.com/kubernetes-sigs/controller-runtime), the library under Kubebuilder and Operator SDK.
4. **The loop at work.** Let time pass, break things on purpose, and watch the controller cope.

![The operator at a glance: you write a Pet's spec, the controller watches it, creates the Pet's ConfigMap and Pod, and writes status back.](__static__/operator-overview.png)

::remark-box
---
kind: info
---
You don't need to know Go to follow along. All the code is given to you, and every part is explained.
Basic `kubectl` is enough.
::

The playground has a multi-node Kubernetes cluster, and `kubectl` is ready to go on the `dev-machine`.
There's an empty `zoo` namespace waiting for its first resident.

## Part 1: The API

### A CRD is a new table in the API server

Start with the smallest CRD that works:

```sh
cat > ~/pet-operator/config/crd-minimal.yaml <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: pets.zoo.example.com   # must be <plural>.<group>
spec:
  group: zoo.example.com
  scope: Namespaced
  names:
    kind: Pet
    plural: pets
    singular: pet
  versions:
  - name: v1alpha1
    served: true      # the API server answers requests for this version
    storage: true     # objects are stored in etcd in this version
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true   # "anything goes", for now
EOF

kubectl apply -f ~/pet-operator/config/crd-minimal.yaml
```

That's it. The API server now serves a new REST endpoint, with no restart and no compiled code:

```sh
kubectl api-resources --api-group=zoo.example.com
kubectl get --raw /apis/zoo.example.com/v1alpha1 | python3 -m json.tool
```

Adopt your first pet:

```sh
kubectl apply -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata:
  name: mochi
  namespace: zoo
spec:
  species: cat
  toy: yarn
EOF

kubectl get pets -n zoo
```

::simple-task
---
:tasks: tasks
:name: verify_crd_minimal
---
#active
Waiting for the CRD and your first Pet...

#completed
Welcome home, mochi. The API server stores Pets now, just like Pods or ConfigMaps.
::

Now try something silly:

```sh
kubectl apply -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata:
  name: sparkles
  namespace: zoo
spec:
  species: unicorn
  toy: 42
  favoriteColor: rainbow
EOF
```

It's accepted. Right now the API server is a very polite database: it stores whatever you give it.
Nothing happens either: no Pod, no pet, nothing. **A CRD alone never *does* anything.**
Keep that in mind for Part 2. First, let's make the API strict.

```sh
kubectl delete pet -n zoo sparkles
```

### Validation, house rules, defaults, and status

Here's the real CRD. Read through it first. The table below explains each piece.

```sh
cat > ~/pet-operator/config/crd-by-hand.yaml <<'EOF'
{{file:../adopt-a-pet-crd/reference-crd.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-operator/config/crd-by-hand.yaml
```

| Piece | What the API server does with it |
|---|---|
| `shortNames`, `categories` | `kubectl get pt` and `kubectl get zoo` work. Pure convenience, but it's what people actually type. |
| `openAPIV3Schema` with `type`, `required`, `enum`, `maxLength`, `pattern`, `format` | Rejects bad objects **before** they reach etcd. Unknown fields are pruned. |
| `x-kubernetes-validations` | [CEL](https://kubernetes.io/docs/reference/using-api/cel/) rules for what OpenAPI can't express, like "a cactus can't have a toy". The rules sit on `spec` because each one needs to see two fields. |
| `duration(...)` | CEL can parse durations. Compared as strings, `'59m' >= '1h'` would be true! |
| `default` | Fills in missing fields, so every client (and your controller!) sees the same complete object. |
| `diet: default: {}` | The subtle one. Defaults apply only where the parent object exists. Without this, a Pet with no `diet` block never gets `food: snacks` or `feedEvery: 10m`. |
| `subresources: status: {}` | `.status` gets its own endpoint. Users write `spec`, the controller writes `status`, and neither can overwrite the other. |
| `additionalPrinterColumns` | Better `kubectl get` output. Once you define columns, `AGE` is no longer added automatically, so it's listed explicitly. |

Now try to get past the zookeeper. Every one of these should bounce:

```sh
for spec in \
  '{"species":"unicorn"}' \
  '{"species":"cactus","toy":"tennis ball"}' \
  '{"species":"dragon","diet":{"feedEvery":"15m"}}' \
  '{"species":"dragon"}' \
  '{"species":"dog","diet":{"feedEvery":"whenever"}}'
do
  echo "{\"apiVersion\":\"zoo.example.com/v1alpha1\",\"kind\":\"Pet\",\"metadata\":{\"name\":\"nope\",\"namespace\":\"zoo\"},\"spec\":$spec}" \
    | kubectl apply --dry-run=server -f - 2>&1 | head -2
  echo
done
```

Look at the fourth one: a dragon with no `diet` at all. It gets the default `feedEvery: 10m`, and *then* fails the dragon rule.
Defaulting always runs before validation.

![What happens to a Pet on its way to etcd: decoding and pruning, defaulting, mutating webhooks, schema and CEL validation, validating webhooks, and only then storage.](__static__/request-pipeline.png)

Now look at what the API server filled in for mochi. You never gave it a diet:

```sh
kubectl get pet -n zoo mochi -o yaml | grep -A8 '^spec:'
kubectl get pets -n zoo
```

::simple-task
---
:tasks: tasks
:name: verify_crd_full
---
#active
Waiting for the CRD to validate and default Pets...

#completed
Your API now has a contract: bad input is turned away at the gate, and good input comes back complete.
::

::details-box
---
:summary: Why is "status" a separate subresource?
---
Without it, `kubectl apply` from a user and a status update from the controller write the same object,
so one can silently overwrite the other. With it:

- writes to the main resource ignore `.status`,
- writes to `/status` ignore everything but `.status`,
- and `metadata.generation` only increases when **spec** changes.

That last point matters: a controller can record `status.observedGeneration = metadata.generation`
to say "I've acted on this version of the spec". You'll see it in Part 3.
::

## Part 2: The loop, by hand

A controller is just a loop: **observe** the desired state, **compare** it with the actual state, **act** to close the gap, and repeat.
That fits in a few lines of bash. This one gives every Pet a Pod to live in:

```sh
cat > ~/naive-controller.sh <<'EOF'
{{file:bash/naive-controller.sh}}
EOF
chmod +x ~/naive-controller.sh
```

Open a second terminal tab and run it:

```sh
~/naive-controller.sh
```

Back in the first tab:

```sh
kubectl get pods -n zoo
kubectl logs -n zoo mochi
```

::simple-task
---
:tasks: tasks
:name: verify_naive_controller
---
#active
Waiting for the bash controller to give mochi a Pod...

#completed
Your Pet just caused something to happen in the cluster.
::

Now delete the Pod and watch it come back within a few seconds:

```sh
kubectl delete pod -n zoo mochi
kubectl get pods -n zoo -w
```

This is the most important idea in Kubernetes. The script never asked *what happened?* It only asked *what should exist?*
That's called **level-triggered** reconciliation, and it's why controllers are so robust: a missed event doesn't matter, because the next pass fixes everything anyway.

Now for its flaws. First, change mochi's species:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"species":"dog"}}'
sleep 10
kubectl logs -n zoo mochi --tail=1
```

Mochi still thinks it's a cat. The script only checks whether *a* Pod exists, not whether it's the *right* one.
It couldn't easily fix that anyway: most of a Pod's spec can't be changed after it's created.
Put things back:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"species":"cat"}}'
```

Next, adopt a throwaway pet, wait for its Pod, then give it away:

```sh
kubectl apply -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata:
  name: goldie
  namespace: zoo
spec:
  species: dog
EOF
sleep 8
kubectl delete pet -n zoo goldie
sleep 8
kubectl get pods -n zoo
```

The `goldie` Pod is still there, an orphan. The script only knows how to add things. Its other problems:

- **Polling.** It lists every Pet every 5 seconds, even when nothing changed. Imagine 5,000 of them.
- **No status.** Nobody can tell from the Pet whether it's alive, happy or hungry.
- **No ownership.** Nothing links a Pod to the Pet it came from.
- **No sense of time.** Pets should get hungry. Funnily enough, polling would make that easy: the script wakes up every 5 seconds anyway.
  An efficient, event-driven controller only wakes up when something changes, and the passing of time is not a change in the cluster.
  You'll see how a real controller solves that.

Stop the script with `Ctrl+C` in the second tab, and clean up after it:

```sh
kubectl delete pods -n zoo --all
```

## Part 3: A real controller in Go

### Set up the project

[controller-runtime](https://github.com/kubernetes-sigs/controller-runtime) is the library behind Kubebuilder and Operator SDK.
We'll use it directly, without any scaffolding, so every file is one you wrote and understand.

```sh
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
go version

cd ~/pet-operator
go mod init example.com/pet-operator
go get sigs.k8s.io/controller-runtime@v0.25.1
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.22.0
```

The downloads take a minute. Meanwhile, here's the plan:

```text
pet-operator/
├── api/v1alpha1/              the Pet type, in Go
├── internal/controller/       the reconcile loop
├── config/                    CRDs (the one you wrote, and one we'll generate)
└── main.go                    wires everything together and starts it
```

### The API, in Go

The controller needs Go structs that mirror the CRD's schema. First, the file that tells the Go client which API group these types belong to:

```sh
mkdir -p api/v1alpha1 internal/controller
cat > api/v1alpha1/groupversion_info.go <<'EOF'
{{file:pet-operator/api/v1alpha1/groupversion_info.go}}
EOF
```

Then the types themselves. Look at the `+kubebuilder:` comments. They're called **markers**, and they should look familiar:

```sh
cat > api/v1alpha1/pet_types.go <<'EOF'
{{file:pet-operator/api/v1alpha1/pet_types.go}}
EOF
```

Each marker is one line of the CRD you wrote by hand: `Enum`, `MaxLength`, `Pattern`, `default`, `XValidation`, `printcolumn`, `subresource:status`.
The status gained a few fields a controller conventionally reports: the Pod the pet lives in, `observedGeneration`, and `conditions`.

Kubernetes objects must be deep-copyable. That's boilerplate, so let `controller-gen` write it.
Then use the same tool to **generate the CRD from the markers**:

```sh
controller-gen object paths=./api/...
controller-gen crd paths=./api/... output:crd:dir=config

ls api/v1alpha1 config
```

Compare the generated CRD with the one you wrote by hand:

```sh
diff <(kubectl create --dry-run=client -o yaml -f config/crd-by-hand.yaml) \
     <(kubectl create --dry-run=client -o yaml -f config/zoo.example.com_pets.yaml) | less
```

The whole `spec` schema (validation rules, defaults, the CEL rules) and the names are identical.
The differences are descriptions (taken from the Go comments), the new status fields,
and small details controller-gen always adds, like `listKind`.

::remark-box
---
kind: info
---
This is exactly what `kubebuilder` and `make manifests` do. From now on the Go types are the source of truth and the CRD is generated from them.
::

Replace the hand-written CRD with the generated one:

```sh
kubectl apply -f config/zoo.example.com_pets.yaml
```

### The reconciler

This is the heart of the operator. Read the comments: the whole design is in them.

```sh
cat > internal/controller/pet_controller.go <<'EOF'
{{file:pet-operator/internal/controller/pet_controller.go}}
EOF
```

![What wakes the controller up: Pet events, events on owned objects, RequeueAfter timers and startup all put a name in the work queue, and Reconcile observes, computes, acts and reports.](__static__/reconcile-loop.png)

Some things worth noticing:

- **`Reconcile` receives only a name.** Not the event, not the diff, not the old object. Just like the bash loop, it looks at the current state and makes it right.
- **Hunger is computed, not stored.** Nothing in the cluster changes when time passes, so every run works out the mood from `lastFedAt` and the clock.
- **`RequeueAfter`** is how the controller deals with time: "call me again when this pet's mood is due to change". There's no polling, and no timer per pet in your code. The controller's work queue takes care of it.
- **The ConfigMap is updated, the Pod never is.** Anything that changes (the card) lives in the ConfigMap, and the Pod just mounts it. That's the fix for the bash script's "mochi still thinks it's a cat" problem. `CreateOrUpdate` reads the ConfigMap (or starts from an empty one), runs your function, and writes only if something actually changed.
- **`SetControllerReference`** stamps the Pod and the ConfigMap with an owner reference pointing at the Pet. That fixes the orphan problem, as you'll see.
- **`Owns(&corev1.Pod{})`**: when a Pod or ConfigMap that belongs to a Pet changes or disappears, the *owner* Pet gets reconciled.
- **Events** (`Recorder.Eventf`) leave a human-readable trail in `kubectl describe pet`.

### main.go

```sh
cat > main.go <<'EOF'
{{file:pet-operator/main.go}}
EOF
```

The **manager** runs a shared cache of the watched objects. It's backed by informers: one LIST at startup, then a long-lived WATCH.
The controller's `r.Get` calls read from that local cache, not from the API server. That's how controllers stay cheap even with thousands of objects, and it fixes the bash loop's polling problem.

### Run it

Operators normally run inside the cluster. During development it's much faster to run them locally against your kubeconfig, which is what `make run` does in Kubebuilder projects:

```sh
go mod tidy
go run .
```

Leave it running. From now on, use the other terminal tab.

Mochi has been waiting since Part 1, and nobody has fed it. It gets hungry 10 minutes after being fed (or, if it never was, after being adopted),
and it runs away after 30. Depending on how long you took to get here, it might be happy, hungry, or already gone:

```sh
kubectl get pets,pods -n zoo
```

Whatever happened, feeding fixes it. Add a little helper to your shell. It sets `lastFedAt` to the current time:

```sh
cat >> ~/.bashrc <<'EOF'
feed() {
  kubectl patch pet "$1" -n zoo --type=merge \
    -p "{\"spec\":{\"lastFedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
}
EOF
source ~/.bashrc

feed mochi
kubectl get pets,pods -n zoo
```

Look at what the operator created, who owns it, and what it reported:

```sh
kubectl get pod,configmap -n zoo -o custom-columns=KIND:.kind,NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind
kubectl get pet -n zoo mochi -o jsonpath='{.status}' | python3 -m json.tool
```

Once the Pod is running, say hi:

```sh
kubectl logs -n zoo mochi
```

::simple-task
---
:tasks: tasks
:name: verify_operator_adopted
---
#active
Waiting for the operator to move mochi into its Pod and report its mood...

#completed
Mochi's Pod and card are owned by the Pet, and the Pet reports a mood with an up-to-date observedGeneration.
::

## Part 4: The loop at work

Keep the operator's logs in view in one tab and run these experiments in the other.

### Time passes

Ten minutes is a long time to wait. Put mochi on a faster metabolism, and feed it right away:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"diet":{"feedEvery":"1m"}}}'
feed mochi
kubectl get pets -n zoo -w
```

Then do nothing. Nobody touches the Pet, but after a minute its mood changes to `Hungry`,
and after three minutes mochi runs away and its Pod is deleted.
That's `RequeueAfter` at work: each reconcile asked to be called again exactly when the mood was due to change.

![Mochi's hunger over time: Happy until feedEvery, Hungry until three times feedEvery, then it runs away and its Pod is deleted, until it's fed again. Reconcile runs on each feeding and on each RequeueAfter.](__static__/hunger-timeline.png)

While you wait, watch the pet itself in another tab. The card updates within a minute or so of a mood change,
because the kubelet refreshes mounted ConfigMaps periodically:

```sh
kubectl logs -n zoo mochi -f
```

::simple-task
---
:tasks: tasks
:name: verify_ran_away
---
#active
Waiting for mochi to get hungry... and then some. (About 3 minutes.)

#completed
Mochi ran away. Nothing changed in the cluster: the controller woke itself up to notice.
::

Poor thing. Look at what the operator recorded, then bring mochi home:

```sh
kubectl describe pet -n zoo mochi | tail -n 8
feed mochi
kubectl get pets,pods -n zoo
```

::simple-task
---
:tasks: tasks
:name: verify_came_home
---
#active
Waiting for mochi to come home...

#completed
Welcome back. Feeding changed the spec, the controller reconciled, and a new Pod was created.
::

Put mochi back on a relaxed diet so it doesn't run away during the next experiments:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"diet":{"feedEvery":"10m"}}}'
feed mochi
```

### Deleted children come back

```sh
kubectl delete pod -n zoo mochi
kubectl get pods -n zoo -w
```

### Drift is reverted

Scribble on mochi's card behind the operator's back:

```sh
kubectl patch configmap -n zoo mochi-card --type=merge -p '{"data":{"card":"mochi is a dog now"}}'
kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'
```

It's back before you can blink. The edit fired a watch event on an *owned* ConfigMap, which triggered a reconcile of its owner.

### Spec changes are picked up, and acknowledged

This time, unlike in Part 2, changing the spec actually changes the pet:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"toy":"laser pointer"}}'

kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'
kubectl get pet -n zoo mochi \
  -o jsonpath='generation={.metadata.generation} observedGeneration={.status.observedGeneration}{"\n"}'
```

`observedGeneration` catches up with `generation`: that's the controller telling you it has seen this version of your spec.

### A crashed controller catches up

Stop the operator with `Ctrl+C`. While it's down, change the spec:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"toy":"cardboard box"}}'
kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'   # still the laser pointer
```

Start it again with `go run .` and check once more. On startup the cache LISTs everything, and every object gets reconciled.
No event was "missed", because the controller never depended on events in the first place.

::details-box
---
:summary: What's "the object has been modified; please apply your changes to the latest version"?
---
Sooner or later you'll see this `Reconciler error` in the logs. It's **optimistic concurrency**: the controller tried to write the status of an object that changed after it was read.
The API server refuses the stale write, controller-runtime puts the request back in the queue, and the next reconcile works on fresh data.
It's harmless and expected. Just never "fix" it by retrying the same stale write in a loop.
::

### Deletion cleans up after itself

Remember the orphaned Pod from the bash controller? Adopt a second pet:

```sh
kubectl apply -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata:
  name: smaug
  namespace: zoo
spec:
  species: dragon
  diet:
    food: sheep
    feedEvery: 6h
EOF

kubectl get pets,pods,configmaps -n zoo
```

::simple-task
---
:tasks: tasks
:name: verify_second_pet
---
#active
Waiting for the operator to move smaug in...

#completed
One Pet, one Pod, one card, all owned by the Pet.
::

Now, sadly, smaug has to go to a bigger zoo:

```sh
kubectl delete pet -n zoo smaug
kubectl get pods,configmaps -n zoo
```

Its Pod and card are gone too, and the operator did nothing: its `Reconcile` just got a "not found" and returned.
The cleanup was done by Kubernetes' **garbage collector**, which deletes objects whose owner no longer exists.
That's what the owner references were for.

![Without owner references, the bash controller's Pod outlives its Pet forever. With them, deleting a Pet lets the garbage collector delete its Pod and ConfigMap.](__static__/ownership-gc.png)

::simple-task
---
:tasks: tasks
:name: verify_garbage_collected
---
#active
Waiting for smaug, its Pod and its card to be gone...

#completed
No orphans this time.
::

## What you built, and what real operators add

You now have every essential piece of an operator:

| Piece | Where |
|---|---|
| An API with a contract: validation, CEL house rules, defaults | CRD (Part 1), generated from Go markers (Part 3) |
| Spec/status separation and `observedGeneration` | status subresource + `r.Status().Update` |
| Level-triggered reconciliation | `Reconcile(ctx, req)` gets a name, not an event |
| Time-based behaviour without polling | `ctrl.Result{RequeueAfter: ...}` |
| Cheap watching | the manager's informer cache |
| Self-healing and drift correction | `Owns(&corev1.Pod{})`, `Owns(&corev1.ConfigMap{})` |
| Handling immutable children | update the ConfigMap, only create (or delete) the Pod |
| Cleanup | owner references + the garbage collector |
| Human-readable feedback | conditions, printer columns, events |

Production operators typically add:

- **Finalizers**, for cleanup the garbage collector can't do: things outside the cluster.
  If each pet had an account in some external "pet registry", a finalizer would make sure it's deregistered before the Pet disappears.
- **RBAC and in-cluster deployment.** A ServiceAccount, a ClusterRole generated from `+kubebuilder:rbac` markers, and a Deployment running the image.
- **Predicates**, such as `GenerationChangedPredicate`, to skip reconciles that can't change anything, like the one triggered by our own status update.
- **Tests** with `envtest`, which runs a real kube-apiserver and etcd, just like the one this tutorial's checks were developed against.
- **Admission webhooks** for validation or defaulting that CEL can't express.
- **Scaffolding.** [Kubebuilder](https://book.kubebuilder.io/) generates this whole layout (plus Makefiles, Dockerfiles and kustomize) with `kubebuilder init` and `kubebuilder create api`. Now you know what every generated file is for.

::remark-box
---
kind: success
---
Want to practice the API design part without the guide? Try the challenge
[Open a Kubernetes Zoo: Design a Validated Pet CustomResourceDefinition](/challenges/adopt-a-pet-crd):
same `Pet`, no hints until you ask, and a hidden test suite.
::
