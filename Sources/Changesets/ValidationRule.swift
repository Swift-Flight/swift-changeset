/// A single-field semantic validation (§3): the part of the job Swift's
/// types genuinely cannot do at compile time. Small composable values; the
/// catalog below covers the design doc's named rules plus the `.custom`
/// escape hatch, and every message can be overridden at the call site.
///
/// A rule runs against a field's *recorded change* (see
/// `Changeset.validate`) and answers with nil (pass) or a message (fail).
public struct ValidationRule<V>: Sendable {
    /// nil = pass; a message = fail. Messages are field-relative fragments
    /// ("has invalid format"), rendered next to the column name.
    internal let run: @Sendable (V) -> String?

    /// Rules are open for authorship: libraries and apps build their own
    /// catalogs as `static` extensions, exactly like the built-ins.
    public init(_ run: @escaping @Sendable (V) -> String?) {
        self.run = run
    }

    /// The escape hatch (§3): `check` returns whether the value passes.
    public static func custom(message: String, _ check: @escaping @Sendable (V) -> Bool) -> ValidationRule {
        ValidationRule { check($0) ? nil : message }
    }
}

extension ValidationRule where V == String {
    /// Passes when the pattern matches anywhere in the value — anchor with
    /// `^`/`$` for whole-value semantics. The pattern must be a valid
    /// regular expression; an invalid one is a programmer error and traps
    /// at first use, not a validation failure of the data.
    public static func matches(_ pattern: String, message: String? = nil) -> ValidationRule {
        ValidationRule { value in
            guard let regex = try? Regex(pattern) else {
                preconditionFailure("ValidationRule.matches: '\(pattern)' is not a valid regular expression.")
            }
            return value.firstMatch(of: regex) != nil ? nil : (message ?? "has invalid format")
        }
    }

    /// Pragmatic email shape: something@something.tld, no whitespace.
    /// Deliberately not RFC 5322 — that grammar admits addresses no mail
    /// system accepts; apps needing stricter rules compose `.matches`.
    public static var email: ValidationRule {
        .matches(#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, message: "is not a valid email address")
    }
}

extension ValidationRule where V: Collection & Sendable {
    /// Element count within `range` — `1...200`, `1...`, `...80` all work.
    /// On `String` this is `count` (grapheme clusters), matching what a
    /// user perceives as length.
    public static func length<R: RangeExpression<Int> & Sendable>(
        _ range: R, message: String? = nil
    ) -> ValidationRule {
        ValidationRule { value in
            range.contains(value.count) ? nil : (message ?? "length must be \(describeRange(range))")
        }
    }
}

extension ValidationRule where V: Comparable & Sendable {
    /// Value within `range` — `18...120`, `0...`, `..<100` all work.
    public static func range<R: RangeExpression<V> & Sendable>(
        _ range: R, message: String? = nil
    ) -> ValidationRule {
        ValidationRule { value in
            range.contains(value) ? nil : (message ?? "must be \(describeRange(range))")
        }
    }
}

extension ValidationRule where V: Equatable & Sendable {
    /// Membership in a closed set — enum-ish string columns, unit fields.
    public static func oneOf(_ allowed: [V], message: String? = nil) -> ValidationRule {
        ValidationRule { value in
            allowed.contains(value)
                ? nil
                : (message ?? "must be one of: \(allowed.map { String(describing: $0) }.joined(separator: ", "))")
        }
    }
}

/// A validation spanning multiple fields of one model (§3): "endDate after
/// startDate". Runs against the changeset's *effective* state (changes
/// overlaid on the original) and always runs — a consistency property must
/// hold over the whole row, whichever side of it changed. On insert
/// changesets untouched fields read as nil, and the built-ins skip when a
/// participating value is missing (nil-ness is `validateRequired`'s job).
public struct CrossFieldRule<Model: TableModel>: Sendable {
    /// The column the resulting error is attached to.
    internal let field: String
    internal let check: @Sendable (Changeset<Model>) -> String?

    /// The escape hatch: `check` reads effective values off the changeset
    /// (`changeset.value(\.someField)`) and returns whether the rule holds.
    /// The error lands on `field`.
    public static func custom<V>(
        on field: KeyPath<Model, V>,
        message: String,
        _ check: @escaping @Sendable (Changeset<Model>) -> Bool
    ) -> CrossFieldRule {
        CrossFieldRule(field: Model.column(for: field).name) { check($0) ? nil : message }
    }

    /// `earlier < later`, the canonical cross-field shape (date ranges).
    /// Skips when either side is missing; the error lands on `later`.
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

    /// Optional-field overload of `ordered` — a nil on either side skips.
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
}

/// Human phrasing for the built-in rules' default messages: "within 1...200",
/// "at least 1", "at most 80".
private func describeRange<R: RangeExpression>(_ range: R) -> String {
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
