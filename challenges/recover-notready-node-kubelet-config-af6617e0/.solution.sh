# session: root@node-02
# The kubelet fails to parse its config: maxPods is int32 and the value is quoted.
sed -i 's/^maxPods: "110"$/maxPods: 110/' /var/lib/kubelet/config.yaml
systemctl restart kubelet
examinerctl task wait verify_kubelet_running --timeout 180s

# session: root@cplane-01
examinerctl task wait verify_node_ready --timeout 300s
# Pods evicted during the outage are replaced once the node is Ready again.
examinerctl task wait verify_workload_healthy --timeout 600s
