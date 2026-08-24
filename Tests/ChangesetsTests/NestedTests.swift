import Foundation
import Testing
import Changesets

@Suite("Changeset — nesting")
struct NestedChangesetTests {

    private func line(_ sku: String, _ quantity: Int) -> Changeset<LineItem> {
        Changeset(LineItem.self)
            .change(\.sku, sku)
            .change(\.quantity, quantity)
            .validate(\.quantity, .range(1..., message: "must be greater than 0"))
    }

    @Test("a valid parent with valid children is valid")
    func allValid() throws {
        let order = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("lineItems", [line("A", 1), line("B", 2)])

        #expect(order.isValid)
        #expect(order.hasChanges)
        #expect(order.nested("lineItems").count == 2)

        let nested = try order.validatedNestedChanges()
        #expect(nested["lineItems"]?.count == 2)
        #expect(nested["lineItems"]?[1].changedFields["sku"] as? String == "B")
        // Children are inserts: no identity, so a driver knows to INSERT.
        #expect(nested["lineItems"]?[0].identity == nil)
    }

    @Test("an invalid child invalidates the parent, under a pathed key")
    func childInvalidatesParent() {
        let order = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("lineItems", [line("A", 1), line("B", 0)])

        #expect(!order.isValid)
        #expect(order.ownErrors.isEmpty, "the parent itself is fine")
        #expect(order.messagesByField["lineItems[1].quantity"] == ["must be greater than 0"])
        #expect(order.messagesByField["lineItems[0].quantity"] == nil)
    }

    @Test("the parent's handoff refuses while a child is invalid")
    func handoffRefuses() {
        let order = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("lineItems", [line("B", 0)])

        #expect(throws: ChangesetValidationError.self) {
            _ = try order.validatedChanges()
        }
    }

    @Test("a to-one child uses an unindexed path")
    func toOnePath() {
        let order = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("address", Changeset(ShippingAddress.self).addError(\.zip, "is required"))

        #expect(order.messagesByField["address.zip"] == ["is required"])
        #expect(order.nested("address").first?.index == nil)
        #expect(order.nested("address").first?.path == "address")
    }

    @Test("associations of different model types coexist")
    func mixedAssociations() throws {
        let order = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("lineItems", [line("A", 1)])
            .nest("address", Changeset(ShippingAddress.self).change(\.zip, "97201"))

        #expect(order.nestedChangesets.map(\.tableName) == ["line_items", "shipping_addresses"])
        let nested = try order.validatedNestedChanges()
        #expect(nested["address"]?.first?.changedFields["zip"] as? String == "97201")
    }

    @Test("re-nesting the same association replaces rather than appends")
    func renestReplaces() {
        let order = Changeset(Order.self)
            .nest("lineItems", [line("A", 1), line("B", 0)])
            .nest("lineItems", [line("C", 5)])

        #expect(order.nested("lineItems").count == 1)
        #expect(order.isValid, "the earlier invalid child is gone, not accumulated")
    }

    @Test("removeNested drops an association")
    func removeNested() {
        let order = Changeset(Order.self)
            .change(\.customerID, 3)
            .nest("lineItems", [line("B", 0)])
            .removeNested("lineItems")

        #expect(order.isValid)
        #expect(order.nestedChangesets.isEmpty)
    }

    @Test("a parent with no changes of its own still has changes through a child")
    func changesThroughChildOnly() {
        let order = Changeset(original: Order.placed)
            .nest("lineItems", [line("A", 1)])

        #expect(order.changes.isEmpty)
        #expect(order.hasChanges)
    }

    @Test("a child with no changes leaves hasChanges false")
    func noChangesAnywhere() {
        let order = Changeset(original: Order.placed)
            .nest("lineItems", [Changeset(original: LineItem(id: 1, orderID: 7, sku: "A", quantity: 2))])

        #expect(!order.hasChanges)
    }

    @Test("merge carries nested children across")
    func mergeCarriesNested() {
        let base = Changeset(Order.self).change(\.customerID, 3)
        let withLines = Changeset(Order.self).nest("lineItems", [line("A", 1)])

        #expect(base.merge(withLines).nested("lineItems").count == 1)
    }

    @Test("nesting is invisible to a changeset that does not use it")
    func noNestingIsUnchanged() throws {
        let changeset = Changeset(original: User.ada).change(\.age, 37)
        #expect(changeset.errors.isEmpty)
        #expect(changeset.nestedChangesets.isEmpty)
        #expect(try changeset.validatedChanges().lock == nil)
    }
}
