# session: root@cplane-01
export KUBECONFIG=/etc/kubernetes/admin.conf

# Renew every kubeadm-managed leaf certificate from the still-valid cluster CA.
kubeadm certs renew all

# Static pods do not restart on their own when a certificate file changes. Moving
# the manifests out and back makes the kubelet tear them down and recreate them.
WORK=$(mktemp -d)
mv /etc/kubernetes/manifests/*.yaml "${WORK}/"
sleep 10
mv "${WORK}"/*.yaml /etc/kubernetes/manifests/
rmdir "${WORK}"

for i in $(seq 1 90); do
  kubectl get ns default >/dev/null 2>&1 && break
  sleep 4
done

examinerctl task wait verify_certs_renewed --timeout 300s
examinerctl task wait verify_serving_new_cert --timeout 300s

# kubeadm renews the admin kubeconfig it owns, not the copy in laborant's home.
cp /etc/kubernetes/admin.conf /home/laborant/.kube/config
chown laborant:laborant /home/laborant/.kube/config
chmod 600 /home/laborant/.kube/config
examinerctl task wait verify_user_kubeconfig --timeout 300s

examinerctl task wait verify_cluster_healthy --timeout 600s
