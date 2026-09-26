#!/usr/bin/env bash
# Runs the challenge's own task scripts (extracted from index.md) against whatever
# cluster the current kubectl context points at, walking through the learner journey:
#
#   1. init             -> scenario files + payments namespace
#   2. no CRD           -> every verify task must FAIL
#   3. naive CRD        -> registered/discoverable pass, schema/defaults/status/columns FAIL
#   4. reference CRD    -> everything except the "apply manifests" + "status" tasks passes
#   5. learner actions  -> apply accepted manifests, patch status -> everything passes
#
# The cluster must be disposable: the script deletes the BackupSchedule CRD and the
# payments namespace's BackupSchedules.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INDEX="$HERE/../../challenges/build-a-validated-crd/index.md"
WORK="$(mktemp -d)"
export HOME="$WORK/home"   # init writes scenario files into $HOME
mkdir -p "$HOME"
cp "${KUBECONFIG:-/root/.kube/config}" "$WORK/kubeconfig"
export KUBECONFIG="$WORK/kubeconfig"

python3 - "$INDEX" "$WORK" <<'PY'
import re, sys, yaml, pathlib
index, work = sys.argv[1], pathlib.Path(sys.argv[2])
fm = yaml.safe_load(re.split(r"^---$\n", open(index).read(), maxsplit=2, flags=re.M)[1])
for name, task in fm["tasks"].items():
    (work / f"{name}.run.sh").write_text(task["run"])
    if "hintcheck" in task:
        (work / f"{name}.hint.sh").write_text(task["hintcheck"])
PY

VERIFY=(verify_crd_registered verify_crd_discoverable verify_schema_accepts_valid
        verify_schema_rejects_invalid verify_cross_field_rule verify_defaults
        verify_status_subresource verify_printer_columns verify_manifests_applied
        verify_status_reported)
FAILURES=0

expect() { # expect <pass|fail> <task>
  local want=$1 task=$2 got
  if bash "$WORK/$task.run.sh" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    printf '  ok    %-30s %s\n' "$task" "$got"
  else
    printf '  FAIL  %-30s wanted %s, got %s\n' "$task" "$want" "$got"
    FAILURES=$((FAILURES + 1))
  fi
  if [ "$got" = fail ] && [ -f "$WORK/$task.hint.sh" ]; then
    bash "$WORK/$task.hint.sh" 2>&1 | sed 's/^/          hint: /'
  fi
}

reset() {
  kubectl delete bks -n payments --all --ignore-not-found >/dev/null 2>&1
  kubectl delete crd backupschedules.platform.example.com --ignore-not-found --wait=true >/dev/null 2>&1
  while kubectl get crd backupschedules.platform.example.com >/dev/null 2>&1; do sleep 1; done
}
apply_crd() { kubectl apply -f "$1" >/dev/null && kubectl wait --for=condition=Established crd/backupschedules.platform.example.com --timeout=30s >/dev/null; sleep 2; }

echo "== init"
reset
bash "$WORK/init_scenario.run.sh" || { echo "init failed"; exit 1; }
ls -R "$HOME" | sed 's/^/  /'

echo "== stage: no CRD"
for t in "${VERIFY[@]}"; do expect fail "$t"; done

echo "== stage: naive CRD (names only, preserve-unknown-fields)"
cat > "$WORK/naive.yaml" <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backupschedules.platform.example.com
spec:
  group: platform.example.com
  scope: Namespaced
  names: {kind: BackupSchedule, plural: backupschedules, singular: backupschedule, shortNames: [bks], categories: [platform]}
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
EOF
apply_crd "$WORK/naive.yaml"
expect pass verify_crd_registered
expect pass verify_crd_discoverable
expect pass verify_schema_accepts_valid
for t in verify_schema_rejects_invalid verify_cross_field_rule verify_defaults \
         verify_status_subresource verify_printer_columns verify_manifests_applied verify_status_reported; do
  expect fail "$t"
done

echo "== stage: reference CRD minus 'retention: default {}' (classic nested-default gotcha)"
reset
sed '/^                default: {}$/d' "$HERE/reference-crd.yaml" > "$WORK/no-parent-default.yaml"
apply_crd "$WORK/no-parent-default.yaml"
expect fail verify_defaults

echo "== stage: reference CRD"
reset
apply_crd "$HERE/reference-crd.yaml"
for t in verify_crd_registered verify_crd_discoverable verify_schema_accepts_valid \
         verify_schema_rejects_invalid verify_cross_field_rule verify_defaults \
         verify_status_subresource verify_printer_columns; do
  expect pass "$t"
done
expect fail verify_manifests_applied

echo "== learner self-check: accepted/ passes, every file in rejected/ bounces"
kubectl apply --dry-run=server -f "$HOME/manifests/accepted/" | sed 's/^/  /'
for f in "$HOME"/manifests/rejected/*.yaml; do
  if kubectl apply --dry-run=server -f "$f" >/dev/null 2>"$WORK/err"; then
    echo "  FAIL  $(basename "$f") was accepted"; FAILURES=$((FAILURES + 1))
  else
    echo "  ok    $(basename "$f"): $(cat "$WORK/err")"
  fi
done

echo "== stage: learner applies accepted manifests"
kubectl apply -f "$HOME/manifests/accepted/" >/dev/null
expect pass verify_manifests_applied
expect fail verify_status_reported

echo "== stage: writing status the wrong way (kubectl apply) is ignored"
kubectl get bks -n payments orders-db-nightly -o json \
  | python3 -c 'import json,sys; o=json.load(sys.stdin); o["status"]={"lastBackupTime":"2026-09-25T02:00:00Z","lastBackupResult":"Succeeded"}; print(json.dumps(o))' \
  | kubectl apply -f - >/dev/null
expect fail verify_status_reported

echo "== stage: learner patches the status subresource"
kubectl patch bks orders-db-nightly -n payments --subresource=status --type=merge \
  -p '{"status":{"lastBackupTime":"2026-09-25T02:00:00Z","lastBackupResult":"Succeeded"}}' >/dev/null
for t in "${VERIFY[@]}"; do expect pass "$t"; done
echo
kubectl get bks -n payments
echo
kubectl get platform -n payments

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL CHECKS BEHAVED AS EXPECTED"; else echo "$FAILURES UNEXPECTED RESULT(S)"; exit 1; fi
