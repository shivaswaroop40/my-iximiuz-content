---

kind: challenge

title: 'CKA Practice: Migrate an Ingress to Gateway API'

description: |
  An app in the web namespace is served over HTTPS by an ingress-nginx Ingress. Create a Gateway and HTTPRoute on a staging hostname, verify traffic, move the production hostname to the Gateway, and remove the Ingress without downtime.

categories:

- kubernetes
- networking

tagz:

- cka
- gateway-api
- ingress

difficulty: medium

createdAt: 2026-03-19
updatedAt: 2026-09-01

cover: __static__/cover.png

tasks:
  init_controllers:
    init: true
    machine: k3s-01
    user: laborant
    timeout_seconds: 600
    run: |
      set -euo pipefail
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        if [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
          export KUBECONFIG="$kube"
          break
        fi
      done

      # Gateway API CRDs must match the version NGINX Gateway Fabric v2.4.2 declares support
      # for (1.4.1). NGF's own crds.yaml ships gateway.nginx.org CRDs only - it does NOT
      # install Gateway API, so this line is the single source of the API version.
      kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
      kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml
      kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.4.2/deploy/crds.yaml
      kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.4.2/deploy/default/deploy.yaml

      for c in gatewayclasses gateways httproutes; do
        kubectl wait --for=condition=Established "crd/${c}.gateway.networking.k8s.io" --timeout=180s
      done

      # ingress-nginx: the admission webhook must have live endpoints before an Ingress
      # can be created, otherwise the workload seeding task's apply is rejected.
      kubectl wait --for=condition=available deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s
      for i in $(seq 1 24); do
        kubectl get endpoints -n ingress-nginx ingress-nginx-controller-admission \
          -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q . && break
        sleep 5
      done

      # NGF control plane must actually be healthy. GatewayClass/nginx ships as a static
      # object in deploy.yaml, so its existence proves nothing - wait for Accepted=True,
      # which only the running controller can set.
      kubectl wait --for=condition=available deployment/nginx-gateway -n nginx-gateway --timeout=300s
      gwc_accepted() {
        kubectl get gatewayclass nginx \
          -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null
      }
      for i in $(seq 1 36); do
        [ "$(gwc_accepted)" = "True" ] && break
        sleep 5
      done
      if [ "$(gwc_accepted)" != "True" ]; then
        echo "GatewayClass nginx was not Accepted by NGINX Gateway Fabric."
        echo "This usually means the Gateway API CRD version does not match what NGF supports."
        kubectl get gatewayclass nginx -o yaml || true
        kubectl logs -n nginx-gateway deployment/nginx-gateway --tail=50 || true
        exit 1
      fi

  init_workload:
    init: true
    machine: k3s-01
    user: laborant
    needs:
      - init_controllers
    timeout_seconds: 600
    run: |
      set -euo pipefail
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        if [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
          export KUBECONFIG="$kube"
          break
        fi
      done

      # Seed the legacy Ingress-based setup the learner inherits.
      kubectl apply -f /home/laborant/challenge-workload.yaml
      kubectl apply -f /home/laborant/challenge-tls.yaml
      kubectl apply -f /home/laborant/challenge-ingress.yaml
      kubectl wait --for=condition=available deployment/web-backend -n web --timeout=180s

      # The "before" picture must be genuinely healthy before the learner sees the task list.
      # If this fails it is an environment problem, not a learner problem - fail init loudly
      # rather than surfacing it later as a red check the learner cannot fix.
      INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
      POD="init-curl-ing-$$"
      kubectl run "$POD" -n web --image=curlimages/curl:8.12.1 --restart=Never --command -- sleep 300
      kubectl wait --for=condition=Ready "pod/$POD" -n web --timeout=120s
      code=000
      for i in $(seq 1 24); do
        code=$(kubectl exec -n web "$POD" -- curl -k -sS -o /dev/null -w '%{http_code}' \
          --connect-timeout 10 --resolve "web.k8s.local:443:${INGRESS_IP}" \
          "https://web.k8s.local/" 2>/dev/null || echo "000")
        [ "$code" = "200" ] && break
        sleep 5
      done
      kubectl delete pod -n web "$POD" --ignore-not-found --wait=false
      if [ "$code" != "200" ]; then
        echo "Baseline Ingress did not serve HTTPS 200 (got ${code}) - environment setup failed."
        exit 1
      fi

  verify_gateway_created:
    machine: k3s-01
    user: laborant
    needs:
      - init_workload
    hintcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      if ! kubectl get gateway web-gateway -n web >/dev/null 2>&1; then
        if kubectl get gateway -n web --no-headers 2>/dev/null | grep -q .; then
          echo "There is a Gateway in namespace web, but none named 'web-gateway':"
          kubectl get gateway -n web
        fi
        exit 0
      fi
      g="$(kubectl get gateway web-gateway -n web -o json)"
      cls=$(echo "$g" | jq -r '.spec.gatewayClassName // "<unset>"')
      if [ "$cls" != "nginx" ]; then
        echo "spec.gatewayClassName is '${cls}'. It must name a GatewayClass that actually exists in this cluster - list them with 'kubectl get gatewayclass'."
      fi
      n=$(echo "$g" | jq -r '[.spec.listeners[]? | select(.name=="https")] | length')
      if [ "$n" != "1" ]; then
        echo "Expected exactly one listener named 'https'. Listener names found: $(echo "$g" | jq -rc '[.spec.listeners[]?.name]')"
        exit 0
      fi
      l=$(echo "$g" | jq '[.spec.listeners[] | select(.name=="https")][0]')
      v=$(echo "$l" | jq -r '.protocol // "<unset>"')
      [ "$v" != "HTTPS" ] && echo "Listener protocol is '${v}' - use HTTPS so the Gateway terminates TLS."
      v=$(echo "$l" | jq -r '.hostname // "<unset>"')
      [ "$v" != "gateway.web.k8s.local" ] && echo "Listener hostname is '${v}' - expected gateway.web.k8s.local. This is the NEW hostname; the Ingress keeps web.k8s.local until you retire it."
      v=$(echo "$l" | jq -r '.tls.mode // "<unset>"')
      [ "$v" != "Terminate" ] && echo "Listener tls.mode is '${v}' - expected Terminate."
      v=$(echo "$l" | jq -r '[.tls.certificateRefs[]?.name] | join(",")')
      [ "$v" != "web-tls" ] && echo "Listener tls.certificateRefs names '${v:-<none>}' - reference Secret web-tls, the same certificate the Ingress already uses."
      exit 0
    failcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      for r in deployment/web-backend service/web-backend secret/web-tls; do
        if ! kubectl get -n web "$r" >/dev/null 2>&1; then
          echo "Constraint violated: $r no longer exists in namespace web. The app must not be modified."
          exit 1
        fi
      done
      exit 0
    run: |
      set -euo pipefail
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        if [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
          export KUBECONFIG="$kube"
          break
        fi
      done
      ns=web
      kubectl get gateway -n "$ns" web-gateway >/dev/null
      kubectl get gateway web-gateway -n "$ns" -o json | jq -e '
        .spec.gatewayClassName == "nginx" and
        ((.spec.listeners // []) | map(select(.name == "https")) | length) == 1 and
        ((.spec.listeners // []) | map(select(.name == "https")) | .[0] | .protocol == "HTTPS") and
        ((.spec.listeners // []) | map(select(.name == "https")) | .[0] | (.port == 443 or .port == "443")) and
        ((.spec.listeners // []) | map(select(.name == "https")) | .[0] | .hostname == "gateway.web.k8s.local") and
        ((.spec.listeners // []) | map(select(.name == "https")) | .[0] | .tls.mode == "Terminate") and
        ((.spec.listeners // []) | map(select(.name == "https")) | .[0] | .tls.certificateRefs // [] | map(select(.name == "web-tls" and (.kind == "Secret" or .kind == null or .kind == ""))) | length) == 1
      ' >/dev/null

  verify_httproute_created:
    machine: k3s-01
    user: laborant
    needs:
      - verify_gateway_created
    hintcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      if ! kubectl get httproute web-route -n web >/dev/null 2>&1; then
        if kubectl get httproute -n web --no-headers 2>/dev/null | grep -q .; then
          echo "There is an HTTPRoute in namespace web, but none named 'web-route':"
          kubectl get httproute -n web
        fi
        exit 0
      fi
      h="$(kubectl get httproute web-route -n web -o json)"
      if [ "$(echo "$h" | jq -r '[.spec.parentRefs[]? | select(.name=="web-gateway")] | length')" = "0" ]; then
        echo "No parentRef points at Gateway web-gateway. An HTTPRoute attaches to a Gateway through spec.parentRefs - there is no ingressClassName equivalent here."
      fi
      if [ "$(echo "$h" | jq -r '[.spec.hostnames[]? | select(. == "gateway.web.k8s.local")] | length')" = "0" ]; then
        echo "spec.hostnames is $(echo "$h" | jq -rc '.spec.hostnames // []') - it must include gateway.web.k8s.local. If it does not intersect the Gateway listener hostname, the route will not attach."
      fi
      if [ "$(echo "$h" | jq -r '[.spec.rules[]?.backendRefs[]? | select(.name=="web-backend")] | length')" = "0" ]; then
        echo "No rule forwards to Service web-backend. The workload is unchanged by this migration - point backendRefs at the same Service the Ingress used, on port 80."
      fi
      st=$(echo "$h" | jq -r '[.status.parents[]?.conditions[]? | select(.type=="Accepted") | .status] | first // ""')
      if [ -n "$st" ] && [ "$st" != "True" ]; then
        echo "The controller has not accepted this route:"
        kubectl get httproute web-route -n web -o jsonpath='{range .status.parents[*]}{range .conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}{end}' 2>/dev/null
      fi
      exit 0
    failcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      for r in deployment/web-backend service/web-backend secret/web-tls; do
        if ! kubectl get -n web "$r" >/dev/null 2>&1; then
          echo "Constraint violated: $r no longer exists in namespace web. The app must not be modified."
          exit 1
        fi
      done
      exit 0
    run: |
      set -euo pipefail
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        if [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
          export KUBECONFIG="$kube"
          break
        fi
      done
      ns=web
      kubectl get httproute -n "$ns" web-route >/dev/null
      kubectl get httproute web-route -n "$ns" -o json | jq -e '
        ((.spec.parentRefs // []) | map(select(.name == "web-gateway")) | length) >= 1 and
        ((.spec.hostnames // []) | contains(["gateway.web.k8s.local"])) and
        ((.spec.rules // []) | map(
            . as $r |
            ($r.matches // []) | map(select((.path.type // "") == "PathPrefix" and (.path.value // "") == "/")) | length as $pm |
            ($r.backendRefs // []) | map(select(.name == "web-backend" and (.port == null or .port == 80 or .port == "80"))) | length as $br |
            ($pm > 0 and $br > 0)
          ) | any)
      ' >/dev/null

  verify_curl_backend_http:
    machine: k3s-01
    user: laborant
    needs:
      - verify_httproute_created
    timeout_seconds: 300
    hintcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      prog=$(kubectl get gateway web-gateway -n web -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
      if [ "$prog" != "True" ]; then
        echo "Gateway web-gateway is not Programmed yet (Programmed=${prog:-<none>}). Controller conditions:"
        kubectl get gateway web-gateway -n web -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}' 2>/dev/null
        exit 0
      fi
      if ! kubectl get svc -n web web-gateway-nginx >/dev/null 2>&1; then
        echo "Gateway is Programmed, but data plane Service web-gateway-nginx does not exist yet - NGINX Gateway Fabric provisions one nginx deployment per Gateway. Watch it appear with 'kubectl get pods,svc -n web'."
        exit 0
      fi
      if kubectl get deploy -n web web-gateway-nginx >/dev/null 2>&1; then
        ready=$(kubectl get deploy -n web web-gateway-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        if [ -z "$ready" ] || [ "$ready" = "0" ]; then
          echo "Data plane Deployment web-gateway-nginx has no ready replicas yet (the image pull can take a minute). Inspect with 'kubectl describe -n web \$(kubectl get pod -n web -l gateway.networking.k8s.io/gateway-name=web-gateway -o name | head -1)' - describe needs a concrete pod to print its Events."
        fi
      fi
      exit 0
    failcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      for r in deployment/web-backend service/web-backend secret/web-tls; do
        if ! kubectl get -n web "$r" >/dev/null 2>&1; then
          echo "Constraint violated: $r no longer exists in namespace web. The app must not be modified."
          exit 1
        fi
      done
      exit 0
    run: |
      set -euo pipefail
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        if [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
          export KUBECONFIG="$kube"
          break
        fi
      done
      kubectl get svc -n web web-gateway-nginx >/dev/null
      GW_IP=$(kubectl get svc -n web web-gateway-nginx -o jsonpath='{.spec.clusterIP}')
      POD="verify-curl-gw-${RANDOM}"
      kubectl run "$POD" -n web --image=curlimages/curl:8.12.1 --restart=Never --command -- sleep 300
      kubectl wait --for=condition=Ready "pod/$POD" -n web --timeout=120s
      code=$(kubectl exec -n web "$POD" -- curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --resolve "gateway.web.k8s.local:443:${GW_IP}" "https://gateway.web.k8s.local/" || echo "000")
      kubectl delete pod -n web "$POD" --ignore-not-found --wait=false
      [ "$code" = "200" ]

  verify_hostname_cutover:
    machine: k3s-01
    user: laborant
    needs:
      - verify_curl_backend_http
    timeout_seconds: 300
    hintcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      g="$(kubectl get gateway web-gateway -n web -o json 2>/dev/null || echo '{}')"
      n=$(echo "$g" | jq -r '[.spec.listeners[]? | select(.hostname=="web.k8s.local" and .protocol=="HTTPS")] | length')
      if [ "$n" = "0" ]; then
        echo "No HTTPS listener on web-gateway serves hostname web.k8s.local yet. Listener names cannot repeat - add a second listener (e.g. name it https-prod) with the production hostname, same port 443, same TLS setup. Current listeners: $(echo "$g" | jq -rc '[.spec.listeners[]? | {name, hostname}]')"
        exit 0
      fi
      l=$(echo "$g" | jq '[.spec.listeners[] | select(.hostname=="web.k8s.local" and .protocol=="HTTPS")][0]')
      v=$(echo "$l" | jq -r '.tls.mode // "<unset>"')
      [ "$v" != "Terminate" ] && echo "The web.k8s.local listener has tls.mode '${v}' - expected Terminate." && exit 0
      v=$(echo "$l" | jq -r '[.tls.certificateRefs[]?.name] | join(",")')
      if [ "$v" != "web-tls" ]; then
        echo "The web.k8s.local listener references certificate '${v:-<none>}' - reuse Secret web-tls. Its SAN list already covers web.k8s.local (inspect it with openssl as shown in the intro)."
        exit 0
      fi
      h="$(kubectl get httproute web-route -n web -o json 2>/dev/null || echo '{}')"
      if [ "$(echo "$h" | jq -r '[.spec.hostnames[]? | select(. == "web.k8s.local")] | length')" = "0" ]; then
        echo "The Gateway listens for web.k8s.local, but HTTPRoute web-route does not include it in spec.hostnames - the route only attaches for hostnames it declares. Current: $(echo "$h" | jq -rc '.spec.hostnames // []')"
        exit 0
      fi
      echo "Gateway and HTTPRoute both cover web.k8s.local - waiting for the data plane to serve HTTP 200 for it (this can lag reconciliation by a few seconds)."
      exit 0
    failcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      for r in deployment/web-backend service/web-backend secret/web-tls; do
        if ! kubectl get -n web "$r" >/dev/null 2>&1; then
          echo "Constraint violated: $r no longer exists in namespace web. The app must not be modified."
          exit 1
        fi
      done
      exit 0
    run: |
      set -euo pipefail
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        if [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
          export KUBECONFIG="$kube"
          break
        fi
      done
      g="$(kubectl get gateway web-gateway -n web -o json)"
      echo "$g" | jq -e '
        [.spec.listeners[]? | select(
          .hostname == "web.k8s.local" and
          .protocol == "HTTPS" and
          (.port == 443 or .port == "443") and
          .tls.mode == "Terminate" and
          ([.tls.certificateRefs[]? | select(.name == "web-tls" and (.kind == "Secret" or .kind == null or .kind == ""))] | length) >= 1
        )] | length >= 1
      ' >/dev/null
      kubectl get httproute web-route -n web -o json | jq -e '
        (.spec.hostnames // []) | contains(["web.k8s.local"])
      ' >/dev/null
      GW_IP=$(kubectl get svc -n web web-gateway-nginx -o jsonpath='{.spec.clusterIP}')
      POD="verify-curl-cut-${RANDOM}"
      kubectl run "$POD" -n web --image=curlimages/curl:8.12.1 --restart=Never --command -- sleep 300
      kubectl wait --for=condition=Ready "pod/$POD" -n web --timeout=120s
      code=$(kubectl exec -n web "$POD" -- curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --resolve "web.k8s.local:443:${GW_IP}" "https://web.k8s.local/" || echo "000")
      kubectl delete pod -n web "$POD" --ignore-not-found --wait=false
      [ "$code" = "200" ]

  verify_ingress_deleted:
    machine: k3s-01
    user: laborant
    needs:
      - verify_hostname_cutover
    timeout_seconds: 300
    hintcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      if kubectl get ingress web -n web >/dev/null 2>&1; then
        echo "Ingress 'web' is still present. The production hostname is already served by the Gateway, so the legacy entry point is no longer carrying any traffic."
        exit 0
      fi
      g="$(kubectl get gateway web-gateway -n web -o json 2>/dev/null || echo '{}')"
      if [ "$(echo "$g" | jq -r '[.spec.listeners[]? | select(.hostname=="web.k8s.local")] | length')" = "0" ]; then
        echo "The Ingress is gone, but no Gateway listener serves web.k8s.local. Production is down. Restore the listener from Step 4."
      fi
      exit 0
    failcheck: |
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1 && export KUBECONFIG="$kube" && break
      done
      for r in deployment/web-backend service/web-backend secret/web-tls; do
        if ! kubectl get -n web "$r" >/dev/null 2>&1; then
          echo "Constraint violated: $r no longer exists in namespace web. The app must not be modified."
          exit 1
        fi
      done
      exit 0
    run: |
      set -euo pipefail
      for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
        if [ -f "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
          export KUBECONFIG="$kube"
          break
        fi
      done
      # "! cmd" is exempt from errexit, so test existence explicitly.
      if kubectl get ingress web -n web >/dev/null 2>&1; then
        echo "Ingress web still exists in namespace web."
        exit 1
      fi
      # Deleting the Ingress must not take the app down: the production hostname
      # has to keep serving through the Gateway.
      GW_IP=$(kubectl get svc -n web web-gateway-nginx -o jsonpath='{.spec.clusterIP}')
      POD="verify-curl-fin-${RANDOM}"
      kubectl run "$POD" -n web --image=curlimages/curl:8.12.1 --restart=Never --command -- sleep 300
      kubectl wait --for=condition=Ready "pod/$POD" -n web --timeout=120s
      code=$(kubectl exec -n web "$POD" -- curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --resolve "web.k8s.local:443:${GW_IP}" "https://web.k8s.local/" || echo "000")
      kubectl delete pod -n web "$POD" --ignore-not-found --wait=false
      [ "$code" = "200" ]

playground:
  name: k3s-bare
  machines:
    - name: k3s-01
      startupFiles:
        - path: /home/laborant/challenge-workload.yaml
          owner: laborant
          mode: "644"
          content: |
            # Workload seed: namespace + Deployment + Service (no TLS, no Ingress).
            # Applied by lab init. Keep in sync with index.md playground → challenge-workload.yaml.
            apiVersion: v1
            kind: Namespace
            metadata:
              name: web
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: web-backend
              namespace: web
            spec:
              replicas: 2
              selector:
                matchLabels:
                  app: web-backend
              template:
                metadata:
                  labels:
                    app: web-backend
                spec:
                  containers:
                    - name: app
                      image: nginx:stable
                      ports:
                        - containerPort: 80
            ---
            apiVersion: v1
            kind: Service
            metadata:
              name: web-backend
              namespace: web
            spec:
              selector:
                app: web-backend
              ports:
                - port: 80
                  targetPort: 80

        - path: /home/laborant/challenge-tls.yaml
          owner: laborant
          mode: "644"
          content: |
            # TLS Secret for Ingress / Gateway (same cert data as before).
            # Applied by lab init. Keep in sync with index.md playground → challenge-tls.yaml.
            apiVersion: v1
            kind: Secret
            metadata:
              name: web-tls
              namespace: web
            type: kubernetes.io/tls
            data:
              tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUM5akNDQWQ2Z0F3SUJBZ0lKQU4zWHVaZVowR1dOTUEwR0NTcUdTSWIzRFFFQkN3VUFNQ0F4SGpBY0JnTlYKQkFNTUZXZGhkR1YzWVhrdWQyVmlMbXM0Y3k1c2IyTmhiREFlRncweU5qQXpNakF4TXpBeE1ESmFGdzB5TnpBegpNakF4TXpBeE1ESmFNQ0F4SGpBY0JnTlZCQU1NRldkaGRHVjNZWGt1ZDJWaUxtczRjeTVzYjJOaGJEQ0NBU0l3CkRRWUpLb1pJaHZjTkFRRUJCUUFEZ2dFUEFEQ0NBUW9DZ2dFQkFKcks2Qnc1dVp6TVNxVCt1OVBlWTJHZUpCK2wKSmJRK2NGeVdnZDdqTG9tanZDMDRpdzdtT3dwWElPZVNlbkFCaHhhN1IwM0FRRHpjZlQ2QmZmSDlIbWJiOWc1VQp0NWszQ1BIcjk2bG5FWVl1MDZyV3ZycjFsbHQ3OHBqRURCWis1eVYwdFdSNDRRMlV1NytqV3g2TVgyS1o1akw2Cms2emNvcGhmQnVHZ0FxZktTNlM5aW5CbzFHRlZiOGk3azNHVXE5VlE3NjlnUE82c2F2SldkamJNTGtmT3J1Yi8KcEI0TVh0cHIzOXo0YmhsR2hVOTNqbDV5T1RrS2R1U0dSU1JjanFzYzZNdENJNXQ1dDBBSmtJSXVUbUxaUW9wVgpteDlWTHpEbGMyU2MyMUJZejNKSFV5OHNSRitFV0NURC9rWmFEVDFCSWpQeFFUcVg2OVR2aXBIakJBOENBd0VBCkFhTXpNREV3THdZRFZSMFJCQ2d3Sm9JVloyRjBaWGRoZVM1M1pXSXVhemh6TG14dlkyRnNnZzEzWldJdWF6aHoKTG14dlkyRnNNQTBHQ1NxR1NJYjNEUUVCQ3dVQUE0SUJBUUFpL2VxbmRjM1ltTXVFTlpKT21kaGp4VUVxbC80eApaWWpUQnRIK2lsSUxYK0lDNEhPMFNiWWp3bUw2MnJTTTFJVmduTWwyVm81emV2L2w4cm9tdkxPdTU1VDY5a2VQClptTWM3VUlpTmlwZ1Q5MWhpbUtjZVBXenR3NXFiWklEMmpIQi9uYkVMSVp6SDl6c1BpY0RQejZ0K29aMkYvSHEKcjlIVDVNKyt0RVMzZWE4ZkwzWlJDQlh0SGoxVmMrbUhyVGExTWUzVWlKNXlWY0c5RGliSHpSZkN5SEowS0FrcwpSWTVwcVc0WEZKYm9VL21EWGpzOWdRRTU4WUt0ZWlFMlZWb05jZCtEa3dPUGdQL1U2aVEySDdYQVZSakNPMGhXClE1TWRnQVdSWGl0VENPR2xiMU9HaGU0TUVDRk5kMHhwN3pzaUpWd1RrS0RSYUtOQzBzTzJYL0lVCi0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K
              tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUV2UUlCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQktjd2dnU2pBZ0VBQW9JQkFRQ2F5dWdjT2JtY3pFcWsKL3J2VDNtTmhuaVFmcFNXMFBuQmNsb0hlNHk2Sm83d3RPSXNPNWpzS1Z5RG5rbnB3QVljV3UwZE53RUE4M0gwKwpnWDN4L1I1bTIvWU9WTGVaTndqeDYvZXBaeEdHTHRPcTFyNjY5WlpiZS9LWXhBd1dmdWNsZExWa2VPRU5sTHUvCm8xc2VqRjlpbWVZeStwT3MzS0tZWHdiaG9BS255a3Vrdllwd2FOUmhWVy9JdTVOeGxLdlZVTyt2WUR6dXJHcnkKVm5ZMnpDNUh6cTdtLzZRZURGN2FhOS9jK0c0WlJvVlBkNDVlY2prNUNuYmtoa1VrWEk2ckhPakxRaU9iZWJkQQpDWkNDTGs1aTJVS0tWWnNmVlM4dzVYTmtuTnRRV005eVIxTXZMRVJmaEZna3cvNUdXZzA5UVNJejhVRTZsK3ZVCjc0cVI0d1FQQWdNQkFBRUNnZ0VBYTRKdVA5eGY3R1YvbXFWS00xY01VMnFRMEdIVmxDQ2h6Y3pER3RsVEkwblQKa3R6b3lFcGp5MFRFbDlJR3MvQjdzUEFXRUF4dEVWaGFyS1Vub29FWk1udW5wRUIyM0RWN1F2dVBJZHR5TW00bgptVXBaWW1UY0wySWhGclZqWitSd0NuWEszcU9PTys2SGtBeVhadG84RGJHeVRzbjI4Mkt5azMyOHU4eDB5N0FDCjEyc2l3U3JIUnJ0Z3psb1Ard0FqaHRhOHNqMVdZNmJROEhxM21KZVdMTFZnZ20xM3ZYbDlTeGlOYXpxWUJRcVYKZUljc1doR21aVGVYRmt5NDZLb24vRzJWaEk4US9pYVVrMVlmUlFWYnhQYnVteUlSNkpDcktrYUlaODNXUGJUNQppSGRCTTdjU0p0c2tFdisxM25CWFNjTnlwVlJxTjM1ZGNxazZYdGlpZ1FLQmdRREtRTFlNYTFyUVRKNXgrNXhoCmkyMCtSZitDSG9UMkRkQm56VUxaa3hiOSs5UmdzMk9Cam8rYzVZUnNZcUg1VWE4WlprR09lWng2cTJWdzhUMjUKc3NwVldBSVVtN1ZBc1RYdExmV3A4Y0Q3TDJOdGR2bnpCazNLOUhlc3FWUlRNNTY1N1d1SW5PQnhudEloNU9UWgptLzA2RHMzV25RRXBEc3hsT2Q2L3llMjRvUUtCZ1FERDdYanJTNVdPTUxWSXhjNDZVV3JIb1hYSS9Jd3M0TU05CmZtUFlkamxvZUJpWi9tVHpMV2dSVlNVNVRZd0RkMk5Db24xQXFuVE56UlhKSklTcjJucGlsMkptN2lOaFA4YloKdE1xcnVxa3ZHbmxQZXE1Y0NJQjdJZHl1UU4zaTVsaUZSaUkxSHdMSERnMytKMGk1NG5JSGpZenpTVDFxOHFPZgpiNnAxNXFrT3J3S0JnRGp4eDAvdjJmM1QxTGlhOHdpenpPby9veFRycXR2c1A4VTZFWnhZd1p4NUR1NjdFMFVpCjhtUm1hc1pwYnRsWG1razRkVFM4SU1hWkExS3RXWWV6UXl5TVB1bTJmVzNkZHlWMFR6cXVDbnV1ZC93V0I0SFoKUUlYb0Z0blNReCs1NVBMTVdmNTR6T2l3b3RGUU5PN2Y4SWdzS3VCR0RGR1hEUTFqSWNnMS9teUJBb0dBVnQ3NgpHRW5CRy9TWXpKVjM1UCtvZXE4cVRGMDl3Y0Era1F0ek5jemxrMTU4ZWZzRHc1YkVaN3I2OERkajl6MStNMU5jCmVjbWFWSTIwTlNVTjlpeSt5dXdZWTA3L1BPVk1ROGNYZmFFYjFwakVaT3NlV0F3ayszTitKM3ozWk4yQkxrWjAKY0YwNW5BeXRRNTBqYjlmcGUxUFZ4U0VhTEVzOUpUb2J1SDczUWwwQ2dZRUFsL2p6TEFFdGhnNmpzZUh1SlNSYwp2dlQvNzM4QVNTZC9DMjhFc0ZjNCtsanM4NWk3K0drWklSa2daZzIzYWsxbkhtK3VpT1dsSzhTZ0VLZjBnZTBKCittR00vUXFDMG1mamI3VVZMMm5hOXNGUk41WjhleGlqSS9HMUNVRDQvaDdSNVYvNnZTN3JIc1Y2WTRGcnpZWk8KRVh4czN0VGtFd2YxRjh3b2ZNUVpSZmM9Ci0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0K
        - path: /home/laborant/challenge-ingress.yaml
          owner: laborant
          mode: "644"
          content: |
            # Ingress baseline (applied by lab init). This block is the source of truth.
            apiVersion: networking.k8s.io/v1
            kind: Ingress
            metadata:
              name: web
              namespace: web
            spec:
              ingressClassName: nginx
              tls:
                - hosts:
                    - web.k8s.local
                  secretName: web-tls
              rules:
                - host: web.k8s.local
                  http:
                    paths:
                      - path: /
                        pathType: Prefix
                        backend:
                          service:
                            name: web-backend
                            port:
                              number: 80

---

A ticket lands in your queue:

> **PLAT-2119: Migrate `web` off ingress-nginx**
> The platform team is deprecating ingress-nginx. Move the `web-backend` app in namespace `web` to the Gateway API. Clients keep calling `https://web.k8s.local/` with no downtime. Do not change the app.

The cluster is single-node K3s. Namespace **`web`** holds Deployment and Service **`web-backend`**. An Ingress named **`web`** serves **`https://web.k8s.local/`**. ingress-nginx terminates TLS with Secret **`web-tls`**.

Why migrate: Kubernetes native Ingress has no standard fields for traffic splitting, header matching, or cross-namespace routing. Each controller filled the gap with its own annotations, so manifests are not portable. The **Gateway API** replaces Ingress and is part of the current CKA (Certified Kubernetes Administrator) curriculum. It splits the config by owner: a **Gateway** holds the listener, port, and certificate. An **HTTPRoute** holds hostnames and path rules.

The plan:

1. Create the new path on a staging hostname: **`gateway.web.k8s.local`**.
2. Verify it serves traffic.
3. Move the production hostname to it.
4. Delete the Ingress.

Both controllers run at the same time during the migration. This is normal. ingress-nginx keeps the Ingress working while **NGINX Gateway Fabric** handles the Gateway resources.

Constraints:

- Do not modify the Deployment or the Service.
- Reuse Secret **`web-tls`**. Do not create new certificates.

### Pre-flight

**Note:** the init scripts take about 30 to 40 seconds to set up the cluster. Please wait for them to finish before you start.

Inspect what you inherited:

```bash
kubectl get ingress web -n web -o yaml
```

One resource holds the hostname, the TLS config, and the routing.

Check the certificate. A cutover needs a certificate that covers every hostname you plan to serve:

```bash
kubectl get secret web-tls -n web -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -ext subjectAltName
```

### Step 1: Create the Gateway

In namespace **`web`**, create a Gateway named **`web-gateway`**:

- It uses the GatewayClass that the cluster's controller provides.
- It has one listener named **`https`**: HTTPS on port **443** for hostname **`gateway.web.k8s.local`**, terminating TLS with Secret **`web-tls`**.

::simple-task
---
:tasks: tasks
:name: verify_gateway_created
---
#active
Checking Gateway **web-gateway**…

#completed
Gateway **web-gateway** matches the required spec.
::

::hint-box
---
:summary: Gateway manifest shape
---
Find the class with `kubectl get gatewayclass`. Explore the fields with **`kubectl explain gateway.spec.listeners --recursive`**. TLS settings live under `listeners[].tls`: a mode and a list of certificate refs.
::

### Step 2: Create the HTTPRoute

The Gateway listens, but nothing routes yet. In namespace **`web`**, create an HTTPRoute named **`web-route`**. It must attach to **`web-gateway`**, accept hostname **`gateway.web.k8s.local`**, and route every path to Service **`web-backend`**.

::simple-task
---
:tasks: tasks
:name: verify_httproute_created
---
#active
Checking HTTPRoute **web-route**…

#completed
HTTPRoute **web-route** matches the required spec.
::

::hint-box
---
:summary: HTTPRoute vs Ingress
---
An HTTPRoute attaches to a Gateway through **`spec.parentRefs`**. There is no `ingressClassName` here. Map the Ingress fields you read during pre-flight: rule `host` becomes `spec.hostnames`, `http.paths` becomes `rules[].matches`, `backend.service` becomes `rules[].backendRefs`. Route hostnames must intersect the listener hostname, or the route does not attach.
::

### Step 3: Verify the staging path

NGINX Gateway Fabric now reconciles your resources. The Gateway reaches **`Programmed`**, and the controller creates a data plane Deployment and Service named **`web-gateway-nginx`** in namespace `web`. This takes about a minute.

Then verify like a client would: resolve **`gateway.web.k8s.local`** to the data plane Service's ClusterIP and request `/` over HTTPS. Expect **200**. Also confirm the old path still serves. Both paths running at once is the migration window.

::simple-task
---
:tasks: tasks
:name: verify_curl_backend_http
---
#active
Verifying the staging path…

#completed
Staging path serves **HTTP 200**. Checked with an in-cluster `curl` pod against the **`web-gateway-nginx`** Service ClusterIP.
::

::hint-box
---
:summary: Verification and debugging
---
`curl --resolve` pins a hostname to an IP for one request:

```bash
GW_IP=$(kubectl get svc -n web web-gateway-nginx -o jsonpath='{.spec.clusterIP}')
curl -k --resolve "gateway.web.k8s.local:443:${GW_IP}" https://gateway.web.k8s.local/
```

If `GW_IP` is empty, the Service does not exist yet. Check **`kubectl describe gateway web-gateway -n web`** for status conditions, and **`status.parents[].conditions`** in the HTTPRoute. A route that is not `Accepted` usually has a wrong `parentRefs` name or non-matching hostnames. The old path uses the `ingress-nginx-controller` Service ClusterIP the same way.
::

### Step 4: Move the production hostname

Clients call **`web.k8s.local`**. Extend **`web-gateway`** and **`web-route`** so `https://web.k8s.local/` answers through the Gateway as well. Listener names are unique within a Gateway. Reuse the same certificate.

Verify the same way as Step 3, now for **`web.k8s.local`**. In production this step is a DNS change. The `--resolve` flag simulates it.

::simple-task
---
:tasks: tasks
:name: verify_hostname_cutover
---
#active
Verifying **web.k8s.local** through the Gateway…

#completed
Cutover done: **`https://web.k8s.local/`** returns **HTTP 200** through the Gateway.
::

::hint-box
---
:summary: Editing live resources
---
`kubectl edit` or re-applying an updated manifest both work. `listeners` is an array: append a second HTTPS listener with a new name (for example `https-prod`) for `web.k8s.local`, and add the hostname to the route's `spec.hostnames`. After the edit, **`status.listeners[].attachedRoutes`** on the Gateway should show **1** for the new listener.
::

### Step 5: Delete the Ingress

```bash
kubectl delete ingress web -n web
```

The check passes only when the Ingress is gone and **`web.k8s.local`** still returns 200 through the Gateway.

::simple-task
---
:tasks: tasks
:name: verify_ingress_deleted
---
#active
Waiting for Ingress **web** to be deleted while **web.k8s.local** keeps serving…

#completed
Ingress removed. **`web.k8s.local`** still returns **HTTP 200** through the Gateway. Migration complete.
::

### Related on iximiuz Labs

Gateway API challenges by other authors, once the migration here is done:

- [Expose Internal Services Using NGINX Kubernetes Gateway API](https://labs.iximiuz.com/challenges/expose-internal-services-using-gateway-api-351e7e74) by Omkar Shelke. Path-based routing on a Gateway you build from scratch
- [Cross-Namespace Gateway and HTTPRoute Binding with Kubernetes Gateway API](https://labs.iximiuz.com/challenges/cross-namespace-gateway-api-routing-2cfcf387) by Omkar Shelke. Splitting the Gateway and the HTTPRoute across namespaces, the way a platform team would
- [Canary Deployment Using Kubernetes Gateway API Traffic Splitting](https://labs.iximiuz.com/challenges/canary-deployment-using-kubernetes-gatewaya-api-traffic-splitting-453178d3) by Omkar Shelke. Traffic splitting, which is the thing Ingress could never do cleanly

### References

- [Gateway API](https://gateway-api.sigs.k8s.io/) and the [full spec](https://gateway-api.sigs.k8s.io/reference/spec/)
- [Migrating from Ingress](https://gateway-api.sigs.k8s.io/guides/migrating-from-ingress/), the upstream guide for this cutover
- Kubernetes docs: [Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/), [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric): provides the GatewayClass. Init pins [v2.4.2](https://github.com/nginx/nginx-gateway-fabric/tree/v2.4.2/deploy) with [Gateway API v1.4.1](https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.4.1) CRDs.
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx/deploy/): bare-metal manifest for the legacy path
