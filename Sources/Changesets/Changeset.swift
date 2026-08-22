/// Validates and shapes data *before* it becomes a write (changeset design
/// §1): accumulates semantic-validation errors, tracks which fields actually
/// changed from an original, and produces the neutral `ValidatedChanges` a
/// driver translates into its native write.
///
/// Deliberately the *thin* layer (§2): no type casting ("is this an Int" is
/// Swift's job, already done at `Codable` decode), no "is this a real field"
/// checks (keypaths make that a compile error). Only the residual the type
/// system genuinely cannot cover: formats, lengths, ranges, cross-field
/// consistency, and dirty tracking.
///
/// Every field-referencing method takes a `WritableKeyPath`, never a string
/// (§4). Keypaths are erased to store-neutral column names (via the model's
/// `TableModel` metadata) only when building `changes` — the one place
/// store-agnosticism requires erasure.
///
/// ```swift
/// let changeset = Changeset(original: user)          // update; Changeset(User.self) for insert
///     .change(\.email, input.email)
///     .change(\.displayName, input.displayName)
///     .validate(\.email, .email)
///     .validate(\.displayName, .length(1...80))
///
/// guard changeset.isValid else { return .failure(changeset.errors) }
/// try await connection.apply(changeset.validatedChanges(), to: User.self)
/// ```
public struct Changeset<Model: TableModel>: Sendable {
    /// The row being updated, or nil for an insert changeset.
    public private(set) var original: Model?

    /// Dirty fields ONLY, keyed by store-neutral column name. A `change`
    /// whose value equals the original never lands here; one that reverts a
    /// prior change removes it. Values may box `Optional.none` ("set NULL").
    public private(set) var changes: [String: any Sendable]

    /// Every accumulated validation failure, in the order rules ran.
    public private(set) var errors: [ChangesetError]

    public var isValid: Bool { errors.isEmpty }

    /// False when nothing differs from the original — callers can skip the
    /// driver call entirely (drivers also treat empty `changedFields` as a
    /// no-op; see `InMemoryConnection.apply` for the reference translation).
    public var hasChanges: Bool { !changes.isEmpty }

    /// An insert changeset: no original, so *every* `change` is dirty and
    /// `validatedChanges().identity` is nil (§3).
    public init(_ type: Model.Type = Model.self) {
        self.original = nil
        self.changes = [:]
        self.errors = []
    }

    /// An update changeset over `original`: only genuine differences are
    /// tracked, and identity comes from the model's primary-key columns.
    public init(original: Model) {
        self.original = original
        self.changes = [:]
        self.errors = []
    }

    // MARK: - Change accumulation (§4: keypath-based, compile-checked)

    /// Records that `field` should become `value` — but only if it genuinely
    /// differs from the original (§6: "only if actually changed"). Setting a
    /// field back to its original value *removes* any recorded change, so
    /// `changes` always means exactly "differs from the original". Repeated
    /// changes to one field: last one wins.
    public func change<V: Sendable & Equatable>(_ field: WritableKeyPath<Model, V>, _ value: V) -> Changeset {
        let name = Model.column(for: field).name
        var next = self
        if let original, original[keyPath: field] == value {
            next.changes.removeValue(forKey: name)
        } else {
            next.changes.updateValue(value, forKey: name)
        }
        return next
    }

    /// Non-`Equatable` values cannot be compared against the original, so
    /// they are always recorded as dirty. Prefer `Equatable` column types —
    /// they are what makes minimal writes minimal.
    public func change<V: Sendable>(_ field: WritableKeyPath<Model, V>, _ value: V) -> Changeset {
        let name = Model.column(for: field).name
        var next = self
        next.changes.updateValue(value, forKey: name)
        return next
    }

    // MARK: - Effective values

    /// The value `field` would have if this changeset were applied: the
    /// recorded change if there is one, else the original's value, else nil
    /// (insert changeset, field untouched). This is what validation rules
    /// and cross-field checks read.
    public func value<V>(_ field: KeyPath<Model, V>) -> V? {
        let name = Model.column(for: field).name
        if let recorded = changes[name] {
            return recorded as? V
        }
        return original?[keyPath: field]
    }

    /// Optional-field overload, flattened: a recorded "set to nil", an
    /// original nil, and an untouched insert field all read as nil.
    public func value<V>(_ field: KeyPath<Model, V?>) -> V? {
        let name = Model.column(for: field).name
        if let recorded = changes[name] {
            return recorded as? V
        }
        return original.flatMap { $0[keyPath: field] }
    }

    // MARK: - Validation (accumulates, never throws mid-chain)

    /// Fails unless the *effective* value of `field` is non-nil. Only
    /// optional fields can be required — a non-optional field is guaranteed
    /// present by construction, and referencing it here is a compile error
    /// (§2: the type system's half of the job stays with the type system).
    public func validateRequired<V>(_ field: WritableKeyPath<Model, V?>) -> Changeset {
        let name = Model.column(for: field).name
        if value(field) == nil {
            return appending(ChangesetError(field: name, message: "is required"))
        }
        return self
    }

    /// Applies `rule` to `field`'s *recorded change*. A field with no
    /// recorded change is not validated — unchanged data came from the
    /// store and was validated when it was written (Ecto's semantics).
    /// Nil-ness is `validateRequired`'s job, not a rule's.
    public func validate<V>(_ field: WritableKeyPath<Model, V>, _ rule: ValidationRule<V>) -> Changeset {
        applyRule(rule, toChangeAt: Model.column(for: field).name)
    }

    /// Optional-field overload: the rule sees the wrapped value; a change
    /// that sets the field to nil is skipped (pair with `validateRequired`
    /// when nil must be rejected).
    public func validate<V>(_ field: WritableKeyPath<Model, V?>, _ rule: ValidationRule<V>) -> Changeset {
        applyRule(rule, toChangeAt: Model.column(for: field).name)
    }

    /// Applies a cross-field rule (§3) against the changeset's *effective*
    /// state. Cross-field rules always run — a consistency property must
    /// hold over the whole row, whichever side of it changed.
    public func validate(_ rule: CrossFieldRule<Model>) -> Changeset {
        if let message = rule.check(self) {
            return appending(ChangesetError(field: rule.field, message: message))
        }
        return self
    }

    // MARK: - The driver handoff (§3, §5)

    /// The neutral handoff to a driver. Throws `ChangesetValidationError`
    /// if `!isValid`, so an invalid changeset can NEVER reach a driver —
    /// validation failure is caught at this boundary, structurally.
    ///
    /// For update changesets, `identity` is read from the original's
    /// primary-key columns; a `TableModel` with no primary key cannot
    /// address a row and traps (metadata bug, not a runtime condition).
    public func validatedChanges() throws -> ValidatedChanges {
        guard errors.isEmpty else {
            throw ChangesetValidationError(errors: errors)
        }
        let identity: [String: any Sendable]?
        if let original {
            let primaryKey = Model.primaryKey
            precondition(!primaryKey.isEmpty, """
            \(Model.self) has no primary-key column, so an update changeset cannot address its row. \
            Flag identity columns with TableColumn(_, _, primaryKey: true).
            """)
            identity = Dictionary(uniqueKeysWithValues: primaryKey.map { ($0.name, $0.read(original)) })
        } else {
            identity = nil
        }
        return ValidatedChanges(changedFields: changes, identity: identity)
    }

    // MARK: - Internals

    private func applyRule<V>(_ rule: ValidationRule<V>, toChangeAt name: String) -> Changeset {
        guard let recorded = changes[name], let value = recorded as? V else {
            return self
        }
        if let message = rule.run(value) {
            return appending(ChangesetError(field: name, message: message))
        }
        return self
    }

    private func appending(_ error: ChangesetError) -> Changeset {
        var next = self
        next.errors.append(error)
        return next
    }
}
