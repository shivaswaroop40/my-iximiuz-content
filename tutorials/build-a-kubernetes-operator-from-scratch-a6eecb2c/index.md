---
kind: tutorial

title: "How Kubernetes Operators Work: Building a Controller From Scratch"

description: |
  Learn how Kubernetes operators work by building one for a small Pet API, first as a 15-line bash loop and then as a Go controller with controller-runtime.
  See how the reconcile loop recreates deleted Pods, reports status, and reacts to the passage of time, and how owner references let the garbage collector clean up.

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

tasks:
  init_go:
    init: true
    machine: dev-machine
    user: root
    timeout_seconds: 900
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
    timeout_seconds: 900
    run: |
      set -euo pipefail
      for i in $(seq 1 400); do
        kubectl get --raw /readyz >/dev/null 2>&1 && break
        sleep 2
      done
      kubectl get --raw /readyz >/dev/null
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

Many popular Kubernetes add-ons are operators, for example cert-manager, Argo CD, CloudNativePG, and Cluster API.
An operator consists of two parts.
A CustomResourceDefinition (CRD) adds a new resource type to the Kubernetes API,
and a controller watches the resources of that type and changes the cluster to match them.

In this tutorial, we'll build an operator from scratch for a small example API, a `Pet` resource.
For every Pet, the operator creates a Pod for the pet to live in, and it keeps track of how hungry the pet is.
If nobody feeds the pet for too long, the pet runs away, and the operator deletes its Pod.

Along the way, we'll answer the following questions:

- What does a controller do, and why is it written as a loop?
- Why does a controller receive only the name of an object, and not the event that changed it?
- How can a controller react to the passage of time, when nothing in the cluster changes?
- How do owner references let Kubernetes clean up after a deleted resource?
- What do controller-runtime and Kubebuilder do for you?

We'll start with a controller written in 15 lines of bash, see where it falls short, and then write a proper one in Go.

::image-box
---
:src: __static__/operator-overview.png
:alt: 'The Pet operator: a user writes the Pet spec, the controller watches Pets, creates a ConfigMap and a Pod for each of them, and writes the status back.'
---
::

Let's get started!

## Prerequisites

Basic familiarity with Kubernetes and `kubectl` is assumed.
Knowing Go helps, but it isn't required.
All the code is provided, and the important parts are explained.

The playground comes with a multi-node Kubernetes cluster, and `kubectl` on the `dev-machine` is already configured to talk to it.
Go is installed, too.
If the playground asks you to choose a networking plugin, keep the default one (flannel), because the pets need running Pods.
The `zoo` namespace is created for you.

## Defining the Pet API (CustomResourceDefinition)

::remark-box
---
kind: info
---
This section covers CRD design briefly.
If schemas, CEL rules, and defaults are new to you,
[How Kubernetes CRDs Work: Designing a Validated API From Scratch](/tutorials/open-a-kubernetes-zoo-9ad54ae8)
builds the same CRD step by step.
::

### The smallest CRD that works

A CRD needs a group, a kind with its plural and singular names, and at least one version with a schema.
The schema below accepts any `spec`:

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
            x-kubernetes-preserve-unknown-fields: true   # accept any fields, for now
EOF

kubectl apply -f ~/pet-operator/config/crd-minimal.yaml
```

The API server starts serving a new REST endpoint right away, with no restart and no compiled code:

```sh
kubectl api-resources --api-group=zoo.example.com
kubectl get --raw /apis/zoo.example.com/v1alpha1 | python3 -m json.tool
```

```text
NAME   SHORTNAMES   APIVERSION                 NAMESPACED   KIND
pets                zoo.example.com/v1alpha1   true         Pet
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
            "storageVersionHash": "rsi7zQxickQ="
        }
    ]
}
```

Create the first Pet:

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

Now, create a Pet that makes no sense:

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

```text
pet.zoo.example.com/sparkles created
```

The API server accepts it, because the schema allows any `spec`.
And nothing else happens. No Pod was created for either Pet:

```sh
kubectl get pods -n zoo
```

```text
No resources found in zoo namespace.
```

**A CRD on its own only stores objects.** Acting on them is the controller's job, and we'll write one in the next section.
But first, let's make the API strict:

```sh
kubectl delete pet -n zoo sparkles
```

### Adding validation, defaults, and a status

Here is the complete CRD.
Read through it first, and then check the table below it for what each part does:

```sh
cat > ~/pet-operator/config/crd-by-hand.yaml <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
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
  versions:
  - name: v1alpha1
    served: true
    storage: true
    subresources:
      status: {}
    additionalPrinterColumns:
    - {name: Species,  type: string, jsonPath: .spec.species}
    - {name: Face,     type: string, jsonPath: .status.face}
    - {name: Mood,     type: string, jsonPath: .status.mood}
    - {name: Toy,      type: string, jsonPath: .spec.toy}
    - {name: Last Fed, type: date,   jsonPath: .spec.lastFedAt}
    - {name: Age,      type: date,   jsonPath: .metadata.creationTimestamp}
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [species]
            x-kubernetes-validations:
            - rule: "self.species != 'cactus' || !has(self.toy)"
              message: "cacti don't play with toys"
            - rule: "self.species != 'dragon' || duration(self.diet.feedEvery) >= duration('1h')"
              message: "dragons eat at most once an hour: diet.feedEvery must be at least 1h"
            properties:
              species:
                type: string
                enum: [cat, dog, dragon, cactus]
              toy:
                type: string
                maxLength: 20
              diet:
                type: object
                default: {}
                properties:
                  food:
                    type: string
                    maxLength: 20
                    default: snacks
                  feedEvery:
                    type: string
                    maxLength: 10
                    pattern: '^[0-9]+(s|m|h)$'
                    default: 10m
                    x-kubernetes-validations:
                    - rule: "duration(self) >= duration('1s') && duration(self) <= duration('8760h')"
                      message: "feedEvery must be between 1s and 8760h (a year)"
              lastFedAt:
                type: string
                format: date-time
          status:
            type: object
            properties:
              mood:
                type: string
              face:
                type: string
EOF

kubectl apply -f ~/pet-operator/config/crd-by-hand.yaml
```

| Part of the CRD | What the API server does with it |
|---|---|
| `shortNames`, `categories` | Makes `kubectl get pt` and `kubectl get zoo` work. |
| `openAPIV3Schema` with `type`, `required`, `enum`, `maxLength`, `pattern`, `format` | Rejects invalid objects before they reach etcd. `kubectl` gets an error for unknown fields, and less strict clients get them pruned. |
| `x-kubernetes-validations` | Evaluates [CEL](https://kubernetes.io/docs/reference/using-api/cel/) rules that OpenAPI can't express, such as "a cactus can't have a toy". The cactus rule and the dragon rule are on `spec`, because each of them reads two fields. |
| `duration(...)` | Parses durations in CEL. Compared as strings, `'59m' >= '1h'` would be `true`. A third rule, on `feedEvery` itself, keeps it between `1s` and a year, because the pattern alone accepts `0s` and `9999999h`, which the controller can't use. |
| `default` | Fills in missing fields, so every client, including the controller, reads the same complete object. |
| `diet: default: {}` | Defaults only apply when the parent object exists. Without this line, a Pet without a `diet` block never gets `food: snacks` or `feedEvery: 10m`. |
| `subresources: status: {}` | Gives `.status` a separate endpoint. Users write the `spec` and the controller writes the `status` through separate endpoints, so a write to one doesn't change the other. |
| `additionalPrinterColumns` | Adds columns to `kubectl get`. Once you define custom columns, `AGE` is no longer added automatically, so it's on the list. |

Now, send a few invalid Pets to the API server:

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

Look at the fourth one, a dragon without a `diet`.
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

The last point lets a controller set `status.observedGeneration` to the `metadata.generation` it has acted on.
We'll use it in the Go controller.
::

## Writing a controller in 15 lines of bash

A controller is a loop.
It reads the desired state, compares it with the actual state, changes the actual state to match, and then repeats.
The loop fits in a few lines of bash.
This one creates a Pod for every Pet:

```sh
cat > ~/naive-controller.sh <<'EOF'
#!/usr/bin/env bash
# A minimal controller: read the desired state, create what's missing,
# sleep for a few seconds, and repeat.
while true; do
  for pet in $(kubectl get pets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}'); do
    ns=${pet%/*}; name=${pet#*/}
    species=$(kubectl get pet -n "$ns" "$name" -o jsonpath='{.spec.species}')

    if ! kubectl get pod -n "$ns" "$name" >/dev/null 2>&1; then
      kubectl run "$name" -n "$ns" --image=busybox:1.37 --restart=Never -- \
        sh -c "while true; do echo \"I am $name the $species\"; sleep 10; done"
    fi
  done
  sleep 5
done
EOF
chmod +x ~/naive-controller.sh
```

Open a second terminal tab (the **+** button next to the terminal tabs) and start the script there:

```sh
~/naive-controller.sh
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

Delete the Pod and watch it come back.
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

The script didn't see the deletion event.
On the next pass, it found no Pod for `mochi` and created one.
This approach is called **level-triggered** reconciliation.
If a controller misses an event, the next pass still brings the cluster to the right state.

### What the bash controller gets wrong

First, change the species of `mochi`:

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
It has a few other problems:

- Every 5 seconds, it lists all Pets and sends two more requests for each of them, even when nothing has changed. With 5,000 Pets, that's 10,000 requests every 5 seconds.
- It doesn't write a status, so the Pet doesn't show whether its Pod is running.
- Nothing links a Pod to the Pet it was created for.
- Pets should get hungry over time. Polling makes that easy, since the script wakes up every 5 seconds anyway.
  But an efficient controller reacts to changes in the cluster, and the passage of time isn't one of them.
  We'll see how a real controller handles this.

Stop the script with `Ctrl+C` in the second tab, and delete the Pods it created:

```sh
kubectl delete pods -n zoo --all --grace-period=1
```

::remark-box
---
kind: warning
---
Don't skip the cleanup.
The Go controller never takes over a Pod it didn't create.
If the old `mochi` Pod is still around, the controller reports `PodNameTaken` in the Pet's status instead of creating its own Pod.
::

## Writing a controller in Go (controller-runtime)

### Setting up the project

[controller-runtime](https://github.com/kubernetes-sigs/controller-runtime) is the library that Kubebuilder and Operator SDK generate code for.
We'll use it directly, without any scaffolding tool, so you create every file of the project yourself, except the two that `controller-gen` generates:

```sh
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
go version

cd ~/pet-operator
go mod init example.com/pet-operator
go get sigs.k8s.io/controller-runtime@v0.25.1
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.22.0
```

The downloads take about a minute.
Here is the layout of the project we're going to write:

```text
pet-operator/
├── api/v1alpha1/              the Pet type in Go
├── internal/controller/       the reconcile loop
├── config/                    the CRDs (the two you wrote, and the generated one)
└── main.go                    creates the manager and starts the controller
```

### Defining the API types in Go

The controller works with Go structs that mirror the CRD schema.
The first file registers the API group and version of these types:

```sh
mkdir -p api/v1alpha1 internal/controller
cat > api/v1alpha1/groupversion_info.go <<'EOF'
// Package v1alpha1 contains the Pet API.
// +kubebuilder:object:generate=true
// +groupName=zoo.example.com
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	GroupVersion  = schema.GroupVersion{Group: "zoo.example.com", Version: "v1alpha1"}
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}
	AddToScheme   = SchemeBuilder.AddToScheme
)
EOF
```

The second file defines the types themselves.
Pay attention to the `+kubebuilder:` comments, which are called **markers**:

```sh
cat > api/v1alpha1/pet_types.go <<'EOF'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

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

type Diet struct {
	// +kubebuilder:validation:MaxLength=20
	// +kubebuilder:default=snacks
	// +optional
	Food string `json:"food,omitempty"`

	// How often the pet needs food, e.g. "10m" or "6h".
	// +kubebuilder:validation:MaxLength=10
	// +kubebuilder:validation:Pattern=`^[0-9]+(s|m|h)$`
	// +kubebuilder:validation:XValidation:rule="duration(self) >= duration('1s') && duration(self) <= duration('8760h')",message="feedEvery must be between 1s and 8760h (a year)"
	// +kubebuilder:default="10m"
	// +optional
	FeedEvery string `json:"feedEvery,omitempty"`
}

type PetStatus struct {
	// Happy, Hungry or RanAway.
	// +optional
	Mood string `json:"mood,omitempty"`

	// +optional
	Face string `json:"face,omitempty"`

	// The Pod the pet lives in. Empty if it ran away.
	// +optional
	PodName string `json:"podName,omitempty"`

	// The .metadata.generation the controller last acted on.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=pt,categories=zoo
// +kubebuilder:printcolumn:name="Species",type=string,JSONPath=`.spec.species`
// +kubebuilder:printcolumn:name="Face",type=string,JSONPath=`.status.face`
// +kubebuilder:printcolumn:name="Mood",type=string,JSONPath=`.status.mood`
// +kubebuilder:printcolumn:name="Toy",type=string,JSONPath=`.spec.toy`
// +kubebuilder:printcolumn:name="Last Fed",type=date,JSONPath=`.spec.lastFedAt`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type Pet struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PetSpec   `json:"spec"`
	Status PetStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type PetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Pet `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Pet{}, &PetList{})
}
EOF
```

Most markers correspond to a line of the CRD you wrote by hand: `Enum`, `MaxLength`, `Pattern`, `default`, `XValidation`, `resource`, `printcolumn`, and `subresource:status`.
The status has three new fields: the name of the Pod the pet lives in, and two fields that most controllers report, `observedGeneration` and `conditions`.

### Generating the CRD from the Go types

Every Kubernetes object type in Go needs deep-copy methods.
They are boilerplate, so `controller-gen` generates them.
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

Compare the generated CRD with the one you wrote by hand:

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

### Implementing the reconciler

The reconciler is the core of the operator.
The comments in the code explain each step:

```sh
cat > internal/controller/pet_controller.go <<'EOF'
package controller

import (
	"context"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/recorder"

	zoov1alpha1 "example.com/pet-operator/api/v1alpha1"
)

const (
	Happy   = "Happy"
	Hungry  = "Hungry"
	RanAway = "RanAway"
)

type PetReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder recorder.EventRecorder
}

// Reconcile makes the world match one Pet. It is called with just a namespace/name,
// never with "what changed", so it always starts by reading the current state.
func (r *PetReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Observe: fetch the desired state.
	var pet zoov1alpha1.Pet
	if err := r.Get(ctx, req.NamespacedName, &pet); err != nil {
		// Deleted? Nothing to do: owner references let the garbage collector remove the Pod and ConfigMap.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

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

	// 2. Act: the ConfigMap holds the pet's "card", the Pod shows it.
	card := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: pet.Name + "-card", Namespace: pet.Namespace}}
	op, err := controllerutil.CreateOrUpdate(ctx, r.Client, card, func() error {
		card.Data = map[string]string{"card": renderCard(&pet, mood)}
		return controllerutil.SetControllerReference(&pet, card, r.Scheme)
	})
	if err != nil {
		return ctrl.Result{}, err
	}
	if op != controllerutil.OperationResultNone {
		logger.Info("card updated", "mood", mood, "operation", op)
	}

	podName, nameTaken, err := r.reconcilePod(ctx, &pet, card, mood)
	if err != nil {
		return ctrl.Result{}, err
	}

	// 3. Report: write what we observed to status.
	pet.Status.Mood = mood
	pet.Status.Face = faces[pet.Spec.Species][mood]
	pet.Status.PodName = podName
	pet.Status.ObservedGeneration = pet.Generation
	home := metav1.Condition{
		Type:               "AtHome",
		Status:             metav1.ConditionTrue,
		Reason:             mood,
		Message:            fmt.Sprintf("%s lives in Pod %s", pet.Name, podName),
		ObservedGeneration: pet.Generation,
	}
	if mood == RanAway {
		home.Status, home.Message = metav1.ConditionFalse, fmt.Sprintf("%s ran away. Feed it to bring it back.", pet.Name)
	}
	if nameTaken {
		home.Status, home.Reason = metav1.ConditionFalse, "PodNameTaken"
		home.Message = fmt.Sprintf("a Pod named %s already exists and doesn't belong to this Pet. Delete it and %s moves in.", pet.Name, pet.Name)
	}
	meta.SetStatusCondition(&pet.Status.Conditions, home)
	if err := r.Status().Update(ctx, &pet); err != nil {
		return ctrl.Result{}, err
	}

	// 4. Come back when the mood is due to change, even if nothing else happens.
	var wake time.Duration
	if !moodChangesAt.IsZero() {
		wake = moodChangesAt.Sub(now) + time.Second
	}
	// The cache sees every Pod, but only events on Pods we own queue a reconcile,
	// so nothing tells us when someone else's Pod goes away. Check back soon.
	if nameTaken && (wake == 0 || wake > 10*time.Second) {
		wake = 10 * time.Second
	}
	return ctrl.Result{RequeueAfter: wake}, nil
}

// moodAt: fed less than feedEvery ago is Happy, less than 3x feedEvery is Hungry,
// anything longer and the pet runs away. It also says when the mood changes next.
func moodAt(now, lastFed time.Time, feedEvery time.Duration) (mood string, changesAt time.Time) {
	hungryAt := lastFed.Add(feedEvery)
	runAwayAt := lastFed.Add(3 * feedEvery)
	switch {
	case now.Before(hungryAt):
		return Happy, hungryAt
	case now.Before(runAwayAt):
		return Hungry, runAwayAt
	default:
		return RanAway, time.Time{} // it stays gone until someone feeds it
	}
}

// reconcilePod makes sure the pet's Pod exists, unless the pet ran away.
// Most of a Pod's spec can't be changed after creation, so the Pod never gets
// updated: anything that changes (the card) lives in the ConfigMap it mounts.
// It reports nameTaken if a Pod with the pet's name exists but isn't the pet's.
func (r *PetReconciler) reconcilePod(ctx context.Context, pet *zoov1alpha1.Pet, card *corev1.ConfigMap, mood string) (podName string, nameTaken bool, err error) {
	var pod corev1.Pod
	err = r.Get(ctx, client.ObjectKey{Namespace: pet.Namespace, Name: pet.Name}, &pod)
	exists := err == nil
	if err != nil && !apierrors.IsNotFound(err) {
		return "", false, err
	}

	// Never use, or delete, what you don't own.
	if exists && !metav1.IsControlledBy(&pod, pet) {
		if mood == RanAway {
			return "", false, nil
		}
		r.Recorder.Eventf(pet, &pod, corev1.EventTypeWarning, "PodNameTaken", "CreatePod", "Pod %s already exists and doesn't belong to %s", pod.Name, pet.Name)
		return "", true, nil
	}

	if mood == RanAway {
		if exists && pod.DeletionTimestamp == nil {
			if err := r.Delete(ctx, &pod); client.IgnoreNotFound(err) != nil {
				return "", false, err
			}
			r.Recorder.Eventf(pet, &pod, corev1.EventTypeWarning, "RanAway", "Starve", "%s got too hungry and ran away", pet.Name)
		}
		return "", false, nil
	}
	if exists {
		return pod.Name, false, nil
	}

	pod = corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      pet.Name,
			Namespace: pet.Namespace,
			Labels:    map[string]string{"zoo.example.com/pet": pet.Name},
		},
		Spec: corev1.PodSpec{
			TerminationGracePeriodSeconds: ptr.To[int64](1),
			Containers: []corev1.Container{{
				Name:         "pet",
				Image:        "busybox:1.37",
				Command:      []string{"sh", "-c", `while true; do echo "--- $(date +%T)"; cat /pet/card; sleep 10; done`},
				VolumeMounts: []corev1.VolumeMount{{Name: "card", MountPath: "/pet"}},
			}},
			Volumes: []corev1.Volume{{
				Name: "card",
				VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{Name: card.Name},
				}},
			}},
		},
	}
	if err := controllerutil.SetControllerReference(pet, &pod, r.Scheme); err != nil {
		return "", false, err
	}
	if err := r.Create(ctx, &pod); apierrors.IsAlreadyExists(err) {
		// The cache hasn't seen the Pod we created a moment ago yet. The next reconcile will.
		return pod.Name, false, nil
	} else if err != nil {
		return "", false, err
	}
	r.Recorder.Eventf(pet, &pod, corev1.EventTypeNormal, "MovedIn", "CreatePod", "%s moved into Pod %s", pet.Name, pod.Name)
	return pod.Name, false, nil
}

var faces = map[string]map[string]string{
	"cat":    {Happy: "😺", Hungry: "😾", RanAway: "💨"},
	"dog":    {Happy: "🐶", Hungry: "🥺", RanAway: "💨"},
	"dragon": {Happy: "🐲", Hungry: "🔥", RanAway: "💨"},
	"cactus": {Happy: "🌵", Hungry: "🥀", RanAway: "💨"},
}

var art = map[string]string{
	"cat": `
  /\_/\
 ( %s )
  > ^ <`,
	"dog": `
  /^ ^\
 / %s \
 V\ Y /V
  / - \
 |    \
 || (__V`,
	"dragon": `
   __/\__
  (  %s  )~~<
   \_vv_/  ~~`,
	"cactus": `
      _
   _ | | _
  | || || |
   \_%s_/
     | |
   __|_|__`,
}

var eyes = map[string]string{Happy: "^.^", Hungry: "o.o", RanAway: "   "}

func renderCard(pet *zoov1alpha1.Pet, mood string) string {
	var b strings.Builder
	switch mood {
	case RanAway:
		fmt.Fprintf(&b, "%s ran away. Feed it to bring it back!\n", pet.Name)
		return b.String()
	case Hungry:
		fmt.Fprintf(&b, "%s is HUNGRY. %s, please!\n", pet.Name, pet.Spec.Diet.Food)
	default:
		fmt.Fprintf(&b, "%s is happy.\n", pet.Name)
	}
	fmt.Fprintf(&b, art[pet.Spec.Species]+"\n", eyes[mood])
	if pet.Spec.Toy != "" {
		fmt.Fprintf(&b, "playing with: %s\n", pet.Spec.Toy)
	}
	return b.String()
}

// SetupWithManager wires up the watches: every Pet event, and every event on a
// Pod or ConfigMap a Pet owns, ends up as a Reconcile call for that Pet.
func (r *PetReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&zoov1alpha1.Pet{}).
		Owns(&corev1.Pod{}).
		Owns(&corev1.ConfigMap{}).
		Complete(r)
}
EOF
```

::image-box
---
:src: __static__/reconcile-loop.png
:alt: 'What triggers a reconcile: Pet events, events on owned Pods and ConfigMaps, RequeueAfter timers, and the controller start all add a name to the work queue, and Reconcile observes, computes, acts, and reports.'
---
::

A few things are worth pointing out:

- `Reconcile` receives only the namespace and name of a Pet.
  It doesn't get the event, the diff, or the old object.
  Just like the bash loop, it reads the current state and brings the cluster in line with it.
- The mood of a pet isn't stored anywhere.
  Nothing in the cluster changes when time passes, so every run calculates the mood from `lastFedAt` and the current time.
- `RequeueAfter` tells controller-runtime to call `Reconcile` again after the given delay, which is the time left until the mood changes.
  The controller doesn't poll, and your code doesn't manage any timers. The work queue handles that.
- The controller updates the ConfigMap, but it never updates the Pod.
  Everything that can change is in the pet's "card", a ConfigMap that the Pod mounts.
  This solves the bash controller's problem with the stale species.
  `CreateOrUpdate` reads the ConfigMap and applies your function to it. If the ConfigMap didn't exist, it creates it. Otherwise, it sends an update only if the function changed something.
- The controller never uses or deletes objects it doesn't own.
  If a Pod named `mochi` exists but isn't controlled by the Pet, the controller reports `PodNameTaken` in the Pet's `AtHome` condition and checks again every 10 seconds.
- `SetControllerReference` adds an owner reference with `controller: true` that points to the Pet. The controller sets it on both the Pod and the ConfigMap. We'll see what it's for at the end of the tutorial.
- `Owns(&corev1.Pod{})` makes controller-runtime reconcile the owner Pet whenever one of its Pods changes or is deleted. The same applies to ConfigMaps.
- `Recorder.Eventf` records Kubernetes events, which show up in `kubectl describe pet`.

### Starting the manager (main.go)

```sh
cat > main.go <<'EOF'
package main

import (
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	zoov1alpha1 "example.com/pet-operator/api/v1alpha1"
	"example.com/pet-operator/internal/controller"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	setupLog := ctrl.Log.WithName("setup")

	// The scheme maps Go types to API kinds: the built-in ones plus our Pet.
	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(zoov1alpha1.AddToScheme(scheme))

	// The manager owns the shared informer cache, the clients, and the controllers' lifecycle.
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:  scheme,
		Metrics: metricsserver.Options{BindAddress: "0"},
	})
	if err != nil {
		setupLog.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err := (&controller.PetReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorder("pet-operator"),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to set up controller")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "manager exited with an error")
		os.Exit(1)
	}
}
EOF
```

The **manager** maintains a shared cache of the watched objects.
The cache is backed by informers, which make one LIST request at startup and then keep a WATCH connection open.
The `r.Get` calls in the reconciler read from this local cache, not from the API server.
This is how a controller stays cheap with thousands of objects, and it solves the bash controller's polling problem.

### Running the controller

In production, operators run inside the cluster.
During development, it's faster to run them locally with your kubeconfig, which is what `make run` does in Kubebuilder projects:

```sh
go mod tidy
go build -o pet-operator . && ./pet-operator
```

The first build takes a couple of minutes, because it compiles client-go and controller-runtime.
Keep the operator running, and use the other terminal tab for the rest of the tutorial.

A pet gets hungry `feedEvery` (10 minutes by default) after its last feeding, or after its creation if it was never fed.
It runs away after three times that.
`mochi` was created in the first section and has never been fed.
Depending on how long ago that was, it's happy, hungry, or gone:

```sh
kubectl get pets,pods -n zoo
```

A pet is fed by setting `spec.lastFedAt` to the current time.
Add a small helper function to your shell:

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

Check what the operator created, who owns it, and what the operator reported:

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

Once the Pod is running, read its logs:

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

## Watching the reconcile loop at work

Keep the operator logs visible in one tab, and run the following experiments in the other one.

### Reacting to the passage of time (RequeueAfter)

Waiting ten minutes for a pet to get hungry is too long for a tutorial.
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
Each reconcile returned a `RequeueAfter` equal to the time left until the next mood change, so controller-runtime called `Reconcile` again when the mood was due to change.

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
mochi ran away. Nobody changed the Pet's spec, and the controller still noticed, because it scheduled its own next reconcile.
::

Check the events that the operator recorded, and feed `mochi` to bring it back:

```sh
kubectl describe pet -n zoo mochi | tail -n 8
feed mochi
kubectl get pets,pods -n zoo
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

Set `feedEvery` back to ten minutes, so that `mochi` doesn't run away during the next experiments:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"diet":{"feedEvery":"10m"}}}'
feed mochi
```

### Recreating deleted Pods

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

### Reverting manual changes

Change the pet's card without going through the Pet:

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

The change is already reverted.
The ConfigMap update triggered a watch event, controller-runtime queued the owner Pet, and the reconcile wrote the correct card back.

### Acknowledging spec changes (observedGeneration)

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

### Catching up after a restart

Stop the operator with `Ctrl+C`.
While it's stopped, change the spec:

```sh
kubectl patch pet -n zoo mochi --type=merge -p '{"spec":{"toy":"cardboard box"}}'
kubectl get configmap -n zoo mochi-card -o jsonpath='{.data.card}'   # still the laser pointer
```

Start the operator again with `./pet-operator`, and check the card once more:

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

::details-box
---
:summary: What does "the object has been modified; please apply your changes to the latest version" mean?
---
Sooner or later, you'll see this `Reconciler error` in the operator logs.
It's caused by **optimistic concurrency**: the controller tried to update the status of an object that had changed since the controller read it.
The API server rejects the update, and controller-runtime puts the request back into the queue with a backoff.
A later reconcile reads the new version of the object and succeeds.
The error is expected and harmless.
Don't retry the update with the same object you already read.
::

### Cleaning up after deleted Pets (owner references)

Remember the `goldie` Pod that the bash controller left behind?
Create a second Pet:

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

Once the checkpoint above completes, delete the Pet.
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

## Summarizing

An operator is a CRD and a controller.
The CRD defines the API, and the API server uses it to validate objects and fill in defaults.
The controller runs a reconcile loop that receives only an object name, reads the current state, and changes the cluster to match the spec.
Because the loop is level-triggered, the controller handles deleted Pods, manual changes, and its own restarts in the same way.

The Pet operator uses the same building blocks as real operators.
It reports progress with a status subresource, `observedGeneration`, conditions, and events.
It acts on time-based conditions with `RequeueAfter` instead of polling, reads from the manager's informer cache, and watches its child objects with `Owns()`.
It keeps everything that changes in a ConfigMap, because most of a Pod's spec can't be updated, and it sets owner references so that the garbage collector can clean up.

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
