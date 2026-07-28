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
        // catalog. Pure Swift: no IOKit, no I/O beyond reading a file, fully
        // unit-testable. Keep it that way.
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
        // Exercises fanctl's read commands (list, sensors) against fake SensorProviders,
        // so the bulk of the suite needs no hardware at all. The handful of assertions
        // that do touch the real SMC follow the isDevelopmentMachine() gating pattern
        // from Tests/SMCCoreTests/DevelopmentMachine.swift.
        .testTarget(
            name: "fanctlTests",
            dependencies: ["fanctl", "SMCCore"],
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
    ]
)
