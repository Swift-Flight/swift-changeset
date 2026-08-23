# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
