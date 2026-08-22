// swift-tools-version: 6.2
// Swift Changeset — the thin validation + dirty-tracking layer
// (flight-changeset-design.md): semantic validation, dirty tracking, and the
// neutral ValidatedChanges handoff a driver translates into its native
// write. Deliberately Flight-independent (hangar-design.md §11.2): zero
// dependencies, so both Hangar and Flight Data Core can consume it.
import PackageDescription

let package = Package(
    name: "swift-changeset",
    platforms: [
        // macOS 15, same floor as the Flight packages that consume it.
        .macOS(.v15)
    ],
    products: [
        // The contract: Changeset, ValidationRule/CrossFieldRule, the
        // TableModel metadata seam, and ValidatedChanges (design §3–§5).
        // Module named "Changesets" (swift-collections → Collections
        // convention) so it never collides with the central Changeset type.
        .library(name: "Changesets", targets: ["Changesets"])
    ],
    targets: [
        .target(
            name: "Changesets",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChangesetsTests",
            dependencies: ["Changesets"]
        ),
    ]
)
