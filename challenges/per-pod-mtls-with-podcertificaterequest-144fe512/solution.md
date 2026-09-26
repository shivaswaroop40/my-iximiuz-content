## Reference solution

### Investigation

From `cplane-01`:

```bash
kubectl -n payments get pods -o wide
# payments-api-...   0/1  ContainerCreating   (and has never been anything else)
# checkout-...       1/1  Running

kubectl -n payments describe $(kubectl -n payments get pod -l app=payments-api -o name | head -1) | tail -5
# Warning  FailedMount  ...  credential bundle is not issued yet
```

`describe` needs a concrete pod here: with a label selector it drops the
`Events:` section, and the event is the whole story.

Not a crash loop, a wait. A pod with a `podCertificate` projected volume does not
start until every certificate in it has been issued. Look at what it is waiting on:

```bash
kubectl -n payments get podcertificaterequests -o wide
# NAME        PODNAME           SERVICEACCOUNTNAME  NODENAME  SIGNERNAME                          STATE
# req-4x8pq   payments-api-...  payments-api        node-01   pki.example.com/workload-identity   Pending
```

The request exists and carries no condition, so nothing has answered it. Kubernetes
never will: it records the request and stops there. Something else has to write a
certificate back.

That something is running, and healthy:

```bash
systemctl status pod-identity-signer
journalctl -u pod-identity-signer -n 5 --no-pager
# pod-identity-signer starting: signer=pki.example.com/workload-identity-v2 ca=/etc/pod-identity-signer
```

There it is. The signer watches `pki.example.com/workload-identity-v2`; the pods ask
for `pki.example.com/workload-identity`. Both halves are working perfectly and
neither is talking to the other. A signer only answers requests carrying its own
name, so every request sits untouched.

```bash
systemctl cat pod-identity-signer
# Environment=SIGNER_NAME=pki.example.com/workload-identity-v2
```

### Fix

**1. Make the two names agree.** Either side can move. Pointing the signer at the
name the workload already asks for leaves the workload manifests alone:

```bash
sudo mkdir -p /etc/systemd/system/pod-identity-signer.service.d
sudo tee /etc/systemd/system/pod-identity-signer.service.d/override.conf <<'EOF'
[Service]
Environment=SIGNER_NAME=pki.example.com/workload-identity
EOF
sudo systemctl daemon-reload
sudo systemctl restart pod-identity-signer
```

`daemon-reload` matters: systemd runs the unit it loaded earlier, so a restart
without it re-runs the old configuration.

Editing the deployments to ask for `-v2` instead works equally well. The check is
state-based and judges the outcome, so either fix passes.

The pending requests are answered within seconds, and the pods start:

```bash
kubectl -n payments get podcertificaterequests -o wide   # Issued
kubectl -n payments get pods -o wide                     # 2/2 Running
```

**2. The client's identity.** Add the volume and its mount to `checkout`:

```bash
kubectl -n payments edit deployment checkout
```

```yaml
      volumes:
        - name: pod-identity
          projected:
            sources:
              - podCertificate:
                  signerName: pki.example.com/workload-identity
                  keyType: ECDSAP256
                  keyPath: tls.key
                  certificateChainPath: tls.crt
                  maxExpirationSeconds: 3600
```

```yaml
          volumeMounts:
            - name: pod-identity
              mountPath: /var/run/pod-identity
              readOnly: true
```

Check what it was given:

```bash
kubectl -n payments get podcertificaterequests -o json \
  | jq -r '.items[] | select(.spec.serviceAccountName=="checkout") | .status.certificateChain' \
  | openssl x509 -noout -ext subjectAltName
# URI:spiffe://cluster.local/ns/payments/sa/checkout, DNS:checkout.payments.svc.cluster.local, ...
```

**3. Enforcement.** Up to here nothing verifies anything. `payments-api` serves
whoever connects:

```bash
POD=$(kubectl -n payments get pod -l app=checkout -o name | head -1)
kubectl -n payments exec ${POD#pod/} -- \
  curl -sS --cacert /etc/pod-identity/ca.crt https://payments-api.payments.svc:8443/
# payments-api ok
# client-verify=NONE
```

Edit the server's configuration:

```bash
kubectl -n payments edit configmap payments-api-nginx
```

```
      ssl_client_certificate /etc/pod-identity/ca.crt;
      ssl_verify_client on;
```

nginx reads its configuration at startup and a ConfigMap update restarts nothing:

```bash
kubectl -n payments rollout restart deployment payments-api
kubectl -n payments rollout status deployment payments-api
```

### Verify

```bash
POD=$(kubectl -n payments get pod -l app=checkout -o name | head -1)

kubectl -n payments exec ${POD#pod/} -- curl -sS \
  --cacert /etc/pod-identity/ca.crt \
  --cert /var/run/pod-identity/tls.crt --key /var/run/pod-identity/tls.key \
  https://payments-api.payments.svc:8443/
# payments-api ok
# client-verify=SUCCESS

kubectl -n payments exec ${POD#pod/} -- curl -sS \
  --cacert /etc/pod-identity/ca.crt https://payments-api.payments.svc:8443/
# 400 No required SSL certificate was sent
```

Same pod, same network path, same DNS name. The only difference is whether it
presented an identity the cluster issued it.
