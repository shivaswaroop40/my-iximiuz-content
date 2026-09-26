---
kind: challenge

title: 'CKA Practice: Recover a NotReady Node After a Kubelet Configuration Error'

description: |
  A worker node dropped to NotReady and part of the workload went with it. The container runtime is fine and the control plane is healthy; the trail leads from kubectl symptoms down into systemd and the kubelet configuration. Diagnose the node and bring it back.

categories:
- kubernetes

tagz:
- cka
- kubelet
- nodes
- troubleshooting

difficulty: easy

createdAt: 2026-08-10
updatedAt: 2026-09-02

cover: __static__/cover.png

playground:
  name: k8s-omni

tasks:
  # Seeding is split so a failed init reads from the task list: the slow part
  # (cluster wait + image pulls) and the instant part (recording the CA guard)
  # fail separately, each with a timeout sized to what it does.
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
      # Count nodes whose Ready condition is True. Reading the condition instead
      # of the STATUS column keeps this correct for a cordoned node, which prints
      # "Ready,SchedulingDisabled". The `|| true` keeps a transient API error from
      # aborting the retry loop under `set -o pipefail`.
      count_ready() {
        kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
          | grep -c '^True$' || true
      }
      for i in $(seq 1 60); do
        [ "$(count_ready)" -ge 3 ] && break
        sleep 5
      done
      [ "$(count_ready)" -ge 3 ]

      # Workload: a spread deployment plus one replica pinned to node-02, so the
      # node failure visibly affects real workload availability.
      kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f - <<EOF
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: web-backend
        namespace: web
      spec:
        replicas: 3
        selector:
          matchLabels:
            app: web-backend
        template:
          metadata:
            labels:
              app: web-backend
          spec:
            containers:
              - name: nginx
                image: ghcr.io/iximiuz/labs/nginx:alpine
                ports:
                  - containerPort: 80
      ---
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: web-canary
        namespace: web
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: web-canary
        template:
          metadata:
            labels:
              app: web-canary
          spec:
            nodeSelector:
              kubernetes.io/hostname: node-02
            containers:
              - name: nginx
                image: ghcr.io/iximiuz/labs/nginx:alpine
                ports:
                  - containerPort: 80
      EOF
      kubectl -n web wait --for=condition=available deployment/web-backend --timeout=300s
      kubectl -n web wait --for=condition=available deployment/web-canary --timeout=300s

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

  init_break:
    init: true
    machine: node-02
    user: root
    needs:
      - init_seed_workload
    timeout_seconds: 600
    run: |
      set -euo pipefail
      CFG=/var/lib/kubelet/config.yaml
      if [ ! -f "$CFG" ]; then
        echo "init failed: $CFG not found on node-02"
        exit 1
      fi

      # Inject a deterministic type error. maxPods is int32, so a quoted string
      # fails KubeletConfiguration strict decoding at startup, before the kubelet
      # touches the runtime or the API. The journal names the file and the field:
      # "cannot unmarshal string into Go struct field KubeletConfiguration.maxPods
      # of type int32".
      #
      # A quoted integer is used on purpose. It is the mistake a person actually
      # makes when hand-editing this file or templating it, and it reads as a
      # plausible value rather than as a planted joke.
      #
      # No backup copy of the good file is kept on the node: the learner has
      # sudo, so anything left in /root is an answer key. The grep guard alone
      # keeps a retry of this task from double-injecting, and node-01 carries
      # the same file for anyone who wants a reference to diff against.
      if ! grep -q '^maxPods:' "$CFG"; then
        # Insert after the apiVersion line so the fault sits mid-file. Appending it
        # would let `tail` reveal the answer without reading the journal.
        sed -i '/^apiVersion:/a maxPods: "110"' "$CFG"
      fi
      systemctl restart kubelet || true

      # The kubelet must be failing for the intended reason.
      ok=""
      for i in $(seq 1 24); do
        state=$(systemctl is-active kubelet || true)
        if [ "$state" != "active" ] && journalctl -u kubelet -n 50 --no-pager 2>/dev/null \
            | grep -q "failed to load kubelet config file"; then
          ok=yes
          break
        fi
        sleep 5
      done
      if [ -z "$ok" ]; then
        echo "init failed: kubelet did not fail on the injected configuration error"
        exit 1
      fi

  # Confirming NotReady needs a cluster view, so it runs on the control plane.
  # A kubeadm worker has no admin kubeconfig, so this cannot be checked from node-02.
  init_confirm:
    init: true
    machine: cplane-01
    user: root
    needs:
      - init_break
    timeout_seconds: 300
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      notready=""
      for i in $(seq 1 36); do
        s=$(kubectl get node node-02 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
        if [ "$s" = "False" ] || [ "$s" = "Unknown" ]; then
          notready=yes
          break
        fi
        sleep 5
      done
      if [ -z "$notready" ]; then
        echo "init failed: node-02 did not become NotReady"
        exit 1
      fi

  # Step 1 asks the node directly, because systemd is the only thing that can
  # answer "is the process running". No kubeconfig is involved.
  verify_kubelet_running:
    machine: node-02
    user: root
    needs:
      - init_confirm
    timeout_seconds: 300
    hintcheck: |
      state=$(systemctl is-active kubelet 2>/dev/null || true)
      if [ "$state" != "active" ]; then
        if journalctl -u kubelet -n 50 --no-pager 2>/dev/null | grep -q "failed to load kubelet config file"; then
          echo "systemd reports the kubelet as '${state}'. It exits while loading its configuration, so systemd starts it again, and again. Read one restart cycle in the journal: journalctl -u kubelet -n 50 --no-pager | grep -i config"
        else
          echo "systemd reports the kubelet as '${state}'. The journal holds the reason: journalctl -u kubelet -n 100 --no-pager"
        fi
      fi
      exit 0
    failcheck: |
      if [ ! -f /var/lib/kubelet/config.yaml ]; then
        echo "Constraint violated: /var/lib/kubelet/config.yaml no longer exists. Repair the file, do not delete it."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      # A crash-looping kubelet reports "active" for the moment it takes to
      # load its configuration and exit, which is long enough to fool a
      # single sample. Require the same process to stay up across a window.
      [ "$(systemctl is-active kubelet)" = "active" ]
      pid=$(systemctl show kubelet -p MainPID --value)
      [ "${pid:-0}" -gt 0 ]
      sleep 15
      [ "$(systemctl is-active kubelet)" = "active" ]
      [ "$(systemctl show kubelet -p MainPID --value)" = "$pid" ]

  verify_node_ready:
    machine: cplane-01
    user: root
    needs:
      - verify_kubelet_running
    timeout_seconds: 300
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      timeout 5 kubectl get ns default >/dev/null 2>&1 || exit 0
      s=$(kubectl get node node-02 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
      if [ "$s" != "True" ]; then
        msg=$(kubectl get node node-02 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.message}{end}' 2>/dev/null || true)
        echo "node-02 Ready=${s:-unknown}. The API only reports what the node last told it: \"${msg}\". The node stopped reporting, so the next evidence is on the node itself. Open a shell there and ask systemd about the kubelet."
        exit 0
      fi
      if [ "$(kubectl get node node-02 -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)" = "true" ]; then
        echo "node-02 is Ready again, but it is still cordoned, so the scheduler will not place anything on it. That is a state you set, not a fault: compare 'kubectl get nodes' with '.spec.unschedulable'."
      fi
      exit 0
    failcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      if timeout 5 kubectl get ns default >/dev/null 2>&1 && ! kubectl get node node-02 >/dev/null 2>&1; then
        echo "Constraint violated: node-02 was removed from the cluster. Repair the node, do not replace it."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      # Read the Ready condition, not the STATUS column. A cordoned node prints
      # "Ready,SchedulingDisabled", and cordoning a sick node is normal practice.
      s=$(kubectl get node node-02 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')
      [ "$s" = "True" ]

  verify_workload_healthy:
    machine: cplane-01
    user: root
    needs:
      - verify_node_ready
    timeout_seconds: 600
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      kubectl get ns default >/dev/null 2>&1 || exit 0
      cavail=$(kubectl -n web get deployment web-canary -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
      if [ "${cavail:-0}" -lt 1 ]; then
        if [ "$(kubectl get node node-02 -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)" = "true" ]; then
          echo "web-canary is pinned to node-02, and node-02 is cordoned, so the scheduler will not place it there. The node is healthy; it is just marked unschedulable."
        else
          echo "web-canary is pinned to node-02 and has no available replica yet. Check 'kubectl get pods -n web -o wide': pods evicted during the outage are replaced automatically once the node is Ready, but a stuck Terminating pod can be deleted to speed things up."
        fi
      fi
      exit 0
    failcheck: |
      current=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null)
      stored=$(cat /root/.challenge-ca.sha256 2>/dev/null)
      if [ -n "$stored" ] && [ "$current" != "$stored" ]; then
        echo "Constraint violated: the cluster was recreated."
        exit 1
      fi
      export KUBECONFIG=/etc/kubernetes/admin.conf
      if kubectl get ns default >/dev/null 2>&1; then
        for d in web-backend web-canary; do
          if ! kubectl get deployment "$d" -n web >/dev/null 2>&1; then
            echo "Constraint violated: deployment ${d} in namespace web no longer exists."
            exit 1
          fi
        done
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      ready=$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' | grep -c '^True$' || true)
      [ "$ready" -ge 3 ]
      avail=$(kubectl -n web get deployment web-backend -o jsonpath='{.status.availableReplicas}')
      [ "${avail:-0}" -ge 3 ]
      cavail=$(kubectl -n web get deployment web-canary -o jsonpath='{.status.availableReplicas}')
      [ "${cavail:-0}" -ge 1 ]
      # jsonpath over all matching items, so an empty list gives an empty string
      # instead of an "array index out of bounds" error from kubectl.
      nodes=$(kubectl -n web get pods -l app=web-canary --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
      echo "$nodes" | grep -qx 'node-02'
---

The alert fired eleven minutes ago and has not cleared:

> **NodeNotReady** `node-02` condition `Ready` is `Unknown`. Workload availability in namespace `web` degraded: `web-canary` 0/1 available.

**`node-02`** has become NotReady and the workload running on it is affected. Investigate the node and restore it to a healthy Ready state.

The other nodes and the control plane are healthy, and they should stay that way. Whatever went wrong is local to `node-02`.

The plan:

1. Read what the control plane knows, and work out what it cannot know.
2. Get the kubelet process running again on the node.
3. Get the node reporting Ready to the API server.
4. Confirm the workload came back.

**Constraints:**

- Repair `node-02`. Do not delete it, drain it permanently, or replace it.
- Do not delete or edit the deployments in the `web` namespace.
- Do not recreate the cluster.
- If you cordon the node while you work, uncordon it before you finish.

### Three states that look the same from a distance

A NotReady node is a symptom, not a diagnosis. The kubelet passes through three
states, and a node can fail at any of them:

1. **The process runs.** `systemctl` reports `active`. This says nothing about Kubernetes.
2. **The process initialised.** The kubelet parsed its configuration, reached the container runtime, and started its control loops.
3. **The node reports Ready.** The kubelet posts node status to the API server, and keeps posting it.

Troubleshooting a NotReady node means working out which of the three the node
failed to reach. The API server only knows what the node last told it, so once a
node stops reporting, the next evidence lives on the node itself.

### Pre-flight

Start from the cluster view on **`cplane-01`**:

```bash
kubectl get nodes -o wide
kubectl describe node node-02
kubectl get pods -n web -o wide
```

Read the `Ready` condition and its message before you go anywhere else.

The pod list can look healthier than the deployment. For the first five minutes
after a node goes quiet, the `web-canary` pod on `node-02` still shows `Running`
while its deployment reports `0/1` available. The API server is showing you the
node's last report, because nothing has arrived to replace it. The node controller
marks the pod not ready straight away, but it only evicts it, and the listing only
flips to `Terminating`, once the default 300-second `unreachable` toleration runs
out. Both views are true. They disagree because the control plane only knows what
the node last told it.

Each step below carries its own hints. Open them only as far as you need.

::hint-box
---
:summary: Reading the Ready condition
---
`kubectl describe node node-02` prints the `Ready` condition with a `reason` and a
`message`. A node that stopped reporting shows
`reason: NodeStatusUnknown` and `message: Kubelet stopped posting node status`.

Read that literally. The control plane is not saying the node is broken. It is
saying the node went quiet. The node lease in the `kube-node-lease` namespace
stopped being renewed, so after 40 seconds the node controller marked the node
`Unknown`. Nothing on the control plane can tell you why. The next evidence is on
the node.
::

### Step 1: Get the kubelet process running

The control plane has told you everything it can. The rest of the evidence is on the
node:

```bash
ssh node-02
sudo -i
```

This step passes when systemd reports the kubelet as `active`. First of the three
states, and the one you fix directly.

::simple-task
---
:tasks: tasks
:name: verify_kubelet_running
---
#active
Waiting for the kubelet on **node-02** to stay running…

#completed
The kubelet on **node-02** is active.
::

::hint-box
---
:summary: Asking systemd about the kubelet
---
The kubelet is a systemd unit on the node, not a pod:

```bash
systemctl status kubelet
systemctl is-active kubelet
```

Read the state word carefully, because three of them mean different things:

- `active (running)`: the process is up. It may still be failing to do its job.
- `activating (auto-restart)`: it starts, exits, and systemd restarts it. A crash loop.
- `failed`: it exited and systemd gave up restarting it.

`activating (auto-restart)` is the interesting one. Something makes the kubelet
exit very early, every time.
::

::hint-box
---
:summary: Reading the kubelet journal
---
```bash
journalctl -u kubelet -n 100 --no-pager
```

In a restart loop the journal repeats the same short block. Find one restart
boundary and read the lines above it. Those are the real error. Everything below is
systemd starting the process again.

The kubelet loads its configuration file before it contacts the runtime or the API
server, so a configuration failure appears at the very top of each attempt and
nothing else gets a chance to log.
::

::hint-box
---
:summary: Where the kubelet's configuration comes from
---
The kubelet does not read a fixed path. systemd passes it one:

```bash
systemctl cat kubelet | grep -- --config
```

On a kubeadm node the drop-in points at `/var/lib/kubelet/config.yaml`. That file is
a `KubeletConfiguration` object, and it is strictly decoded, so a value of the wrong
type stops startup.

`node-01` is healthy and has the same file. Comparing the two is a fast way to see
what changed:

```bash
ssh node-01 sudo cat /var/lib/kubelet/config.yaml > /tmp/node-01.yaml
diff /tmp/node-01.yaml /var/lib/kubelet/config.yaml
```
::

### Step 2: Get the node reporting Ready

A running process is not a healthy node. Once the kubelet starts cleanly it
re-registers and begins posting status again, which takes a few seconds. Watch it
flip from `cplane-01`:

```bash
kubectl get nodes -w
```

You should not need to do anything else here. If the node stays NotReady after the
kubelet has been `active` for a minute, the process is running but not initialising,
which is the second of the three states.

::simple-task
---
:tasks: tasks
:name: verify_node_ready
---
#active
Waiting for **node-02** to report Ready…

#completed
**node-02** reports Ready again.
::

::hint-box
---
:summary: Still NotReady after the kubelet came up
---
Separate two cases:

- **The kubelet is active but the node never reports.** Read the journal again after
  the restart. A kubelet can start, fail to reach the container runtime or the API
  server, and keep running while it retries.
- **The node reports Ready but nothing schedules on it.** That is a cordon, not a
  fault. `kubectl get nodes` prints `Ready,SchedulingDisabled`, and `.spec.unschedulable`
  is `true`. It is cleared by the inverse of whatever set it.

This challenge judges the node on its `Ready` condition, so a cordoned but healthy
node still passes this step. It will stop you in Step 3, where the workload has to
land back on the node.
::

### Step 3: Confirm the workload recovered

A Ready node does not by itself mean the workload recovered. Confirm that too:

```bash
kubectl get pods -n web -o wide
kubectl -n web get deployment web-backend web-canary
```

`web-canary` is pinned to `node-02`, so it can only become available once the node is
both Ready and schedulable.

::simple-task
---
:tasks: tasks
:name: verify_workload_healthy
---
#active
Checking deployments and pod placement…

#completed
All nodes Ready, both deployments fully available, canary back on **node-02**. Node recovered.
::

### Related on iximiuz Labs

More on the same terrain, worth doing alongside this one:

- [Recover a Broken Static Control-Plane Pod](https://labs.iximiuz.com/challenges/recover-broken-apiserver-static-pod-b8e1a53b), the sibling challenge in this series. Here `kubectl` still worked, so you could start on the control plane and descend; there the API server itself is down, and you start at the container runtime instead
- [Klustered: Level Three](https://labs.iximiuz.com/challenges/klustered-l3-246fd43f) by Rawkode Academy. Break-and-fix on a sabotaged cluster, where nobody tells you which layer failed
- [Diagnose Why a DaemonSet Skips the Control Plane Node](https://labs.iximiuz.com/challenges/diagnose-why-daemonset-skips-the-control-plane-node-61e8e69b) by Omkar Shelke. The other direction: the node is fine and the workload still will not land on it
- [Provisioning a Kubernetes Cluster with kubeadm](https://labs.iximiuz.com/tutorials/provision-k8s-kubeadm-900d1e53) by Márk Sági-Kazár. Where `/var/lib/kubelet/config.yaml` comes from in the first place

### References

- [Kubelet configuration file](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/)
- [KubeletConfiguration reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [Troubleshooting clusters](https://kubernetes.io/docs/tasks/debug/debug-cluster/)
- [Node status and conditions](https://kubernetes.io/docs/reference/node/node-status/)
- [Reconfigure a node's kubelet in a live cluster](https://kubernetes.io/docs/tasks/administer-cluster/reconfigure-kubelet/)
