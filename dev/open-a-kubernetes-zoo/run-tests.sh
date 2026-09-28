#!/usr/bin/env bash
# Walks the zoo tutorial against whatever cluster the current kubectl context points at,
# using the tutorial's own task scripts and the CRD files the playground ships (pet-crd/):
#
#   1. init             -> scenario files + zoo namespace
#   2. no CRD           -> every verify task must FAIL
#   3. tutorial steps   -> after each of the 5 CRD blocks, exactly the expected tasks pass
#   4. gotcha variants  -> missing parent default / string-compared durations / no range rule
#                          FAIL the right task, with a useful hint
#   5. learner actions  -> apply adopted pets, patch status -> everything passes
#
# The cluster must be disposable: the script deletes the Pet CRD and the zoo namespace's Pets.
# Needs kubectl, python3 with PyYAML, and bash 4+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INDEX="$HERE/../../tutorials/open-a-kubernetes-zoo-9ad54ae8/index.md"
REFERENCE="$HERE/crd/5-status-and-columns.yaml"
WORK="$(mktemp -d)"
cp "${KUBECONFIG:-$HOME/.kube/config}" "$WORK/kubeconfig" || { echo "no kubeconfig to copy"; exit 1; }
export KUBECONFIG="$WORK/kubeconfig"
export HOME="$WORK/home"   # init writes scenario files into $HOME
mkdir -p "$HOME"
CRD=pets.zoo.example.com

"$HERE/render.py" >/dev/null

python3 - "$INDEX" "$WORK" <<'PY'
import re, sys, yaml, pathlib
index, work = sys.argv[1], pathlib.Path(sys.argv[2])
_, fm, body = re.split(r"^---$\n", open(index).read(), maxsplit=2, flags=re.M)
for name, task in yaml.safe_load(fm)["tasks"].items():
    (work / f"{name}.run.sh").write_text(task["run"])
    if "hintcheck" in task:
        (work / f"{name}.hint.sh").write_text(task["hintcheck"])
# The learner applies the CRD versions the playground ships in ~/pet-crd, in the order
# the tutorial's `kubectl apply -f ~/pet-crd/...` commands give.
shipped = pathlib.Path(index).parent / "pet-crd"
steps = re.findall(r"^kubectl apply -f ~/pet-crd/(\S+\.yaml)$", body, re.M)
assert len(steps) == 5, f"expected 5 CRD steps in the tutorial, found {len(steps)}: {steps}"
assert steps == sorted(steps), f"CRD steps are applied out of order: {steps}"
for i, name in enumerate(steps, 1):
    (work / f"step{i}.yaml").write_text((shipped / name).read_text())
PY
[ -f "$WORK/step5.yaml" ] || { echo "could not extract the tutorial"; exit 1; }

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

# expect_only <passing tasks...>: those pass, every other task before adoption fails.
expect_only() {
  local t p want
  for t in "${VERIFY[@]:0:8}"; do
    want=fail
    for p in "$@"; do [ "$p" = "$t" ] && want=pass; done
    expect "$want" "$t"
  done
}

ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

reset() {
  kubectl delete pets -n zoo --all --ignore-not-found >/dev/null 2>&1
  kubectl delete crd "$CRD" --ignore-not-found --wait=true >/dev/null 2>&1
  while kubectl get crd "$CRD" >/dev/null 2>&1; do sleep 1; done
}
apply_crd() { kubectl apply -f "$1" >/dev/null && kubectl wait --for=condition=Established "crd/$CRD" --timeout=30s >/dev/null; sleep 2; }

# turned_away_rejected: how many files in turned-away/ the API server rejects.
turned_away_rejected() {
  local f n=0
  for f in "$HOME"/pets/turned-away/*.yaml; do
    kubectl apply --dry-run=server -f "$f" >/dev/null 2>&1 || n=$((n + 1))
  done
  echo "$n"
}

echo "== init"
reset
bash "$WORK/init_scenario.run.sh" >/dev/null || { echo "init failed"; exit 1; }

echo "== stage: no CRD"
for t in "${VERIFY[@]}"; do expect fail "$t"; done

echo "== tutorial step 1: names only"
apply_crd "$WORK/step1.yaml"
expect_only verify_crd_registered verify_crd_discoverable verify_schema_accepts_valid
[ "$(turned_away_rejected)" = 0 ] && ok "all five turned-away pets get in" || bad "step 1 should let every turned-away pet in"

echo "== tutorial step 2: OpenAPI schema"
apply_crd "$WORK/step2.yaml"
expect_only verify_crd_registered verify_crd_discoverable verify_schema_accepts_valid
[ "$(turned_away_rejected)" = 2 ] && ok "only sparkles and whenever bounce" || bad "step 2 should reject exactly 2 turned-away pets"
out=$(printf 'apiVersion: zoo.example.com/v1alpha1\nkind: Pet\nmetadata: {name: picky, namespace: zoo}\nspec: {species: cat, favoriteColor: blue}\n' \
  | kubectl create --dry-run=server -f - 2>&1)
if echo "$out" | grep -q 'unknown field "spec.favoriteColor"'; then
  ok "kubectl rejects an unknown field (details box)"
else
  bad "the favoriteColor details box doesn't match what kubectl prints: $out"
fi

echo "== tutorial step 3: CEL rules"
apply_crd "$WORK/step3.yaml"
expect_only verify_crd_registered verify_crd_discoverable verify_schema_accepts_valid \
            verify_schema_rejects_invalid verify_house_rules
[ "$(turned_away_rejected)" = 5 ] && ok "every turned-away pet bounces" || bad "step 3 should reject all turned-away pets"
out=$(kubectl apply --dry-run=server -f "$HOME/pets/turned-away/lazy-dragon.yaml" 2>&1)
echo "$out" | grep -q 'no such key: diet' \
  && ok "lazy-dragon is rejected by accident (no such key: diet)" || bad "lazy-dragon's step-3 error isn't the one the tutorial quotes"

echo "== tutorial step 4: defaults"
apply_crd "$WORK/step4.yaml"
expect_only verify_crd_registered verify_crd_discoverable verify_schema_accepts_valid \
            verify_schema_rejects_invalid verify_house_rules verify_defaults
out=$(kubectl apply --dry-run=server -f "$HOME/pets/turned-away/lazy-dragon.yaml" 2>&1)
if echo "$out" | grep -q 'dragons eat at most once an hour' && ! echo "$out" | grep -q 'no such key'; then
  ok "lazy-dragon is rejected for the right reason"
else
  bad "lazy-dragon after defaults: $out"
fi

echo "== tutorial step 5: status subresource and printer columns"
apply_crd "$WORK/step5.yaml"
expect_only "${VERIFY[@]:0:8}"
cmp -s "$REFERENCE" "$WORK/step5.yaml" && ok "step 5 is the reference CRD" || bad "step 5 differs from $REFERENCE"

echo "== gotcha: no 'diet: default: {}' (nested defaults need a parent)"
reset
python3 - "$REFERENCE" "$WORK/no-parent-default.yaml" <<'PY'
import sys, yaml
crd = yaml.safe_load(open(sys.argv[1]))
del crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["diet"]["default"]
yaml.safe_dump(crd, open(sys.argv[2], "w"), allow_unicode=True)
PY
apply_crd "$WORK/no-parent-default.yaml" 2>/dev/null || echo "  (CRD without parent default was rejected by the API server)"
expect fail verify_defaults

echo "== gotcha: durations compared as strings"
reset
sed "s/duration(self.diet.feedEvery) >= duration('1h')/self.diet.feedEvery >= '1h'/" "$REFERENCE" > "$WORK/string-compare.yaml"
apply_crd "$WORK/string-compare.yaml"
expect fail verify_house_rules

echo "== gotcha: no feedEvery range rule (a pattern checks shape, not size)"
reset
python3 - "$REFERENCE" "$WORK/no-range.yaml" <<'PY'
import sys, yaml
crd = yaml.safe_load(open(sys.argv[1]))
del crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["diet"]["properties"]["feedEvery"]["x-kubernetes-validations"]
yaml.safe_dump(crd, open(sys.argv[2], "w"), allow_unicode=True)
PY
apply_crd "$WORK/no-range.yaml"
expect fail verify_schema_rejects_invalid

echo "== step 6: the learner adopts the pets"
reset
apply_crd "$WORK/step5.yaml"
kubectl apply -f "$HOME/pets/adopted/" >/dev/null
expect pass verify_pets_adopted
expect fail verify_status_reported

echo "== step 6: a status patch through the main endpoint is ignored"
kubectl patch pet mochi -n zoo --type=merge -p '{"status":{"mood":"Happy","face":"😺"}}' >/dev/null
expect fail verify_status_reported

echo "== step 6: the learner patches the status subresource"
kubectl patch pet mochi -n zoo --subresource=status --type=merge -p '{"status":{"mood":"Happy","face":"😺"}}' >/dev/null
for t in "${VERIFY[@]}"; do expect pass "$t"; done
echo
kubectl get pets -n zoo

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL CHECKS BEHAVED AS EXPECTED"; else echo "$FAILURES UNEXPECTED RESULT(S)"; exit 1; fi
