# my-iximiuz-content

Source for my [iximiuz Labs](https://labs.iximiuz.com/a/shiva-swaroop) content.

| Path | What |
|---|---|
| `tutorials/<slug>/index.md` | Tutorial markdown + front matter (tasks, playground) |
| `challenges/<slug>/index.md` | Challenge markdown + front matter (tasks, playground) |
| `challenges/<slug>/solution.md` | Reference solution write-up |
| `challenges/<slug>/.solution.sh` | Scripted solution for automated end-to-end runs |
| `challenges/<slug>/__static__/` | Cover and other static assets |
| `dev/<slug>/` | Reference code and test harnesses (not published) |
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
Everything is currently tested against Kubernetes v1.37.1, Go 1.26.8, controller-runtime v0.25.1 and controller-tools v0.22.0.

```sh
dev/open-a-kubernetes-zoo/run-tests.sh          # zoo tutorial: each CRD step passes exactly the expected checks
dev/build-a-kubernetes-operator/run-tests.sh    # tutorial: builds the code *from the tutorial* and walks every step
```

Both tutorials are rendered from a `tutorial.template.md` in their `dev/` folder, which pulls code blocks
from the tested files next to it: the CRD steps in `dev/open-a-kubernetes-zoo/crd/` and the operator project in
`dev/build-a-kubernetes-operator/pet-operator/`. Edit the template or the files, then run that folder's `render.py`.
The finished zoo CRD (`crd/5-status-and-columns.yaml`) is also Part 1 of the operator tutorial.
