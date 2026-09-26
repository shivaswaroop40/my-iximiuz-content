---
kind: challenge

title: "Open a Kubernetes Zoo: Design a Validated Pet CustomResourceDefinition"

description: |
  The zoo is opening and the keepers have already written the paperwork for their first pets.
  All that's missing is the API. Teach the Kubernetes API server what a Pet is,
  so it can reject a cactus with a toy or a dragon that wants a snack every ten minutes.

categories:
- kubernetes

tagz:
- crd
- custom-resources
- cel
- api-extension

difficulty: medium

createdAt: 2026-09-26
updatedAt: 2026-09-26

cover: __static__/cover.png

playground:
  name: k8s-omni

tasks:
  init_scenario:
    init: true
    machine: dev-machine
    user: laborant
    run: |
      set -euo pipefail

      until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
      kubectl get namespace zoo >/dev/null 2>&1 || kubectl create namespace zoo

      mkdir -p "$HOME/pets/adopted" "$HOME/pets/turned-away"

      cat > "$HOME/pet-api.md" <<'SPEC'
      # The Pet API (signed off by the head zookeeper)

      Group:        zoo.example.com
      Version:      v1alpha1   (served, storage)
      Kind:         Pet
      Plural:       pets
      Singular:     pet
      Short name:   pt
      Category:     zoo        (so `kubectl get zoo` lists them)
      Scope:        Namespaced

      ## spec

      | Field          | Type                | Required | Default | Rules                                   |
      |----------------|---------------------|----------|---------|-----------------------------------------|
      | species        | string              | yes      |         | one of: cat, dog, dragon, cactus        |
      | toy            | string              | no       |         | at most 20 characters                   |
      | diet.food      | string              | no       | snacks  | at most 20 characters                   |
      | diet.feedEvery | string              | no       | 10m     | a number followed by s, m or h (e.g. 90s, 10m, 6h), at most 10 characters |
      | lastFedAt      | string (date-time)  | no       |         |                                         |

      A Pet without a `diet` block must still end up with `diet.food: snacks`
      and `diet.feedEvery: 10m`.

      House rules (the API server must enforce these too):

      - Cacti don't play with toys. A cactus must not have a `toy`.
        Error message: "cacti don't play with toys"
      - Dragons eat at most once an hour. A dragon's `diet.feedEvery` must be at least 1h.
        Error message: "dragons eat at most once an hour: diet.feedEvery must be at least 1h"

      ## status (written only by the future pet controller, never by keepers)

      | Field | Type   | Example        |
      |-------|--------|----------------|
      | mood  | string | Happy, Hungry  |
      | face  | string | 😺             |

      ## kubectl get output

      NAME   SPECIES   FACE   MOOD   TOY   LAST FED   AGE
      SPEC

      cat > "$HOME/pets/adopted/mochi.yaml" <<'EOF'
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: mochi
        namespace: zoo
      spec:
        species: cat
        toy: yarn
      EOF

      cat > "$HOME/pets/adopted/rex.yaml" <<'EOF'
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: rex
        namespace: zoo
      spec:
        species: dog
        toy: stick
        diet:
          food: bones
          feedEvery: 30m
      EOF

      cat > "$HOME/pets/adopted/smaug.yaml" <<'EOF'
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

      cat > "$HOME/pets/adopted/prickles.yaml" <<'EOF'
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: prickles
        namespace: zoo
      spec:
        species: cactus
        diet:
          food: water
          feedEvery: 168h
      EOF

      cat > "$HOME/pets/turned-away/spiky-ball.yaml" <<'EOF'
      # A cactus that wants to play fetch. Ouch.
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: spiky-ball
        namespace: zoo
      spec:
        species: cactus
        toy: tennis ball
      EOF

      cat > "$HOME/pets/turned-away/snacky-dragon.yaml" <<'EOF'
      # A dragon on a cat's feeding schedule would eat the zoo's budget in a day.
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: snacky-dragon
        namespace: zoo
      spec:
        species: dragon
        diet:
          food: sheep
          feedEvery: 15m
      EOF

      cat > "$HOME/pets/turned-away/lazy-dragon.yaml" <<'EOF'
      # No diet given, so this dragon gets the default one. Is that allowed?
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: lazy-dragon
        namespace: zoo
      spec:
        species: dragon
      EOF

      cat > "$HOME/pets/turned-away/sparkles.yaml" <<'EOF'
      # We don't have a unicorn enclosure.
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: sparkles
        namespace: zoo
      spec:
        species: unicorn
      EOF

      cat > "$HOME/pets/turned-away/whenever.yaml" <<'EOF'
      # "whenever" is not a duration.
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: whenever
        namespace: zoo
      spec:
        species: dog
        diet:
          feedEvery: whenever
      EOF

  verify_crd_registered:
    machine: dev-machine
    user: laborant
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
      )
      for spec in "${GOOD[@]}"; do try "$spec" || exit 1; done
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
      )
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
      )
      for c in "${BAD[@]}"; do
        if try "${c#*|}"; then
          echo "The API server accepted a Pet where ${c%%|*}. The contract says it must be turned away."
          break
        fi
      done
      exit 0

  verify_house_rules:
    machine: dev-machine
    user: laborant
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
      if out=$(try '{"species":"cactus","toy":"ball"}'); then
        echo "A cactus with a toy is still accepted."
        echo "OpenAPI can't say 'this field is forbidden only if another field has a certain value'. What else can the API server evaluate?"
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
        echo "A default on a nested field only kicks in if its parent object exists..."
      else
        [ "$food" = "snacks" ] || echo "A Pet without a diet should get diet.food: snacks, but got '${food}'."
        [ "$every" = "10m" ] || echo "A Pet without a diet should get diet.feedEvery: 10m, but got '${every}'."
      fi
      exit 0

  verify_status_subresource:
    machine: dev-machine
    user: laborant
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
        echo "Keepers can still write .status directly. How do you give a CRD version a separate /status endpoint?"
      elif ! printf '{"apiVersion":"zoo.example.com/v1alpha1","kind":"Pet","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"species":"cat"},"status":{"mood":"Happy","face":"😺"}}' \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1; then
        echo "The status subresource is on, but the schema doesn't describe .status.mood and .status.face yet."
      fi
      exit 0

  verify_printer_columns:
    machine: dev-machine
    user: laborant
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
    hintcheck: |
      n=$(kubectl get pets -n zoo -o name 2>/dev/null | wc -l)
      if [ "$n" -gt 4 ]; then
        echo "There are $n Pets in the zoo namespace, but only the four from ~/pets/adopted/ belong there."
      else
        for name in mochi rex smaug prickles; do
          kubectl get pet -n zoo "$name" >/dev/null 2>&1 || { echo "Pet zoo/$name doesn't exist yet."; break; }
        done
      fi
      exit 0

  verify_status_reported:
    machine: dev-machine
    user: laborant
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
      else
        echo "mochi's status is '$got', expected mood Happy and face 😺."
      fi
      exit 0
---

The zoo opens next week. The keepers have done their paperwork, and every new arrival already has a Pet manifest.
There's no pet-care controller yet (that's another team's job). The keepers need the **API** first,
so they can commit manifests today and have the API server turn away anything that breaks the house rules.

The head zookeeper's spec is waiting for you on the `dev-machine`:

```sh
cat ~/pet-api.md
```

So is the paperwork:

```sh
ls ~/pets/adopted ~/pets/turned-away
```

Every Pet in `adopted/` must be let in. Every Pet in `turned-away/` must bounce off the API server with a clear error.
Those files aren't the whole test suite, though. The spec is.

::remark-box
---
kind: info
---
There is no controller in this challenge, and you don't need one.
A CustomResourceDefinition alone makes the API server store, validate, default and print a new resource type.
Want to see a controller bring these pets to life? That's the
[Build a Kubernetes Operator From Scratch](/tutorials/build-a-kubernetes-operator-from-scratch) tutorial.
::

## Register the API

Create a CustomResourceDefinition that serves `Pet` objects in the `zoo.example.com` group, version `v1alpha1`, exactly as named in the spec.

::simple-task
---
:tasks: tasks
:name: verify_crd_registered
---
#active
Waiting for the `pets.zoo.example.com` CRD to be registered and established...

#completed
The API server now knows what a Pet is. No recompiling, no restarts.
::

::hint-box
---
:summary: Hint 1
---
You don't have to write a CRD from memory. `kubectl explain` works for CRDs too:

```sh
kubectl explain customresourcedefinition.spec --recursive | less
```

The Kubernetes docs page [Extend the Kubernetes API with CustomResourceDefinitions](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/) has a complete example you can adapt.
::

Keepers are busy people. Make sure both of these work:

```sh
kubectl get pt -n zoo
kubectl get zoo -n zoo
```

::simple-task
---
:tasks: tasks
:name: verify_crd_discoverable
---
#active
Waiting for Pets to answer to `pt` and to the `zoo` category...

#completed
Short names and categories are just discovery metadata, but they are what people actually type.
::

## Enforce the spec

Every rule in the spec table must be enforced by the API server.
Valid Pets must be let in, invalid ones turned away, and the checker will try more than the files in `~/pets/`.

::simple-task
---
:tasks: tasks
:name: verify_schema_accepts_valid
---
#active
Sending valid Pets to the API server (server-side dry run)...

#completed
All valid Pets were let in.
::

::simple-task
---
:tasks: tasks
:name: verify_schema_rejects_invalid
---
#active
Sending invalid Pets to the API server (server-side dry run)...

#completed
Every invalid Pet was turned away before it could reach etcd.
::

::hint-box
---
:summary: Hint 2
---
A CRD's `openAPIV3Schema` supports much more than `type`.
Look up `required`, `enum`, `maxLength`, `pattern` and `format`.

You can test your schema without creating anything:

```sh
kubectl apply --dry-run=server -f ~/pets/turned-away/
```
::

The house rules don't fit into a plain OpenAPI schema: whether `toy` is allowed depends on `species`,
and "at least an hour" means comparing durations, not strings.

::simple-task
---
:tasks: tasks
:name: verify_house_rules
---
#active
Checking that cacti can't have toys and dragons don't snack...

#completed
Cross-field rules, enforced entirely by the API server.
::

::hint-box
---
:summary: Hint 3
---
CRDs can carry validation rules written in the
[Common Expression Language (CEL)](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules).
Look for `x-kubernetes-validations`. A rule attached to `spec` can see all of spec's fields through `self`,
and the [Kubernetes CEL libraries](https://kubernetes.io/docs/reference/using-api/cel/) include a `duration()` function.
::

Keepers shouldn't have to spell out the obvious. A Pet with only a `species` must come back from the API server with the default diet from the spec.

::simple-task
---
:tasks: tasks
:name: verify_defaults
---
#active
Creating a minimal Pet and checking which defaults the API server filled in...

#completed
Defaults are applied by the API server, so every client sees the same object.
::

::hint-box
---
:summary: Hint 4
---
`default:` is a valid schema keyword in CRDs.
Watch out for `diet`: if the object doesn't have a `diet` block at all, there's nothing for the nested defaults to attach to.
And look closely at `~/pets/turned-away/lazy-dragon.yaml`. Defaults are applied *before* validation.
::

## Separate spec from status

The future pet controller will report each pet's mood in `.status`. Keepers must not be able to write it along with their spec,
and the schema must describe the two status fields from the spec.

::simple-task
---
:tasks: tasks
:name: verify_status_subresource
---
#active
Waiting for Pet to get a dedicated status subresource...

#completed
`.status` is now written through its own endpoint, and any `.status` in a regular create or update is ignored.
::

## Make `kubectl get` useful

`kubectl get pets` should show the columns from the spec: `SPECIES`, `FACE`, `MOOD`, `TOY`, `LAST FED`, and `AGE`.

::simple-task
---
:tasks: tasks
:name: verify_printer_columns
---
#active
Waiting for the printer columns to be defined...

#completed
Much better than a lonely `NAME` column.
::

::hint-box
---
:summary: Hint 5
---
Look up `additionalPrinterColumns` in the CRD version spec.
Each column needs a `name`, a `type` and a `jsonPath`.
::

## Open the gates

Let in the four pets from `~/pets/adopted/`, as they are, and no one else.

::simple-task
---
:tasks: tasks
:name: verify_pets_adopted
---
#active
Waiting for mochi, rex, smaug and prickles to arrive in the `zoo` namespace...

#completed
The zoo has its first residents.
::

Finally, pretend to be the pet controller. Mochi just had a nap in the sun.
Record that on its status, without touching its spec:

- `mood`: `Happy`
- `face`: `😺`

Then run `kubectl get pets -n zoo` and enjoy the view.

::simple-task
---
:tasks: tasks
:name: verify_status_reported
---
#active
Waiting for mochi to report a happy mood...

#completed
That's a controller's whole job, done by hand: watch the spec, act on it, write the result to status.
If you want to see one do it for real, and watch mochi get hungry, try the operator tutorial next.
::

::hint-box
---
:summary: Hint 6
---
`kubectl apply`, `kubectl edit` and `kubectl patch` all target the main resource by default,
and the main resource ignores `.status` now. Check `kubectl patch --help` for a flag that picks a subresource.
::
