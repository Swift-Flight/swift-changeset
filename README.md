# swift-changeset

The thin validation and dirty-tracking layer of the SwiftFlight data stack,
specified in [`../flight-changeset-design.md`](../flight-changeset-design.md).
An Ecto-inspired `Changeset` adapted to a statically typed language: it does
only what Swift's type system genuinely cannot do at compile time.

It does three things, all store-agnostic:

1. **Semantic validation** — formats, lengths, ranges, membership,
   cross-field consistency — accumulating *all* errors rather than failing
   on the first.
2. **Dirty tracking** — records only the fields that genuinely differ from
   the original row, so writes are minimal and a no-op changeset never
   reaches the store.
3. **The neutral handoff** — `validatedChanges()` produces a
   `ValidatedChanges` value (changed fields + primary-key identity, keyed by
   store-neutral column names) that each driver translates into its own
   native write. An invalid changeset throws at this boundary and can never
   reach a driver, structurally.

Deliberately **not** here: type casting. "Is this an `Int`", "is this a real
field" are Swift's job — answered at `Codable` decode and by keypaths at
compile time. The changeset covers only the residual (design §2).

The fourth piece, `TableModel`, is the metadata seam `Changeset` is generic
over: the keypath → store-neutral column-name mapping, and nothing else —
deliberately not a query model.

## Why a standalone package

Originally a component of Flight Data Core. Hangar (the Ecto-inspired
Postgres query layer, [`hangar-design.md`](../../Hangar/hangar-design.md)
§11.2) must consume changesets directly — `Multi` and
`Repo.insert/update` take them — but Hangar cannot depend on Flight. The
changeset layer was Flight-independent by construction (pure stdlib, zero
dependencies), so it becomes its own package that both Hangar and Flight
Data Core depend on, rather than duplicating validation logic in two places.

## Module naming

The package is `swift-changeset`; the module it vends is **`Changesets`**,
following the swift-collections → `Collections` convention. This avoids a
module named identically to its central `Changeset` type, which would force
`Changeset.Changeset` disambiguation on consumers.

```swift
import Changesets

let changeset = Changeset(original: user)
    .change(\.email, input.email)
    .validate(\.email, .email)
```

## Consumers

- **FlightDataCore** depends on this package and re-exports it
  (`@_exported import Changesets`), so its consumers keep compiling with a
  single `import FlightDataCore`.
- **flight-data-postgres** and **flight-data-valkey** (the drivers) consume
  `ValidatedChanges` through that re-export — each implements only a thin
  `apply(_:)` translation (design §5), never its own changeset.
- **Hangar** depends on it directly, with no Flight in between.
