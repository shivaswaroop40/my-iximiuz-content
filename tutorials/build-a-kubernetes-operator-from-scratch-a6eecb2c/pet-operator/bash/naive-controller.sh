#!/usr/bin/env bash
# A minimal controller: read the desired state, create what's missing,
# sleep for a few seconds, and repeat.
while true; do
  for pet in $(kubectl get pets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}'); do
    ns=${pet%/*}; name=${pet#*/}
    species=$(kubectl get pet -n "$ns" "$name" -o jsonpath='{.spec.species}')

    if ! kubectl get pod -n "$ns" "$name" >/dev/null 2>&1; then
      kubectl run "$name" -n "$ns" --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never -- \
        sh -c "while true; do echo \"I am $name the $species\"; sleep 10; done"
    fi
  done
  sleep 5
done
