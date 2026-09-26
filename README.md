# my-iximiuz-content

Source for my [iximiuz Labs](https://labs.iximiuz.com/a/shiva-swaroop) content.

| Path | What |
|---|---|
| `challenges/<slug>/index.md` | Challenge markdown + front matter (tasks, playground) |
| `challenges/<slug>/solution.md` | Reference solution write-up |
| `challenges/<slug>/__static__/` | Cover and other static assets |
| `dev/<slug>/` | Local test harness for a challenge's verify tasks (not published) |
| `docs/` | Research and roadmaps |

## Challenges

- [CKA Practice: Extend the Kubernetes API With a Validated CustomResourceDefinition](challenges/cka-practice-build-a-validated-crd/index.md) (draft)

## Testing a challenge's checks locally

The harness extracts the `init`/`run`/`hintcheck` scripts from `index.md` and runs them against the
current kubectl context. CRD challenges only need an API server, so a bare `etcd` + `kube-apiserver`
(or kind, where it can run) is enough. Use a disposable cluster.

```sh
dev/cka-practice-build-a-validated-crd/run-tests.sh
```
