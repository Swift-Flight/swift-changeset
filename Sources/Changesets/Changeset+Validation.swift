extension Changeset {

    // MARK: - Validating

    /// Fails unless the *effective* value of `field` is non-`nil`.
    ///
    /// Only optional fields can be required — a non-optional field is
    /// guaranteed present by construction, and referencing one here is a
    /// compile error. That is the type system keeping its half of the job.
    ///
    /// ```swift
    /// Changeset(User.self)
    ///     .validateRequired(\.email)      // email is String?
    ///     .errors                          // [email: is required]
    /// ```
    public consuming func validateRequired<V>(_ field: WritableKeyPath<Model, V?>) -> Changeset {
        let name = Model.column(for: field).name
        if value(field) == nil {
            return appending(ChangesetError(field: name, message: "is required"))
        }
        return self
    }

    /// Fails when `field` carries no value into the write and there is no
    /// original to supply one.
    ///
    /// The insert-side companion to ``validateRequired(_:)``. A
    /// non-optional field cannot be "missing" once a row exists, so
    /// `validateRequired` correctly refuses to accept one — but on an
    /// *insert* an untouched non-optional field is simply absent from the
    /// write, and the first thing to notice is the store's `NOT NULL`
    /// error. This rule says "this insert must name `display_name`" in the
    /// changeset, where the message can reach the form.
    ///
    /// ```swift
    /// Changeset(User.self)
    ///     .change(\.email, input.email)
    ///     .validateChanged(\.displayName)     // displayName is String
    ///     .errors                              // [display_name: is required]
    /// ```
    ///
    /// On an update changeset this always passes: the original already
    /// supplies the value, so an untouched field is not a missing one. Use
    /// it on optional fields too when the *write itself* must set them —
    /// there, a change to `nil` counts as present, which
    /// ``validateRequired(_:)`` would reject.
    public consuming func validateChanged<V>(
        _ field: KeyPath<Model, V>, message: String = "is required"
    ) -> Changeset {
        let name = Model.column(for: field).name
        if original == nil, changes[name] == nil {
            return appending(ChangesetError(field: name, message: message))
        }
        return self
    }

    /// Applies `rule` to `field`'s *recorded change*.
    ///
    /// A field with no recorded change is not validated. Unchanged data came
    /// from the store and was validated when it was written, so re-checking
    /// it would surface failures the user cannot act on — a row that
    /// predates a rule stays editable.
    ///
    /// ```swift
    /// Changeset(original: ada)
    ///     .change(\.displayName, "")
    ///     .validate(\.displayName, .length(1...80))
    ///     .errors                     // [display_name: length must be within 1...80]
    /// ```
    public consuming func validate<V>(
        _ field: WritableKeyPath<Model, V>, _ rule: ValidationRule<V>
    ) -> Changeset {
        applyRule(rule, toChangeAt: Model.column(for: field).name)
    }

    /// Optional-field overload of `validate(_:_:)`.
    ///
    /// The rule sees the wrapped value; a change that sets the field to
    /// `nil` is skipped. Pair with ``validateRequired(_:)`` when `nil` must
    /// be rejected.
    public consuming func validate<V>(
        _ field: WritableKeyPath<Model, V?>, _ rule: ValidationRule<V>
    ) -> Changeset {
        applyRule(rule, toChangeAt: Model.column(for: field).name)
    }

    /// Applies a cross-field rule against the changeset's *effective* state.
    ///
    /// Cross-field rules always run, whichever side of the property changed —
    /// a consistency property has to hold over the whole row.
    ///
    /// ```swift
    /// Changeset(original: event)
    ///     .change(\.endsAt, earlierThanStart)
    ///     .validate(.ordered(\.startsAt, before: \.endsAt))
    ///     .errors                     // [ends_at: must be after starts_at]
    /// ```
    public consuming func validate(_ rule: CrossFieldRule<Model>) -> Changeset {
        if let message = rule.check(self) {
            return appending(ChangesetError(field: rule.field, message: message))
        }
        return self
    }

    // MARK: - Adding errors directly

    /// Attaches an error to `field` without running a rule.
    ///
    /// This is how failures discovered *outside* the changeset rejoin it: a
    /// unique-constraint violation the database reported, a business rule
    /// that needed a service call, an authorization decision. Without it
    /// those failures end up in a parallel error channel and a form has two
    /// places to look.
    ///
    /// ```swift
    /// do {
    ///     try await repo.insert(changeset.validatedChanges())
    /// } catch let error as DatabaseError where error.isUniqueViolation {
    ///     return changeset.addError(\.email, "has already been taken")
    /// }
    /// ```
    ///
    /// The changeset becomes invalid, so ``validatedChanges()`` will refuse
    /// it exactly as if a rule had failed.
    public consuming func addError<V>(_ field: KeyPath<Model, V>, _ message: String) -> Changeset {
        appending(ChangesetError(field: Model.column(for: field).name, message: message))
    }

    /// Attaches an error to a column by name.
    ///
    /// The string-keyed form, for the case where the only thing you have is
    /// what the store told you — a constraint name mapped to a column, say.
    /// Prefer ``addError(_:_:)`` when you can name the field in code.
    ///
    /// ```swift
    /// changeset.addError(column: violation.columnName, "has already been taken")
    /// ```
    public consuming func addError(column name: String, _ message: String) -> Changeset {
        appending(ChangesetError(field: name, message: message))
    }

    // MARK: - The driver handoff

    /// The neutral handoff to a driver.
    ///
    /// Throws ``ChangesetValidationError`` when the changeset is invalid, so
    /// an invalid changeset can never reach a driver — the validation
    /// boundary is structural, not a convention.
    ///
    /// For update changesets, ``ValidatedChanges/identity`` is read from the
    /// original's primary-key columns — plus the version column, if
    /// ``optimisticLock(_:)`` was applied.
    ///
    /// ```swift
    /// let validated = try changeset.validatedChanges()
    /// validated.tableName          // "users"
    /// validated.changedFields      // ["age": 37]
    /// validated.identity           // ["id": 1]  — nil for an insert
    /// ```
    ///
    /// A changeset with nested children is invalid while any child is, so
    /// this refuses a parent whose children have not validated. The
    /// children's own handoffs come from ``validatedNestedChanges()``.
    ///
    /// - Throws: ``ChangesetValidationError`` carrying every accumulated
    ///   error, this changeset's and its children's.
    /// - Precondition: an update changeset's model must declare at least one
    ///   primary-key column; without one there is no way to address the row.
    public func validatedChanges() throws -> ValidatedChanges {
        guard isValid else {
            throw ChangesetValidationError(errors: errors)
        }
        let identity: [String: any Sendable]?
        if let original {
            let primaryKey = Model.primaryKey
            precondition(!primaryKey.isEmpty, """
            \(Model.self) has no primary-key column, so an update changeset cannot address its row. \
            Flag identity columns with TableColumn(_, _, primaryKey: true).
            """)
            var keys = Dictionary(uniqueKeysWithValues: primaryKey.map { ($0.name, $0.read(original)) })
            if let lock { keys[lock.field] = lock.expected }
            identity = keys
        } else {
            identity = nil
        }
        return ValidatedChanges(
            tableName: Model.tableName, changedFields: changes, identity: identity, lock: lock)
    }

    // MARK: - Internals

    private consuming func applyRule<V>(_ rule: ValidationRule<V>, toChangeAt name: String) -> Changeset {
        guard let recorded = changes[name], let value = recorded as? V else {
            return self
        }
        if let message = rule.run(value) {
            return appending(ChangesetError(field: name, message: message))
        }
        return self
    }
}
