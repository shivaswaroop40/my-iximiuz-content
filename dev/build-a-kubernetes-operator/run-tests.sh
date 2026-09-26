#!/usr/bin/env bash
# End-to-end test of the operator tutorial against the current kubectl context.
#
# Every file the learner is told to write (`cat > PATH <<'EOF'` blocks) is taken
# from the *rendered* tutorial, so this proves the published code builds and works.
# The tutorial's checkpoint tasks come from its front matter and are asserted
# along the way.
#
# Needs: go, kubectl, a disposable cluster with the garbage collector running
# (kube-apiserver + etcd + kube-controller-manager is enough). There is no
# kubelet requirement: the "real backup" step is simulated by writing the
# CronJob's status, which is what the CronJob controller would do.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TUTORIAL="$HERE/../../tutorials/build-a-kubernetes-operator-from-scratch/index.md"
WORK="$(mktemp -d)"
export HOME="$WORK/home"
mkdir -p "$HOME"
cp "${KUBECONFIG:-/root/.kube/config}" "$WORK/kubeconfig"
export KUBECONFIG="$WORK/kubeconfig"
export GOPATH="${GOPATH:-/root/go}" GOMODCACHE="${GOMODCACHE:-/root/go/pkg/mod}" GOCACHE="${GOCACHE:-/root/.cache/go-build}"
export PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"
N=payments
FAILURES=0
OP_PID=""

"$HERE/render.py" >/dev/null

python3 - "$TUTORIAL" "$WORK" <<'PY'
import sys, re, yaml, pathlib
text = open(sys.argv[1]).read()
work = pathlib.Path(sys.argv[2])
_, fm, body = re.split(r"^---$\n", text, maxsplit=2, flags=re.M)
for name, task in yaml.safe_load(fm)["tasks"].items():
    (work / f"{name}.sh").write_text(task["run"])
files = re.findall(r"^cat > (\S+) <<'EOF'\n(.*?)\nEOF$", body, re.S | re.M)
out = []
for path, content in files:
    out.append(path)
    (work / "files").mkdir(exist_ok=True)
    (work / "files" / str(len(out))).write_text(content + "\n")
(work / "files.txt").write_text("\n".join(out) + "\n")
PY

# write_file <path as written in the tutorial>: materialize that heredoc from the tutorial.
write_file() {
  local i=0 p
  while read -r p; do
    i=$((i + 1))
    if [ "$p" = "$1" ]; then
      local dest="${p/#\~/$HOME}"
      mkdir -p "$(dirname "$dest")"
      cp "$WORK/files/$i" "$dest"
      return 0
    fi
  done < "$WORK/files.txt"
  echo "tutorial has no file block for $1"; exit 1
}

check() { # check <pass|fail> <task>
  local want=$1 task=$2 got=fail
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if bash "$WORK/$task.sh" >/dev/null 2>&1; then got=pass; fi
    [ "$got" = "$want" ] && break
    [ "$want" = fail ] && break
    sleep 1
  done
  if [ "$got" = "$want" ]; then printf '  ok    %-30s %s\n' "$task" "$got"
  else printf '  FAIL  %-30s wanted %s, got %s\n' "$task" "$want" "$got"; FAILURES=$((FAILURES + 1)); fi
}

assert() { # assert <description> <command...>
  local desc=$1; shift
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$desc"; return; fi
    sleep 1
  done
  printf '  FAIL  %s\n' "$desc"; FAILURES=$((FAILURES + 1))
}

cj() { kubectl get cronjob -n $N "$1" -o jsonpath="$2" 2>/dev/null; }
bks() { kubectl get bks -n $N "$1" -o jsonpath="$2" 2>/dev/null; }

start_operator() {
  (cd "$HOME/backup-operator" && exec ./backup-operator >>"$WORK/operator.log" 2>&1) &
  OP_PID=$!
}
stop_operator() { [ -n "$OP_PID" ] && kill "$OP_PID" 2>/dev/null; wait "$OP_PID" 2>/dev/null; OP_PID=""; }
trap 'stop_operator; pkill -f "$HOME/naive-controlle[r].sh" 2>/dev/null' EXIT

echo "== reset cluster state"
kubectl delete bks -A --all --ignore-not-found >/dev/null 2>&1
kubectl delete crd backupschedules.platform.example.com --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete cronjobs -n $N --all --ignore-not-found >/dev/null 2>&1
# The test cluster may lack the pvc-protection controller, so clear finalizers explicitly.
kubectl patch pvc -n $N orders-db-data --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
kubectl delete pvc -n $N orders-db-data --ignore-not-found --wait=false >/dev/null 2>&1
kubectl patch pv orders-db-data --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
kubectl delete pv orders-db-data --ignore-not-found --wait=false >/dev/null 2>&1

echo "== init_cluster"
bash "$WORK/init_cluster.sh" >/dev/null || { echo "init failed"; exit 1; }
for t in verify_crd_minimal verify_crd_full verify_naive_controller verify_operator_owns_cronjob \
         verify_first_backup verify_second_schedule verify_garbage_collected; do check fail "$t"; done

echo "== part 1: minimal CRD"
write_file "~/backup-operator/config/crd-minimal.yaml"
kubectl apply -f "$HOME/backup-operator/config/crd-minimal.yaml" >/dev/null
kubectl wait --for=condition=Established crd/backupschedules.platform.example.com >/dev/null; sleep 1
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: BackupSchedule
metadata:
  name: orders-db-nightly
  namespace: payments
spec:
  schedule: "0 2 * * *"
  source:
    pvcName: orders-db-data
  retention:
    keepLast: 14
EOF
check pass verify_crd_minimal
check fail verify_crd_full
assert "minimal CRD accepts nonsense" bash -c "kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: BackupSchedule
metadata: {name: nonsense, namespace: payments}
spec: {schedule: whenever, retention: {keepLast: 'a lot'}}
EOF"

echo "== part 1: full CRD by hand"
write_file "~/backup-operator/config/crd-by-hand.yaml"
kubectl apply -f "$HOME/backup-operator/config/crd-by-hand.yaml" >/dev/null; sleep 2
check pass verify_crd_full
assert "existing object got defaults (method=snapshot)" bash -c "[ \"\$(kubectl get bks -n $N orders-db-nightly -o jsonpath='{.spec.method}')\" = snapshot ]"

echo "== part 2: naive bash controller"
write_file "~/naive-controller.sh"
chmod +x "$HOME/naive-controller.sh"
(setsid "$HOME/naive-controller.sh" >"$WORK/naive.log" 2>&1 &)
check pass verify_naive_controller
kubectl patch bks -n $N orders-db-nightly --type=merge -p '{"spec":{"schedule":"30 1 * * *"}}' >/dev/null
assert "naive controller follows spec change" bash -c "[ \"\$(kubectl get cronjob -n $N orders-db-nightly-backup -o jsonpath='{.spec.schedule}')\" = '30 1 * * *' ]"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: BackupSchedule
metadata: {name: throwaway, namespace: payments}
spec: {schedule: "0 0 * * *", source: {pvcName: orders-db-data}}
EOF
assert "naive controller creates throwaway-backup" kubectl get cronjob -n $N throwaway-backup
kubectl delete bks -n $N throwaway >/dev/null; sleep 6
assert "throwaway-backup is orphaned" kubectl get cronjob -n $N throwaway-backup
pkill -f "$HOME/naive-controlle[r].sh"
kubectl delete cronjobs -n $N --all >/dev/null

echo "== part 3: build the operator from the tutorial's code"
cd "$HOME/backup-operator"
go mod init example.com/backup-operator >/dev/null 2>&1
go get sigs.k8s.io/controller-runtime@v0.21.0 >/dev/null 2>&1
command -v controller-gen >/dev/null || go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.18.0
mkdir -p api/v1alpha1 internal/controller
write_file "api/v1alpha1/groupversion_info.go"
write_file "api/v1alpha1/backupschedule_types.go"
write_file "internal/controller/backupschedule_controller.go"
write_file "main.go"
controller-gen object paths=./api/... || FAILURES=$((FAILURES + 1))
controller-gen crd paths=./api/... output:crd:dir=config || FAILURES=$((FAILURES + 1))
go mod tidy >/dev/null 2>&1
if go vet ./... && go build -o backup-operator .; then echo "  ok    tutorial code builds and vets"; else echo "  FAIL  tutorial code does not build"; exit 1; fi
if diff -q config/platform.example.com_backupschedules.yaml "$HERE/backup-operator/config/platform.example.com_backupschedules.yaml" >/dev/null; then
  echo "  ok    generated CRD matches the reference"; else echo "  FAIL  generated CRD differs from the reference"; FAILURES=$((FAILURES + 1)); fi
crd_diff() { diff <(kubectl create --dry-run=client -o yaml -f config/crd-by-hand.yaml) <(kubectl create --dry-run=client -o yaml -f config/platform.example.com_backupschedules.yaml); }
assert "tutorial's CRD diff step shows differences" bash -c "$(declare -f crd_diff); crd_diff | grep -q '^>'"
assert "  ...and the spec schema (minus descriptions/formats) is identical" python3 - config/crd-by-hand.yaml config/platform.example.com_backupschedules.yaml <<'PY2'
import sys, yaml
def clean(x):
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items() if k not in ("description", "format")}
    if isinstance(x, list):
        return [clean(v) for v in x]
    return x
a, b = (clean(yaml.safe_load(open(f))["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]) for f in sys.argv[1:])
sys.exit(a != b)
PY2
kubectl apply -f config/platform.example.com_backupschedules.yaml >/dev/null; sleep 2
start_operator
check pass verify_operator_owns_cronjob

echo "== part 4: the loop at work"
sleep 3
before=$(grep -c 'CronJob reconciled' "$WORK/operator.log")
sleep 5
assert "steady state: no updates without changes" bash -c "[ \$(grep -c 'CronJob reconciled' '$WORK/operator.log') -eq $before ]"

kubectl patch bks -n $N orders-db-nightly --type=merge -p '{"spec":{"retention":{"keepLast":5}}}' >/dev/null
assert "spec change -> successfulJobsHistoryLimit=5" bash -c "[ \"\$(kubectl get cronjob -n $N orders-db-nightly-backup -o jsonpath='{.spec.successfulJobsHistoryLimit}')\" = 5 ]"
assert "observedGeneration == generation" bash -c "[ \"\$(kubectl get bks -n $N orders-db-nightly -o jsonpath='{.metadata.generation}')\" = \"\$(kubectl get bks -n $N orders-db-nightly -o jsonpath='{.status.observedGeneration}')\" ]"

kubectl patch cronjob -n $N orders-db-nightly-backup --type=merge -p '{"spec":{"schedule":"* * * * *"}}' >/dev/null
assert "drift reverted" bash -c "[ \"\$(kubectl get cronjob -n $N orders-db-nightly-backup -o jsonpath='{.spec.schedule}')\" = '30 1 * * *' ]"

uid=$(cj orders-db-nightly-backup '{.metadata.uid}')
kubectl delete cronjob -n $N orders-db-nightly-backup >/dev/null
assert "deleted CronJob recreated" bash -c "u=\$(kubectl get cronjob -n $N orders-db-nightly-backup -o jsonpath='{.metadata.uid}'); [ -n \"\$u\" ] && [ \"\$u\" != '$uid' ]"

kubectl patch bks -n $N orders-db-nightly --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
assert "suspend -> Ready=False/Suspended" bash -c "[ \"\$(kubectl get bks -n $N orders-db-nightly -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].reason}')\" = Suspended ]"
assert "suspend propagated to CronJob" bash -c "[ \"\$(kubectl get cronjob -n $N orders-db-nightly-backup -o jsonpath='{.spec.suspend}')\" = true ]"
kubectl patch bks -n $N orders-db-nightly --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
assert "resume -> Ready=True" bash -c "[ \"\$(kubectl get bks -n $N orders-db-nightly -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"
assert "events recorded" bash -c "kubectl get events -n $N --field-selector involvedObject.kind=BackupSchedule -o name | grep -q ."

stop_operator
kubectl patch bks -n $N orders-db-nightly --type=merge -p '{"spec":{"schedule":"45 3 * * *"}}' >/dev/null; sleep 2
assert "operator down: CronJob still has old schedule" bash -c "[ \"\$(kubectl get cronjob -n $N orders-db-nightly-backup -o jsonpath='{.spec.schedule}')\" = '30 1 * * *' ]"
start_operator
assert "operator restarted: caught up" bash -c "[ \"\$(kubectl get cronjob -n $N orders-db-nightly-backup -o jsonpath='{.spec.schedule}')\" = '45 3 * * *' ]"

kubectl patch bks -n $N orders-db-nightly --type=merge -p '{"spec":{"schedule":"* * * * *"}}' >/dev/null
check fail verify_first_backup
# Simulate the CronJob controller recording a successful run (no kubelet here).
kubectl patch cronjob -n $N orders-db-nightly-backup --subresource=status --type=merge \
  -p "{\"status\":{\"lastSuccessfulTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null
check pass verify_first_backup
kubectl patch bks -n $N orders-db-nightly --type=merge -p '{"spec":{"schedule":"0 2 * * *"}}' >/dev/null

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: BackupSchedule
metadata:
  name: ledger-hourly
  namespace: payments
spec:
  schedule: "0 * * * *"
  method: restic
  repository: s3://acme-backups/ledger
  source:
    pvcName: orders-db-data
EOF
check pass verify_second_schedule
assert "restic env passed to the backup container" bash -c "kubectl get cronjob -n $N ledger-hourly-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' | grep -q s3://acme-backups/ledger"
check fail verify_garbage_collected
kubectl delete bks -n $N ledger-hourly >/dev/null
check pass verify_garbage_collected

echo
kubectl get bks,cronjobs -n $N
echo
echo "operator log: $(grep -c 'CronJob reconciled' "$WORK/operator.log") CronJob writes, $(grep -c 'Reconciler error' "$WORK/operator.log") retried conflicts"
if [ "$FAILURES" -eq 0 ]; then echo "ALL CHECKS BEHAVED AS EXPECTED"; else echo "$FAILURES UNEXPECTED RESULT(S)"; exit 1; fi
