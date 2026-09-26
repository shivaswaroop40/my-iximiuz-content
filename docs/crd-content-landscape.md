# CRD content on iximiuz Labs: landscape and roadmap

_Researched 2026-09-26 via web search. labs.iximiuz.com itself was not reachable from the authoring
sandbox, so double-check the catalog for anything published recently._

## What already exists

| Content | Type | How it touches CRDs |
|---|---|---|
| [Render and Install Argo CD with Helm, Skipping Pre-Installed CRDs](https://labs.iximiuz.com/challenges/render-argocd-manifests-with-helm-without-reinstalling-existing-crds-cbceeaa3) | Community challenge | CRD *lifecycle* with Helm (`--skip-crds`). You consume CRDs, you don't author them. |
| [Kubelings, module 10: Cluster API, clusters as custom resources](https://labs.iximiuz.com/courses/kubelings-dbd840c8/module-10/cluster-api-intro) | Course lesson | Operator pattern explained through Cluster API. Conceptual; uses someone else's CRDs. |
| [Kubernetes: Admission Control](https://labs.iximiuz.com/tutorials/kubernetes-admission-control-534baab1) | Tutorial | Validation/mutation via webhooks and policies, not CRD schemas. |
| [Getting Started with VictoriaMetrics on Kubernetes](https://labs.iximiuz.com/tutorials/victoriametrics-getting-started-kubernetes) | Tutorial | Uses an operator's CRDs. |
| [Kubernetes Client (Go) playground](https://labs.iximiuz.com/playgrounds/k8s-client-go) | Playground | Go + client-go IDE, a ready-made base for controller content. |
| [Writing Kubernetes Controllers/Operators](https://iximiuz.com/en/series/writing-kubernetes-controllers-operators/) and [Exploring the Operator Pattern](https://iximiuz.com/en/posts/kubernetes-operator-pattern/) | Blog series (iximiuz.com, not Labs) | Deep theory; no hands-on challenges attached. |

## The gap

No challenge found where the learner **authors** a CRD: schema, validation, defaulting, CEL,
subresources, printer columns, versioning. Everything on the platform consumes someone else's CRDs.
It's also in the CKA curriculum ("understand CRDs, install and configure operators"),
which fits the existing *CKA Practice* series.

## Roadmap: a "Custom Resources" track in the CKA Practice style

| # | Challenge | Skill | Difficulty | Status |
|---|---|---|---|---|
| 1 | **Extend the Kubernetes API With a Validated CRD** | names, structural schema, OpenAPI validation, CEL, defaults, status subresource, printer columns | Medium | ✅ drafted: `challenges/cka-practice-build-a-validated-crd` |
| 2 | Make a CRD field immutable and add a v1beta1 | CEL transition rules (`self == oldSelf`), multiple served versions, storage version switch, `status.storedVersions` | Medium/Hard | idea |
| 3 | Namespace stuck in Terminating: orphaned custom resources | finalizers on CRs, a deleted controller, `kubectl patch` to remove finalizers safely, API discovery errors | Medium (troubleshooting, the series' signature style) | idea |
| 4 | Who can read BackupSchedules? | ClusterRole aggregation (`aggregate-to-view/edit/admin`) for custom resources | Easy | idea |
| 5 | Reconcile it: a tiny BackupSchedule controller | turn BackupSchedule into CronJobs with a shell/kubectl or Go (client-go playground) reconcile loop, owner references, `observedGeneration` | Hard | idea |

Challenges 1 to 5 share the same `BackupSchedule` API, so they can later be bundled into a
skill path or a short course, with each challenge's end state as the next one's init state.
