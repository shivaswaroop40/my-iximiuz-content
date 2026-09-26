# Solution: Extend the Kubernetes API With a Validated CustomResourceDefinition

## 1. Read the contract, then write the CRD

Every row of `~/backupschedule-api.md` maps to one CRD feature:

| Contract says                                   | CRD feature                                               |
|-------------------------------------------------|-----------------------------------------------------------|
| group / version / kind / plural / singular      | `spec.group`, `spec.versions[].name`, `spec.names.*`      |
| short name `bks`, category `platform`           | `spec.names.shortNames`, `spec.names.categories`          |
| required fields, enum, 1..30, non-empty, cron   | OpenAPI: `required`, `enum`, `minimum`/`maximum`, `minLength`, `pattern` |
| repository required **only if** method = restic | CEL rule in `x-kubernetes-validations`                    |
| defaults                                        | `default:` (plus `default: {}` on the parent `retention`) |
| status written only by the agent                | `subresources.status: {}`                                 |
| `kubectl get` columns                           | `additionalPrinterColumns`                                |

```yaml
cat > ~/backupschedule-crd.yaml <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backupschedules.platform.example.com   # must be <plural>.<group>
spec:
  group: platform.example.com
  scope: Namespaced
  names:
    kind: BackupSchedule
    plural: backupschedules
    singular: backupschedule
    shortNames: [bks]
    categories: [platform]
  versions:
  - name: v1alpha1
    served: true
    storage: true
    subresources:
      status: {}
    additionalPrinterColumns:
    - {name: Schedule,    type: string,  jsonPath: .spec.schedule}
    - {name: Method,      type: string,  jsonPath: .spec.method}
    - {name: Keep,        type: integer, jsonPath: .spec.retention.keepLast}
    - {name: Suspended,   type: boolean, jsonPath: .spec.suspend}
    - {name: Last Backup, type: date,    jsonPath: .status.lastBackupTime}
    - {name: Age,         type: date,    jsonPath: .metadata.creationTimestamp}
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [schedule, source]
            x-kubernetes-validations:
            - rule: "self.method != 'restic' || has(self.repository)"
              message: "repository is required when method is restic"
            properties:
              schedule:
                type: string
                pattern: '^(\S+\s+){4}\S+$'
              source:
                type: object
                required: [pvcName]
                properties:
                  pvcName:
                    type: string
                    minLength: 1
              method:
                type: string
                enum: [snapshot, restic]
                default: snapshot
              repository:
                type: string
              retention:
                type: object
                default: {}
                properties:
                  keepLast:
                    type: integer
                    minimum: 1
                    maximum: 30
                    default: 7
              suspend:
                type: boolean
                default: false
          status:
            type: object
            properties:
              lastBackupTime:
                type: string
                format: date-time
              lastBackupResult:
                type: string
EOF

kubectl apply -f ~/backupschedule-crd.yaml
kubectl wait --for=condition=Established crd/backupschedules.platform.example.com
```

A few things are easy to get wrong:

- **`retention: default: {}`**: defaults are applied top-down, and only to fields whose parent exists.
  Without a default on `retention`, an object that omits `retention` never gets `keepLast: 7`.
- **The CEL rule lives on `spec`**, not on `repository`. A rule on a field only runs when that field is present,
  so a rule on `repository` can never complain that `repository` is missing.
  Because defaulting runs before validation, `self.method` is always set here.
- **`AGE` disappears** as soon as you define `additionalPrinterColumns`. Declare it yourself.
- **The `status` schema** matters: with pruning, undeclared status fields are silently dropped.

## 2. Test the contract

```sh
kubectl apply --dry-run=server -f ~/manifests/accepted/   # all three: created (server dry run)
kubectl apply --dry-run=server -f ~/manifests/rejected/   # every file: invalid
```

## 3. Ship the manifests

```sh
kubectl apply -f ~/manifests/accepted/
kubectl get bks -n payments
```

## 4. Report the backup through the status subresource

`kubectl apply` or `kubectl edit` against the main resource ignores `.status` once the status subresource is on.
Target `/status` directly:

```sh
kubectl patch bks orders-db-nightly -n payments \
  --subresource=status --type=merge \
  -p '{"status":{"lastBackupTime":"2026-09-25T02:00:00Z","lastBackupResult":"Succeeded"}}'

kubectl get bks -n payments
```

```
NAME                SCHEDULE     METHOD     KEEP   SUSPENDED   LAST BACKUP   AGE
invoices-weekly     30 3 * * 0   snapshot   7      true                      1m
ledger-hourly       0 * * * *    restic     7      false                     1m
orders-db-nightly   0 2 * * *    snapshot   14     false       27h           1m
```

Note that `metadata.generation` of `orders-db-nightly` stays at `1`:
with the status subresource on, status writes don't count as spec changes.
Controllers rely on exactly that (`status.observedGeneration`) to tell whether they've caught up with the spec.
