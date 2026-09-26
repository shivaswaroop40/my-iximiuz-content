## Reference solution

The lab's **init** tasks install the controllers, seed **`challenge-workload.yaml`**, **`challenge-tls.yaml`**, and **`challenge-ingress.yaml`**, and confirm the legacy Ingress serves **HTTPS 200** on **`web.k8s.local`**. Everything you do is the **migration** itself.

### Pre-flight

```bash
kubectl get ingress web -n web -o yaml
kubectl get secret web-tls -n web -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -ext subjectAltName
# SAN covers gateway.web.k8s.local and web.k8s.local
kubectl get gatewayclass   # nginx (NGINX Gateway Fabric)
```

### Step 1: Gateway (staging hostname)

```yaml
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
```

### Step 2: HTTPRoute

```yaml
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
```

### Step 3: Prove the staging path

```bash
kubectl wait --for=condition=Programmed gateway/web-gateway -n web --timeout=180s
GW_IP=$(kubectl get svc -n web web-gateway-nginx -o jsonpath='{.spec.clusterIP}')
curl -k --resolve "gateway.web.k8s.local:443:${GW_IP}" https://gateway.web.k8s.local/   # 200
```

### Step 4: Cut the production hostname over

Add a second listener to the Gateway (listener names must be unique) and the production hostname to the route:

```yaml
# Gateway spec.listeners gains:
    - name: https-prod
      protocol: HTTPS
      port: 443
      hostname: web.k8s.local
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: web-tls
```

```yaml
# HTTPRoute spec.hostnames becomes:
  hostnames:
    - gateway.web.k8s.local
    - web.k8s.local
```

Verify:

```bash
GW_IP=$(kubectl get svc -n web web-gateway-nginx -o jsonpath='{.spec.clusterIP}')
curl -k --resolve "web.k8s.local:443:${GW_IP}" https://web.k8s.local/   # 200 via Gateway
```

### Step 5: Retire the Ingress

```bash
kubectl delete ingress web -n web
GW_IP=$(kubectl get svc -n web web-gateway-nginx -o jsonpath='{.spec.clusterIP}')
curl -k --resolve "web.k8s.local:443:${GW_IP}" https://web.k8s.local/   # still 200
```

