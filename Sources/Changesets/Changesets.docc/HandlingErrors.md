# Handling errors

Render validation failures, and fold store-reported failures back into the
changeset that caused them.

## Overview

A changeset gathers every failure rather than stopping at the first, and
attaches each to the column it belongs to. That shape is what lets a form
render all of its messages in one pass instead of making a user resubmit to
discover the next problem.

```swift
let changeset = Changeset(User.self)
    .change(\.email, "not-an-email")
    .change(\.displayName, "")
    .validate(\.email, .email)
    .validate(\.displayName, .length(1...80))

changeset.errors
// [email: is not a valid email address,
//  display_name: length must be within 1...80]
```

## Rendering

``Changeset/messagesByField`` groups messages by column, which is the shape
both a form and a JSON error body want:

```swift
guard changeset.isValid else {
    return render(form, errors: changeset.messagesByField)
    // ["email": ["is not a valid email address"],
    //  "display_name": ["length must be within 1...80"]]
}
```

Keys are store column names — `display_name`, not `displayName` — because
that is what ``ChangesetError/field`` carries. Match your templates to those.

When you catch the thrown error instead of inspecting the changeset,
``ChangesetValidationError/messagesByField`` gives you the same grouping:

```swift
do {
    try await repo.update(changeset.validatedChanges())
} catch let error as ChangesetValidationError {
    return .unprocessableEntity(error.messagesByField)
}
```

``ChangesetValidationError`` also conforms to `LocalizedError`, so
`localizedDescription` carries the real messages rather than a generic
placeholder — which matters, because that is the property most logging code
reaches for.

## Errors from outside the changeset

Not every failure is something a rule can see. A uniqueness violation is only
known once the database rejects the write. An authorization decision may need
a service call. A business rule may depend on state the changeset never held.

``Changeset/addError(_:_:)`` folds those back in:

```swift
do {
    try await repo.insert(changeset.validatedChanges())
} catch let error as DatabaseError where error.isUniqueViolation {
    let rejected = changeset.addError(\.email, "has already been taken")
    return render(form, errors: rejected.messagesByField)
}
```

The changeset becomes invalid, so ``Changeset/validatedChanges()`` refuses it
exactly as if a rule had failed. The important part is that the message ends
up in the *same* stream as the rule failures — a form has one place to look,
not two.

> Tip: Without this, store-reported failures end up in a parallel error
> channel and every form has to merge two shapes. Reach for ``Changeset/addError(_:_:)``
> before you build that second channel.

When the only thing you have is what the store told you — a constraint name
mapped to a column — use the string-keyed form:

```swift
changeset.addError(column: violation.columnName, "has already been taken")
```

## Preflighting expensive checks

Because errors accumulate and ``Changeset/isValid`` is cheap to read, you can
run the free checks first and only pay for the expensive ones if those pass:

```swift
var changeset = Changeset(User.self)
    .change(\.email, input.email)
    .validate(\.email, .email)

if changeset.isValid, await repo.emailExists(input.email) {
    changeset = changeset.addError(\.email, "has already been taken")
}
```

This is the same ordering discipline a database constraint gives you, just
moved earlier so the user sees the problem before the write is attempted. The
constraint stays as the authority — a check-then-write is racy on its own —
but it turns the common case into immediate feedback.

## Guarding what a client may write

``Changeset/deleteChange(_:)`` removes a recorded change, which is how you
drop fields a caller is not permitted to set without rejecting the whole
request:

```swift
let sanitized = changeset
    .deleteChange(\.role)
    .deleteChange(\.isAdmin)
```

For a whole-request rejection instead, ``Changeset/addError(_:_:)`` is
the better tool — it tells the user what happened rather than silently
discarding their input.
