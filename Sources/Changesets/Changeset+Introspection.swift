extension Changeset {

    // MARK: - Reading values

    /// The value `field` would have if this changeset were applied: the
    /// recorded change if there is one, else the original's value, else
    /// `nil`.
    ///
    /// This is the *effective* value, and it is what cross-field rules read.
    /// To ask specifically what changed, use `getChange(_:)`; to ask
    /// what was there before, use `originalValue(_:)`.
    ///
    /// ```swift
    /// let changeset = Changeset(original: ada).change(\.age, 37)
    /// changeset.value(\.age)          // 37  — the change
    /// changeset.value(\.displayName)  // "Ada" — untouched, from the original
    /// ```
    public func value<V>(_ field: KeyPath<Model, V>) -> V? {
        let name = Model.column(for: field).name
        if let recorded = changes[name] {
            return recorded as? V
        }
        return original?[keyPath: field]
    }

    /// Optional-field overload of `value(_:)`, flattened.
    ///
    /// A recorded "set to nil", an original `nil`, and an untouched insert
    /// field all read as `nil`. When you need to tell those apart, pair with
    /// ``changed(_:)``.
    public func value<V>(_ field: KeyPath<Model, V?>) -> V? {
        let name = Model.column(for: field).name
        if let recorded = changes[name] {
            return recorded as? V
        }
        return original.flatMap { $0[keyPath: field] }
    }

    /// The recorded change for `field`, or `nil` if it was not changed.
    ///
    /// Unlike `value(_:)` this never falls back to the original — it
    /// answers "what is this write setting?", not "what will the row look
    /// like?".
    ///
    /// ```swift
    /// let changeset = Changeset(original: ada).change(\.age, 37)
    /// changeset.getChange(\.age)          // 37
    /// changeset.getChange(\.displayName)  // nil — not part of this write
    /// ```
    public func getChange<V>(_ field: KeyPath<Model, V>) -> V? {
        changes[Model.column(for: field).name] as? V
    }

    /// Optional-field overload of `getChange(_:)`.
    ///
    /// Returns `nil` both when the field was not changed and when it was
    /// changed *to* `nil`. Use ``changed(_:)`` to distinguish them.
    public func getChange<V>(_ field: KeyPath<Model, V?>) -> V? {
        changes[Model.column(for: field).name] as? V
    }

    /// The value `field` had before any changes, or `nil` on an insert
    /// changeset.
    ///
    /// The natural partner to `getChange(_:)` when rendering a
    /// before-and-after diff.
    ///
    /// ```swift
    /// for column in User.columns where changeset.changedColumn(column.name) {
    ///     print("\(column.name): was \(changeset.originalValue(...)) ")
    /// }
    /// ```
    public func originalValue<V>(_ field: KeyPath<Model, V>) -> V? {
        original?[keyPath: field]
    }

    /// Optional-field overload of `originalValue(_:)`.
    public func originalValue<V>(_ field: KeyPath<Model, V?>) -> V? {
        original.flatMap { $0[keyPath: field] }
    }

    /// Whether `field` has a recorded change.
    ///
    /// This is the honest answer even when the change is to `nil`, which is
    /// what makes it the right tool for optional fields.
    ///
    /// ```swift
    /// let changeset = Changeset(original: ada).change(\.email, nil)
    /// changeset.value(\.email)      // nil — but so is an untouched field
    /// changeset.changed(\.email)    // true — this write sets it to NULL
    /// ```
    public func changed<V>(_ field: KeyPath<Model, V>) -> Bool {
        changes.keys.contains(Model.column(for: field).name)
    }

    /// Whether the column named `name` has a recorded change.
    ///
    /// The string-keyed form, for code that works across models — an audit
    /// log iterating ``TableModel/columns``, for instance. Prefer
    /// ``changed(_:)`` in model-specific code; it is compile-checked.
    public func changedColumn(_ name: String) -> Bool {
        changes.keys.contains(name)
    }

    // MARK: - Materializing

    /// The model as it would look with this changeset's changes applied.
    ///
    /// Returns `nil` for an insert changeset, which has no base to apply
    /// onto — use ``applyChanges(to:)`` there.
    ///
    /// This does **not** check validity: it answers "what would this
    /// produce?", which is exactly what a form preview or an optimistic UI
    /// update needs *while the user is still typing and the changeset is
    /// still invalid*. Guard on ``isValid`` yourself when that matters.
    ///
    /// ```swift
    /// let preview = changeset.applyChanges()      // User?
    /// ```
    public func applyChanges() -> Model? {
        guard var model = original else { return nil }
        for (name, apply) in appliers {
            if let recorded = changes[name] { apply(&model, recorded) }
        }
        return model
    }

    /// `base` with this changeset's changes applied.
    ///
    /// Works for insert and update changesets alike, since you supply the
    /// starting point. For an insert, pass a model holding your defaults.
    ///
    /// ```swift
    /// let draft = Changeset(User.self)
    ///     .change(\.email, "grace@example.com")
    ///     .applyChanges(to: User.blank)
    /// ```
    public func applyChanges(to base: Model) -> Model {
        var model = base
        for (name, apply) in appliers {
            if let recorded = changes[name] { apply(&model, recorded) }
        }
        return model
    }
}
