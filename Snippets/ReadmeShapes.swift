// Every shape the README claims, compiled.
//
// A README example that does not compile is worse than no example: it costs
// a reader the time to find out. This snippet builds as part of
// `swift build`, so a rename that invalidates the prose breaks the build.

import Foundation
import Changesets

struct Post: TableModel, Equatable {
    var id: Int?
    var title: String
    var version: Int

    static let tableName = "posts"
    static let columns: [TableColumn<Post>] = [
        TableColumn("id", \Post.id, primaryKey: true),
        TableColumn("title", \Post.title),
        TableColumn("version", \Post.version),
    ]
}

struct Order: TableModel {
    var id: Int?
    var customerID: Int

    static let tableName = "orders"
    static let columns: [TableColumn<Order>] = [
        TableColumn("id", \Order.id, primaryKey: true),
        TableColumn("customer_id", \Order.customerID),
    ]
}

struct LineItem: TableModel {
    var id: Int?
    var sku: String
    var quantity: Int

    static let tableName = "line_items"
    static let columns: [TableColumn<LineItem>] = [
        TableColumn("id", \LineItem.id, primaryKey: true),
        TableColumn("sku", \LineItem.sku),
        TableColumn("quantity", \LineItem.quantity),
    ]
}

struct ShippingAddress: TableModel {
    var id: Int?
    var zip: String

    static let tableName = "shipping_addresses"
    static let columns: [TableColumn<ShippingAddress>] = [
        TableColumn("id", \ShippingAddress.id, primaryKey: true),
        TableColumn("zip", \ShippingAddress.zip),
    ]
}

struct LineInput { var sku: String; var quantity: Int }

// MARK: - Nested changesets

let lines = [LineInput(sku: "A", quantity: 2), LineInput(sku: "B", quantity: 0)]

let order = Changeset(Order.self)
    .change(\.customerID, 3)
    .nest("lineItems", lines.map { line in
        Changeset(LineItem.self)
            .change(\.sku, line.sku)
            .change(\.quantity, line.quantity)
            .validate(\.quantity, .range(1..., message: "must be at least 1"))
    })

precondition(!order.isValid)
precondition(order.messagesByField["lineItems[1].quantity"] == ["must be at least 1"])

// A to-one association drops the index from the path.
let withAddress = Changeset(Order.self)
    .change(\.customerID, 3)
    .nest("address", Changeset(ShippingAddress.self).change(\.zip, "97201"))
precondition(withAddress.nested("address").first?.path == "address")

// Re-nesting replaces rather than appends.
let rebuilt = order.nest("lineItems", [Changeset(LineItem.self).change(\.sku, "C").change(\.quantity, 1)])
precondition(rebuilt.isValid)
precondition(try! rebuilt.validatedNestedChanges()["lineItems"]?.count == 1)

// The two handoffs are two calls, because the parent must land first.
let parent = try! rebuilt.validatedChanges()
precondition(parent.identity == nil)
for row in try! rebuilt.validatedNestedChanges()["lineItems"] ?? [] {
    precondition(row.changedFields["sku"] as? String == "C")
}

// MARK: - Optimistic locking

let post = Post(id: 1, title: "Draft", version: 7)
let locked = Changeset(original: post)
    .change(\.title, "Revised")
    .optimisticLock(\.version)

let validated = try! locked.validatedChanges()
precondition(validated.changedFields["version"] as? Int == 8)
precondition(validated.identity?["version"] as? Int == 7)
precondition(validated.identity?["id"] as? Int == 1)

let rows = 0
if rows == 0, let lock = validated.lock {
    let conflict = ChangesetConflictError(
        table: Post.tableName, field: lock.field,
        expected: String(describing: lock.expected))
    precondition(conflict.description.contains("version == 7"))
}
