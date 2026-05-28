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
    ],
    targets: [
        .target(name: "UnstuckCore"),
        .testTarget(name: "UnstuckCoreTests", dependencies: ["UnstuckCore"]),
    ]
)
