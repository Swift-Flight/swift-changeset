/// The store-agnostic model-metadata seam a changeset consumes: which
/// stored properties are columns, what each is named at the store, and
/// which of them identify a row.
///
/// A changeset needs exactly one thing from a model type: a mapping from
/// *keypaths* — the compile-checked, developer-facing currency — to *column
/// identifiers*, the store-neutral strings inside ``ValidatedChanges``.
/// This protocol is that mapping and nothing else. It is deliberately not a
/// query model: the same conformance has to serve a SQL driver, a document
/// store, and a key-value store identically.
///
/// Conforming by hand is a handful of lines, and a code generator can emit
/// the same shape mechanically.
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

    /// The store-neutral column name for `keyPath`, or `nil` when no column
    /// metadata covers it.
    ///
    /// The non-trapping counterpart to the changeset's internal lookup, for
    /// code that resolves keypaths to column identifiers outside a
    /// changeset — turning a foreign-key keypath into the column a query
    /// filters on, for instance.
    ///
    /// ```swift
    /// User.columnName(for: \User.displayName)   // "display_name"
    /// ```
    public static func columnName(for keyPath: AnyKeyPath) -> String? {
        columns.first(where: { $0.keyPath == keyPath })?.name
    }

    /// Keypath → column lookup. Trapping, not throwing: a missing entry is
    /// incomplete metadata — a wiring bug caught by any test that touches
    /// the field — not a runtime condition callers can recover from.
    /// Traps when two columns share a ``TableColumn/name``.
    ///
    /// Duplicate names are silent data corruption: ``Changeset/changes`` is
    /// keyed by name, so the second column's write overwrites the first's
    /// and reads come back from the wrong field. Checking at changeset
    /// construction turns that into a loud failure at the first test that
    /// touches the model.
    internal static func assertColumnNamesAreUnique() {
        var seen = Set<String>()
        seen.reserveCapacity(columns.count)
        for column in columns where !seen.insert(column.name).inserted {
            preconditionFailure("""
            \(Self.self) declares more than one column named "\(column.name)". \
            Column names key the changeset's changes, so duplicates would silently \
            drop one field's write and read back the other's value. \
            Give each TableColumn in \(Self.self).columns a distinct name.
            """)
        }
    }

    /// Checks this model's column metadata and traps on a problem.
    ///
    /// Call it from a test to catch metadata mistakes at their source rather
    /// than at the first changeset that happens to touch the field.
    ///
    /// ```swift
    /// @Test func metadataIsWellFormed() {
    ///     User.validateColumnMetadata()
    /// }
    /// ```
    ///
    /// - Precondition: no two columns share a name.
    public static func validateColumnMetadata() {
        assertColumnNamesAreUnique()
    }

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
