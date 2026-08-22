import Testing
import Changesets

@Suite("TableModel — public keypath→column-name lookup")
struct ColumnNameLookupTests {

    @Test("columnName(for:) resolves keypaths to store-neutral names")
    func columnNameLookup() {
        #expect(User.columnName(for: \User.displayName) == "display_name")
        #expect(User.columnName(for: \User.id) == "id")
    }

    @Test("columnName(for:) is nil for keypaths with no column metadata")
    func columnNameMiss() {
        // A keypath into another type's metadata is simply not found —
        // non-trapping, unlike the internal changeset-path lookup.
        #expect(User.columnName(for: \User.self) == nil)
    }
}
