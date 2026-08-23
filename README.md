# swift-changeset

Validate and shape data before it becomes a write.

A changeset sits between the data a user submitted and the write you are about
to perform. It tracks which fields actually changed, gathers every validation
failure at once, and hands your persistence layer a neutral description of the
write — one a SQL driver, a document store, or a key-value store can each
translate into their own dialect.

Zero dependencies. Swift 6, strict concurrency, no `@unchecked` anywhere.

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

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Swift-Flight/swift-changeset", from: "0.1.0")
]
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "Changesets", package: "swift-changeset")
])
```

Requires Swift 6.0+. Supports macOS 13+, iOS 16+, tvOS 16+, watchOS 9+,
visionOS 1+, and Linux.

## What a changeset does

**Tracks what actually changed.** Not what the form submitted — what differs
from the row you already have.

```swift
Changeset(original: ada)
    .change(\.age, 37)
    .change(\.age, 36)      // ada.age is already 36
    .hasChanges              // false — the edit was undone, so there is nothing to write
```

A user who edits a field and then reverts it produces no write for it, and an
`UPDATE` touches only the columns that moved.

**Gathers every failure, attached to a field.** Nothing short-circuits, so one
pass reports every problem and a form renders them all at once.

```swift
let changeset = Changeset(User.self)
    .change(\.email, "not-an-email")
    .change(\.displayName, "")
    .validate(\.email, .email)
    .validate(\.displayName, .length(1...80))

changeset.messagesByField
// ["email": ["is not a valid email address"],
//  "display_name": ["length must be within 1...80"]]
```

**Refuses to hand an invalid write to your store.** `validatedChanges()` throws
rather than producing a write description, so the validation boundary is
structural rather than a convention you have to remember.

```swift
let validated = try changeset.validatedChanges()
validated.changedFields   // ["display_name": "Ada Lovelace"]
validated.identity        // ["id": 1]   — nil for an insert
```

## Describing a model

One conformance, and it is the only thing the library asks of your type:

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

Every field is named by a keypath, so a typo is a compile error rather than a
runtime surprise. The string is what your *store* calls the column, and it need
not match the Swift property.

## Validation rules

Built in: `.email`, `.matches`, `.length`, `.range`, `.oneOf`, `.excluding`,
`.subset(of:)`, `.accepted()`, and `.custom`.

```swift
changeset
    .validateRequired(\.email)
    .validate(\.email, .email)
    .validate(\.age, .range(13...))
    .validate(\.status, .oneOf(["draft", "published"]))
    .validate(\.handle, .excluding(["admin", "root"], message: "is reserved"))
    .validate(\.tags, .subset(of: ["swift", "server"]))
```

Cross-field rules run against the changeset's effective state:

```swift
changeset
    .validate(.ordered(\.startsAt, before: \.endsAt))
    .validate(.confirms(\.password, matches: \.passwordConfirmation))
```

Rules are ordinary values, so a catalog of your own is a static extension:

```swift
extension ValidationRule where V == String {
    static var slug: ValidationRule {
        .matches(#"^[a-z0-9-]+$"#, message: "may only contain lowercase letters, numbers and hyphens")
    }
}
```

## Errors from outside the changeset

Not every failure is something a rule can see. A uniqueness violation is only
known once the database rejects the write. `addError` folds those back into the
same error stream, so a form has one place to look rather than two:

```swift
do {
    try await repo.insert(changeset.validatedChanges())
} catch let error as DatabaseError where error.isUniqueViolation {
    return render(form, errors: changeset.addError(\.email, "has already been taken").messagesByField)
}
```

## Previewing the result

`applyChanges()` materializes the model a changeset describes — for a form
preview or an optimistic UI update. It deliberately does not require validity,
because a preview is most useful while the user is still typing:

```swift
let preview = changeset.applyChanges()          // User?
let draft = changeset.applyChanges(to: .blank)  // for insert changesets
```

## What this library is not

It does not cast types — `Codable` already did that when your request body
decoded. It does not check that a field exists — keypaths make that a compile
error. It does not talk to a database, build queries, or run migrations.

Also not included, deliberately: nested and embedded changesets (validating a
parent and its children as one unit), and optimistic locking. If you need
either, this is not yet the library for you.

## Documentation

Full API documentation and guides:

```bash
SWIFT_CHANGESET_BUILD_DOCS=1 swift package generate-documentation --target Changesets
```

The DocC catalog includes guides on describing your model, validating changes,
and handling errors.

## License

MIT. See [LICENSE](LICENSE).
