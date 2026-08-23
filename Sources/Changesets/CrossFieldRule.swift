/// A validation spanning multiple fields of one model.
///
/// Cross-field rules run against the changeset's *effective* state — changes
/// overlaid on the original — and they always run, whichever side of the
/// property changed. A consistency property has to hold over the whole row,
/// so validating only the field the user touched would let the other side
/// break it.
///
/// ```swift
/// changeset
///     .validate(.ordered(\.startsAt, before: \.endsAt))
///     .validate(.confirms(\.password, matches: \.passwordConfirmation))
/// ```
///
/// On insert changesets untouched fields read as `nil`, and the built-ins
/// skip when a participating value is missing — absence is
/// ``Changeset/validateRequired(_:)``'s job, not a consistency rule's.
///
/// ## Topics
///
/// ### Built-in rules
///
/// ### Building your own
/// - ``custom(on:message:_:)``
public struct CrossFieldRule<Model: TableModel>: Sendable {

    /// The column the resulting error is attached to.
    internal let field: String
    internal let check: @Sendable (Changeset<Model>) -> String?

    /// A rule of your own: `check` reads effective values off the changeset
    /// and returns whether the property holds. The error lands on `field`.
    ///
    /// ```swift
    /// .custom(on: \.discountedPrice, message: "must be below the list price") { changeset in
    ///     guard let list = changeset.value(\.listPrice),
    ///           let discounted = changeset.value(\.discountedPrice)
    ///     else { return true }        // absence is validateRequired's job
    ///     return discounted < list
    /// }
    /// ```
    public static func custom<V>(
        on field: KeyPath<Model, V>,
        message: String,
        _ check: @escaping @Sendable (Changeset<Model>) -> Bool
    ) -> CrossFieldRule {
        CrossFieldRule(field: Model.column(for: field).name) { check($0) ? nil : message }
    }

    /// `earlier < later` — the canonical date-range shape.
    ///
    /// Skips when either side is missing. The error lands on `later`,
    /// because that is the field a user most recently touched when a range
    /// goes backwards.
    ///
    /// ```swift
    /// .ordered(\.startsAt, before: \.endsAt)
    /// // ends_at: must be after starts_at
    /// ```
    public static func ordered<V: Comparable & Sendable>(
        _ earlier: KeyPath<Model, V> & Sendable,
        before later: KeyPath<Model, V> & Sendable,
        message: String? = nil
    ) -> CrossFieldRule {
        let earlierName = Model.column(for: earlier).name
        let laterName = Model.column(for: later).name
        return CrossFieldRule(field: laterName) { changeset in
            guard let earlierValue = changeset.value(earlier),
                  let laterValue = changeset.value(later)
            else { return nil }
            return earlierValue < laterValue ? nil : (message ?? "must be after \(earlierName)")
        }
    }

    /// Optional-field overload of `ordered(_:before:message:)`.
    ///
    /// A `nil` on either side skips the rule.
    public static func ordered<V: Comparable & Sendable>(
        _ earlier: KeyPath<Model, V?> & Sendable,
        before later: KeyPath<Model, V?> & Sendable,
        message: String? = nil
    ) -> CrossFieldRule {
        let earlierName = Model.column(for: earlier).name
        let laterName = Model.column(for: later).name
        return CrossFieldRule(field: laterName) { changeset in
            guard let earlierValue = changeset.value(earlier),
                  let laterValue = changeset.value(later)
            else { return nil }
            return earlierValue < laterValue ? nil : (message ?? "must be after \(earlierName)")
        }
    }

    /// Two fields must hold equal values.
    ///
    /// The password-confirmation rule. The error lands on `confirmation`,
    /// which is the field the user should correct.
    ///
    /// ```swift
    /// Changeset(User.self)
    ///     .change(\.password, "hunter2")
    ///     .change(\.passwordConfirmation, "hunter3")
    ///     .validate(.confirms(\.password, matches: \.passwordConfirmation))
    ///     .errors      // [password_confirmation: does not match password]
    /// ```
    ///
    /// Skips when the confirmation field is absent, so a partial update that
    /// never touches either field is not forced to resupply both. Pair with
    /// ``Changeset/validateRequired(_:)`` when the confirmation is mandatory.
    public static func confirms<V: Equatable & Sendable>(
        _ field: KeyPath<Model, V> & Sendable,
        matches confirmation: KeyPath<Model, V> & Sendable,
        message: String? = nil
    ) -> CrossFieldRule {
        let fieldName = Model.column(for: field).name
        let confirmationName = Model.column(for: confirmation).name
        return CrossFieldRule(field: confirmationName) { changeset in
            guard let value = changeset.value(field),
                  let confirmed = changeset.value(confirmation)
            else { return nil }
            return value == confirmed ? nil : (message ?? "does not match \(fieldName)")
        }
    }

    /// Optional-field overload of `confirms(_:matches:message:)`.
    public static func confirms<V: Equatable & Sendable>(
        _ field: KeyPath<Model, V?> & Sendable,
        matches confirmation: KeyPath<Model, V?> & Sendable,
        message: String? = nil
    ) -> CrossFieldRule {
        let fieldName = Model.column(for: field).name
        let confirmationName = Model.column(for: confirmation).name
        return CrossFieldRule(field: confirmationName) { changeset in
            guard let value = changeset.value(field),
                  let confirmed = changeset.value(confirmation)
            else { return nil }
            return value == confirmed ? nil : (message ?? "does not match \(fieldName)")
        }
    }
}
