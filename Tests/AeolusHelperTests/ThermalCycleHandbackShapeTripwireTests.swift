import Foundation
import Testing

@testable import AeolusHelper

/// The routes around § 3's handback that no word count and no census sees (#440's review).
///
/// `ThermalCycleHandbackTripwireTests` counts where a view is minted by `admitted(at:)`, and the
/// stored-plane census sees what is held. Neither sees:
///
/// - **a second handback.** `ThermalCycleHandback.init` admits its writer in the lane, so building
///   one is a mint — and one built inside a closure is held by nothing the census walks;
/// - **a laundered mint.** A computed property in the handback's file that returns a lane view
///   keeps every per-file count where it is, and a call site elsewhere then writes in the lane
///   under no lane word;
/// - **a copy through the protocol.** A requirement on `FanRestoring` that hands back a closure
///   over `self`, defaulted in a plain extension, gives the borrower a copy it can keep;
/// - **a copy through the bits.** `withoutActuallyEscaping` and the `Unsafe*` family move a
///   borrowed value out of the move checker's sight.
///
/// So each is held by the shape of the source, failing closed. Every scan reads the same
/// comment-stripped `Sources/AeolusHelper` as `ThermalCycleHandbackTripwireTests`.
///
/// **What these scans are, and are not.** They catch the shapes an edit makes by accident, and
/// claim nothing more: a lexical scan never converges on a deliberate evasion — every round of
/// #436's and #439's review found a new spelling past one. The consequence those spellings would
/// buy, a mechanism other than § 3 writing in § 3's lane, is held by behaviour instead:
/// `SupervisorWriterAdmissionTests`, K6 in `ThermalCycleLaneRoutingTests`, and the reachable
/// stored-plane census in `ThermalCycleLaneWriterTests`.
@Suite("Nothing builds, launders, extends or copies § 3's handback, at the source")
struct ThermalCycleHandbackShapeTripwireTests {

    private static var helperCode: [String: String] {
        get throws { try ThermalCycleHandbackTripwireTests.helperCode.get() }
    }

    private static func uses(of word: String, inCode code: String) throws -> Int {
        try ThermalCycleHandbackTripwireTests.uses(of: word, inCode: code)
    }

    /// Every range of `pattern` in `code`.
    private static func ranges(
        of pattern: String, in code: String
    ) throws -> [Range<String.Index>] {
        try NSRegularExpression(pattern: pattern)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range, in: code) }
    }

    /// Every range of `pattern` in `code` that starts inside `within`.
    private static func ranges(
        of pattern: String, in code: String, within: Range<String.Index>
    ) throws -> [Range<String.Index>] {
        try ranges(of: pattern, in: code).filter { within.contains($0.lowerBound) }
    }

    /// How deeply `index` is nested in braces below `start`.
    private static func depth(
        at index: String.Index, below start: String.Index, in code: String
    ) -> Int {
        code[start..<index].reduce(0) { $0 + ($1 == "{" ? 1 : $1 == "}" ? -1 : 0) }
    }

    /// The bodies of the initialisers declared directly in the braced `body` of `code`, by brace
    /// depth: not one in a nested type, a closure or a method, and not a `.init(…)` call.
    static func memberInitBodies(
        in body: Range<String.Index>, of code: String
    ) throws -> [Range<String.Index>] {
        try ranges(of: #"(?<![A-Za-z0-9_.])init\s*\("#, in: code, within: body)
            .filter { depth(at: $0.lowerBound, below: body.lowerBound, in: code) == 0 }
            .compactMap { TeardownSweepTripwireTests.bracedBody(in: code, after: $0.upperBound) }
    }

    /// `code` with every braced body removed, braces included: what is declared at the top level.
    static func topLevel(of code: String) -> String {
        var depth = 0
        var kept = ""
        for character in code {
            if character == "{" { depth += 1 }
            if depth == 0 { kept.append(character) }
            if character == "}" { depth -= 1 }
        }
        return kept.replacingOccurrences(of: "}", with: "")
    }

    /// The body of the first declaration in `code` matching `header`, a pattern ending at the
    /// point where its parameters or its braces begin.
    static func body(of header: String, in code: String) throws -> Range<String.Index>? {
        guard let declaration = try ranges(of: header, in: code).first else { return nil }
        return TeardownSweepTripwireTests.bracedBody(in: code, after: declaration.upperBound)
    }

    /// The spellings that move a borrowed value's bits out of the move checker's sight.
    static let unsafeSpelling =
        #"(?<![A-Za-z0-9_])(withoutActuallyEscaping|Unsafe[A-Za-z]*Pointer|withUnsafe[A-Za-z]*|"#
        + #"unsafeBitCast|unsafeDowncast|Unmanaged)(?![A-Za-z0-9_])"#

    // MARK: - Positive controls

    /// The scans over fixtures, before any is trusted.
    ///
    /// **Mutation:** in `topLevel(of:)`, keep characters inside braces. Run: red.
    /// **Mutation:** in `memberInitBodies(in:of:)`, drop the depth filter. Run: red — the nested
    /// type's initialiser is found first.
    @Test("The shape scans read their fixtures")
    func theShapeScansReadTheirFixtures() throws {
        #expect(
            Self.topLevel(of: "struct S { let a = 1 }\nextension S { var b: Int { 2 } }")
                == "struct S \nextension S ")
        let code = "struct S { init(x: Int) { y(at: .lane) } func f() { z } }"
        let initBody = try #require(try Self.body(of: #"\binit\s*\("#, in: code))
        #expect(code[initBody].contains("y(at: .lane)") && !code[initBody].contains("z"))
        let nested = "struct S { struct N { init(_ w: W) { a(at: .lane) } } init(x: Int) { y } }"
        let structBody = try #require(try Self.body(of: #"\bstruct\s+S\b"#, in: nested))
        let inits = try Self.memberInitBodies(in: structBody, of: nested)
        #expect(inits.count == 1, "\(inits.count) member initialisers found in the fixture")
        #expect(inits.allSatisfy { nested[$0].contains("y") && !nested[$0].contains("a(at:") })
        for spelling in [
            "withoutActuallyEscaping(body) { $0 }", "UnsafeMutablePointer<H>.allocate(capacity: 1)",
            "withUnsafePointer(to: h) { $0 }", "UnsafeRawPointer(p)",
            "unsafeBitCast(h, to: Int.self)",
            "Unmanaged.passRetained(x)",
        ] {
            #expect(
                try Self.ranges(of: Self.unsafeSpelling, in: spelling).count == 1, "\(spelling)")
        }
        #expect(try Self.ranges(of: Self.unsafeSpelling, in: "let unsafeLane = safeLane").isEmpty)
    }

    // MARK: - Who builds a handback

    /// The names of the type `ThermalCycleHandback`, per file: where it is declared, where § 3
    /// holds and takes it, and where the composition builds it — once. A construction written
    /// anywhere else by the type's name, in any expression and by `.init(…)` too, names it one
    /// more time in some file. A construction under another name — a `typealias`, or an inferred
    /// `Self(…)` — is not a name of it: `noTypealiasNamesTheHandback` and the handback's own shape
    /// close the two spellings an edit reaches for, and the behavioural suites hold the rest.
    ///
    /// **Mutation (CX1):** in `HelperComposition.bringUp()`, build a second handback inside the
    /// signal teardown's closure and restore through it. Run: red — two in the file.
    /// **Mutation (R6):** in `StartupReconciliation.restore(fanAt:)`, restore through a handback
    /// built over its own plane and restorer. Run: red — a file that names the type.
    @Test("Only the composition builds § 3's handback, once")
    func onlyTheCompositionBuildsTheHandback() throws {
        var named: [String: Int] = [:]
        for (file, code) in try Self.helperCode {
            let count = try Self.uses(of: "ThermalCycleHandback", inCode: code)
            if count > 0 { named[file] = count }
        }
        #expect(
            named == [
                "Lease/ThermalCycleHandback.swift": 1, "HelperComposition.swift": 1,
                "Safety/ThermalEmergency.swift": 2,
            ],
            """
            ThermalCycleHandback is named \(named). Building one is minting a lane writer, so it \
            is built once, by the composition, and held by § 3 alone (ADR 0012's #440 amendment).
            """)
    }

    // MARK: - Where the lane is minted

    /// The handback's file declares the handback and nothing else, and its one lane mint is inside
    /// the handback's own `init`: no extension of any type, no second top-level declaration, no
    /// nested type, no `static` member and no `typealias` in its body, and exactly one initialiser
    /// declared directly in that body, found by brace depth.
    ///
    /// **Mutation (L2b):** add `extension SafetyActorWriter { var inTheLane: Self {
    /// admitted(at: .thermalCycle) } }` to the file, build the handback's bound over
    /// `writer.inTheLane`, and write § 5's re-assert through `writer.inTheLane`. Run: red here and
    /// in `SupervisorWriterAdmissionTests`.
    /// **Mutation (C1):** a nested `struct LaneWriter` before the handback's `init`, whose own
    /// `init` admits a writer in the lane. Run: red here — a nested type, and a mint outside the
    /// handback's own `init`.
    /// **Mutation:** a `static func lane(…) -> Self` factory in the handback. Run: red here.
    @Test("The handback's file holds the handback alone, with its mint inside its own init")
    func theHandbacksFileHoldsTheHandbackAlone() throws {
        let code = try #require(try Self.helperCode["Lease/ThermalCycleHandback.swift"])
        #expect(try Self.uses(of: "extension", inCode: code) == 0, "the handback's file extends")
        #expect(
            ThermalCycleHandbackTripwireTests.compacted(Self.topLevel(of: code))
                == "structThermalCycleHandback<Plane:FanControlPlane>:FanRestoring",
            "the handback's file declares more than the handback: \(Self.topLevel(of: code))")
        let structBody = try #require(
            try Self.body(of: #"\bstruct\s+ThermalCycleHandback\b"#, in: code))
        let keywords = "struct|class|enum|actor|protocol|static|typealias"
        let declared = try Self.ranges(
            of: #"(?<![A-Za-z0-9_])("# + keywords + #")(?![A-Za-z0-9_])"#, in: code,
            within: structBody)
        #expect(
            declared.isEmpty,
            "the handback declares \(declared.map { String(code[$0]) }) inside itself")
        let inits = try Self.memberInitBodies(in: structBody, of: code)
        #expect(inits.count == 1, "the handback declares \(inits.count) initialisers")
        let initBody = try #require(inits.first)
        let lane = try Self.ranges(of: #"(?<![A-Za-z0-9_])thermalCycle(?![A-Za-z0-9_])"#, in: code)
        #expect(lane.count == 1, "the handback names the lane \(lane.count) times")
        #expect(
            lane.allSatisfy { initBody.contains($0.lowerBound) },
            "the handback's lane mint is not inside its own init")
    }

    /// No `typealias` anywhere in `Sources/AeolusHelper` names `ThermalCycleHandback`. An alias
    /// is a way to build one without naming the type, which `onlyTheCompositionBuildsTheHandback`
    /// counts by name.
    ///
    /// **Mutation (C1):** `typealias LaneHandback = ThermalCycleHandback` in the composition's
    /// file. Run: red here.
    @Test("No typealias names § 3's handback")
    func noTypealiasNamesTheHandback() throws {
        var aliased: [String] = []
        for (file, code) in try Self.helperCode
        where try !Self.ranges(
            of: #"\btypealias\s+[A-Za-z_]\w*[^=\n]*=[^\n]*\bThermalCycleHandback\b"#, in: code
        ).isEmpty {
            aliased.append(file)
        }
        #expect(aliased.isEmpty, "ThermalCycleHandback is aliased in \(aliased.sorted())")
    }

    /// Every lane naming in the composition's file is inside the composition's `init` — § 3's
    /// telemetry, writer and read-back — and none is in an extension, `production(…)` included.
    ///
    /// **Mutation:** add `extension HelperComposition { var laneWriter: SafetyActorWriter<Plane> {
    /// SafetyActorWriter(plane: plane.admitted(at: .thermalCycle), level: .reclamationWatchdog)
    /// } }`. Run: red here, and at the lane's per-file count.
    @Test("The composition names the lane only inside its init")
    func theCompositionNamesTheLaneOnlyInsideItsInit() throws {
        let code = try #require(try Self.helperCode["HelperComposition.swift"])
        let lane = try Self.ranges(of: #"(?<![A-Za-z0-9_])thermalCycle(?![A-Za-z0-9_])"#, in: code)
        let initBody = try #require(try Self.body(of: #"(?m)^    init\s*\("#, in: code))
        #expect(lane.count == 3, "the composition names the lane \(lane.count) times")
        #expect(
            lane.allSatisfy { initBody.contains($0.lowerBound) },
            "the composition names the lane outside its init")
        for header in try Self.ranges(of: #"(?<![A-Za-z0-9_])extension\s"#, in: code) {
            let extended = try #require(
                TeardownSweepTripwireTests.bracedBody(in: code, after: header.upperBound))
            #expect(
                !lane.contains { extended.contains($0.lowerBound) },
                "an extension in the composition's file names the lane")
        }
    }

    // MARK: - What a borrower can reach

    /// `FanRestoring` has one requirement, and nothing extends it. A borrower of a
    /// `FanRestoring & ~Copyable` generic reaches exactly what the protocol offers, so a second
    /// requirement — one that hands back a closure over `self`, defaulted in a plain extension —
    /// would give it a copy it could keep, with every signature pin green.
    ///
    /// **Mutation (M17):** add `func laneReplay() -> @Sendable (Set<Int>, FanRestoreCause) async
    /// -> Set<Int>` to the protocol, defaulted in `extension FanRestoring` to a closure over
    /// `self`, and keep `handback.laneReplay()` in `LeaseAuthority` for `expireLapsedLeases`. Run:
    /// red here.
    @Test("FanRestoring has one requirement, and nothing extends it")
    func fanRestoringHasOneRequirement() throws {
        let code = try #require(try Self.helperCode["Lease/FanRestoring.swift"])
        let header = try #require(
            try Self.ranges(of: #"\bprotocol\s+FanRestoring\b[^{]*"#, in: code).first)
        #expect(
            ThermalCycleHandbackTripwireTests.compacted(String(code[header]))
                == "protocolFanRestoring:Sendable,~Copyable")
        let body = try #require(
            TeardownSweepTripwireTests.bracedBody(in: code, after: header.upperBound))
        #expect(
            ThermalCycleHandbackTripwireTests.compacted(String(code[body]))
                == "funcrestoreToAutomatic(fans:Set<Int>,becausecause:FanRestoreCause)"
                + "async->Set<Int>",
            "FanRestoring's requirements changed: \(code[body])")
        var extended: [String] = []
        for (file, text) in try Self.helperCode
        where try !Self.ranges(of: #"\bextension\s+FanRestoring\b"#, in: text).isEmpty {
            extended.append(file)
        }
        #expect(extended.isEmpty, "FanRestoring is extended in \(extended.sorted())")
    }

    /// The helper's unsafe spellings, per file, pinned: the two IOKit callback bridges that need
    /// them today — `AeolusHelperMain.swift` and `Lifecycle/SystemPowerObserver.swift` — and
    /// nowhere else. In safe Swift a borrowed parameter cannot be kept; `withoutActuallyEscaping`
    /// and the `Unsafe*` family are where that stops being true, and a borrowed handback can be
    /// forwarded to any generic function in the module, so the ban is helper-wide rather than
    /// `Lease/`'s.
    ///
    /// **Mutation (M14, relocated):** a generic function in `Safety/` that copies a borrowed
    /// `FanRestoring & ~Copyable` value's bytes into an `UnsafeMutablePointer` through
    /// `withUnsafePointer(to:)`, called from `revokeEveryLease` with a closure kept over the copy's
    /// `pointee`. Run: red here — it compiles, and nothing else sees it.
    @Test("Only the IOKit bridges use an unsafe spelling, as often as they do today")
    func onlyTheIOKitBridgesUseUnsafeSpellings() throws {
        var found: [String: Int] = [:]
        for (file, code) in try Self.helperCode {
            let count = try Self.ranges(of: Self.unsafeSpelling, in: code).count
            if count > 0 { found[file] = count }
        }
        #expect(
            found == ["AeolusHelperMain.swift": 2, "Lifecycle/SystemPowerObserver.swift": 4],
            """
            unsafe spellings in the helper: \(found). A new one is a way to keep a borrowed \
            value past its call; acknowledge it here only with a reason no borrowed restorer \
            reaches it.
            """)
    }
}
