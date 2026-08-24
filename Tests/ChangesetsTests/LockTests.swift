import Foundation
import Testing
import Changesets

@Suite("Changeset — optimistic locking")
struct OptimisticLockTests {

    @Test("the lock bumps the version and pins the old one into identity")
    func bumpsAndPins() throws {
        let changeset = Changeset(original: Order.placed)     // version 4
            .change(\.note, "ring the bell")
            .optimisticLock(\.version)

        let validated = try changeset.validatedChanges()
        #expect(validated.changedFields["version"] as? Int == 5)
        #expect(validated.identity?["version"] as? Int == 4)
        #expect(validated.identity?["id"] as? Int == 7)
        #expect(validated.lock?.field == "version")
    }

    @Test("locking alone is enough to produce a write")
    func lockIsAForceChange() {
        let changeset = Changeset(original: Order.placed).optimisticLock(\.version)
        #expect(changeset.hasChanges, "a touch-to-claim write still bumps the version")
        #expect(changeset.changes.count == 1)
    }

    @Test("locking an insert is a no-op")
    func insertIsUnlocked() throws {
        let changeset = Changeset(Order.self)
            .change(\.customerID, 3)
            .optimisticLock(\.version)

        #expect(changeset.lock == nil)
        let validated = try changeset.validatedChanges()
        #expect(validated.identity == nil)
        #expect(validated.changedFields["version"] == nil)
        #expect(validated.lock == nil)
    }

    @Test("locking twice leaves one lock, still against the original")
    func idempotent() throws {
        let changeset = Changeset(original: Order.placed)
            .optimisticLock(\.version)
            .optimisticLock(\.version)

        let validated = try changeset.validatedChanges()
        #expect(validated.changedFields["version"] as? Int == 5)
        #expect(validated.identity?["version"] as? Int == 4)
    }

    @Test("the lock wins over a hand-written version change")
    func lockOverridesManualChange() throws {
        let changeset = Changeset(original: Order.placed)
            .change(\.version, 99)
            .optimisticLock(\.version)

        #expect(try changeset.validatedChanges().changedFields["version"] as? Int == 5)
    }

    @Test("the increment wraps rather than traps at the version type's maximum")
    func wrapsAtMaximum() throws {
        let changeset = Changeset(original: Counter(id: 1, revision: .max))
            .optimisticLock(\.revision)

        #expect(try changeset.validatedChanges().changedFields["revision"] as? Int16 == .min)
    }

    @Test("an invalid changeset still cannot hand off a lock")
    func invalidStillRefuses() {
        let changeset = Changeset(original: Order.placed)
            .addError(\.note, "is too long")
            .optimisticLock(\.version)

        #expect(throws: ChangesetValidationError.self) {
            _ = try changeset.validatedChanges()
        }
    }

    @Test("a conflict error says which row and which version")
    func conflictErrorText() {
        let error = ChangesetConflictError(table: "orders", field: "version", expected: "4")
        #expect(error.description.contains("orders"))
        #expect(error.description.contains("version == 4"))
        #expect(error.localizedDescription == error.description)
    }

    @Test("a lock and nested children compose")
    func lockWithNesting() throws {
        let order = Changeset(original: Order.placed)
            .change(\.note, "n")
            .optimisticLock(\.version)
            .nest("lineItems", [Changeset(LineItem.self).change(\.sku, "A")])

        let validated = try order.validatedChanges()
        #expect(validated.identity?["version"] as? Int == 4)
        #expect(try order.validatedNestedChanges()["lineItems"]?.count == 1)
    }
}
