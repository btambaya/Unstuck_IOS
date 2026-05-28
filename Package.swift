// swift-tools-version: 6.0
// UnstuckKit — local Swift package powering the unstuck iOS app.
//
// The app target + widget/Live-Activity extensions live in an Xcode
// project (added in a later phase) that depends on these library
// products. Pure-logic + data + sync layers live here so they build and
// test via `swift test` with no Xcode project or code signing required.
//
// Layering (added incrementally as phases land):
//   UnstuckCore     — pure domain models + logic ports (NO UI/Supabase)
//   UnstuckData     — GRDB local store + outbox          (phase P1)
//   UnstuckSync     — supabase-swift wiring + sync engine (phase P1)
//   UnstuckDesign   — brand tokens + SwiftUI components   (phase P1/UI)
//   UnstuckShared   — App-Group snapshot shared w/ widgets (surfaces)
//   UnstuckFeatures — SwiftUI feature modules             (P2–P6)
import PackageDescription

let package = Package(
    name: "UnstuckKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UnstuckCore", targets: ["UnstuckCore"]),
        .library(name: "UnstuckData", targets: ["UnstuckData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "UnstuckCore"),
        .testTarget(name: "UnstuckCoreTests", dependencies: ["UnstuckCore"]),

        // Offline-first local store: GRDB schema mirroring the server
        // tables + a write-ahead outbox + device-local live session.
        .target(
            name: "UnstuckData",
            dependencies: ["UnstuckCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(
            name: "UnstuckDataTests",
            dependencies: ["UnstuckData", "UnstuckCore", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
