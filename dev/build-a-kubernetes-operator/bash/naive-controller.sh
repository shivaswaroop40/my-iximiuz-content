#!/usr/bin/env bash
# A controller in its simplest possible form: look at the desired state,
# make the world match it, sleep, repeat. Forever.
while true; do
  for bs in $(kubectl get bks -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}'); do
    ns=${bs%/*}; name=${bs#*/}
    schedule=$(kubectl get bks -n "$ns" "$name" -o jsonpath='{.spec.schedule}')

    kubectl create cronjob "$name-backup" -n "$ns" \
      --image=busybox:1.36 --schedule="$schedule" \
      --dry-run=client -o yaml -- echo "backing up $name" \
      | kubectl apply -f - | grep -v unchanged
  done
  sleep 5
done
