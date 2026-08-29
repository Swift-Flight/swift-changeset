# Validating changes

The built-in rules, cross-field consistency, and how to write your own.

## Overview

Validation in a changeset has one governing rule: **rules see changes, not
data**. A field with no recorded change is not validated.

```swift
let changeset = Changeset(original: legacyUser)   // email predates your rules
    .change(\.displayName, "Ada Lovelace")
    .validate(\.email, .email)                     // never runs — email untouched
    .validate(\.displayName, .length(1...80))

changeset.isValid       // true, even though legacyUser.email is malformed
```

That is deliberate. Unchanged data came from the store and was validated when
it was written; re-checking it surfaces failures the user cannot act on and
makes rows that predate a rule permanently uneditable.

Errors also **accumulate**. Nothing short-circuits, so one pass reports every
problem and a form renders them all at once.

## The catalog

### Text

``ValidationRule/email`` — a pragmatic `something@something.tld` shape.
Deliberately not RFC 5322, whose grammar admits addresses no mail system
accepts.

```swift
.validate(\.email, .email)
```

``ValidationRule/matches(_:message:)`` — a regular expression. It matches
*anywhere* in the value, so anchor with `^` and `$` when you mean the whole
thing:

```swift
.validate(\.handle, .matches(#"^[a-z0-9-]+$"#, message: "may only contain lowercase letters, numbers and hyphens"))
```

Swift's `Regex` is not multiline by default, so `$` means end of input. A
newline cannot be used to smuggle a second line past an anchored check.

``ValidationRule/length(_:message:)`` — element count, on any collection.
On `String` it counts grapheme clusters, which is what a person perceives as
length: an emoji is one character, not four.

```swift
.validate(\.displayName, .length(1...80))
.validate(\.password, .length(8...))
.validate(\.bio, .length(...500))
```

### Values

``ValidationRule/range(_:message:)`` — any `Comparable`, any range shape.

```swift
.validate(\.age, .range(13...))
.validate(\.discount, .range(0..<1))
```

``ValidationRule/oneOf(_:message:)`` and
``ValidationRule/excluding(_:message:)`` — membership in a closed set, and
its inverse.

```swift
.validate(\.status, .oneOf(["draft", "published", "archived"]))
.validate(\.handle, .excluding(["admin", "root", "system"], message: "is reserved"))
```

``ValidationRule/accepted(message:)`` — the terms-of-service checkbox.

```swift
.validate(\.acceptedTerms, .accepted())
```

### Collections

``ValidationRule/subset(of:message:)`` — every element must be permitted. The
failure message names the offenders, which is what makes it actionable:

```swift
.validate(\.tags, .subset(of: ["swift", "server", "database"]))
// tags: contains values that are not allowed: cobol, fortran
```

## Required fields

``Changeset/validateRequired(_:)`` checks the *effective* value — the change
if there is one, otherwise the original:

```swift
Changeset(User.self)
    .validateRequired(\.email)      // email: is required
```

It only compiles against optional properties. A non-optional property is
guaranteed present by the type system, and asking to check it again is a
compile error rather than a redundant runtime check.

Rules and requirement are separate concerns: a rule skips a change that sets
a field to `nil`, so pair them when `nil` must be rejected *and* a present
value must be well-formed:

```swift
changeset
    .validateRequired(\.email)
    .validate(\.email, .email)
```

### Required on an insert

``Changeset/validateRequired(_:)`` answers "will this row have a value?",
which a non-optional property answers by existing. It cannot answer "does
*this insert* supply one" — an untouched non-optional field is simply absent
from the write, and the first thing to notice would be the store's `NOT NULL`
error, far from the form that could have said so.

``Changeset/validateChanged(_:message:)`` is that check:

```swift
Changeset(User.self)
    .change(\.email, input.email)
    .validateChanged(\.displayName)      // display_name: is required
```

It passes on an update changeset, where the original already supplies the
value, and on an optional field it counts a write of `nil` as present —
which is exactly the case ``Changeset/validateRequired(_:)`` rejects. The two
answer different questions; use whichever question you mean.

## Cross-field rules

Some properties are not about one field. ``CrossFieldRule`` runs against the
changeset's *effective* state and — unlike single-field rules — **always
runs**, whichever side changed. A consistency property has to hold over the
whole row, so validating only the field the user touched would let the other
side break it.

`ordered(_:before:message:)` — the date-range shape:

```swift
changeset.validate(.ordered(\.startsAt, before: \.endsAt))
// ends_at: must be after starts_at
```

`confirms(_:matches:message:)` — password confirmation:

```swift
Changeset(User.self)
    .change(\.password, "hunter2")
    .change(\.passwordConfirmation, "hunter3")
    .validate(.confirms(\.password, matches: \.passwordConfirmation))
// password_confirmation: does not match password
```

The error lands on the confirmation field, because that is the one the user
should correct.

Both skip when a participating value is missing, so a partial update that
touches neither field is not forced to resupply both.

## Writing your own

### A one-off check

``ValidationRule/custom(message:_:)`` takes a predicate:

```swift
.validate(\.quantity, .custom(message: "must be a multiple of 12") {
    $0.isMultiple(of: 12)
})
```

### A reusable rule

Rules are ordinary values. Build a catalog as a static extension, exactly
like the built-ins:

```swift
extension ValidationRule where V == String {
    static var slug: ValidationRule {
        .matches(#"^[a-z0-9-]+$"#, message: "may only contain lowercase letters, numbers and hyphens")
    }

    static func noneOf(_ words: Set<String>) -> ValidationRule {
        ValidationRule { words.contains($0.lowercased()) ? "is not available" : nil }
    }
}

changeset
    .validate(\.handle, .slug)
    .validate(\.handle, .noneOf(reservedWords))
```

``ValidationRule/init(_:)`` is the general form: return `nil` to pass, or a
message to fail. Messages are field-relative fragments — "is not available",
not "Handle is not available" — because they are rendered next to the field
name.

### A reusable cross-field rule

``CrossFieldRule/custom(on:message:_:)`` reads effective values off the
changeset and names the field the error attaches to:

```swift
extension CrossFieldRule where Model == Product {
    static var discountBelowList: CrossFieldRule {
        .custom(on: \.discountedPrice, message: "must be below the list price") { changeset in
            guard let list = changeset.value(\.listPrice),
                  let discounted = changeset.value(\.discountedPrice)
            else { return true }        // absence is validateRequired's job
            return discounted < list
        }
    }
}
```

Returning `true` when a value is missing is the convention the built-ins
follow: a consistency rule reports inconsistency, not absence.
