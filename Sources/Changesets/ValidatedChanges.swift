/// The neutral, validated handoff from a changeset to a driver.
///
/// This is the *only* type that crosses the changeset/driver boundary, and
/// it is expressible for any store: a SQL driver turns ``changedFields``
/// into a `SET` clause and ``identity`` into a `WHERE`; a document driver
/// turns the same fields into `$set`. No write logic is shared, and no
/// changeset logic is duplicated.
///
/// Construction normally goes through ``Changeset/validatedChanges()``,
/// which throws on an invalid changeset — so an invalid one can never reach
/// a driver. The initializer is public for driver test fixtures.
public struct ValidatedChanges: Sendable {
    /// ONLY the fields that changed — this is what enables minimal writes.
    /// Keys are store-neutral column names (`TableColumn.name`); values may
    /// box an `Optional.none` to mean "set to NULL/absent".
    public let changedFields: [String: any Sendable]

    /// Primary-key identity, for updates.
    ///
    /// `nil` for inserts — that nil-ness is how a driver tells the two
    /// apart without a separate flag.
    public let identity: [String: any Sendable]?

    public init(changedFields: [String: any Sendable], identity: [String: any Sendable]?) {
        self.changedFields = changedFields
        self.identity = identity
    }
}

/// One failed validation, attached to a column.
///
/// Errors accumulate: a changeset reports *all* of them, never just the
/// first, so a form can render every message in one pass.
public struct ChangesetError: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The store-neutral column name the failure belongs to — what a form
    /// renders the message next to.
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    public var description: String {
        "\(field): \(message)"
    }
}

/// What ``Changeset/validatedChanges()`` throws for an invalid changeset.
///
/// Carries every accumulated error, so a caller that reaches for the thrown
/// value gets the same information a caller that inspected
/// ``Changeset/errors`` would have.
public struct ChangesetValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public let errors: [ChangesetError]

    public init(errors: [ChangesetError]) {
        self.errors = errors
    }

    public var description: String {
        "changeset is invalid: " + errors.map(\.description).joined(separator: "; ")
    }
}

#if canImport(Foundation)
import Foundation

extension ChangesetValidationError: LocalizedError {
    /// The same text as ``description``.
    ///
    /// Without this conformance `localizedDescription` — which is what most
    /// Swift logging and error-reporting code reaches for — would discard
    /// every message and report a generic Foundation placeholder.
    public var errorDescription: String? { description }
}
#endif

extension ChangesetValidationError {

    /// Errors grouped by column name, for rendering.
    ///
    /// A form renders messages next to fields, and a JSON API usually
    /// serializes the same shape. Grouping once here beats every caller
    /// writing the same `Dictionary(grouping:)`.
    ///
    /// ```swift
    /// catch let error as ChangesetValidationError {
    ///     return .unprocessableEntity(error.messagesByField)
    ///     // ["email": ["is not a valid email address"], "age": ["must be at least 13"]]
    /// }
    /// ```
    public var messagesByField: [String: [String]] {
        Dictionary(grouping: errors, by: \.field).mapValues { $0.map(\.message) }
    }
}

extension Changeset {

    /// This changeset's errors grouped by column name, for rendering.
    ///
    /// The same shape as ``ChangesetValidationError/messagesByField``, for
    /// the common case where you inspect the changeset directly instead of
    /// catching the thrown error.
    ///
    /// ```swift
    /// guard changeset.isValid else {
    ///     return render(form, errors: changeset.messagesByField)
    /// }
    /// ```
    public var messagesByField: [String: [String]] {
        Dictionary(grouping: errors, by: \.field).mapValues { $0.map(\.message) }
    }
}
