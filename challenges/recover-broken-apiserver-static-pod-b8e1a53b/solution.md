## Reference solution

### Investigation

From anywhere with a kubeconfig:

```bash
kubectl get nodes
# The connection to the server ... was refused
```

The API refuses connections, so the answer is on the control-plane node. SSH to `cplane-01` and become root:

```bash
sudo -i
systemctl status kubelet          # active (running): the kubelet is fine
crictl ps                         # etcd, scheduler, controller-manager present; no apiserver
crictl ps -a --name kube-apiserver
# state Exited, ATTEMPT counter climbing: a crashloop
```

Use `crictl ps`, not `crictl pods`. The second lists pod sandboxes, whose IDs no
container subcommand accepts.

Read the logs of the newest attempt:

```bash
crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -3
# Error: unknown flag: --etcd-severs
```

If the kubelet has already garbage-collected that container, the same output is on
disk and survives:

```bash
tail -5 /var/log/containers/kube-apiserver-cplane-01_kube-system_kube-apiserver-*.log
```

The apiserver rejects its own command line. Static pod manifests live in `/etc/kubernetes/manifests/`:

```bash
grep etcd-severs /etc/kubernetes/manifests/kube-apiserver.yaml
#    - --etcd-severs=https://127.0.0.1:2379
```

### Fix

Open the manifest and correct the flag name:

```bash
vi /etc/kubernetes/manifests/kube-apiserver.yaml
# - --etcd-severs=https://127.0.0.1:2379
# becomes
# - --etcd-servers=https://127.0.0.1:2379
```

Edit the file. A `sed` substitution works too, but it presupposes that you already
know the exact typo, and in the exam you will be reading the manifest, not
pattern-matching against a string you were given.

No restart is needed. The kubelet watches the manifests directory and also rescans it
on a timer set by `fileCheckFrequency` (20 seconds by default), so the change is
picked up shortly after the file is saved. For a static pod the manifest file is what
the kubelet acts on, so editing the file is how you deploy a change.

A practical habit: copy the manifest before you edit it, and keep the copy somewhere
outside `/etc/kubernetes/manifests/`. A stray file inside that directory is itself a
static pod definition, and the kubelet will try to run it.

### Verify

```bash
kubectl get --raw=/readyz          # ok
kubectl get nodes                  # all Ready
kubectl get pods -n kube-system    # control plane pods Running
kubectl -n web get deployment web-backend   # 2/2
```

The scheduler and controller-manager may show a restart or two from the outage window; they recover on their own.

