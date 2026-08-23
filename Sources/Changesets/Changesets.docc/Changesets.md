# ``Changesets``

Validate and shape data before it becomes a write.

## Overview

A changeset sits between the data a user submitted and the write you are
about to perform. It answers three questions that every persistence layer
needs answered and none of them answers well on its own:

- **What actually changed?** Not what the form submitted — what *differs*
  from the row you already have.
- **Is it valid?** All of the reasons it is not, gathered at once, each
  attached to the field a form renders it beside.
- **What does the store need?** A neutral description of the write that a
  SQL driver, a document store, and a key-value store can each translate
  into their own dialect.

```swift
let changeset = Changeset(original: user)
    .change(\.email, input.email)
    .updateChange(\.email) { $0.lowercased() }
    .change(\.displayName, input.displayName)
    .validate(\.email, .email)
    .validate(\.displayName, .length(1...80))

guard changeset.isValid else {
    return render(form, errors: changeset.messagesByField)
}
try await repo.update(changeset.validatedChanges())
```

Nothing here mutates. Every method returns a new changeset, so a pipeline
reads top to bottom, any intermediate stage can be held onto or branched
from, and a changeset can cross an isolation boundary without ceremony.

## Why it is thin

There is no type casting in this library. "Is this an `Int`" is Swift's
question and it was already answered when the request body decoded. There
are no "is this a real field" checks either — every field is named by a
keypath, so a typo is a compile error rather than a runtime surprise.

What is left is the residual the type system genuinely cannot cover:
formats, lengths, ranges, cross-field consistency, and knowing which fields
a user actually touched.

## Dirty tracking

The distinguishing behavior. A change equal to the original never lands in
``Changeset/changes``, and a change that reverts a prior one removes it:

```swift
Changeset(original: ada)
    .change(\.age, 37)
    .change(\.age, 36)      // ada.age is already 36
    .hasChanges              // false — nothing to write
```

So a user who edits a field and then undoes the edit produces no write for
it, and an `UPDATE` touches only the columns that moved. When you need a
column written regardless — a timestamp, a revision counter — reach for
``Changeset/forceChange(_:_:)``.

## Topics

### Essentials

- ``Changeset``
- ``TableModel``
- ``TableColumn``
- ``ValidatedChanges``

### Validation

- ``ValidationRule``
- ``CrossFieldRule``
- ``ChangesetError``
- ``ChangesetValidationError``

### Guides

- <doc:GettingStarted>
- <doc:DescribingYourModel>
- <doc:ValidatingChanges>
- <doc:HandlingErrors>
