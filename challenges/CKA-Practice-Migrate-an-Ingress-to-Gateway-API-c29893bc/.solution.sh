# session: laborant@k3s-01
# The solution runs as laborant, and /etc/rancher/k3s/k3s.yaml is root-only on
# k3s-bare. Use the same discovery the challenge's own tasks use: take whichever
# kubeconfig this user can actually read.
for kube in /etc/rancher/k3s/k3s.yaml /home/laborant/.kube/config; do
  if [ -r "$kube" ] && KUBECONFIG="$kube" kubectl get ns default >/dev/null 2>&1; then
    export KUBECONFIG="$kube"
    break
  fi
done

# 1. Stand the Gateway and HTTPRoute up on the staging hostname, leaving the
#    production Ingress untouched and serving.
kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: web
spec:
  gatewayClassName: nginx
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: gateway.web.k8s.local
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: web-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-route
  namespace: web
spec:
  parentRefs:
    - name: web-gateway
  hostnames:
    - gateway.web.k8s.local
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: web-backend
          port: 80
YAML
kubectl wait --for=condition=Programmed gateway/web-gateway -n web --timeout=300s
examinerctl task wait verify_gateway_created --timeout 300s
examinerctl task wait verify_httproute_created --timeout 300s

# NGF names the data plane Service after the Gateway; it appears shortly after
# the Gateway is Programmed.
for i in $(seq 1 36); do
  kubectl get svc -n web web-gateway-nginx >/dev/null 2>&1 && break
  sleep 5
done
examinerctl task wait verify_curl_backend_http --timeout 600s

# 2. Move the production hostname onto the Gateway.
kubectl patch gateway web-gateway -n web --type=json -p '[{"op":"add","path":"/spec/listeners/-","value":{"name":"https-prod","protocol":"HTTPS","port":443,"hostname":"web.k8s.local","tls":{"mode":"Terminate","certificateRefs":[{"kind":"Secret","name":"web-tls"}]}}}]'
kubectl patch httproute web-route -n web --type=json -p '[{"op":"add","path":"/spec/hostnames/-","value":"web.k8s.local"}]'
examinerctl task wait verify_hostname_cutover --timeout 600s

# 3. Retire the Ingress only once the Gateway is serving production.
kubectl delete ingress web -n web
examinerctl task wait verify_ingress_deleted --timeout 600s
