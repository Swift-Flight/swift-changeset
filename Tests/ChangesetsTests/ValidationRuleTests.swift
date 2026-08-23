import Testing
import Changesets

/// The rule catalog (§3: "their exact catalog is an implementation detail;
/// the shape above is the contract"). Exercised through `Changeset.validate`
/// on insert changesets — the same path production code takes.
@Suite("ValidationRule catalog")
struct ValidationRuleTests {

    private func errors<V: Sendable & Equatable>(
        _ value: V, _ keyPath: WritableKeyPath<User, V> & Sendable, _ rule: ValidationRule<V>
    ) -> [ChangesetError] {
        Changeset(User.self).change(keyPath, value).validate(keyPath, rule).errors
    }

    @Test("matches: anywhere-in-value semantics; anchoring is the pattern's job")
    func matches() {
        #expect(errors("Ada Lovelace", \.displayName, .matches("Love")).isEmpty)
        #expect(errors("Ada", \.displayName, .matches("^[a-z]+$")).map(\.message) == ["has invalid format"])
        #expect(errors("Ada", \.displayName, .matches("^[a-z]+$", message: "lowercase only")).map(\.message) == ["lowercase only"])
    }

    @Test("email: accepts the plausible, rejects the malformed")
    func email() {
        let valid = ["ada@example.com", "a.b+tag@sub.domain.dev"]
        for address in valid {
            let changeset = Changeset(User.self).change(\.email, address).validate(\.email, .email)
            #expect(changeset.isValid, "expected '\(address)' to pass")
        }
        let invalid = ["nope", "no@tld", "spa ce@x.dev", "@x.dev", "a@.com "]
        for address in invalid {
            let changeset = Changeset(User.self).change(\.email, address).validate(\.email, .email)
            #expect(!changeset.isValid, "expected '\(address)' to fail")
        }
    }

    @Test("length: closed, from, and through ranges with readable defaults")
    func length() {
        #expect(errors("Ada", \.displayName, .length(1...80)).isEmpty)
        #expect(errors("", \.displayName, .length(1...80)).map(\.message) == ["length must be within 1...80"])
        #expect(errors("", \.displayName, .length(1...)).map(\.message) == ["length must be at least 1"])
        #expect(errors("Adaa", \.displayName, .length(...3)).map(\.message) == ["length must be at most 3"])
    }

    @Test("range: comparable bounds, half-open supported")
    func range() {
        #expect(errors(36, \.age, .range(18...120)).isEmpty)
        #expect(errors(7, \.age, .range(18...120)).map(\.message) == ["must be within 18...120"])
        #expect(errors(100, \.age, .range(0..<100)).map(\.message) == ["must be within 0..<100"])
        #expect(errors(17, \.age, .range(18..., message: "adults only")).map(\.message) == ["adults only"])
    }

    @Test("oneOf: membership in a closed set")
    func oneOf() {
        #expect(errors("Ada", \.displayName, .oneOf(["Ada", "Grace"])).isEmpty)
        #expect(errors("Linus", \.displayName, .oneOf(["Ada", "Grace"])).map(\.message)
            == ["must be one of: Ada, Grace"])
    }

    @Test("custom: the escape hatch")
    func custom() {
        let even = ValidationRule<Int>.custom(message: "must be even") { $0.isMultiple(of: 2) }
        #expect(errors(36, \.age, even).isEmpty)
        #expect(errors(37, \.age, even).map(\.message) == ["must be even"])
    }

    @Test("rules are authorable outside the catalog via the public initializer")
    func authorship() {
        let noShouting = ValidationRule<String> { value in
            value == value.uppercased() && value.count > 3 ? "no shouting" : nil
        }
        #expect(errors("ADA!", \.displayName, noShouting).map(\.message) == ["no shouting"])
        #expect(errors("Ada", \.displayName, noShouting).isEmpty)
    }

    @Test("error rendering: 'field: message'")
    func errorDescription() {
        let error = ChangesetError(field: "email", message: "is required")
        #expect(error.description == "email: is required")
        let thrown = ChangesetValidationError(errors: [error])
        #expect(thrown.description.contains("email: is required"))
    }
}
