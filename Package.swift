// swift-tools-version: 6.0
import PackageDescription

// Aeolus is built two ways, and this manifest is the shared foundation for both:
//
//   * `swift build` / `swift test` — libraries, the CLI, and the helper daemon. This is
//     what CI runs on every PR and what a contributor without an Apple Developer account
//     can build. No signing, no entitlements, no app bundle.
//   * XcodeGen (`project.yml`) — generates the .xcodeproj that produces the signed
//     Aeolus.app bundle with the helper embedded. See CONTRIBUTING.md.
//
// The SwiftUI app lives in `Sources/Aeolus` and is exposed here as the `AeolusUI`
// library so it type-checks under `swift build`. The `@main` entry point is supplied by
// the Xcode app target, not by this package.

let package = Package(
    name: "Aeolus",
    platforms: [
        // SMAppService.daemon(plistName:) requires macOS 13. Newer MenuBarExtra
        // affordances are gated with @available checks rather than raising this floor.
        .macOS(.v13)
    ],
    products: [
        .library(name: "SMCCore", targets: ["SMCCore"]),
        .library(name: "FanKit", targets: ["FanKit"]),
        .library(name: "AeolusXPC", targets: ["AeolusXPC"]),
        .library(name: "AeolusUI", targets: ["AeolusUI"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
        .executable(name: "AeolusHelper", targets: ["AeolusHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Key enumeration, the type codec, and the IOKit connection.
        //
        // The read API is `public`. The write API is deliberately NOT public — it is
        // `package`-scoped so only AeolusHelper can reach it. Any change that widens
        // that boundary is a safety review, not a refactor. See docs/SAFETY.md.
        .target(
            name: "SMCCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Fan/sensor models, curve engine, profile and config schema, and the sensor
        // catalog. Pure Swift: no IOKit, no general-purpose I/O, fully unit-testable.
        // Keep it that way. The two narrow exceptions are reading a file
        // (CatalogLoader's bundled/override catalog) and reading a fixed system
        // property via sysctlbyname (HardwareIdentity.current(), for hw.model /
        // machdep.cpu.brand_string — see that file's doc comment for why this belongs
        // here rather than in a client). Both are single, clearly-marked non-pure
        // entry points; everything downstream of them (matching included) stays a pure
        // function of the value they produce.
        //
        // `resources` copies the canonical `Resources/catalog/catalog.json` — it lives
        // at the repo root, not under Sources/FanKit, so every consumer (SPM, the Xcode
        // app) reads the one file rather than a duplicated copy that can drift.
        // `catalog.schema.json` is deliberately not copied here: nothing at runtime
        // reads it (CI validates it directly against the source tree), so there is no
        // reason to ship a development artifact inside the app.
        .target(
            name: "FanKit",
            resources: [.copy("../../Resources/catalog/catalog.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The shared privilege-boundary contract: the @objc XPC protocol plus the
        // Codable DTOs that cross it. Imported by the helper, the app, and the CLI.
        .target(
            name: "AeolusXPC",
            dependencies: ["FanKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The root launchd daemon. Sole owner of every SMC write.
        .executableTarget(
            name: "AeolusHelper",
            dependencies: ["SMCCore", "FanKit", "AeolusXPC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Thin XPC client. Also runs standalone in read-only mode with no helper present.
        .executableTarget(
            name: "fanctl",
            dependencies: [
                "SMCCore",
                "FanKit",
                "AeolusXPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // SwiftUI views and view models for Aeolus.app.
        .target(
            name: "AeolusUI",
            dependencies: ["SMCCore", "FanKit", "AeolusXPC"],
            path: "Sources/Aeolus",
            // The app's entry point belongs to the Xcode bundle target, not to this
            // library — a library may not contain top-level code.
            exclude: ["main.swift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "SMCCoreTests",
            dependencies: ["SMCCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Exercises fanctl's read commands (list, sensors, dump) against fake
        // SensorProviders and pure formatting/classification logic (row models, error
        // descriptions, table/JSON rendering) via @testable import, so the bulk of the
        // suite needs no open SMC connection at all. The handful of assertions that do
        // touch real hardware gate on HardwareIdentity.current(), the same check
        // Tests/SMCCoreTests/DevelopmentMachine.swift performs — fanctl already depends on
        // FanKit, so there is no reason for a second, test-only sysctl reader here.
        .testTarget(
            name: "fanctlTests",
            // FanKit is also needed directly, not just transitively via fanctl, so tests
            // can build SensorCatalog/CatalogEntry/HardwareIdentity fixtures for
            // CatalogSensorLookup — see CatalogSensorLookupTests.swift.
            dependencies: ["fanctl", "SMCCore", "FanKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FanKitTests",
            dependencies: ["FanKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Exercises the safety subsystem against a mock SMC. These tests are the gate
        // on the write path (E5); they must not require real hardware.
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["SMCCore", "FanKit", "AeolusXPC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Exercises AeolusUI's polling data layer (E7.1): fan/sensor enumeration, the
        // unavailable-vs-zero and non-finite-value guards, and the refresh loop, against
        // fake SensorProviders/clocks via @testable import — the same "no hardware needed
        // for the bulk of the suite, hardware-gated smoke tests for the rest" split
        // fanctlTests uses. FanKit is needed directly, not just transitively via AeolusUI,
        // for HardwareIdentity/catalog fixtures in the label-source tests.
        .testTarget(
            name: "AeolusUITests",
            dependencies: ["AeolusUI", "SMCCore", "FanKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
