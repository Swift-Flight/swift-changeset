import Foundation
import Testing
import Changesets

/// Reading a changeset: effective value vs. recorded change vs. original.
@Suite("Introspection — value, getChange, originalValue, changed")
struct IntrospectionTests {

    @Test("getChange answers what the write sets; value answers what the row becomes")
    func changeVersusEffective() {
        let changeset = Changeset(original: User.ada).change(\.age, 37)
        #expect(changeset.getChange(\.age) == 37)
        #expect(changeset.value(\.age) == 37)
        // Untouched: no change, but the effective value still resolves.
        #expect(changeset.getChange(\.displayName) == nil)
        #expect(changeset.value(\.displayName) == "Ada")
    }

    @Test("originalValue always reports the pre-change value")
    func originalIsPreserved() {
        let changeset = Changeset(original: User.ada).change(\.displayName, "Ada Lovelace")
        #expect(changeset.originalValue(\.displayName) == "Ada")
        #expect(changeset.value(\.displayName) == "Ada Lovelace")
    }

    @Test("originalValue is nil on an insert changeset")
    func originalIsNilForInsert() {
        let changeset = Changeset(User.self).change(\.displayName, "Grace")
        #expect(changeset.originalValue(\.displayName) == nil)
    }

    @Test("setting an already-nil field to nil is not a change — dirty tracking holds for NULL too")
    func nilToNilIsClean() {
        let anonymous = User(id: 2, email: nil, displayName: "Anon", age: 30)
        let changeset = Changeset(original: anonymous).change(\.email, nil)
        #expect(!changeset.changed(\.email))
        #expect(!changeset.hasChanges)
    }

    @Test("changed distinguishes a NULL write from an untouched field, where value cannot")
    func changedDisambiguatesNil() {
        let cleared = Changeset(original: User.ada).change(\.email, nil)
        let untouched = Changeset(original: User.ada).change(\.age, 37)

        // Both report nil for email through the effective-value reader...
        #expect(cleared.value(\.email) == nil)
        #expect(untouched.value(\.email) == "ada@example.com")

        // ...and only `changed` reports that one of them is a write.
        #expect(cleared.changed(\.email))
        #expect(!untouched.changed(\.email))
    }

    @Test("clearing a set field is a change; value alone cannot tell you that")
    func clearingIsAChange() {
        let cleared = Changeset(original: User.ada).change(\.email, nil)
        #expect(cleared.changed(\.email))
        #expect(cleared.value(\.email) == nil)
        #expect(cleared.originalValue(\.email) == "ada@example.com")
    }

    @Test("changedColumn is the string-keyed twin of changed")
    func changedColumnByName() {
        let changeset = Changeset(original: User.ada).change(\.displayName, "Ada L")
        #expect(changeset.changedColumn("display_name"))
        #expect(!changeset.changedColumn("age"))
    }
}

/// Materializing a changeset into the model it describes.
@Suite("applyChanges")
struct ApplyChangesTests {

    @Test("applyChanges returns the original with changes overlaid")
    func appliesOntoOriginal() throws {
        let applied = try #require(
            Changeset(original: User.ada)
                .change(\.age, 37)
                .change(\.displayName, "Ada Lovelace")
                .applyChanges()
        )
        #expect(applied.age == 37)
        #expect(applied.displayName == "Ada Lovelace")
        #expect(applied.id == 1)               // untouched fields survive
        #expect(applied.email == "ada@example.com")
    }

    @Test("applyChanges writes optional fields set to nil")
    func appliesNil() throws {
        let applied = try #require(
            Changeset(original: User.ada).change(\.email, nil).applyChanges()
        )
        #expect(applied.email == nil)
    }

    @Test("applyChanges returns nil for an insert changeset — no base to apply onto")
    func insertHasNoBase() {
        #expect(Changeset(User.self).change(\.displayName, "Grace").applyChanges() == nil)
    }

    @Test("applyChanges(to:) supplies the base, so inserts materialize too")
    func appliesOntoExplicitBase() {
        let draft = Changeset(Signup.self)
            .change(\.handle, "grace")
            .change(\.acceptedTerms, true)
            .applyChanges(to: Signup.blank)
        #expect(draft.handle == "grace")
        #expect(draft.acceptedTerms)
        #expect(draft.password == "")          // untouched default survives
    }

    @Test("applyChanges does not require validity — it is a preview, not a commit")
    func previewsInvalidState() throws {
        let changeset = Changeset(original: User.ada)
            .change(\.displayName, "")
            .validate(\.displayName, .length(1...80))
        #expect(!changeset.isValid)
        let preview = try #require(changeset.applyChanges())
        #expect(preview.displayName == "")
        // ...and the invalid changeset still cannot reach a driver.
        #expect(throws: ChangesetValidationError.self) { try changeset.validatedChanges() }
    }
}

/// Transforming and removing recorded changes.
@Suite("updateChange, forceChange, deleteChange")
struct ChangeManipulationTests {

    @Test("updateChange transforms a recorded change")
    func transformsRecorded() {
        let changeset = Changeset(User.self)
            .change(\.email, "  Ada@Example.COM  ")
            .updateChange(\.email) { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        #expect(changeset.getChange(\.email) == "ada@example.com")
    }

    @Test("updateChange is a no-op when the field was not changed")
    func skipsUnchanged() {
        var called = false
        let changeset = Changeset(original: User.ada)
            .updateChange(\.displayName) { called = true; return $0.uppercased() }
        #expect(!called)
        #expect(!changeset.hasChanges)
    }

    @Test("normalizing before validating means the rule sees the normalized value")
    func normalizeThenValidate() {
        let changeset = Changeset(User.self)
            .change(\.email, "  ADA@EXAMPLE.COM ")
            .updateChange(\.email) { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .validate(\.email, .email)
        #expect(changeset.isValid)
    }

    @Test("forceChange records a value even when it equals the original")
    func forceBypassesDirtyTracking() {
        let plain = Changeset(original: User.ada).change(\.age, 36)
        #expect(!plain.hasChanges)

        let forced = Changeset(original: User.ada).forceChange(\.age, 36)
        #expect(forced.hasChanges)
        #expect(forced.getChange(\.age) == 36)
    }

    @Test("deleteChange drops a recorded change and reverts to the original")
    func deleteReverts() {
        let changeset = Changeset(original: User.ada)
            .change(\.displayName, "Ada Lovelace")
            .deleteChange(\.displayName)
        #expect(!changeset.changed(\.displayName))
        #expect(changeset.value(\.displayName) == "Ada")
    }

    @Test("deleteChange also drops the applier, so applyChanges reflects the removal")
    func deleteAffectsApply() throws {
        let applied = try #require(
            Changeset(original: User.ada)
                .change(\.age, 99)
                .deleteChange(\.age)
                .applyChanges()
        )
        #expect(applied.age == 36)
    }

    @Test("reverting via change also drops the applier")
    func revertAffectsApply() throws {
        let applied = try #require(
            Changeset(original: User.ada)
                .change(\.age, 99)
                .change(\.age, 36)
                .applyChanges()
        )
        #expect(applied.age == 36)
    }
}

/// Errors that originate outside the changeset.
@Suite("addError")
struct AddErrorTests {

    @Test("addError attaches a failure to a field and invalidates the changeset")
    func attachesByKeyPath() {
        let changeset = Changeset(User.self)
            .change(\.email, "ada@example.com")
            .validate(\.email, .email)
        #expect(changeset.isValid)

        let rejected = changeset.addError(\.email, "has already been taken")
        #expect(!rejected.isValid)
        #expect(rejected.errors.map(\.description) == ["email: has already been taken"])
    }

    @Test("addError(column:) attaches by column name for store-reported failures")
    func attachesByColumnName() {
        let changeset = Changeset(User.self).addError(column: "email", "has already been taken")
        #expect(rejectedFields(changeset) == ["email"])
    }

    @Test("an added error blocks the driver handoff exactly as a rule failure does")
    func blocksHandoff() {
        let changeset = Changeset(User.self)
            .change(\.email, "ada@example.com")
            .addError(\.email, "has already been taken")
        #expect(throws: ChangesetValidationError.self) { try changeset.validatedChanges() }
    }

    @Test("added errors accumulate alongside rule failures, in order")
    func accumulatesInOrder() {
        let changeset = Changeset(User.self)
            .change(\.displayName, "")
            .validate(\.displayName, .length(1...80))
            .addError(\.email, "has already been taken")
        #expect(changeset.errors.map(\.field) == ["display_name", "email"])
    }

    private func rejectedFields<M>(_ changeset: Changeset<M>) -> [String] {
        changeset.errors.map(\.field)
    }
}

/// Combining independently-built changesets.
@Suite("merge")
struct MergeTests {

    @Test("merge layers changes, with the incoming side winning")
    func incomingWins() {
        let base = Changeset(original: User.ada).change(\.displayName, "Ada L").change(\.age, 37)
        let override = Changeset(original: User.ada).change(\.age, 40)
        let merged = base.merge(override)
        #expect(merged.getChange(\.displayName) == "Ada L")
        #expect(merged.getChange(\.age) == 40)
    }

    @Test("merge keeps errors from both sides")
    func keepsBothErrorSets() {
        let base = Changeset(User.self).addError(\.email, "first")
        let other = Changeset(User.self).addError(\.displayName, "second")
        #expect(base.merge(other).errors.map(\.message) == ["first", "second"])
    }

    @Test("merged changes apply correctly, so appliers merged too")
    func mergedAppliersWork() throws {
        let merged = Changeset(original: User.ada)
            .change(\.displayName, "Ada L")
            .merge(Changeset(original: User.ada).change(\.age, 40))
        let applied = try #require(merged.applyChanges())
        #expect(applied.displayName == "Ada L")
        #expect(applied.age == 40)
    }
}

/// The validators added for form parity.
@Suite("Validators — accepted, excluding, subset, confirms")
struct NewValidatorTests {

    @Test("accepted passes only on true")
    func acceptance() {
        let refused = Changeset(Signup.self)
            .change(\.acceptedTerms, false)
            .validate(\.acceptedTerms, .accepted())
        #expect(refused.errors.map(\.description) == ["accepted_terms: must be accepted"])

        let agreed = Changeset(Signup.self)
            .change(\.acceptedTerms, true)
            .validate(\.acceptedTerms, .accepted())
        #expect(agreed.isValid)
    }

    @Test("excluding rejects reserved values and passes everything else")
    func exclusion() {
        let reserved = Changeset(Signup.self)
            .change(\.handle, "admin")
            .validate(\.handle, .excluding(["admin", "root"]))
        #expect(reserved.errors.map(\.description) == ["handle: is reserved"])

        let fine = Changeset(Signup.self)
            .change(\.handle, "grace")
            .validate(\.handle, .excluding(["admin", "root"]))
        #expect(fine.isValid)
    }

    @Test("subset names the offending elements")
    func subsetReportsExtras() {
        let bad = Changeset(Signup.self)
            .change(\.tags, ["swift", "cobol", "fortran"])
            .validate(\.tags, .subset(of: ["swift", "server"]))
        #expect(bad.errors.count == 1)
        #expect(bad.errors[0].message.contains("cobol"))
        #expect(bad.errors[0].message.contains("fortran"))

        let good = Changeset(Signup.self)
            .change(\.tags, ["swift"])
            .validate(\.tags, .subset(of: ["swift", "server"]))
        #expect(good.isValid)
    }

    @Test("confirms fails on a mismatch and attaches the error to the confirmation field")
    func confirmationMismatch() {
        let mismatched = Changeset(Signup.self)
            .change(\.password, "hunter2")
            .change(\.passwordConfirmation, "hunter3")
            .validate(.confirms(\.password, matches: \.passwordConfirmation))
        #expect(mismatched.errors.map(\.description) == ["password_confirmation: does not match password"])
    }

    @Test("confirms passes when both sides agree")
    func confirmationMatch() {
        let matched = Changeset(Signup.self)
            .change(\.password, "hunter2")
            .change(\.passwordConfirmation, "hunter2")
            .validate(.confirms(\.password, matches: \.passwordConfirmation))
        #expect(matched.isValid)
    }

    @Test("confirms skips when neither side is present, so partial updates are not forced to resupply")
    func confirmationSkipsWhenAbsent() {
        let untouched = Changeset(original: Signup.blank)
            .change(\.handle, "grace")
            .validate(.confirms(\.password, matches: \.passwordConfirmation))
        #expect(untouched.isValid)
    }
}

/// Error rendering.
@Suite("Error rendering")
struct ErrorRenderingTests {

    @Test("messagesByField groups messages for a form or a JSON response")
    func groupsByField() {
        let changeset = Changeset(User.self)
            .change(\.displayName, "")
            .validate(\.displayName, .length(1...80))
            .addError(\.displayName, "is already taken")
            .addError(\.email, "is required")
        let grouped = changeset.messagesByField
        #expect(grouped["display_name"]?.count == 2)
        #expect(grouped["email"] == ["is required"])
    }

    @Test("the thrown error carries the same grouping")
    func thrownErrorGroups() {
        let changeset = Changeset(User.self).addError(\.email, "is required")
        do {
            _ = try changeset.validatedChanges()
            Issue.record("expected validatedChanges() to throw")
        } catch let error as ChangesetValidationError {
            #expect(error.messagesByField == ["email": ["is required"]])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("localizedDescription carries the real message, not a Foundation placeholder")
    func localizedDescriptionIsUseful() {
        let error = ChangesetValidationError(errors: [
            ChangesetError(field: "email", message: "is required")
        ])
        #expect(error.localizedDescription == "changeset is invalid: email: is required")
    }
}

/// The metadata guard that closes the duplicate-column corruption.
@Suite("Column metadata validation")
struct ColumnMetadataTests {

    @Test("well-formed metadata passes validation")
    func wellFormedPasses() {
        User.validateColumnMetadata()
        Signup.validateColumnMetadata()
        Membership.validateColumnMetadata()
        Event.validateColumnMetadata()
    }

    @Test("distinct column names survive a full round trip")
    func distinctNamesRoundTrip() throws {
        let validated = try Changeset(original: Membership(userID: 1, teamID: 2, role: "member"))
            .change(\.role, "admin")
            .validatedChanges()
        #expect(validated.changedFields.keys.sorted() == ["role"])
        #expect(validated.identity?.keys.sorted() == ["team_id", "user_id"])
    }
}
