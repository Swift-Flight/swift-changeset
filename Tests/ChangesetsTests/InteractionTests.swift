import Testing
import Changesets

/// Pairwise feature interactions. Every feature here is covered alone
/// elsewhere; these are the seams between two of them, which is where the
/// contracts of each get a chance to disagree.

@Suite("merge × nesting")
struct MergeNestingTests {

    private func line(_ sku: String) -> Changeset<LineItem> {
        Changeset(LineItem.self).change(\.sku, sku)
    }

    private func skus(_ changeset: Changeset<Order>, _ association: String) throws -> [String] {
        try changeset.nested(association).map {
            try $0.validatedChanges().changedFields["sku"] as? String ?? "?"
        }
    }

    @Test("merging replaces a whole association — a superseded list leaves no tail behind")
    func replacesTheAssociation() throws {
        let first = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("lineItems", [line("A"), line("B"), line("C")])
        let second = Changeset(Order.self)
            .nest("lineItems", [line("Z")])

        let merged = first.merge(second)
        #expect(try skus(merged, "lineItems") == ["Z"])
        #expect(merged.nested("lineItems").map(\.index) == [0])
    }

    @Test("a longer incoming list replaces a shorter one, indices intact")
    func replacesWithLonger() throws {
        let first = Changeset(Order.self).nest("lineItems", [line("A")])
        let second = Changeset(Order.self).nest("lineItems", [line("X"), line("Y")])

        let merged = first.merge(second)
        #expect(try skus(merged, "lineItems") == ["X", "Y"])
        #expect(merged.nested("lineItems").map(\.path) == ["lineItems[0]", "lineItems[1]"])
    }

    @Test("associations the incoming side says nothing about survive untouched")
    func untouchedAssociationsSurvive() throws {
        let first = Changeset(Order.self)
            .nest("lineItems", [line("A")])
            .nest("address", Changeset(ShippingAddress.self).change(\.zip, "97201"))
        let second = Changeset(Order.self).nest("lineItems", [line("Z")])

        let merged = first.merge(second)
        #expect(try skus(merged, "lineItems") == ["Z"])
        #expect(merged.nested("address").count == 1)
        #expect(merged.nested("address").first?.path == "address")
    }

    @Test("a to-one child replaces a to-many under the same association, and vice versa")
    func toOneAndToManyDoNotCoexist() {
        let toMany = Changeset(Order.self)
            .nest("address", [Changeset(ShippingAddress.self).change(\.zip, "97201")])
        let toOne = Changeset(Order.self)
            .nest("address", Changeset(ShippingAddress.self).change(\.zip, "10001"))

        let oneWins = toMany.merge(toOne)
        #expect(oneWins.nested("address").count == 1)
        #expect(oneWins.nested("address").first?.index == nil)
        #expect(oneWins.nested("address").map(\.path) == ["address"])

        let manyWins = toOne.merge(toMany)
        #expect(manyWins.nested("address").count == 1)
        #expect(manyWins.nested("address").first?.index == 0)
        #expect(manyWins.nested("address").map(\.path) == ["address[0]"])
    }

    @Test("errors after a merge are pathed against the surviving children only")
    func errorPathsFollowTheSurvivors() {
        let rejected = Changeset(LineItem.self).change(\.sku, "A").addError(\.sku, "is discontinued")
        let first = Changeset(Order.self).nest("lineItems", [line("ok"), rejected])
        let second = Changeset(Order.self).nest("lineItems", [line("fresh")])

        let merged = first.merge(second)
        #expect(merged.isValid, "the superseded child's error went with it")
        #expect(merged.messagesByField.isEmpty)

        let stillFailing = second.merge(first)
        #expect(stillFailing.messagesByField["lineItems[1].sku"] == ["is discontinued"])
    }

    @Test("merging a changeset with no children leaves the children alone")
    func mergingChildlessKeepsChildren() throws {
        let first = Changeset(Order.self).nest("lineItems", [line("A")])
        let merged = first.merge(Changeset(Order.self).change(\.customerID, 9))

        #expect(try skus(merged, "lineItems") == ["A"])
        #expect(merged.changes["customer_id"] as? Int == 9)
    }
}

@Suite("optimistic lock × later edits to the lock column")
struct LockEditingTests {

    @Test("deleting the version change clears the lock — no guard the write never advances")
    func deleteChangeClearsTheLock() throws {
        let changeset = Changeset(original: Order.placed)     // version 4
            .change(\.note, "ring the bell")
            .optimisticLock(\.version)
            .deleteChange(\.version)

        #expect(changeset.lock == nil)
        let validated = try changeset.validatedChanges()
        #expect(validated.changedFields["version"] == nil)
        #expect(validated.identity?["version"] == nil, "an unmoved version must not guard the write")
        #expect(validated.identity?["id"] as? Int == 7)
        #expect(validated.lock == nil)
    }

    @Test("reverting the version to the original clears the lock too")
    func revertingClearsTheLock() throws {
        let changeset = Changeset(original: Order.placed)
            .optimisticLock(\.version)
            .change(\.version, 4)                             // back to the original

        #expect(changeset.lock == nil)
        #expect(!changeset.hasChanges)
        #expect(try changeset.validatedChanges().identity?["version"] == nil)
    }

    @Test("changing the version by hand after locking re-points the lock at the real write")
    func handEditRepointsTheLock() throws {
        let changeset = Changeset(original: Order.placed)
            .optimisticLock(\.version)
            .change(\.version, 99)

        #expect(changeset.lock?.next as? Int == 99)
        #expect(changeset.lock?.expected as? Int == 4)

        let validated = try changeset.validatedChanges()
        #expect(validated.changedFields["version"] as? Int == 99)
        #expect(validated.identity?["version"] as? Int == 4)
        #expect(validated.lock?.next as? Int == 99, "the lock must describe the write performed")
    }

    @Test("forceChange and updateChange re-point the lock the same way")
    func forceAndUpdateRepointTheLock() {
        let forced = Changeset(original: Order.placed)
            .optimisticLock(\.version)
            .forceChange(\.version, 42)
        #expect(forced.lock?.next as? Int == 42)
        #expect(forced.lock?.expected as? Int == 4)

        let updated = Changeset(original: Order.placed)
            .optimisticLock(\.version)
            .updateChange(\.version) { $0 * 10 }              // the bumped 5
        #expect(updated.lock?.next as? Int == 50)
        #expect(updated.changes["version"] as? Int == 50)
    }

    @Test("editing another column leaves the lock exactly as it was")
    func unrelatedEditsLeaveTheLockAlone() throws {
        let changeset = Changeset(original: Order.placed)
            .optimisticLock(\.version)
            .change(\.note, "leave in the porch")
            .deleteChange(\.note)

        #expect(changeset.lock?.next as? Int == 5)
        #expect(try changeset.validatedChanges().identity?["version"] as? Int == 4)
    }

    @Test("merge carries a lock and re-points it at the merged value")
    func mergeReconcilesTheLock() throws {
        let locked = Changeset(original: Order.placed).optimisticLock(\.version)
        let overriding = Changeset(original: Order.placed).forceChange(\.version, 77)

        let merged = locked.merge(overriding)
        #expect(merged.lock?.expected as? Int == 4)
        #expect(merged.lock?.next as? Int == 77)
        #expect(try merged.validatedChanges().changedFields["version"] as? Int == 77)

        // The other direction: the incoming lock wins, and still describes
        // the value that survives the change merge.
        let lockWins = overriding.merge(locked)
        #expect(lockWins.lock?.next as? Int == 5)
        #expect(try lockWins.validatedChanges().changedFields["version"] as? Int == 5)
    }
}

@Suite("validateChanged — the insert-side required field")
struct ValidateChangedTests {

    @Test("an insert missing a non-optional field fails, where validateRequired cannot reach")
    func insertMissingFieldFails() {
        let changeset = Changeset(User.self)
            .change(\.email, "grace@example.com")
            .validateChanged(\.displayName)

        #expect(!changeset.isValid)
        #expect(changeset.messagesByField["display_name"] == ["is required"])
    }

    @Test("an insert that names the field passes")
    func insertWithFieldPasses() {
        let changeset = Changeset(User.self)
            .change(\.displayName, "Grace")
            .validateChanged(\.displayName)

        #expect(changeset.isValid)
    }

    @Test("an update passes untouched — the original already supplies the value")
    func updatePasses() {
        #expect(Changeset(original: User.ada).validateChanged(\.displayName).isValid)
    }

    @Test("a custom message replaces the default")
    func customMessage() {
        let changeset = Changeset(User.self)
            .validateChanged(\.displayName, message: "must be supplied when creating an account")
        #expect(changeset.messagesByField["display_name"]
            == ["must be supplied when creating an account"])
    }

    @Test("on an optional field a NULL write counts as present, unlike validateRequired")
    func nullCountsAsPresent() {
        let changeset = Changeset(User.self).change(\.email, nil)
        #expect(changeset.validateChanged(\.email).isValid)
        #expect(!changeset.validateRequired(\.email).isValid)
    }

    @Test("errors accumulate with the rest, in order")
    func accumulates() {
        let changeset = Changeset(User.self)
            .change(\.age, 7)
            .validateChanged(\.displayName)
            .validate(\.age, .range(13...))

        #expect(changeset.errors.map(\.field) == ["display_name", "age"])
    }
}

@Suite("updateChange(orError:) — normalization that can reject")
struct FallibleUpdateChangeTests {

    @Test("a transform returning nil records an error and keeps the value as submitted")
    func failureRecordsAnError() {
        let changeset = Changeset(User.self)
            .change(\.displayName, "  ")
            .updateChange(\.displayName, orError: "cannot be blank") { name in
                name.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : name.trimmingCharacters(in: .whitespaces)
            }

        #expect(!changeset.isValid)
        #expect(changeset.messagesByField["display_name"] == ["cannot be blank"])
        #expect(changeset.getChange(\.displayName) == "  ", "the submitted value survives for re-rendering")
    }

    @Test("a transform returning a value normalizes exactly like updateChange")
    func successNormalizes() {
        let changeset = Changeset(User.self)
            .change(\.displayName, " Ada ")
            .updateChange(\.displayName, orError: "cannot be blank") {
                $0.trimmingCharacters(in: .whitespaces)
            }

        #expect(changeset.isValid)
        #expect(changeset.getChange(\.displayName) == "Ada")
    }

    @Test("an untouched field is left alone and the transform never runs")
    func untouchedIsSkipped() {
        nonisolated(unsafe) var ran = false
        let changeset = Changeset(original: User.ada)
            .updateChange(\.age, orError: "is not a valid age") { value in
                ran = true
                return value
            }

        #expect(!ran)
        #expect(changeset.isValid)
        #expect(!changeset.hasChanges)
    }

    @Test("the optional overload sees the wrapped value and re-wraps the result")
    func optionalOverload() {
        let ok = Changeset(User.self)
            .change(\.email, "ADA@EXAMPLE.COM")
            .updateChange(\.email, orError: "is not a valid email address") { $0.lowercased() }
        #expect(ok.getChange(\.email) == "ada@example.com")

        let rejected = Changeset(User.self)
            .change(\.email, "nope")
            .updateChange(\.email, orError: "is not a valid email address") {
                $0.contains("@") ? $0 : nil
            }
        #expect(rejected.messagesByField["email"] == ["is not a valid email address"])
    }
}

@Suite("the handoff addresses its own table")
struct HandoffTableNameTests {

    @Test("validatedChanges carries the model's table name")
    func carriesTableName() throws {
        #expect(try Changeset(original: User.ada).change(\.age, 37)
            .validatedChanges().tableName == "users")
        #expect(try Changeset(Membership.self).change(\.role, "owner")
            .validatedChanges().tableName == "membership", "the defaulted name")
    }

    @Test("a parent and its children name their tables the same way")
    func parentAndChildrenAgree() throws {
        let order = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("lineItems", [Changeset(LineItem.self).change(\.sku, "A")])

        #expect(try order.validatedChanges().tableName == "orders")
        let child = try #require(order.nested("lineItems").first)
        #expect(child.tableName == "line_items")
        #expect(try child.validatedChanges().tableName == child.tableName)
    }
}
