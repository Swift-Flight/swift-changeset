/// An optimistic lock recorded on a changeset: which column guards the row,
/// what the changeset believes its value to be, and what it will become.
///
/// Optimistic locking makes a lost update *loud*. Two users load the same
/// row, both edit it, both save; without a lock the second write silently
/// overwrites the first. With one, the second write matches zero rows —
/// because the version it expects is no longer there — and the driver can
/// tell the user their copy is stale.
///
/// The whole mechanism is expressed in terms a driver already implements:
/// the lock column is merged into ``ValidatedChanges/identity`` (the value
/// the changeset expects, joining the primary key in the `WHERE`) and into
/// ``ValidatedChanges/changedFields`` (the incremented value, joining the
/// `SET`). A driver that has never heard of locking does the right thing.
/// This type is here for one that wants to raise
/// ``ChangesetConflictError`` rather than report "0 rows updated".
public struct ChangesetLock: Sendable {
    /// The store-neutral name of the version column.
    public let field: String

    /// The version the changeset read from the original — what the `WHERE`
    /// must still find.
    public let expected: any Sendable

    /// The version the write installs: `expected` plus one.
    public let next: any Sendable

    public init(field: String, expected: any Sendable, next: any Sendable) {
        self.field = field
        self.expected = expected
        self.next = next
    }
}

/// What a driver raises when an optimistically-locked write matched no row.
///
/// Distinct from "the row was deleted", which a driver cannot tell apart
/// from "the version moved" without a second query — the message says so
/// rather than guessing.
public struct ChangesetConflictError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The table the write targeted.
    public let table: String
    /// The version column that guarded it.
    public let field: String
    /// The version the write expected to find, rendered for display.
    public let expected: String

    public init(table: String, field: String, expected: String) {
        self.table = table
        self.field = field
        self.expected = expected
    }

    public var description: String {
        """
        \(table) row was modified by someone else: expected \(field) == \(expected). \
        Reload the row and re-apply the change.
        """
    }
}

#if canImport(Foundation)
import Foundation

extension ChangesetConflictError: LocalizedError {
    /// The same text as ``description``.
    public var errorDescription: String? { description }
}
#endif

extension Changeset {

    // MARK: - Optimistic locking

    /// Guards this update against a concurrent write, using an integer
    /// version column.
    ///
    /// Records `field = original + 1` as a change *and* pins the original's
    /// value into ``ValidatedChanges/identity``, so the resulting write is
    /// `SET version = 8 WHERE id = 1 AND version = 7`. If another writer
    /// got there first, the row's version is no longer 7, the update matches
    /// nothing, and the driver reports the conflict instead of silently
    /// discarding the other writer's edit.
    ///
    /// ```swift
    /// let changeset = Changeset(original: post)      // post.version == 7
    ///     .change(\.title, "Revised")
    ///     .optimisticLock(\.version)
    ///
    /// let validated = try changeset.validatedChanges()
    /// validated.changedFields    // ["title": "Revised", "version": 8]
    /// validated.identity         // ["id": 1, "version": 7]
    /// ```
    ///
    /// The version is written unconditionally, the way ``forceChange(_:_:)``
    /// writes: locking a changeset with no other changes still bumps the
    /// version, which is what a "touch to claim this row" flow wants.
    ///
    /// On an **insert** changeset this is a no-op — there is no original to
    /// lock against, and the row's starting version comes from its column
    /// default or from an explicit `change(\.version, 1)`.
    ///
    /// Calling it twice, or after changing the version by hand, leaves the
    /// last lock in force.
    ///
    /// - Note: The increment wraps rather than traps at the version type's
    ///   maximum. Reaching `Int32.max` takes two billion updates to one row;
    ///   trapping there would turn a survivable curiosity into a crash.
    /// - Precondition: `field` must not also be a primary-key column — the
    ///   two would collide in ``ValidatedChanges/identity``.
    public func optimisticLock<V: FixedWidthInteger & Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable
    ) -> Changeset {
        guard let original else { return self }
        let column = Model.column(for: field)
        precondition(!column.isPrimaryKey, """
        \(Model.self).\(column.name) is a primary-key column and cannot also be the \
        optimistic-lock column: identity would carry two conflicting values for it. \
        Add a separate version column.
        """)
        let expected = original[keyPath: field]
        let next = expected &+ 1
        var result = forceChange(field, next)
        result.lock = ChangesetLock(field: column.name, expected: expected, next: next)
        return result
    }
}
