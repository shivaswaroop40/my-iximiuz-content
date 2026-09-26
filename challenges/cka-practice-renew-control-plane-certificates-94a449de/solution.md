## Reference solution

All commands run on `cplane-01` as root, unless stated otherwise. Set the kubeconfig
explicitly, because kubeadm does not create one for root:

```bash
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.conf
```

### Step 1: Diagnose and renew

kubectl is down, so read the certificates from disk:

```bash
kubeadm certs check-expiration
# warns about falling back to default configuration (the API is down; that is fine)
# apiserver, controller-manager.conf, and scheduler.conf show RESIDUAL TIME
# <invalid>; every other row has only a few days left

kubeadm certs renew all
kubeadm certs check-expiration
# every certificate now shows about a year
```

`renew all` refreshes the certificate files under `/etc/kubernetes/pki/` and the client certificates embedded in `admin.conf`, `controller-manager.conf`, and `scheduler.conf`.

### Step 2: Bring the control plane back

Nothing crashed, so there is nothing to wait for. The API server loaded the expired
certificate and served it; the clients are what refused it. The serving certificate is
picked up without a restart, but the controller-manager and the scheduler read their
kubeconfig only at startup and are still holding the expired one. Restart the control
plane static pods:

```bash
mkdir -p /tmp/manifests
mv /etc/kubernetes/manifests/*.yaml /tmp/manifests/
sleep 10
mv /tmp/manifests/*.yaml /etc/kubernetes/manifests/

# wait for the apiserver to come back
until kubectl get ns default >/dev/null 2>&1; do sleep 3; done

echo | openssl s_client -connect localhost:6443 2>/dev/null | openssl x509 -noout -enddate
# now the renewed date

# and confirm the other two components are talking to the API server again;
# the default table has no renew column, so ask for it
kubectl -n kube-system get lease kube-controller-manager kube-scheduler \
  -o custom-columns=NAME:.metadata.name,RENEW:.spec.renewTime
# RENEW should be seconds ago, not minutes
```

Stopping the containers with `crictl stop` works too. Deleting the mirror pods with
kubectl does not.

### Step 3: Restore laborant's access

Even with the control plane back, kubectl as laborant fails with `the server has asked for the client to provide credentials`: the client certificate inside `~/.kube/config` is an expired copy. Replace it with the renewed admin.conf:

```bash
sudo cp /etc/kubernetes/admin.conf /home/laborant/.kube/config
sudo chown laborant:laborant /home/laborant/.kube/config
sudo chmod 600 /home/laborant/.kube/config
kubectl get ns default    # works as laborant again
```

### Step 4: Verify

```bash
kubectl get nodes                       # all Ready
kubectl -n web get deployment web-backend   # 2/2 available
```

