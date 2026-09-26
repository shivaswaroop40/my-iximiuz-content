## Reference solution

### Investigation

From `cplane-01`:

```bash
kubectl get nodes
# node-02   NotReady
kubectl describe node node-02
# Ready condition Unknown, reason NodeStatusUnknown: "Kubelet stopped posting node status"
kubectl get pods -n web -o wide
# web-canary pod on node-02 affected
```

The node stopped reporting. Onto the node:

```bash
ssh node-02
sudo systemctl status kubelet
# activating (auto-restart) / failed: systemd keeps restarting it
sudo journalctl -u kubelet -n 100 --no-pager | tail -5
# "command failed" err="failed to load kubelet config file, path: /var/lib/kubelet/config.yaml,
#  error ... cannot unmarshal string into Go struct field KubeletConfiguration.maxPods of type int32"
```

The journal names the file and the field. Look at it:

```bash
sudo grep -n maxPods /var/lib/kubelet/config.yaml
# 2:maxPods: "110"
```

`maxPods` is an `int32` field. The quoted value makes it a string, and
`KubeletConfiguration` is strictly decoded, so startup stops there. The value looks
reasonable, which is why this mistake survives review.

Where the path came from, if you want to confirm it:

```bash
systemctl cat kubelet | grep -- --config
```

### Fix

Correct the value, then restart. The kubelet reads this file only at startup, so
editing it changes nothing until the unit restarts:

```bash
sudo sed -i 's/^maxPods: "110"$/maxPods: 110/' /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
sudo systemctl is-active kubelet    # active
```

Deleting the line works equally well, because `maxPods` has a default of 110. The
checks are state-based, so any legitimate fix passes. Nothing compares the file
against a stored copy.

Comparing with the healthy `node-01` is an equally valid diagnosis path:

```bash
ssh node-01 sudo cat /var/lib/kubelet/config.yaml > /tmp/node-01.yaml
diff /tmp/node-01.yaml /var/lib/kubelet/config.yaml
```

### Verify

Back on `cplane-01`:

```bash
kubectl get nodes                   # node-02 Ready again
kubectl get pods -n web -o wide     # canary replacement lands on node-02
kubectl -n web get deployment web-backend web-canary   # 3/3 and 1/1
```

If a pod from the outage window is stuck Terminating, deleting it is safe; the deployment replaces it.

