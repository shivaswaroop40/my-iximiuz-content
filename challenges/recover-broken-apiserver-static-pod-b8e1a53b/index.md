---
kind: challenge

title: 'CKA Practice: Recover a Broken Static Control-Plane Pod'

description: |
  Every kubectl command against a kubeadm cluster fails, and the workload is still serving. With no API to query, the usual tools tell you nothing. Work from the node itself to find what broke and bring the control plane back.

categories:
- kubernetes

tagz:
- cka
- kubelet
- static-pods
- troubleshooting

difficulty: medium

createdAt: 2026-08-10
updatedAt: 2026-09-02

cover: __static__/cover.png

playground:
  name: k8s-omni

tasks:
  # Seeding is split so a failed init reads from the task list: the slow
  # workload seeding, the instant CA guard, and the fault injection fail
  # separately, each with a timeout sized to what it does.
  init_seed_workload:
    init: true
    machine: cplane-01
    user: root
    timeout_seconds: 900
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf

      # Wait for the kubeadm cluster that the playground provisions.
      for i in $(seq 1 60); do
        [ -f /etc/kubernetes/admin.conf ] && kubectl get ns default >/dev/null 2>&1 && break
        sleep 5
      done
      # Count nodes by their Ready condition, not the STATUS column, so a cordoned
      # node still counts. `|| true` stops a transient API error from aborting the
      # retry loop under `set -o pipefail`.
      count_ready() {
        kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
          | grep -c '^True$' || true
      }
      for i in $(seq 1 60); do
        [ "$(count_ready)" -ge 3 ] && break
        sleep 5
      done
      [ "$(count_ready)" -ge 3 ]

      # Seed a workload so the outage affects something real.
      kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n web create deployment web-backend --image=ghcr.io/iximiuz/labs/nginx:alpine --replicas=2 \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n web wait --for=condition=available deployment/web-backend --timeout=300s

  init_guard_ca:
    init: true
    machine: cplane-01
    user: root
    needs:
      - init_seed_workload
    timeout_seconds: 120
    run: |
      set -euo pipefail
      # Guard value: recreating the cluster changes the CA and fails the attempt.
      openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 > /root/.challenge-ca.sha256
      chmod 600 /root/.challenge-ca.sha256
      # No copy of the good manifest is kept anywhere on this machine. The learner
      # works as root, so any such file would be a one-command bypass of the whole
      # exercise. The checks are state-based, so nothing needs one.

  init_break_apiserver:
    init: true
    machine: cplane-01
    user: root
    needs:
      - init_guard_ca
    timeout_seconds: 480
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      # Inject the fault: a realistic typo in a required flag. The YAML stays valid,
      # the apiserver exits immediately with "unknown flag". Guarded so that a retry
      # of this task cannot run the substitution against an already-broken manifest.
      if grep -q -- '--etcd-servers=' /etc/kubernetes/manifests/kube-apiserver.yaml; then
        sed -i 's|--etcd-servers=|--etcd-severs=|' /etc/kubernetes/manifests/kube-apiserver.yaml
      fi
      grep -q -- '--etcd-severs=' /etc/kubernetes/manifests/kube-apiserver.yaml

      # Wait until the API is actually down; fail init loudly if it never breaks.
      down=0
      for i in $(seq 1 45); do
        if timeout 5 kubectl get ns default >/dev/null 2>&1; then
          down=0
        else
          down=$((down+1))
          [ "$down" -ge 3 ] && break
        fi
        sleep 4
      done
      if [ "$down" -lt 3 ]; then
        echo "init failed: API server did not go down after fault injection"
        exit 1
      fi

  verify_apiserver_recovered:
    machine: cplane-01
    user: root
    needs:
      - init_break_apiserver
    timeout_seconds: 300
    hintcheck: |
      M=/etc/kubernetes/manifests/kube-apiserver.yaml
      if [ ! -f "$M" ]; then
        echo "The kube-apiserver manifest is gone from /etc/kubernetes/manifests/. Deleting it removes the component instead of fixing it; the kubelet only runs static pods whose manifests exist."
        exit 0
      fi
      if ! systemctl is-active kubelet >/dev/null 2>&1; then
        echo "The kubelet is not running on this node. On a kubeadm control plane the kubelet runs every control plane component. Start there: systemctl status kubelet."
        exit 0
      fi
      # `crictl ps` without -a lists running containers only, so this needs no jq.
      RUNNING=$(crictl ps --name kube-apiserver -q 2>/dev/null | head -1)
      if [ -n "$RUNNING" ]; then
        if ! timeout 5 kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw=/readyz >/dev/null 2>&1; then
          echo "The kube-apiserver container is running but not answering yet. Give it a moment, then check: kubectl get --raw=/readyz"
        fi
        exit 0
      fi
      # Below here the apiserver is not running. Say nothing about the cause until
      # the learner has spent time on it. Naming the component and the command on
      # arrival would replace the investigation this challenge exists to teach.
      START=$(stat -c %Y /root/.challenge-ca.sha256 2>/dev/null || echo 0)
      NOW=$(date +%s)
      ELAPSED=$(( NOW - START ))
      if [ "$ELAPSED" -lt 480 ]; then
        exit 0
      fi
      echo "Still stuck? On a kubeadm control plane the kubelet runs the control plane components itself, from manifests on disk. It keeps running even when the API server does not, so ask the node what it is doing rather than asking Kubernetes."
      exit 0
    failcheck: |
      current=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null)
      stored=$(cat /root/.challenge-ca.sha256 2>/dev/null)
      if [ -n "$stored" ] && [ "$current" != "$stored" ]; then
        echo "Constraint violated: the cluster was recreated. The task is to repair the control plane, not rebuild it."
        exit 1
      fi
      export KUBECONFIG=/etc/kubernetes/admin.conf
      if kubectl get ns default >/dev/null 2>&1 && ! kubectl get deployment web-backend -n web >/dev/null 2>&1; then
        echo "Constraint violated: deployment web-backend in namespace web no longer exists."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      [ "$(kubectl get --raw=/readyz)" = "ok" ]

  verify_control_plane_pods:
    machine: cplane-01
    user: root
    needs:
      - verify_apiserver_recovered
    timeout_seconds: 300
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      timeout 5 kubectl get ns default >/dev/null 2>&1 || exit 0
      bad=$(kubectl get pods -n kube-system -l tier=control-plane \
        -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | grep -v '=Running$' | cut -d= -f1 | tr '\n' ' ')
      if [ -n "$bad" ]; then
        echo "Not Running yet: ${bad}. The kubelet republishes a mirror pod for each static pod once the API server accepts writes again. The scheduler and controller-manager may also restart once or twice after an outage; that settles in a minute."
      fi
      exit 0
    failcheck: |
      current=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null)
      stored=$(cat /root/.challenge-ca.sha256 2>/dev/null)
      if [ -n "$stored" ] && [ "$current" != "$stored" ]; then
        echo "Constraint violated: the cluster was recreated."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      # Select by label, not by name. Hardcoding etcd-cplane-01 and friends assumes
      # the node name and a stacked etcd, and a mirror pod that has not been
      # republished yet would abort the check under `set -e`.
      notrunning=$(kubectl get pods -n kube-system -l tier=control-plane \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -cv '^Running$' || true)
      [ "$notrunning" -eq 0 ]
      cp_count=$(kubectl get pods -n kube-system -l tier=control-plane --no-headers | wc -l)
      [ "$cp_count" -ge 3 ]

  verify_cluster_healthy:
    machine: cplane-01
    user: root
    needs:
      - verify_control_plane_pods
    timeout_seconds: 300
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      kubectl get ns default >/dev/null 2>&1 || exit 0
      bad=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}' | head -3)
      [ -n "$bad" ] && echo "kube-system pods not Running yet: ${bad}. The scheduler and controller-manager may restart a few times after an API outage; that settles within a minute or two."
      notready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}')
      [ -n "$notready" ] && echo "Nodes not Ready: ${notready}. Kubelets re-report shortly after the API returns."
      exit 0
    failcheck: |
      current=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null)
      stored=$(cat /root/.challenge-ca.sha256 2>/dev/null)
      if [ -n "$stored" ] && [ "$current" != "$stored" ]; then
        echo "Constraint violated: the cluster was recreated."
        exit 1
      fi
      export KUBECONFIG=/etc/kubernetes/admin.conf
      if kubectl get ns default >/dev/null 2>&1 && ! kubectl get deployment web-backend -n web >/dev/null 2>&1; then
        echo "Constraint violated: deployment web-backend in namespace web no longer exists."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      [ "$(kubectl get --raw=/readyz)" = "ok" ]
      ready=$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' | grep -c '^True$' || true)
      [ "$ready" -ge 3 ]
      avail=$(kubectl -n web get deployment web-backend -o jsonpath='{.status.availableReplicas}')
      [ "${avail:-0}" -ge 2 ]
---

12:41 in the incident channel:

> **@here** kubectl is failing against the training cluster: `The connection to the server 172.16.0.2:6443 was refused`. Deploys are blocked and the dashboard is blank. The VMs are all up, and nobody changed anything (they say). Can someone take a look?

The control plane on **`cplane-01`** is unhealthy. Cluster operations are failing and
workloads are affected. Restore the control plane and return the cluster to a healthy
state.

The plan:

1. Work out what is broken without the API server to help you.
2. Get the API server answering again.
3. Confirm the rest of the control plane came back with it.
4. Confirm the nodes and the workload are healthy.

**Constraints:**

- Repair the control plane. Do not recreate the cluster. A rebuild takes the evidence with it.
- Do not delete or edit the `web-backend` deployment in the `web` namespace.
- Keep the existing cluster CA. Reissuing it fails the attempt.

### Pre-flight

Work on `cplane-01` as root (`sudo -i`).

`kubectl` talks to the API server, and the API server is what is missing, so every
`kubectl` command will fail for the whole first half of this challenge. Everything you
need is on the node:

- `systemctl` and `journalctl` answer for the kubelet, which is a plain systemd unit.
- `crictl` talks to the container runtime over its own socket, so it keeps working.
- `/etc/kubernetes/manifests/` and `/var/log/` are files on disk.

Each step below carries its own hints. Open them only as far as you need.

::hint-box
---
:summary: What runs the control plane
---
On a kubeadm cluster the control plane components are not scheduled. The kubelet on
`cplane-01` runs them directly from manifest files in `/etc/kubernetes/manifests/`.
They are called static pods, and the kubelet owns their whole lifecycle.

That has two consequences worth holding on to:

- The kubelet does not need the API server to run them. If the kubelet is up, it is
  still trying to run the control plane right now.
- The mirror pods you normally see with `kubectl get pods -n kube-system` are only
  read-only copies published to the API. With the API down, they do not exist as far
  as you are concerned.

So the first question is whether the kubelet is healthy: `systemctl status kubelet`.
::

### Step 1: Get the API server answering again

Find the component that is failing, work out why from its own output, and correct it.

This step passes when `kubectl get --raw=/readyz` returns `ok`.

::simple-task
---
:tasks: tasks
:name: verify_apiserver_recovered
---
#active
Waiting for the API server to answer `/readyz`…

#completed
The API server answers `/readyz: ok`.
::

::hint-box
---
:summary: Seeing containers without the API
---
`crictl` speaks to the container runtime over its socket, so it works with the API
server down:

```bash
crictl ps            # running containers
crictl ps -a         # also containers that have exited
```

Compare the two. A component that starts and dies keeps appearing in `crictl ps -a`
with a climbing attempt count, and never appears in `crictl ps`.

**`crictl pods` is a different list.** It shows pod sandboxes, which hold the network
and IPC namespaces. The container runs inside the sandbox and has its own ID. The two
lists never share an ID, and most `crictl` subcommands take one or the other, not
both. Reach for `crictl ps`, not `crictl pods`.
::

::hint-box
---
:summary: Reading the logs of a container that will not stay up
---
```bash
crictl logs <container-id>
```

`logs` takes a **container** ID. Passing it a pod ID from `crictl pods`, or a pod name,
returns `NotFound`, which reads like the container is gone when it is only the wrong
identifier. Take the ID from `crictl ps -a`, or skip the copying:

```bash
crictl logs "$(crictl ps -a --name kube-apiserver -q | head -1)"
```

A process that exits immediately usually explains itself in its last line.

The kubelet garbage-collects exited containers, so that ID can disappear mid-incident.
The logs on disk outlive it:

```bash
ls /var/log/pods/kube-system_kube-apiserver-*/
tail -50 /var/log/containers/kube-apiserver-*.log
```

Know where the kubelet writes container logs. It is the more reliable path.
::

::hint-box
---
:summary: From the error to the manifest
---
The component is failing on its own configuration, before it does any real work.
Read its static pod manifest and compare it line by line against what the error
message named:

```bash
grep -n -- '--etcd' /etc/kubernetes/manifests/kube-apiserver.yaml
```
::

::hint-box
---
:summary: Applying the fix
---
Edit the manifest in place. You do not need to restart anything by hand.

The kubelet watches `/etc/kubernetes/manifests/` and also rescans it on a timer set by
`fileCheckFrequency`, 20 seconds by default, so an edit is picked up shortly after you
save it. Changing the file is how you deploy a change to a static pod.

Give it a moment after that. An API server that answers requests is not yet an API
server that is ready: `/readyz` reports failures for a few seconds while its
post-start hooks finish.
::

### Step 2: Confirm the control plane came back whole

The API server is one of four components on this node. Check that all of them are
running, and meet the objects that represent them:

```bash
kubectl get pods -n kube-system -l tier=control-plane
```

::simple-task
---
:tasks: tasks
:name: verify_control_plane_pods
---
#active
Checking the control plane pods on **cplane-01**…

#completed
Every control plane component is Running.
::

::hint-box
---
:summary: Mirror pods, and why kubectl cannot manage them
---
The control plane pods are back in that listing now. They are **mirror pods**: the
kubelet publishes a read-only copy of each static pod to the API server so that you
can see it. The API server does not manage them. The practical difference:

```bash
kubectl -n kube-system delete pod kube-apiserver-cplane-01
```

That command appears to succeed. It deletes the mirror, the kubelet notices, and the
mirror comes straight back. It never touched the running container. To change or stop
a static pod you edit or move its manifest file, which is what you did in Step 1.

In the exam: `kubectl edit` on a mirror pod is rejected, and
`kubectl delete` on one is close to useless.
::

### Step 3: Confirm the nodes and the workload

Getting the process running is not the same as the cluster being healthy:

```bash
kubectl get nodes
kubectl -n web get deployment web-backend
```

The workload never stopped serving during the outage. This step confirms it, and
confirms the kubelets have re-reported since the API server returned.

::simple-task
---
:tasks: tasks
:name: verify_cluster_healthy
---
#active
Checking nodes and the workload…

#completed
Cluster healthy: all nodes Ready, workload available. Incident closed.
::

Here `kubectl` was dead, so the investigation had to start at the runtime. When the
API server is up and a single node has gone quiet, the investigation runs the other
way, from the control plane down. The sibling challenge in this series,
[Recover a NotReady Node After a Kubelet Configuration
Error](https://labs.iximiuz.com/challenges/recover-notready-node-kubelet-config-af6617e0),
starts from that side.

### Related on iximiuz Labs

Other people's work on the same terrain, worth doing alongside this one:

- [Klustered: Level Three](https://labs.iximiuz.com/challenges/klustered-l3-246fd43f) by Rawkode Academy. Break-and-fix on a sabotaged cluster, the genre this challenge belongs to
- [Take and Restore an etcd Snapshot on a Kubernetes Cluster](https://labs.iximiuz.com/challenges/take-and-restore-etcd-snapshot-on-a-kubernetes-cluster-7ae31fbc) by Omkar Shelke. The other half of control plane recovery: the data, not the process
- [Kubernetes the (Very) Hard Way](https://labs.iximiuz.com/courses/kubernetes-the-very-hard-way-0cbfd997) by Márk Sági-Kazár. Assembling the control plane by hand, which makes a static pod manifest much easier to read
- [Kubernetes Debugging with DebugBox: Right-Sized Containers for Every Scenario](https://labs.iximiuz.com/tutorials/kubernetes-debugging-with-debugbox-74e481c8) by Muhammad Ibtisam. Tooling for the moment `kubectl exec` is not available to you

### References

- [Static pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
- [Troubleshooting clusters](https://kubernetes.io/docs/tasks/debug/debug-cluster/)
- [crictl](https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/)
- [Mirror pods](https://kubernetes.io/docs/reference/glossary/?all=true#term-mirror-pod)
- [Kubernetes API health endpoints](https://kubernetes.io/docs/reference/using-api/health-checks/)
