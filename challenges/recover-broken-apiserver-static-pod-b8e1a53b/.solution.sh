# session: root@cplane-01
# A typo in the static pod manifest: --etcd-severs instead of --etcd-servers.
sed -i 's|--etcd-severs=|--etcd-servers=|' /etc/kubernetes/manifests/kube-apiserver.yaml
# The kubelet rescans the manifest directory on its own (fileCheckFrequency, 20s
# by default), so nothing else is needed to restart the static pod.
examinerctl task wait verify_apiserver_recovered --timeout 420s
examinerctl task wait verify_control_plane_pods --timeout 420s
examinerctl task wait verify_cluster_healthy --timeout 600s
