import Foundation
import Testing
import Changesets

/// The changeset core (design §3): dirty tracking, effective values, and the
/// validated handoff.
@Suite("Changeset — dirty tracking (§1, §6)")
struct ChangesetDirtyTrackingTests {

    @Test("an insert changeset records every change")
    func insertRecordsAll() {
        let changeset = Changeset(User.self)
            .change(\.email, "grace@example.com")
            .change(\.displayName, "Grace")
        #expect(changeset.hasChanges)
        #expect(Set(changeset.changes.keys) == ["email", "display_name"])
        #expect(changeset.original == nil)
    }

    @Test("a change equal to the original is not a change (§6: only if actually changed)")
    func equalValueIsClean() {
        let changeset = Changeset(original: User.ada)
            .change(\.email, User.ada.email)
            .change(\.displayName, "Ada")
        #expect(!changeset.hasChanges)
        #expect(changeset.changes.isEmpty)
    }

    @Test("a differing value is recorded under the column name, not the property name")
    func differingValueIsDirty() {
        let changeset = Changeset(original: User.ada)
            .change(\.displayName, "Ada Lovelace")
        #expect(changeset.changes.count == 1)
        #expect(changeset.changes["display_name"] as? String == "Ada Lovelace")
    }

    @Test("changing a field back to its original value removes the recorded change")
    func revertRemovesChange() {
        let changeset = Changeset(original: User.ada)
            .change(\.age, 37)
            .change(\.age, 36)
        #expect(!changeset.hasChanges)
    }

    @Test("repeated changes to one field: last one wins")
    func lastChangeWins() {
        let changeset = Changeset(original: User.ada)
            .change(\.age, 37)
            .change(\.age, 38)
        #expect(changeset.changes["age"] as? Int == 38)
        #expect(changeset.changes.count == 1)
    }

    @Test("setting an optional field to nil is a real change (set NULL), not a removal")
    func nilIsARealChange() {
        let changeset = Changeset(original: User.ada)
            .change(\.email, nil)
        #expect(changeset.hasChanges)
        #expect(changeset.changes.keys.contains("email"))
        #expect(changeset.value(\.email) == nil)
    }

    @Test("non-Equatable values are always dirty — no comparison is possible")
    func nonEquatableAlwaysDirty() {
        let document = Document(id: 1, payload: Payload(lines: ["a"]))
        let changeset = Changeset(original: document)
            .change(\.payload, Payload(lines: ["a"]))  // same content, unknowable
        #expect(changeset.hasChanges)
    }

    @Test("value(_:) reads change over original over nothing")
    func effectiveValues() {
        let insert = Changeset(User.self)
        #expect(insert.value(\.displayName) == nil, "untouched insert field: nil")

        let update = Changeset(original: User.ada)
        #expect(update.value(\.displayName) == "Ada", "no change: the original's value")
        #expect(update.value(\.email) == "ada@example.com", "optional overload flattens")

        let changed = update.change(\.displayName, "Countess")
        #expect(changed.value(\.displayName) == "Countess", "a change wins")
    }
}

@Suite("Changeset — validation (§3)")
struct ChangesetValidationTests {

    @Test("validateRequired fails an untouched optional on insert")
    func requiredOnInsert() {
        let changeset = Changeset(User.self).validateRequired(\.email)
        #expect(!changeset.isValid)
        #expect(changeset.errors == [ChangesetError(field: "email", message: "is required")])
    }

    @Test("validateRequired passes via a change or via the original")
    func requiredSatisfied() {
        #expect(Changeset(User.self).change(\.email, "g@x.dev").validateRequired(\.email).isValid)
        #expect(Changeset(original: User.ada).validateRequired(\.email).isValid)
    }

    @Test("validateRequired fails an explicit set-to-nil")
    func requiredRejectsNilChange() {
        let changeset = Changeset(original: User.ada)
            .change(\.email, nil)
            .validateRequired(\.email)
        #expect(changeset.errors == [ChangesetError(field: "email", message: "is required")])
    }

    @Test("field rules validate recorded changes only — unchanged data is not re-litigated")
    func rulesSkipUnchangedFields() {
        var stored = User.ada
        stored.email = "not-an-email"   // presumptively valid when written; not this changeset's business
        let changeset = Changeset(original: stored)
            .change(\.age, 37)
            .validate(\.email, .email)
        #expect(changeset.isValid)
    }

    @Test("a failing rule lands on the column name with the rule's message")
    func ruleFailureShape() {
        let changeset = Changeset(original: User.ada)
            .change(\.displayName, "")
            .validate(\.displayName, .length(1...80))
        #expect(changeset.errors == [
            ChangesetError(field: "display_name", message: "length must be within 1...80")
        ])
    }

    @Test("optional-field rules see the wrapped value and skip a nil change")
    func optionalFieldRules() {
        let invalid = Changeset(original: User.ada)
            .change(\.email, "not-an-email")
            .validate(\.email, .email)
        #expect(invalid.errors.map(\.field) == ["email"])

        let nilChange = Changeset(original: User.ada)
            .change(\.email, nil)
            .validate(\.email, .email)
        #expect(nilChange.isValid, "nil-ness is validateRequired's job, not a format rule's")
    }

    @Test("errors accumulate across the whole chain — never fail-fast (§1)")
    func errorsAccumulate() {
        let changeset = Changeset(User.self)
            .change(\.email, "nope")
            .change(\.displayName, "")
            .change(\.age, 7)
            .validate(\.email, .email)
            .validate(\.displayName, .length(1...80))
            .validate(\.age, .range(18...120))
            .validateRequired(\.id)
        #expect(changeset.errors.count == 4)
        #expect(changeset.errors.map(\.field) == ["email", "display_name", "age", "id"])
        #expect(!changeset.isValid)
    }

    @Test("cross-field ordered: fails on the later field, naming the earlier column")
    func orderedFails() {
        let noon = Date(timeIntervalSince1970: 1_752_580_800)
        let changeset = Changeset(Event.self)
            .change(\.title, "Launch")
            .change(\.startsAt, noon)
            .change(\.endsAt, noon.addingTimeInterval(-3600))
            .validate(.ordered(\.startsAt, before: \.endsAt))
        #expect(changeset.errors == [
            ChangesetError(field: "ends_at", message: "must be after starts_at")
        ])
    }

    @Test("cross-field ordered: passes when ordered, skips when a side is missing")
    func orderedPassesAndSkips() {
        let noon = Date(timeIntervalSince1970: 1_752_580_800)
        let ordered = Changeset(Event.self)
            .change(\.startsAt, noon)
            .change(\.endsAt, noon.addingTimeInterval(3600))
            .validate(.ordered(\.startsAt, before: \.endsAt))
        #expect(ordered.isValid)

        let halfSet = Changeset(Event.self)
            .change(\.startsAt, noon)
            .validate(.ordered(\.startsAt, before: \.endsAt))
        #expect(halfSet.isValid, "missing side: skip; requiredness is validateRequired's job")
    }

    @Test("cross-field rules run on effective state: original + changes together")
    func crossFieldSeesEffectiveState() {
        let noon = Date(timeIntervalSince1970: 1_752_580_800)
        let stored = Event(id: 7, title: "Launch", startsAt: noon, endsAt: noon.addingTimeInterval(3600))
        // Only the END moves — before the start, which comes from the original.
        let changeset = Changeset(original: stored)
            .change(\.endsAt, noon.addingTimeInterval(-60))
            .validate(.ordered(\.startsAt, before: \.endsAt))
        #expect(changeset.errors.map(\.field) == ["ends_at"])
    }

    @Test("cross-field custom: reads the changeset, error lands on the chosen field")
    func crossFieldCustom() {
        let changeset = Changeset(original: User.ada)
            .change(\.displayName, "A")
            .change(\.age, 17)
            .validate(.custom(on: \.age, message: "minors need a guardian account") { cs in
                (cs.value(\.age) ?? 0) >= 18
            })
        #expect(changeset.errors == [
            ChangesetError(field: "age", message: "minors need a guardian account")
        ])
    }
}

@Suite("Changeset — the driver handoff (§3, §5)")
struct ValidatedChangesTests {

    @Test("an update hands off only dirty fields, with primary-key identity")
    func updateHandoff() throws {
        let validated = try Changeset(original: User.ada)
            .change(\.email, "ada@lovelace.dev")
            .change(\.age, 36)              // equal → clean → absent below
            .validatedChanges()
        #expect(validated.changedFields.count == 1)
        #expect(validated.changedFields["email"] as? String == "ada@lovelace.dev")
        let identity = try #require(validated.identity)
        #expect(identity.count == 1)
        #expect(identity["id"] as? Int == 1)
    }

    @Test("an insert hands off nil identity — how a driver knows it's an INSERT")
    func insertHandoff() throws {
        let validated = try Changeset(User.self)
            .change(\.displayName, "Grace")
            .validatedChanges()
        #expect(validated.identity == nil)
        #expect(validated.changedFields["display_name"] as? String == "Grace")
    }

    @Test("a composite primary key lands whole in identity")
    func compositeIdentity() throws {
        let membership = Membership(userID: 3, teamID: 9, role: "member")
        let validated = try Changeset(original: membership)
            .change(\.role, "admin")
            .validatedChanges()
        let identity = try #require(validated.identity)
        #expect(identity["user_id"] as? Int == 3)
        #expect(identity["team_id"] as? Int == 9)
    }

    @Test("an invalid changeset can never reach a driver — validatedChanges throws everything")
    func invalidThrows() {
        let changeset = Changeset(User.self)
            .change(\.email, "nope")
            .validate(\.email, .email)
            .validateRequired(\.id)
        #expect(throws: ChangesetValidationError(errors: changeset.errors)) {
            _ = try changeset.validatedChanges()
        }
        #expect(changeset.errors.count == 2, "the thrown error carries every accumulated failure")
    }

    @Test("a clean update hands off empty changedFields — the no-op is the driver's to skip")
    func cleanUpdateHandoff() throws {
        let validated = try Changeset(original: User.ada).validatedChanges()
        #expect(validated.changedFields.isEmpty)
        #expect(validated.identity != nil)
    }
}

@Suite("TableModel metadata")
struct TableModelTests {

    @Test("tableName defaults to the lowercased type name; explicit wins")
    func tableNames() {
        #expect(Membership.tableName == "membership")
        #expect(User.tableName == "users")
    }

    @Test("primaryKey defaults to the columns flagged primaryKey: true")
    func primaryKeyDefault() {
        #expect(User.primaryKey.map(\.name) == ["id"])
        #expect(Membership.primaryKey.map(\.name) == ["user_id", "team_id"])
        #expect(User.columns.map(\.isPrimaryKey) == [true, false, false, false])
    }
}
