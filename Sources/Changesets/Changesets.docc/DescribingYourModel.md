# Describing your model

Map Swift properties to store columns, and tell a changeset how to address a
row.

## Overview

``TableModel`` is the one thing a changeset needs from your type. It answers:
which properties are columns, what each is named at the store, and which of
them identify a row.

```swift
struct User: TableModel {
    var id: Int?
    var email: String?
    var displayName: String
    var age: Int

    static let columns: [TableColumn<User>] = [
        TableColumn("id", \User.id, primaryKey: true),
        TableColumn("email", \User.email),
        TableColumn("display_name", \User.displayName),
        TableColumn("age", \User.age),
    ]
}
```

That is the whole conformance. `tableName` and `primaryKey` both have
defaults, so a minimal model declares only `columns`.

## Naming

The first argument to ``TableColumn/init(_:_:primaryKey:)`` is the name *the
store* uses. It has no obligation to match the Swift property:

```swift
TableColumn("display_name", \User.displayName)
TableColumn("created_at", \User.createdAt)
TableColumn("is_active", \User.isActive)
```

This name is what appears in ``ValidatedChanges/changedFields``, in
``ValidatedChanges/identity``, and in ``ChangesetError/field`` — so it is
also the key your form templates will match on when rendering errors.

> Important: No two columns may share a name. Because ``Changeset/changes``
> is keyed by name, duplicates would silently drop one field's write and read
> back the other's value. A changeset checks this when it is constructed and
> traps with a message naming the offending column, so the mistake surfaces
> at the first test that touches the model rather than in production data.

## Table name

Defaults to the type name, lowercased:

```swift
struct Membership: TableModel { /* ... */ }
Membership.tableName        // "membership"
```

Override it when your store disagrees, which it usually does:

```swift
static let tableName = "users"
```

## Primary keys

Flag the columns that identify a row:

```swift
TableColumn("id", \User.id, primaryKey: true)
```

``TableModel/primaryKey`` then defaults to exactly those columns, and
``Changeset/validatedChanges()`` reads them off the original to build
``ValidatedChanges/identity``.

Composite keys work the same way — flag each part:

```swift
struct Membership: TableModel {
    var userID: Int
    var teamID: Int
    var role: String

    static let columns: [TableColumn<Membership>] = [
        TableColumn("user_id", \Membership.userID, primaryKey: true),
        TableColumn("team_id", \Membership.teamID, primaryKey: true),
        TableColumn("role", \Membership.role),
    ]
}
```

An update changeset over that model produces both:

```swift
validated.identity      // ["user_id": 1, "team_id": 2]
```

> Note: A model with no primary-key column cannot be updated — there is no
> way to address the row. Insert changesets are unaffected, since they carry
> no identity at all. ``Changeset/validatedChanges()`` traps rather than
> throws here, because a missing primary key is incomplete metadata, not a
> runtime condition a caller can recover from.

## Optional and non-optional columns

The distinction is load-bearing, not incidental:

- A **non-optional** property is guaranteed present by the type system.
  ``Changeset/validateRequired(_:)`` will not compile against it, which is
  the type system correctly refusing to let you check something it already
  guarantees.
- An **optional** property can be required, cleared, or left alone — and
  ``Changeset/changed(_:)`` is how you tell "cleared" from "left alone",
  since both read as `nil` through `value(_:)`.

```swift
Changeset(original: ada)
    .change(\.email, nil)       // a real write: SET email = NULL
    .changed(\.email)            // true
```

Setting an already-`nil` field to `nil` is not a change, exactly as setting
any field to the value it already holds is not a change.

## Checking metadata in tests

``TableModel/validateColumnMetadata()`` runs the same checks a changeset runs
at construction. Calling it in a test pins the mistake to the model rather
than to whichever feature happened to touch the field first:

```swift
@Test func metadataIsWellFormed() {
    User.validateColumnMetadata()
    Membership.validateColumnMetadata()
}
```

## Values that cannot be compared

Dirty tracking needs `Equatable` to know whether a value differs. A column
whose type is not `Equatable` still works, but every change to it is recorded
as dirty because there is no way to tell:

```swift
struct Document: TableModel {
    var id: Int?
    var payload: Payload         // not Equatable

    static let columns: [TableColumn<Document>] = [
        TableColumn("id", \Document.id, primaryKey: true),
        TableColumn("payload", \Document.payload),
    ]
}
```

Prefer `Equatable` column types where you can. They are what makes minimal
writes minimal.
