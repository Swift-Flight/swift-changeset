/// The neutral, validated handoff from a changeset to a driver (§3, §5).
///
/// This is the *only* type that crosses the changeset/driver boundary, and
/// it is expressible for any store: Postgres turns `changedFields` into a
/// `SET` clause and `identity` into a `WHERE`; a Mongo driver turns the same
/// fields into `$set`. Zero shared write logic, zero duplicated changeset
/// logic — the §5 proof that the store-agnostic line is drawn right.
///
/// Construction goes through `Changeset.validatedChanges()`, which throws on
/// an invalid changeset — an invalid one can never reach a driver,
/// structurally. The initializer is public for driver test fixtures.
public struct ValidatedChanges: Sendable {
    /// ONLY the fields that changed — this is what enables minimal writes.
    /// Keys are store-neutral column names (`TableColumn.name`); values may
    /// box an `Optional.none` to mean "set to NULL/absent".
    public let changedFields: [String: any Sendable]

    /// Primary-key identity, for UPDATEs. Nil for inserts — nil-ness is how
    /// a driver distinguishes the two (§5).
    public let identity: [String: any Sendable]?

    public init(changedFields: [String: any Sendable], identity: [String: any Sendable]?) {
        self.changedFields = changedFields
        self.identity = identity
    }
}

/// One failed validation, attached to a column (§3). Accumulated — a
/// changeset reports *all* of them, never just the first.
public struct ChangesetError: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The store-neutral column name (`TableColumn.name`) the failure
    /// belongs to — what a form renders the message next to.
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

/// What `validatedChanges()` throws for an invalid changeset — the §3
/// boundary made structural. Carries every accumulated error.
public struct ChangesetValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public let errors: [ChangesetError]

    public init(errors: [ChangesetError]) {
        self.errors = errors
    }

    public var description: String {
        "changeset is invalid: " + errors.map(\.description).joined(separator: "; ")
    }
}
