#!/bin/bash
# The playground's init task: waits for the cluster, applies the zoo, and writes each Pet's mood.
set -euo pipefail
for _ in $(seq 1 120); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 2; done
kubectl apply -f /opt/night-keeper-setup/zoo.yaml 2>/dev/null || true   # Pets fail until the CRD is established
kubectl wait --for=condition=Established crd/pets.zoo.example.com --timeout=60s
kubectl apply -f /opt/night-keeper-setup/zoo.yaml
mood() { kubectl patch pet -n zoo "$1" --subresource=status --type=merge -p "{\"status\":{\"mood\":\"$2\",\"face\":\"$3\"}}"; }
mood mochi Hungry 🙀
mood prickles Happy 🌵
mood rex Happy 🐶
mood smaug RanAway 💨
