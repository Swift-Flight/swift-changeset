/// A single-field semantic validation: the part of the job Swift's types
/// genuinely cannot do at compile time.
///
/// Rules are small composable values. A rule runs against a field's
/// *recorded change* — see `validate(_:_:)` — and answers
/// with `nil` (pass) or a message (fail).
///
/// ```swift
/// changeset
///     .validate(\.email, .email)
///     .validate(\.displayName, .length(1...80))
///     .validate(\.age, .range(13...))
///     .validate(\.role, .oneOf(["member", "admin"]))
/// ```
///
/// ## Writing your own
///
/// Rules are open for authorship — build a catalog as static extensions,
/// exactly like the built-ins:
///
/// ```swift
/// extension ValidationRule where V == String {
///     static var slug: ValidationRule {
///         .matches(#"^[a-z0-9-]+$"#, message: "may only contain lowercase letters, numbers and hyphens")
///     }
/// }
///
/// changeset.validate(\.handle, .slug)
/// ```
///
/// ## Topics
///
/// ### Text
/// - ``matches(_:message:)``
/// - ``email``
/// - ``length(_:message:)``
///
/// ### Values
/// - ``range(_:message:)``
/// - ``oneOf(_:message:)``
/// - ``excluding(_:message:)``
/// - ``accepted(message:)``
///
/// ### Collections
/// - ``subset(of:message:)``
///
/// ### Building your own
/// - ``init(_:)``
/// - ``custom(message:_:)``
public struct ValidationRule<V>: Sendable {

    /// `nil` = pass; a message = fail.
    ///
    /// Messages are field-relative fragments — "has invalid format" — so
    /// they read correctly rendered next to the column name.
    internal let run: @Sendable (V) -> String?

    /// Builds a rule from a closure returning `nil` to pass or a message to
    /// fail.
    ///
    /// ```swift
    /// let notReserved = ValidationRule<String> { name in
    ///     reserved.contains(name) ? "is reserved" : nil
    /// }
    /// ```
    public init(_ run: @escaping @Sendable (V) -> String?) {
        self.run = run
    }

    /// Builds a rule from a predicate and a fixed message.
    ///
    /// The shorthand for the common case where the message does not depend
    /// on the value.
    ///
    /// ```swift
    /// .custom(message: "must be even") { $0.isMultiple(of: 2) }
    /// ```
    public static func custom(
        message: String, _ check: @escaping @Sendable (V) -> Bool
    ) -> ValidationRule {
        ValidationRule { check($0) ? nil : message }
    }
}

// MARK: - Text

extension ValidationRule where V == String {

    /// Passes when `pattern` matches anywhere in the value.
    ///
    /// Anchor with `^` and `$` for whole-value semantics — Swift's `Regex`
    /// is not multiline by default, so `$` means end of input and a newline
    /// cannot be used to smuggle a second line past the check.
    ///
    /// ```swift
    /// .matches(#"^\+?[0-9 ()-]{7,}$"#, message: "is not a valid phone number")
    /// ```
    ///
    /// The pattern is checked when the rule is built, so a malformed one
    /// fails at the point you wrote it rather than at the first value that
    /// happens to reach it.
    ///
    /// > Note: The expression is recompiled per evaluation. `Regex` compiles
    /// > its program lazily, which makes sharing a single instance across
    /// > concurrent validations a data race — correctness wins over reuse
    /// > here. For bulk validation of many thousands of rows, hoist the
    /// > match into a ``custom(message:_:)`` rule holding your own
    /// > synchronization.
    ///
    /// - Precondition: `pattern` must be a valid regular expression. An
    ///   invalid one is a programmer error and traps at construction.
    public static func matches(_ pattern: String, message: String? = nil) -> ValidationRule {
        guard (try? Regex(pattern)) != nil else {
            preconditionFailure("ValidationRule.matches: '\(pattern)' is not a valid regular expression.")
        }
        let failure = message ?? "has invalid format"
        return ValidationRule { value in
            guard let regex = try? Regex(pattern) else { return failure }
            return value.firstMatch(of: regex) != nil ? nil : failure
        }
    }

    /// A pragmatic email shape: `something@something.tld`, no whitespace.
    ///
    /// Deliberately not RFC 5322 — that grammar admits addresses no mail
    /// system accepts. Apps needing stricter rules compose ``matches(_:message:)``.
    ///
    /// ```swift
    /// changeset.validate(\.email, .email)
    /// ```
    public static var email: ValidationRule {
        .matches(#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, message: "is not a valid email address")
    }
}

// MARK: - Collections

extension ValidationRule where V: Collection & Sendable {

    /// Element count within `range`.
    ///
    /// `1...200`, `1...`, and `...80` all work. On `String` this counts
    /// grapheme clusters, which is what a user perceives as length — an
    /// emoji is one character, not four.
    ///
    /// ```swift
    /// .length(1...80)      // between 1 and 80
    /// .length(8...)        // at least 8
    /// .length(...500)      // at most 500
    /// ```
    public static func length<R: RangeExpression<Int> & Sendable>(
        _ range: R, message: String? = nil
    ) -> ValidationRule {
        ValidationRule { value in
            range.contains(value.count) ? nil : (message ?? "length must be \(describeRange(range))")
        }
    }
}

extension ValidationRule where V: Collection & Sendable, V.Element: Hashable & Sendable {

    /// Every element of the value must appear in `allowed`.
    ///
    /// The multi-select counterpart to ``oneOf(_:message:)`` — for a tags
    /// array, a permissions set, a list of selected options.
    ///
    /// ```swift
    /// changeset.validate(\.tags, .subset(of: ["swift", "server", "database"]))
    /// ```
    public static func subset(
        of allowed: some Sequence<V.Element> & Sendable, message: String? = nil
    ) -> ValidationRule {
        let permitted = Set(allowed)
        return ValidationRule { value in
            let extras = Set(value).subtracting(permitted)
            guard extras.isEmpty else {
                let listed = extras.map { String(describing: $0) }.sorted().joined(separator: ", ")
                return message ?? "contains values that are not allowed: \(listed)"
            }
            return nil
        }
    }
}

// MARK: - Values

extension ValidationRule where V: Comparable & Sendable {

    /// Value within `range`.
    ///
    /// `18...120`, `0...`, and `..<100` all work.
    ///
    /// ```swift
    /// .range(13...)        // at least 13
    /// .range(0..<100)      // less than 100
    /// ```
    public static func range<R: RangeExpression<V> & Sendable>(
        _ range: R, message: String? = nil
    ) -> ValidationRule {
        ValidationRule { value in
            range.contains(value) ? nil : (message ?? "must be \(describeRange(range))")
        }
    }
}

extension ValidationRule where V: Equatable & Sendable {

    /// Membership in a closed set.
    ///
    /// For enum-ish string columns, unit fields, status values.
    ///
    /// ```swift
    /// .oneOf(["draft", "published", "archived"])
    /// ```
    public static func oneOf(_ allowed: [V], message: String? = nil) -> ValidationRule {
        ValidationRule { value in
            allowed.contains(value)
                ? nil
                : (message ?? "must be one of: \(allowed.map { String(describing: $0) }.joined(separator: ", "))")
        }
    }

    /// Absence from a closed set — the inverse of ``oneOf(_:message:)``.
    ///
    /// For reserved words, blocked values, names an app has claimed.
    ///
    /// ```swift
    /// .excluding(["admin", "root", "system"], message: "is reserved")
    /// ```
    public static func excluding(_ disallowed: [V], message: String? = nil) -> ValidationRule {
        ValidationRule { value in
            disallowed.contains(value)
                ? (message ?? "is reserved")
                : nil
        }
    }
}

extension ValidationRule where V == Bool {

    /// Passes only when the value is `true`.
    ///
    /// The terms-of-service checkbox rule. Pair with
    /// ``Changeset/validateRequired(_:)`` when the field is optional and
    /// absence should also fail.
    ///
    /// ```swift
    /// changeset.validate(\.acceptedTerms, .accepted())
    /// ```
    public static func accepted(message: String? = nil) -> ValidationRule {
        ValidationRule { $0 ? nil : (message ?? "must be accepted") }
    }
}

/// Human phrasing for the built-in rules' default messages.
internal func describeRange<R: RangeExpression>(_ range: R) -> String {
    switch range {
    case let r as ClosedRange<R.Bound>:
        return "within \(r.lowerBound)...\(r.upperBound)"
    case let r as Range<R.Bound>:
        return "within \(r.lowerBound)..<\(r.upperBound)"
    case let r as PartialRangeFrom<R.Bound>:
        return "at least \(r.lowerBound)"
    case let r as PartialRangeThrough<R.Bound>:
        return "at most \(r.upperBound)"
    case let r as PartialRangeUpTo<R.Bound>:
        return "less than \(r.upperBound)"
    default:
        return String(describing: range)
    }
}
