import Foundation
import Testing

@testable import AeolusHelper

/// § 3's lane is § 3's alone, at the source (ADR 0012's 2026-10-18 amendment).
///
/// ## Why tripwires, and why they count
///
/// ADR 0010 D2 rejected a third admission class partly because *"a level somebody will use"*: a
/// lane that any mechanism could take would be a lane that slows § 3 again. The amendment answers
/// that with censuses over `Sources/AeolusHelper`, each read on comment-stripped source and each a
/// **count per file**, pinned. A file-level census lets a second use into a file that already has
/// one; a count does not, whatever expression the use sits in — a ternary, a computed property, a
/// default argument or a helper in the same file all add one. Two words are counted:
///
/// - **`thermalCycle`**, the lane's case in `SMCReadPriority` and in `PlaneAdmission`: declared,
///   mapped and queued in the scheduler, and named by the composition's § 3 wiring and by
///   `ThermalCycleHandback`, the restorer § 3 holds in the lane (#440). The one way to reach a case
///   without naming it, `allCases`, is counted too, and is held to the gate mirror.
/// - **`thermalEmergencyRevocation`**, § 3's restore cause. Since #440 it routes nothing — the lane
///   is reached by holding the handback, which `ThermalCycleHandbackTripwireTests` holds at the
///   source — so its count is provenance: who may label a restore as § 3's. Named for the
///   revocation so that the word is the cause's alone — `SafetyActorLevel` has a
///   `thermalEmergency` — and counted as a word for the same reason as the lane.
///
/// And #124's and #295's one-of-each, which the lane's views must not split: one read loop behind
/// § 3's read-back and reconciliation's, held by a census of where `PlaneHandbackReadBack` is
/// built. (The one memo is held by behaviour, in `ThermalCycleLaneSharingTests`, and § 3's reader
/// by type there too.) A source tree that SwiftPM compiles and the scan cannot see would make every
/// count here a count of part of the tree, so no symbolic link is allowed under `Sources`.
///
/// The censuses cover `Sources/AeolusHelper` and no other target: every type they name is internal
/// to that module, so no other target can spell a use.
@Suite("§ 3's lane is § 3's alone, at the source")
struct ThermalCycleLaneTripwireTests {

    // MARK: - The scans

    /// Every file in `Sources/AeolusHelper`, by name, with its comments removed — read and
    /// stripped **once** for the whole suite.
    ///
    /// Stripping is a walk over every character of every helper file, and this suite runs beside
    /// the XPC suites, whose deadlines are wall clock: on a three-core runner, four walks of the
    /// tree where one will do is load those suites pay for. A `static let` is initialised once,
    /// on first use, whichever test touches it first.
    private static let helperCode: Result<[String: String], any Error> = Result {
        var code: [String: String] = [:]
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            code[file.lastPathComponent] = SeamScanner.strippingAllComments(source)
        }
        return code
    }

    /// How many times `source`'s code names `identifier` as a whole word, after every comment is
    /// removed. A dot and whitespace around it change nothing, because an identifier cannot be
    /// split.
    static func uses(of identifier: String, inSource source: String) throws -> Int {
        try uses(of: identifier, inCode: SeamScanner.strippingAllComments(source))
    }

    /// `uses(of:inSource:)` over code whose comments are already removed.
    private static func uses(of identifier: String, inCode code: String) throws -> Int {
        try wholeWord(identifier).numberOfMatches(
            in: code, range: NSRange(code.startIndex..., in: code))
    }

    private static func wholeWord(_ identifier: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])"# + identifier + #"(?![A-Za-z0-9_])"#)
    }

    /// Every file in `Sources/AeolusHelper` whose code names `identifier`, with its count.
    static func census(of identifier: String) throws -> [String: Int] {
        var found: [String: Int] = [:]
        for (name, code) in try helperCode.get() {
            let count = try uses(of: identifier, inCode: code)
            if count > 0 { found[name] = count }
        }
        return found
    }

    /// How many times `source` builds a `PlaneHandbackReadBack` — a call of its name, with or
    /// without generic arguments and with any whitespace before the parenthesis — after every
    /// comment is removed. Whitespace is matched rather than removed, so `await` before the name
    /// does not join it into one word.
    static func readBackConstructions(inSource source: String) throws -> Int {
        try readBackConstructions(inCode: SeamScanner.strippingAllComments(source))
    }

    private static func readBackConstructions(inCode code: String) throws -> Int {
        let built = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])PlaneHandbackReadBack\s*(?:<[^()]*>)?\s*\("#)
        return built.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    // MARK: - Positive controls

    /// The scans themselves, over fixtures, before either is trusted. Every fixture of a use is
    /// counted, a comment is not, and a longer identifier is not the word. The cause's fixtures
    /// are the spellings a review found a pattern-matching scan missed — a ternary, a computed
    /// property, a return, an array literal, `??`, a `static var` in an extension, a reassignment,
    /// a line break — which a count of the word cannot miss, because each of them spells it.
    ///
    /// **Mutation:** in `uses(of:inSource:)`, count the source without stripping comments. Run:
    /// red — the comment counts as a use.
    /// **Mutation:** drop the whole-word guards from `wholeWord(_:)`. Run: red —
    /// `thermalCycleWaiters` counts as the lane.
    @Test("The scans count every use in their fixtures and nothing that is not one")
    func theScansCountTheirFixtures() throws {
        for use in [
            "let p = SMCReadPriority.thermalCycle", "x(at:\n    .thermalCycle)",
            "case .thermalCycle: break", "SMCReadPriority . thermalCycle",
            "view.admitted(at: PlaneAdmission.thermalCycle)",
            "static var lane: PlaneAdmission { .thermalCycle }",
            "func read(keys: [String], at priority: SMCReadPriority = .thermalCycle)",
        ] {
            #expect(try Self.uses(of: "thermalCycle", inSource: use) == 1, "missed: \(use)")
        }
        for notUse in [
            "// .thermalCycle", "/* SMCReadPriority.thermalCycle */", "var thermalCycleWaiters = 0",
            "ThermalCycleProgress()", "WatchdogLimits.thermalCycleTurns(fans: 2)",
            "case thermalCycleLaneOverlapped(outstanding: Int)",
        ] {
            #expect(try Self.uses(of: "thermalCycle", inSource: notUse) == 0, "counted: \(notUse)")
        }

        let cause = "thermalEmergencyRevocation"
        for use in [
            "revoke(because: .thermalEmergencyRevocation)",
            "revoke(\n  because:\n    .thermalEmergencyRevocation)",
            "revoke(because: hot ? .thermalEmergencyRevocation : .leaseExpired)",
            "private var restoreCause: FanRestoreCause { .thermalEmergencyRevocation }",
            "case true: return .thermalEmergencyRevocation",
            "for cause in [FanRestoreCause.leaseExpired, .thermalEmergencyRevocation] {",
            "revoke(because: override ?? .thermalEmergencyRevocation)",
            "extension FanRestoreCause { static var lane: Self { .thermalEmergencyRevocation } }",
            "reassigned = .thermalEmergencyRevocation",
        ] {
            #expect(try Self.uses(of: cause, inSource: use) == 1, "missed: \(use)")
        }
        for notUse in [
            "// because: .thermalEmergencyRevocation", "/* .thermalEmergencyRevocation */",
            "SafetyActorWriter(plane: plane, level: .thermalEmergency)",
            "because: .thermalEmergencyRevocationLater",
        ] {
            #expect(try Self.uses(of: cause, inSource: notUse) == 0, "counted: \(notUse)")
        }

        #expect(try Self.readBackConstructions(inSource: "PlaneHandbackReadBack(sensing: p)") == 1)
        #expect(
            try Self.readBackConstructions(inSource: "await PlaneHandbackReadBack(sensing: p).r()")
                == 1)
        #expect(
            try Self.readBackConstructions(inSource: "PlaneHandbackReadBack<P> (\n sensing: p)")
                == 1)
        #expect(try Self.readBackConstructions(inSource: "-> PlaneHandbackReadBack<Plane> {") == 0)
        #expect(try Self.readBackConstructions(inSource: "struct PlaneHandbackReadBack<S>:") == 0)
    }

    // MARK: - The censuses

    /// The lane is named only where it is wired, and as often as it is wired: declared in
    /// `SMCReadPriority` and `PlaneAdmission` (whose mapping names it twice more), mapped to its
    /// queue once in the scheduler (`queue(for:)`, which queuing, counting and reporting all go
    /// through), given to § 3's telemetry, writer and read-back in the composition, and taken by
    /// `ThermalCycleHandback`'s bound, which § 3 holds and lends (#440). The restorer names it no
    /// longer. A case that reaches the lane under another name is the value-set pin's
    /// (`ThermalCycleLaneValueSetTests`), not this count's.
    ///
    /// **Mutation:** in `ReclamationWatchdog.swift`, add
    /// `private var laneWriter: SafetyActorWriter<Plane> { writer.admitted(at: .lane) }`, with
    /// `static var lane: PlaneAdmission { .thermalCycle }` in `PlaneAdmission`. Run: red — one
    /// more in `PlaneAdmission.swift`.
    /// **Mutation:** in `HelperComposition.init`, build § 5's writer over
    /// `plane.admitted(at: .thermalCycle)`. Run: red — four in the file.
    /// **Mutation:** default `SMCReadScheduler.read(keys:at:)`'s priority to `.thermalCycle`.
    /// Run: red — two in the file.
    /// **Mutation:** break the file discovery — scan `under: "AeolusHelperX"`. Run: red.
    @Test("The lane is named only where it is wired, as often as it is wired")
    func theLaneIsNamedOnlyWhereItIsWired() throws {
        #expect(try Self.helperCode.get().count > 50, "the scan found too few helper files")
        let named = try Self.census(of: "thermalCycle")
        // Adding a file here, or raising a count, is an ADR 0012 amendment and a safety review
        // (#332): a new lane site lands with a few visible edits and nothing else red, so this
        // list is the review signal.
        #expect(
            named == [
                "SMCReadPriority.swift": 1, "PlaneAdmission.swift": 3, "SMCReadScheduler.swift": 1,
                "HelperComposition.swift": 3, "ThermalCycleHandback.swift": 1,
            ],
            """
            § 3's lane is named \(named). It is § 3's alone (ADR 0012's 2026-10-18 amendment): a \
            mechanism that takes it slows § 3 again. Wire a new user through ADR review, not here.
            """)
    }

    /// No helper code enumerates an enum's cases but the gate mirror, which reads every priority.
    /// An enumeration reaches a case without naming it: `SMCReadPriority.allCases` reaches the
    /// lane, and `FanRestoreCause.allCases` — the enum is `CaseIterable` for a test — reaches § 3's
    /// cause label, which since #440 routes nothing but still says who restored. Counted as a word,
    /// so a type alias or a metatype in front of it changes nothing.
    ///
    /// **Mutation:** in `ConnectionHealth.swift`, add `private typealias Priority =
    /// SMCReadPriority` and `private let everyPriority = Priority.allCases`. Run: red.
    /// **Mutation:** add `private let everyPriority = SMCReadPriority.self.allCases` there
    /// instead. Run: red.
    @Test("Only the gate mirror enumerates a helper enum's cases")
    func onlyTheGateMirrorEnumeratesCases() throws {
        let enumerations = try Self.census(of: "allCases")
        #expect(
            enumerations == ["GateWaitMonitor.swift": 1],
            """
            cases are enumerated \(enumerations). An enumeration of SMCReadPriority reaches § 3's \
            lane, and one of FanRestoreCause § 3's cause label, without naming either.
            """)
    }

    /// § 3's restore cause is named where it is declared, logged, and labelled: once in the lease
    /// core, by `revokeEveryLease(handingBackThrough:)`, which fixes it for § 3's revocation
    /// (#440).
    /// § 3 passes no cause and the restorer switches on none. It is a label, so this count is
    /// provenance — a mechanism that labelled its own restore as § 3's would be one an operator
    /// reading `log show` mistook for § 3 — and not a route: a stored and replayed cause reaches
    /// no lane (`ThermalCycleLaneRoutingTests`). `LeaseLog.swift` is the one logging file that
    /// names it: its exhaustive switch describes every cause for the lease log's line. `SafetyLog`
    /// describes no cause.
    ///
    /// **Mutation:** in `ReclamationWatchdog.swift`, give § 5's blind-fan release
    /// `because: restoreCause` with `private var restoreCause: FanRestoreCause {
    /// .thermalEmergencyRevocation }`. Run: red.
    /// **Mutation:** in `LeaseAuthority.swift`, label `revokeLeases(coveringFan:because:)`'s line
    /// with it too. Run: red — two in the file.
    @Test("§ 3's restore cause is named only where it is labelled, as often as it is labelled")
    func theEmergencyCauseIsNamedOnlyWhereItIsWired() throws {
        let named = try Self.census(of: "thermalEmergencyRevocation")
        #expect(
            named == ["FanRestoring.swift": 1, "LeaseAuthority.swift": 1, "LeaseLog.swift": 1],
            """
            FanRestoreCause.thermalEmergencyRevocation is named \(named). It labels § 3's \
            revocation, which the lease core fixes; nothing else may claim to be § 3.
            """)
    }

    /// One read loop serves § 3's lane reader and reconciliation (#295): `PlaneHandbackReadBack`,
    /// which `StartupReconciliation` builds twice — over its own plane, and over the lane view it
    /// hands § 3 — and nothing else builds. A second copy of the loop reading through any verb is
    /// a reader that is not this one, and `ThermalCycleLaneSharingTests` pins § 3's by type.
    ///
    /// **Mutation:** in `StartupReconciliation.handbackReadBack(admittedAt:)`, return a reader of
    /// its own whose loop reads through `readMode(ofFan:)`. Run: red — one construction.
    @Test("The handback read loop is built only by reconciliation")
    func theHandbackReadLoopIsBuiltOnlyByReconciliation() throws {
        var built: [String: Int] = [:]
        for (name, code) in try Self.helperCode.get() {
            let count = try Self.readBackConstructions(inCode: code)
            if count > 0 { built[name] = count }
        }
        #expect(
            built == ["StartupReconciliation.swift": 2],
            """
            PlaneHandbackReadBack is built \(built). One loop serves § 3 and reconciliation \
            (#295); a second reader is a second copy of it.
            """)
    }

    /// Nothing under `Sources` is a symbolic link. SwiftPM compiles a target's sources through a
    /// linked directory, and `FileManager`'s enumerator does not descend into one, so a linked
    /// directory is code every census here compiles and none of them reads.
    ///
    /// **Mutation:** link `Sources/AeolusHelper/LaneExtras` to a directory holding a file that
    /// names `PlaneAdmission.thermalCycle`. Run: red here — and green in every census.
    @Test("Nothing under Sources is a symbolic link the scans cannot follow")
    func nothingUnderSourcesIsASymbolicLink() throws {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: SeamScanner.sourcesRoot, includingPropertiesForKeys: [.isSymbolicLinkKey]))
        var links: [String] = []
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                links.append(url.path)
            }
        }
        #expect(seen > 50, "the walk saw \(seen) entries under Sources")
        #expect(links.isEmpty, "symbolic links under Sources, which no scan reads: \(links)")
    }
}
