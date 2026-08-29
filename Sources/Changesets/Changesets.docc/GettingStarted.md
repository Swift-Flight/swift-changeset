# Getting started

Build your first changeset, from an empty struct to a validated write.

## Overview

This guide walks the whole path: describing a model, recording changes,
validating them, and handing the result to a driver. It assumes nothing
beyond a Swift struct you want to persist.

## Describe the model

A changeset needs one thing from your type: which properties are columns and
what each is called at the store. That is ``TableModel``.

```swift
struct User: TableModel {
    var id: Int?
    var email: String?
    var displayName: String
    var age: Int

    static let tableName = "users"
    static let columns: [TableColumn<User>] = [
        TableColumn("id", \User.id, primaryKey: true),
        TableColumn("email", \User.email),
        TableColumn("display_name", \User.displayName),
        TableColumn("age", \User.age),
    ]
}
```

Note that `display_name` is spelled differently from `displayName`. That is
the point of the mapping — your Swift code stays Swift-shaped and the store
gets the names it expects. See <doc:DescribingYourModel> for the details.

## Record changes

For a new row, start from the type:

```swift
let changeset = Changeset(User.self)
    .change(\.email, "grace@example.com")
    .change(\.displayName, "Grace")
```

For an existing row, start from the row. Now dirty tracking is live:

```swift
let ada = User(id: 1, email: "ada@example.com", displayName: "Ada", age: 36)

let changeset = Changeset(original: ada)
    .change(\.displayName, "Ada Lovelace")   // recorded — it differs
    .change(\.age, 36)                        // ignored — already 36

changeset.changes        // ["display_name": "Ada Lovelace"]
changeset.hasChanges     // true
```

## Normalize before you validate

`updateChange(_:_:)` transforms a change that was recorded,
and does nothing when the field was untouched. Put it before your rules so
they see the cleaned value:

```swift
let changeset = Changeset(User.self)
    .change(\.email, "  Grace@Example.COM ")
    .updateChange(\.email) { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    .validate(\.email, .email)

changeset.getChange(\.email)     // "grace@example.com"
changeset.isValid                 // true
```

When the normalization can *fail* — parsing a phone number, canonicalizing a
URL — ``Changeset/updateChange(_:orError:_:)`` takes a transform that may
return `nil`, and records the message you give it when it does:

```swift
Changeset(User.self)
    .change(\.phone, input.phone)
    .updateChange(\.phone, orError: "is not a valid phone number") { E164.normalize($0) }
```

## Validate

Rules accumulate. Nothing short-circuits, so one pass reports every problem:

```swift
let changeset = Changeset(User.self)
    .change(\.email, "not-an-email")
    .change(\.displayName, "")
    .validate(\.email, .email)
    .validate(\.displayName, .length(1...80))

changeset.isValid       // false
changeset.errors        // [email: is not a valid email address,
                        //  display_name: length must be within 1...80]
```

A rule only sees fields that were *changed*. Untouched data came from the
store and was validated when it was written, so re-checking it would surface
failures the user cannot act on. See <doc:ValidatingChanges>.

## Hand off to a driver

``Changeset/validatedChanges()`` produces the neutral description of the
write — and refuses to produce one at all if the changeset is invalid:

```swift
let validated = try changeset.validatedChanges()

validated.tableName       // "users"
validated.changedFields   // ["display_name": "Ada Lovelace"]
validated.identity        // ["id": 1]   — nil for an insert
```

It names its own table, so a driver call takes one argument rather than a
value and the table its caller had to remember to pass alongside.

That `identity`/`nil` distinction is how a driver knows whether it is
writing an `UPDATE ... WHERE id = 1` or an `INSERT`.

Because the throw is structural rather than a convention, an invalid
changeset cannot reach your database by accident:

```swift
do {
    try await repo.update(changeset.validatedChanges())
} catch let error as ChangesetValidationError {
    return .unprocessableEntity(error.messagesByField)
}
```

## Preview the result

Sometimes you want the model rather than the write — a form preview, an
optimistic UI update. ``Changeset/applyChanges()`` gives you that, and
deliberately does *not* require validity, because a preview is most useful
while the user is still typing:

```swift
let preview = changeset.applyChanges()      // User?
```

## Next steps

- <doc:DescribingYourModel> — column metadata, primary keys, and the rules it must satisfy
- <doc:ValidatingChanges> — the rule catalog, cross-field rules, writing your own
- <doc:HandlingErrors> — rendering errors, and folding store failures back in
