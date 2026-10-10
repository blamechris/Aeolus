import Foundation
import Testing

@testable import AeolusHelper

/// The watchdog's bounds cannot be moved by anything a client, a configuration or a caller can
/// reach (ADR 0012 I8, CLAUDE.md rule 5), asserted at the source.
///
/// `WatchdogLimits` is `static let`, and `LivenessWatchdog.init` takes only its collaborators.
/// Neither fact is observable at runtime, and neither is enough alone: a `static let` can be
/// initialised from the environment, and an initialiser with no `Duration` can still take an
/// `Int` that is added to a threshold. So the scans here are semantic as well as syntactic, and,
/// because a tripwire is itself a guard, each is run over fixtures so that a scan which has
/// quietly stopped seeing anything cannot pass for a tree that is clean.
@Suite("The watchdog's bounds are constants, at the source")
struct WatchdogBoundsTripwireTests {

    private func lifecycleSource(_ file: String) throws -> String {
        try source("AeolusHelper/Lifecycle/\(file)")
    }

    private func source(_ path: String) throws -> String {
        let url = SeamScanner.sourcesRoot.appendingPathComponent(path)
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - No Duration on the initialiser

    /// The `(…)` of every `init` in `code`, parsed to its closing parenthesis rather than
    /// matched up to the first `)`: a default value such as `log: WatchdogLog = WatchdogLog()`
    /// has parentheses of its own.
    static func initializerParameters(in code: String) throws -> [String] {
        let opener = try NSRegularExpression(pattern: #"\binit\s*[?!]?\s*\("#)
        let characters = Array(code)
        var parameters: [String] = []
        let openings = opener.matches(
            in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
        for match in openings {
            guard let range = Range(match.range, in: code) else { continue }
            var index = code.distance(from: code.startIndex, to: range.upperBound)
            var depth = 1
            let start = index
            while index < characters.count, depth > 0 {
                if characters[index] == "(" { depth += 1 }
                if characters[index] == ")" { depth -= 1 }
                index += 1
            }
            parameters.append(String(characters[start..<max(start, index - 1)]))
        }
        return parameters
    }

    /// The text of the type declared by `header` (`final class LivenessWatchdog`), from its
    /// opening brace to the matching close. `LivenessWatchdog.swift` declares more than one
    /// type with an `init` of its own, and the I8 claim is about the watchdog's.
    static func body(ofTypeDeclaredBy header: String, in code: String) -> String? {
        guard let declaration = code.range(of: header),
            let open = code[declaration.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// I8: no `Duration` is a parameter of the watchdog's initialiser. There is nothing to
    /// lengthen — D, D_cycle, D_bringUp and the tick are `static let` on `WatchdogLimits`.
    ///
    /// **Mutation:** add a `Duration` parameter to `LivenessWatchdog.init`. Run: red.
    @Test("The watchdog's initialiser takes no Duration")
    func theWatchdogInitTakesNoDuration() throws {
        let initializers = try Self.initializerParameters(in: try watchdogClassBody())
        #expect(!initializers.isEmpty, "the scan found no initialiser at all")
        for parameters in initializers {
            #expect(
                !parameters.contains("Duration"),
                "a Duration parameter would make a bound configurable: \(parameters)")
        }
    }

    private func watchdogClassBody() throws -> String {
        try #require(
            Self.body(
                ofTypeDeclaredBy: "final class LivenessWatchdog: Sendable",
                in: try lifecycleSource("LivenessWatchdog.swift")),
            "LivenessWatchdog is no longer declared as `final class LivenessWatchdog: Sendable`")
    }

    // MARK: - No other way to move a bound

    /// The only parameters `LivenessWatchdog.init` may take, with their types: the six
    /// collaborators, each a *named dependency*. A `Duration` is one way to make a bound
    /// configurable and not the only one — `extraTicks: Int = 0` added to the streak
    /// threshold, a `Double` scale on D — so the rule is the allowlist and not the type.
    static let watchdogInitializerAllowlist: [String: String] = [
        "roundTrips": "SMCRoundTripMonitor",
        "progress": "ThermalCycleProgress",
        "gateMonitor": "GateWaitMonitor",
        "termination": "ProcessTermination",
        "ticks": "any WatchdogTicking",
        "log": "WatchdogLog",
    ]

    /// Splits a parameter list at its top-level commas (a closure type has commas inside its
    /// own parentheses) into `label: Type` pairs, each default value dropped.
    static func labelledParameters(in parameters: String) -> [(label: String, type: String)] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var previous: Character = " "
        for character in parameters {
            switch character {
            case "(", "[", "<": depth += 1
            case ")", "]": depth -= 1
            case ">" where previous != "-": depth -= 1
            default: break
            }
            if character == ",", depth == 0 {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        pieces.append(current)

        return pieces.compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { return nil }
            let names = trimmed[..<colon].split(whereSeparator: \.isWhitespace)
            var type = String(trimmed[trimmed.index(after: colon)...])
            if let equals = type.range(of: " = ") { type = String(type[..<equals.lowerBound]) }
            return (
                label: names.first.map(String.init) ?? "",
                type: type.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Every parameter in `parameters` that is not exactly an allowlisted collaborator, and
    /// every allowlisted collaborator that is missing (a renamed or dropped one would leave the
    /// allowlist describing a different initialiser).
    static func disallowedParameters(
        in parameters: String, allowing allowlist: [String: String]
    ) -> [String] {
        let found = labelledParameters(in: parameters)
        var problems = found.compactMap { parameter -> String? in
            allowlist[parameter.label] == parameter.type
                ? nil : "\(parameter.label): \(parameter.type)"
        }
        for label in allowlist.keys where !found.contains(where: { $0.label == label }) {
            problems.append("missing \(label)")
        }
        return problems.sorted()
    }

    /// I8, the general form: the watchdog's initialiser takes the six collaborators and
    /// **nothing else** — no `Int`, `Double` or `Duration` that a caller could use to move a
    /// bound or a streak, and no new dependency without this list being edited in the same
    /// change, where a reviewer sees it.
    ///
    /// **Mutation:** add `extraTicks: Int = 0` to `LivenessWatchdog.init` and add it to the
    /// streak threshold. Run: red.
    /// **Mutation:** add `scale: Double = 1.0` to `LivenessWatchdog.init`. Run: red.
    /// **Mutation:** delete the `"gateMonitor": "GateWaitMonitor"` entry from the allowlist (the
    /// initialiser's sixth collaborator then reads as something that is not named). Run: red.
    @Test("The watchdog's initialiser takes the named collaborators and nothing else")
    func theWatchdogInitTakesOnlyNamedDependencies() throws {
        let initializers = try Self.initializerParameters(in: try watchdogClassBody())
        #expect(initializers.count == 1, "expected exactly one initialiser: \(initializers)")
        for parameters in initializers {
            let problems = Self.disallowedParameters(
                in: parameters, allowing: Self.watchdogInitializerAllowlist)
            #expect(
                problems.isEmpty,
                """
                LivenessWatchdog.init takes something that is not a named collaborator: \
                \(problems). A number here can lengthen a verdict (ADR 0012 I8).
                """)
        }
    }

    /// The scans above, run over fixtures: a scan that parses nothing allows everything.
    ///
    /// **Mutation:** make `labelledParameters(in:)` return an empty array. Run: red.
    /// **Mutation:** split on every comma, not only the top-level ones. Run: red — the closure
    /// type fixture is cut in two.
    @Test("The initialiser allowlist reads a parameter list the way Swift does")
    func theInitAllowlistParsesParameterLists() {
        let allowed = Self.watchdogInitializerAllowlist
        let clean = """
            roundTrips: SMCRoundTripMonitor,
            progress: ThermalCycleProgress,
            gateMonitor: GateWaitMonitor,
            termination: ProcessTermination,
            ticks: any WatchdogTicking,
            log: WatchdogLog = WatchdogLog()
            """
        #expect(Self.disallowedParameters(in: clean, allowing: allowed).isEmpty)
        #expect(
            Self.disallowedParameters(in: clean + ", extraTicks: Int = 0", allowing: allowed)
                == ["extraTicks: Int"])
        #expect(
            Self.disallowedParameters(in: clean + ", scale: Double = 1.0", allowing: allowed)
                == ["scale: Double"])
        #expect(
            Self.disallowedParameters(in: clean + ", _ d: Duration", allowing: allowed)
                == ["_: Duration"])
        // A collaborator re-typed, and one dropped.
        #expect(
            Self.disallowedParameters(
                in: clean.replacingOccurrences(of: "ProcessTermination", with: "Int"),
                allowing: allowed) == ["termination: Int"])
        #expect(
            Self.disallowedParameters(
                in: clean.replacingOccurrences(of: "GateWaitMonitor", with: "Int"),
                allowing: allowed) == ["gateMonitor: Int"])
        #expect(
            Self.disallowedParameters(
                in: "roundTrips: SMCRoundTripMonitor", allowing: allowed
            ).contains("missing log"))
        // A closure type has commas of its own.
        let closure =
            "makeTimer: @escaping @Sendable (DispatchSource.TimerFlags, DispatchQueue) "
            + "-> any WatchdogTimer = X"
        let parsed = Self.labelledParameters(in: closure)
        #expect(parsed.count == 1)
        #expect(parsed.first?.label == "makeTimer")
    }

    @Test("The initialiser scan reads a parameter list to its closing parenthesis")
    func theInitScanParsesParameterLists() throws {
        func parameters(_ source: String) throws -> [String] {
            try Self.initializerParameters(in: source)
        }
        #expect(try parameters("init(a: Duration)").first?.contains("Duration") == true)
        #expect(
            try parameters("init(\n    roundTrips: X,\n    log: L = L(),\n    d: Duration\n) {}")
                .first?.contains("Duration") == true)
        #expect(try parameters("init (a: Duration) {}").first?.contains("Duration") == true)
        #expect(try parameters("init?(a: Duration) {}").first?.contains("Duration") == true)
        #expect(
            try parameters("init(roundTrips: X, log: L = L()) { self.d = Duration() }").first?
                .contains("Duration") == false)
        #expect(try parameters("func initialise(a: Duration)").isEmpty)
    }

    /// I8, from the other side: the bounds are `static let`. A stored `static var` in
    /// `WatchdogLimits` would be a bound assignable from anywhere in the module at runtime.
    ///
    /// **Mutation:** write `static var roundTrip: Duration = .seconds(5)`. Run: red.
    /// **Mutation:** write `static var gateWaiterAlarm: Duration = roundTrip * 2`. Run: red.
    @Test("The bounds are constants, not assignable variables")
    func theBoundsAreStaticLets() throws {
        let code = try lifecycleSource("WatchdogLimits.swift")
        let storedVar = try NSRegularExpression(
            pattern: #"\bstatic\s+var\s+\w+\s*(:[^={\n]*)?="#)
        let found = storedVar.numberOfMatches(
            in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
        #expect(found == 0, "WatchdogLimits has a stored static var: a bound that can change")
        #expect(code.contains("static let roundTrip"), "the scan no longer finds D")
        #expect(code.contains("static let gateWaiterAlarm"), "the scan no longer finds G")
    }
}
