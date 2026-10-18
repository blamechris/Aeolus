import Foundation
import Testing

@testable import AeolusHelper

/// § 3's lane is held by § 3 and lent for one call, at the source (#440).
///
/// ADR 0012's #440 amendment holds the lane four ways: the value sets by the compiler, the uses by
/// per-file counts (`ThermalCycleLaneTripwireTests`), what is held by the stored-plane census at
/// rest and after a firing (`ThermalCycleLaneWriterTests`), and what is lent by the compiler —
/// a `borrowing` parameter of a generic that suppresses `Copyable` cannot be kept. This suite holds
/// the source half of the last, and the sites around it:
///
/// - a view is minted only in the composition and in `ThermalCycleHandback`;
/// - the lease core's files and the restorer name no admission, priority or view;
/// - `revokeEveryLease(handingBackThrough:)` is called only from § 3;
/// - the three lending signatures keep `borrowing` and `~Copyable`. Dropping `borrowing` alone does
///   not compile, but dropping `~Copyable` from `revokeEveryLease`'s or `handBack`'s constraint
///   does, and so does dropping both words together.
///
/// `ThermalCycleHandbackShapeTripwireTests` holds the rest: who builds a handback, the handback
/// file's shape, `FanRestoring`'s one requirement, and the unsafe spellings `Lease/` may not use.
/// Every scan reads comment-stripped source under `Sources/AeolusHelper`.
@Suite("§ 3's lane is held by § 3 and lent, at the source")
struct ThermalCycleHandbackTripwireTests {

    /// Every file in `Sources/AeolusHelper`, by its path below that directory, with its comments
    /// removed — read and stripped once, for `ThermalCycleLaneTripwireTests.helperCode`'s reason.
    /// `ThermalCycleHandbackShapeTripwireTests` reads the same scan.
    static let helperCode: Result<[String: String], any Error> = Result {
        var code: [String: String] = [:]
        let marker = "/Sources/AeolusHelper/"
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let path = file.path
            guard let range = path.range(of: marker, options: .backwards) else {
                Issue.record("\(path) is not under \(marker)")
                continue
            }
            let source = try String(contentsOf: file, encoding: .utf8)
            code[String(path[range.upperBound...])] = SeamScanner.strippingAllComments(source)
        }
        return code
    }

    // MARK: - The scans

    /// Every view `code` mints: the argument of each `admitted(at:)` or `admittedAt:` call, up to
    /// the comma or parenthesis that ends it, with any whitespace and line breaks around it. A
    /// declaration (`func admitted(at admission: PlaneAdmission)`) is not a call and is not read.
    static func mints(inCode code: String) throws -> [String] {
        let call = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])(?:admitted\s*\(\s*at|admittedAt)\s*:\s*([^,()]+)"#)
        return call.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range(at: 1), in: code).map {
                code[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// How many times `code` names `identifier` as a whole word.
    static func uses(of identifier: String, inCode code: String) throws -> Int {
        try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])"# + identifier + #"(?![A-Za-z0-9_])"#)
            .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// `code` with every whitespace character removed, so a signature reads the same however it
    /// is wrapped or indented. Comparing a whole signature this way cannot match a different one.
    static func compacted(_ code: String) -> String {
        code.filter { !$0.isWhitespace }
    }

    /// The words that name admission: its type, the scheduler's priority, a view's mint, and the
    /// lane itself.
    private static let admissionWords = [
        "PlaneAdmission", "SMCReadPriority", "admitted", "admittedAt", "thermalCycle",
    ]

    /// The one parameter name a view's admission is forwarded under: the plane's, the writer's,
    /// the telemetry's and reconciliation's `admitted(at:)` each pass their own on to the plane.
    private static let forwarded = "admission"

    // MARK: - Positive controls

    /// The scans over fixtures, before any is trusted.
    ///
    /// **Mutation:** in `mints(inCode:)`, require `at:` with no space before the colon's argument.
    /// Run: red — the wrapped call is missed.
    @Test("The scans read their fixtures")
    func theScansReadTheirFixtures() throws {
        for (use, argument) in [
            ("plane.admitted(at: .thermalCycle)", ".thermalCycle"),
            ("x.admitted (\n  at:\n    .thermalCycle), level: l", ".thermalCycle"),
            ("handbackReadBack(admittedAt: .thermalCycle)", ".thermalCycle"),
            ("view.admitted(at: PlaneAdmission.thermalCycle)", "PlaneAdmission.thermalCycle"),
            ("plane.admitted(at: admission)", "admission"),
        ] {
            #expect(try Self.mints(inCode: use) == [argument], "misread: \(use)")
        }
        for notAMint in [
            "func admitted(at admission: PlaneAdmission) -> Self",
            "func handbackReadBack(admittedAt admission: PlaneAdmission) -> R",
            "let readmitted = at",
        ] {
            #expect(try Self.mints(inCode: notAMint).isEmpty, "counted: \(notAMint)")
        }
        #expect(
            Self.compacted("func f<T: P & ~Copyable>(\n  x: borrowing T\n) async")
                == "funcf<T:P&~Copyable>(x:borrowingT)async")
    }

    // MARK: - Minting

    /// Every view `Sources/AeolusHelper` mints is § 3's, and is minted in the composition — § 3's
    /// telemetry, writer and read-back — or in `ThermalCycleHandback`, its lane bound. Every other
    /// call forwards the admission it was given.
    ///
    /// **Mutation (K7a):** in `HelperFanRestorer.init`, build a second bound over
    /// `writer.admitted(at: .thermalCycle)`. Run: red — a mint in `Lease/HelperFanRestorer.swift`,
    /// and red in `theLeaseCoreAndTheRestorerKnowNoAdmission`.
    @Test("A lane view is minted only in the composition and in § 3's handback")
    func theLaneIsMintedOnlyInTheCompositionAndTheHandback() throws {
        let code = try Self.helperCode.get()
        #expect(code.count > 50, "the scan found too few helper files")
        var minted: [String: [String]] = [:]
        var forwarding: Set<String> = []
        for (file, text) in code {
            for argument in try Self.mints(inCode: text) {
                if argument == Self.forwarded {
                    forwarding.insert(file)
                } else {
                    minted[file, default: []].append(argument)
                }
            }
        }
        #expect(
            minted == [
                "HelperComposition.swift": Array(repeating: ".thermalCycle", count: 3),
                "Lease/ThermalCycleHandback.swift": [".thermalCycle"],
            ],
            """
            views are minted \(minted). § 3's lane is minted where § 3 is wired and in the \
            handback § 3 holds (ADR 0012's #440 amendment); a mint anywhere else is a second \
            producer.
            """)
        #expect(!forwarding.isEmpty, "no call forwards an admission: the scan read nothing")
    }

    /// Neither the lease core nor the restorer knows about admission: no file under `Lease/` but
    /// `ThermalCycleHandback.swift` names `PlaneAdmission`, `SMCReadPriority`, a view's mint, or
    /// the lane. Only the composition, which mints views, the handback, and the plane, which
    /// honours them, know admission.
    ///
    /// **Mutation (K7a):** the restorer's second bound, as above. Run: red, naming
    /// `admitted` and `thermalCycle` in `Lease/HelperFanRestorer.swift`.
    /// **Mutation:** add `private let admission: PlaneAdmission = .supervisor` to `LeaseAuthority`.
    /// Run: red.
    @Test("The lease core and the restorer name no admission, priority or view")
    func theLeaseCoreAndTheRestorerKnowNoAdmission() throws {
        let lease = try Self.helperCode.get().filter {
            $0.key.hasPrefix("Lease/") && $0.key != "Lease/ThermalCycleHandback.swift"
        }
        #expect(lease.count > 10, "the scan found \(lease.count) lease-core files")
        #expect(lease["Lease/LeaseAuthority.swift"] != nil)
        #expect(lease["Lease/HelperFanRestorer.swift"] != nil)
        var named: [String: [String]] = [:]
        for (file, text) in lease {
            for word in Self.admissionWords where try Self.uses(of: word, inCode: text) > 0 {
                named[file, default: []].append(word)
            }
        }
        #expect(
            named.isEmpty,
            """
            the lease core names admission: \(named). § 3's lane is reached by holding the \
            handback § 3 lends, and the lease core must not be able to reach it any other way.
            """)
    }

    // MARK: - Lending

    /// `revokeEveryLease(handingBackThrough:)` is declared once, in the lease core, and called only
    /// by § 3 — `fire`'s revocation, take-back's and the empty-registry take-back's. And
    /// `HelperFanRestorer.handBack(_:because:through:)`, which a lent bound runs through, is called
    /// only by the restorer's own `restoreToAutomatic` and by the handback. (Several mechanisms
    /// declare a `handBack(fanAt:)` of their own; those are a different verb, and are not counted.)
    ///
    /// **Mutation:** in `SystemPowerResponder`'s handback, replace `releaseEveryLease()` with
    /// `revokeEveryLease(handingBackThrough:)` lending a bound over its own writer. Run: red.
    @Test("Only § 3 lends to the lease core, and only the handback lends to the restorer")
    func onlySectionThreeLends() throws {
        let revocations = try ThermalCycleLaneTripwireTests.census(of: "revokeEveryLease")
        #expect(
            revocations == ["LeaseAuthority.swift": 1, "ThermalEmergency.swift": 3],
            "revokeEveryLease is named \(revocations); only § 3 lends its handback to it")
        let lending = try NSRegularExpression(pattern: #"handBack(?:<[^>]*>)?\((?!fanAt)"#)
        var handBacks: [String: Int] = [:]
        for (file, text) in try Self.helperCode.get() {
            let compact = Self.compacted(text)
            let count = lending.numberOfMatches(
                in: compact, range: NSRange(compact.startIndex..., in: compact))
            if count > 0 { handBacks[file] = count }
        }
        #expect(
            handBacks == [
                "Lease/HelperFanRestorer.swift": 2, "Lease/ThermalCycleHandback.swift": 1,
            ],
            "the restorer's lending verb is named \(handBacks)")
    }

    /// The three lending signatures, compacted: each borrows a parameter of a generic constrained
    /// `FanRestoring & ~Copyable`. Dropping `~Copyable` from `revokeEveryLease`'s or `handBack`'s
    /// constraint still compiles — a copyable argument satisfies either signature — and so does
    /// dropping it with `borrowing`; either makes the parameter one the callee can keep, so the
    /// source is where that is held. (`borrowing` alone cannot be dropped: a noncopyable generic
    /// parameter must state its ownership. `restore(_:because:through:)` refuses losing either
    /// word, because the verb lends it a noncopyable generic.) Each verb is declared exactly as
    /// often as it is pinned, so an overload beside a pinned signature fails too.
    ///
    /// **Mutation (K7b):** drop `& ~Copyable` from `HelperFanRestorer.handBack`'s constraint.
    /// Run: red. **Mutation (K7c):** drop `borrowing` and `& ~Copyable` from `revokeEveryLease`.
    /// Run: red. Dropping `borrowing` alone does not compile — a parameter of a noncopyable
    /// generic must state its ownership — so the pin is for the pair, and for `~Copyable` alone.
    @Test("The three lending signatures borrow a noncopyable generic")
    func theLendingSignaturesBorrowANoncopyableGeneric() throws {
        let code = try Self.helperCode.get()
        let authority = Self.compacted(try #require(code["Lease/LeaseAuthority.swift"]))
        let restorer = Self.compacted(try #require(code["Lease/HelperFanRestorer.swift"]))
        let pinned: [(String, String)] = [
            (
                authority,
                "funcrevokeEveryLease<Handback:FanRestoring&~Copyable>("
                    + "handingBackThroughhandback:borrowingHandback)async"
            ),
            (
                authority,
                "privatefuncrestore<Handback:FanRestoring&~Copyable>(_fans:Set<Int>,"
                    + "becausecause:FanRestoreCause,throughhandback:borrowingHandback)async"
            ),
            (
                restorer,
                "funchandBack<Bound:FanRestoring&~Copyable>(_fans:Set<Int>,"
                    + "becausecause:FanRestoreCause,throughbound:borrowingBound)async->Set<Int>"
            ),
        ]
        for (file, signature) in pinned {
            #expect(file.contains(signature), "a lending signature changed: \(signature)")
        }

        func declarations(_ pattern: String, in file: String) throws -> Int {
            try NSRegularExpression(pattern: pattern)
                .numberOfMatches(in: file, range: NSRange(file.startIndex..., in: file))
        }
        #expect(try declarations(#"funcrevokeEveryLease[<(]"#, in: authority) == 1)
        #expect(try declarations(#"funcrestore[<(]"#, in: authority) == 2)
        #expect(try declarations(#"funchandBack[<(]"#, in: restorer) == 1)
    }
}
