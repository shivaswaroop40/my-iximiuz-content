# Solution: Open a Kubernetes Zoo: Design a Validated Pet CustomResourceDefinition

## 1. Read the spec, then write the CRD

Every row of `~/pet-api.md` maps to one CRD feature:

| The spec says                                    | CRD feature                                                   |
|--------------------------------------------------|---------------------------------------------------------------|
| group / version / kind / plural / singular       | `spec.group`, `spec.versions[].name`, `spec.names.*`          |
| short name `pt`, category `zoo`                  | `spec.names.shortNames`, `spec.names.categories`              |
| species list, max lengths, duration format, date | OpenAPI: `required`, `enum`, `maxLength`, `pattern`, `format` |
| cacti have no toys, dragons eat ≤ once an hour   | CEL rules in `x-kubernetes-validations`                       |
| default diet                                     | `default:` (plus `default: {}` on the parent `diet`)          |
| status written only by the controller            | `subresources.status: {}`                                     |
| `kubectl get` columns                            | `additionalPrinterColumns`                                    |

```yaml
cat > ~/pet-crd.yaml <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: pets.zoo.example.com   # must be <plural>.<group>
spec:
  group: zoo.example.com
  scope: Namespaced
  names:
    kind: Pet
    plural: pets
    singular: pet
    shortNames: [pt]
    categories: [zoo]
  versions:
  - name: v1alpha1
    served: true
    storage: true
    subresources:
      status: {}
    additionalPrinterColumns:
    - {name: Species,  type: string, jsonPath: .spec.species}
    - {name: Face,     type: string, jsonPath: .status.face}
    - {name: Mood,     type: string, jsonPath: .status.mood}
    - {name: Toy,      type: string, jsonPath: .spec.toy}
    - {name: Last Fed, type: date,   jsonPath: .spec.lastFedAt}
    - {name: Age,      type: date,   jsonPath: .metadata.creationTimestamp}
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [species]
            x-kubernetes-validations:
            - rule: "self.species != 'cactus' || !has(self.toy)"
              message: "cacti don't play with toys"
            - rule: "self.species != 'dragon' || duration(self.diet.feedEvery) >= duration('1h')"
              message: "dragons eat at most once an hour: diet.feedEvery must be at least 1h"
            properties:
              species:
                type: string
                enum: [cat, dog, dragon, cactus]
              toy:
                type: string
                maxLength: 20
              diet:
                type: object
                default: {}
                properties:
                  food:
                    type: string
                    maxLength: 20
                    default: snacks
                  feedEvery:
                    type: string
                    maxLength: 10
                    pattern: '^[0-9]+(s|m|h)$'
                    default: 10m
              lastFedAt:
                type: string
                format: date-time
          status:
            type: object
            properties:
              mood:
                type: string
              face:
                type: string
EOF

kubectl apply -f ~/pet-crd.yaml
kubectl wait --for=condition=Established crd/pets.zoo.example.com
```

A few things are easy to get wrong:

- **`diet: default: {}`**: defaults are applied top-down, and only to fields whose parent exists.
  Without a default on `diet`, a Pet that omits `diet` never gets `food: snacks` or `feedEvery: 10m`.
- **Both CEL rules live on `spec`**, not on `toy` or `diet`. A rule attached to a field only runs when that field is present,
  and each rule here needs to see `species` *and* another field.
- **Compare durations, not strings.** `'59m' >= '1h'` is `true` as a string comparison (`'5' > '1'`).
  `duration()` parses the string, so `duration('59m') >= duration('1h')` is correctly `false`.
- **Defaulting runs before validation.** That's why `lazy-dragon.yaml`, which has no `diet` at all, is rejected:
  it gets `feedEvery: 10m` from the default, and then fails the dragon rule.
  It's also why `self.diet.feedEvery` is always safe to read in the rule.
- **`AGE` disappears** as soon as you define `additionalPrinterColumns`. Declare it yourself.
- **The `status` schema** matters: undeclared status fields are pruned, silently.

## 2. Test against the paperwork

```sh
kubectl apply --dry-run=server -f ~/pets/adopted/       # all four: created (server dry run)
kubectl apply --dry-run=server -f ~/pets/turned-away/   # every file: invalid
```

## 3. Open the gates

```sh
kubectl apply -f ~/pets/adopted/
kubectl get pets -n zoo
```

## 4. Report mochi's mood through the status subresource

`kubectl apply` or `kubectl edit` against the main resource ignores `.status` once the status subresource is on.
Target `/status` directly:

```sh
kubectl patch pet mochi -n zoo --subresource=status --type=merge \
  -p '{"status":{"mood":"Happy","face":"😺"}}'

kubectl get pets -n zoo
```

```
NAME       SPECIES   FACE   MOOD    TOY     LAST FED   AGE
mochi      cat       😺      Happy   yarn               1m
prickles   cactus                                      1m
rex        dog                      stick              1m
smaug      dragon                                      1m
```

Note that `metadata.generation` of `mochi` stays at `1`:
with the status subresource on, status writes don't count as spec changes.
Controllers rely on exactly that (`status.observedGeneration`) to tell whether they've caught up with the spec.
