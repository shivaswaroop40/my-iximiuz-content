---
kind: tutorial

title: "Build a Kubernetes Operator From Scratch: CRD, Controller, and the Reconcile Loop"

description: |
  Design a BackupSchedule API with a CustomResourceDefinition, then bring it to life:
  first with a 15-line bash loop, then with a real Go controller built on controller-runtime.
  Watch the reconcile loop create, update, self-heal, report status, survive restarts, and clean up after itself.

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
      if ! /usr/local/go/bin/go version 2>/dev/null | grep -q 'go1\.24'; then
        case "$(uname -m)" in
          x86_64) arch=amd64 ;;
          aarch64|arm64) arch=arm64 ;;
          *) echo "unsupported arch $(uname -m)"; exit 1 ;;
        esac
        rm -rf /usr/local/go
        curl -fsSL "https://go.dev/dl/go1.24.7.linux-${arch}.tar.gz" | tar -C /usr/local -xz
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
      kubectl get namespace payments >/dev/null 2>&1 || kubectl create namespace payments

      # A volume for our "database", so the backup jobs have something real to read.
      kubectl apply -f - <<'EOF'
      apiVersion: v1
      kind: PersistentVolume
      metadata:
        name: orders-db-data
      spec:
        capacity:
          storage: 1Gi
        accessModes: [ReadWriteOnce]
        storageClassName: ""
        hostPath:
          path: /var/lib/backup-demo/orders-db
          type: DirectoryOrCreate
      ---
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: orders-db-data
        namespace: payments
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: ""
        volumeName: orders-db-data
        resources:
          requests:
            storage: 1Gi
      EOF

      mkdir -p "$HOME/backup-operator/config"

  verify_crd_minimal:
    machine: dev-machine
    user: laborant
    run: |
      [ "$(kubectl get crd backupschedules.platform.example.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" = "True" ] || exit 1
      kubectl get backupschedules -n payments orders-db-nightly >/dev/null 2>&1

  verify_crd_full:
    machine: dev-machine
    user: laborant
    needs:
    - verify_crd_minimal
    run: |
      try() {
        printf '{"apiVersion":"platform.example.com/v1alpha1","kind":"BackupSchedule","metadata":{"generateName":"verify-","namespace":"default"},"spec":%s}' "$1" \
          | kubectl create --dry-run=server -f - -o "${2:-name}" 2>/dev/null
      }
      [ "$(try '{"schedule":"0 2 * * *","source":{"pvcName":"d"}}' 'jsonpath={.spec.method}/{.spec.retention.keepLast}')" = "snapshot/7" ] || exit 1
      try '{"schedule":"0 2 * * *","source":{"pvcName":"d"},"retention":{"keepLast":45}}' >/dev/null && exit 1
      try '{"schedule":"0 2 * * *","source":{"pvcName":"d"},"method":"restic"}' >/dev/null && exit 1
      try '{"schedule":"nightly","source":{"pvcName":"d"}}' >/dev/null && exit 1
      [ -n "$(kubectl get crd backupschedules.platform.example.com -o jsonpath='{.spec.versions[0].subresources.status}')" ]

  verify_naive_controller:
    machine: dev-machine
    user: laborant
    needs:
    - verify_crd_full
    run: |
      kubectl get cronjob -n payments orders-db-nightly-backup >/dev/null 2>&1

  verify_operator_owns_cronjob:
    machine: dev-machine
    user: laborant
    needs:
    - verify_naive_controller
    run: |
      [ "$(kubectl get cronjob -n payments orders-db-nightly-backup -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}' 2>/dev/null)" = "BackupSchedule" ] || exit 1
      [ -n "$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" ] || exit 1
      gen=$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.metadata.generation}')
      [ "$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.status.observedGeneration}')" = "$gen" ]

  verify_first_backup:
    machine: dev-machine
    user: laborant
    needs:
    - verify_operator_owns_cronjob
    run: |
      [ -n "$(kubectl get bks -n payments orders-db-nightly -o jsonpath='{.status.lastBackupTime}' 2>/dev/null)" ]

  verify_second_schedule:
    machine: dev-machine
    user: laborant
    needs:
    - verify_operator_owns_cronjob
    run: |
      [ "$(kubectl get cronjob -n payments ledger-hourly-backup -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}' 2>/dev/null)" = "ledger-hourly" ]

  verify_garbage_collected:
    machine: dev-machine
    user: laborant
    needs:
    - verify_second_schedule
    run: |
      kubectl get cronjob -n payments orders-db-nightly-backup >/dev/null 2>&1 || exit 1
      ! kubectl get bks -n payments ledger-hourly >/dev/null 2>&1 || exit 1
      ! kubectl get cronjob -n payments ledger-hourly-backup >/dev/null 2>&1
---

Most interesting things in Kubernetes today aren't built into Kubernetes.
Certificates (cert-manager), GitOps (Argo CD), databases (CloudNativePG), whole clusters (Cluster API):
they all follow the same recipe. **A CustomResourceDefinition** teaches the API server a new noun,
and **a controller** keeps turning that noun into reality.
Together they're called an *operator*.

In this tutorial you'll build one from scratch, one layer at a time, and see every layer work before adding the next:

1. **The API.** A `BackupSchedule` CRD with validation, defaults, and a status. No code yet.
2. **The loop, by hand.** A 15-line bash script that already acts like a controller, and shows you why it isn't enough.
3. **The real controller.** Go and [controller-runtime](https://github.com/kubernetes-sigs/controller-runtime), the library under Kubebuilder and Operator SDK.
4. **The loop at work.** Break things on purpose and watch the controller put them back.

```text
                  you                            the controller
                   │                                   │
  kubectl apply ──▶│  BackupSchedule                   │  watches BackupSchedules
                   │    spec:   what you want  ────────┼─▶ and the CronJobs it owns
                   │    status: what happened  ◀───────┼── writes observations back
                   │                                   │
                   │                                   ▼
                   │                       CronJob ──▶ Job ──▶ Pod (tar the PVC)
```

::remark-box
---
kind: info
---
You don't need to know Go to follow along. All the code is given to you, and every part is explained.
Basic `kubectl` is enough.
::

The playground has a multi-node cluster, and `kubectl` is ready to go on the `dev-machine`.
A `payments` namespace and a PersistentVolumeClaim named `orders-db-data` (the "database" we'll back up) are already there:

```sh
kubectl get pvc -n payments
```

## Part 1: The API

### A CRD is a new table in the API server

Start with the smallest CRD that works:

```sh
cat > ~/backup-operator/config/crd-minimal.yaml <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backupschedules.platform.example.com   # must be <plural>.<group>
spec:
  group: platform.example.com
  scope: Namespaced
  names:
    kind: BackupSchedule
    plural: backupschedules
    singular: backupschedule
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

kubectl apply -f ~/backup-operator/config/crd-minimal.yaml
```

That's it. The API server now serves a new REST endpoint, with no restart and no compiled code:

```sh
kubectl api-resources --api-group=platform.example.com
kubectl get --raw /apis/platform.example.com/v1alpha1 | python3 -m json.tool
```

Create your first BackupSchedule:

```sh
kubectl apply -f - <<'EOF'
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

kubectl get backupschedules -n payments
```

::simple-task
---
:tasks: tasks
:name: verify_crd_minimal
---
#active
Waiting for the CRD and the first BackupSchedule...

#completed
The API server stores BackupSchedules now, just like Pods or ConfigMaps.
::

Now try something silly:

```sh
kubectl apply -f - <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: BackupSchedule
metadata:
  name: nonsense
  namespace: payments
spec:
  schedule: whenever
  retention:
    keepLast: "a lot"
EOF
```

It's accepted. Right now the API server is a very polite database: it stores whatever you give it.
Nothing happens either: no CronJob, no Pod, no backup. **A CRD alone never *does* anything.**
Keep that in mind for Part 2. First, let's make the API strict.

```sh
kubectl delete backupschedule -n payments nonsense
```

### Validation, defaults, and status

Here's the real CRD. Read through it first. The table below explains each piece.

```sh
cat > ~/backup-operator/config/crd-by-hand.yaml <<'EOF'
{{file:../build-a-validated-crd/reference-crd.yaml|strip-comments}}
EOF

kubectl apply -f ~/backup-operator/config/crd-by-hand.yaml
```

| Piece | What the API server does with it |
|---|---|
| `shortNames`, `categories` | `kubectl get bks` and `kubectl get platform` work. Pure convenience, but it's what people actually type. |
| `openAPIV3Schema` with `type`, `required`, `enum`, `minimum`/`maximum`, `minLength`, `pattern` | Rejects bad objects **before** they reach etcd. Unknown fields are pruned. |
| `x-kubernetes-validations` | [CEL](https://kubernetes.io/docs/reference/using-api/cel/) rules for what OpenAPI can't express, like "`repository` is required *only if* `method` is `restic`". The rule sits on `spec` because a rule on `repository` would never run when `repository` is missing. |
| `default` | Fills in missing fields, so every client (and your controller!) sees the same complete object. |
| `retention: default: {}` | The subtle one. Defaults apply only where the parent object exists. Without this, an object with no `retention` block never gets `keepLast: 7`. |
| `subresources: status: {}` | `.status` gets its own endpoint. Users write `spec`, the controller writes `status`, and neither can overwrite the other. |
| `additionalPrinterColumns` | Better `kubectl get` output. Once you define columns, `AGE` is no longer added automatically, so it's listed explicitly. |

Now try to break it. Every one of these should bounce:

```sh
for spec in \
  '{"schedule":"whenever","source":{"pvcName":"x"}}' \
  '{"schedule":"0 2 * * *"}' \
  '{"schedule":"0 2 * * *","source":{"pvcName":"x"},"retention":{"keepLast":90}}' \
  '{"schedule":"0 2 * * *","source":{"pvcName":"x"},"method":"rsync"}' \
  '{"schedule":"0 2 * * *","source":{"pvcName":"x"},"method":"restic"}'
do
  echo "{\"apiVersion\":\"platform.example.com/v1alpha1\",\"kind\":\"BackupSchedule\",\"metadata\":{\"name\":\"bad\",\"namespace\":\"payments\"},\"spec\":$spec}" \
    | kubectl apply --dry-run=server -f - 2>&1 | head -2
  echo
done
```

And look at what the API server filled in for your first object. You never set `method` or `suspend`:

```sh
kubectl get bks -n payments orders-db-nightly -o yaml | grep -A10 '^spec:'
kubectl get bks -n payments
```

::simple-task
---
:tasks: tasks
:name: verify_crd_full
---
#active
Waiting for the CRD to validate and default BackupSchedules...

#completed
Your API now has a contract: bad input is rejected at the door, and good input comes back complete.
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
That fits in a few lines of bash:

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
kubectl get cronjobs -n payments
```

::simple-task
---
:tasks: tasks
:name: verify_naive_controller
---
#active
Waiting for the bash controller to create a CronJob for orders-db-nightly...

#completed
Your BackupSchedule just caused something to happen in the cluster.
::

Change the desired state and watch the actual state follow within a few seconds:

```sh
kubectl patch bks -n payments orders-db-nightly --type=merge -p '{"spec":{"schedule":"30 1 * * *"}}'
kubectl get cronjobs -n payments -w
```

This is the most important idea in Kubernetes. The script never asked *what changed?* It only asked *what should exist?*
That's called **level-triggered** reconciliation, and it's why controllers are so robust: a missed event doesn't matter, because the next pass fixes everything anyway.

Now for its flaws. Create a throwaway schedule, wait for its CronJob, then delete the schedule:

```sh
kubectl apply -f - <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: BackupSchedule
metadata:
  name: throwaway
  namespace: payments
spec:
  schedule: "0 0 * * *"
  source:
    pvcName: orders-db-data
EOF
sleep 8
kubectl delete bks -n payments throwaway
sleep 8
kubectl get cronjobs -n payments
```

`throwaway-backup` is still there, an orphan. The script only knows how to add things. Its other problems:

- **Polling.** It lists every BackupSchedule every 5 seconds, even when nothing changed. Imagine 5,000 of them.
- **No status.** Users have no way to tell whether their schedule was picked up or whether backups succeed.
- **Blind to drift.** If someone edits the CronJob by hand, the script overwrites it only by luck (because `kubectl apply` happens to).
- **No ownership.** Nothing links the CronJob to the BackupSchedule it came from.

A real controller fixes all of that. Stop the script with `Ctrl+C` and clean up after it:

```sh
kubectl delete cronjobs -n payments --all
```

## Part 3: A real controller in Go

### Set up the project

[controller-runtime](https://github.com/kubernetes-sigs/controller-runtime) is the library behind Kubebuilder and Operator SDK.
We'll use it directly, without any scaffolding, so every file is one you wrote and understand.

```sh
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
go version

cd ~/backup-operator
go mod init example.com/backup-operator
go get sigs.k8s.io/controller-runtime@v0.21.0
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.18.0
```

The downloads take a minute. Meanwhile, here's the plan:

```text
backup-operator/
├── api/v1alpha1/              the BackupSchedule type, in Go
├── internal/controller/       the reconcile loop
├── config/                    CRDs (the one you wrote, and one we'll generate)
└── main.go                    wires everything together and starts it
```

### The API, in Go

The controller needs Go structs that mirror the CRD's schema. First, the file that tells the Go client which API group these types belong to:

```sh
mkdir -p api/v1alpha1 internal/controller
cat > api/v1alpha1/groupversion_info.go <<'EOF'
{{file:backup-operator/api/v1alpha1/groupversion_info.go}}
EOF
```

Then the types themselves. Look at the `+kubebuilder:` comments. They're called **markers**, and they should look familiar:

```sh
cat > api/v1alpha1/backupschedule_types.go <<'EOF'
{{file:backup-operator/api/v1alpha1/backupschedule_types.go}}
EOF
```

Each marker is one line of the CRD you wrote by hand: `Enum`, `Minimum`, `default`, `XValidation`, `printcolumn`, `subresource:status`.
The status gained a few fields a controller conventionally reports: `observedGeneration`, `conditions`, and the name of the CronJob it manages.

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
     <(kubectl create --dry-run=client -o yaml -f config/platform.example.com_backupschedules.yaml) | less
```

The whole `spec` schema (validation rules, defaults, the CEL rule) and the names are identical.
The differences are descriptions (taken from the Go comments), the new status fields and `Ready` column,
and small details controller-gen always adds, like `listKind` and `format: int32`.

::remark-box
---
kind: info
---
This is exactly what `kubebuilder` and `make manifests` do. From now on the Go types are the source of truth and the CRD is generated from them.
::

Replace the hand-written CRD with the generated one:

```sh
kubectl apply -f config/platform.example.com_backupschedules.yaml
```

### The reconciler

This is the heart of the operator. Read the comments: the whole design is in them.

```sh
cat > internal/controller/backupschedule_controller.go <<'EOF'
{{file:backup-operator/internal/controller/backupschedule_controller.go}}
EOF
```

Some things worth noticing:

- **`Reconcile` receives only a name.** Not the event, not the diff, not the old object. Just like the bash loop, it looks at the current state and makes it right. It's level-triggered, but it only runs when something relevant changes.
- **`CreateOrUpdate`** reads the CronJob (or starts from an empty one), runs your mutate function, and writes only if something actually changed.
- **`mutateCronJob` touches only fields it owns.** The API server fills in defaults on every object (`imagePullPolicy`, `dnsPolicy`, and many more). If you replaced the whole pod spec, those defaults would disappear from your copy, every reconcile would look like a change, and the controller would send pointless updates.
- **`SetControllerReference`** stamps the CronJob with an owner reference pointing at the BackupSchedule. That fixes the orphan problem, as you'll see.
- **`Owns(&batchv1.CronJob{})`**: when an owned CronJob changes (someone edits it, deletes it, or a backup finishes), the *owner* BackupSchedule gets reconciled.
- The retention policy maps onto the CronJob's `successfulJobsHistoryLimit`: "keep the last N successful backup jobs".

### main.go

```sh
cat > main.go <<'EOF'
{{file:backup-operator/main.go}}
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

You should see the manager start, and a `CronJob reconciled ... "operation": "created"` line.
Leave it running. From now on, use the other terminal tab.

```sh
kubectl get bks,cronjobs -n payments
kubectl get cronjob -n payments orders-db-nightly-backup -o jsonpath='{.metadata.ownerReferences}' | python3 -m json.tool
kubectl get bks -n payments orders-db-nightly -o jsonpath='{.status}' | python3 -m json.tool
```

::simple-task
---
:tasks: tasks
:name: verify_operator_owns_cronjob
---
#active
Waiting for the operator to own the CronJob and report status...

#completed
The CronJob is owned by the BackupSchedule, and the BackupSchedule reports Ready with an up-to-date observedGeneration.
::

## Part 4: The loop at work

Keep the operator's logs in view in one tab and run these experiments in the other.

### Spec changes are picked up, and acknowledged

```sh
kubectl patch bks -n payments orders-db-nightly --type=merge -p '{"spec":{"retention":{"keepLast":5}}}'

kubectl get cronjob -n payments orders-db-nightly-backup -o jsonpath='{.spec.successfulJobsHistoryLimit}{"\n"}'
kubectl get bks -n payments orders-db-nightly \
  -o jsonpath='generation={.metadata.generation} observedGeneration={.status.observedGeneration}{"\n"}'
```

`observedGeneration` catches up with `generation`: that's the controller telling you it has seen this version of your spec.

### Drift is reverted

Edit the CronJob behind the operator's back:

```sh
kubectl patch cronjob -n payments orders-db-nightly-backup --type=merge -p '{"spec":{"schedule":"* * * * *"}}'
kubectl get cronjob -n payments orders-db-nightly-backup -o jsonpath='{.spec.schedule}{"\n"}'
```

It's back to the BackupSchedule's schedule before you can blink. The edit fired a watch event on an *owned* CronJob, which triggered a reconcile of its owner.

### Deleted children come back

```sh
kubectl delete cronjob -n payments orders-db-nightly-backup
kubectl get cronjob -n payments
```

### Suspending reports a condition

```sh
kubectl patch bks -n payments orders-db-nightly --type=merge -p '{"spec":{"suspend":true}}'
kubectl get bks -n payments
kubectl describe bks -n payments orders-db-nightly | tail -n 15
```

`READY` turns `False` with reason `Suspended`, and the Events section shows what the operator did.
Resume it before moving on:

```sh
kubectl patch bks -n payments orders-db-nightly --type=merge -p '{"spec":{"suspend":false}}'
```

### A crashed controller catches up

Stop the operator with `Ctrl+C`. While it's down, change the spec:

```sh
kubectl patch bks -n payments orders-db-nightly --type=merge -p '{"spec":{"schedule":"45 3 * * *"}}'
kubectl get cronjob -n payments orders-db-nightly-backup -o jsonpath='{.spec.schedule}{"\n"}'   # still the old one
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

### Run a real backup

So far no backup has actually run. Make the schedule fire every minute:

```sh
kubectl patch bks -n payments orders-db-nightly --type=merge -p '{"spec":{"schedule":"* * * * *"}}'
kubectl get jobs,pods -n payments -w
```

Within a minute or two a Job runs, the pod mounts the PVC and archives it:

```sh
kubectl logs -n payments -l job-name --tail=5 --prefix
kubectl get bks -n payments
```

When the Job succeeds, the CronJob's `status.lastSuccessfulTime` changes. That's an event on an *owned* object, so the BackupSchedule is reconciled, and its `LAST BACKUP` column fills in.

::simple-task
---
:tasks: tasks
:name: verify_first_backup
---
#active
Waiting for the first backup to finish and show up in the BackupSchedule's status...

#completed
Full loop: spec → CronJob → Job → Pod → CronJob status → BackupSchedule status.
::

Put the nightly schedule back so the cluster isn't archiving every minute:

```sh
kubectl patch bks -n payments orders-db-nightly --type=merge -p '{"spec":{"schedule":"0 2 * * *"}}'
```

### Deletion cleans up after itself

Remember the orphaned CronJob from the bash controller? Create a second schedule:

```sh
kubectl apply -f - <<'EOF'
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
    pvcName: orders-db-data
EOF

kubectl get bks,cronjobs -n payments
```

::simple-task
---
:tasks: tasks
:name: verify_second_schedule
---
#active
Waiting for the operator to create ledger-hourly-backup...

#completed
One BackupSchedule, one owned CronJob.
::

Now delete it:

```sh
kubectl delete bks -n payments ledger-hourly
kubectl get cronjobs -n payments
```

The CronJob is gone too, and the operator did nothing: its `Reconcile` just got a "not found" and returned.
The cleanup was done by Kubernetes' **garbage collector**, which deletes objects whose owner no longer exists.
That's what the owner reference was for.

::simple-task
---
:tasks: tasks
:name: verify_garbage_collected
---
#active
Waiting for ledger-hourly and its CronJob to be gone...

#completed
No orphans this time.
::

## What you built, and what real operators add

You now have every essential piece of an operator:

| Piece | Where |
|---|---|
| An API with a contract: validation, CEL, defaults | CRD (Part 1), generated from Go markers (Part 3) |
| Spec/status separation and `observedGeneration` | status subresource + `r.Status().Update` |
| Level-triggered reconciliation | `Reconcile(ctx, req)` gets a name, not an event |
| Cheap watching | the manager's informer cache |
| Self-healing | `Owns(&batchv1.CronJob{})` |
| Cleanup | owner references + the garbage collector |
| Human-readable feedback | conditions, printer columns, events |

Production operators typically add:

- **Finalizers**, for cleanup the garbage collector can't do: things outside the cluster, like deleting the backups in S3 when a BackupSchedule is removed.
- **RBAC and in-cluster deployment.** A ServiceAccount, a ClusterRole generated from `+kubebuilder:rbac` markers, and a Deployment running the image.
- **Predicates**, such as `GenerationChangedPredicate`, to skip reconciles that can't change anything, like the one triggered by our own status update.
- **Tests** with `envtest`, which runs a real kube-apiserver and etcd, just like the one this tutorial's checks run against.
- **Admission webhooks** for validation or defaulting that CEL can't express.
- **Scaffolding.** [Kubebuilder](https://book.kubebuilder.io/) generates this whole layout (plus Makefiles, Dockerfiles and kustomize) with `kubebuilder init` and `kubebuilder create api`. Now you know what every generated file is for.

::remark-box
---
kind: success
---
Want to test the API design part without the guide? Try the challenge
[Extend the Kubernetes API With a Validated CustomResourceDefinition](/challenges/build-a-validated-crd):
same `BackupSchedule`, no hints until you ask, and a hidden test suite.
::
