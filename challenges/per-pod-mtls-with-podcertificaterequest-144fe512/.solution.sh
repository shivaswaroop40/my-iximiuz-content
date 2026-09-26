# session: root@cplane-01
export KUBECONFIG=/etc/kubernetes/admin.conf

# 1. The signer watches pki.example.com/workload-identity-v2 while the workload
#    asks for pki.example.com/workload-identity, so every request sits unanswered.
#    Point the signer at the name that is actually being requested.
WANT=$(kubectl -n payments get deployment payments-api -o json \
  | jq -r '[.spec.template.spec.volumes[]?.projected?.sources[]?.podCertificate.signerName] | .[0]')
mkdir -p /etc/systemd/system/pod-identity-signer.service.d
cat > /etc/systemd/system/pod-identity-signer.service.d/override.conf <<OVERRIDE
[Service]
Environment=SIGNER_NAME=${WANT}
OVERRIDE
# A unit change needs a reload before a restart; systemd otherwise runs what it
# already loaded.
systemctl daemon-reload
systemctl restart pod-identity-signer
kubectl -n payments rollout status deployment payments-api --timeout=600s
examinerctl task wait verify_certs_issued --timeout 900s

# 2. Give the client an identity of its own, from the same signer.
kubectl -n payments patch deployment checkout --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{\"name\":\"pod-identity\",\"projected\":{\"sources\":[{\"podCertificate\":{\"signerName\":\"${WANT}\",\"keyType\":\"ECDSAP256\",\"keyPath\":\"tls.key\",\"certificateChainPath\":\"tls.crt\",\"maxExpirationSeconds\":3600}}]}}},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{\"name\":\"pod-identity\",\"mountPath\":\"/var/run/pod-identity\",\"readOnly\":true}}
]"
kubectl -n payments rollout status deployment/checkout --timeout=300s
examinerctl task wait verify_client_identity --timeout 600s

# 3. Make the server require and verify a client certificate. Issuing identities
#    and enforcing them are separate jobs.
kubectl -n payments get configmap payments-api-nginx -o jsonpath='{.data.default\.conf}' > /tmp/default.conf
sed -i 's|ssl_verify_client off;|ssl_client_certificate /etc/pod-identity/ca.crt;\n      ssl_verify_client on;|' /tmp/default.conf
kubectl -n payments create configmap payments-api-nginx --from-file=default.conf=/tmp/default.conf \
  --dry-run=client -o yaml | kubectl apply -f -
# nginx reads its configuration at startup; a ConfigMap update restarts nothing.
kubectl -n payments rollout restart deployment payments-api
kubectl -n payments rollout status deployment payments-api --timeout=300s
examinerctl task wait verify_mtls_enforced --timeout 600s
