import Foundation
import Testing

@testable import AeolusHelper

/// No bound of the watchdog is read from outside the binary (ADR 0012 I8, CLAUDE.md rule 5).
///
/// `WatchdogLimitsTests` pins each bound's value with nothing set, which is exactly the state in
/// which a bound read from the environment still passes. This is the other half: the files that
/// hold or apply a bound may not name a way to read one from outside. Each scan is run over
/// fixtures first, so that one which has quietly stopped seeing anything cannot pass for a tree
/// that is clean.
@Suite("No bound of the watchdog is configurable, at the source")
struct WatchdogConfigurationTripwireTests {

    private func lifecycleSource(_ file: String) throws -> String {
        try source("AeolusHelper/Lifecycle/\(file)")
    }

    private func source(_ path: String) throws -> String {
        let url = SeamScanner.sourcesRoot.appendingPathComponent(path)
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// The words that read a bound from outside the binary. `WatchdogLimits` is `static let`
    /// and `LivenessWatchdog.init` takes only collaborators, and **neither of those stops a
    /// `static let` being initialised from the environment**: a launchd `EnvironmentVariables`
    /// key is a configuration file by another name, and CLAUDE.md rule 5 says a config that
    /// moves a safety limit does not exist.
    ///
    /// Words, not prefixes: `.environment` is a member access and has to be found.
    static let configurationSources = [
        "ProcessInfo", "getenv", "setenv", "environment", "UserDefaults", "CommandLine",
        "FileManager", "Bundle", "NSUbiquitousKeyValueStore",
    ]

    static func configurationReads(in code: String) throws -> [String] {
        try configurationSources.filter { word in
            try NSRegularExpression(pattern: #"(?<![\w])"# + word + #"(?![\w])"#)
                .firstMatch(in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
                != nil
        }
    }

    /// **Mutation:** initialise `WatchdogLimits.roundTrip` from
    /// `ProcessInfo.processInfo.environment` (default 5 s, `static let` kept). Run: red.
    /// **Mutation:** read `UserDefaults.standard` anywhere in `LivenessWatchdog.swift`. Run: red.
    @Test("No bound of the watchdog is read from outside the binary")
    func noBoundIsReadFromTheEnvironment() throws {
        let files: [(name: String, code: String)] = [
            ("WatchdogLimits.swift", try lifecycleSource("WatchdogLimits.swift")),
            ("LivenessWatchdog.swift", try lifecycleSource("LivenessWatchdog.swift")),
            ("ProcessTermination.swift", try lifecycleSource("ProcessTermination.swift")),
            (
                "ThermalCycleProgress.swift",
                try source("AeolusHelper/Safety/ThermalCycleProgress.swift")
            ),
        ]
        for (name, code) in files {
            let found = try Self.configurationReads(in: code)
            #expect(
                found.isEmpty,
                """
                \(name) reads \(found). A bound that can be set from the environment, a \
                defaults domain, the command line or a file is a bound a configuration can \
                lengthen (ADR 0012 I8, CLAUDE.md rule 5).
                """)
        }
    }

    /// The scan above, over fixtures.
    ///
    /// **Mutation:** make `configurationReads(in:)` return an empty array. Run: red.
    /// **Mutation:** drop `environment` from `configurationSources`. Run: red — the member
    /// access fixture goes unseen.
    @Test("The configuration scan sees every way of reading one")
    func theConfigurationScanSeesWhatItShould() throws {
        let read = [
            #"static let roundTrip = .seconds(Int(ProcessInfo.processInfo.environment["D"]!)!)"#,
            #"let d = getenv("AEOLUS_D")"#,
            "let d = UserDefaults.standard.integer(forKey: \"d\")",
            "let a = CommandLine.arguments",
            "let e = info.environment",
            "let p = FileManager.default.contents(atPath: path)",
            "let b = Bundle.main.object(forInfoDictionaryKey: \"D\")",
            "let p = Foundation.ProcessInfo.processInfo",
        ]
        for fixture in read {
            #expect(try !Self.configurationReads(in: fixture).isEmpty, "not seen: \(fixture)")
        }
        let clean = [
            "static let roundTrip: Duration = .seconds(5)",
            "/// never reads ProcessInfo\nlet x = 1",
            "let environmental = 1",
            "let getenvironment = 2",
        ]
        for fixture in clean {
            #expect(
                try Self.configurationReads(in: SeamScanner.strippingComments(fixture)).isEmpty,
                "seen in clean code: \(fixture)")
        }
    }
}
