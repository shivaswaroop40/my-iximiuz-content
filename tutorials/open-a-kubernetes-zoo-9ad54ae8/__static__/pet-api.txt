# The Pet API

Group:        zoo.example.com
Version:      v1alpha1   (served, storage)
Kind:         Pet
Plural:       pets
Singular:     pet
Short name:   pt
Category:     zoo        (so `kubectl get zoo` lists them)
Scope:        Namespaced

## spec

| Field          | Type                | Required | Default | Rules                                   |
|----------------|---------------------|----------|---------|-----------------------------------------|
| species        | string              | yes      |         | one of: cat, dog, dragon, cactus        |
| toy            | string              | no       |         | at most 20 characters                   |
| diet.food      | string              | no       | snacks  | at most 20 characters                   |
| diet.feedEvery | string              | no       | 10m     | a number followed by s, m or h (e.g. 90s, 10m, 6h), at most 10 characters, between 1s and 8760h (a year) |
| lastFedAt      | string (date-time)  | no       |         |                                         |

A Pet without a `diet` block must still end up with `diet.food: snacks`
and `diet.feedEvery: 10m`.

Validation rules (the API server must enforce these too):

- Cacti don't play with toys. A cactus must not have a `toy`.
  Error message: "cacti don't play with toys"
- Dragons eat at most once an hour. A dragon's `diet.feedEvery` must be at least 1h.
  Error message: "dragons eat at most once an hour: diet.feedEvery must be at least 1h"

## status (written only by a controller, never by users)

| Field | Type   | Example        |
|-------|--------|----------------|
| mood  | string | Happy, Hungry  |
| face  | string | 😺             |

## kubectl get output

NAME   SPECIES   FACE   MOOD   TOY   LAST FED   AGE
