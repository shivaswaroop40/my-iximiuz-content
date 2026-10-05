#!/bin/bash
# The playground's init task: waits for the cluster, gives it a default StorageClass
# (kagent keeps its conversations in a Postgres database that needs a volume), then opens the zoo.
set -euo pipefail
for _ in $(seq 1 120); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 2; done
kubectl apply -f /opt/zoo-setup/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl apply -f /opt/zoo-setup/zoo.yaml
kubectl -n zoo rollout status deploy/mochi deploy/rex deploy/prickles --timeout=300s
