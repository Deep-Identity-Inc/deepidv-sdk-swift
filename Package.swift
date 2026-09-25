// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DeepIDV",
    // The SDK ships iOS-only: the feature surface is camera/UIKit-bound, so
    // there is no macOS build.
    platforms: [
        .iOS(.v15),
    ],
    products: [
        // We expose exactly ONE product to clients: the `DeepIDV` library.
        // `DeepIDVCore` is a target but NOT a product — clients can't
        // `import DeepIDVCore`. It's a sealed implementation detail.
        .library(
            name: "DeepIDV",
            targets: ["DeepIDV"]
        )
    ],
    targets: [
        // ── Core: models, services, networking, errors — NO UI. ──────────────
        // Lives in Sources/DeepIDVCore/. Pure logic, independently testable.
        .target(
            name: "DeepIDVCore"
        ),
        // ── DeepIDV: public-facing umbrella (UI + top-level namespace). ───────
        .target(
            name: "DeepIDV",
            dependencies: ["DeepIDVCore"]
        ),
        // ── One test target per source target. ───────────────────────────────
        .testTarget(
            name: "DeepIDVCoreTests",
            dependencies: ["DeepIDVCore"]
        ),
        .testTarget(
            name: "DeepIDVTests",
            // Also depends on DeepIDVCore directly so model tests can build
            // services on a stubbed `package` transport.
            dependencies: ["DeepIDV", "DeepIDVCore"]
        ),
    ]
)
