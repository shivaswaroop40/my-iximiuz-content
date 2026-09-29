# my-iximiuz-content

Source for my [iximiuz Labs](https://labs.iximiuz.com/a/shiva-swaroop) content.

| Path | What |
|---|---|
| `tutorials/<slug>/index.md` | Tutorial markdown + front matter (tasks, playground) |
| `challenges/<slug>/index.md` | Challenge markdown + front matter (tasks, playground) |
| `challenges/<slug>/solution.md` | Reference solution write-up |
| `challenges/<slug>/.solution.sh` | Scripted solution for automated end-to-end runs |
| `challenges/<slug>/__static__/` | Cover and other static assets |
| `dev/<slug>/` | Tutorial templates and test harnesses (not published) |
| `tools/diagrams/` | Excalidraw-style diagram sources and renderer (see its README) |
| `docs/` | Research and roadmaps |

Folders are named after the content's name on Labs, including its hash suffix, so
`labctl content push <kind> <slug> --dir <kinds>/<slug> --force` publishes a folder as-is and
`labctl content pull` refreshes it.

## Tutorials

- [How Kubernetes CRDs Work: Designing a Validated API From Scratch](tutorials/open-a-kubernetes-zoo-9ad54ae8/index.md) (draft)
- [How Kubernetes Operators Work: Building a Controller From Scratch](tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c/index.md) (draft)

## Challenges

- [Issue Per-Pod mTLS Certificates with PodCertificateRequest](challenges/per-pod-mtls-with-podcertificaterequest-144fe512/index.md)
- [CKA Practice: Migrate an Ingress to Gateway API](challenges/CKA-Practice-Migrate-an-Ingress-to-Gateway-API-c29893bc/index.md)
- [CKA Practice: Renew Expiring Control Plane Certificates](challenges/cka-practice-renew-control-plane-certificates-94a449de/index.md)
- [CKA Practice: Recover a Broken Static Control-Plane Pod](challenges/recover-broken-apiserver-static-pod-b8e1a53b/index.md)
- [CKA Practice: Recover a NotReady Node After a Kubelet Configuration Error](challenges/recover-notready-node-kubelet-config-af6617e0/index.md)

## Testing locally

Each harness extracts the task scripts from the published `index.md` and runs them against the
current kubectl context, and they delete Pets, Pods and CRDs there, so point them at a disposable cluster.
A `kind` cluster works for both and runs real Pods, which the operator tutorial needs to be tested properly:
`kind create cluster --name iximiuz-test --kubeconfig /tmp/kc && KUBECONFIG=/tmp/kc dev/.../run-tests.sh`.
Everything is currently tested against Kubernetes v1.37, Go 1.26.8, controller-runtime v0.25.1 and controller-tools v0.22.0.

```sh
dev/open-a-kubernetes-zoo/run-tests.sh          # zoo tutorial: each CRD step passes exactly the expected checks
dev/build-a-kubernetes-operator/run-tests.sh    # operator tutorial: builds the shipped project and walks every step
```

Each tutorial ships its code to the playground. The shipped folder next to `index.md` is the source of truth:
`tutorials/open-a-kubernetes-zoo-9ad54ae8/pet-crd/` (the five CRD versions) and
`tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c/pet-operator/` (the Go project, the hand-written
CRD and the bash controller). `labctl content push` packs each folder into `__static__/<folder>.tar.gz`, which
the `startupFiles` in the front matter unpack into the learner's home directory. The tutorial's `.labctlignore`
keeps the raw folder out of the push, and `pet-operator/.labctlignore` keeps the files the learner generates
(`zz_generated.deepcopy.go`, the generated CRD) out of the archive; they stay in the repo as test references.

The pages are rendered from `dev/<name>/tutorial.template.md` by `dev/render.py`, which quotes the shipped
files with `{{file:path}}` and `{{excerpt:path#from=RE#to=RE}}` (see its docstring) and fails if an excerpt
anchor stops matching exactly one line. It also copies the finished zoo CRD (`pet-crd/5-status-and-columns.yaml`)
to `pet-operator/config/crd-by-hand.yaml`. Edit a template or a shipped file, then run `dev/render.py`.
