---
kind: challenge

title: 'Issue Per-Pod mTLS Certificates with PodCertificateRequest'

description: |
  Kubernetes 1.37 can hand every pod its own short-lived X.509 identity, no service mesh and no sidecar involved. The API is served out of the box, but it issues nothing without a signer, and a request nobody answers leaves the pod waiting forever. Get a stalled workload its certificates, give its client an identity of its own, and make the server actually enforce mutual TLS.

categories:
- kubernetes
- security

tagz:
- mtls
- certificates
- pki
- workload-identity

difficulty: medium

createdAt: 2026-08-20
updatedAt: 2026-09-02

cover: __static__/cover.png

playground:
  name: k8s-omni

tasks:
  init_seed:
    init: true
    machine: cplane-01
    user: root
    timeout_seconds: 1500
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf

      # Wait for the kubeadm cluster that the playground provisions.
      for i in $(seq 1 60); do
        [ -f /etc/kubernetes/admin.conf ] && kubectl get ns default >/dev/null 2>&1 && break
        sleep 5
      done
      count_ready() {
        kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
          | grep -c '^True$' || true
      }
      for i in $(seq 1 60); do
        [ "$(count_ready)" -ge 3 ] && break
        sleep 5
      done
      [ "$(count_ready)" -ge 3 ]

      # The signer needs to build certificates from a bare public key, which the
      # openssl CLI on this image cannot date precisely enough. python3-cryptography
      # ships with the playground; fail loudly rather than hand over a broken lab.
      python3 -c 'import cryptography' || {
        echo "init failed: python3 cryptography module is missing on cplane-01"
        exit 1
      }

      ############################################################
      # The workload CA. The platform team's, not the cluster's.
      ############################################################
      mkdir -p /etc/pod-identity-signer
      cd /etc/pod-identity-signer
      if [ ! -f ca.key ]; then
        openssl ecparam -name prime256v1 -genkey -noout -out ca.key
        openssl req -x509 -new -key ca.key -sha256 -days 3650 \
          -subj "/CN=pod-identity-ca" -out ca.crt
      fi
      chmod 600 ca.key

      ############################################################
      # The signer controller.
      #
      # Kubernetes issues no pod certificates on its own: the kubelet generates a
      # key, files a PodCertificateRequest naming a signer, and then waits. This
      # is the thing that answers. It is deliberately small enough to read.
      ############################################################
      # The signer lives in __static__ rather than inline here. A 180-line Python
      # program inside a YAML block scalar is one re-indentation away from being
      # silently mangled, and it cannot be linted or run on its own.
      # Note the per-content URL: the global https://labs.iximiuz.com/__static__/<file>
      # form returns 404, including for published content, so assets are fetched
      # from /content/files/challenges/<name>/__static__/<file> instead.
      # --no-cache plus a cache-buster so a re-pushed signer is picked up on the
      # next challenge start instead of a stale cached copy.
      wget --no-cache -q "https://labs.iximiuz.com/content/files/challenges/per-pod-mtls-with-podcertificaterequest-144fe512/__static__/pod-identity-signer.py?t=$(date +%s)" \
        -O /usr/local/bin/pod-identity-signer
      [ -s /usr/local/bin/pod-identity-signer ] || {
        echo "init failed: could not fetch the signer from __static__"
        exit 1
      }
      chmod 755 /usr/local/bin/pod-identity-signer

      # The fault. The signer answers one signer name and the workload asks for
      # another, so it starts cleanly, logs that it is watching, and never sees a
      # single request. This is the shape of a real rename that got applied to one
      # side only.
      cat > /etc/systemd/system/pod-identity-signer.service <<'UNITEOF'
      [Unit]
      Description=Workload identity signer for PodCertificateRequest
      After=network-online.target

      [Service]
      Environment=SIGNER_NAME=pki.example.com/workload-identity-v2
      ExecStart=/usr/local/bin/pod-identity-signer
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
      UNITEOF
      systemctl daemon-reload
      systemctl enable --now pod-identity-signer
      systemctl restart pod-identity-signer

      ############################################################
      # The workload.
      ############################################################
      kubectl create namespace payments --dry-run=client -o yaml | kubectl apply -f -
      for sa in payments-api checkout; do
        kubectl -n payments create serviceaccount "$sa" --dry-run=client -o yaml | kubectl apply -f -
      done

      # The trust anchor. Pods need it to verify the other end; it is public, so a
      # ConfigMap is the right place for it.
      kubectl -n payments create configmap pod-identity-ca \
        --from-file=ca.crt=/etc/pod-identity-signer/ca.crt \
        --dry-run=client -o yaml | kubectl apply -f -

      wget --no-cache -q "https://labs.iximiuz.com/content/files/challenges/per-pod-mtls-with-podcertificaterequest-144fe512/__static__/pod-certificates-workload.yaml?t=$(date +%s)" \
        -O /tmp/pod-certificates-workload.yaml
      [ -s /tmp/pod-certificates-workload.yaml ] || {
        echo "init failed: could not fetch the workload manifests from __static__"
        exit 1
      }
      kubectl apply -f /tmp/pod-certificates-workload.yaml

      # The manifest the platform team wrote, kept on disk the way it would be kept
      # in a repository. It is applied exactly as they applied it, and the API server
      # will quietly accept a version of it that is missing the only part that matters.
      wget --no-cache -q "https://labs.iximiuz.com/content/files/challenges/per-pod-mtls-with-podcertificaterequest-144fe512/__static__/pod-certificates-payments-api.yaml?t=$(date +%s)" \
        -O /home/laborant/payments-api.yaml
      [ -s /home/laborant/payments-api.yaml ] || {
        echo "init failed: could not fetch the payments-api manifest from __static__"
        exit 1
      }
      # The learner works as laborant, so the manifest has to be readable by
      # laborant. Only the guard files below belong in /root.
      chown laborant:laborant /home/laborant/payments-api.yaml
      chmod 644 /home/laborant/payments-api.yaml
      kubectl apply -f /home/laborant/payments-api.yaml

      # The client has no certificate of its own yet, so it must come up normally.
      kubectl -n payments rollout status deployment/checkout --timeout=300s

      # Pod certificates are GA and served by default from Kubernetes 1.37. If this
      # cluster does not serve the resource, it is too old for this challenge and
      # nothing below will make sense, so fail here rather than later.
      served=$(kubectl api-resources --api-group=certificates.k8s.io 2>/dev/null \
        | grep -c podcertificaterequests || true)
      if [ "${served:-0}" -eq 0 ]; then
        echo "init failed: this cluster does not serve podcertificaterequests (needs Kubernetes 1.37+)"
        exit 1
      fi

      # The starting state, verified rather than assumed. The kubelet files a
      # request for every projected pod certificate and then waits: no signer
      # answers this one, so the request stays Pending and the pod never starts.
      broken=""
      for i in $(seq 1 36); do
        avail=$(kubectl -n payments get deployment payments-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
        pending=$(kubectl -n payments get podcertificaterequests -o json 2>/dev/null \
          | jq '[.items[] | select((.status.conditions // []) | length == 0)] | length')
        if [ "${avail:-0}" -eq 0 ] && [ "${pending:-0}" -ge 1 ]; then
          broken=yes
          break
        fi
        sleep 5
      done
      if [ -z "$broken" ]; then
        echo "init failed: payments-api did not end up waiting on an unanswered certificate request"
        exit 1
      fi

      # Guard values. Recreating the cluster or swapping the workload CA fails the
      # attempt, and the checks below compare against these.
      openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 > /root/.challenge-ca.sha256
      openssl x509 -in /etc/pod-identity-signer/ca.crt -noout -fingerprint -sha256 > /root/.challenge-workload-ca.sha256
      chmod 600 /root/.challenge-ca.sha256 /root/.challenge-workload-ca.sha256

  verify_certs_issued:
    machine: cplane-01
    user: root
    needs:
      - init_seed
    timeout_seconds: 900
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      timeout 10 kubectl get ns default >/dev/null 2>&1 || exit 0
      avail=$(kubectl -n payments get deployment payments-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
      [ "${avail:-0}" -ge 2 ] && exit 0
      pend=$(kubectl -n payments get podcertificaterequests -o json 2>/dev/null \
        | jq '[.items[] | select((.status.conditions // []) | length == 0)] | length')
      if [ "${pend:-0}" -gt 0 ]; then
        asked=$(kubectl -n payments get podcertificaterequests -o json 2>/dev/null \
          | jq -r '[.items[] | select((.status.conditions // []) | length == 0) | .spec.signerName] | unique | join(", ")')
        echo "${pend} PodCertificateRequest(s) are waiting for an answer, for signer(s): ${asked}. Kubernetes ships no CA for this and never answers a request itself: something has to watch for these and write a certificate back. There is a signer on cplane-01. Compare what it reports at startup against what is being asked for above: journalctl -u pod-identity-signer -n 20 --no-pager"
        exit 0
      fi
      denied=$(kubectl -n payments get podcertificaterequests -o json 2>/dev/null \
        | jq '[.items[] | select([.status.conditions[]? | select(.type == "Denied" or .type == "Failed")] | length > 0)] | length')
      if [ "${denied:-0}" -gt 0 ]; then
        echo "${denied} request(s) were answered with a refusal rather than a certificate. The signer looked at them and said no: journalctl -u pod-identity-signer -n 20 --no-pager"
        exit 0
      fi
      echo "payments-api has ${avail:-0} of 2 replicas available, and no request is outstanding. Start from the pod: kubectl -n payments describe \$(kubectl -n payments get pod -l app=payments-api -o name | head -1) | tail -20"
      exit 0
    failcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      timeout 10 kubectl get ns default >/dev/null 2>&1 || exit 0
      if ! kubectl -n payments get deployment payments-api >/dev/null 2>&1; then
        echo "Constraint violated: the payments-api deployment no longer exists. Repair it, do not replace it."
        exit 1
      fi
      # Only genuine violations belong here. A failcheck that fires on the starting
      # state settles the task at "failed" the moment it unblocks, and task status
      # never regresses, so the challenge would be unsolvable. What is a violation
      # is substituting a Secret for the feature.
      sec=$(kubectl -n payments get deployment payments-api -o json | jq '
        [.spec.template.spec.volumes[]?
          | select(.name == "pod-identity")
          | (.secret, .projected?.sources[]?.secret)
          | select(. != null)] | length')
      if [ "${sec:-0}" -ge 1 ]; then
        echo "Constraint violated: the pod-identity volume now takes its certificate from a Secret. It has to come from the podCertificate projection, not from a Secret you fill in yourself."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf

      avail=$(kubectl -n payments get deployment payments-api -o jsonpath='{.status.availableReplicas}')
      [ "${avail:-0}" -ge 2 ]

      # One replica per worker node, so both kubelets have to be able to do this.
      nodes=$(kubectl -n payments get pods -l app=payments-api \
        --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
      echo "$nodes" | grep -qx 'node-01'
      echo "$nodes" | grep -qx 'node-02'

      # Every running server pod must hold a certificate that this cluster issued
      # to that exact pod. Matching on podUID is what makes a hand-made Secret or
      # a leftover request from an earlier pod fail here.
      # Judged on the outcome, not on how it was reached. Making the signer answer
      # the name the workload asks for, or pointing the workload at the name the
      # signer already answers, are both legitimate fixes, so no literal signer
      # name appears here.
      for uid in $(kubectl -n payments get pods -l app=payments-api \
          --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}'); do
        kubectl -n payments get podcertificaterequests -o json | jq -e --arg uid "$uid" '
          [.items[]
            | select(.spec.podUID == $uid)
            | select([.status.conditions[]? | select(.type == "Issued" and .status == "True")] | length > 0)
          ] | length > 0' >/dev/null
      done

  verify_client_identity:
    machine: cplane-01
    user: root
    needs:
      - verify_certs_issued
    timeout_seconds: 900
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      timeout 10 kubectl get ns default >/dev/null 2>&1 || exit 0
      src=$(kubectl -n payments get deployment checkout -o json 2>/dev/null \
        | jq '[.spec.template.spec.volumes[]?.projected?.sources[]? | select(.podCertificate)] | length')
      if [ "${src:-0}" -lt 1 ]; then
        echo "The checkout deployment still has no podCertificate projected volume source. Copy the shape from payments-api: kubectl -n payments get deployment payments-api -o yaml | grep -A10 podCertificate"
        exit 0
      fi
      signer=$(kubectl -n payments get deployment checkout -o json \
        | jq -r '[.spec.template.spec.volumes[]?.projected?.sources[]?.podCertificate?.signerName] | .[0] // ""')
      want=$(kubectl -n payments get deployment payments-api -o json \
        | jq -r '[.spec.template.spec.volumes[]?.projected?.sources[]?.podCertificate?.signerName] | .[0] // ""')
      if [ -n "$want" ] && [ "$signer" != "$want" ]; then
        echo "checkout asks signer '${signer}', but payments-api gets its certificates from '${want}'. A request for a signer nobody answers sits Pending forever: point checkout at the signer payments-api uses."
        exit 0
      fi
      pod=$(kubectl -n payments get pods -l app=checkout -o json 2>/dev/null | jq -r '
        [.items[]
          | select(.metadata.deletionTimestamp == null)
          | select(.status.phase == "Running")]
        | sort_by(.metadata.creationTimestamp) | last | .metadata.name // ""')
      if [ -z "$pod" ]; then
        echo "No Running checkout pod yet. A pod with a podCertificate source does not start until every one of its certificates has been issued: kubectl -n payments describe \$(kubectl -n payments get pod -l app=checkout -o name | head -1) | tail -15"
        exit 0
      fi
      if ! kubectl -n payments exec "$pod" -- test -f /var/run/pod-identity/tls.crt 2>/dev/null; then
        echo "The pod is running but /var/run/pod-identity/tls.crt is not there. Check the mountPath and that keyPath/certificateChainPath are tls.key and tls.crt."
      fi
      exit 0
    failcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      timeout 10 kubectl get ns default >/dev/null 2>&1 || exit 0
      if ! kubectl -n payments get deployment checkout >/dev/null 2>&1; then
        echo "Constraint violated: the checkout deployment no longer exists. Edit it, do not replace it."
        exit 1
      fi
      sa=$(kubectl -n payments get deployment checkout -o jsonpath='{.spec.template.spec.serviceAccountName}')
      if [ "$sa" != "checkout" ]; then
        echo "Constraint violated: checkout now runs as service account '${sa}'. Its identity has to stay its own."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf

      # checkout has to use the same signer the server does, whichever that ended
      # up being, so this reads it from payments-api instead of hardcoding it.
      want=$(kubectl -n payments get deployment payments-api -o json | jq -r '
        [.spec.template.spec.volumes[]?.projected?.sources[]?.podCertificate.signerName] | .[0] // ""')
      [ -n "$want" ]
      kubectl -n payments get deployment checkout -o json | jq -e --arg want "$want" '
        [.spec.template.spec.volumes[]?.projected?.sources[]?.podCertificate
          | select(.signerName == $want)] | length > 0' >/dev/null

      # The newest Ready pod that is not on its way out. A deployment that has just
      # rolled leaves a Terminating pod behind for a while, and that pod predates
      # the change being checked here.
      pod=$(kubectl -n payments get pods -l app=checkout -o json | jq -r '
        [.items[]
          | select(.metadata.deletionTimestamp == null)
          | select(.status.phase == "Running")
          | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)]
        | sort_by(.metadata.creationTimestamp) | last | .metadata.name // ""')
      [ -n "$pod" ]
      uid=$(kubectl -n payments get pod "$pod" -o jsonpath='{.metadata.uid}')

      kubectl -n payments exec "$pod" -- test -f /var/run/pod-identity/tls.crt
      kubectl -n payments exec "$pod" -- test -f /var/run/pod-identity/tls.key

      # The certificate has to name this pod's own service account. Running the
      # client under payments-api's identity would pass every other check here.
      chain=$(kubectl -n payments get podcertificaterequests -o json | jq -r --arg uid "$uid" '
        [.items[]
          | select(.spec.podUID == $uid)
          | select([.status.conditions[]? | select(.type == "Issued" and .status == "True")] | length > 0)
          | .status.certificateChain] | .[0] // ""')
      [ -n "$chain" ]
      echo "$chain" | openssl x509 -noout -ext subjectAltName \
        | grep -q 'URI:spiffe://cluster.local/ns/payments/sa/checkout'

  verify_mtls_enforced:
    machine: cplane-01
    user: root
    needs:
      - verify_client_identity
    timeout_seconds: 900
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      timeout 10 kubectl get ns default >/dev/null 2>&1 || exit 0
      conf=$(kubectl -n payments get configmap payments-api-nginx -o jsonpath='{.data.default\.conf}' 2>/dev/null || true)
      if ! echo "$conf" | grep -q 'ssl_verify_client[[:space:]]*on'; then
        echo "payments-api terminates TLS but asks nothing of the client, so it serves anyone who can reach it. Two directives are missing: one names a CA to verify clients against, the other makes a client certificate required rather than optional. The CA is already mounted in the pod at /etc/pod-identity/ca.crt."
        exit 0
      fi
      if ! echo "$conf" | grep -q 'ssl_client_certificate'; then
        echo "Client verification is switched on but nginx has no CA to verify against, so no client can pass. The trust anchor is mounted in the pod at /etc/pod-identity/ca.crt."
        exit 0
      fi
      # The ConfigMap is right, so the only question left is whether the running
      # pods have read it. Ask the server instead of guessing: if a request with no
      # client certificate still gets a 200, the pods predate the change.
      pod=$(kubectl -n payments get pods -l app=checkout -o json 2>/dev/null | jq -r '
        [.items[] | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running")]
        | sort_by(.metadata.creationTimestamp) | last | .metadata.name // ""')
      if [ -n "$pod" ]; then
        code=$(kubectl -n payments exec "$pod" -- curl -sS -o /dev/null -w '%{http_code}' \
          --connect-timeout 5 --max-time 15 --cacert /etc/pod-identity/ca.crt \
          https://payments-api.payments.svc:8443/ 2>/dev/null | tail -1)
        if [ "$code" = "200" ]; then
          echo "The ConfigMap is right and the server still serves a client that presents no certificate. nginx reads its configuration once, at startup, and updating a ConfigMap does not restart anything on its own."
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
      timeout 10 kubectl get ns default >/dev/null 2>&1 || exit 0
      if ! kubectl -n payments get service payments-api >/dev/null 2>&1; then
        echo "Constraint violated: the payments-api Service no longer exists."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf

      pod=$(kubectl -n payments get pods -l app=checkout -o json | jq -r '
        [.items[]
          | select(.metadata.deletionTimestamp == null)
          | select(.status.phase == "Running")
          | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)]
        | sort_by(.metadata.creationTimestamp) | last | .metadata.name // ""')
      [ -n "$pod" ]

      curl_code() {
        kubectl -n payments exec "$pod" -- curl -sS -o /dev/null -w '%{http_code}' \
          --connect-timeout 5 --max-time 15 "$@" \
          https://payments-api.payments.svc:8443/ 2>/dev/null | tail -1
      }

      # A pod holding an identity this cluster issued gets through. Retried, because
      # the server deployment replaces its pods rather than rolling them, so a
      # restart takes the Service to zero endpoints for a few seconds.
      code=""
      for i in $(seq 1 12); do
        code=$(curl_code --cacert /etc/pod-identity/ca.crt \
          --cert /var/run/pod-identity/tls.crt --key /var/run/pod-identity/tls.key || true)
        [ "$code" = "200" ] && break
        sleep 5
      done
      [ "$code" = "200" ]

      # The same pod, same network path, no client certificate: refused. Without
      # this half, the certificates are decoration.
      code=$(curl_code --cacert /etc/pod-identity/ca.crt || true)
      [ "$code" != "200" ]
---

Your team has been asked to get mutual TLS between two services in the `payments`
namespace. The usual answer is a service mesh: a control plane, a sidecar or a
node proxy per workload, and a CA you now operate. For two services, that is a
lot of machinery to take on.

[Kubernetes 1.37 made an alternative generally available](https://kubernetes.io/blog/2026/08/28/kubernetes-v1-37-pod-certificates-and-cluster-trust-bundles/). The kubelet can generate
a private key for a pod, ask a signer for a certificate, and drop the result into
the pod's filesystem, rotating it before it expires. The pod gets an identity it
never has to handle, mint, or renew. No sidecar, no mesh, no bearer token
exchanged for a certificate.

The API is served out of the box now. What Kubernetes still does not ship is a
certificate authority. It will accept a request, record who is asking, and then
wait for something else to answer it. Your platform team put that piece in place:
a `pod-identity-signer` service on `cplane-01`, with its own CA.

Two workloads are deployed:

- **`payments-api`**: two replicas, one per worker node, meant to serve HTTPS on
  `8443`. Its pods are stuck in `ContainerCreating` and have never started.
- **`checkout`**: the client. Running, and with no identity of its own.

The plan:

1. Get `payments-api` running with certificates the cluster issued it.
2. Give `checkout` its own identity.
3. Make `payments-api` reject anyone who does not have one.

**Constraints:**

- Use the signer that is already installed. Do not replace its CA.
- Both workloads keep their own service accounts, and their certificates come from
  the `podCertificate` projected volume, not from a `Secret` you fill in yourself.
- Edit the deployments in place. Do not delete and recreate them.
- Do not recreate the cluster.

### Where this can fail

Three conditions have to hold before a pod holds a certificate it can use, and
each one fails in its own way:

1. **The pod asks.** A `podCertificate` projected volume is what makes the kubelet
   generate a key and file a request at all.
2. **A signer answers.** Kubernetes has no built-in CA for this. A request nobody
   answers stays pending forever, nothing times out on the pod's behalf, and the
   pod stays in `ContainerCreating`.
3. **The application uses the certificate for something.** A key on disk is not
   mutual TLS until the server checks the other end.

The first two are platform work. The third is the part a service mesh would have
done for you, and the part people forget when they replace one.

### Pre-flight

Start on **`cplane-01`**:

```bash
kubectl -n payments get pods -o wide
kubectl -n payments logs -l app=payments-api --tail=5
journalctl -u pod-identity-signer -n 20 --no-pager

diff <(kubectl -n payments get deployment payments-api -o yaml) /home/laborant/payments-api.yaml
```

Read all four before you change anything. The last one is the interesting one.

### Step 1: Get the server its certificates

The `payments-api` pods have never started. A pod with a `podCertificate` projected
volume does not start until every certificate in it has been issued, so this is not
a crash loop, it is a wait.

```bash
kubectl -n payments get podcertificaterequests -o wide
```

A request carrying no condition has not been answered by anybody. Nothing times out
on the pod's behalf, so this state lasts indefinitely.

::simple-task
---
:tasks: tasks
:name: verify_certs_issued
---
#active
Waiting for both payments-api replicas to hold issued certificates…

#completed
Both `payments-api` pods are running with certificates issued to their own pod UIDs.
::

::hint-box
---
:summary: "Hint 1: who is supposed to answer"
---
Kubernetes records the request and stops there. It ships no certificate authority
for pod certificates and will never issue one itself. Something has to watch for
these requests and write a certificate back into the status.

That something runs on `cplane-01`, and it reports what it is doing when it starts:

```bash
systemctl status pod-identity-signer
journalctl -u pod-identity-signer -n 20 --no-pager
```

It is up, and it is healthy. So "is the signer running" is not the question.
::

::hint-box
---
:summary: "Hint 2: two names that have to agree"
---
A signer watches for one signer name and ignores every request that does not carry
it. A pod asks for one signer name and waits for exactly that one. Put the two side
by side:

```bash
kubectl -n payments get podcertificaterequests -o wide
journalctl -u pod-identity-signer -n 20 --no-pager | head -3
```

If they disagree, both halves are working perfectly and neither is talking to the
other. The signer takes its copy from its unit:

```bash
systemctl cat pod-identity-signer
```

Either side can be brought into line with the other, and this step is judged on the
outcome, so either fix passes.
::

::hint-box
---
:summary: "Hint 3: making a unit change take effect"
---
systemd reads a unit file when it loads it, not when the service restarts. After
editing a unit, `systemctl restart` on its own still runs what systemd loaded
earlier. `systemctl cat` shows you what it currently believes the unit says.
::

### Step 2: Give the client an identity

`checkout` can already reach the server and verify it, because the CA bundle is
mounted at `/etc/pod-identity/ca.crt`:

```bash
POD=$(kubectl -n payments get pod -l app=checkout -o name | head -1)
kubectl -n payments exec ${POD#pod/} -- \
  curl -sS --cacert /etc/pod-identity/ca.crt https://payments-api.payments.svc:8443/
```

That is one-way TLS. The client knows who the server is; the server has no idea who
the client is. Give `checkout` a certificate of its own.

Add a `podCertificate` projected volume to the `checkout` deployment, mounted at
`/var/run/pod-identity`, with the certificate at `tls.crt` and the key at `tls.key`,
signed by the same signer `payments-api` uses.

::simple-task
---
:tasks: tasks
:name: verify_client_identity
---
#active
Waiting for checkout to hold a certificate for its own service account…

#completed
`checkout` holds a certificate naming `spiffe://cluster.local/ns/payments/sa/checkout`.
::

::hint-box
---
:summary: The shape of the volume
---
You do not have to invent this. `payments-api` already has a working one, so read
its spec:

```bash
kubectl -n payments get deployment payments-api -o yaml
```

The field is also self-documenting from the cluster:

```bash
kubectl explain pod.spec.volumes.projected.sources.podCertificate
```

That output covers every field, including which key types the kubelet will
generate, and a third path option that writes the key and the chain into a single
file. Prefer that single file when your application can read it, because two
separate files can be read mid-rotation and disagree with each other. nginx needs
them separate, which is why the server here does not use it.
::

::hint-box
---
:summary: The identity comes from the service account
---
`checkout` runs as the `checkout` service account, and the signer here turns that
into `spiffe://cluster.local/ns/payments/sa/checkout`. Read what was issued:

```bash
kubectl -n payments get podcertificaterequests -o json \
  | jq -r '.items[] | select(.spec.serviceAccountName == "checkout") | .status.certificateChain' \
  | openssl x509 -noout -ext subjectAltName
```

Two workloads sharing a service account share an identity. That is a design
decision about your service accounts, not about certificates.
::

### Step 3: Make the server enforce it

Both workloads now have certificates. Nothing is checking them.

```bash
POD=$(kubectl -n payments get pod -l app=checkout -o name | head -1)
kubectl -n payments exec ${POD#pod/} -- \
  curl -sS --cacert /etc/pod-identity/ca.crt https://payments-api.payments.svc:8443/
# payments-api ok
# client-verify=NONE
```

A request with no client certificate at all is still served. Make `payments-api`
require one and verify it against the workload CA, so that the same request is
refused while a request presenting an issued certificate succeeds.

::simple-task
---
:tasks: tasks
:name: verify_mtls_enforced
---
#active
Checking that certified clients get through and uncertified ones do not…

#completed
Mutual TLS enforced: `checkout` is admitted with its certificate and refused without it.
::

::hint-box
---
:summary: Where the server's configuration lives
---
```bash
kubectl -n payments get configmap payments-api-nginx -o yaml
```

The server terminates TLS but asks nothing of the client. Two directives are
missing, and they do different jobs. One gives nginx a CA to verify client certificates against; the other
makes presenting one mandatory instead of optional. The CA bundle is already
mounted into the server pod at `/etc/pod-identity/ca.crt`.

Both directives are in the
[ngx_http_ssl_module reference](https://nginx.org/en/docs/http/ngx_http_ssl_module.html);
look for the two whose names begin with `ssl_verify` and `ssl_client`.
::

::hint-box
---
:summary: The change is applied but nothing changed
---
nginx reads its configuration at startup, and updating a ConfigMap does not restart
anything by itself. The projected file inside the running container updates on its
own schedule, and the process will not notice either way:

```bash
kubectl -n payments rollout restart deployment payments-api
kubectl -n payments rollout status deployment payments-api
```
::

### Related on iximiuz Labs

Other people's work on the same terrain, worth doing alongside this one:

- [Building a Minimal Service Mesh with eBPF and Envoy](https://labs.iximiuz.com/skill-paths/ebpf-minimal-service-mesh-1a81fd6d) by Teodor Janez Podobnik. The road this challenge deliberately does not take, and the best way to judge the trade
- [Troubleshoot CrashLoopBackOff Caused by a Missing TLS Secret](https://labs.iximiuz.com/challenges/recover-crashing-deployment-by-recreating-tls-secret-df22c665) by Omkar Shelke. The Secret-mounted certificate this feature is meant to replace, failing in the same way
- [Getting Started with OpenBao/Vault](https://labs.iximiuz.com/tutorials/openbao-vault-getting-started-e783c133) by Márk Sági-Kazár. The other common answer to getting certificates into workloads

### References

- [PodCertificateRequest API reference](https://kubernetes.io/docs/reference/kubernetes-api/certificates/pod-certificate-request-v1/)
- [Projected volumes: podCertificate](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [KEP-4317: Pod Certificates](https://github.com/kubernetes/enhancements/tree/master/keps/sig-auth/4317-pod-certificates)
- [Certificate signing requests and signers](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
- [Feature gates](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/)
