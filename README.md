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
| `AGENTS.md` | Rules and the pre-push checklist for anyone (or any agent) editing content |

Folders are named after the content's name on Labs, including its hash suffix, so
`dev/push.py <kinds>/<slug>` publishes a folder as-is (lint, pack the shipped archives, push, verify)
and `labctl content pull` refreshes it. See `AGENTS.md` for the pre-push checklist.

## Tutorials

- [How Kubernetes CRDs Work: Designing a Validated API From Scratch](tutorials/open-a-kubernetes-zoo-9ad54ae8/index.md) (draft)
- [How Kubernetes Operators Work: Building a Controller From Scratch](tutorials/build-a-kubernetes-operator-from-scratch-a6eecb2c/index.md) (draft)
- [How AI Agents Run on Kubernetes: Solving a Zoo Mystery With kagent](tutorials/run-ai-agents-on-kubernetes-with-kagent/index.md) (draft, not on Labs yet: `labctl content create` will give the folder its hash suffix)

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
dev/lint.py                                     # every folder: what learners see, startupFiles, cover, task scripts
dev/open-a-kubernetes-zoo/run-tests.sh          # zoo tutorial: each CRD step passes exactly the expected checks
dev/build-a-kubernetes-operator/run-tests.sh    # operator tutorial: builds the shipped project and walks every step
dev/kagent-smaug-escaped/run-tests.sh           # kagent tutorial: installs kagent 0.10.2 and walks every step (no API key)
```

Each tutorial ships its files to the playground, and the shipped files next to `index.md` are the source of truth:

- zoo: `pet-crd/` (the five CRD versions), `pets/` (the adopted and turned-away Pet manifests) and
  `__static__/pet-api.txt` (the spec, unpacked as `~/pet-api.md`);
- operator: `pet-operator/` (the Go project, the hand-written CRD and the bash controller);
- kagent: `detective/` (Helm values, the Agent, the scripted model, `radio`) and `setup/` (the init script, the zoo and a mirrored local-path-provisioner manifest, unpacked in `/opt/zoo-setup`).

`dev/push.py` packs each folder into `__static__/<folder>.tar.gz`, which the `startupFiles` in the
front matter unpack into the learner's home directory. The tutorial's `.labctlignore` keeps the raw folders out
of the push. Each folder's own `.labctlignore` keeps `.DS_Store` out of the archive, and `pet-operator/`'s also
keeps out what the learner generates (`zz_generated.deepcopy.go`, the generated CRD); those stay in the repo as
references the harness diffs against. `dev/render.py --archive-files <folder>` prints exactly what labctl packs.

The pages are rendered from `dev/<name>/tutorial.template.md` by `dev/render.py`, which quotes the shipped
files with `{{file:path}}` and `{{excerpt:path#from=RE#to=RE}}` (see its docstring) and fails if an excerpt
anchor stops matching exactly one line. It also copies the finished zoo CRD (`pet-crd/5-status-and-columns.yaml`)
to `pet-operator/config/crd-by-hand.yaml` with a "generated, edit the zoo file" header. Edit a template or a shipped
file, then run `dev/render.py`.
