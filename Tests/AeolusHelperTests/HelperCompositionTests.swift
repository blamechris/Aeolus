import Foundation
import Testing

@testable import AeolusHelper

/// The composition root, guarded at the source.
///
/// ## Why a source tripwire rather than a behavioural test
///
/// `AeolusHelperMain.main()` resolves a code-signing requirement, binds a Mach service and
/// calls `dispatchMain()`, which never returns. There is no seam to drive it through and
/// nothing to assert against afterwards — so the one line of production code #127 changes,
/// `provider: scheduler.snapshotReader`, had **no coverage of any kind**. A review panel
/// demonstrated the cost: reverting that line to the pre-#127 wiring, deleting the entire
/// production effect of the change while leaving the scheduler constructed, left
/// `Test run with 261 tests in 33 suites passed`. The hardware suite included.
///
/// `WritePathAbsenceTests` and `WriteAuthorisationTests` already assert properties of the
/// source tree this way, through `SeamScanner`, for the same reason: some invariants are
/// about what is *written*, and no runtime can observe them.
///
/// ## The hazard this exists for
///
/// Two `SMCReadScheduler`s arbitrate nothing while looking exactly like one that does. Each
/// grants turns against a queue the other cannot see, so the safety cycle and the client
/// snapshot contend exactly as they did before #127 — with all the machinery for fixing it
/// present, tested, and bypassed. `AeolusHelperMain` warns #103 about this in a comment;
/// this is the same warning in a form that fails.
@Suite("The helper's composition root")
struct HelperCompositionTests {

    private static func mainSource() throws -> String {
        let file = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == "AeolusHelperMain.swift" },
            "AeolusHelperMain.swift was not found in Sources")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// **Mutation:** restore the pre-#127 line —
    /// `ReadOnlyFanAuthority(provider: SMCSensorProvider(), …)`. Run: red here, and green
    /// everywhere else in the repository, which is the whole point of the file.
    @Test("The read-only authority is given the scheduler's snapshot reader, not a raw provider")
    func theAuthorityReadsThroughTheScheduler() throws {
        let source = try Self.mainSource()

        #expect(
            source.contains("provider: scheduler.snapshotReader"),
            "the snapshot path no longer takes its turns from the scheduler")

        // The raw provider may appear exactly once, inside the scheduler's own construction.
        // A second occurrence is the authority — or something else — reading around the gate.
        #expect(
            Self.occurrences(of: "SMCSensorProvider(", in: source) == 1,
            "something in the composition root reads the SMC without taking a turn")
        #expect(source.contains("SMCReadScheduler(provider: SMCSensorProvider())"))
    }

    /// **Mutation:** add a second `SMCReadScheduler(provider: SMCSensorProvider())` anywhere
    /// in `Sources/` — which is exactly the shape #103 is at risk of writing when it builds
    /// `SMCFanControlPlane`. Run: red.
    @Test("Exactly one scheduler is constructed in the whole of Sources")
    func onlyOneSchedulerIsEverBuilt() throws {
        var constructions: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = Self.occurrences(of: "SMCReadScheduler(provider:", in: source)
            if count > 0 {
                constructions.append("\(file.lastPathComponent) x\(count)")
            }
        }

        #expect(
            constructions == ["AeolusHelperMain.swift x1"],
            """
            the SMC connection is arbitrated by one scheduler or by none: \(constructions). \
            A second scheduler grants turns against a queue the first cannot see, so the \
            safety cycle and the snapshot contend exactly as they did before #127.
            """)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
