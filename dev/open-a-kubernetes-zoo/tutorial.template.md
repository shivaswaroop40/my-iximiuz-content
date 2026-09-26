---
kind: tutorial

title: "Open a Kubernetes Zoo: Design a Validated CustomResourceDefinition"

description: |
  The zoo opens next week and the keepers have already written the paperwork. All that's missing is the API.
  Build a Pet CustomResourceDefinition one layer at a time: names, an OpenAPI schema, CEL house rules,
  defaults, a status subresource and printer columns. By the end, the API server itself turns away
  a cactus with a toy and a dragon that wants a snack every ten minutes.

categories:
- kubernetes

tagz:
- crd
- custom-resources
- cel
- api-extension

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
      | diet.feedEvery | string              | no       | 10m     | a number followed by s, m or h (e.g. 90s, 10m, 6h), at most 10 characters, between 1s and 8760h (a year) |
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
        'spec.diet.feedEvery is "0s" (the pet would never be full)|{"species":"cat","diet":{"feedEvery":"0s"}}'
        'spec.diet.feedEvery is "8761h", just over a year|{"species":"cat","diet":{"feedEvery":"8761h"}}'
        'spec.diet.feedEvery is "9999999h", more than a controller can even count|{"species":"cat","diet":{"feedEvery":"9999999h"}}'
        'spec.diet.feedEvery is "00000000001h", 12 characters long|{"species":"cat","diet":{"feedEvery":"00000000001h"}}'
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
        echo "A default on a nested field only kicks in if its parent object exists..."
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
        echo "If you already used it, check that the CRD schema still describes .status.mood and .status.face: undeclared fields are dropped."
      else
        echo "mochi's status is '$got', expected mood Happy and face 😺."
      fi
      exit 0
---

The zoo opens next week. The keepers have done their paperwork, and every new arrival already has a Pet manifest.
There's no pet-care controller yet (that's another team's job). The keepers need the **API** first,
so they can commit manifests today and have the API server turn away anything that breaks the house rules.

In this tutorial you'll build that API as a CustomResourceDefinition (CRD), one layer at a time:

- **names**, so the API server and `kubectl` know what a Pet is called
- an **OpenAPI schema**, so a Pet has a shape and bad values bounce
- **CEL rules**, for house rules that depend on more than one field
- **defaults**, and why their order relative to validation matters
- the **status subresource**, which keeps what keepers want apart from what a controller observes
- **printer columns**, so `kubectl get pets` shows something useful

No controller and no code: a CRD alone makes the API server store, validate, default and print a new resource type.

::remark-box
---
kind: info
---
The playground has a multi-node Kubernetes cluster, and `kubectl` is ready to go on the `dev-machine`.
Every checkpoint below turns green on its own once the cluster is in the right state.
::

## Meet the zoo

The head zookeeper's spec is waiting for you:

```sh
cat ~/pet-api.md
```

So is the paperwork. Pets in `adopted/` must be let in, pets in `turned-away/` must bounce off the API server with a clear error:

```sh
ls ~/pets/adopted ~/pets/turned-away
```

Try to use them before there's an API:

```sh
kubectl apply --dry-run=server -f ~/pets/adopted/
```

The API server has never heard of a `Pet`: `no matches for kind "Pet" in version "zoo.example.com/v1alpha1"`. Time to teach it.

## Step 1: Teach the API server the word "Pet"

A CRD starts with names. The object's own name must be `<plural>.<group>`, and `spec.names` holds everything clients use to refer to the type:

| Field | Value | Used for |
|-------|-------|----------|
| `group` + `versions[].name` | `zoo.example.com`, `v1alpha1` | the `apiVersion` in every Pet manifest |
| `names.kind` | `Pet` | the `kind` in every Pet manifest |
| `names.plural` / `names.singular` | `pets` / `pet` | the URL path (`/apis/zoo.example.com/v1alpha1/namespaces/zoo/pets`) and `kubectl get pet(s)` |
| `names.shortNames` | `pt` | `kubectl get pt` |
| `names.categories` | `zoo` | `kubectl get zoo`, the way `kubectl get all` works |
| `scope` | `Namespaced` | Pets live in a namespace, like Pods |

Every version needs a schema. For now, use the one that allows anything:

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/1-names.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
kubectl wait --for=condition=Established crd/pets.zoo.example.com
```

The new API shows up next to the built-in ones, and the short name and category work straight away:

```sh
kubectl api-resources --api-group=zoo.example.com
kubectl get pt -n zoo
kubectl get zoo -n zoo
```

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

Now try the pets that should be turned away:

```sh
kubectl apply --dry-run=server -f ~/pets/turned-away/
```

All five get in, unicorn included. `x-kubernetes-preserve-unknown-fields: true` means "store whatever you're given".
That's handy for a first prototype, and useless as a contract.

## Step 2: Describe what a Pet looks like

A CRD schema is an OpenAPI v3 schema, and it must be **structural**: every field has a `type`, and every object lists its `properties`.
Each row of the spec table maps to a schema keyword:

| The spec says | Schema keyword |
|---------------|----------------|
| `species` is required | `required: [species]` on `spec` |
| one of cat, dog, dragon, cactus | `enum` |
| at most 20 characters | `maxLength` |
| a number followed by s, m or h | `pattern` |
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
All valid Pets are let in.
::

Check the paperwork again. The adopted pets still get in:

```sh
kubectl apply --dry-run=server -f ~/pets/adopted/
kubectl apply --dry-run=server -f ~/pets/turned-away/
```

The unicorn (`sparkles`) and the pet that eats `whenever` now bounce. The other three still get in.
Two of them break rules that involve **two fields at once**, which OpenAPI is awkward at:
a `toy` is fine unless the `species` is `cactus`, and a dragon's `feedEvery` must be at least an hour.

There's also a quieter gap. A pattern checks the **shape** of a string, not its size.
`^[0-9]+(s|m|h)$` happily accepts `0s` (a pet that is never full) and `9999999h`, which is more than Go's `time.Duration` can hold.
Whatever controller reads this field later would choke on it.

::details-box
---
:summary: What happens to fields the schema doesn't mention?
---
Try adopting a Pet with a `favoriteColor`:

```sh
kubectl create --dry-run=server -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata: {name: picky, namespace: zoo}
spec: {species: cat, favoriteColor: blue}
EOF
```

`kubectl` asks the API server for strict field validation, so the request fails with `unknown field "spec.favoriteColor"`.
Clients that don't ask for strictness get their unknown fields silently **pruned** instead.
Either way, nothing the schema doesn't describe ever reaches etcd.
::

## Step 3: Write the house rules in CEL

CRDs can carry validation rules in the [Common Expression Language (CEL)](https://kubernetes.io/docs/reference/using-api/cel/).
A rule lives under `x-kubernetes-validations` at some level of the schema, and `self` is the value at that level.
The API server evaluates it on every create and update, before anything is stored.

Three rules cover the gaps:

- **Cacti don't play with toys.** The rule needs `species` and `toy`, so it goes on `spec`, where `self` sees both:
  `self.species != 'cactus' || !has(self.toy)`.
  A rule attached to `toy` itself would only run when a toy is present, and couldn't see the species.
- **Dragons eat at most once an hour.** Also on `spec`. Compare **durations**, not strings:
  as strings, `'59m' >= '1h'` is `true`, because `'5' > '1'`. The Kubernetes CEL library's `duration()` parses the string first,
  so `duration('59m') >= duration('1h')` is correctly `false`.
- **`feedEvery` between 1s and a year.** This one only needs the field itself, so it goes on `feedEvery`.

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/3-rules.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
kubectl apply --dry-run=server -f ~/pets/turned-away/
```

Every pet in `turned-away/` bounces now, each with the message from its rule.

::simple-task
---
:tasks: tasks
:name: verify_schema_rejects_invalid
---
#active
Sending invalid Pets to the API server (server-side dry run)...

#completed
Every invalid Pet is turned away before it can reach etcd.
::

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

Look closely at the error for `lazy-dragon`, though:

```
spec: Invalid value: "object": no such key: diet evaluating rule: dragons eat at most once an hour ...
```

The lazy dragon has no `diet` block at all, so the rule crashed trying to read `self.diet.feedEvery`.
It was rejected by accident. A cat without a diet gets in only because `self.species != 'dragon'` is true and CEL never looks further.
The spec says a Pet without a diet eats snacks every 10 minutes. Time to make the API server say so too.

## Step 4: Fill in the obvious with defaults

`default:` sets a value when a field is missing. Two details matter here.

**Defaults only apply where the parent exists.** A default on `diet.food` does nothing for a Pet with no `diet` block,
because there's no object to put `food` into. Give `diet` itself a default of `{}`: the API server creates the empty object first,
then fills in its fields.

**Defaulting runs before validation.** The lazy dragon gets `feedEvery: 10m` from the default, and only then do the rules run.
So it's rejected for the right reason now, and `self.diet.feedEvery` is always safe to read.

![The path of a request through the API server: decoding, then defaulting, then OpenAPI and CEL validation, then etcd. The lazy dragon gets its default diet before the dragon rule sees it.](__static__/request-pipeline.png)

```sh
cat > ~/pet-crd.yaml <<'EOF'
{{file:crd/4-defaults.yaml|strip-comments}}
EOF

kubectl apply -f ~/pet-crd.yaml
kubectl apply --dry-run=server -f ~/pets/turned-away/lazy-dragon.yaml
```

See what a minimal Pet looks like once the API server has filled it in:

```sh
kubectl create --dry-run=server -o yaml -f - <<'EOF'
apiVersion: zoo.example.com/v1alpha1
kind: Pet
metadata: {name: minimal, namespace: zoo}
spec: {species: cat}
EOF
```

::simple-task
---
:tasks: tasks
:name: verify_defaults
---
#active
Creating minimal Pets and checking which defaults the API server filled in...

#completed
Defaults are applied by the API server, so every client sees the same object.
::

## Step 5: Separate spec from status, and make `kubectl get` useful

A Pet's `spec` is what the keepers want. Its `status` is what the future pet controller observes, like the pet's mood.
They should be written by different people, through different doors.

`subresources.status: {}` gives Pets a separate `/status` endpoint:

- the main endpoint ignores whatever a client sends in `.status`
- the `/status` endpoint ignores whatever a client sends in `.spec`
- `metadata.generation` only goes up when the spec changes, which is how a controller later tells whether it has caught up

The schema has to describe `status` too. Undeclared status fields are pruned just like undeclared spec fields.

Finally, `kubectl get pets` only shows `NAME` and `AGE` so far. `additionalPrinterColumns` adds columns from any field.
Once you define your own, `AGE` isn't added for you anymore, so declare it explicitly.

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
Waiting for Pet to get a status subresource and a status schema...

#completed
`.status` is now written through its own endpoint, and any `.status` in a regular create or update is ignored.
::

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

## Step 6: Open the gates

Let in the four pets from `adopted/`:

```sh
kubectl apply -f ~/pets/adopted/
kubectl get pets -n zoo
```

Every pet got the columns, and the defaulted diet shows up in the stored objects:

```sh
kubectl get pet -n zoo mochi -o jsonpath='{.spec.diet}{"\n"}'
```

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

The `FACE` and `MOOD` columns are empty, because nobody has written a status yet. Pretend to be the pet controller.
First, try the obvious way, and watch it get ignored:

```sh
kubectl patch pet mochi -n zoo --type=merge -p '{"status":{"mood":"Happy","face":"😺"}}'
kubectl get pet mochi -n zoo
```

The main endpoint dropped the status. Target the `/status` subresource instead:

```sh
kubectl patch pet mochi -n zoo --subresource=status --type=merge \
  -p '{"status":{"mood":"Happy","face":"😺"}}'

kubectl get pets -n zoo
```

```
NAME       SPECIES   FACE   MOOD    TOY     LAST FED   AGE
mochi      cat       😺      Happy   yarn               1m
prickles   cactus                                      1m
rex        dog                      stick              1m
smaug      dragon                                      1m
```

Mochi's `generation` is still `1`: the status write didn't count as a spec change.

```sh
kubectl get pet mochi -n zoo -o jsonpath='{.metadata.generation}{"\n"}'
```

::simple-task
---
:tasks: tasks
:name: verify_status_reported
---
#active
Waiting for mochi to report a happy mood...

#completed
That's a controller's whole job, done by hand: watch the spec, act on it, write the result to status.
::

## What you built

| Feature | What it gives you |
|---------|-------------------|
| `spec.names` | the kind, the URL path, short names and categories |
| OpenAPI schema | types, required fields, enums, lengths, patterns, formats; unknown fields never stored |
| CEL rules (`x-kubernetes-validations`) | rules across fields, and real duration comparisons |
| `default:` | values filled in on the server, before validation, for every client |
| `subresources.status` | spec and status written through separate endpoints; `generation` tracks spec changes only |
| `additionalPrinterColumns` | a `kubectl get` output people can read |

All of it runs inside the API server. Nothing in the cluster reacts to a Pet yet, though: mochi will never actually get hungry.
To bring the pets to life, with a controller that gives each one a Pod, gets it hungry over time and lets it run away when nobody feeds it, continue with
[Build a Kubernetes Operator From Scratch: A Pet That Gets Hungry](/tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c).
