---
kind: tutorial

title: "How Kubernetes CRDs Work: Designing a Validated API From Scratch"

description: |
  Build a CustomResourceDefinition for a small Pet API one layer at a time, and see how much the API server does with it on its own.
  By the end, it rejects invalid Pets, fills in defaults, keeps status separate, and prints useful columns. No controller and no code needed.

categories:
- kubernetes

tagz:
- crd
- custom-resources
- cel
- kube-apiserver

createdAt: 2026-09-26
updatedAt: 2026-09-30

cover: __static__/crd-overview.png

playground:
  name: k8s-omni
  startupFiles:
  - path: /home/laborant/pet-crd
    source: __static__/pet-crd.tar.gz
    extract: true
    owner: laborant
    machines: [dev-machine]
  - path: /home/laborant/pets
    source: __static__/pets.tar.gz
    extract: true
    owner: laborant
    machines: [dev-machine]
  - path: /home/laborant/pet-api.md
    source: __static__/pet-api.txt   # .txt: Labs parses any .md in __static__ as content
    owner: laborant
    mode: "644"
    machines: [dev-machine]

tasks:
  init_scenario:
    init: true
    machine: dev-machine
    user: laborant
    timeout_seconds: 900
    run: |
      set -euo pipefail
      # The spec (~/pet-api.md), the Pet manifests (~/pets) and the CRD versions
      # (~/pet-crd) arrive as startupFiles. This task waits for the cluster.
      for i in $(seq 1 400); do
        kubectl get --raw /readyz >/dev/null 2>&1 && break
        sleep 2
      done
      kubectl get --raw /readyz >/dev/null
      kubectl get namespace zoo >/dev/null 2>&1 || kubectl create namespace zoo

  verify_crd_registered:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    run: |
      CRD=pets.zoo.example.com
      get() { kubectl get crd "$CRD" -o jsonpath="$1" 2>/dev/null; }

      [ "$(get '{.status.conditions[?(@.type=="Established")].status}')" = "True" ] || exit 1
      [ "$(get '{.spec.group}')" = "zoo.example.com" ] || exit 1
      [ "$(get '{.spec.names.kind}')" = "Pet" ] || exit 1
      [ "$(get '{.spec.names.singular}')" = "pet" ] || exit 1
      [ "$(get '{.spec.scope}')" = "Namespaced" ] || exit 1
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].served}')" = "true" ] || exit 1
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].storage}')" = "true" ] || exit 1
    hintcheck: |
      CRD=pets.zoo.example.com
      get() { kubectl get crd "$CRD" -o jsonpath="$1" 2>/dev/null; }

      if ! kubectl get crd "$CRD" >/dev/null 2>&1; then
        echo "There is no CRD named $CRD yet. A CRD's name must be <plural>.<group>."
        exit 0
      fi
      [ "$(get '{.status.conditions[?(@.type=="Established")].status}')" = "True" ] \
        || echo "The CRD exists but is not Established. Check its status conditions: kubectl describe crd $CRD"
      [ "$(get '{.spec.names.kind}')" = "Pet" ] || echo "The kind should be Pet."
      [ "$(get '{.spec.names.singular}')" = "pet" ] || echo "The singular name should be pet."
      [ "$(get '{.spec.scope}')" = "Namespaced" ] || echo "Pets live in namespaces. Check the CRD scope."
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].served}')" = "true" ] || echo "Version v1alpha1 must be served."
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].storage}')" = "true" ] || echo "Version v1alpha1 must be the storage version."
      exit 0

  verify_crd_discoverable:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_crd_registered
    run: |
      kubectl api-resources --api-group=zoo.example.com -o wide 2>/dev/null | grep -qw pt || exit 1
      kubectl get pt -n zoo >/dev/null 2>&1 || exit 1
      kubectl get zoo -n zoo >/dev/null 2>&1 || exit 1
    hintcheck: |
      CRD=pets.zoo.example.com
      kubectl get crd "$CRD" -o jsonpath='{.spec.names.shortNames}' 2>/dev/null | grep -qw pt \
        || echo "'kubectl get pt' doesn't work yet. Which field under spec.names holds short aliases?"
      kubectl get crd "$CRD" -o jsonpath='{.spec.names.categories}' 2>/dev/null | grep -qw zoo \
        || echo "'kubectl get zoo' doesn't list Pets yet. Which field under spec.names groups resources, like 'all' does?"
      exit 0

  verify_schema_accepts_valid:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_crd_registered
    run: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1
      }
      GOOD=(
        '{"species":"cat"}'
        '{"species":"dog","toy":"stick","diet":{"food":"bones","feedEvery":"30m"}}'
        '{"species":"dragon","diet":{"feedEvery":"1h"}}'
        '{"species":"dragon","diet":{"food":"sheep","feedEvery":"90m"}}'
        '{"species":"cactus","diet":{"food":"water","feedEvery":"168h"}}'
        '{"species":"cat","toy":"12345678901234567890","diet":{"feedEvery":"45s"}}'
        '{"species":"cat","lastFedAt":"2026-09-26T10:00:00Z"}'
        '{"species":"cactus","diet":{"feedEvery":"8760h"}}'
        '{"species":"cat","diet":{"feedEvery":"1s"}}'
      )
      for spec in "${GOOD[@]}"; do try "$spec" || exit 1; done
      # A schema-less CRD accepts everything, so also require one rejection.
      try '{"species":"cat","toy":42}' && exit 1
      exit 0
    hintcheck: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - 2>&1 >/dev/null
      }
      GOOD=(
        '{"species":"cat"}'
        '{"species":"dog","toy":"stick","diet":{"food":"bones","feedEvery":"30m"}}'
        '{"species":"dragon","diet":{"feedEvery":"1h"}}'
        '{"species":"dragon","diet":{"food":"sheep","feedEvery":"90m"}}'
        '{"species":"cactus","diet":{"food":"water","feedEvery":"168h"}}'
        '{"species":"cat","toy":"12345678901234567890","diet":{"feedEvery":"45s"}}'
        '{"species":"cat","lastFedAt":"2026-09-26T10:00:00Z"}'
        '{"species":"cactus","diet":{"feedEvery":"8760h"}}'
        '{"species":"cat","diet":{"feedEvery":"1s"}}'
      )
      if [ -z "$(try '{"species":"cat","toy":42}')" ]; then
        echo "The API server still accepts anything, even a toy that is a number. Apply ~/pet-crd/2-schema.yaml to give Pets a schema."
        exit 0
      fi
      for spec in "${GOOD[@]}"; do
        if err=$(try "$spec") && [ -z "$err" ]; then continue; fi
        echo "A valid Pet was turned away. spec: $spec"
        echo "API server said: $err"
        break
      done
      exit 0

  verify_schema_rejects_invalid:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_schema_accepts_valid
    run: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1
      }
      BAD=(
        '{}'
        '{"species":"unicorn"}'
        '{"species":"Cat"}'
        '{"species":"cat","toy":"123456789012345678901"}'
        '{"species":"cat","toy":42}'
        '{"species":"cat","diet":{"feedEvery":"whenever"}}'
        '{"species":"cat","diet":{"feedEvery":"10 minutes"}}'
        '{"species":"cat","diet":{"feedEvery":"2d"}}'
        '{"species":"cat","diet":{"feedEvery":10}}'
        '{"species":"cat","diet":{"food":"a very long list of snacks"}}'
        '{"species":"cat","lastFedAt":"yesterday"}'
        '{"species":"cat","diet":{"feedEvery":"0s"}}'
        '{"species":"cat","diet":{"feedEvery":"8761h"}}'
        '{"species":"cat","diet":{"feedEvery":"9999999h"}}'
        '{"species":"cat","diet":{"feedEvery":"00000000001h"}}'
      )
      try '{"species":"cat"}' || exit 1
      for spec in "${BAD[@]}"; do try "$spec" && exit 1; done
      exit 0
    hintcheck: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1
      }
      BAD=(
        'spec.species is missing|{}'
        'spec.species is "unicorn"|{"species":"unicorn"}'
        'spec.species is "Cat" (with a capital C)|{"species":"Cat"}'
        'spec.toy is 21 characters long|{"species":"cat","toy":"123456789012345678901"}'
        'spec.toy is the number 42|{"species":"cat","toy":42}'
        'spec.diet.feedEvery is "whenever"|{"species":"cat","diet":{"feedEvery":"whenever"}}'
        'spec.diet.feedEvery is "10 minutes"|{"species":"cat","diet":{"feedEvery":"10 minutes"}}'
        'spec.diet.feedEvery is "2d" (days are not an allowed unit)|{"species":"cat","diet":{"feedEvery":"2d"}}'
        'spec.diet.feedEvery is the number 10|{"species":"cat","diet":{"feedEvery":10}}'
        'spec.diet.food is 26 characters long|{"species":"cat","diet":{"food":"a very long list of snacks"}}'
        'spec.lastFedAt is "yesterday"|{"species":"cat","lastFedAt":"yesterday"}'
        'spec.diet.feedEvery is "0s" (not a valid feeding interval)|{"species":"cat","diet":{"feedEvery":"0s"}}'
        'spec.diet.feedEvery is "8761h", just over a year|{"species":"cat","diet":{"feedEvery":"8761h"}}'
        'spec.diet.feedEvery is "9999999h", too big for a Go time.Duration|{"species":"cat","diet":{"feedEvery":"9999999h"}}'
        'spec.diet.feedEvery is "00000000001h", 12 characters long|{"species":"cat","diet":{"feedEvery":"00000000001h"}}'
      )
      for c in "${BAD[@]}"; do
        if try "${c#*|}"; then
          echo "The API server accepted a Pet where ${c%%|*}. The specification says it must be rejected."
          break
        fi
      done
      exit 0

  verify_house_rules:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_schema_accepts_valid
    run: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - 2>&1
      }
      try '{"species":"dragon","diet":{"feedEvery":"1h"}}' >/dev/null || exit 1
      try '{"species":"cactus"}' >/dev/null || exit 1
      out=$(try '{"species":"cactus","toy":"ball"}') && exit 1
      echo "$out" | grep -qi "toy" || exit 1
      out=$(try '{"species":"dragon","diet":{"feedEvery":"59m"}}') && exit 1
      echo "$out" | grep -qi "hour" || exit 1
      out=$(try '{"species":"dragon","diet":{"feedEvery":"3599s"}}') && exit 1
      out=$(try '{"species":"dragon"}') && exit 1
      kubectl get crd pets.zoo.example.com -o yaml 2>/dev/null | grep -q "x-kubernetes-validations" || exit 1
    hintcheck: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - 2>&1
      }
      kubectl get crd pets.zoo.example.com >/dev/null 2>&1 || exit 0
      if out=$(try '{"species":"cactus","toy":"ball"}'); then
        echo "A cactus with a toy is still accepted."
        echo "'This field is forbidden only if another field has a certain value' is awkward to say in OpenAPI. What else can the API server evaluate?"
      elif ! echo "$out" | grep -qi toy; then
        echo "A cactus with a toy is rejected, but the error message should mention the toy."
      elif try '{"species":"dragon","diet":{"feedEvery":"59m"}}' >/dev/null; then
        echo "A dragon that eats every 59 minutes is still accepted."
        echo "Comparing '59m' and '1h' as strings won't work. CEL can turn a string into a duration."
      elif try '{"species":"dragon","diet":{"feedEvery":"3599s"}}' >/dev/null; then
        echo "A dragon that eats every 3599s is still accepted. That's less than an hour."
      elif try '{"species":"dragon"}' >/dev/null; then
        echo "A dragon with no diet block is accepted. What does its diet.feedEvery default to?"
      elif ! try '{"species":"dragon","diet":{"feedEvery":"1h"}}' >/dev/null; then
        echo "A dragon that eats exactly once an hour is rejected, but 'at least 1h' includes 1h."
      else
        echo "The dragon is rejected, but the error message should say dragons eat at most once an hour."
      fi
      exit 0

  verify_defaults:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_schema_accepts_valid
    run: |
      try() {
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -f - -o jsonpath='{.spec.diet.food}/{.spec.diet.feedEvery}' 2>/dev/null
      }
      [ "$(try '{"species":"cat"}')" = "snacks/10m" ] || exit 1
      [ "$(try '{"species":"cat","diet":{"food":"fish"}}')" = "fish/10m" ] || exit 1
      [ "$(try '{"species":"cat","diet":{"feedEvery":"5m"}}')" = "snacks/5m" ] || exit 1
    hintcheck: |
      got=$(printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"species":"cat"}}' \
        | kubectl create --dry-run=server -f - -o jsonpath='{.spec.diet.food}|{.spec.diet.feedEvery}' 2>/dev/null)
      IFS='|' read -r food every <<< "$got"
      if [ -z "$food$every" ]; then
        echo "A Pet with no diet block comes back with no diet at all."
        echo "A default on a nested field applies only if its parent object exists."
      elif [ "$food" != "snacks" ] || [ "$every" != "10m" ]; then
        [ "$food" = "snacks" ] || echo "A Pet without a diet should get diet.food: snacks, but got '${food}'."
        [ "$every" = "10m" ] || echo "A Pet without a diet should get diet.feedEvery: 10m, but got '${every}'."
      else
        part=$(printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"species":"cat","diet":{"food":"fish"}}}' \
          | kubectl create --dry-run=server -f - -o jsonpath='{.spec.diet.feedEvery}' 2>/dev/null)
        if [ "$part" != "10m" ]; then
          echo "A Pet with diet: {food: fish} comes back without feedEvery."
          echo "A default on diet itself only applies when diet is missing. Each field needs its own default too."
        fi
      fi
      exit 0

  verify_status_subresource:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_schema_accepts_valid
    run: |
      CRD=pets.zoo.example.com
      [ -n "$(kubectl get crd "$CRD" -o jsonpath='{.spec.versions[?(@.name=="v1alpha1")].subresources.status}' 2>/dev/null)" ] || exit 1
      # With the status subresource on, whatever a client sends in .status on create is dropped.
      got=$(printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"species":"cat"},"status":{"mood":"Happy","face":"😺"}}' \
        | kubectl create --dry-run=server -f - -o jsonpath='{.status}' 2>/dev/null) || exit 1
      [ -z "$got" ] || exit 1
    hintcheck: |
      CRD=pets.zoo.example.com
      if [ -z "$(kubectl get crd "$CRD" -o jsonpath='{.spec.versions[?(@.name=="v1alpha1")].subresources.status}' 2>/dev/null)" ]; then
        echo "Users can still write .status directly. How do you give a CRD version a separate /status endpoint?"
      elif ! printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"species":"cat"},"status":{"mood":"Happy","face":"😺"}}' \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1; then
        echo "The status subresource is on, but the schema doesn't describe .status.mood and .status.face yet."
      fi
      exit 0

  verify_printer_columns:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_crd_registered
    run: |
      cols=$(kubectl get crd pets.zoo.example.com \
        -o jsonpath='{range .spec.versions[?(@.name=="v1alpha1")].additionalPrinterColumns[*]}{.name}={.jsonPath}{"\n"}{end}' 2>/dev/null \
        | tr '[:upper:]' '[:lower:]')
      for want in \
        "species=.spec.species" \
        "face=.status.face" \
        "mood=.status.mood" \
        "toy=.spec.toy" \
        "last fed=.spec.lastfedat" \
        "age=.metadata.creationtimestamp"; do
        echo "$cols" | grep -qxF "$want" || exit 1
      done
    hintcheck: |
      cols=$(kubectl get crd pets.zoo.example.com \
        -o jsonpath='{range .spec.versions[?(@.name=="v1alpha1")].additionalPrinterColumns[*]}{.name}={.jsonPath}{"\n"}{end}' 2>/dev/null \
        | tr '[:upper:]' '[:lower:]')
      for want in \
        "species=.spec.species" \
        "face=.status.face" \
        "mood=.status.mood" \
        "toy=.spec.toy" \
        "last fed=.spec.lastfedat" \
        "age=.metadata.creationtimestamp"; do
        if ! echo "$cols" | grep -qxF "$want"; then
          echo "The '${want%%=*}' column is missing or points at the wrong field."
          [ "${want%%=*}" = "age" ] && echo "Once you define custom columns, AGE isn't added for you anymore."
          break
        fi
      done
      exit 0

  verify_pets_adopted:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_schema_rejects_invalid
    - verify_house_rules
    - verify_defaults
    run: |
      q() { kubectl get pet -n zoo "$1" -o jsonpath="$2" 2>/dev/null; }
      [ "$(q mochi '{.spec.species}/{.spec.toy}/{.spec.diet.food}/{.spec.diet.feedEvery}')" = "cat/yarn/snacks/10m" ] || exit 1
      [ "$(q rex '{.spec.species}/{.spec.toy}/{.spec.diet.food}/{.spec.diet.feedEvery}')" = "dog/stick/bones/30m" ] || exit 1
      [ "$(q smaug '{.spec.species}/{.spec.diet.food}/{.spec.diet.feedEvery}')" = "dragon/sheep/6h" ] || exit 1
      [ "$(q prickles '{.spec.species}/{.spec.diet.food}/{.spec.diet.feedEvery}')" = "cactus/water/168h" ] || exit 1
      [ "$(kubectl get pets -n zoo -o name 2>/dev/null | wc -l)" -eq 4 ] || exit 1
      # The CRD that let them in must still enforce the rules.
      for bad in '{"species":"unicorn"}' '{"species":"cactus","toy":"ball"}' '{"species":"dragon","diet":{"feedEvery":"59m"}}'; do
        printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$bad" \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1 && exit 1
      done
      exit 0
    hintcheck: |
      n=$(kubectl get pets -n zoo -o name 2>/dev/null | wc -l)
      if [ "$n" -gt 4 ]; then
        echo "There are $n Pets in the zoo namespace, but only the four from ~/pets/adopted/ belong there."
      else
        for name in mochi rex smaug prickles; do
          kubectl get pet -n zoo "$name" >/dev/null 2>&1 || { echo "Pet zoo/$name doesn't exist yet."; exit 0; }
        done
        echo "All four Pets are in, but the CRD no longer turns away a unicorn, a cactus with a toy, or a dragon that eats every 59m. Did a later edit drop a rule?"
      fi
      exit 0

  verify_status_reported:
    machine: dev-machine
    user: laborant
    timeout_seconds: 60
    needs:
    - verify_pets_adopted
    - verify_status_subresource
    - verify_printer_columns
    run: |
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}/{.status.face}' 2>/dev/null)" = "Happy/😺" ] || exit 1
      [ "$(kubectl get pet -n zoo mochi -o jsonpath='{.metadata.generation}' 2>/dev/null)" = "1" ] || exit 1
    hintcheck: |
      got=$(kubectl get pet -n zoo mochi -o jsonpath='{.status.mood}/{.status.face}' 2>/dev/null)
      gen=$(kubectl get pet -n zoo mochi -o jsonpath='{.metadata.generation}' 2>/dev/null)
      if [ -n "$gen" ] && [ "$gen" != "1" ]; then
        echo "mochi's spec has been changed since it was created (generation $gen). Delete and re-apply it from ~/pets/adopted/, then write only its status."
      elif [ "$got" = "/" ]; then
        echo "mochi has no status yet. A plain 'kubectl apply' or 'kubectl edit' won't write it. Which kubectl flag targets a subresource?"
        echo "If you already used it, check that the CRD schema still describes .status.mood and .status.face. The API server drops fields that the schema doesn't describe."
      else
        echo "mochi's status is '$got', expected mood Happy and face 😺."
      fi
      exit 0
---

Welcome wanderer!

If you've landed on this tutorial, you've probably seen CRDs come along with an operator you installed,
or you're about to write your own and want to know what the API server actually does with one.

By the end of this tutorial, you will have a CustomResourceDefinition (CRD) for a small `Pet` API that the API server enforces on its own.
It will reject invalid Pets with clear errors, fill in the fields you leave out, keep the status separate from the spec, and show useful columns in `kubectl get`.
There's no controller and no code involved, only YAML and `kubectl`.

Here's the whole picture of what you'll end up with:

::image-box
---
:src: __static__/crd-overview.png
:alt: 'The finished Pet API: the manifests in ~/pets/adopted go through kube-apiserver, which checks them against the Pet CRD (names, schema, CEL rules, defaults, status, printer columns) and stores them in etcd with the defaults filled in. The manifests in ~/pets/turned-away are rejected with a clear error. kubectl get pets shows the stored Pets in custom columns.'
---
::

I went with pets because the API is small enough to keep in your head.
It still has a couple of rules that are hard to express in a schema, and those rules show what CRD validation can do.

We'll build the CRD one layer at a time.
All five versions of it are already in the `~/pet-crd` folder of the playground, so you don't have to type any YAML.
In the tutorial, I'll show only what's new in each version, and you can open the full files in the IDE tab.
After every change, we'll send the same set of valid and invalid Pets to the API server and see which ones get in.

## Prerequisites

All you need is basic `kubectl` knowledge.
If you've never written a CRD before, don't worry, we'll build this one from scratch.

The playground already has a multi-node Kubernetes cluster, and `kubectl` on the `dev-machine` is set up to talk to it.
The checkpoints along the way turn green on their own once the cluster is in the right state, so there's nothing to click.

## Meeting the Pet API

To begin with, let's look at what we're building. The specification is waiting in your home directory:

```sh
cat ~/pet-api.md
```

A Pet has a required `species`, an optional `toy`, an optional `diet` with a default value, and a `lastFedAt` timestamp.
Two rules involve more than one field: a cactus can't have a toy, and a dragon can't be fed more often than once an hour.
The `status` section is for a controller that doesn't exist yet, so we'll leave it alone until the end.

There are also two folders of Pet manifests in `~/pets`.
The ones in `adopted/` follow the specification, and the ones in `turned-away/` each break it in a different way:

```sh
ls ~/pets/adopted ~/pets/turned-away
```

```text
/home/laborant/pets/adopted:
mochi.yaml
prickles.yaml
rex.yaml
smaug.yaml

/home/laborant/pets/turned-away:
lazy-dragon.yaml
snacky-dragon.yaml
sparkles.yaml
spiky-ball.yaml
whenever.yaml
```

By the end, the API server should accept every Pet in `adopted/` and reject every Pet in `turned-away/`.
Let's see where we stand. Right now, `kubectl` can't even send them, because the API server has never heard of a `Pet`:

```sh
kubectl apply --dry-run=server -f ~/pets/adopted/mochi.yaml
```

```text
error: resource mapping not found for name: "mochi" namespace: "zoo" from "/home/laborant/pets/adopted/mochi.yaml": no matches for kind "Pet" in version "zoo.example.com/v1alpha1"
ensure CRDs are installed first
```

::remark-box
---
kind: info
---
Whenever we only want to test the API, we'll use `--dry-run=server`.
The request goes through the full API server pipeline, including defaulting and validation, but nothing is written to etcd, so you can try as many invalid Pets as you like.
::

## Registering the Pet resource

Let's start with the smallest CRD that works.
It tells the API server what the new resource is called, which versions it has, and whether it lives in a namespace.
Every version also needs a schema.
For now, we'll use one that accepts anything (`x-kubernetes-preserve-unknown-fields: true`) and tighten it in the next step.
This first version is short, so here it is in full:

```yaml [~/pet-crd/1-names.yaml]
{{file:pet-crd/1-names.yaml|strip-comments}}
```

Here's where each of these fields shows up.
One thing to keep in mind: the CRD itself must be named `<plural>.<group>`.

| Field | Value | Where it shows up |
|-------|-------|-------------------|
| `group` and `versions[].name` | `zoo.example.com`, `v1alpha1` | The `apiVersion` of every Pet manifest |
| `names.kind` | `Pet` | The `kind` of every Pet manifest |
| `names.plural`, `names.singular` | `pets`, `pet` | The URL path (`/apis/zoo.example.com/v1alpha1/namespaces/zoo/pets`) and `kubectl get pet(s)` |
| `names.shortNames` | `pt` | `kubectl get pt` |
| `names.categories` | `zoo` | `kubectl get zoo`, similar to how `kubectl get all` works |
| `scope` | `Namespaced` | Pets live in namespaces, like Pods |

Apply it:

```sh
kubectl apply -f ~/pet-crd/1-names.yaml
kubectl wait --for=condition=Established crd/pets.zoo.example.com
```

If everything goes well, you should see the new resource right away. You don't need to restart anything:

```sh
kubectl api-resources --api-group=zoo.example.com
```

```text
NAME   SHORTNAMES   APIVERSION                 NAMESPACED   KIND
pets   pt           zoo.example.com/v1alpha1   true         Pet
```

The short name and the category work, too:

```sh
kubectl get pt -n zoo
kubectl get zoo -n zoo
```

```text
No resources found in zoo namespace.
No resources found in zoo namespace.
```

::simple-task
---
:tasks: tasks
:name: verify_crd_registered
---
#active
Waiting for the `pets.zoo.example.com` CRD to be registered and established...

#completed
The `pets.zoo.example.com` CRD is established, and the API server serves the `Pet` resource.
::

::simple-task
---
:tasks: tasks
:name: verify_crd_discoverable
---
#active
Waiting for Pets to be listed by `kubectl get pt` and `kubectl get zoo`...

#completed
Pets are available through the `pt` short name and the `zoo` category.
::

Now, let's try the Pets that should be rejected:

```sh
kubectl apply --dry-run=server -f ~/pets/turned-away/
```

```text
pet.zoo.example.com/lazy-dragon created (server dry run)
pet.zoo.example.com/snacky-dragon created (server dry run)
pet.zoo.example.com/sparkles created (server dry run)
pet.zoo.example.com/spiky-ball created (server dry run)
pet.zoo.example.com/whenever created (server dry run)
```

All five would get in, including a unicorn (`sparkles`).
That's expected. With `x-kubernetes-preserve-unknown-fields: true`, the API server stores whatever it receives, so nothing is validated yet.
Let's fix that.

## Adding a schema

Now that the Pet has a name, let's describe its fields.
A CRD schema is written in OpenAPI v3.
Kubernetes requires it to be **structural**.
Every field must have a `type`, and the fields of an object must be listed under `properties`, unless the schema explicitly allows unknown fields, as the first version did.
The second version replaces the "accept anything" schema with a real one. Here's the new part:

```yaml [~/pet-crd/2-schema.yaml]
{{excerpt:pet-crd/2-schema.yaml#from=^          spec:#to=format: date-time}}
```

Most lines of the specification map to a single schema keyword:

| The specification says | Schema keyword |
|------------------------|----------------|
| `species` is required | `required: [species]` on `spec` |
| One of cat, dog, dragon, cactus | `enum` |
| At most 20 characters | `maxLength` |
| A number followed by s, m or h | `pattern` |
| `lastFedAt` is a date-time | `format: date-time` |

::remark-box
---
kind: tip
---
To see every change between two versions, run `diff ~/pet-crd/1-names.yaml ~/pet-crd/2-schema.yaml`.
::

Apply it:

```sh
kubectl apply -f ~/pet-crd/2-schema.yaml
```

::simple-task
---
:tasks: tasks
:name: verify_schema_accepts_valid
---
#active
Sending valid Pets to the API server (server-side dry run)...

#completed
The API server accepts all valid Pets.
::

The adopted Pets would still get in:

```sh
kubectl apply --dry-run=server -f ~/pets/adopted/
```

```text
pet.zoo.example.com/mochi created (server dry run)
pet.zoo.example.com/prickles created (server dry run)
pet.zoo.example.com/rex created (server dry run)
pet.zoo.example.com/smaug created (server dry run)
```

And two of the five turned-away Pets are rejected now:

```sh
kubectl apply --dry-run=server -f ~/pets/turned-away/
```

```text
pet.zoo.example.com/lazy-dragon created (server dry run)
pet.zoo.example.com/snacky-dragon created (server dry run)
pet.zoo.example.com/spiky-ball created (server dry run)
Error from server (Invalid): error when creating "/home/laborant/pets/turned-away/sparkles.yaml": Pet.zoo.example.com "sparkles" is invalid: spec.species: Unsupported value: "unicorn": supported values: "cat", "dog", "dragon", "cactus"
Error from server (Invalid): error when creating "/home/laborant/pets/turned-away/whenever.yaml": Pet.zoo.example.com "whenever" is invalid: spec.diet.feedEvery: Invalid value: "whenever": spec.diet.feedEvery in body should match '^[0-9]+(s|m|h)$'
```

The other three would still get in, because they break rules that are hard or impossible to express with OpenAPI keywords alone:

- `spiky-ball` is a cactus with a toy. A `toy` is valid on its own, and only invalid in combination with `species: cactus`.
- `snacky-dragon` wants to be fed every `15m`. The value matches the pattern, but dragons must wait at least an hour.
- `lazy-dragon` has no `diet` at all. We'll come back to this one later.

The `pattern` keyword has another catch.
It only checks what a string looks like, not the value behind it.
`^[0-9]+(s|m|h)$` accepts `0s`, which is not a valid feeding interval,
and `9999999h`, which doesn't fit into Go's `time.Duration`, the type a controller would parse this field into.

::details-box
---
:summary: What happens to fields that the schema doesn't mention?
---
Try creating a Pet with a `favoriteColor` field:

```sh
kubectl create --dry-run=server -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata: {name: picky, namespace: zoo}
spec: {species: cat, favoriteColor: blue}
EOF
```

```text
Error from server (BadRequest): error when creating "STDIN": Pet in version "v1alpha1" cannot be handled as a Pet: strict decoding error: unknown field "spec.favoriteColor"
```

`kubectl` asks the API server for strict field validation, so the request fails.
Clients that don't ask for it get the unknown fields **pruned** instead, with a warning in the response.
Either way, fields that the schema doesn't describe never reach etcd.
::

## Adding validation rules with CEL

OpenAPI can't express these rules, but the
[Common Expression Language (CEL)](https://kubernetes.io/docs/reference/using-api/cel/) can.
You add CEL rules to the `x-kubernetes-validations` list at any level of the schema.
There, `self` is the value at that level.
The API server checks the rules on create and update requests, before it stores the object.

For our Pets, we need three rules:

- **Cacti don't play with toys.** The rule needs both `species` and `toy`, so it goes on `spec`, where `self` has access to both fields:
  `self.species != 'cactus' || !has(self.toy)`.
  A rule placed on `toy` would only run when a toy is present, and it couldn't read the species.
- **Dragons eat at most once an hour.** This rule also goes on `spec`.
  It must compare durations, not strings. As strings, `'59m' >= '1h'` is `true`, because `5` sorts after `1`.
  CEL's built-in `duration()` function fixes this: `duration('59m') >= duration('1h')` is `false`.
- **`feedEvery` is between 1s and a year.** This rule only needs the field itself, so it goes on `feedEvery`.

Here are the two rules on `spec`:

```yaml [~/pet-crd/3-rules.yaml]
{{excerpt:pet-crd/3-rules.yaml#from=^            x-kubernetes-validations:#to=message: "dragons eat}}
```

And the range rule on `feedEvery`:

```yaml [~/pet-crd/3-rules.yaml]
{{excerpt:pet-crd/3-rules.yaml#from=^                  feedEvery:#to=message: "feedEvery must be}}
```

Apply the third version:

```sh
kubectl apply -f ~/pet-crd/3-rules.yaml
```

Now all five turned-away Pets are rejected:

```sh
kubectl apply --dry-run=server -f ~/pets/turned-away/
```

```text
Error from server (Invalid): error when creating "/home/laborant/pets/turned-away/lazy-dragon.yaml": Pet.zoo.example.com "lazy-dragon" is invalid: spec: Invalid value: "object": no such key: diet evaluating rule: dragons eat at most once an hour: diet.feedEvery must be at least 1h
Error from server (Invalid): error when creating "/home/laborant/pets/turned-away/snacky-dragon.yaml": Pet.zoo.example.com "snacky-dragon" is invalid: spec: Invalid value: dragons eat at most once an hour: diet.feedEvery must be at least 1h
Error from server (Invalid): error when creating "/home/laborant/pets/turned-away/sparkles.yaml": Pet.zoo.example.com "sparkles" is invalid: [spec.species: Unsupported value: "unicorn": supported values: "cat", "dog", "dragon", "cactus", <nil>: Invalid value: null: some validation rules were not checked because the object was invalid; correct the existing errors to complete validation]
Error from server (Invalid): error when creating "/home/laborant/pets/turned-away/spiky-ball.yaml": Pet.zoo.example.com "spiky-ball" is invalid: spec: Invalid value: cacti don't play with toys
Error from server (Invalid): error when creating "/home/laborant/pets/turned-away/whenever.yaml": Pet.zoo.example.com "whenever" is invalid: [spec.diet.feedEvery: Invalid value: "whenever": spec.diet.feedEvery in body should match '^[0-9]+(s|m|h)$', spec.diet.feedEvery: Invalid value: "string": type conversion error from 'string' to 'google.protobuf.Duration' evaluating rule: feedEvery must be between 1s and 8760h (a year)]
```

Note that the API server doesn't stop at the first error.
The `whenever` Pet fails both the pattern and the duration rule.
Some schema errors do stop the CEL rules, though.
A value outside the `enum`, like `unicorn`, or a field of the wrong type means the CEL rules are skipped, and the error for `sparkles` says so.

::simple-task
---
:tasks: tasks
:name: verify_schema_rejects_invalid
---
#active
Sending invalid Pets to the API server (server-side dry run)...

#completed
The API server rejects every invalid Pet before it reaches etcd.
::

::simple-task
---
:tasks: tasks
:name: verify_house_rules
---
#active
Checking that cacti can't have toys and dragons can't be fed more than once an hour...

#completed
The API server enforces both rules that span several fields.
::

Now, take a closer look at the error for `lazy-dragon`:

```text
spec: Invalid value: "object": no such key: diet evaluating rule: dragons eat at most once an hour ...
```

This Pet has no `diet` block, so the rule failed while trying to read `self.diet.feedEvery`.
The Pet is rejected, but not for the reason we want.
A cat without a `diet` gets in for a lucky reason: for a cat, `self.species != 'dragon'` is `true`,
and when one side of `||` is `true`, CEL ignores an error on the other side.
The specification says that a Pet without a diet eats snacks every 10 minutes, so let's teach the CRD that too.

## Adding defaults

The `default` keyword fills in a field when it's missing.
The API server does this for incoming requests and for objects it reads from etcd.

It's important to know that a default only works if the parent object exists.
A default on `diet.food` does nothing for a Pet without a `diet` block, because there's nowhere to put `food`.
To fix this, we set `default: {}` on `diet` itself.
The API server then adds an empty `diet` first and fills in its fields.

Defaulting also runs before validation.
So the lazy dragon gets `feedEvery: 10m` first, and only then does the API server check the CEL rules.
By the time a rule reads `self.diet.feedEvery`, the field is always there.

::image-box
---
:src: __static__/request-pipeline.png
:alt: 'The path of a Pet through the API server: decoding and pruning, defaulting, mutating webhooks, schema and CEL validation, validating webhooks, and etcd.'
---
::

Here's the `diet` block of the fourth version, with its three defaults:

```yaml [~/pet-crd/4-defaults.yaml]
{{excerpt:pet-crd/4-defaults.yaml#from=^              diet:#to=default: 10m}}
```

Apply it, and try the lazy dragon again:

```sh
kubectl apply -f ~/pet-crd/4-defaults.yaml
kubectl apply --dry-run=server -f ~/pets/turned-away/lazy-dragon.yaml
```

The lazy dragon is still rejected, but this time for the right reason:

```text
The Pet "lazy-dragon" is invalid: spec: Invalid value: dragons eat at most once an hour: diet.feedEvery must be at least 1h
```

To see the defaults in action, create a minimal Pet and print the object that the API server would store:

```sh
kubectl create --dry-run=server -o yaml -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata: {name: minimal, namespace: zoo}
spec: {species: cat}
EOF
```

```text
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata:
  creationTimestamp: "2026-09-28T19:46:35Z"
  generation: 1
  name: minimal
  namespace: zoo
  uid: 9d82f0db-8d20-4950-b6fc-b9dbed9c5d9d
spec:
  diet:
    feedEvery: 10m
    food: snacks
  species: cat
```

::simple-task
---
:tasks: tasks
:name: verify_defaults
---
#active
Creating minimal Pets and checking which defaults the API server fills in...

#completed
The API server fills in `diet.food: snacks` and `diet.feedEvery: 10m` for every client.
::

## Adding a status

A quick clarification before we add a status.
Think of the `spec` as what the pet's owner asks for, and the `status` as the controller's report on what actually happened, such as the pet's mood.
Different clients write these two parts, and the CRD can keep them apart.

Setting `subresources.status: {}` gives Pets a separate `/status` endpoint.
The main endpoint ignores changes to `.status`, and the `/status` endpoint ignores changes to everything else.
On top of that, `metadata.generation` only goes up when the spec changes, so a controller can compare it with the generation it last handled.

The schema must describe `status` too, or the API server prunes its fields in the same way it prunes unknown `spec` fields.
The last version of the CRD adds all of that, plus the printer columns we'll look at next:

```yaml [~/pet-crd/5-status-and-columns.yaml]
{{excerpt:pet-crd/5-status-and-columns.yaml#from=^    subresources:#to=^      status: }}
    ...
{{excerpt:pet-crd/5-status-and-columns.yaml#from=^          status:#to=EOF}}
```

Apply it:

```sh
kubectl apply -f ~/pet-crd/5-status-and-columns.yaml
```

::simple-task
---
:tasks: tasks
:name: verify_status_subresource
---
#active
Waiting for the Pet resource to get a status subresource and a status schema...

#completed
The `.status` field is written only through the `/status` endpoint.
::

## Adding printer columns

The CRD you just applied also has an `additionalPrinterColumns` list:

```yaml [~/pet-crd/5-status-and-columns.yaml]
{{excerpt:pet-crd/5-status-and-columns.yaml#from=^    additionalPrinterColumns:#to=jsonPath: .metadata.creationTimestamp}}
```

Without it, `kubectl get pets` shows only `NAME` and `AGE`.
It's important to know that the API server drops `AGE` once you define your own columns, so I added it back to the list.

::simple-task
---
:tasks: tasks
:name: verify_printer_columns
---
#active
Waiting for the printer columns to be defined...

#completed
`kubectl get pets` shows the species, face, mood, toy, last feeding time, and age of each Pet.
::

Now that the CRD is complete, it's time to let the adopted Pets in for real:

```sh
kubectl apply -f ~/pets/adopted/
kubectl get pets -n zoo
```

```text
NAME       SPECIES   FACE   MOOD   TOY     LAST FED   AGE
mochi      cat                     yarn               0s
prickles   cactus                                     0s
rex        dog                     stick              0s
smaug      dragon                                     0s
```

The stored objects have the default diet filled in:

```sh
kubectl get pet -n zoo mochi -o jsonpath='{.spec.diet}{"\n"}'
```

```text
{"feedEvery":"10m","food":"snacks"}
```

::simple-task
---
:tasks: tasks
:name: verify_pets_adopted
---
#active
Waiting for mochi, rex, smaug and prickles to be created in the `zoo` namespace...

#completed
All four Pets from `~/pets/adopted/` are created, and the CRD still rejects invalid ones.
::

## Writing the status by hand

The `FACE` and `MOOD` columns are empty, because nothing has written a status yet.
Normally, that's the controller's job, but we can do it by hand to see how the status subresource behaves.
First, try the obvious way and patch the status through the main endpoint:

```sh
kubectl patch pet mochi -n zoo --type=merge -p '{"status":{"mood":"Happy","face":"😺"}}'
```

```text
pet.zoo.example.com/mochi patched (no change)
```

`(no change)` means the API server ignored the `.status` part of the patch.
To change the status, send the patch to the `/status` subresource instead:

```sh
kubectl patch pet mochi -n zoo --subresource=status --type=merge \
  -p '{"status":{"mood":"Happy","face":"😺"}}'

kubectl get pets -n zoo
```

```text
NAME       SPECIES   FACE   MOOD    TOY     LAST FED   AGE
mochi      cat       😺      Happy   yarn               0s
prickles   cactus                                      0s
rex        dog                      stick              0s
smaug      dragon                                      0s
```

The status change didn't affect `metadata.generation`, which is still `1`:

```sh
kubectl get pet mochi -n zoo -o jsonpath='{.metadata.generation}{"\n"}'
```

```text
1
```

::simple-task
---
:tasks: tasks
:name: verify_status_reported
---
#active
Waiting for mochi's status to report the `Happy` mood...

#completed
You updated mochi's status through the `/status` subresource, and its generation stayed at `1`.
::

A controller does the same thing in a loop. It reads the spec, acts on it, and writes the result to the status.

## Common points to debug

If something doesn't behave the way you expect:

- If applying a CRD version fails, read the error carefully. The API server validates the CRD itself, so a field without a `type` or a CEL rule that doesn't compile is rejected before anything changes.
- If a valid Pet is rejected, run the same command with `--dry-run=server` and read the full error. It names the field and the rule that failed.
- If `kubectl get pt` or `kubectl get zoo` doesn't work, check `spec.names.shortNames` and `spec.names.categories` in the CRD.
- If a default doesn't show up, check that every parent object on the way to the field has a default too, like `diet: default: {}`.
- If the status doesn't change, make sure you used `--subresource=status`, and that the CRD schema still describes `status.mood` and `status.face`.

## Wrapping up

That's it! The API server now validates Pets, fills in defaults, keeps the status separate from the spec, and prints useful columns, all without a controller.

Nothing in the cluster reacts to a Pet yet, so `mochi` will never get hungry.
In the next tutorial, we write the controller that takes care of that:
[How Kubernetes Operators Work: Building a Controller From Scratch](/tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c).

### References

- [Extend the Kubernetes API with CustomResourceDefinitions](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)
- [Common Expression Language in Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/)
- [Validation rules for CRDs (KEP-2876)](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/2876-crd-validation-expression-language)
- [Kubernetes API conventions: spec and status](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md#spec-and-status)
