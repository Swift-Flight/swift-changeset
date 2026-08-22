/// The store-agnostic model-metadata seam the changeset consumes (changeset
/// design §4): which stored properties are columns, what each is named at
/// the store, and which of them identify a row.
///
/// The changeset needs exactly one thing from a model type: a mapping from
/// *keypaths* (the compile-checked, developer-facing currency) to *column
/// identifiers* (the store-neutral strings inside `ValidatedChanges`). This
/// protocol is that mapping and nothing else — deliberately not a query
/// model (Flight Data Core §1) and deliberately not StructuredQueries'
/// `Table`: that library is the Postgres driver's choice (its design §3.2),
/// and this seam must serve a Mongo or Redis driver identically. The
/// Postgres package bridges its `@Table` metadata onto this protocol
/// mechanically; hand-conformance is a handful of lines (see
/// `TableColumn`). A `@TableModel` macro generating the conformance is
/// deliberate future sugar, not a dependency of the design.
///
/// ```swift
/// struct User: TableModel {
///     var id: Int?
///     var email: String?
///     var displayName: String
///
///     static let columns: [TableColumn<User>] = [
///         TableColumn("id", \User.id, primaryKey: true),
///         TableColumn("email", \User.email),
///         TableColumn("display_name", \User.displayName),
///     ]
/// }
/// ```
public protocol TableModel: Sendable {
    /// The table/collection identifier at the store. Defaults to the type
    /// name, lowercased.
    static var tableName: String { get }

    /// Every column a changeset may touch. A keypath with no entry here is a
    /// programmer error (incomplete metadata) and traps loudly at the first
    /// `change`/`validate` that references it.
    static var columns: [TableColumn<Self>] { get }

    /// The columns that identify a row — `ValidatedChanges.identity` for
    /// UPDATEs. Defaults to the `columns` flagged `primaryKey: true`.
    static var primaryKey: [TableColumn<Self>] { get }
}

extension TableModel {
    public static var tableName: String {
        String(describing: Self.self).lowercased()
    }

    public static var primaryKey: [TableColumn<Self>] {
        columns.filter(\.isPrimaryKey)
    }

    /// The store-neutral column name for `keyPath`, or nil when no column
    /// metadata covers it. The non-trapping public face of `column(for:)`,
    /// for consumers that resolve keypaths to column identifiers outside a
    /// changeset — e.g. Hangar's association preloading, which turns a
    /// foreign-key keypath into the column its batched query filters on.
    public static func columnName(for keyPath: AnyKeyPath) -> String? {
        columns.first(where: { $0.keyPath == keyPath })?.name
    }

    /// Keypath → column lookup. Trapping, not throwing: a missing entry is
    /// incomplete metadata (a wiring bug caught by any test that touches the
    /// field), not a runtime condition — the same reasoning as Core's
    /// registration preconditions (Flight Core §2.1).
    internal static func column(for keyPath: AnyKeyPath) -> TableColumn<Self> {
        guard let column = columns.first(where: { $0.keyPath == keyPath }) else {
            preconditionFailure("""
            \(Self.self) has no column metadata for \(keyPath). \
            Every field a changeset references needs a TableColumn entry in \(Self.self).columns.
            """)
        }
        return column
    }
}

/// One column of a `TableModel`: its store-neutral name, the keypath that
/// reaches it, and whether it participates in row identity.
///
/// The typed keypath is captured twice at construction — erased for lookup
/// equality, and inside a reader closure so primary-key values can be pulled
/// from an original model as `any Sendable` without a runtime `Sendable`
/// cast (marker protocols cannot be casted to; the closure preserves the
/// conformance statically instead).
public struct TableColumn<Model>: Sendable {
    /// The column identifier as the store sees it (`display_name`, not
    /// `displayName`). This is the string that appears in
    /// `ValidatedChanges.changedFields` / `.identity` and in
    /// `ChangesetError.field`.
    public let name: String
    /// Whether this column is part of the row's identity (§3: UPDATEs need
    /// a primary key; inserts don't).
    public let isPrimaryKey: Bool

    internal let keyPath: PartialKeyPath<Model> & Sendable
    internal let read: @Sendable (Model) -> any Sendable

    public init<V: Sendable>(
        _ name: String,
        _ keyPath: KeyPath<Model, V> & Sendable,
        primaryKey: Bool = false
    ) {
        self.name = name
        self.isPrimaryKey = primaryKey
        self.keyPath = keyPath
        self.read = { $0[keyPath: keyPath] }
    }
}
