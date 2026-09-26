---
kind: challenge

title: 'CKA Practice: Renew Expiring Control Plane Certificates'

description: |
  kubectl is dead: the kube-apiserver certificate expired and the control plane is down, while the workload quietly keeps serving. Diagnose the expiry offline, renew the certificates, bring the control plane back, and prove the cluster recovered.

categories:
- kubernetes
- security

tagz:
- cka
- kubeadm
- certificates

difficulty: medium

createdAt: 2026-08-07
updatedAt: 2026-09-02

cover: __static__/cover.png

playground:
  name: k8s-omni

tasks:
  # Seeding is split so a failed init reads from the task list: the slow
  # workload seeding, the instant CA guard, and the certificate sabotage
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
      count_ready() {
        kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
          | grep -c '^True$' || true
      }
      for i in $(seq 1 60); do
        [ "$(count_ready)" -ge 3 ] && break
        sleep 5
      done
      [ "$(count_ready)" -ge 3 ]

      # Seed the workload that must stay up during the renewal.
      kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n web create deployment web-backend --image=ghcr.io/iximiuz/labs/nginx:alpine --replicas=2 \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n web expose deployment web-backend --port=80 --dry-run=client -o yaml | kubectl apply -f -
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
      # Record the CA fingerprint. Rotating the CA is out of scope and fails the attempt.
      openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 > /root/.challenge-ca.sha256
      chmod 600 /root/.challenge-ca.sha256

  init_break_certs:
    init: true
    machine: cplane-01
    user: root
    needs:
      - init_guard_ca
    timeout_seconds: 600
    run: |
      set -euo pipefail
      # Re-sign the apiserver certificate with the cluster CA at zero validity so
      # it is already expired when the learner arrives, and every other
      # kubeadm-managed leaf at a few days, so `kubeadm certs check-expiration`
      # shows what the story says ("the others are not far behind") and renewing
      # only the expired items cannot pass the 300-day check. kubeadm cannot
      # issue such certificates, hence openssl.
      cd /etc/kubernetes/pki

      # Re-sign the client certificate embedded in a kubeconfig at the given
      # validity, keeping the same key and subject. Private material goes into a
      # private directory, never into world-readable /tmp.
      WORK=$(mktemp -d)
      chmod 700 "$WORK"
      expire_kubeconfig_cert() {
        kc="$1"; days="$2"
        [ -f "$kc" ] || { echo "init failed: $kc not found"; exit 1; }
        grep -q client-key-data "$kc" || { echo "init failed: $kc has no embedded client key"; exit 1; }
        grep client-key-data "$kc" | awk '{print $2}' | base64 -d > "$WORK/client.key"
        subj=$(grep client-certificate-data "$kc" | awk '{print $2}' | base64 -d \
          | openssl x509 -noout -subject | sed 's/^subject=//; s/, /\//g; s/ = /=/g; s/^/\//')
        openssl req -new -key "$WORK/client.key" -subj "$subj" -out "$WORK/client.csr"
        printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' > "$WORK/client.cnf"
        openssl x509 -req -in "$WORK/client.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days "$days" \
          -extfile "$WORK/client.cnf" -out "$WORK/client.crt" 2>/dev/null
        sed -i "s|client-certificate-data: .*|client-certificate-data: $(base64 -w0 "$WORK/client.crt")|" "$kc"
        rm -f "$WORK"/client.*
      }

      # short_sign re-signs an on-disk certificate with its own CA at a short
      # validity, keeping key, subject, SANs, and EKUs. This is what puts the
      # non-outage leaves at "a few days left" instead of an untouched year.
      short_sign() {
        crt="$1"; key="$2"; cacrt="$3"; cakey="$4"; days="$5"
        subj=$(openssl x509 -in "$crt" -noout -subject | sed 's/^subject=//; s/, /\//g; s/ = /=/g; s/^/\//')
        san=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -n1 | sed 's/^ *//; s/IP Address:/IP:/g')
        case "$san" in DNS:*|IP:*) ;; *) san="" ;; esac
        eku=$(openssl x509 -in "$crt" -noout -ext extendedKeyUsage 2>/dev/null | tail -n1 \
          | sed 's/^ *//; s/TLS Web Server Authentication/serverAuth/g; s/TLS Web Client Authentication/clientAuth/g; s/, /,/g')
        case "$eku" in serverAuth*|clientAuth*) ;; *) eku="" ;; esac
        {
          echo 'basicConstraints=CA:FALSE'
          echo 'keyUsage=critical,digitalSignature,keyEncipherment'
          if [ -n "$eku" ]; then echo "extendedKeyUsage=$eku"; fi
          if [ -n "$san" ]; then echo "subjectAltName=$san"; fi
        } > "$WORK/short.cnf"
        openssl req -new -key "$key" -subj "$subj" -out "$WORK/short.csr"
        openssl x509 -req -in "$WORK/short.csr" -CA "$cacrt" -CAkey "$cakey" -CAcreateserial -days "$days" \
          -extfile "$WORK/short.cnf" -out "$crt" 2>/dev/null
        rm -f "$WORK"/short.*
      }

      # laborant's kubeconfig is a copy of admin.conf taken at provisioning time.
      # Renewal refreshes admin.conf and never touches this copy.
      KCU=/home/laborant/.kube/config
      expire_kubeconfig_cert "$KCU" 0

      # kube-controller-manager and kube-scheduler read their kubeconfig once, at
      # startup, and never reload it. Expiring these two is what makes a restart
      # genuinely necessary later: renewing the files on disk cannot fix a process
      # that is already holding an expired credential in memory.
      expire_kubeconfig_cert /etc/kubernetes/controller-manager.conf 0
      expire_kubeconfig_cert /etc/kubernetes/scheduler.conf 0

      # Everything else gets a few days: still working today, visibly about to
      # fail in `kubeadm certs check-expiration`, and far inside the 300-day
      # horizon the final check demands, so `renew all` is genuinely required.
      D=3
      expire_kubeconfig_cert /etc/kubernetes/admin.conf "$D"
      if [ -f /etc/kubernetes/super-admin.conf ]; then
        expire_kubeconfig_cert /etc/kubernetes/super-admin.conf "$D"
      fi
      short_sign apiserver-kubelet-client.crt apiserver-kubelet-client.key ca.crt ca.key "$D"
      short_sign front-proxy-client.crt front-proxy-client.key front-proxy-ca.crt front-proxy-ca.key "$D"
      short_sign apiserver-etcd-client.crt apiserver-etcd-client.key etcd/ca.crt etcd/ca.key "$D"
      for c in server peer healthcheck-client; do
        short_sign "etcd/${c}.crt" "etcd/${c}.key" etcd/ca.crt etcd/ca.key "$D"
      done

      SAN=$(openssl x509 -in apiserver.crt -noout -ext subjectAltName | tail -n1 | sed 's/^ *//; s/IP Address:/IP:/g')
      cat > /tmp/apiserver-ext.cnf <<EOF
      basicConstraints=CA:FALSE
      keyUsage=critical,digitalSignature,keyEncipherment
      extendedKeyUsage=serverAuth
      subjectAltName=${SAN}
      EOF
      openssl req -new -key apiserver.key -subj "/CN=kube-apiserver" -out /tmp/apiserver.csr
      openssl x509 -req -in /tmp/apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 0 \
        -extfile /tmp/apiserver-ext.cnf -out apiserver.crt 2>/dev/null
      rm -f /tmp/apiserver.csr /tmp/apiserver-ext.cnf

      # Restart every control plane static pod. The apiserver picks up the expired
      # serving certificate, and the controller-manager and the scheduler pick up
      # their expired kubeconfigs. Moving the manifests out and back is the standard
      # way to force this; the kubelet stops the pods when the files disappear.
      #
      # Note the apiserver does NOT crash on an expired serving certificate. It loads
      # it and serves it. Every client that validates against the CA is what breaks.
      mkdir -p "$WORK/manifests"
      mv /etc/kubernetes/manifests/*.yaml "$WORK/manifests/"
      sleep 10
      mv "$WORK/manifests"/*.yaml /etc/kubernetes/manifests/
      sleep 10
      rm -rf "$WORK"

      # Assert the fault took: the serving certificate and both component
      # kubeconfigs must be expired on disk.
      if openssl x509 -in apiserver.crt -noout -checkend 0 >/dev/null 2>&1; then
        echo "init failed: apiserver certificate is not expired"
        exit 1
      fi
      for f in /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /home/laborant/.kube/config; do
        if grep client-certificate-data "$f" | awk '{print $2}' | base64 -d \
            | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
          echo "init failed: client certificate in $f is not expired"
          exit 1
        fi
      done
      # And the remaining leaves must sit inside the 300-day horizon, or
      # renewing only the expired items would pass the first check.
      for c in apiserver-kubelet-client front-proxy-client apiserver-etcd-client; do
        if openssl x509 -in "${c}.crt" -noout -checkend 25920000 >/dev/null 2>&1; then
          echo "init failed: ${c}.crt is still valid past the 300-day horizon"
          exit 1
        fi
      done

  verify_certs_renewed:
    machine: cplane-01
    user: root
    needs:
      - init_break_certs
    timeout_seconds: 120
    hintcheck: |
      # 300 days in seconds; checkend exits 0 when the cert is still valid at that horizon
      if ! openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -checkend 25920000 >/dev/null 2>&1; then
        echo "apiserver.crt on disk still expires soon: $(openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate). Run 'kubeadm certs check-expiration' to see the picture, then look at 'kubeadm certs renew --help'."
        exit 0
      fi
      if ! grep client-certificate-data /etc/kubernetes/admin.conf | awk '{print $2}' | base64 -d | openssl x509 -noout -checkend 25920000 >/dev/null 2>&1; then
        echo "apiserver.crt is renewed, but the client certificate inside admin.conf is not. One renewal subcommand refreshes every kubeadm-managed certificate at once."
      fi
      exit 0
    failcheck: |
      current=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null)
      stored=$(cat /root/.challenge-ca.sha256 2>/dev/null)
      if [ -n "$stored" ] && [ "$current" != "$stored" ]; then
        echo "Constraint violated: the cluster CA was replaced. Renew the leaf certificates, do not rotate the CA."
        exit 1
      fi
      export KUBECONFIG=/etc/kubernetes/admin.conf
      if kubectl get ns default >/dev/null 2>&1 && ! kubectl get deployment web-backend -n web >/dev/null 2>&1; then
        echo "Constraint violated: deployment web-backend in namespace web no longer exists. The workload must not be modified."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      # Every kubeadm-managed certificate must be valid for at least 300 more days.
      for c in apiserver apiserver-kubelet-client front-proxy-client apiserver-etcd-client; do
        openssl x509 -in "/etc/kubernetes/pki/${c}.crt" -noout -checkend 25920000
      done
      for c in server peer healthcheck-client; do
        openssl x509 -in "/etc/kubernetes/pki/etcd/${c}.crt" -noout -checkend 25920000
      done
      for f in admin.conf controller-manager.conf scheduler.conf; do
        grep client-certificate-data "/etc/kubernetes/${f}" | awk '{print $2}' | base64 -d \
          | openssl x509 -noout -checkend 25920000
      done

  verify_serving_new_cert:
    machine: cplane-01
    user: root
    needs:
      - verify_certs_renewed
    timeout_seconds: 300
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      served=$(timeout 5 bash -c "echo | openssl s_client -connect localhost:6443 2>/dev/null" | openssl x509 -noout -enddate 2>/dev/null)
      ondisk=$(openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate)
      if [ -n "$served" ] && [ "$served" != "$ondisk" ]; then
        echo "The file on disk is renewed (${ondisk}) but the API server is still presenting ${served}. Give it a moment; if it does not change, restart the control plane static pods."
        exit 0
      fi
      if ! timeout 5 kubectl get ns default >/dev/null 2>&1; then
        echo "kubectl still cannot reach the API server. Check 'crictl ps' and the container logs for the control plane components."
        exit 0
      fi
      for l in kube-controller-manager kube-scheduler; do
        rt=$(kubectl -n kube-system get lease "$l" -o jsonpath='{.spec.renewTime}' 2>/dev/null || true)
        if [ -z "$rt" ]; then
          echo "The ${l} lease in kube-system has no renew time. That component is not talking to the API server."
          exit 0
        fi
        age=$(( $(date +%s) - $(date -d "$rt" +%s) ))
        if [ "$age" -gt 120 ]; then
          echo "${l} last renewed its lease ${age}s ago, so it is not talking to the API server. Renewing a file on disk does not change a process that is already running: these components read their kubeconfig once, at startup. They need a restart."
          exit 0
        fi
      done
      exit 0
    failcheck: |
      current=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null)
      stored=$(cat /root/.challenge-ca.sha256 2>/dev/null)
      if [ -n "$stored" ] && [ "$current" != "$stored" ]; then
        echo "Constraint violated: the cluster CA was replaced."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      export KUBECONFIG=/etc/kubernetes/admin.conf
      # The certificate actually presented on the wire must be the renewed one.
      echo | openssl s_client -connect localhost:6443 2>/dev/null | openssl x509 -noout -checkend 25920000
      # And the two components that never reload their kubeconfig must be back in
      # contact with the API server. A live leader-election lease proves it, and no
      # amount of waiting can fake it while they hold an expired credential.
      for l in kube-controller-manager kube-scheduler; do
        rt=$(kubectl -n kube-system get lease "$l" -o jsonpath='{.spec.renewTime}')
        [ -n "$rt" ]
        age=$(( $(date +%s) - $(date -d "$rt" +%s) ))
        [ "$age" -le 120 ]
      done

  verify_user_kubeconfig:
    machine: cplane-01
    user: laborant
    needs:
      - verify_serving_new_cert
    timeout_seconds: 300
    hintcheck: |
      if ! grep client-certificate-data /home/laborant/.kube/config | awk '{print $2}' | base64 -d | openssl x509 -noout -checkend 25920000 >/dev/null 2>&1; then
        echo "kubectl as laborant fails with 'the server has asked for the client to provide credentials' even though the control plane is back. The client certificate inside /home/laborant/.kube/config is expired: this file is a copy made at provisioning time, and the renewal refreshed /etc/kubernetes/admin.conf, not the copy. Update the copy and mind file ownership."
      fi
      exit 0
    failcheck: |
      # This task runs as laborant, who cannot read root's CA fingerprint file, so
      # the workload half of the guard is what can be enforced here.
      export KUBECONFIG=/home/laborant/.kube/config
      if timeout 5 kubectl get ns default >/dev/null 2>&1 && ! kubectl get deployment web-backend -n web >/dev/null 2>&1; then
        echo "Constraint violated: deployment web-backend in namespace web no longer exists."
        exit 1
      fi
      exit 0
    run: |
      set -euo pipefail
      grep client-certificate-data /home/laborant/.kube/config | awk '{print $2}' | base64 -d \
        | openssl x509 -noout -checkend 25920000
      kubectl --kubeconfig /home/laborant/.kube/config get ns default >/dev/null

  verify_cluster_healthy:
    machine: cplane-01
    user: root
    needs:
      - verify_user_kubeconfig
    timeout_seconds: 300
    hintcheck: |
      export KUBECONFIG=/etc/kubernetes/admin.conf
      if ! kubectl get ns default >/dev/null 2>&1; then
        echo "kubectl cannot reach the API server. Did every control plane component come back after the restart? Check 'crictl ps' and the manifests in /etc/kubernetes/manifests/."
        exit 0
      fi
      notready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}')
      [ -n "$notready" ] && echo "Nodes not Ready: ${notready}. Give the kubelets a minute after the control plane restart, then investigate with kubectl describe node."
      exit 0
    failcheck: |
      current=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -fingerprint -sha256 2>/dev/null)
      stored=$(cat /root/.challenge-ca.sha256 2>/dev/null)
      if [ -n "$stored" ] && [ "$current" != "$stored" ]; then
        echo "Constraint violated: the cluster CA was replaced."
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
      ready=$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' | grep -c '^True$' || true)
      [ "$ready" -ge 3 ]
      kubectl -n web get deployment web-backend >/dev/null
      avail=$(kubectl -n web get deployment web-backend -o jsonpath='{.status.availableReplicas}')
      [ "${avail:-0}" -ge 2 ]
      # Reach the Service from inside the cluster. Curling a ClusterIP from the host
      # network depends on the CNI and on kube-proxy programming host-originated
      # DNAT, which is not guaranteed across the runtimes this playground offers.
      # Scheduling this pod also re-proves the scheduler is alive. The mirrored
      # nginx image ships curl and is already on every node for the workload, so
      # this pulls nothing from Docker Hub. curl exits before kubectl attaches,
      # so kubectl falls back to streaming the log and can print the status code
      # twice; a prefix match keeps that from failing a healthy cluster.
      code=$(kubectl -n web run curl-check-$$ --image=ghcr.io/iximiuz/labs/nginx:alpine --restart=Never --rm -i --quiet \
        --command -- curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 http://web-backend/ 2>/dev/null || true)
      case "$code" in 200*) ;; *) echo "workload returned '${code}'"; exit 1 ;; esac
---

About a year ago someone provisioned this three-node cluster with kubeadm. The SRE on
call today ran a routine check to confirm all services were up. Every `kubectl`
command failed:

```
Unable to connect to the server: tls: failed to verify certificate:
x509: certificate has expired or is not yet valid
```

The cluster is unmanageable, and the application in namespace `web` is still serving
traffic. Both of those are normal, and the reason is worth understanding before you
start. Running pods do not depend on the control plane to keep running. Their
containers are supervised by the kubelet on each node, and their traffic is carried by
kube-proxy rules already programmed on those nodes. Liveness and readiness probes keep
working too, because the kubelet executes them locally. What you lose in an API outage
is the ability to *change* anything: no scheduling, no rollouts, no scaling, no
`kubectl`.

Recover the cluster. The workload in namespace `web` must stay up throughout.

This exercise covers two CKA domains: Cluster Architecture, Installation and
Configuration, and Troubleshooting.

The plan:

1. Confirm the diagnosis without the API, since kubectl is not coming back on its own.
2. Renew the certificates.
3. Bring the control plane back.
4. Restore your own kubectl access.
5. Verify the cluster and the workload.

Constraints:

- Do not rotate the CA. `/etc/kubernetes/pki/ca.crt` and `ca.key` stay as they are.
- Do not modify the workload in namespace `web`.

### Pre-flight

Work on `cplane-01` as root (`sudo -i`). Since `kubectl get nodes` fails, you need
tools that read the certificates from disk instead of asking the API. Find out which
certificates this cluster has, when each one expires, and which authority signed them.

One piece of background that explains the shape of this incident: `kubeadm init`
issues the cluster CA with ten years of validity and every leaf certificate with one
year. It issues all the leaves at the same moment, so they expire at roughly the same
moment. A cluster that is upgraded regularly never notices, because `kubeadm upgrade`
renews them as a side effect. A cluster that is left alone for a year does notice, all
at once.

::hint-box
---
:summary: Inspecting certificates without the API
---
`kubeadm certs --help` gives you the set of subcommands that can be used to read/modify certificate expiry. Raw openssl works too: `openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate`. The CA section shows validity measured in years; the CAs are not your problem today.
::

### Step 1: Renew the certificates

Renew the kubeadm-managed certificates on `cplane-01`. One expired certificate caused the outage, but kubeadm issued all of them at the same time, so the others are not far behind. The check expects every kubeadm-managed certificate to be valid well past today, including the client certificates embedded in the kubeconfig files under `/etc/kubernetes/`.

::simple-task
---
:tasks: tasks
:name: verify_certs_renewed
---
#active
Checking certificate validity on disk…

#completed
All control plane certificates on disk are valid for more than 300 days.
::

::hint-box
---
:summary: Finding the right subcommand
---
`kubeadm certs --help` has one subcommand that reports the expiry of every certificate
it manages, and another that reissues them. Start with the reporting one and read the
whole table, including the rows for the kubeconfig files.
::

::hint-box
---
:summary: Which renewal command (spoiler)
---
`kubeadm certs renew --help` lists one subcommand per certificate plus `all`. `all`
also refreshes the client certificates embedded in `admin.conf`,
`controller-manager.conf`, and `scheduler.conf`. If you renew only the apiserver
certificate, the others still expire on their original schedule.
::

### Step 2: Bring the control plane back

A renewed file on disk is not the same as a renewed credential in use.

Nothing here crashed. The API server loaded the expired certificate quite happily and
served it; it was every *client* that refused the handshake. So there is no crash loop
to wait out, and nothing will fix itself.

Two reload behaviours differ here, and telling them apart is what this step tests:

- The API server watches its `--tls-cert-file` and picks up a replacement serving
  certificate without a restart.
- The controller-manager and the scheduler read their kubeconfig exactly once, at
  startup. They are still holding the credential they loaded when they started, and
  renewing a file on disk does not reach into a running process.

Check what port 6443 serves, then confirm the other two components are back
in contact with the API server:

```bash
echo | openssl s_client -connect localhost:6443 2>/dev/null | openssl x509 -noout -enddate
kubectl -n kube-system get lease kube-controller-manager kube-scheduler \
  -o custom-columns=NAME:.metadata.name,RENEW:.spec.renewTime
```

The custom columns matter: the default `get lease` table shows only NAME, HOLDER, and
AGE, and AGE is the lease object's age, not when it was last renewed. A leader-election
lease that stopped being renewed is a component that cannot talk to the API server.

::simple-task
---
:tasks: tasks
:name: verify_serving_new_cert
---
#active
Checking the served certificate and the control plane leases…

#completed
The API server serves the renewed certificate, and the controller-manager and scheduler are renewing their leases again.
::

::hint-box
---
:summary: Restarting static pods
---
The kubelet restarts a static pod when its manifest changes or its container stops. Two common approaches: move the manifests out of `/etc/kubernetes/manifests/` and back after a few seconds, or stop the containers with `crictl` and let the kubelet recreate them. Deleting the mirror pod with kubectl does not work, and with the API down it is not even an option.
::

### Step 3: Restore your own access

The control plane is back and `kubectl` works as root with
`/etc/kubernetes/admin.conf`. Try it as the regular user now:

```bash
exit          # drop back from sudo -i to laborant
kubectl get nodes
```

It fails with `error: You must be logged in to the server (the server has asked for
the client to provide credentials)`, even though root's `kubectl` works fine against
the same cluster. Restore your own access.

::simple-task
---
:tasks: tasks
:name: verify_user_kubeconfig
---
#active
Checking kubectl access for the regular user…

#completed
laborant's kubeconfig carries a renewed client certificate and kubectl works without sudo.
::

::hint-box
---
:summary: Comparing the two kubeconfig files
---
Look at the client certificate each file carries:

```bash
grep client-certificate-data ~/.kube/config | awk '{print $2}' | base64 -d | openssl x509 -noout -enddate
sudo grep client-certificate-data /etc/kubernetes/admin.conf | awk '{print $2}' | base64 -d | openssl x509 -noout -enddate
```

The fix is the same file copy kubeadm documents after cluster creation. Mind ownership and permissions: the file must belong to laborant and stay private.
::

### Step 4: Verify the cluster

Confirm the renewal did not break anything else. The nodes should be Ready, kubectl should work for both root and laborant, and the workload in `web` should still be serving.

::simple-task
---
:tasks: tasks
:name: verify_cluster_healthy
---
#active
Checking nodes, kubeconfig, and the workload…

#completed
Cluster healthy: nodes Ready, kubectl works again, workload serving. Only the control plane was ever down.
::

### Related on iximiuz Labs

Other people's work on the same terrain, worth doing alongside this one:

- [Inspecting and Extracting Kubernetes Kubeconfig Data](https://labs.iximiuz.com/challenges/inspecting-and-extracting-kubernetes-kubeconfig-data-50e5b3b3) by Omkar Shelke. Reading the client certificate embedded in a kubeconfig, which is one of the certificates that expires here
- [CKA Practice: Upgrade Multi-Node Kubernetes Cluster](https://labs.iximiuz.com/challenges/cka-kubeadm-upgrade-ecfc7390) by Adam Leskis. The upgrade path that renews every certificate as a side effect, and so prevents this outage
- [Kubernetes the (Very) Hard Way](https://labs.iximiuz.com/courses/kubernetes-the-very-hard-way-0cbfd997) by Márk Sági-Kazár. Building the cluster PKI by hand, which is the best way to learn what kubeadm is renewing

### References

- [kubeadm certs](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-certs/)
- [Certificate management with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [Static pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
