#!/usr/bin/env bash
# End-to-end test of the operator tutorial against the current kubectl context.
#
# What it tests, and what it doesn't:
# - The project the playground ships at startup (the tutorial's pet-operator/ folder, packed
#   into __static__/pet-operator.tar.gz by labctl) is copied to ~/pet-operator, built with
#   controller-gen and go, and run. That is the code the learner gets.
# - The Pet manifests and the feed() helper are taken from the *rendered* tutorial.
# - The other commands it runs for the learner must appear verbatim in the rendered tutorial
#   (see CMDS). It sets up its own HOME, GOPATH and GOBIN, and it doesn't run init_go.
# - The Go excerpts on the page are not compiled on their own; dev/render.py cuts them
#   from the same files, and fails if an anchor stops matching exactly one line.
# - Every task script (run and hintcheck) must pass `bash -n`, and the checkpoint tasks
#   are asserted along the way.
#
# Needs: go (any version that can fetch the go1.26 toolchain), kubectl, and a disposable
# cluster with a kubelet, like kind. The hunger timeline uses feedEvery: 3s instead of the
# tutorial's 1m to keep the run short.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TUTORIAL="$HERE/../../tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c/index.md"
WORK="$(mktemp -d)"
kubectl config view --raw > "$WORK/kubeconfig" || { echo "no kubeconfig"; exit 1; }
export KUBECONFIG="$WORK/kubeconfig"
export GOPATH="${GOPATH:-$(go env GOPATH)}" GOMODCACHE="${GOMODCACHE:-$(go env GOMODCACHE)}" GOCACHE="${GOCACHE:-$(go env GOCACHE)}"
export HOME="$WORK/home"
mkdir -p "$HOME"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.26.8}"
export PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"
N=zoo
FAILURES=0
OP_PID=""
NAIVE_PID=""

"$HERE/../render.py" >/dev/null || exit 1

python3 - "$TUTORIAL" "$WORK" <<'PY'
import sys, re, yaml, pathlib
text = open(sys.argv[1]).read()
work = pathlib.Path(sys.argv[2])
_, fm, body = re.split(r"^---$\n", text, maxsplit=2, flags=re.M)
import subprocess
broken = []
for name, task in yaml.safe_load(fm)["tasks"].items():
    (work / f"{name}.sh").write_text(task["run"])
    if "hintcheck" in task:
        (work / "hints").mkdir(exist_ok=True)
        (work / "hints" / f"{name}.sh").write_text(task["hintcheck"])
    for kind in ("run", "hintcheck", "failcheck"):
        if kind in task and subprocess.run(["bash", "-n"], input=task[kind], text=True, capture_output=True).returncode:
            broken.append(f"{name}.{kind}")
assert not broken, f"task scripts with bash syntax errors: {broken}"
feed = re.findall(r"^grep -q '\^feed\(\)' ~/.bashrc \|\| cat >> ~/.bashrc <<'EOF'\n(.*?)\nEOF$", body, re.S | re.M)
assert len(feed) == 1, "the tutorial's feed() helper block not found"
(work / "feed.sh").write_text(feed[0] + "\n")
# Pet manifests the learner applies (kubectl apply [--dry-run=server] -f - <<'EOF'), by name.
(work / "pets").mkdir(exist_ok=True)
for doc in re.findall(r"^kubectl apply (?:--dry-run=server )?-f - <<'EOF'\n(.*?)\nEOF$", body, re.S | re.M):
    pet = yaml.safe_load(doc)
    if pet.get("kind") == "Pet":
        (work / "pets" / f"{pet['metadata']['name']}.yaml").write_text(doc + "\n")
for name in ("mochi", "sparkles", "goldie", "smaug"):
    assert (work / "pets" / f"{name}.yaml").exists(), f"the tutorial's {name} manifest not found"
PY

# The playground's startupFiles unpack the shipped project here before the learner logs in.
# Copy it the way labctl packs the archive: without what the folder's .labctlignore lists.
SHIPPED="$(dirname "$TUTORIAL")/pet-operator"
while IFS= read -r f; do
  mkdir -p "$HOME/pet-operator/$(dirname "$f")" && cp -p "$SHIPPED/$f" "$HOME/pet-operator/$f"
done < <("$HERE/../render.py" --archive-files "$SHIPPED")
for generated in api/v1alpha1/zz_generated.deepcopy.go config/zoo.example.com_pets.yaml pet-operator; do
  [ ! -e "$HOME/pet-operator/$generated" ] || { echo "the playground would ship $generated, which the learner generates"; exit 1; }
done
strip_header() { awk 'body || !/^#/ { body = 1; print }' "$1"; }   # drop the leading comment lines
ZOO_CRD="$HERE/../../tutorials/open-a-kubernetes-zoo-9ad54ae8/pet-crd"
cmp -s <(strip_header "$HOME/pet-operator/config/crd-minimal.yaml") <(strip_header "$ZOO_CRD/1-names.yaml") \
  || { echo "the shipped crd-minimal.yaml is not zoo step 1; run dev/render.py"; exit 1; }
cmp -s <(strip_header "$HOME/pet-operator/config/crd-by-hand.yaml") <(strip_header "$ZOO_CRD/5-status-and-columns.yaml") \
  || { echo "the shipped crd-by-hand.yaml is not zoo step 5; run dev/render.py"; exit 1; }
# Commands this script runs on the learner's behalf: each must still be in the tutorial, verbatim.
while IFS= read -r cmd; do
  grep -qxF -- "$cmd" "$TUTORIAL" || { echo "tutorial no longer runs: $cmd"; exit 1; }
done <<'CMDS'
kubectl apply -f ~/pet-operator/config/crd-minimal.yaml
kubectl apply -f ~/pet-operator/config/crd-by-hand.yaml
bash ~/pet-operator/bash/naive-controller.sh
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
go mod download
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.22.0
controller-gen object paths=./api/...
controller-gen crd paths=./api/... output:crd:dir=config
kubectl apply -f config/zoo.example.com_pets.yaml
go build -o pet-operator . && ./pet-operator
CMDS

# The Labs examiner polls tasks, so a state that passes for only a few seconds can go unseen.
# A learner waits for each checkpoint to turn green; give it the same time before the next step
# changes the state a task just checked. Set EXAMINER_GRACE=0 when nothing is watching.
examiner_grace() { sleep "${EXAMINER_GRACE:-15}"; }

check() { # check <pass|fail> <task>: a "pass" may take a few seconds to converge
  local want=$1 task=$2 got=fail
  for _ in $(seq 15); do
    if bash "$WORK/$task.sh" >/dev/null 2>&1; then got=pass; else got=fail; fi
    [ "$got" = "$want" ] && break
    [ "$want" = fail ] && break
    sleep 1
  done
  if [ "$got" = "$want" ]; then printf '  ok    %-30s %s\n' "$task" "$got"
  else printf '  FAIL  %-30s wanted %s, got %s\n' "$task" "$want" "$got"; FAILURES=$((FAILURES + 1)); fi
}

assert() { # assert <description> <command...>: retried for up to 15s
  local desc=$1; shift
  for _ in $(seq 15); do
    if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$desc"; return; fi
    sleep 1
  done
  printf '  FAIL  %s\n' "$desc"; FAILURES=$((FAILURES + 1))
}

jp() { kubectl get -n $N "$1" "$2" -o jsonpath="$3" 2>/dev/null; }   # jp <kind> <name> <jsonpath>
is() { [ "$(jp "$1" "$2" "$3")" = "$4" ]; }                         # is <kind> <name> <jsonpath> <value>
has() { jp "$1" "$2" "$3" | grep -qF -- "$4"; }                     # has <kind> <name> <jsonpath> <substring>
# The tutorial's own feed() helper, quietened.
source "$WORK/feed.sh"
eval "tutorial_$(declare -f feed)"
feed() { tutorial_feed "$@" >/dev/null; }

start_operator() {
  (cd "$HOME/pet-operator" && exec ./pet-operator >>"$WORK/operator.log" 2>&1) &
  OP_PID=$!
}
stop_operator() { [ -n "$OP_PID" ] && kill "$OP_PID" 2>/dev/null; wait "$OP_PID" 2>/dev/null; OP_PID=""; }
stop_naive() { [ -n "$NAIVE_PID" ] && kill "$NAIVE_PID" 2>/dev/null; wait "$NAIVE_PID" 2>/dev/null; NAIVE_PID=""; }
trap 'stop_operator; stop_naive' EXIT

echo "== reset cluster state"
kubectl delete pets -A --all --ignore-not-found >/dev/null 2>&1
kubectl delete crd pets.zoo.example.com --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete pods,configmaps -n $N --all --ignore-not-found >/dev/null 2>&1

echo "== init_cluster"
bash "$WORK/init_cluster.sh" >/dev/null || { echo "init failed"; exit 1; }
for t in verify_crd_minimal verify_crd_full verify_naive_controller verify_operator_adopted \
         verify_ran_away verify_came_home verify_second_pet verify_garbage_collected; do check fail "$t"; done

echo "== part 1: minimal CRD"
kubectl apply -f "$HOME/pet-operator/config/crd-minimal.yaml" >/dev/null
kubectl wait --for=condition=Established crd/pets.zoo.example.com >/dev/null; sleep 1
kubectl apply -f "$WORK/pets/mochi.yaml" >/dev/null
check pass verify_crd_minimal
examiner_grace
check fail verify_crd_full
assert "minimal CRD accepts a unicorn with toy: 42" kubectl apply --dry-run=server -f "$WORK/pets/sparkles.yaml"

echo "== part 1: full CRD by hand"
kubectl apply -f "$HOME/pet-operator/config/crd-by-hand.yaml" >/dev/null; sleep 2
check pass verify_crd_full
assert "dragon without a diet is rejected (default, then CEL)" bash -c "! echo '{\"apiVersion\":\"zoo.example.com/v1alpha1\",\"kind\":\"Pet\",\"metadata\":{\"name\":\"nope\",\"namespace\":\"zoo\"},\"spec\":{\"species\":\"dragon\"}}' | kubectl apply --dry-run=server -f -"
for every in 0s 8761h 9999999h; do
  assert "feedEvery: $every is rejected" bash -c "! echo '{\"apiVersion\":\"zoo.example.com/v1alpha1\",\"kind\":\"Pet\",\"metadata\":{\"name\":\"nope\",\"namespace\":\"zoo\"},\"spec\":{\"species\":\"cat\",\"diet\":{\"feedEvery\":\"$every\"}}}' | kubectl apply --dry-run=server -f -"
done
assert "mochi got the default diet" is pet mochi '{.spec.diet.food}/{.spec.diet.feedEvery}' 'snacks/10m'

echo "== part 2: naive bash controller"
bash "$HOME/pet-operator/bash/naive-controller.sh" >"$WORK/naive.log" 2>&1 &
NAIVE_PID=$!
check pass verify_naive_controller
uid=$(jp pod mochi '{.metadata.uid}')
kubectl delete pod -n $N mochi --grace-period=1 --wait=false >/dev/null
assert "naive controller recreates a deleted Pod" bash -c "u=\$(kubectl get pod -n $N mochi -o jsonpath='{.metadata.uid}'); [ -n \"\$u\" ] && [ \"\$u\" != '$uid' ]"
kubectl patch pet -n $N mochi --type=merge -p '{"spec":{"species":"dog"}}' >/dev/null; sleep 7
assert "species change is NOT picked up (the flaw)" has pod mochi '{.spec.containers[0].args}' 'I am mochi the cat'
kubectl patch pet -n $N mochi --type=merge -p '{"spec":{"species":"cat"}}' >/dev/null
kubectl apply -f "$WORK/pets/goldie.yaml" >/dev/null
assert "naive controller gives goldie a Pod" kubectl get pod -n $N goldie
kubectl delete pet -n $N goldie >/dev/null; sleep 6
assert "goldie's Pod is orphaned" kubectl get pod -n $N goldie
stop_naive
kubectl delete pods -n $N --all --grace-period=1 >/dev/null

echo "== part 3: build the operator the playground ships"
cd "$HOME/pet-operator"
go mod download
GOBIN="$GOPATH/bin" go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.22.0
controller-gen object paths=./api/... || FAILURES=$((FAILURES + 1))
controller-gen crd paths=./api/... output:crd:dir=config || FAILURES=$((FAILURES + 1))
if go vet ./... && go build -o pet-operator .; then echo "  ok    tutorial code builds and vets (go $(go env GOVERSION))"; else echo "  FAIL  tutorial code does not build"; exit 1; fi
for generated in config/zoo.example.com_pets.yaml api/v1alpha1/zz_generated.deepcopy.go; do
  if diff -q "$generated" "$SHIPPED/$generated" >/dev/null; then echo "  ok    generated $generated matches the reference"
  else echo "  FAIL  generated $generated differs from the reference"; FAILURES=$((FAILURES + 1)); fi
done
assert "tutorial's CRD diff step shows differences" bash -c "diff <(kubectl create --dry-run=client -o yaml -f config/crd-by-hand.yaml) <(kubectl create --dry-run=client -o yaml -f config/zoo.example.com_pets.yaml) | grep -q '^>'"
assert "  ...and the spec schema (minus descriptions) is identical" python3 - config/crd-by-hand.yaml config/zoo.example.com_pets.yaml <<'PY2'
import sys, yaml
def clean(x):
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items() if k != "description"}
    if isinstance(x, list):
        return [clean(v) for v in x]
    return x
a, b = (clean(yaml.safe_load(open(f))["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]) for f in sys.argv[1:])
sys.exit(a != b)
PY2
kubectl apply -f config/zoo.example.com_pets.yaml >/dev/null; sleep 2

echo "== part 3: a ConfigMap the Pet doesn't own is left alone"
kubectl create configmap -n $N mochi-card --from-literal=card="not mochi's" >/dev/null
start_operator
feed mochi
assert "the foreign card is not overwritten" is configmap mochi-card '{.data.card}' "not mochi's"
assert "  ...or adopted" bash -c "[ -z \"\$(kubectl get configmap -n $N mochi-card -o jsonpath='{.metadata.ownerReferences}')\" ]"
assert "  ...and the operator logs why" grep -q "ConfigMap mochi-card already exists and doesn't belong to mochi" "$WORK/operator.log"
hint=$(bash "$WORK/hints/verify_operator_adopted.sh" 2>&1)
echo "$hint" | grep -q "mochi-card ConfigMap that the Pet doesn't own" && echo "  ok    hint names the foreign ConfigMap" \
  || { echo "  FAIL  hint for a foreign ConfigMap: $hint"; FAILURES=$((FAILURES + 1)); }
assert "  ...and reports ConfigMapNameTaken" is pet mochi '{.status.conditions[?(@.type=="AtHome")].reason}' ConfigMapNameTaken
kubectl delete configmap -n $N mochi-card >/dev/null
# Deleting an object the Pet doesn't own triggers no event; the 10s requeue has to notice.
assert "operator takes over within its 10s requeue" bash -c "sleep 11; [ \"\$(kubectl get configmap -n $N mochi-card -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}')\" = Pet ]"
stop_operator
# Start the next scenario from the same state: no card, no Pod.
kubectl delete pod -n $N mochi --ignore-not-found --wait=true --timeout=90s >/dev/null
kubectl delete configmap -n $N mochi-card --ignore-not-found >/dev/null

echo "== part 3: a leftover Pod the Pet doesn't own (the learner skipped the cleanup)"
kubectl run mochi -n $N --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never -- sleep 3600 >/dev/null
start_operator
# mochi was adopted minutes ago and never fed; here it's still Happy, on the playground it may not be.
feed mochi
assert "operator reports PodNameTaken" is pet mochi '{.status.conditions[?(@.type=="AtHome")].reason}' PodNameTaken
hint=$(bash "$WORK/hints/verify_operator_adopted.sh" 2>&1)
echo "$hint" | grep -q "A mochi Pod that the Pet doesn't own is in the way" && echo "  ok    hint names the leftover Pod" \
  || { echo "  FAIL  hint for PodNameTaken: $hint"; FAILURES=$((FAILURES + 1)); }
assert "PodNameTaken warning event recorded" bash -c "kubectl get events -n $N --field-selector reason=PodNameTaken -o name | grep -q ."
assert "the foreign Pod is left alone" bash -c "p=\$(kubectl get pod -n $N mochi -o jsonpath='{.metadata.uid}/{.metadata.ownerReferences}'); [ -n \"\$p\" ] && [ \"\${p#*/}\" = '' ]"
check fail verify_operator_adopted
kubectl delete pod -n $N mochi --wait=true --timeout=90s >/dev/null   # a real kubelet takes the grace period
check pass verify_operator_adopted
assert "card shows the ASCII cat" has configmap mochi-card '{.data.card}' '( ^.^ )'

echo "== part 4: time passes (feedEvery: 3s instead of 1m)"
kubectl patch pet -n $N mochi --type=merge -p '{"spec":{"diet":{"feedEvery":"3s"}}}' >/dev/null
feed mochi
assert "Happy right after feeding" is pet mochi '{.status.mood}' Happy
assert "Hungry after feedEvery, with nothing touching the Pet" is pet mochi '{.status.mood}/{.status.face}' 'Hungry/😾'
assert "hungry card" has configmap mochi-card '{.data.card}' 'HUNGRY'
check pass verify_ran_away
examiner_grace
assert "RanAway event recorded" bash -c "kubectl get events -n $N --field-selector reason=RanAway -o name | grep -q ."
assert "AtHome condition is False" is pet mochi '{.status.conditions[?(@.type=="AtHome")].status}' False
check fail verify_came_home
kubectl patch pet -n $N mochi --type=merge -p '{"spec":{"diet":{"feedEvery":"10m"}}}' >/dev/null
feed mochi
check pass verify_came_home

echo "== part 4: self-healing, drift, spec changes, restart"
uid=$(jp pod mochi '{.metadata.uid}')
kubectl delete pod -n $N mochi --wait=false >/dev/null
assert "deleted Pod recreated" bash -c "u=\$(kubectl get pod -n $N mochi -o jsonpath='{.metadata.uid}'); [ -n \"\$u\" ] && [ \"\$u\" != '$uid' ]"
kubectl patch configmap -n $N mochi-card --type=merge -p '{"data":{"card":"mochi is a dog now"}}' >/dev/null
assert "scribbled card reverted" has configmap mochi-card '{.data.card}' '( ^.^ )'
kubectl patch pet -n $N mochi --type=merge -p '{"spec":{"toy":"laser pointer"}}' >/dev/null
assert "toy change reaches the card" has configmap mochi-card '{.data.card}' 'laser pointer'
assert "observedGeneration == generation" bash -c "[ \"\$(kubectl get pet -n $N mochi -o jsonpath='{.metadata.generation}')\" = \"\$(kubectl get pet -n $N mochi -o jsonpath='{.status.observedGeneration}')\" ]"
stop_operator
kubectl patch pet -n $N mochi --type=merge -p '{"spec":{"toy":"cardboard box"}}' >/dev/null; sleep 2
assert "operator down: card still has the laser pointer" has configmap mochi-card '{.data.card}' 'laser pointer'
start_operator
assert "operator restarted: card caught up" has configmap mochi-card '{.data.card}' 'cardboard box'

echo "== part 4: second pet and garbage collection"
kubectl apply -f "$WORK/pets/smaug.yaml" >/dev/null
check pass verify_second_pet
examiner_grace
assert "smaug is a happy dragon" is pet smaug '{.status.face}' '🐲'
check fail verify_garbage_collected
kubectl delete pet -n $N smaug >/dev/null
check pass verify_garbage_collected
assert "smaug's Pod and card are gone" bash -c "! kubectl get pod,configmap -n $N smaug smaug-card 2>/dev/null | grep -q ."

echo
kubectl get pets,pods,configmaps -n $N
echo
kubectl get configmap -n $N mochi-card -o jsonpath='{.data.card}'
echo
echo "operator log: $(grep -c 'card updated' "$WORK/operator.log") card writes, $(grep -c 'Reconciler error' "$WORK/operator.log") retried errors"
grep 'Reconciler error' "$WORK/operator.log" | grep -v 'the object has been modified' | head -3
if [ "$FAILURES" -eq 0 ]; then echo "ALL CHECKS BEHAVED AS EXPECTED"; else echo "$FAILURES UNEXPECTED RESULT(S)"; exit 1; fi
