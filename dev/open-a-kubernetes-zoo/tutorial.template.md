---
kind: tutorial

title: "How Kubernetes CRDs Work: Designing a Validated API From Scratch"

description: |
  Learn what the Kubernetes API server does with a CustomResourceDefinition before any controller is involved.
  Build a CRD step by step, adding an OpenAPI schema, CEL validation rules, defaults, a status subresource, and printer columns.

categories:
- kubernetes

tagz:
- crd
- custom-resources
- cel
- kube-apiserver

createdAt: 2026-09-26
updatedAt: 2026-09-28

cover: __static__/cover.png

playground:
  name: k8s-omni

tasks:
  init_scenario:
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

      mkdir -p "$HOME/pets/adopted" "$HOME/pets/turned-away"

      cat > "$HOME/pet-api.md" <<'SPEC'
      # The Pet API

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
      | diet.feedEvery | string              | no       | 10m     | a number followed by s, m or h (e.g. 90s, 10m, 6h), at most 10 characters, between 1s and 8760h (a year) |
      | lastFedAt      | string (date-time)  | no       |         |                                         |

      A Pet without a `diet` block must still end up with `diet.food: snacks`
      and `diet.feedEvery: 10m`.

      Validation rules (the API server must enforce these too):

      - Cacti don't play with toys. A cactus must not have a `toy`.
        Error message: "cacti don't play with toys"
      - Dragons eat at most once an hour. A dragon's `diet.feedEvery` must be at least 1h.
        Error message: "dragons eat at most once an hour: diet.feedEvery must be at least 1h"

      ## status (written only by a controller, never by users)

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
      # Cacti must not have a toy.
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
      # Dragons must not be fed more often than once an hour.
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
      # No diet, so this dragon gets the default one. Is that allowed?
      apiVersion: zoo.example.com/v1alpha1
      kind: Pet
      metadata:
        name: lazy-dragon
        namespace: zoo
      spec:
        species: dragon
      EOF

      cat > "$HOME/pets/turned-away/sparkles.yaml" <<'EOF'
      # Unicorns are not on the list of species.
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
        '{"species":"cactus","diet":{"feedEvery":"8760h"}}'
        '{"species":"cat","diet":{"feedEvery":"1s"}}'
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
        '{"species":"cactus","diet":{"feedEvery":"8760h"}}'
        '{"species":"cat","diet":{"feedEvery":"1s"}}'
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
        'spec.diet.feedEvery is "9999999h", more than Go's time.Duration can hold|{"species":"cat","diet":{"feedEvery":"9999999h"}}'
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

A CustomResourceDefinition (CRD) adds a new resource type to the Kubernetes API.
CRDs usually come with a controller that acts on the new resources, and together they form an operator.
However, the API server can do a lot with a CRD alone.
With no controller involved, it stores custom resources, rejects invalid ones, fills in missing fields, and prints them in `kubectl get` output.

In this tutorial, we'll design a CRD for a small example API, a `Pet` resource, and answer the following questions:

- What does the API server need to know to serve a new resource type?
- How does an OpenAPI schema restrict what a custom resource can contain?
- How to express validation rules that involve several fields at once?
- In what order does the API server apply defaults and validation, and why does it matter?
- Why do custom resources need a separate `status` subresource?
- How to make `kubectl get` show the fields that matter?

We'll build the CRD one part at a time.
After every change, we'll send the same set of valid and invalid Pets to the API server and see which ones it accepts.

Let's get started!

## Prerequisites

Basic familiarity with Kubernetes and `kubectl` is assumed.
No programming is needed. Everything in this tutorial is YAML and `kubectl` commands.

The playground comes with a multi-node Kubernetes cluster, and `kubectl` on the `dev-machine` is already configured to talk to it.
The checkpoints in the text complete on their own once the cluster reaches the expected state.

## The Pet API specification

The playground's home directory has a short specification of the API we're going to build:

```sh
cat ~/pet-api.md
```

A Pet has a required `species`, an optional `toy`, an optional `diet` with a default value, and a `lastFedAt` timestamp.
Two rules involve more than one field: a cactus can't have a toy, and a dragon can't be fed more often than once an hour.
The `status` section is reserved for a controller that doesn't exist yet.

The `~/pets` directory has two sets of Pet manifests.
The ones in `adopted/` follow the specification, and the ones in `turned-away/` break it in different ways:

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

The goal is to make the API server accept every manifest from the first directory and reject every manifest from the second one.
Right now, `kubectl` can't even send them, because the API server doesn't know what a `Pet` is:

```sh
kubectl apply --dry-run=server -f ~/pets/adopted/
```

```text
resource mapping not found for name: "mochi" namespace: "zoo" from "/home/laborant/pets/adopted/mochi.yaml": no matches for kind "Pet" in version "zoo.example.com/v1alpha1"
ensure CRDs are installed first
...
```

::remark-box
---
kind: info
---
All commands in this tutorial that only test the API use `--dry-run=server`.
The request goes through the full API server pipeline, including defaulting and validation, but the object is never written to etcd.
::

## Registering a new resource type (names and versions)

The smallest useful CRD tells the API server what the new resource type is called, which versions it has, and whether it lives in a namespace.
The CRD object itself must be named `<plural>.<group>`:

| Field | Value | Where it shows up |
|-------|-------|-------------------|
| `group` and `versions[].name` | `zoo.example.com`, `v1alpha1` | The `apiVersion` of every Pet manifest |
| `names.kind` | `Pet` | The `kind` of every Pet manifest |
| `names.plural`, `names.singular` | `pets`, `pet` | The URL path (`/apis/zoo.example.com/v1alpha1/namespaces/zoo/pets`) and `kubectl get pet(s)` |
| `names.shortNames` | `pt` | `kubectl get pt` |
| `names.categories` | `zoo` | `kubectl get zoo`, similar to how `kubectl get all` works |
| `scope` | `Namespaced` | Pets live in namespaces, like Pods |

Every version also needs a schema.
For now, we'll use a schema that accepts any object (`x-kubernetes-preserve-unknown-fields: true`):

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/1-names.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
kubectl wait --for=condition=Established crd/pets.zoo.example.com
```

The API server starts serving the new resource right away.
There's no restart and no code to compile:

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

Now, try the manifests that should be rejected:

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

All five are accepted, including a unicorn (`sparkles`).
With `x-kubernetes-preserve-unknown-fields: true`, the API server stores whatever it receives, so the CRD doesn't validate anything yet.

## Describing the resource structure (OpenAPI schema)

A CRD schema is written in OpenAPI v3, and Kubernetes requires it to be **structural**.
Every field must have a `type`, and the fields of an object must be listed under `properties`, unless the schema explicitly allows unknown fields, as the first version did.
Most requirements from the specification map to a single schema keyword:

| The specification says | Schema keyword |
|------------------------|----------------|
| `species` is required | `required: [species]` on `spec` |
| One of cat, dog, dragon, cactus | `enum` |
| At most 20 characters | `maxLength` |
| A number followed by s, m or h | `pattern` |
| `lastFedAt` is a date-time | `format: date-time` |

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/2-schema.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
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

The manifests from `adopted/` are still accepted:

```sh
kubectl apply --dry-run=server -f ~/pets/adopted/
```

```text
pet.zoo.example.com/mochi created (server dry run)
pet.zoo.example.com/prickles created (server dry run)
pet.zoo.example.com/rex created (server dry run)
pet.zoo.example.com/smaug created (server dry run)
```

Two of the five manifests from `turned-away/` are now rejected:

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

The remaining three break rules that are hard or impossible to express with OpenAPI keywords alone:

- `spiky-ball` is a cactus with a toy. A `toy` is valid on its own, and only invalid in combination with `species: cactus`.
- `snacky-dragon` wants to be fed every `15m`. The value matches the pattern, but dragons must wait at least an hour.
- `lazy-dragon` has no `diet` at all. We'll come back to it later.

The `pattern` keyword has another limitation.
It checks what a string looks like, not the value it represents.
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

## Validating several fields at once (CEL rules)

CRD schemas can include validation rules written in the
[Common Expression Language (CEL)](https://kubernetes.io/docs/reference/using-api/cel/).
A rule goes into the `x-kubernetes-validations` list at some level of the schema, and the `self` variable refers to the value at that level.
The API server evaluates the rules on create and update requests, before the object is stored.

We need three rules:

- **Cacti don't play with toys.** The rule needs both `species` and `toy`, so it goes on `spec`, where `self` has access to both fields:
  `self.species != 'cactus' || !has(self.toy)`.
  A rule placed on `toy` would only run when a toy is present, and it couldn't read the species.
- **Dragons eat at most once an hour.** This rule also goes on `spec`, and it must compare durations, not strings.
  As strings, `'59m' >= '1h'` is `true`, because the character `5` sorts after `1`.
  CEL has a built-in `duration()` function, and `duration('59m') >= duration('1h')` is `false`, as expected.
- **`feedEvery` is between 1s and a year.** This rule only needs the field itself, so it goes on `feedEvery`.

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/3-rules.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
```

Now all five manifests from `turned-away/` are rejected:

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

The API server doesn't stop at the first error.
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

However, take a closer look at the error for `lazy-dragon`:

```text
spec: Invalid value: "object": no such key: diet evaluating rule: dragons eat at most once an hour ...
```

This Pet has no `diet` block, so the rule failed while trying to read `self.diet.feedEvery`.
The rejection is correct, but for the wrong reason.
A cat without a `diet` is accepted only because `self.species != 'dragon'` is `true`, and CEL's `||` ignores an error on the other side when one side is `true`.
The specification says that a Pet without a diet eats snacks every 10 minutes, and the CRD should say that, too.

## Filling in missing fields (defaults)

The `default` keyword sets a value for a field that is missing, both in incoming requests and in objects read from etcd.
There are two details to keep in mind.

**Defaults only apply when the parent object exists.**
A default on `diet.food` does nothing for a Pet without a `diet` block, because there is no object to add `food` to.
Setting `default: {}` on `diet` itself solves this.
The API server first adds an empty `diet` object and then fills in its fields.

**Defaulting runs before validation.**
The lazy dragon gets `feedEvery: 10m` from the default, and only then does the API server evaluate the CEL rules.
So `self.diet.feedEvery` always exists by the time a rule reads it.

::image-box
---
:src: __static__/request-pipeline.png
:alt: 'The path of a Pet through the API server: decoding and pruning, defaulting, mutating webhooks, schema and CEL validation, validating webhooks, and etcd.'
---
::

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/4-defaults.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
kubectl apply --dry-run=server -f ~/pets/turned-away/lazy-dragon.yaml
```

The lazy dragon is still rejected, but now by the dragon rule itself:

```text
The Pet "lazy-dragon" is invalid: spec: Invalid value: dragons eat at most once an hour: diet.feedEvery must be at least 1h
```

To see the defaults, create a minimal Pet and print the object that the API server would store:

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

## Separating spec from status (status subresource)

The `spec` of a Pet describes what its owner wants.
The `status` describes what a controller observed, such as the pet's mood.
These two parts are written by different clients, and the CRD can keep them apart.

Setting `subresources.status: {}` gives Pets a separate `/status` endpoint:

- The main endpoint ignores any changes to `.status`.
- The `/status` endpoint ignores any changes to everything except `.status`.
- `metadata.generation` increases only when something outside `metadata` and `status` changes, which for a Pet means the spec. A controller can compare it with the generation it last processed.

The schema must describe `status` too, or the API server prunes its fields in the same way it prunes unknown `spec` fields.
The final version of the CRD adds the status subresource, the status schema, and the printer columns that we'll look at in the next section:

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/5-status-and-columns.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
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

## Customizing the kubectl get output (printer columns)

Without custom columns, `kubectl get pets` shows only `NAME` and `AGE`.
The `additionalPrinterColumns` list in the CRD adds columns based on any field of the object.
Once you define custom columns, the API server no longer adds the `AGE` column, so it has to be on the list, too.

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

The CRD is complete, so the Pets from `adopted/` can be created for real:

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

The stored objects include the default diet:

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

The `FACE` and `MOOD` columns are empty because nothing has written a status yet.
Normally, a controller does that, but we can do it by hand.
First, try to set the status through the main endpoint:

```sh
kubectl patch pet mochi -n zoo --type=merge -p '{"status":{"mood":"Happy","face":"😺"}}'
```

```text
pet.zoo.example.com/mochi patched (no change)
```

The API server ignored the `.status` part of the patch.
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

This is what a controller does in a loop: it reads the spec, acts on it, and writes the result to the status.

## Summarizing

Without any controller, the API server used the CRD to:

- Serve the new resource under its own URL path, with short names and categories for `kubectl`.
- Reject objects that don't match the OpenAPI schema, and prune or reject fields that the schema doesn't describe.
- Evaluate CEL rules, including rules that involve several fields and durations.
- Fill in defaults before validation, for every client.
- Keep `spec` and `status` behind separate endpoints, and increase `metadata.generation` only on spec changes.
- Show custom columns in `kubectl get`.

Still, nothing in the cluster reacts to a Pet yet.
To build that controller, continue with
[How Kubernetes Operators Work: Building a Controller From Scratch](/tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c).

### References

- [Extend the Kubernetes API with CustomResourceDefinitions](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)
- [Common Expression Language in Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/)
- [Validation rules for CRDs (KEP-2876)](https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/2876-crd-validation-expression-language)
- [Kubernetes API conventions: spec and status](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md#spec-and-status)
