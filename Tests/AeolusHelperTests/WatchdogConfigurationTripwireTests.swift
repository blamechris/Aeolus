import Foundation
import Testing

@testable import AeolusHelper

/// No bound of the watchdog is read from outside the binary (ADR 0012 I8, CLAUDE.md rule 5).
///
/// `WatchdogLimitsTests` pins each bound's value with nothing set, which is exactly the state in
/// which a bound read from the environment still passes. This is the other half: the files that
/// hold or apply a bound, **and every file that defines a constant a bound is built from**, may
/// not name a way to read one from outside. Each scan is run over fixtures first, so that one
/// which has quietly stopped seeing anything cannot pass for a tree that is clean.
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
    /// Words, not prefixes, so that `environmental` is clean and `.environment` (a member
    /// access) is found; a trailing `*` makes an entry a prefix, for the C API families
    /// (`CFPreferencesCopyAppValue`, `kCFPreferencesAnyApplication`) whose every member reads
    /// the same store. An entry with a `(` in it is a call to the initialiser that reads a file.
    static let configurationSources = [
        "ProcessInfo", "getenv", "setenv", "environment",
        "UserDefaults", "NSUserDefaults", "defaults", "CFPreferences*", "kCFPreferences*",
        "NSUbiquitousKeyValueStore",
        "CommandLine", "FileManager", "Bundle", "CFBundle*",
        "String(contentsOf", "Data(contentsOf", "NSData(contentsOf", "NSString(contentsOf",
        "NSDictionary(contentsOf", "NSArray(contentsOf", "contentsOfFile", "fopen",
    ]

    /// `code` as the scans read it: backticks dropped (`` `ProcessInfo`.processInfo `` is the same
    /// call), whitespace collapsed, and none left either side of a parenthesis.
    static func normalised(_ code: String) -> String {
        var text = code.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\(\s*"#, with: "(", options: .regularExpression)
        return text
    }

    static func configurationReads(in code: String) throws -> [String] {
        let text = normalised(code)
        return try configurationSources.filter { entry in
            let isPrefix = entry.hasSuffix("*")
            let word = isPrefix ? String(entry.dropLast()) : entry
            let tail = isPrefix ? "" : #"(?![\w])"#
            let pattern = #"(?<![\w])"# + NSRegularExpression.escapedPattern(for: word) + tail
            return try NSRegularExpression(pattern: pattern)
                .firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
                != nil
        }
    }

    // MARK: - Which files are scanned

    /// The types whose members `code` reads: `ReconciliationLimits.budget`,
    /// `ThermalSupervisor<SMCFanControlPlane>.defaultInterval`. A bound built from a constant
    /// is as configurable as that constant, so the file that defines it is one a bound derives
    /// from.
    static func typesRead(by code: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"\b([A-Z]\w*)(?:<[^>]*>)?\.\w+"#)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return Set(
            pattern.matches(in: code, range: range).compactMap { match in
                Range(match.range(at: 1), in: code).map { String(code[$0]) }
            })
    }

    /// Whether `code` declares the type `name`, or extends it.
    static func declares(_ name: String, in code: String) throws -> Bool {
        let declaration = #"\b(?:enum|struct|class|actor|protocol|extension)\s+"# + name + #"\b"#
        return try NSRegularExpression(pattern: declaration)
            .firstMatch(in: code, range: NSRange(code.startIndex..<code.endIndex, in: code)) != nil
    }

    /// Every file a bound of the watchdog derives from: the four files that hold or apply one,
    /// and every file under `Sources` that declares a type `WatchdogLimits.swift` reads a
    /// member of. A new constant a bound is built from falls inside this set by being
    /// *referenced*, not by someone remembering to add its file to a list.
    ///
    /// One level: a constant that is itself computed from a third type is not followed.
    func scannedFiles() throws -> [(name: String, code: String)] {
        let fixed = [
            "AeolusHelper/Lifecycle/WatchdogLimits.swift",
            "AeolusHelper/Lifecycle/LivenessWatchdog.swift",
            "AeolusHelper/Lifecycle/ProcessTermination.swift",
            "AeolusHelper/Safety/ThermalCycleProgress.swift",
        ]
        var files: [String: String] = [:]
        for path in fixed {
            files[path] = try source(path)
        }
        let referenced = try Self.typesRead(by: try lifecycleSource("WatchdogLimits.swift"))
        for url in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
            if try referenced.contains(where: { try Self.declares($0, in: code) }) {
                let relative = url.path.components(separatedBy: "/Sources/").last ?? url.path
                files[relative] = code
            }
        }
        return files.keys.sorted().map { ($0, files[$0] ?? "") }
    }

    /// **Mutation:** initialise `WatchdogLimits.roundTrip` from
    /// `ProcessInfo.processInfo.environment` (default 5 s, `static let` kept). Run: red.
    /// **Mutation:** initialise `WatchdogLimits.roundTrip` from `CFPreferencesCopyAppValue`.
    /// Run: red.
    /// **Mutation:** initialise `ReconciliationLimits.budget` from the environment — a file the
    /// four named ones do not include. Run: red.
    /// **Mutation:** read `UserDefaults.standard` anywhere in `LivenessWatchdog.swift`. Run: red.
    @Test("No bound of the watchdog is read from outside the binary")
    func noBoundIsReadFromTheEnvironment() throws {
        let files = try scannedFiles()
        let names = files.map(\.name)
        // A derivation that found nothing would pass everything: the files a bound is built
        // from today are asserted present.
        for expected in [
            "AeolusHelper/Safety/ReconciliationBaseline.swift",
            "AeolusHelper/SMCReadScheduler.swift", "AeolusHelper/Safety/ThermalSupervisor.swift",
        ] {
            #expect(names.contains(expected), "\(expected) is no longer among \(names)")
        }
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
    /// **Mutation:** drop `CFPreferences*` from `configurationSources`. Run: red.
    @Test("The configuration scan sees every way of reading one")
    func theConfigurationScanSeesWhatItShould() throws {
        let read = [
            #"static let roundTrip = .seconds(Int(ProcessInfo.processInfo.environment["D"]!)!)"#,
            #"let d = getenv("AEOLUS_D")"#,
            "let d = UserDefaults.standard.integer(forKey: \"d\")",
            "let d = NSUserDefaults.standard",
            "let a = CommandLine.arguments",
            "let e = info.environment",
            "let p = FileManager.default.contents(atPath: path)",
            "let b = Bundle.main.object(forInfoDictionaryKey: \"D\")",
            "let p = Foundation.ProcessInfo.processInfo",
            "let d = `ProcessInfo`.processInfo",
            #"let v = CFPreferencesCopyAppValue("D" as CFString, kCFPreferencesAnyApplication)"#,
            "let v = CFPreferences",
            "let any = kCFPreferencesCurrentApplication",
            "let b = CFBundleGetMainBundle()",
            #"let s = try String(contentsOf: url)"#,
            #"let s = try String (contentsOf: url)"#,
            #"let d = try Data(contentsOf: url)"#,
            #"let d = NSDictionary(contentsOf: url)"#,
            #"let s = try String(contentsOfFile: path)"#,
            #"let f = fopen(path, "r")"#,
            "let key = defaults read",
        ]
        for fixture in read {
            #expect(try !Self.configurationReads(in: fixture).isEmpty, "not seen: \(fixture)")
        }
        let clean = [
            "static let roundTrip: Duration = .seconds(5)",
            "/// never reads ProcessInfo\nlet x = 1",
            "let environmental = 1",
            "let getenvironment = 2",
            "let defaultInterval = 1",
            "outcomes.append(contentsOf: try await provider.read(keys: keys))",
            "let preferences = 3",
        ]
        for fixture in clean {
            #expect(
                try Self.configurationReads(in: SeamScanner.strippingComments(fixture)).isEmpty,
                "seen in clean code: \(fixture)")
        }
    }

    /// The derivation of the file set, over fixtures: a type whose member is read is found, a
    /// generic argument is not a read, and a declaration or an extension is a declaration.
    ///
    /// **Mutation:** make `typesRead(by:)` return an empty set. Run: red.
    /// **Mutation:** drop `extension` from `declares(_:in:)`. Run: red.
    @Test("The scanned file set is derived from what WatchdogLimits reads")
    func theDerivationSeesWhatItShould() throws {
        let code = """
            static let a = ReconciliationLimits.budget + SMCReadScheduler.maxKeysPerTurn
            static let b = ThermalSupervisor<SMCFanControlPlane>.defaultInterval
            static let c: Duration = .seconds(1)
            """
        #expect(
            try Self.typesRead(by: code) == [
                "ReconciliationLimits", "SMCReadScheduler", "ThermalSupervisor",
            ])
        #expect(try Self.declares("A", in: "enum A {"))
        #expect(try Self.declares("A", in: "extension A: Sendable {"))
        #expect(try Self.declares("A", in: "final class A: Sendable {"))
        #expect(try !Self.declares("A", in: "enum AB {"))
        #expect(try !Self.declares("A", in: "let a = A.b"))
    }
}
