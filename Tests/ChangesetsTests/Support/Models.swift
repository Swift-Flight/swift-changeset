import Foundation
import Changesets


// MARK: - Nesting and locking fixtures

/// Parent of a to-many association, and carrier of a version column.
struct Order: TableModel, Equatable {
    var id: Int?
    var customerID: Int
    var note: String
    var version: Int

    static let tableName = "orders"
    static let columns: [TableColumn<Order>] = [
        TableColumn("id", \Order.id, primaryKey: true),
        TableColumn("customer_id", \Order.customerID),
        TableColumn("note", \Order.note),
        TableColumn("version", \Order.version),
    ]
}

extension Order {
    static let placed = Order(id: 7, customerID: 3, note: "leave at door", version: 4)
}

/// Child of `Order`.
struct LineItem: TableModel, Equatable {
    var id: Int?
    var orderID: Int?
    var sku: String
    var quantity: Int

    static let tableName = "line_items"
    static let columns: [TableColumn<LineItem>] = [
        TableColumn("id", \LineItem.id, primaryKey: true),
        TableColumn("order_id", \LineItem.orderID),
        TableColumn("sku", \LineItem.sku),
        TableColumn("quantity", \LineItem.quantity),
    ]
}

/// A to-one child of a different model type than `LineItem`, so a parent
/// holding both proves the erasure actually erases.
struct ShippingAddress: TableModel, Equatable {
    var id: Int?
    var zip: String

    static let tableName = "shipping_addresses"
    static let columns: [TableColumn<ShippingAddress>] = [
        TableColumn("id", \ShippingAddress.id, primaryKey: true),
        TableColumn("zip", \ShippingAddress.zip),
    ]
}

/// A narrow version type, for the wraparound contract.
struct Counter: TableModel, Equatable {
    var id: Int?
    var revision: Int16

    static let columns: [TableColumn<Counter>] = [
        TableColumn("id", \Counter.id, primaryKey: true),
        TableColumn("revision", \Counter.revision),
    ]
}
