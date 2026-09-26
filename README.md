# my-iximiuz-content

Source for my [iximiuz Labs](https://labs.iximiuz.com/a/shiva-swaroop) content.

| Path | What |
|---|---|
| `tutorials/<slug>/index.md` | Tutorial markdown + front matter (tasks, playground) |
| `challenges/<slug>/index.md` | Challenge markdown + front matter (tasks, playground) |
| `challenges/<slug>/solution.md` | Reference solution write-up |
| `challenges/<slug>/__static__/` | Cover and other static assets |
| `dev/<slug>/` | Reference code and test harnesses (not published) |
| `docs/` | Research and roadmaps |

## Tutorials

- [Build a Kubernetes Operator From Scratch: CRD, Controller, and the Reconcile Loop](tutorials/build-a-kubernetes-operator-from-scratch/index.md) (draft)

## Challenges

- [Extend the Kubernetes API With a Validated CustomResourceDefinition](challenges/build-a-validated-crd/index.md) (draft)

## Testing locally

Each harness extracts the task scripts from the published `index.md` and runs them against the
current kubectl context. Use a disposable cluster: a bare `etcd` + `kube-apiserver`
(+ `kube-controller-manager` with the garbage collector, for the operator tutorial) is enough.

```sh
dev/build-a-validated-crd/run-tests.sh          # challenge: every check passes/fails at the right stage
dev/build-a-kubernetes-operator/run-tests.sh    # tutorial: builds the code *from the tutorial* and walks every step
```

The operator tutorial is rendered from `dev/build-a-kubernetes-operator/tutorial.template.md`:
code blocks are pulled from the tested reference project in `dev/build-a-kubernetes-operator/backup-operator/`.
Edit the template or the code, then run `dev/build-a-kubernetes-operator/render.py`.
