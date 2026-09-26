#!/usr/bin/env bash
# Runs the challenge's own task scripts (extracted from index.md) against whatever
# cluster the current kubectl context points at, walking through the learner journey:
#
#   1. init             -> scenario files + zoo namespace
#   2. no CRD           -> every verify task must FAIL
#   3. naive CRD        -> registered/discoverable pass, schema/rules/defaults/status/columns FAIL
#   4. gotcha variants  -> missing parent default / string-compared durations FAIL the right task
#   5. reference CRD    -> everything except the "adopt" + "status" tasks passes
#   6. learner actions  -> apply adopted pets, patch status -> everything passes
#
# The cluster must be disposable: the script deletes the Pet CRD and the zoo namespace's Pets.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INDEX="$HERE/../../challenges/adopt-a-pet-crd/index.md"
WORK="$(mktemp -d)"
export HOME="$WORK/home"   # init writes scenario files into $HOME
mkdir -p "$HOME"
cp "${KUBECONFIG:-/root/.kube/config}" "$WORK/kubeconfig"
export KUBECONFIG="$WORK/kubeconfig"
CRD=pets.zoo.example.com

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
        verify_schema_rejects_invalid verify_house_rules verify_defaults
        verify_status_subresource verify_printer_columns verify_pets_adopted
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
  kubectl delete pets -n zoo --all --ignore-not-found >/dev/null 2>&1
  kubectl delete crd "$CRD" --ignore-not-found --wait=true >/dev/null 2>&1
  while kubectl get crd "$CRD" >/dev/null 2>&1; do sleep 1; done
}
apply_crd() { kubectl apply -f "$1" >/dev/null && kubectl wait --for=condition=Established "crd/$CRD" --timeout=30s >/dev/null; sleep 2; }

echo "== init"
reset
bash "$WORK/init_scenario.run.sh" >/dev/null || { echo "init failed"; exit 1; }
ls -R "$HOME" | sed 's/^/  /'

echo "== stage: no CRD"
for t in "${VERIFY[@]}"; do expect fail "$t"; done

echo "== stage: naive CRD (names only, preserve-unknown-fields)"
cat > "$WORK/naive.yaml" <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: pets.zoo.example.com
spec:
  group: zoo.example.com
  scope: Namespaced
  names: {kind: Pet, plural: pets, singular: pet, shortNames: [pt], categories: [zoo]}
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
for t in verify_schema_rejects_invalid verify_house_rules verify_defaults \
         verify_status_subresource verify_printer_columns verify_pets_adopted verify_status_reported; do
  expect fail "$t"
done

echo "== stage: reference CRD minus 'diet: default: {}' (nested-default gotcha)"
reset
python3 - "$HERE/reference-crd.yaml" "$WORK/no-parent-default.yaml" <<'PY'
import sys, yaml
crd = yaml.safe_load(open(sys.argv[1]))
del crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["diet"]["default"]
yaml.safe_dump(crd, open(sys.argv[2], "w"), allow_unicode=True)
PY
apply_crd "$WORK/no-parent-default.yaml" 2>/dev/null || echo "  (CRD without parent default was rejected by the API server)"
expect fail verify_defaults

echo "== stage: reference CRD with durations compared as strings (CEL gotcha)"
reset
sed "s/duration(self.diet.feedEvery) >= duration('1h')/self.diet.feedEvery >= '1h'/" "$HERE/reference-crd.yaml" > "$WORK/string-compare.yaml"
apply_crd "$WORK/string-compare.yaml"
expect fail verify_house_rules

echo "== stage: reference CRD without the feedEvery range rule (a pattern checks shape, not size)"
reset
python3 - "$HERE/reference-crd.yaml" "$WORK/no-range.yaml" <<'PY'
import sys, yaml
crd = yaml.safe_load(open(sys.argv[1]))
del crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["diet"]["properties"]["feedEvery"]["x-kubernetes-validations"]
yaml.safe_dump(crd, open(sys.argv[2], "w"), allow_unicode=True)
PY
apply_crd "$WORK/no-range.yaml"
expect fail verify_schema_rejects_invalid

echo "== stage: reference CRD"
reset
apply_crd "$HERE/reference-crd.yaml"
for t in verify_crd_registered verify_crd_discoverable verify_schema_accepts_valid \
         verify_schema_rejects_invalid verify_house_rules verify_defaults \
         verify_status_subresource verify_printer_columns; do
  expect pass "$t"
done
expect fail verify_pets_adopted

echo "== learner self-check: adopted/ passes, every file in turned-away/ bounces"
kubectl apply --dry-run=server -f "$HOME/pets/adopted/" | sed 's/^/  /'
for f in "$HOME"/pets/turned-away/*.yaml; do
  if kubectl apply --dry-run=server -f "$f" >/dev/null 2>"$WORK/err"; then
    echo "  FAIL  $(basename "$f") was accepted"; FAILURES=$((FAILURES + 1))
  else
    echo "  ok    $(basename "$f"): $(tr '\n' ' ' < "$WORK/err")"
  fi
done

echo "== stage: learner adopts the pets"
kubectl apply -f "$HOME/pets/adopted/" >/dev/null
expect pass verify_pets_adopted
expect fail verify_status_reported

echo "== stage: writing status the wrong way (kubectl apply) is ignored"
kubectl get pet -n zoo mochi -o json \
  | python3 -c 'import json,sys; o=json.load(sys.stdin); o["status"]={"mood":"Happy","face":"😺"}; print(json.dumps(o))' \
  | kubectl apply -f - >/dev/null
expect fail verify_status_reported

echo "== stage: learner patches the status subresource"
kubectl patch pet mochi -n zoo --subresource=status --type=merge -p '{"status":{"mood":"Happy","face":"😺"}}' >/dev/null
for t in "${VERIFY[@]}"; do expect pass "$t"; done
echo
kubectl get pets -n zoo
echo
kubectl get zoo -n zoo

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL CHECKS BEHAVED AS EXPECTED"; else echo "$FAILURES UNEXPECTED RESULT(S)"; exit 1; fi
