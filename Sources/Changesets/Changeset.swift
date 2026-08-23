/// Validates and shapes data *before* it becomes a write: accumulates
/// semantic-validation errors, tracks which fields actually changed from an
/// original, and produces the neutral ``ValidatedChanges`` a driver
/// translates into its native write.
///
/// A changeset is a **value**. Every method returns a new changeset rather
/// than mutating in place, so a pipeline reads top to bottom and any
/// intermediate stage can be held onto, branched from, or passed across an
/// isolation boundary.
///
/// ```swift
/// let changeset = Changeset(original: user)
///     .change(\.email, input.email)
///     .updateChange(\.email) { $0.lowercased() }
///     .change(\.displayName, input.displayName)
///     .validate(\.email, .email)
///     .validate(\.displayName, .length(1...80))
///
/// guard changeset.isValid else { return .failure(changeset.errors) }
/// try await connection.apply(changeset.validatedChanges(), to: User.self)
/// ```
///
/// ## Deliberately the thin layer
///
/// There is no type casting here — "is this an `Int`" is Swift's job and was
/// already done when the request body decoded. There are no "is this a real
/// field" checks — keypaths make that a compile error. What remains is the
/// residual the type system genuinely cannot cover: formats, lengths,
/// ranges, cross-field consistency, and dirty tracking.
///
/// ## Topics
///
/// ### Creating a changeset
/// - ``init(_:)``
/// - ``init(original:)``
///
/// ### Recording changes
/// - ``forceChange(_:_:)``
/// - ``deleteChange(_:)``
/// - ``merge(_:)``
///
/// ### Reading values
/// - ``changed(_:)``
///
/// ### Validating
/// - ``validateRequired(_:)``
/// - ``validate(_:)``
/// - ``addError(_:_:)``
///
/// ### Finishing
/// - ``applyChanges()``
/// - ``validatedChanges()``
public struct Changeset<Model: TableModel>: Sendable {

    /// The row being updated, or `nil` for an insert changeset.
    ///
    /// ```swift
    /// Changeset(User.self).original          // nil  — an insert
    /// Changeset(original: ada).original      // ada  — an update
    /// ```
    public private(set) var original: Model?

    /// Dirty fields only, keyed by store-neutral column name.
    ///
    /// A `change(_:_:)` whose value equals the original never lands
    /// here, and one that reverts a prior change removes it — so `changes`
    /// always means exactly "differs from the original". Values may box
    /// `Optional.none`, which means *set NULL*, not *no change*.
    ///
    /// Prefer ``changed(_:)`` and `getChange(_:)` for reading
    /// individual fields; they are keypath-based and type-safe. This
    /// dictionary is the form a driver consumes.
    public private(set) var changes: [String: any Sendable]

    /// Every accumulated validation failure, in the order the rules ran.
    ///
    /// Validation never short-circuits: a changeset reports *all* of its
    /// failures so a form can render every message at once.
    public private(set) var errors: [ChangesetError]

    /// Writers captured at change time, keyed by column name.
    ///
    /// ``applyChanges()`` uses these to materialize the result. They are
    /// captured when a change is recorded rather than read from column
    /// metadata, which is what lets ``TableColumn`` keep its read-only
    /// `KeyPath` initializer and still support materialization.
    internal private(set) var appliers: [String: @Sendable (inout Model) -> Void]

    /// `true` when no validation has failed.
    public var isValid: Bool { errors.isEmpty }

    /// `false` when nothing differs from the original.
    ///
    /// Callers can skip the driver call entirely; drivers also treat an
    /// empty ``ValidatedChanges/changedFields`` as a no-op.
    ///
    /// ```swift
    /// guard changeset.hasChanges else { return .noChange }
    /// ```
    public var hasChanges: Bool { !changes.isEmpty }

    // MARK: - Creating a changeset

    /// An insert changeset: no original, so *every* change is dirty and
    /// ``ValidatedChanges/identity`` is `nil`.
    ///
    /// ```swift
    /// let changeset = Changeset(User.self)
    ///     .change(\.email, "grace@example.com")
    ///     .change(\.displayName, "Grace")
    /// ```
    ///
    /// - Precondition: `Model.columns` must not contain two entries with the
    ///   same ``TableColumn/name``. Duplicate names would silently collide
    ///   in ``changes``, so they trap here with a message naming the
    ///   offending column.
    public init(_ type: Model.Type = Model.self) {
        Model.assertColumnNamesAreUnique()
        self.original = nil
        self.changes = [:]
        self.errors = []
        self.appliers = [:]
    }

    /// An update changeset over `original`: only genuine differences are
    /// tracked, and identity comes from the model's primary-key columns.
    ///
    /// ```swift
    /// let changeset = Changeset(original: ada)
    ///     .change(\.age, 37)
    /// changeset.changes            // ["age": 37]
    /// ```
    ///
    /// - Precondition: `Model.columns` must not contain two entries with the
    ///   same ``TableColumn/name``.
    public init(original: Model) {
        Model.assertColumnNamesAreUnique()
        self.original = original
        self.changes = [:]
        self.errors = []
        self.appliers = [:]
    }

    // MARK: - Recording changes

    /// Records that `field` should become `value` — but only if it genuinely
    /// differs from the original.
    ///
    /// Setting a field back to its original value *removes* the recorded
    /// change, so a user who edits a field and then undoes the edit produces
    /// no write for it. Repeated changes to one field: last one wins.
    ///
    /// ```swift
    /// Changeset(original: ada)
    ///     .change(\.age, 37)
    ///     .change(\.age, 36)      // ada.age is 36
    ///     .hasChanges              // false — the edit was undone
    /// ```
    ///
    /// To record a change unconditionally, use ``forceChange(_:_:)``.
    public func change<V: Sendable & Equatable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ value: V
    ) -> Changeset {
        let name = Model.column(for: field).name
        var next = self
        if let original, original[keyPath: field] == value {
            next.changes.removeValue(forKey: name)
            next.appliers.removeValue(forKey: name)
        } else {
            next.record(value, at: name, field: field)
        }
        return next
    }

    /// Records a change for a value that cannot be compared to the original.
    ///
    /// Non-`Equatable` values are always recorded as dirty, because there is
    /// no way to tell whether they differ. Prefer `Equatable` column types —
    /// they are what makes minimal writes minimal.
    public func change<V: Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ value: V
    ) -> Changeset {
        var next = self
        next.record(value, at: Model.column(for: field).name, field: field)
        return next
    }

    /// Records `value` for `field` even when it equals the original.
    ///
    /// The escape hatch from dirty tracking. Use it when a column must be
    /// written regardless of whether the user changed anything — a
    /// `updated_at` stamp, a revision counter, a re-issued token.
    ///
    /// ```swift
    /// changeset
    ///     .change(\.displayName, input.name)   // may be a no-op
    ///     .forceChange(\.updatedAt, .now)      // always written
    /// ```
    public func forceChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ value: V
    ) -> Changeset {
        var next = self
        next.record(value, at: Model.column(for: field).name, field: field)
        return next
    }

    /// Transforms the recorded change for `field`, if there is one.
    ///
    /// A field with no recorded change is left alone — `transform` is not
    /// called and no change is created. This is the normalization hook:
    /// lowercase an email, trim whitespace, hash a password, round a price.
    ///
    /// ```swift
    /// Changeset(User.self)
    ///     .change(\.email, "  Ada@Example.COM ")
    ///     .updateChange(\.email) { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    ///     .getChange(\.email)          // "ada@example.com"
    /// ```
    ///
    /// Because it runs *before* validation in a normal pipeline, a rule that
    /// follows sees the normalized value.
    public func updateChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ transform: (V) -> V
    ) -> Changeset {
        let name = Model.column(for: field).name
        guard let recorded = changes[name], let typed = recorded as? V else {
            return self
        }
        var next = self
        next.record(transform(typed), at: name, field: field)
        return next
    }

    /// Optional-field overload of `updateChange(_:_:)`.
    ///
    /// The transform sees the *wrapped* value, so you write
    /// `{ $0.lowercased() }` rather than unwrapping by hand. A field that
    /// was changed to `nil`, or not changed at all, is left alone.
    ///
    /// ```swift
    /// Changeset(User.self)
    ///     .change(\.email, "  Ada@Example.COM ")     // email is String?
    ///     .updateChange(\.email) { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    ///     .getChange(\.email)                         // "ada@example.com"
    /// ```
    public func updateChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V?> & Sendable, _ transform: (V) -> V
    ) -> Changeset {
        let name = Model.column(for: field).name
        guard let recorded = changes[name], let typed = recorded as? V else {
            return self
        }
        var next = self
        next.record(V?.some(transform(typed)), at: name, field: field)
        return next
    }

    /// Removes any recorded change for `field`.
    ///
    /// The field reverts to reading as the original's value. Use it to drop
    /// a field a caller is not permitted to write, or to discard a change
    /// after deciding it is redundant.
    ///
    /// ```swift
    /// changeset.deleteChange(\.role)      // never let the client set this
    /// ```
    public func deleteChange<V>(_ field: KeyPath<Model, V>) -> Changeset {
        let name = Model.column(for: field).name
        var next = self
        next.changes.removeValue(forKey: name)
        next.appliers.removeValue(forKey: name)
        return next
    }

    /// Combines `other` into this changeset.
    ///
    /// Changes and errors from `other` are layered on top of this one:
    /// where both record the same field, `other` wins; errors from both are
    /// kept, this changeset's first. Use it to assemble one changeset from
    /// several independently-built pieces — a base changeset plus a
    /// role-specific one, say.
    ///
    /// ```swift
    /// let full = baseChangeset.merge(adminOnlyChangeset)
    /// ```
    ///
    /// - Precondition: both changesets must describe the same row — either
    ///   both inserts, or both updates whose originals are the same value.
    ///   Merging an insert with an update, or two different rows, is a
    ///   programmer error and traps.
    public func merge(_ other: Changeset) -> Changeset {
        precondition(
            (original == nil) == (other.original == nil),
            """
            Cannot merge an insert changeset with an update changeset for \
            \(Model.self). Both sides must describe the same row.
            """
        )
        var next = self
        next.changes.merge(other.changes) { _, incoming in incoming }
        next.appliers.merge(other.appliers) { _, incoming in incoming }
        next.errors.append(contentsOf: other.errors)
        return next
    }

    // MARK: - Internals

    /// Stores a value and the writer that will materialize it.
    private mutating func record<V: Sendable>(
        _ value: V, at name: String, field: WritableKeyPath<Model, V> & Sendable
    ) {
        changes.updateValue(value, forKey: name)
        appliers.updateValue({ model in model[keyPath: field] = value }, forKey: name)
    }

    /// Appends an error. Internal so the only public paths are the
    /// validation methods and ``addError(_:_:)``.
    internal func appending(_ error: ChangesetError) -> Changeset {
        var next = self
        next.errors.append(error)
        return next
    }
}
