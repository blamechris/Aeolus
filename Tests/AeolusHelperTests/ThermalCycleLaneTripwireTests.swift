import Foundation
import Testing

@testable import AeolusHelper

/// § 3's lane is § 3's alone, at the source (ADR 0012's 2026-10-18 amendment).
///
/// ## Why tripwires
///
/// ADR 0010 D2 rejected a third admission class partly because *"a level somebody will use"*: a
/// lane that any mechanism could take would be a lane that slows § 3 again. The amendment answers
/// that with two census tripwires over `Sources/AeolusHelper`, each read on comment-stripped
/// source so a spelling cannot hide a use, each with a positive control so a scan that has quietly
/// stopped seeing anything cannot pass for a clean tree:
///
/// - **The lane is named only where it is wired**: the priority enum, the scheduler, the plane
///   view's `PlaneAdmission`, the composition's § 3 wiring and `HelperFanRestorer`'s routing. The
///   one way to reach a case without naming it, `SMCReadPriority.allCases`, is held to the gate
///   mirror, which reads every priority. No observer has an exhaustive switch over the priority
///   today; one that adds it adds its file here.
/// - **`FanRestoreCause.thermalEmergency` is passed only by § 3**, because it is what routes a
///   restore into the lane (`HelperFanRestorer`).
///
/// And #124's and #295's one-of-each, which the lane's views must not split: one read loop behind
/// § 3's read-back and reconciliation's, held by a census of the plane reads that could be a second
/// copy of it. (The one memo is held by behaviour, in `ThermalCycleLaneSharingTests`.)
@Suite("§ 3's lane is § 3's alone, at the source")
struct ThermalCycleLaneTripwireTests {

    // MARK: - The scans

    /// The files in `Sources/AeolusHelper` whose code names `identifier`, as a whole word, after
    /// every comment is removed.
    static func files(naming identifier: String) throws -> Set<String> {
        var found: Set<String> = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            if try names(identifier, inSource: source) { found.insert(file.lastPathComponent) }
        }
        return found
    }

    /// Whether `source`'s code names `identifier` as a whole word. A dot and whitespace around
    /// it change nothing, because an identifier cannot be split.
    static func names(_ identifier: String, inSource source: String) throws -> Bool {
        let code = SeamScanner.strippingAllComments(source)
        let word = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])"# + identifier + #"(?![A-Za-z0-9_])"#)
        return word.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    /// How many times `source`'s code passes § 3's restore cause: as a `because:` or `cause:`
    /// argument, qualified by its type anywhere, or as the value of a binding typed as the
    /// cause. Read with every comment and every whitespace character removed, so a line break or
    /// a space inside the expression changes nothing. A `case .thermalEmergency:` in a switch is
    /// a match, not a pass, and so is the safety actor level of the same name.
    static func causePasses(inSource source: String) throws -> Int {
        let code = SeamScanner.strippingAllComments(source).filter { !$0.isWhitespace }
        let pass = try NSRegularExpression(
            pattern: #"(?:(?:because|cause):|FanRestoreCause\.|:FanRestoreCause=)\.?"#
                + #"thermalEmergency(?![A-Za-z0-9_])"#)
        return pass.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// Every file in `Sources/AeolusHelper` that passes § 3's restore cause, with its count.
    static func causePassers() throws -> [String: Int] {
        var found: [String: Int] = [:]
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let count = try causePasses(inSource: try String(contentsOf: file, encoding: .utf8))
            if count > 0 { found[file.lastPathComponent] = count }
        }
        return found
    }

    // MARK: - Positive controls

    /// The scans themselves, over fixtures, before either is trusted: every spelling of a use is
    /// seen, a comment is not, and a longer identifier is not the lane.
    ///
    /// **Mutation:** in `names(_:inSource:)`, scan the source without stripping comments. Run:
    /// red — the comment counts as a use.
    /// **Mutation:** drop the whole-word guards from the lane's pattern. Run: red —
    /// `thermalCycleWaiters` counts as the lane.
    /// **Mutation:** in `causePasses(inSource:)`, keep the whitespace. Run: red — the split
    /// argument is missed.
    @Test("The scans see every spelling of a use and nothing that is not one")
    func theScansSeeEverySpelling() throws {
        for use in [
            "let p = SMCReadPriority.thermalCycle", "x(at:\n    .thermalCycle)",
            "case .thermalCycle: break", "SMCReadPriority . thermalCycle",
            "view.admitted(at: PlaneAdmission.thermalCycle)",
        ] {
            #expect(try Self.names("thermalCycle", inSource: use), "missed: \(use)")
        }
        for notUse in [
            "// .thermalCycle", "/* SMCReadPriority.thermalCycle */", "var thermalCycleWaiters = 0",
            "ThermalCycleProgress()", "WatchdogLimits.thermalCycleTurns(fans: 2)",
        ] {
            #expect(try !Self.names("thermalCycle", inSource: notUse), "counted: \(notUse)")
        }

        #expect(try Self.causePasses(inSource: "revoke(because: .thermalEmergency)") == 1)
        #expect(try Self.causePasses(inSource: "revoke(\n  because:\n    .thermalEmergency)") == 1)
        #expect(try Self.causePasses(inSource: "let c = FanRestoreCause.thermalEmergency") == 1)
        #expect(try Self.causePasses(inSource: "let c: FanRestoreCause = .thermalEmergency") == 1)
        #expect(try Self.causePasses(inSource: "restore(fans: f, cause: .thermalEmergency)") == 1)
        #expect(try Self.causePasses(inSource: "// because: .thermalEmergency") == 0)
        #expect(try Self.causePasses(inSource: "case .thermalEmergency: return lane") == 0)
        #expect(try Self.causePasses(inSource: "level: .thermalEmergency") == 0)
        #expect(try Self.causePasses(inSource: "because: .thermalEmergencyLater") == 0)
    }

    // MARK: - The censuses

    /// `SMCReadPriority.thermalCycle` and `PlaneAdmission.thermalCycle` are named in exactly the
    /// files that wire the lane, and `SMCReadPriority.allCases` only in the gate mirror. The file
    /// discovery is checked too: the census is a set equality, so a scan that found no files fails
    /// rather than passing for a clean tree.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.swift`, add
    /// `private let laneForTheWire = PlaneAdmission.thermalCycle`. Run: red.
    /// **Mutation:** break the file discovery — scan `under: "AeolusHelperX"`. Run: red.
    @Test("The lane is named only where it is wired")
    func theLaneIsNamedOnlyWhereItIsWired() throws {
        #expect(try SeamScanner.swiftFiles(under: "AeolusHelper").count > 50)
        let named = try Self.files(naming: "thermalCycle")
        #expect(
            named == [
                "SMCReadPriority.swift", "SMCReadScheduler.swift", "PlaneAdmission.swift",
                "HelperComposition.swift", "HelperFanRestorer.swift",
            ],
            """
            § 3's lane is named in \(named.sorted()). It is § 3's alone (ADR 0012's 2026-10-18 \
            amendment): a mechanism that takes it slows § 3 again. Wire a new user through ADR \
            review, not here.
            """)

        var everyCase: Set<String> = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingAllComments(
                try String(contentsOf: file, encoding: .utf8))
            if code.filter({ !$0.isWhitespace }).contains("SMCReadPriority.allCases") {
                everyCase.insert(file.lastPathComponent)
            }
        }
        #expect(
            everyCase == ["GateWaitMonitor.swift"],
            "the priorities are enumerated in \(everyCase.sorted()), which reaches the lane unnamed"
        )
    }

    /// § 3's restore cause is passed three times, all in `ThermalEmergency.swift`: `fire`'s
    /// revocation, take-back's, and the empty-registry take-back's. It is the key
    /// `HelperFanRestorer` routes into the lane by.
    ///
    /// **Mutation:** in `ReclamationWatchdog.swift`, pass `.thermalEmergency` for
    /// `.systemReclaimed`. Run: red.
    /// **Mutation:** break the file discovery — scan `under: "AeolusHelperX"`. Run: red.
    @Test("§ 3's restore cause is passed only by § 3")
    func theEmergencyCauseIsPassedOnlyBySectionThree() throws {
        let passers = try Self.causePassers()
        #expect(
            passers == ["ThermalEmergency.swift": 3],
            """
            FanRestoreCause.thermalEmergency is passed by \(passers). It routes a restore into \
            § 3's lane, so only § 3 may pass it.
            """)
    }

    /// One read loop serves § 3's lane reader and reconciliation (#295): `PlaneHandbackReadBack`,
    /// which `StartupReconciliation` runs over its own plane and hands § 3 over the lane view. A
    /// second copy of that loop is a second `readControlState` call, so the calls are counted file
    /// by file. `ThermalCycleLaneSharingTests` holds that the two read the same.
    ///
    /// **Mutation:** in `StartupReconciliation.swift`, give `handbackReadBack(admittedAt:)` a
    /// private reader of its own with a copy of the loop. Run: red — four calls in the file.
    @Test("The handback read loop has one copy")
    func theHandbackReadLoopHasOneCopy() throws {
        var calls: [String: Int] = [:]
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = try SeamScanner.mentions(of: "readControlState", inSource: source)
            if count > 0 { calls[file.lastPathComponent] = count }
        }
        #expect(
            calls == [
                "FanModeSensing.swift": 1, "ReconciliationBaseline.swift": 1,
                "ReclamationWatchdog.swift": 1, "StartupReconciliation.swift": 3,
            ],
            """
            a control-state read was added or moved: \(calls). If it is a second copy of the \
            handback loop, use `PlaneHandbackReadBack`; otherwise acknowledge it here.
            """)
    }
}
