---
kind: tutorial

title: "How Kubernetes Operators Work: Building a Controller From Scratch"

description: |
  Build a Kubernetes operator for a small Pet API, first as a 15-line bash loop and then as a Go controller with controller-runtime.
  Every Pet gets a Pod to live in, gets hungry as time passes, and runs away if nobody feeds it. Along the way, you'll see how the reconcile loop works.

categories:
- kubernetes
- programming

tagz:
- crd
- custom-resources
- operator
- controller-runtime
- go

createdAt: 2026-09-26
updatedAt: 2026-09-28

cover: __static__/cover.png

playground:
  name: k8s-omni
  startupFiles:
  - path: /home/laborant/pet-operator
    source: __static__/pet-operator.tar.gz
    extract: true
    owner: laborant
    machines: [dev-machine]

tasks:
  init_go:
    init: true
    machine: dev-machine
    user: root
    timeout_seconds: 900
    run: |
      set -euo pipefail
      if ! /usr/local/go/bin/go version 2>/dev/null | grep -qw 'go1\.26\.8'; then
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
    timeout_seconds: 900
    run: |
      set -euo pipefail
      for i in $(seq 1 400); do
        kubectl get --raw /readyz >/dev/null 2>&1 && break
        sleep 2
      done
      kubectl get --raw /readyz >/dev/null
      kubectl get namespace zoo >/dev/null 2>&1 || kubectl create namespace zoo

  verify_crd_minimal:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    run: |
      [ "$(kubectl get crd pets.zoo.example.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" = "True" ] || exit 1
      kubectl get pets -n zoo mochi >/dev/null 2>&1
    hintcheck: |
      if ! kubectl get crd pets.zoo.example.com >/dev/null 2>&1; then
        echo "The pets.zoo.example.com CRD doesn't exist yet. Apply ~/pet-operator/config/crd-minimal.yaml."
      elif ! kubectl get pet -n zoo mochi >/dev/null 2>&1; then
        echo "The CRD is there, but the mochi Pet isn't. Create it in the zoo namespace."
      fi
      exit 0
  verify_crd_full:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
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
    hintcheck: |
      if [ -z "$(kubectl get crd pets.zoo.example.com -o jsonpath='{.spec.versions[0].subresources.status}' 2>/dev/null)" ]; then
        echo "The API server still uses the minimal CRD. Apply ~/pet-operator/config/crd-by-hand.yaml."
      fi
      exit 0
  verify_naive_controller:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_crd_full
    run: |
      kubectl get pod -n zoo mochi >/dev/null 2>&1
    hintcheck: |
      echo "There's no mochi Pod yet. Is ~/pet-operator/bash/naive-controller.sh running in the second terminal tab?"
      exit 0
  verify_operator_adopted:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_naive_controller
    run: |
      [ "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}' 2>/dev/null)" = "Pet" ] || exit 1
      [ "$(kubectl get configmap -n zoo mochi-card -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}' 2>/dev/null)" = "Pet" ] || exit 1
      [ -n "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)" ] || exit 1
      gen=$(kubectl get pet -n zoo mochi -o jsonpath='{.metadata.generation}')
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.observedGeneration}')" = "$gen" ]
    hintcheck: |
      reason=$(kubectl get pet -n zoo mochi -o jsonpath='{.status.conditions[?(@.type=="AtHome")].reason}' 2>/dev/null)
      if [ "$reason" = "PodNameTaken" ]; then
        echo "A mochi Pod that the Pet doesn't own is in the way, probably left over from the bash controller."
        echo "Delete it with 'kubectl delete pod -n zoo mochi', and the operator moves mochi in within 10 seconds."
        echo "(If you just deleted and re-created mochi, wait 10 seconds: the old Pet's Pod is still being cleaned up.)"
      elif [ "$reason" = "ConfigMapNameTaken" ]; then
        echo "A mochi-card ConfigMap that the Pet doesn't own is in the way."
        echo "Delete it with 'kubectl delete configmap -n zoo mochi-card', and the operator creates its own within 10 seconds."
        echo "(If you just deleted and re-created mochi, wait 10 seconds: the old Pet's card is still being cleaned up.)"
      elif [ -z "$(kubectl get crd pets.zoo.example.com -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.status.properties.observedGeneration}' 2>/dev/null)" ]; then
        echo "The API server still uses the hand-written CRD, so it drops status.observedGeneration."
        echo "Apply the generated one: kubectl apply -f ~/pet-operator/config/zoo.example.com_pets.yaml"
      elif [ -z "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)" ]; then
        echo "mochi has no status yet. Is the operator running? Start it with ./pet-operator in ~/pet-operator."
      elif [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}')" = "RanAway" ]; then
        echo "mochi ran away before the operator could move it in. Feed it: feed mochi"
      fi
      exit 0
  verify_ran_away:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_operator_adopted
    run: |
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)" = "RanAway" ] || exit 1
      # The Pod is gone, or on its way out.
      [ -z "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.name}' 2>/dev/null)" ] \
        || [ -n "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]
    hintcheck: |
      every=$(kubectl get pet -n zoo mochi -o jsonpath='{.spec.diet.feedEvery}' 2>/dev/null)
      mood=$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)
      if [ "$every" != "1m" ]; then
        echo "mochi's feedEvery is '$every'. Set it to 1m, feed mochi, and wait about 3 minutes."
      else
        echo "mochi is $mood. Keep waiting: it runs away 3 minutes after its last feeding. Is the operator still running?"
      fi
      exit 0
  verify_came_home:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_ran_away
    run: |
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null)" = "Happy" ] || exit 1
      [ "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}' 2>/dev/null)" = "Pet" ] || exit 1
      [ -z "$(kubectl get pod -n zoo mochi -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]
    hintcheck: |
      echo "mochi is $(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}' 2>/dev/null). Feed it to bring it home: feed mochi"
      exit 0
  verify_second_pet:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_operator_adopted
    run: |
      [ "$(kubectl get pod -n zoo smaug -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}' 2>/dev/null)" = "smaug" ] || exit 1
      [ "$(kubectl get configmap -n zoo smaug-card -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}' 2>/dev/null)" = "smaug" ]
    hintcheck: |
      if ! kubectl get pet -n zoo smaug >/dev/null 2>&1; then
        echo "There's no smaug Pet. Create it (again) and wait for this checkpoint before you delete it."
      else
        echo "smaug exists, but its Pod or card isn't there yet. Is the operator running?"
      fi
      exit 0
  verify_garbage_collected:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_second_pet
    run: |
      kubectl get pet -n zoo mochi >/dev/null 2>&1 || exit 1
      ! kubectl get pet -n zoo smaug >/dev/null 2>&1 || exit 1
      ! kubectl get configmap -n zoo smaug-card >/dev/null 2>&1 || exit 1
      [ -z "$(kubectl get pod -n zoo smaug -o jsonpath='{.metadata.name}' 2>/dev/null)" ] \
        || [ -n "$(kubectl get pod -n zoo smaug -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]
    hintcheck: |
      if kubectl get pet -n zoo smaug >/dev/null 2>&1; then
        echo "smaug is still here. Delete it: kubectl delete pet -n zoo smaug"
      fi
      exit 0
---

Welcome wanderer!

If you've landed on this tutorial, you've probably installed an operator or two, like cert-manager or Argo CD,
or you're about to write your own and want to know how they work.

An operator has two parts.
A CustomResourceDefinition (CRD) adds a new resource type to the Kubernetes API,
and a controller watches the resources of that type and changes the cluster to match them.

By the end of this tutorial, you will have an operator running against your cluster that looks after pets.
Every Pet gets a Pod to live in and gets hungry as time passes.
If nobody feeds it for too long, the pet runs away, and the operator deletes its Pod.

Here's the whole picture of what you'll end up with:

::image-box
---
:src: __static__/operator-overview.png
:alt: 'The Pet operator: a user writes the Pet spec, the controller watches Pets, creates a ConfigMap and a Pod for each of them, and writes the status back.'
---
::

I picked pets for this one because hunger depends on time,
and reacting to time passing is one of the less obvious things a controller has to handle.

We'll get there in steps: first the CRD, then a controller in 15 lines of bash,
and once we've seen where that falls short, a real controller in Go.

You won't have to type out any long files.
The whole project is already waiting in `~/pet-operator` on the playground.
In the tutorial, I'll show the parts that matter and explain them, and you can open the full files in the IDE tab whenever you want the bigger picture.

## Prerequisites

You need basic `kubectl` knowledge.
Knowing Go helps, but don't worry if you don't: all the code is given to you, and I'll explain the parts that matter.

The playground already has a multi-node Kubernetes cluster, and `kubectl` on the `dev-machine` is set up to talk to it.
Go is installed too, and the `zoo` namespace is waiting for its first resident.
If the playground asks you to choose a networking plugin, keep the default one (flannel), because the pets need running Pods.

## Setting up the Pet API

::remark-box
---
kind: info
---
This section goes through CRD design quickly.
If schemas, CEL rules, and defaults are new to you,
[How Kubernetes CRDs Work: Designing a Validated API From Scratch](/tutorials/open-a-kubernetes-zoo-9ad54ae8)
builds the same CRD step by step.
::

### Creating the smallest CRD

Let's start small.
A CRD needs a group, a kind with its plural and singular names, and at least one version with a schema.
The smallest one is already in `~/pet-operator/config/crd-minimal.yaml`, and it has two parts.

The first part names the new resource:

```yaml [~/pet-operator/config/crd-minimal.yaml]
metadata:
  name: pets.zoo.example.com
spec:
  group: zoo.example.com
  scope: Namespaced
  names:
    kind: Pet
    plural: pets
    singular: pet
    shortNames: [pt]
    categories: [zoo]
```

- `group` becomes the first half of every Pet's `apiVersion`, so it's `zoo.example.com/v1alpha1`.
- `metadata.name` must be `<plural>.<group>`. The API server rejects the CRD if it isn't.
- `scope: Namespaced` makes Pets live in a namespace, like Pods. The alternative is `Cluster`, like Nodes.
- `plural` goes in the URL (`/apis/zoo.example.com/v1alpha1/namespaces/zoo/pets`), and `kind` goes in the manifests.
- `shortNames` and `categories` are aliases for `kubectl`, so `kubectl get pt` and `kubectl get zoo` work too.

The second part lists the versions:

```yaml [~/pet-operator/config/crd-minimal.yaml]
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
```

- `served: true` means the API server answers requests for `v1alpha1`.
- `storage: true` means objects are stored in etcd in this version. When there are several versions, exactly one of them has it.
- The schema is required, but this one accepts anything: `x-kubernetes-preserve-unknown-fields` tells the API server to keep every field it doesn't know. We'll make it strict in the next section.

Apply it:

```sh
kubectl apply -f ~/pet-operator/config/crd-minimal.yaml
```

If everything goes well, you should see a new REST endpoint right away:

```sh
kubectl api-resources --api-group=zoo.example.com
kubectl get --raw /apis/zoo.example.com/v1alpha1 | jq
```

```text
NAME   SHORTNAMES   APIVERSION                 NAMESPACED   KIND
pets   pt           zoo.example.com/v1alpha1   true         Pet
{
  "kind": "APIResourceList",
  "apiVersion": "v1",
  "groupVersion": "zoo.example.com/v1alpha1",
  "resources": [
    {
      "name": "pets",
      "singularName": "pet",
      "namespaced": true,
      "kind": "Pet",
      "verbs": [
        "delete",
        "deletecollection",
        "get",
        "list",
        "patch",
        "create",
        "update",
        "watch"
      ],
      "shortNames": [
        "pt"
      ],
      "categories": [
        "zoo"
      ],
      "storageVersionHash": "rsi7zQxickQ="
    }
  ]
}
```

Now, let's adopt the first Pet:

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

```text
pet.zoo.example.com/mochi created
NAME    AGE
mochi   0s
```

::simple-task
---
:tasks: tasks
:name: verify_crd_minimal
---
#active
Waiting for the CRD and the first Pet...

#completed
The API server stores the `mochi` Pet, just like it stores Pods or ConfigMaps.
::

Next, try a Pet that makes no sense.
We'll use a server-side dry run, so the API server checks the Pet but doesn't store it:

```sh
kubectl apply --dry-run=server -f - <<'EOF'
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

```text
pet.zoo.example.com/sparkles created (server dry run)
```

The API server accepts it, because the schema allows any `spec`.
And nothing else happens.
Every pet is supposed to live in its own Pod, which keeps running for as long as the pet is around.
But there's no Pod for `mochi`:

```sh
kubectl get pods -n zoo
```

```text
No resources found in zoo namespace.
```

It's important to know that a CRD on its own only stores objects. The controller is what acts on them, and we'll write one soon.
But first, let's make the API strict.

### Adding validation, defaults, and a status

The complete CRD is in `~/pet-operator/config/crd-by-hand.yaml`.
The most interesting part is the validation rules on `spec`:

```yaml [~/pet-operator/config/crd-by-hand.yaml]
            x-kubernetes-validations:
            - rule: "self.species != 'cactus' || !has(self.toy)"
              message: "cacti don't play with toys"
            - rule: "self.species != 'dragon' || duration(self.diet.feedEvery) >= duration('1h')"
              message: "dragons eat at most once an hour: diet.feedEvery must be at least 1h"
```

The table below goes through the rest of the file:

| Part of the CRD | What the API server does with it |
|---|---|
| `openAPIV3Schema` with `type`, `required`, `enum`, `maxLength`, `pattern`, `format` | Rejects invalid objects before they reach etcd. `kubectl` gets an error for unknown fields, and less strict clients get them pruned. |
| `x-kubernetes-validations` | Evaluates [CEL](https://kubernetes.io/docs/reference/using-api/cel/) rules that OpenAPI can't express, such as "a cactus can't have a toy". The cactus rule and the dragon rule are on `spec`, because each of them reads two fields. |
| `duration(...)` | Compares durations as time, not as text. As strings, `'59m' >= '1h'` would be `true`. |
| A rule on `feedEvery` | Keeps `feedEvery` between `1s` and a year. The pattern alone accepts `0s` and `9999999h`, which the controller can't use. |
| `default` | Fills in missing fields, so every client, including the controller, reads the same complete object. |
| `diet: default: {}` | Defaults only apply when the parent object exists. Without this line, a Pet without a `diet` block never gets `food: snacks` or `feedEvery: 10m`. |
| `subresources: status: {}` | Gives `.status` a separate endpoint. Users write the `spec` and the controller writes the `status` through separate endpoints, so a write to one doesn't change the other. |
| `additionalPrinterColumns` | Adds columns to `kubectl get`. Once you define custom columns, `AGE` is no longer added automatically, so it's on the list. |

Apply it:

```sh
kubectl apply -f ~/pet-operator/config/crd-by-hand.yaml
```

Now, let's send a few invalid Pets to the API server and see what happens:

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

```text
The Pet "nope" is invalid: 
* spec.species: Unsupported value: "unicorn": supported values: "cat", "dog", "dragon", "cactus"

The Pet "nope" is invalid: spec: Invalid value: cacti don't play with toys

The Pet "nope" is invalid: spec: Invalid value: dragons eat at most once an hour: diet.feedEvery must be at least 1h

The Pet "nope" is invalid: spec: Invalid value: dragons eat at most once an hour: diet.feedEvery must be at least 1h

The Pet "nope" is invalid: 
* spec.diet.feedEvery: Invalid value: "whenever": spec.diet.feedEvery in body should match '^[0-9]+(s|m|h)$'
```

Take a look at the fourth one, a dragon without a `diet`.
It gets the default `feedEvery: 10m`, and only then fails the dragon rule.
The API server always applies defaults before it validates an object.

::image-box
---
:src: __static__/request-pipeline.png
:alt: 'The path of a Pet through the API server: decoding and pruning, defaulting, mutating webhooks, schema and CEL validation, validating webhooks, and etcd.'
---
::

The existing `mochi` Pet got the defaults too, even though its manifest has no `diet`.
The API server also applies defaults when it reads an object from etcd, so objects created before the defaults existed get them as well:

```sh
kubectl get pet -n zoo mochi -o yaml | grep -A8 '^spec:'
kubectl get pets -n zoo
```

```text
spec:
  diet:
    feedEvery: 10m
    food: snacks
  species: cat
  toy: yarn
NAME    SPECIES   FACE   MOOD   TOY    LAST FED   AGE
mochi   cat                     yarn              4s
```

::simple-task
---
:tasks: tasks
:name: verify_crd_full
---
#active
Waiting for the CRD to validate Pets and fill in defaults...

#completed
The API server rejects invalid Pets and fills in the default diet for valid ones.
::

## Writing a controller in bash

Now that the API is in place, it's time to write the controller.
A controller is a loop.
It reads the desired state, compares it with the actual state, changes the actual state to match, and then repeats.

For our pets, the desired state is the Pet: `mochi` is a cat that likes yarn.
The actual state is a Pod where `mochi` lives, and a Pet without one is a pet that doesn't exist yet.
So the controller reads Pets and creates Pods.
A Deployment works the same way: you write the Deployment, and controllers turn it into Pods.

The loop fits in a few lines of bash, in `~/pet-operator/bash/naive-controller.sh`.
Every 5 seconds, it goes through all Pets and creates a Pod for each Pet that doesn't have one yet:

```bash [~/pet-operator/bash/naive-controller.sh]
while true; do
  for pet in $(kubectl get pets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}'); do
    ns=${pet%/*}; name=${pet#*/}
    species=$(kubectl get pet -n "$ns" "$name" -o jsonpath='{.spec.species}')

    if ! kubectl get pod -n "$ns" "$name" >/dev/null 2>&1; then
      kubectl run "$name" -n "$ns" --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never -- \
        sh -c "while true; do echo \"I am $name the $species\"; sleep 10; done"
    fi
  done
  sleep 5
done
```

Open a second terminal tab (the **+** button next to the terminal tabs) and start the script there:

```sh
bash ~/pet-operator/bash/naive-controller.sh
```

In the first tab, check the Pods:

```sh
kubectl get pods -n zoo
kubectl wait -n zoo --for=condition=Ready pod/mochi --timeout=90s
kubectl logs -n zoo mochi
```

```text
NAME    READY   STATUS    RESTARTS   AGE
mochi   1/1     Running   0          10s
pod/mochi condition met
I am mochi the cat
```

::simple-task
---
:tasks: tasks
:name: verify_naive_controller
---
#active
Waiting for the bash controller to create a Pod for mochi...

#completed
The bash controller created the `mochi` Pod. The Pet now causes changes in the cluster.
::

Now, delete the Pod and watch it come back.
The shell in the Pod runs as PID 1 and has no `SIGTERM` handler, so it ignores the signal, and `--grace-period=1` saves you a 30-second wait:

```sh
kubectl delete pod -n zoo mochi --grace-period=1
kubectl get pods -n zoo -w    # Ctrl+C to stop watching
```

```text
pod "mochi" deleted from zoo namespace
NAME    READY   STATUS    RESTARTS   AGE
mochi   0/1     Pending   0          0s
mochi   0/1     Pending   0          0s
mochi   0/1     ContainerCreating   0          0s
mochi   0/1     ContainerCreating   0          1s
mochi   1/1     Running             0          1s
```

A quick clarification about what just happened: the script never saw the deletion.
On its next pass, it found no Pod for `mochi` and created one.
Think of it as a thermostat. It doesn't care why the room got cold, it only compares the current temperature with the one you asked for.
This approach is called **level-triggered** reconciliation, and it means that a missed event doesn't matter, because the next pass fixes the state anyway.

### Finding the limits of the bash controller

The loop works, but it has a few problems. First, change the species of `mochi`:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"species":"dog"}}'
sleep 10
kubectl logs -n zoo mochi --tail=1
```

```text
pet.zoo.example.com/mochi patched
I am mochi the cat
```

The Pod still says that `mochi` is a cat.
The script only checks that *a* Pod exists, not that it matches the Pet.
Fixing that isn't easy, because most of a Pod's spec can't be changed after the Pod is created.
Revert the change:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"species":"cat"}}'
```

Next, create another Pet, wait for its Pod, and delete the Pet:

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

```text
pet.zoo.example.com/goldie created
pet.zoo.example.com "goldie" deleted from zoo namespace
NAME     READY   STATUS    RESTARTS   AGE
goldie   1/1     Running   0          14s
mochi    1/1     Running   0          40s
```

The `goldie` Pod is still running, but the Pet it was created for is gone.
The script only knows how to create Pods, never how to delete them.
And there's more:

- On every pass, it lists all Pets and sends two more requests for each of them, even when nothing has changed. With 5,000 Pets, that's about 10,000 requests on every pass.
- It doesn't write a status, so the Pet doesn't show whether its Pod is running.
- Nothing links a Pod to the Pet it was created for.
- Pets should get hungry over time. Polling makes that easy, since the script wakes up every 5 seconds anyway.
  But a good controller only wakes up when something in the cluster changes, and time passing doesn't count as a change.
  We'll see how a real controller handles that.

That's enough bash. Stop the script with `Ctrl+C` in the second tab, and delete the Pods it created:

```sh
kubectl delete pods -n zoo --all --grace-period=1
```

::remark-box
---
kind: warning
---
Don't skip the cleanup!
The Go controller never takes over a Pod it didn't create.
If the old `mochi` Pod is still around, the controller reports `PodNameTaken` in the Pet's status instead of creating its own Pod.
::

## Writing a controller in Go

### Setting up the project

[controller-runtime](https://github.com/kubernetes-sigs/controller-runtime) is the library that Kubebuilder and Operator SDK generate code for.
I want you to see every file of the project, so we'll use it directly, without a scaffolding tool.
Here's what's in `~/pet-operator`:

```text
pet-operator/
├── api/v1alpha1/              the Pet type in Go
├── internal/controller/       the reconcile loop
├── config/                    the CRDs (the two you applied, and soon a generated one)
├── bash/                      the bash controller
├── go.mod, go.sum             the dependencies, controller-runtime v0.25.1
└── main.go                    creates the manager and starts the controller
```

Download the dependencies and install `controller-gen`, a code generator from the Kubebuilder project:

```sh
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
cd ~/pet-operator

go mod download
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.22.0
```

The downloads take about a minute. Meanwhile, let's go through the code.

### Defining the Pet type in Go

The controller works with Go structs that mirror the CRD schema.
They live in `api/v1alpha1/pet_types.go`.
Pay attention to the `+kubebuilder:` comments above the fields, which are called **markers**:

```go [~/pet-operator/api/v1alpha1/pet_types.go]
// +kubebuilder:validation:XValidation:rule="self.species != 'cactus' || !has(self.toy)",message="cacti don't play with toys"
// +kubebuilder:validation:XValidation:rule="self.species != 'dragon' || duration(self.diet.feedEvery) >= duration('1h')",message="dragons eat at most once an hour: diet.feedEvery must be at least 1h"
type PetSpec struct {
	// +kubebuilder:validation:Enum=cat;dog;dragon;cactus
	Species string `json:"species"`

	// +kubebuilder:validation:MaxLength=20
	// +optional
	Toy string `json:"toy,omitempty"`

	// +kubebuilder:default={}
	// +optional
	Diet Diet `json:"diet,omitempty"`

	// When the pet was last fed. Feed it by setting this to the current time.
	// +optional
	LastFedAt *metav1.Time `json:"lastFedAt,omitempty"`
}
```

Each marker corresponds to a line of the CRD you applied: `Enum`, `MaxLength`, `default`, and `XValidation` for the CEL rules.
The `Pet` type itself carries the rest, like the status subresource and the printer columns:

```go [~/pet-operator/api/v1alpha1/pet_types.go]
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=pt,categories=zoo
// +kubebuilder:printcolumn:name="Species",type=string,JSONPath=`.spec.species`
// +kubebuilder:printcolumn:name="Face",type=string,JSONPath=`.status.face`
// +kubebuilder:printcolumn:name="Mood",type=string,JSONPath=`.status.mood`
// +kubebuilder:printcolumn:name="Toy",type=string,JSONPath=`.spec.toy`
// +kubebuilder:printcolumn:name="Last Fed",type=date,JSONPath=`.spec.lastFedAt`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
// +kubebuilder:object:root=true
type Pet struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PetSpec   `json:"spec"`
	Status PetStatus `json:"status,omitempty"`
}
```

The status also has three new fields: the name of the Pod the pet lives in, and two fields that most controllers report, `observedGeneration` and `conditions`.
The other file in the folder, `groupversion_info.go`, only registers the `zoo.example.com/v1alpha1` group and version.

### Generating the CRD

Every Kubernetes object type in Go needs deep-copy methods.
They're pure boilerplate, so we'll let `controller-gen` write them.
The same tool also generates the CRD from the markers:

```sh
controller-gen object paths=./api/...
controller-gen crd paths=./api/... output:crd:dir=config

ls api/v1alpha1 config
```

```text
api/v1alpha1:
groupversion_info.go  pet_types.go  zz_generated.deepcopy.go

config:
crd-by-hand.yaml  crd-minimal.yaml  zoo.example.com_pets.yaml
```

Compare the generated CRD with the one you applied by hand:

```sh
diff <(kubectl create --dry-run=client -o yaml -f config/crd-by-hand.yaml) \
     <(kubectl create --dry-run=client -o yaml -f config/zoo.example.com_pets.yaml) | less
```

The names and the whole `spec` schema, including the defaults and the CEL rules, are the same.
The differences are the field descriptions (taken from the Go comments), the new status fields,
and a few details that controller-gen always adds, such as `listKind`.
One difference changes the behavior: `spec` is now `required`, because the Go field has no `omitempty` tag.

::remark-box
---
kind: info
---
Kubebuilder projects run the same two commands in `make generate` and `make manifests`.
From now on, the Go types are the source of truth, and the CRD is generated from them.
::

Replace the hand-written CRD with the generated one:

```sh
kubectl apply -f config/zoo.example.com_pets.yaml
```

### Writing the reconciler

This is the main file of the operator: `internal/controller/pet_controller.go`.
It's about 250 lines, so let's go through it piece by piece.

::image-box
---
:src: __static__/reconcile-loop.png
:alt: 'What triggers a reconcile: Pet events, events on owned Pods and ConfigMaps, RequeueAfter timers, and the controller start all add a name to the work queue, and Reconcile observes, computes, acts, and reports.'
---
::

Everything starts with `Reconcile`:

```go [~/pet-operator/internal/controller/pet_controller.go]
// Reconcile makes the world match one Pet. It is called with just a namespace/name,
// never with "what changed", so it always starts by reading the current state.
func (r *PetReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	// 1. Observe: fetch the desired state.
	var pet zoov1alpha1.Pet
	if err := r.Get(ctx, req.NamespacedName, &pet); err != nil {
		// Deleted? Nothing to do: owner references let the garbage collector remove the Pod and ConfigMap.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
```

`Reconcile` gets only the namespace and name of a Pet.
It doesn't get the event, the diff, or the old object.
Just like the bash loop, it reads the current state and works from there.
If the Pet is gone, there's nothing to do. We'll see why at the end of the tutorial.

Next, the controller works out how hungry the pet is:

```go [~/pet-operator/internal/controller/pet_controller.go]
	// How hungry is it? Nothing in the cluster changes when time passes,
	// so the controller has to work this out itself on every run.
	feedEvery, err := time.ParseDuration(pet.Spec.Diet.FeedEvery)
	if err != nil {
		return ctrl.Result{}, err
	}
	lastFed := pet.CreationTimestamp.Time
	if pet.Spec.LastFedAt != nil {
		lastFed = pet.Spec.LastFedAt.Time
	}
	now := time.Now()
	mood, moodChangesAt := moodAt(now, lastFed, feedEvery)
```

The mood isn't stored anywhere.
Nothing in the cluster changes when time passes, so every run calculates the mood from `lastFedAt` and the current time.
`moodAt` also returns when the mood changes next, which we'll need in a moment.

Then it acts. The pet's "card" goes into a ConfigMap, and the Pod shows it:

```go [~/pet-operator/internal/controller/pet_controller.go]
	// 2. Act: the ConfigMap holds the pet's "card", the Pod shows it.
	// takenBy names the kind of object in the way, if someone else owns the name we need.
	card := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: pet.Name + "-card", Namespace: pet.Namespace}}
	takenBy, podName := "", ""
	cardTaken, err := r.reconcileCard(ctx, &pet, card, mood)
	if err != nil {
		return ctrl.Result{}, err
	}
```

The Pod only mounts the card, and the controller never updates the Pod.
Everything that can change lives in the ConfigMap, which solves the bash controller's problem with the stale species.

Here's how the card gets written:

```go [~/pet-operator/internal/controller/pet_controller.go]
func (r *PetReconciler) reconcileCard(ctx context.Context, pet *zoov1alpha1.Pet, card *corev1.ConfigMap, mood string) (taken bool, err error) {
	if err := r.Get(ctx, client.ObjectKeyFromObject(card), card); err == nil && !metav1.IsControlledBy(card, pet) {
		r.Recorder.Eventf(pet, card, corev1.EventTypeWarning, "ConfigMapNameTaken", "UpdateCard", "ConfigMap %s already exists and doesn't belong to %s", card.Name, pet.Name)
		return true, nil
	} else if client.IgnoreNotFound(err) != nil {
		return false, err
	}

	// CreateOrUpdate creates the ConfigMap, or updates it only if the function changed something.
	op, err := controllerutil.CreateOrUpdate(ctx, r.Client, card, func() error {
		card.Data = map[string]string{"card": renderCard(pet, mood)}
		return controllerutil.SetControllerReference(pet, card, r.Scheme)
	})
	if err == nil && op != controllerutil.OperationResultNone {
		log.FromContext(ctx).Info("card updated", "mood", mood, "operation", op)
	}
	return false, err
}
```

`CreateOrUpdate` reads the ConfigMap and applies your function to it.
If the ConfigMap doesn't exist, it creates it. Otherwise, it sends an update only if the function changed something.
`SetControllerReference` adds an owner reference with `controller: true` that points to the Pet. We'll use it at the end.

It's important to know that a controller never uses or deletes objects it doesn't own.
Before touching the card, `reconcileCard` checks who owns it, and `reconcilePod` does the same for the Pod:

```go [~/pet-operator/internal/controller/pet_controller.go]
	// Never use, or delete, what you don't own.
	if exists && !metav1.IsControlledBy(&pod, pet) {
		if mood == RanAway {
			return "", false, nil
		}
		r.Recorder.Eventf(pet, &pod, corev1.EventTypeWarning, "PodNameTaken", "CreatePod", "Pod %s already exists and doesn't belong to %s", pod.Name, pet.Name)
		return "", true, nil
	}
```

If a Pod named `mochi` or a ConfigMap named `mochi-card` exists but isn't controlled by the Pet, the controller leaves it alone.
It reports `PodNameTaken` or `ConfigMapNameTaken` in the Pet's `AtHome` condition, records an event, and checks again every 10 seconds.
`Recorder.Eventf` records Kubernetes events, which show up in `kubectl describe pet`.

After acting, the controller reports what it saw in the status:

```go [~/pet-operator/internal/controller/pet_controller.go]
	// 3. Report: write what we observed to status.
	base := pet.DeepCopy()
	pet.Status.Mood = mood
	pet.Status.Face = faces[pet.Spec.Species][mood]
	pet.Status.PodName = podName
	pet.Status.ObservedGeneration = pet.Generation
```

The rest of that block sets the `AtHome` condition and saves the status with `r.Status().Patch()`, which goes through the `/status` endpoint.
A merge patch sends only the fields that changed.
An `Update` would send the whole object, and the API server would reject it whenever the controller's cached copy of the Pet is a step behind, which happens right after the controller's own writes.

::details-box
---
:summary: Why is status a separate subresource?
---
Without a status subresource, `.status` is an ordinary field.
Any client that can update a Pet can change its status, and every status update by the controller increases `metadata.generation`.
With the subresource enabled:

- Writes to the main resource ignore `.status`.
- Writes to `/status` ignore everything except `.status`.
- `metadata.generation` increases only when the `spec` changes.

The last point is what makes `observedGeneration` useful: the controller copies the `metadata.generation` it has acted on, and a status write doesn't bump the generation it just copied.
::

And finally, the part that makes the pets get hungry:

```go [~/pet-operator/internal/controller/pet_controller.go]
	// 4. Come back when the mood is due to change, even if nothing else happens.
	var wake time.Duration
	if !moodChangesAt.IsZero() {
		wake = moodChangesAt.Sub(now) + time.Second
	}
	// Only events on objects we own queue a reconcile, so nothing tells us when
	// someone else's Pod or ConfigMap goes away. Check back soon, even if the pet
	// ran away and has no mood change coming (wake == 0).
	if takenBy != "" && (wake == 0 || wake > 10*time.Second) {
		wake = 10 * time.Second
	}
	return ctrl.Result{RequeueAfter: wake}, nil
```

`RequeueAfter` tells controller-runtime to call `Reconcile` again after the given delay: one second after the mood is due to change.
The controller doesn't poll, and your code doesn't manage any timers. The work queue handles that.

At the bottom of the file, `SetupWithManager` decides what the controller watches:

```go [~/pet-operator/internal/controller/pet_controller.go]
// SetupWithManager wires up the watches: every Pet event, and every event on a
// Pod or ConfigMap a Pet owns, ends up as a Reconcile call for that Pet.
func (r *PetReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&zoov1alpha1.Pet{}).
		Owns(&corev1.Pod{}).
		Owns(&corev1.ConfigMap{}).
		Complete(r)
}
```

`For` watches Pets.
`Owns` makes controller-runtime reconcile the owner Pet whenever one of its Pods or ConfigMaps changes or is deleted.

### Starting the manager

`main.go` creates a **manager**:

```go [~/pet-operator/main.go]
	// The manager owns the shared informer cache, the clients, and the controllers' lifecycle.
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:  scheme,
		Metrics: metricsserver.Options{BindAddress: "0"},
	})
	if err != nil {
		setupLog.Error(err, "unable to create manager")
		os.Exit(1)
	}
```

And then registers our controller with it:

```go [~/pet-operator/main.go]
	if err := (&controller.PetReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorder("pet-operator"),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to set up controller")
		os.Exit(1)
	}
```

A quick clarification about the manager: it keeps a local cache of the objects we watch.
At startup, it lists them once and then keeps a watch open.
The `r.Get` calls in the reconciler read from this cache, not from the API server.
This is how a controller stays cheap with thousands of objects, and it fixes the polling problem of the bash controller.

### Running the operator

In production, operators run inside the cluster.
During development, it's faster to run them locally with your kubeconfig, which is what `make run` does in Kubebuilder projects:

```sh
go build -o pet-operator . && ./pet-operator
```

The first build takes a couple of minutes, because it compiles client-go and controller-runtime.
Keep the operator running, and use the other terminal tab from now on.


A pet gets hungry when `feedEvery` (10 minutes by default) has passed since its last feeding.
If it was never fed, the timer starts when it's created. After three times `feedEvery`, it runs away.
Poor `mochi` was adopted in the first section and hasn't been fed since.
Depending on how long ago that was, it's happy, hungry, or already gone:

```sh
kubectl get pets,pods -n zoo
```

Whatever happened, feeding fixes it.
(A note on the outputs below: I went through these steps quickly, so the ages in my outputs are shorter than yours will be.) A pet is fed by setting `spec.lastFedAt` to the current time, so let's add a small helper to the shell:

```sh
grep -q '^feed()' ~/.bashrc || cat >> ~/.bashrc <<'EOF'
feed() {
  kubectl patch pet "$1" -n zoo --type=merge \
    -p "{\"spec\":{\"lastFedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
}
EOF
source ~/.bashrc

feed mochi
kubectl get pets,pods -n zoo
```

```text
pet.zoo.example.com/mochi patched
NAME                        SPECIES   FACE   MOOD    TOY    LAST FED   AGE
pet.zoo.example.com/mochi   cat       😺      Happy   yarn   3s         78s

NAME        READY   STATUS    RESTARTS   AGE
pod/mochi   1/1     Running   0          7s
```

Now, check what the operator created, who owns it, and what it reported:

```sh
kubectl get pod,configmap -n zoo -o custom-columns=KIND:.kind,NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind
kubectl get pet -n zoo mochi -o jsonpath='{.status}' | python3 -m json.tool
```

```text
KIND        NAME               OWNER
Pod         mochi              Pet
ConfigMap   kube-root-ca.crt   <none>
ConfigMap   mochi-card         Pet
{
    "conditions": [
        {
            "lastTransitionTime": "2026-09-28T19:51:10Z",
            "message": "mochi lives in Pod mochi",
            "observedGeneration": 4,
            "reason": "Happy",
            "status": "True",
            "type": "AtHome"
        }
    ],
    "face": "\ud83d\ude3a",
    "mood": "Happy",
    "observedGeneration": 4,
    "podName": "mochi"
}
```

Once the Pod is running, say hi:

```sh
kubectl wait -n zoo --for=condition=Ready pod/mochi --timeout=90s
kubectl logs -n zoo mochi
```

```text
pod/mochi condition met
--- 19:51:10
mochi is happy.

  /\_/\
 ( ^.^ )
  > ^ <
playing with: yarn
```

::simple-task
---
:tasks: tasks
:name: verify_operator_adopted
---
#active
Waiting for the operator to create mochi's Pod and report its mood...

#completed
The Pet owns mochi's Pod and ConfigMap, and its status reports the mood and an up-to-date `observedGeneration`.
::

## Testing the operator

Now, let's break a few things and see how the operator reacts.
Keep the operator logs visible in one tab, and run the experiments in the other one.

### Letting time pass

Waiting ten minutes for a pet to get hungry is a bit long for a tutorial.
Set `feedEvery` to one minute, and feed `mochi` right away:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"diet":{"feedEvery":"1m"}}}'
feed mochi
kubectl get pets -n zoo -w    # Ctrl+C to stop watching
```

To follow the pet's card while you wait, open a third terminal tab and run the command below.
The kubelet refreshes mounted ConfigMaps periodically, so the card changes within a minute or two after the mood does:

```sh
kubectl logs -n zoo mochi -f
```

Now, don't touch anything.
After a minute, the mood changes to `Hungry`.
After three minutes, `mochi` runs away, and the operator deletes its Pod:

```text
NAME    SPECIES   FACE   MOOD    TOY    LAST FED   AGE
mochi   cat       😺      Happy   yarn   0s         79s
mochi   cat       😾      Hungry   yarn   61s        2m20s
mochi   cat       💨      RanAway   yarn   3m1s       4m20s
```

Nobody changed the Pet's spec during those three minutes.
Each reconcile returned a `RequeueAfter` that ends one second after the next mood change, so controller-runtime called `Reconcile` again right when the mood was due to change.

::image-box
---
:src: __static__/hunger-timeline.png
:alt: 'The mood of mochi over time: Happy until feedEvery, Hungry until three times feedEvery, and then it runs away and its Pod is deleted, until the next feeding. Reconcile runs after each feeding and each RequeueAfter.'
---
::

::simple-task
---
:tasks: tasks
:name: verify_ran_away
---
#active
Waiting for mochi to get hungry and run away (about 3 minutes)...

#completed
Your pet `mochi` ran away. Nobody changed the Pet's spec, but the controller still noticed, because it scheduled its own next reconcile.
::

Wait for the checkpoint above to turn green before you feed `mochi`, or it might not notice that mochi was gone.
Meanwhile, check the events that the operator recorded:

```sh
kubectl describe pet -n zoo mochi | tail -n 8
```

```text
  Face:                    💨
  Mood:                    RanAway
  Observed Generation:     6
Events:
  Type     Reason   Age    From          Message
  ----     ------   ----   ----          -------
  Normal   MovedIn  3m28s  pet-operator  mochi moved into Pod mochi
  Warning  RanAway  19s    pet-operator  mochi got too hungry and ran away
```

Once the checkpoint is green, feed `mochi` to bring it back:

```sh
feed mochi
kubectl get pets,pods -n zoo
```

```text
pet.zoo.example.com/mochi patched
NAME                        SPECIES   FACE   MOOD    TOY    LAST FED   AGE
pet.zoo.example.com/mochi   cat       😺      Happy   yarn   5s         4m44s

NAME        READY   STATUS    RESTARTS   AGE
pod/mochi   1/1     Running   0          5s
```

::simple-task
---
:tasks: tasks
:name: verify_came_home
---
#active
Waiting for mochi to come back...

#completed
Feeding changed the spec, the controller reconciled the Pet, and it created a new Pod.
::

Put `mochi` back on a relaxed diet, so that it doesn't run away during the next experiments:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"diet":{"feedEvery":"10m"}}}'
feed mochi
```

### Deleting the Pod

```sh
kubectl delete pod -n zoo mochi
kubectl get pods -n zoo -w    # Ctrl+C to stop watching
```

```text
pod "mochi" deleted from zoo namespace
NAME    READY   STATUS    RESTARTS   AGE
mochi   0/1     Pending   0          0s
mochi   0/1     Pending   0          0s
mochi   0/1     ContainerCreating   0          0s
mochi   0/1     ContainerCreating   0          0s
mochi   1/1     Running             0          1s
```

The Pod deletion triggered a reconcile of its owner Pet, and the controller created a new Pod.

### Editing the card by hand

Next, try to change the pet's card behind the operator's back:

```sh
kubectl patch configmap -n zoo mochi-card --type=merge -p '{"data":{"card":"mochi is a dog now"}}'
kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'
```

```text
configmap/mochi-card patched
mochi is happy.

  /\_/\
 ( ^.^ )
  > ^ <
playing with: yarn
```

By the time you read the card, the change is already gone.
The ConfigMap update triggered a watch event, controller-runtime queued the owner Pet, and the reconcile wrote the correct card back.

### Changing the spec

Unlike with the bash controller, a change to the Pet's spec now updates the pet's card:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"toy":"laser pointer"}}'

kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'
kubectl get pet -n zoo mochi \
  -o jsonpath='generation={.metadata.generation} observedGeneration={.status.observedGeneration}{"\n"}'
```

```text
pet.zoo.example.com/mochi patched
mochi is happy.

  /\_/\
 ( ^.^ )
  > ^ <
playing with: laser pointer
generation=10 observedGeneration=10
```

`observedGeneration` is equal to `generation`, which means that the controller has processed the latest version of the spec.

### Restarting the operator

Stop the operator with `Ctrl+C` in its tab.
While it's stopped, change the spec in the other tab:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"toy":"cardboard box"}}'
kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'   # still the laser pointer
```

Start the operator again in its tab with `./pet-operator`, and check the card once more in the other tab:

```sh
kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'
```

```text
mochi is happy.

  /\_/\
 ( ^.^ )
  > ^ <
playing with: cardboard box
```

On startup, the cache LISTs all Pets, and the controller reconciles each of them.
The controller doesn't need to see every event, only the current state, so the change it missed while it was stopped doesn't matter.

### Deleting a Pet

Remember how deleting `goldie` left its Pod running under the bash controller?
Let's try that again with the operator. Create a second Pet:

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

```text
pet.zoo.example.com/smaug created
NAME                        SPECIES   FACE   MOOD    TOY             LAST FED   AGE
pet.zoo.example.com/mochi   cat       😺      Happy   cardboard box   30s        5m14s
pet.zoo.example.com/smaug   dragon    🐲      Happy                              5s

NAME        READY   STATUS    RESTARTS   AGE
pod/mochi   1/1     Running   0          23s
pod/smaug   1/1     Running   0          5s

NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      5m17s
configmap/mochi-card         1      4m3s
configmap/smaug-card         1      5s
```

::simple-task
---
:tasks: tasks
:name: verify_second_pet
---
#active
Waiting for the operator to create smaug's Pod and ConfigMap...

#completed
The `smaug` Pet owns its Pod and ConfigMap.
::

Once the checkpoint above turns green, `smaug` has to move to a bigger zoo, so delete the Pet.
If you delete it earlier, the checkpoint might miss `smaug`'s Pod, and you'll need to create the Pet again.

```sh
kubectl delete pet -n zoo smaug
kubectl get pods,configmaps -n zoo
```

```text
pet.zoo.example.com "smaug" deleted from zoo namespace
NAME        READY   STATUS    RESTARTS   AGE
pod/mochi   1/1     Running   0          29s

NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      5m23s
configmap/mochi-card         1      4m9s
```

The Pod and the ConfigMap are gone, but the operator didn't delete them.
Its `Reconcile` got a "not found" error for the Pet and returned.
The Kubernetes **garbage collector** deleted them, because it deletes objects whose owner was deleted.
That's what the owner references are for.

::image-box
---
:src: __static__/ownership-gc.png
:alt: 'Without owner references, the Pod created by the bash controller outlives its Pet. With owner references, deleting a Pet lets the garbage collector delete its Pod and ConfigMap.'
---
::

::simple-task
---
:tasks: tasks
:name: verify_garbage_collected
---
#active
Waiting for smaug, its Pod and its ConfigMap to be deleted...

#completed
The garbage collector deleted smaug's Pod and ConfigMap together with the Pet.
::

## Common points to debug

If something doesn't behave the way you expect:

- If `controller-gen` or `go` isn't found, make sure your `PATH` has both Go directories: `export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin`.
- If `go build` fails with missing packages, run `go mod tidy` in `~/pet-operator` again.
- If `mochi` never gets a Pod, check its conditions with `kubectl describe pet -n zoo mochi`. `PodNameTaken` means a Pod from the bash controller is still there. Delete it, and the operator moves `mochi` in within 10 seconds.
- If a Pod is stuck in `Pending` or `ContainerCreating`, check `kubectl get events -n zoo`. The Pod needs to pull the `public.ecr.aws/docker/library/busybox:1.37` image, and the cluster needs a working networking plugin.
- If the checkpoint after starting the operator doesn't turn green and `kubectl get pet -n zoo mochi -o jsonpath='{.status.observedGeneration}'` is empty, the API server still uses the hand-written CRD, which drops that field. Apply `config/zoo.example.com_pets.yaml`.
- If `kubectl describe pet -n zoo mochi` shows `PodNameTaken` or `ConfigMapNameTaken`, an object that the Pet doesn't own is using the name the operator needs. Delete it, and the operator takes over within 10 seconds. If you just deleted and re-created the Pet, wait 10 seconds instead: the old Pet's objects are still being cleaned up.
- If a change doesn't show up, check the operator logs. Every card update is logged, and so is every failed reconcile.
- If the card in the Pod logs looks out of date, give the kubelet a minute or two to refresh the mounted ConfigMap. `kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'` shows the current card right away.

## Wrapping up

That's it! You've built an operator from scratch.
The CRD defines the API, and the API server checks every Pet against it.
The controller gets a name, reads the current state, and fixes the cluster to match.
Because it only looks at the current state, deleted Pods, manual edits, and restarts are all handled the same way.

Real operators like cert-manager use the same pieces: a status with conditions, `RequeueAfter`, `Owns()`, and owner references.
Production operators usually add a few more things:

- Finalizers, for cleanup that the garbage collector can't do, such as deleting resources outside the cluster.
- RBAC rules generated from `+kubebuilder:rbac` markers, a ServiceAccount, and a Deployment to run the operator inside the cluster.
- Predicates, such as `GenerationChangedPredicate`, to skip reconciles that can't change anything, like the one triggered by the controller's own status update.
- Tests with `envtest`, which runs a real kube-apiserver and etcd.
- Admission webhooks, for validation and defaulting that CEL can't express.
- A project generated by [Kubebuilder](https://book.kubebuilder.io/), with a similar layout plus a Makefile, a Dockerfile, and kustomize manifests.

### References

- [Kubernetes documentation: Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
- [Kubernetes documentation: Controllers](https://kubernetes.io/docs/concepts/architecture/controller/)
- [controller-runtime](https://github.com/kubernetes-sigs/controller-runtime)
- [The Kubebuilder Book](https://book.kubebuilder.io/)
- [Garbage collection and owner references](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
- [How Kubernetes CRDs Work: Designing a Validated API From Scratch](/tutorials/open-a-kubernetes-zoo-9ad54ae8)
