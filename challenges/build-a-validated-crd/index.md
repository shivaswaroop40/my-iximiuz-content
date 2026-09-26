---
kind: challenge

title: "Extend the Kubernetes API With a Validated CustomResourceDefinition"

description: |
  The platform team has signed off on a new BackupSchedule API, and app teams are already writing manifests for it.
  There is no controller yet. The contract comes first: register the CRD so that the API server
  validates, defaults, and prints BackupSchedule objects the way the spec says.

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
      kubectl get namespace payments >/dev/null 2>&1 || kubectl create namespace payments

      mkdir -p "$HOME/manifests/accepted" "$HOME/manifests/rejected"

      cat > "$HOME/backupschedule-api.md" <<'SPEC'
      # BackupSchedule API contract (approved by the platform team)

      Group:        platform.example.com
      Version:      v1alpha1   (served, storage)
      Kind:         BackupSchedule
      Plural:       backupschedules
      Singular:     backupschedule
      Short name:   bks
      Category:     platform   (so `kubectl get platform` lists them)
      Scope:        Namespaced

      ## spec

      | Field              | Type    | Required | Default  | Rules                                         |
      |--------------------|---------|----------|----------|-----------------------------------------------|
      | schedule           | string  | yes      |          | a 5-field cron expression, e.g. "0 2 * * *"   |
      | source.pvcName     | string  | yes      |          | non-empty                                     |
      | method             | string  | no       | snapshot | one of: snapshot, restic                      |
      | repository         | string  | no*      |          | *required when method is restic               |
      | retention.keepLast | integer | no       | 7        | 1..30 (inclusive)                             |
      | suspend            | boolean | no       | false    |                                               |

      A BackupSchedule that omits `retention` altogether must still end up with
      `retention.keepLast: 7`.

      ## status (written only by the future backup agent, never by app teams)

      | Field            | Type                |
      |------------------|---------------------|
      | lastBackupTime   | string (date-time)  |
      | lastBackupResult | string              |

      ## kubectl get output

      NAME   SCHEDULE   METHOD   KEEP   SUSPENDED   LAST BACKUP   AGE
      SPEC

      cat > "$HOME/manifests/accepted/orders-db-nightly.yaml" <<'EOF'
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: orders-db-nightly
        namespace: payments
      spec:
        schedule: "0 2 * * *"
        source:
          pvcName: orders-db-data
        retention:
          keepLast: 14
      EOF

      cat > "$HOME/manifests/accepted/ledger-hourly.yaml" <<'EOF'
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: ledger-hourly
        namespace: payments
      spec:
        schedule: "0 * * * *"
        method: restic
        repository: s3://acme-backups/ledger
        source:
          pvcName: ledger-data
      EOF

      cat > "$HOME/manifests/accepted/invoices-weekly.yaml" <<'EOF'
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: invoices-weekly
        namespace: payments
      spec:
        schedule: "30 3 * * 0"
        suspend: true
        source:
          pvcName: invoices-data
      EOF

      cat > "$HOME/manifests/rejected/keep-a-quarter.yaml" <<'EOF'
      # Someone wanted "a quarter's worth" of nightly backups. Policy caps retention at 30.
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: keep-a-quarter
        namespace: payments
      spec:
        schedule: "0 1 * * *"
        source:
          pvcName: orders-db-data
        retention:
          keepLast: 90
      EOF

      cat > "$HOME/manifests/rejected/rsync-method.yaml" <<'EOF'
      # rsync is not a supported backup method.
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: rsync-method
        namespace: payments
      spec:
        schedule: "0 4 * * *"
        method: rsync
        source:
          pvcName: ledger-data
      EOF

      cat > "$HOME/manifests/rejected/restic-nowhere.yaml" <<'EOF'
      # restic needs somewhere to push the backup to.
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: restic-nowhere
        namespace: payments
      spec:
        schedule: "15 * * * *"
        method: restic
        source:
          pvcName: ledger-data
      EOF

      cat > "$HOME/manifests/rejected/human-schedule.yaml" <<'EOF'
      # "nightly" is not a cron expression.
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: human-schedule
        namespace: payments
      spec:
        schedule: nightly
        source:
          pvcName: invoices-data
      EOF

      cat > "$HOME/manifests/rejected/no-source.yaml" <<'EOF'
      # A backup of... what, exactly?
      apiVersion: platform.example.com/v1alpha1
      kind: BackupSchedule
      metadata:
        name: no-source
        namespace: payments
      spec:
        schedule: "0 5 * * *"
      EOF

  verify_crd_registered:
    machine: dev-machine
    user: laborant
    run: |
      CRD=backupschedules.platform.example.com
      get() { kubectl get crd "$CRD" -o jsonpath="$1" 2>/dev/null; }

      [ "$(get '{.status.conditions[?(@.type=="Established")].status}')" = "True" ] || exit 1
      [ "$(get '{.spec.group}')" = "platform.example.com" ] || exit 1
      [ "$(get '{.spec.names.kind}')" = "BackupSchedule" ] || exit 1
      [ "$(get '{.spec.names.singular}')" = "backupschedule" ] || exit 1
      [ "$(get '{.spec.scope}')" = "Namespaced" ] || exit 1
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].served}')" = "true" ] || exit 1
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].storage}')" = "true" ] || exit 1
    hintcheck: |
      CRD=backupschedules.platform.example.com
      get() { kubectl get crd "$CRD" -o jsonpath="$1" 2>/dev/null; }

      if ! kubectl get crd "$CRD" >/dev/null 2>&1; then
        echo "There is no CRD named $CRD yet. A CRD's name must be <plural>.<group>."
        exit 0
      fi
      [ "$(get '{.status.conditions[?(@.type=="Established")].status}')" = "True" ] \
        || echo "The CRD exists but is not Established. Check its status conditions: kubectl describe crd $CRD"
      [ "$(get '{.spec.names.kind}')" = "BackupSchedule" ] || echo "The kind should be BackupSchedule."
      [ "$(get '{.spec.names.singular}')" = "backupschedule" ] || echo "The singular name should be backupschedule."
      [ "$(get '{.spec.scope}')" = "Namespaced" ] || echo "BackupSchedules live in app namespaces. Check the CRD scope."
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].served}')" = "true" ] || echo "Version v1alpha1 must be served."
      [ "$(get '{.spec.versions[?(@.name=="v1alpha1")].storage}')" = "true" ] || echo "Version v1alpha1 must be the storage version."
      exit 0

  verify_crd_discoverable:
    machine: dev-machine
    user: laborant
    needs:
    - verify_crd_registered
    run: |
      kubectl api-resources --api-group=platform.example.com -o wide 2>/dev/null | grep -qw bks || exit 1
      kubectl get bks -n payments >/dev/null 2>&1 || exit 1
      kubectl get platform -n payments >/dev/null 2>&1 || exit 1
    hintcheck: |
      CRD=backupschedules.platform.example.com
      kubectl get crd "$CRD" -o jsonpath='{.spec.names.shortNames}' 2>/dev/null | grep -qw bks \
        || echo "'kubectl get bks' doesn't work yet. Which field under spec.names holds short aliases?"
      kubectl get crd "$CRD" -o jsonpath='{.spec.names.categories}' 2>/dev/null | grep -qw platform \
        || echo "'kubectl get platform' doesn't list BackupSchedules yet. Which field under spec.names groups resources, like 'all' does?"
      exit 0

  verify_schema_accepts_valid:
    machine: dev-machine
    user: laborant
    needs:
    - verify_crd_registered
    run: |
      try() {
        printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1
      }
      GOOD=(
        '{"schedule":"0 2 * * *","source":{"pvcName":"data"}}'
        '{"schedule":"*/15 * * * 1-5","source":{"pvcName":"data"},"method":"snapshot","retention":{"keepLast":1}}'
        '{"schedule":"0 0 1 * *","source":{"pvcName":"data"},"method":"restic","repository":"s3://bucket/path","retention":{"keepLast":30}}'
        '{"schedule":"0 3 * * 0","source":{"pvcName":"data"},"repository":"s3://bucket/path","suspend":true}'
      )
      for spec in "${GOOD[@]}"; do try "$spec" || exit 1; done
    hintcheck: |
      try() {
        printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - 2>&1 >/dev/null
      }
      GOOD=(
        '{"schedule":"0 2 * * *","source":{"pvcName":"data"}}'
        '{"schedule":"*/15 * * * 1-5","source":{"pvcName":"data"},"method":"snapshot","retention":{"keepLast":1}}'
        '{"schedule":"0 0 1 * *","source":{"pvcName":"data"},"method":"restic","repository":"s3://bucket/path","retention":{"keepLast":30}}'
        '{"schedule":"0 3 * * 0","source":{"pvcName":"data"},"repository":"s3://bucket/path","suspend":true}'
      )
      for spec in "${GOOD[@]}"; do
        if err=$(try "$spec") && [ -z "$err" ]; then continue; fi
        echo "A valid BackupSchedule was rejected. spec: $spec"
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
        printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1
      }
      BAD=(
        '{"source":{"pvcName":"data"}}'
        '{"schedule":"nightly","source":{"pvcName":"data"}}'
        '{"schedule":"0 0 * * * *","source":{"pvcName":"data"}}'
        '{"schedule":"0 2 * * *"}'
        '{"schedule":"0 2 * * *","source":{}}'
        '{"schedule":"0 2 * * *","source":{"pvcName":""}}'
        '{"schedule":"0 2 * * *","source":{"pvcName":"data"},"method":"rsync"}'
        '{"schedule":"0 2 * * *","source":{"pvcName":"data"},"retention":{"keepLast":0}}'
        '{"schedule":"0 2 * * *","source":{"pvcName":"data"},"retention":{"keepLast":31}}'
        '{"schedule":"0 2 * * *","source":{"pvcName":"data"},"retention":{"keepLast":"seven"}}'
        '{"schedule":"0 2 * * *","source":{"pvcName":"data"},"suspend":"yes"}'
      )
      try '{"schedule":"0 2 * * *","source":{"pvcName":"data"}}' || exit 1
      for spec in "${BAD[@]}"; do try "$spec" && exit 1; done
      exit 0
    hintcheck: |
      try() {
        printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1
      }
      BAD=(
        'spec.schedule is missing|{"source":{"pvcName":"data"}}'
        'spec.schedule is "nightly", which is not a cron expression|{"schedule":"nightly","source":{"pvcName":"data"}}'
        'spec.schedule has 6 fields instead of 5|{"schedule":"0 0 * * * *","source":{"pvcName":"data"}}'
        'spec.source is missing|{"schedule":"0 2 * * *"}'
        'spec.source.pvcName is missing|{"schedule":"0 2 * * *","source":{}}'
        'spec.source.pvcName is an empty string|{"schedule":"0 2 * * *","source":{"pvcName":""}}'
        'spec.method is "rsync"|{"schedule":"0 2 * * *","source":{"pvcName":"data"},"method":"rsync"}'
        'spec.retention.keepLast is 0|{"schedule":"0 2 * * *","source":{"pvcName":"data"},"retention":{"keepLast":0}}'
        'spec.retention.keepLast is 31|{"schedule":"0 2 * * *","source":{"pvcName":"data"},"retention":{"keepLast":31}}'
        'spec.retention.keepLast is the string "seven"|{"schedule":"0 2 * * *","source":{"pvcName":"data"},"retention":{"keepLast":"seven"}}'
        'spec.suspend is the string "yes"|{"schedule":"0 2 * * *","source":{"pvcName":"data"},"suspend":"yes"}'
      )
      for c in "${BAD[@]}"; do
        if try "${c#*|}"; then
          echo "The API server accepted a BackupSchedule where ${c%%|*}. The contract says it must be rejected."
          break
        fi
      done
      exit 0

  verify_cross_field_rule:
    machine: dev-machine
    user: laborant
    needs:
    - verify_schema_accepts_valid
    run: |
      printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"},"method":"restic","repository":"s3://b/p"}}' \
        | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1 || exit 1
      out=$(printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"},"method":"restic"}}' \
        | kubectl create --dry-run=server -o name -f - 2>&1) && exit 1
      echo "$out" | grep -qi "repository" || exit 1
      kubectl get crd backupschedules.platform.example.com -o yaml 2>/dev/null | grep -q "x-kubernetes-validations" || exit 1
    hintcheck: |
      if printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"},"method":"restic"}}' \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1; then
        echo "A restic BackupSchedule without a repository is still accepted."
        echo "OpenAPI 'required' can't express 'required only if another field has a certain value'. What else can the API server evaluate?"
      else
        echo "The restic-without-repository case is rejected, but the error message should mention the missing repository."
      fi
      exit 0

  verify_defaults:
    machine: dev-machine
    user: laborant
    needs:
    - verify_schema_accepts_valid
    run: |
      got=$(printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"}}}' \
        | kubectl create --dry-run=server -f - -o jsonpath='{.spec.method}/{.spec.suspend}/{.spec.retention.keepLast}' 2>/dev/null)
      [ "$got" = "snapshot/false/7" ] || exit 1
      got=$(printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"},"method":"restic","repository":"s3://b/p","suspend":true,"retention":{"keepLast":3}}}' \
        | kubectl create --dry-run=server -f - -o jsonpath='{.spec.method}/{.spec.suspend}/{.spec.retention.keepLast}' 2>/dev/null)
      [ "$got" = "restic/true/3" ] || exit 1
    hintcheck: |
      got=$(printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"}}}' \
        | kubectl create --dry-run=server -f - -o jsonpath='{.spec.method}|{.spec.suspend}|{.spec.retention.keepLast}' 2>/dev/null)
      IFS='|' read -r method suspend keep <<< "$got"
      [ "$method" = "snapshot" ] || echo "A minimal BackupSchedule should get method: snapshot, but got '${method}'."
      [ "$suspend" = "false" ] || echo "A minimal BackupSchedule should get suspend: false, but got '${suspend}'."
      if [ "$keep" != "7" ]; then
        echo "A BackupSchedule with no retention block should end up with retention.keepLast: 7, but got '${keep}'."
        echo "A default on a nested field only kicks in if its parent object exists..."
      fi
      exit 0

  verify_status_subresource:
    machine: dev-machine
    user: laborant
    needs:
    - verify_schema_accepts_valid
    run: |
      CRD=backupschedules.platform.example.com
      [ -n "$(kubectl get crd "$CRD" -o jsonpath='{.spec.versions[?(@.name=="v1alpha1")].subresources.status}' 2>/dev/null)" ] || exit 1
      # With the status subresource on, whatever a client sends in .status on create is dropped.
      got=$(printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"}},"status":{"lastBackupTime":"2026-01-01T00:00:00Z","lastBackupResult":"Succeeded"}}' \
        | kubectl create --dry-run=server -f - -o jsonpath='{.status}' 2>/dev/null) || exit 1
      [ -z "$got" ] || exit 1
    hintcheck: |
      CRD=backupschedules.platform.example.com
      if [ -z "$(kubectl get crd "$CRD" -o jsonpath='{.spec.versions[?(@.name=="v1alpha1")].subresources.status}' 2>/dev/null)" ]; then
        echo "App teams can still write .status directly. How do you give a CRD version a separate /status endpoint?"
      elif ! printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":{"schedule":"0 2 * * *","source":{"pvcName":"data"}},"status":{"lastBackupTime":"2026-01-01T00:00:00Z","lastBackupResult":"Succeeded"}}' \
          | kubectl create --dry-run=server -o name -f - >/dev/null 2>&1; then
        echo "The status subresource is on, but the schema doesn't describe .status.lastBackupTime and .status.lastBackupResult yet."
      fi
      exit 0

  verify_printer_columns:
    machine: dev-machine
    user: laborant
    needs:
    - verify_crd_registered
    run: |
      cols=$(kubectl get crd backupschedules.platform.example.com \
        -o jsonpath='{range .spec.versions[?(@.name=="v1alpha1")].additionalPrinterColumns[*]}{.name}={.jsonPath}{"\n"}{end}' 2>/dev/null \
        | tr '[:upper:]' '[:lower:]')
      for want in \
        "schedule=.spec.schedule" \
        "method=.spec.method" \
        "keep=.spec.retention.keeplast" \
        "suspended=.spec.suspend" \
        "last backup=.status.lastbackuptime" \
        "age=.metadata.creationtimestamp"; do
        echo "$cols" | grep -qxF "$want" || exit 1
      done
    hintcheck: |
      cols=$(kubectl get crd backupschedules.platform.example.com \
        -o jsonpath='{range .spec.versions[?(@.name=="v1alpha1")].additionalPrinterColumns[*]}{.name}={.jsonPath}{"\n"}{end}' 2>/dev/null \
        | tr '[:upper:]' '[:lower:]')
      for want in \
        "schedule=.spec.schedule" \
        "method=.spec.method" \
        "keep=.spec.retention.keeplast" \
        "suspended=.spec.suspend" \
        "last backup=.status.lastbackuptime" \
        "age=.metadata.creationtimestamp"; do
        if ! echo "$cols" | grep -qxF "$want"; then
          echo "The '${want%%=*}' column is missing or points at the wrong field."
          [ "${want%%=*}" = "age" ] && echo "Once you define custom columns, AGE isn't added for you anymore."
          break
        fi
      done
      exit 0

  verify_manifests_applied:
    machine: dev-machine
    user: laborant
    needs:
    - verify_schema_rejects_invalid
    - verify_cross_field_rule
    - verify_defaults
    run: |
      q() { kubectl get bks -n payments "$1" -o jsonpath="$2" 2>/dev/null; }
      [ "$(q orders-db-nightly '{.spec.schedule}/{.spec.source.pvcName}/{.spec.method}/{.spec.retention.keepLast}/{.spec.suspend}')" = "0 2 * * */orders-db-data/snapshot/14/false" ] || exit 1
      [ "$(q ledger-hourly '{.spec.schedule}/{.spec.source.pvcName}/{.spec.method}/{.spec.repository}/{.spec.retention.keepLast}')" = "0 * * * */ledger-data/restic/s3://acme-backups/ledger/7" ] || exit 1
      [ "$(q invoices-weekly '{.spec.schedule}/{.spec.source.pvcName}/{.spec.method}/{.spec.retention.keepLast}/{.spec.suspend}')" = "30 3 * * 0/invoices-data/snapshot/7/true" ] || exit 1
      [ "$(kubectl get bks -n payments -o name 2>/dev/null | wc -l)" -eq 3 ] || exit 1
    hintcheck: |
      n=$(kubectl get bks -n payments -o name 2>/dev/null | wc -l)
      if [ "$n" -gt 3 ]; then
        echo "There are $n BackupSchedules in the payments namespace, but only the three from ~/manifests/accepted/ belong there."
      else
        for name in orders-db-nightly ledger-hourly invoices-weekly; do
          kubectl get bks -n payments "$name" >/dev/null 2>&1 || { echo "BackupSchedule payments/$name doesn't exist yet."; break; }
        done
      fi
      exit 0

  verify_status_reported:
    machine: dev-machine
    user: laborant
    needs:
    - verify_manifests_applied
    - verify_status_subresource
    - verify_printer_columns
    run: |
      got=$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.status.lastBackupTime}/{.status.lastBackupResult}' 2>/dev/null)
      [ "$got" = "2026-09-25T02:00:00Z/Succeeded" ] || exit 1
      [ "$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.metadata.generation}' 2>/dev/null)" = "1" ] || exit 1
    hintcheck: |
      got=$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.status.lastBackupTime}/{.status.lastBackupResult}' 2>/dev/null)
      gen=$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.metadata.generation}' 2>/dev/null)
      if [ -n "$gen" ] && [ "$gen" != "1" ]; then
        echo "orders-db-nightly's spec has been modified since it was created (generation $gen). Delete and re-apply it from ~/manifests/accepted/, then write only its status."
      elif [ "$got" = "/" ]; then
        echo "orders-db-nightly has no status yet. A plain 'kubectl apply' or 'kubectl edit' won't write it. Which kubectl flag targets a subresource?"
      else
        echo "orders-db-nightly's status is '$got', expected lastBackupTime 2026-09-25T02:00:00Z and lastBackupResult Succeeded."
      fi
      exit 0
---

The platform team is rolling out an in-house backup agent.
Before anyone writes a single line of controller code, they want the **API** in place,
so app teams can start committing `BackupSchedule` manifests to their repos and the API server can tell them right away when a manifest is wrong.

The contract has been approved and is waiting for you on the `dev-machine`:

```sh
cat ~/backupschedule-api.md
```

The app teams have also sent over their first manifests:

```sh
ls ~/manifests/accepted ~/manifests/rejected
```

Everything in `accepted/` must go through. Everything in `rejected/` must bounce off the API server with a clear error.
Those files aren't the full test suite, though. The contract is.

::remark-box
---
kind: info
---
There is no controller in this challenge, and you don't need one.
A CustomResourceDefinition alone makes the API server store, validate, default and print a new resource type.
Reconciling it is a separate job, for another day.
::

## Register the API

Create a CustomResourceDefinition that serves `BackupSchedule` objects in the `platform.example.com` group, version `v1alpha1`, exactly as named in the contract.

::simple-task
---
:tasks: tasks
:name: verify_crd_registered
---
#active
Waiting for the `backupschedules.platform.example.com` CRD to be registered and established...

#completed
The API server now serves a brand-new resource type. No recompiling, no restarts.
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

Your fellow engineers are lazy typists. Make sure both of these work:

```sh
kubectl get bks -n payments
kubectl get platform -n payments
```

::simple-task
---
:tasks: tasks
:name: verify_crd_discoverable
---
#active
Waiting for BackupSchedules to answer to `bks` and to the `platform` category...

#completed
Short names and categories are just discovery metadata, but they are what people actually type.
::

## Enforce the contract

Every rule in the spec table must be enforced by the API server.
Valid objects must be accepted, invalid ones must be rejected, and the checker will try more than the handful of files in `~/manifests/`.

::simple-task
---
:tasks: tasks
:name: verify_schema_accepts_valid
---
#active
Sending valid BackupSchedules to the API server (server-side dry run)...

#completed
All valid BackupSchedules were accepted.
::

::simple-task
---
:tasks: tasks
:name: verify_schema_rejects_invalid
---
#active
Sending invalid BackupSchedules to the API server (server-side dry run)...

#completed
Every invalid BackupSchedule was rejected before it could reach etcd.
::

::hint-box
---
:summary: Hint 2
---
A CRD's `openAPIV3Schema` supports much more than `type`.
Look up `required`, `enum`, `minimum`, `maximum`, `minLength` and `pattern`.

You can test your schema without creating anything:

```sh
kubectl apply --dry-run=server -f ~/manifests/rejected/
```
::

One rule doesn't fit into a plain OpenAPI schema: `repository` is required **only when** `method` is `restic`.

::simple-task
---
:tasks: tasks
:name: verify_cross_field_rule
---
#active
Waiting for a restic BackupSchedule without a repository to be rejected with a meaningful error...

#completed
Cross-field validation, handled entirely by the API server.
::

::hint-box
---
:summary: Hint 3
---
Since Kubernetes v1.29, CRDs can carry validation rules written in the
[Common Expression Language (CEL)](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules).
Look for `x-kubernetes-validations`. A rule attached to `spec` can see all of spec's fields through `self`.
::

App teams shouldn't have to spell out the obvious. A BackupSchedule with only `schedule` and `source.pvcName` must come back from the API server fully populated with the defaults from the contract.

::simple-task
---
:tasks: tasks
:name: verify_defaults
---
#active
Creating a minimal BackupSchedule and checking which defaults the API server filled in...

#completed
Defaults are applied by the API server, so every client sees the same object.
::

::hint-box
---
:summary: Hint 4
---
`default:` is a valid schema keyword in CRDs.
Watch out for `retention.keepLast`: if the object doesn't have a `retention` block at all, there's nothing for the nested default to attach to.
::

## Separate spec from status

The backup agent will report results in `.status`. App teams must not be able to write it along with their spec,
and the schema must describe the two status fields from the contract.

::simple-task
---
:tasks: tasks
:name: verify_status_subresource
---
#active
Waiting for BackupSchedule to get a dedicated status subresource...

#completed
`.status` is now written through its own endpoint, and any `.status` in a regular create or update is ignored.
::

## Make `kubectl get` useful

`kubectl get bks` should show the columns from the contract: `SCHEDULE`, `METHOD`, `KEEP`, `SUSPENDED`, `LAST BACKUP`, and `AGE`.

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

## Ship it

Create the three BackupSchedules from `~/manifests/accepted/`, as they are, and nothing else.

::simple-task
---
:tasks: tasks
:name: verify_manifests_applied
---
#active
Waiting for the three BackupSchedules in the `payments` namespace...

#completed
The first BackupSchedules are live.
::

Finally, pretend to be the backup agent. The first nightly run of `orders-db-nightly` just finished.
Record it on the object's status, without touching its spec:

- `lastBackupTime`: `2026-09-25T02:00:00Z`
- `lastBackupResult`: `Succeeded`

Then run `kubectl get bks -n payments` and look at the `LAST BACKUP` column.

::simple-task
---
:tasks: tasks
:name: verify_status_reported
---
#active
Waiting for `orders-db-nightly` to report its first successful backup...

#completed
That is the whole job of a controller, done by hand: watch the spec, act on it, write the result to status.
You now have the API. Writing the controller is the next challenge.
::

::hint-box
---
:summary: Hint 6
---
`kubectl apply`, `kubectl edit` and `kubectl patch` all target the main resource by default,
and the main resource ignores `.status` now. Check `kubectl patch --help` for a flag that picks a subresource.
::
