# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-29

### Added

- **Nested changesets.** `nest(_:_:)` attaches a to-one or to-many
  association's child changesets, so a parent and its children validate as one
  unit: the parent is invalid while any child is, children's errors arrive
  under the path a nested form renders against (`lineItems[2].quantity`), and
  `validatedNestedChanges()` hands their writes back grouped by association —
  separately from the parent's, because for an insert the parent must land
  first.
- **Optimistic locking.** `optimisticLock(_:)` on an integer version column
  records the bump and pins the value read from the original into
  `ValidatedChanges.identity`, so the write becomes
  `SET version = 8 WHERE id = 1 AND version = 7`. A driver needs no special
  support; `ChangesetLock` and `ChangesetConflictError` are there for one that
  would rather raise a conflict than report "0 rows updated".
- `validateChanged(_:message:)` — the insert-side counterpart to
  `validateRequired(_:)`. A non-optional field cannot be "missing" once a row
  exists, but an untouched one is simply absent from an *insert*, where the
  first thing to notice was the store's `NOT NULL` error. This says "this
  insert must supply `display_name`" where the message can still reach the
  form.
- `updateChange(_:orError:_:)` — normalization that can reject its input.
  The transform returns `nil` to attach a message to the field instead of a
  value, for a phone number that will not parse or a URL that will not
  canonicalize.
- `ValidatedChanges.tableName` — the handoff now addresses its own table, so a
  driver API can take one argument rather than a value plus the table name its
  caller had to remember to pass alongside. `NestedChangeset` already exposed
  the same thing; the parent and its children are now symmetric.

### Fixed

- **`merge` corrupted nested associations.** Children were replaced per
  `(association, index)` pair while `nest` replaces a whole association, so
  merging a three-line order with a one-line one kept the two superseded lines
  and scrambled attachment order — writes for rows no current input described,
  and error paths pointing at children the merged form never rendered. Merging
  a to-one association with a to-many under the same name produced two
  children whose paths (`thing` and `thing[0]`) both claimed it. `merge` now
  replaces per association, exactly as `nest` does.
- **`deleteChange` could silently disarm an optimistic lock.** Dropping the
  version column's change left `lock` in force, so `validatedChanges()` still
  merged the expected version into `identity` — a write guarded by a version
  it never advanced. The next stale writer matched that same version and
  overwrote silently, which is precisely the lost update the lock exists to
  make loud. Dropping the lock column's change — with `deleteChange` or by
  reverting the field to the original's value — now clears the lock.
- **Editing the version after locking desynced the lock metadata.**
  `optimisticLock(\.version).change(\.version, 99)` wrote 99 while
  `lock.next` still said 8, so a driver reporting a conflict reported a value
  the write never used. `change`, `forceChange`, `updateChange`, and `merge`
  now re-point the lock at the value actually recorded.
- `merge`'s documentation claimed that merging two different rows traps. It
  cannot: `Model` need not be `Equatable`, so only insert/update parity is
  checked. The documentation now says what is and is not enforced.
- The DocC example on `nest` used a `.greaterThan(0)` rule that does not
  exist; copying it did not compile.

### Changed

- **`ValidatedChanges.init` takes `tableName` first.** Construction normally
  goes through `validatedChanges()`, which supplies it; only hand-built driver
  test fixtures need updating.
- Builder methods (`change`, `forceChange`, `updateChange`, `deleteChange`,
  `merge`, `validate`, `nest`, `optimisticLock`, …) are now `consuming`. A
  chain moves one value from stage to stage rather than copying its storage at
  every call, which turns a long pipeline's dictionary copying from quadratic
  into linear. Call sites are unaffected.
- Changesets store each changed value once. The writers behind
  `applyChanges()` used to capture the value as well as the keypath, holding
  every value twice and leaving two stores that could drift.
- The per-changeset duplicate-column-name check now runs in debug builds only.
  It verifies a property of the *type*, which cannot change at runtime, so a
  release build re-proved it — and paid a `Set` allocation — for every
  changeset constructed. `TableModel.validateColumnMetadata()` is the
  unconditional form, for a test that wants the check in any configuration.
- `ValidationRule.email` is scanned by hand rather than by a regular
  expression: no compile per evaluation, no allocation, and the same shape it
  documented (a differential test pins the two together). `.subset(of:)` no
  longer builds a set on the passing path, and `isValid` no longer allocates
  the combined error array to ask whether it is empty.

## [0.1.0] - 2026-08-23

### Added

- `addError(_:_:)` and `addError(column:_:)` — attach a failure discovered
  outside the changeset (a unique-constraint violation, an authorization
  decision) to a field, so it joins the same error stream as rule failures.
- `applyChanges()` and `applyChanges(to:)` — materialize the model a changeset
  describes, for form previews and optimistic UI. Deliberately does not require
  validity.
- `getChange(_:)`, `originalValue(_:)`, `changed(_:)`, and `changedColumn(_:)` —
  distinguish "what this write sets" from "what the row becomes" from "what was
  there before". `changed(_:)` is the only way to tell a `NULL` write from an
  untouched optional field.
- `updateChange(_:_:)` — transform a recorded change, for normalization
  (lowercasing an email, trimming whitespace, hashing a password). Overloaded so
  optional fields see the wrapped value.
- `forceChange(_:_:)` — record a value even when it equals the original, for
  timestamps and revision counters.
- `deleteChange(_:)` — drop a recorded change.
- `merge(_:)` — combine two changesets describing the same row.
- `messagesByField` on both `Changeset` and `ChangesetValidationError` — errors
  grouped by column, the shape a form or a JSON error body wants.
- Validation rules: `.excluding(_:message:)`, `.subset(of:message:)`,
  `.accepted(message:)`.
- Cross-field rule: `.confirms(_:matches:message:)` for password confirmation.
- `TableModel.validateColumnMetadata()` — check column metadata from a test.
- DocC catalog with four guides: getting started, describing your model,
  validating changes, and handling errors.

### Fixed

- **Duplicate column names silently corrupted writes.** Two `TableColumn`
  entries sharing a `name` would collide in the changeset's name-keyed storage,
  dropping one field's write and reading back the other's value with no error;
  the primary-key variant aborted the process with a bare stdlib message.
  Changeset construction now traps with a diagnostic naming the model and the
  duplicated column.
- `ChangesetValidationError` now conforms to `LocalizedError`, so
  `localizedDescription` carries the real messages rather than a generic
  Foundation placeholder.
- `ValidationRule.matches` now validates its pattern when the rule is built, so
  a malformed expression fails where it was written rather than at the first
  value that reaches it.

### Changed

- Platform floor lowered to macOS 13 / iOS 16 / tvOS 16 / watchOS 9 /
  visionOS 1, driven by `Regex` rather than by an unrelated consumer.
- Keypath parameters on `change`, `forceChange`, and `updateChange` are now
  `& Sendable`. Keypath literals infer as `Sendable`, so ordinary call sites are
  unaffected.

[Unreleased]: https://github.com/Swift-Flight/swift-changeset/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Swift-Flight/swift-changeset/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Swift-Flight/swift-changeset/releases/tag/v0.1.0
