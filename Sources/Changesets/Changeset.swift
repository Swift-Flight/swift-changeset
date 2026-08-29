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
/// The builder methods take `self` by consumption, so a chain moves one
/// value from stage to stage instead of copying its storage at every step.
/// That is invisible at the call site — a changeset held in a `let` is
/// copied implicitly, exactly as before — but it keeps a long pipeline
/// linear rather than quadratic.
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
/// - ``change(_:_:)``
/// - ``forceChange(_:_:)``
/// - ``updateChange(_:_:)``
/// - ``updateChange(_:orError:_:)``
/// - ``deleteChange(_:)``
/// - ``merge(_:)``
///
/// ### Reading values
/// - ``changed(_:)``
///
/// ### Validating
/// - ``validateRequired(_:)``
/// - ``validateChanged(_:message:)``
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

    /// This changeset's own validation failures, excluding any contributed
    /// by nested children.
    ///
    /// Almost every caller wants ``errors`` instead — it is this list plus
    /// the children's, which is what a form renders. Reach for `ownErrors`
    /// only to answer "did the *parent* fail, or just a child?".
    public internal(set) var ownErrors: [ChangesetError]

    /// Nested child changesets, in the order they were attached.
    ///
    /// Populated by ``nest(_:_:)-(_,[Changeset<Child>])``. Their errors
    /// appear in ``errors`` under a path like `addresses[0].zip`, and their
    /// writes are read back with ``validatedNestedChanges()``.
    public internal(set) var nestedChangesets: [NestedChangeset]

    /// Optimistic-lock state, set by ``optimisticLock(_:)``.
    ///
    /// `nil` unless a lock was requested. When present, the lock column is
    /// merged into both ``ValidatedChanges/changedFields`` (the incremented
    /// value) and ``ValidatedChanges/identity`` (the value read from the
    /// original), so a driver that knows nothing about locking still writes
    /// the right SQL.
    ///
    /// The library keeps this in step with the write it describes: editing
    /// the lock column by hand after locking retargets ``ChangesetLock/next``,
    /// and dropping its change clears the lock entirely rather than leaving
    /// a guard nothing advances.
    public internal(set) var lock: ChangesetLock?

    /// Every accumulated validation failure, in the order the rules ran —
    /// this changeset's own, followed by its children's.
    ///
    /// Validation never short-circuits: a changeset reports *all* of its
    /// failures so a form can render every message at once. A nested
    /// child's failures arrive with their field names prefixed by the
    /// association path (`addresses[0].zip`), which is exactly the key a
    /// nested form renders against.
    public var errors: [ChangesetError] {
        guard !nestedChangesets.isEmpty else { return ownErrors }
        return ownErrors + nestedChangesets.flatMap(\.pathedErrors)
    }

    /// Writers captured at change time, keyed by column name.
    ///
    /// ``applyChanges()`` uses these to materialize the result. They are
    /// captured when a change is recorded rather than read from column
    /// metadata, which is what lets ``TableColumn`` keep its read-only
    /// `KeyPath` initializer and still support materialization.
    ///
    /// Each closure captures only its keypath and takes the value from
    /// ``changes`` at apply time, so a value is stored once rather than
    /// twice and the two stores cannot drift.
    internal private(set) var appliers: [String: @Sendable (inout Model, any Sendable) -> Void]

    /// `true` when no validation has failed.
    public var isValid: Bool {
        ownErrors.isEmpty && nestedChangesets.allSatisfy(\.isValid)
    }

    /// `false` when nothing differs from the original, here or in any
    /// nested child.
    ///
    /// Callers can skip the driver call entirely; drivers also treat an
    /// empty ``ValidatedChanges/changedFields`` as a no-op.
    ///
    /// ```swift
    /// guard changeset.hasChanges else { return .noChange }
    /// ```
    public var hasChanges: Bool {
        !changes.isEmpty || nestedChangesets.contains(where: \.hasChanges)
    }

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
    /// - Precondition: in debug builds, `Model.columns` must not contain two
    ///   entries with the same ``TableColumn/name``. Duplicate names would
    ///   silently collide in ``changes``, so they trap here with a message
    ///   naming the offending column. Call
    ///   ``TableModel/validateColumnMetadata()`` from a test to check the
    ///   same property in any build configuration.
    public init(_ type: Model.Type = Model.self) {
        Model.assertColumnNamesAreUniqueWhenDebugging()
        self.original = nil
        self.changes = [:]
        self.ownErrors = []
        self.appliers = [:]
        self.nestedChangesets = []
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
    /// - Precondition: in debug builds, `Model.columns` must not contain two
    ///   entries with the same ``TableColumn/name``.
    public init(original: Model) {
        Model.assertColumnNamesAreUniqueWhenDebugging()
        self.original = original
        self.changes = [:]
        self.ownErrors = []
        self.appliers = [:]
        self.nestedChangesets = []
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
    ///
    /// - Note: Reverting the ``optimisticLock(_:)`` column this way clears
    ///   the lock, because a version the write never advances guards
    ///   nothing.
    public consuming func change<V: Sendable & Equatable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ value: V
    ) -> Changeset {
        let name = Model.column(for: field).name
        let reverts = original?[keyPath: field] == value
        var next = consume self
        if reverts {
            next.removeRecord(at: name)
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
    public consuming func change<V: Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ value: V
    ) -> Changeset {
        let name = Model.column(for: field).name
        var next = consume self
        next.record(value, at: name, field: field)
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
    public consuming func forceChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ value: V
    ) -> Changeset {
        let name = Model.column(for: field).name
        var next = consume self
        next.record(value, at: name, field: field)
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
    /// follows sees the normalized value. For a normalization that can
    /// *fail*, use ``updateChange(_:orError:_:)``.
    public consuming func updateChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable, _ transform: (V) -> V
    ) -> Changeset {
        let name = Model.column(for: field).name
        guard let recorded = changes[name], let typed = recorded as? V else {
            return self
        }
        let transformed = transform(typed)
        var next = consume self
        next.record(transformed, at: name, field: field)
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
    public consuming func updateChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V?> & Sendable, _ transform: (V) -> V
    ) -> Changeset {
        let name = Model.column(for: field).name
        guard let recorded = changes[name], let typed = recorded as? V else {
            return self
        }
        let transformed = V?.some(transform(typed))
        var next = consume self
        next.record(transformed, at: name, field: field)
        return next
    }

    /// Transforms the recorded change for `field`, attaching `message` when
    /// the transform cannot produce a value.
    ///
    /// The normalization hook for conversions that can reject their input —
    /// parsing a phone number into E.164, canonicalizing a URL, decoding a
    /// signed token. Returning `nil` from `transform` leaves the recorded
    /// change as it was and records an error on the field, so the changeset
    /// is invalid and ``validatedChanges()`` refuses it.
    ///
    /// ```swift
    /// Changeset(User.self)
    ///     .change(\.phone, input.phone)
    ///     .updateChange(\.phone, orError: "is not a valid phone number") {
    ///         E164.normalize($0)
    ///     }
    /// ```
    ///
    /// A field with no recorded change is left alone and `transform` is not
    /// called — absence is ``validateRequired(_:)``'s job, exactly as with
    /// ``updateChange(_:_:)``.
    public consuming func updateChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V> & Sendable,
        orError message: String,
        _ transform: (V) -> V?
    ) -> Changeset {
        let name = Model.column(for: field).name
        guard let recorded = changes[name], let typed = recorded as? V else {
            return self
        }
        guard let transformed = transform(typed) else {
            return appending(ChangesetError(field: name, message: message))
        }
        var next = consume self
        next.record(transformed, at: name, field: field)
        return next
    }

    /// Optional-field overload of `updateChange(_:orError:_:)`.
    ///
    /// The transform sees the *wrapped* value. A field changed to `nil`, or
    /// not changed at all, is left alone.
    public consuming func updateChange<V: Sendable>(
        _ field: WritableKeyPath<Model, V?> & Sendable,
        orError message: String,
        _ transform: (V) -> V?
    ) -> Changeset {
        let name = Model.column(for: field).name
        guard let recorded = changes[name], let typed = recorded as? V else {
            return self
        }
        guard let transformed = transform(typed) else {
            return appending(ChangesetError(field: name, message: message))
        }
        var next = consume self
        next.record(V?.some(transformed), at: name, field: field)
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
    ///
    /// - Note: Deleting the ``optimisticLock(_:)`` column's change clears
    ///   the lock. Keeping it would leave a write guarded by a version it
    ///   never advances — the next stale writer would match the same
    ///   version and overwrite silently, which is the exact failure the
    ///   lock exists to prevent.
    public consuming func deleteChange<V>(_ field: KeyPath<Model, V>) -> Changeset {
        let name = Model.column(for: field).name
        var next = consume self
        next.removeRecord(at: name)
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
    /// Nested children are replaced **per association**, matching
    /// ``nest(_:_:)-(_,[Changeset<Child>])``: an association `other`
    /// attaches supersedes this changeset's children for that association
    /// entirely, rather than being spliced into them position by position.
    /// Associations `other` says nothing about are kept as they are. That is
    /// the only semantics that keeps the merged form describing one
    /// submission: a shorter list of line items must not leave the longer
    /// list's tail behind.
    ///
    /// An optimistic lock from `other` replaces this one, and the surviving
    /// lock is re-pointed at whatever value the merged changes record for
    /// its column.
    ///
    /// - Precondition: both changesets must describe the same row. Insert /
    ///   update parity is checked here and traps; that the two *originals*
    ///   are the same row cannot be checked, because `Model` need not be
    ///   `Equatable` — merging updates over two different rows produces a
    ///   changeset whose identity comes from this side's original and whose
    ///   changes are a blend of both, which is a caller's bug the library
    ///   cannot catch for you.
    public consuming func merge(_ other: Changeset) -> Changeset {
        precondition(
            (original == nil) == (other.original == nil),
            """
            Cannot merge an insert changeset with an update changeset for \
            \(Model.self). Both sides must describe the same row.
            """
        )
        var next = consume self
        next.changes.merge(other.changes) { _, incoming in incoming }
        next.appliers.merge(other.appliers) { _, incoming in incoming }
        next.ownErrors.append(contentsOf: other.ownErrors)
        if !other.nestedChangesets.isEmpty {
            let replaced = Set(other.nestedChangesets.map(\.association))
            next.nestedChangesets.removeAll { replaced.contains($0.association) }
            next.nestedChangesets.append(contentsOf: other.nestedChangesets)
        }
        if let incoming = other.lock { next.lock = incoming }
        next.reconcileLock()
        return next
    }

    // MARK: - Internals

    /// Stores a value and the writer that will materialize it.
    private mutating func record<V: Sendable>(
        _ value: V, at name: String, field: WritableKeyPath<Model, V> & Sendable
    ) {
        changes.updateValue(value, forKey: name)
        appliers.updateValue(
            { model, recorded in
                if let typed = recorded as? V { model[keyPath: field] = typed }
            },
            forKey: name
        )
        if let lock, lock.field == name {
            self.lock = ChangesetLock(field: name, expected: lock.expected, next: value)
        }
    }

    /// Drops a recorded change, and any lock that depended on it.
    private mutating func removeRecord(at name: String) {
        changes.removeValue(forKey: name)
        appliers.removeValue(forKey: name)
        if lock?.field == name { lock = nil }
    }

    /// Re-points the lock at whatever ``changes`` now records for its
    /// column, or drops it when nothing does. Used where changes arrive in
    /// bulk rather than one at a time.
    private mutating func reconcileLock() {
        guard let lock else { return }
        if let recorded = changes[lock.field] {
            self.lock = ChangesetLock(field: lock.field, expected: lock.expected, next: recorded)
        } else {
            self.lock = nil
        }
    }

    /// Appends an error. Internal so the only public paths are the
    /// validation methods and ``addError(_:_:)``.
    internal consuming func appending(_ error: ChangesetError) -> Changeset {
        var next = consume self
        next.ownErrors.append(error)
        return next
    }
}
