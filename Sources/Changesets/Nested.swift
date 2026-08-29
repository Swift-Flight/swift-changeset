/// A child changeset attached to a parent, validated as part of the same
/// unit of work.
///
/// A nested changeset is type-erased on purpose: a parent holds children of
/// several different model types, and the parent's own generic parameter
/// cannot express that. What survives erasure is everything a caller or a
/// driver actually needs — the association it belongs to, its position, its
/// validity, its errors, and a deferred handoff to
/// ``ValidatedChanges``.
///
/// You do not construct these directly. ``Changeset/nest(_:_:)-(_,[Changeset<Child>])``
/// makes them.
public struct NestedChangeset: Sendable {

    /// The association name the parent attached this child under —
    /// `"addresses"`, `"lineItems"`. It is the first segment of the error
    /// paths this child contributes.
    public let association: String

    /// Position within the association, or `nil` for a to-one association.
    ///
    /// Drives the error path: index `0` renders as `addresses[0].zip`,
    /// `nil` as `profile.bio`.
    public let index: Int?

    /// The child model's ``TableModel/tableName`` — what a driver writes to,
    /// available without recovering the erased type.
    public let tableName: String

    /// `true` when the child recorded no differences from its original.
    public let hasChanges: Bool

    /// `true` when the child accumulated no validation failures.
    public let isValid: Bool

    /// The child's own errors, with their field names exactly as the child
    /// reported them — `"zip"`, not `"addresses[0].zip"`.
    ///
    /// Use ``pathedErrors`` for the parent-facing form.
    public let errors: [ChangesetError]

    private let handoff: @Sendable () throws -> ValidatedChanges

    internal init<Child: TableModel>(
        association: String,
        index: Int?,
        changeset: Changeset<Child>
    ) {
        self.association = association
        self.index = index
        self.tableName = Child.tableName
        self.hasChanges = changeset.hasChanges
        self.isValid = changeset.isValid
        self.errors = changeset.errors
        self.handoff = { try changeset.validatedChanges() }
    }

    /// The path prefix this child's errors carry into the parent:
    /// `"addresses[0]"` or `"profile"`.
    public var path: String {
        guard let index else { return association }
        return "\(association)[\(index)]"
    }

    /// This child's errors with their field names rewritten to the full
    /// path a nested form renders against.
    ///
    /// ```swift
    /// // child reported   ChangesetError(field: "zip", message: "is required")
    /// // parent sees      ChangesetError(field: "addresses[0].zip", ...)
    /// ```
    public var pathedErrors: [ChangesetError] {
        errors.map { ChangesetError(field: "\(path).\($0.field)", message: $0.message) }
    }

    /// The child's neutral handoff to a driver.
    ///
    /// - Throws: ``ChangesetValidationError`` if the child is invalid. In
    ///   practice a caller reaches this only after the parent's
    ///   ``Changeset/validatedChanges()`` succeeded, which already requires
    ///   every child to be valid.
    public func validatedChanges() throws -> ValidatedChanges {
        try handoff()
    }
}

extension Changeset {

    // MARK: - Nesting

    /// Attaches a to-many association's changesets, so the parent and its
    /// children validate as one unit.
    ///
    /// The parent is invalid while any child is, and the children's errors
    /// appear in ``errors`` under `association[index].field` — the key a
    /// nested form renders against. Nothing is written here: use
    /// ``validatedNestedChanges()`` to get the children's handoffs after the
    /// parent's.
    ///
    /// ```swift
    /// let order = Changeset(Order.self)
    ///     .change(\.customerID, customerID)
    ///     .nest("lineItems", input.lines.map { line in
    ///         Changeset(LineItem.self)
    ///             .change(\.sku, line.sku)
    ///             .change(\.quantity, line.quantity)
    ///             .validate(\.quantity, .range(1..., message: "must be at least 1"))
    ///     })
    ///
    /// order.isValid                 // false if any line has quantity 0
    /// order.messagesByField         // ["lineItems[2].quantity": ["must be at least 1"]]
    /// ```
    ///
    /// Attaching the same `association` twice replaces the previous
    /// children rather than appending to them, so rebuilding a form's
    /// children from fresh input is idempotent. ``merge(_:)`` replaces at
    /// the same granularity, for the same reason: a superseded submission
    /// must not leave its extra rows behind.
    ///
    /// - Note: This does not decide write order. For inserts a driver must
    ///   write the parent first — the children usually need its generated
    ///   key — which is why ``validatedChanges()`` and
    ///   ``validatedNestedChanges()`` are separate calls rather than one.
    public consuming func nest<Child: TableModel>(
        _ association: String, _ children: [Changeset<Child>]
    ) -> Changeset {
        var next = consume self
        next.nestedChangesets.removeAll { $0.association == association }
        next.nestedChangesets.append(
            contentsOf: children.enumerated().map { index, child in
                NestedChangeset(association: association, index: index, changeset: child)
            }
        )
        return next
    }

    /// Attaches a to-one association's changeset.
    ///
    /// The same contract as the to-many overload, with unindexed error
    /// paths: a failure on the child's `bio` reads as `profile.bio`. An
    /// association is to-one or to-many, never both: nesting either way
    /// replaces whatever the association held before.
    ///
    /// ```swift
    /// let user = Changeset(original: ada)
    ///     .change(\.displayName, "Ada L.")
    ///     .nest("profile", Changeset(original: adasProfile).change(\.bio, bio))
    /// ```
    public consuming func nest<Child: TableModel>(
        _ association: String, _ child: Changeset<Child>
    ) -> Changeset {
        var next = consume self
        next.nestedChangesets.removeAll { $0.association == association }
        next.nestedChangesets.append(
            NestedChangeset(association: association, index: nil, changeset: child)
        )
        return next
    }

    /// Removes an association's children.
    public consuming func removeNested(_ association: String) -> Changeset {
        var next = consume self
        next.nestedChangesets.removeAll { $0.association == association }
        return next
    }

    /// The children attached under `association`, in order.
    ///
    /// ```swift
    /// order.nested("lineItems").count      // 3
    /// ```
    public func nested(_ association: String) -> [NestedChangeset] {
        nestedChangesets.filter { $0.association == association }
    }

    /// Every child's handoff, grouped by association and in attachment
    /// order.
    ///
    /// Call it after ``validatedChanges()`` — for an insert, after the
    /// parent row exists and its generated key is known, since that key is
    /// normally what the children's foreign key needs.
    ///
    /// ```swift
    /// let parent = try changeset.validatedChanges()
    /// let id = try await driver.insert(parent, into: Order.tableName)
    /// for (association, rows) in try changeset.validatedNestedChanges() {
    ///     for row in rows { try await driver.insert(row.withParent(id), into: ...) }
    /// }
    /// ```
    ///
    /// - Throws: ``ChangesetValidationError`` if any child is invalid.
    ///   Unreachable in the normal flow, where the parent's
    ///   ``validatedChanges()`` already refused for the same reason.
    public func validatedNestedChanges() throws -> [String: [ValidatedChanges]] {
        var result: [String: [ValidatedChanges]] = [:]
        for child in nestedChangesets {
            result[child.association, default: []].append(try child.validatedChanges())
        }
        return result
    }
}
