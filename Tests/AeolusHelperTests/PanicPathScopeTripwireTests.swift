import Foundation
import Testing

@testable import AeolusHelper

/// § 7's panic verb is **global in contract**, and since
/// [ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D5 it is global in effect on a plane
/// that can write: it releases every lease, issues `restoreToAutomatic(.everyFan)` if and only
/// if the plane's capability is `.built`, and then reads back. On every build on `main` the
/// capability is `.notBuilt`, so what ships still releases leases and issues nothing more. The
/// gap between "what the verb would do" and "what this binary does" is a documentation claim
/// rather than an observable behaviour, so it is asserted against the source tree.
///
/// [#228](https://github.com/blamechris/Aeolus/issues/228) is what this exists for, and the
/// defect it records is worth restating because it is not a typo. The issue names three sites;
/// `documentationSites` below is the verified list; it had **seven entries** when #228
/// closed, and has eight now. Four said, in plain present indicative, that the verb restored
/// every enumerated fan while it did not —
/// `LeaseAuthority.releaseEveryLease`, `LeaseTeardownTests`,
/// `AeolusXPCProtocol.restoreAllToAutomatic`'s declaration, which named the `Ftst` force key
/// outright beside `fanctl reset --all`, and `ADR 0005`. A fifth, the ordering paragraph above
/// that declaration, said "each fan" where it meant the fans the dropped leases covered. The
/// seventh, `FanAuthority`'s requirement, was merely silent about the gap. `docs/SAFETY.md` § 7
/// inherited the claim and [#222](https://github.com/blamechris/Aeolus/issues/222) corrected
/// the document side without touching the source comments it came from. The eighth,
/// `docs/records/handback-ledger.md`, joined when
/// [#128](https://github.com/blamechris/Aeolus/issues/128) relocated `releaseEveryLease`'s
/// paragraphs on the sweep there: they carried the statement that the machine-wide restore was
/// declined (#159), which is this verb's scope. #104 is the change that gave the verb the
/// restore, and walked the list in the same commit.
///
/// **Why a tripwire and not a behavioural test.** The behaviour is covered:
/// `PanicVerbMachineWideRestoreTests` drives both capabilities, the order and the refusal, and
/// `FanctlResetCorruptedStateTests` drives the command end to end. None of those can fail when
/// a comment starts promising something else, which is the failure #228 actually records: every
/// one of those four sentences was written beside green tests. What has to be pinned is the
/// **coupling** — the handler may not quietly change scope while the prose describing it stays
/// as it is — and a coupling between code and prose has nothing to observe at runtime.
///
/// **The limit, stated rather than discovered later.** This is text matching over stripped
/// source, so it catches the realistic regression — the restore moved, ungated or dropped, and
/// the list below not revisited — and not a plane call reached through a name it cannot
/// recognise. `everyMachineWideRestoreIsOneOfTheKnownCallSites` is what narrows that: the
/// machine-wide scope has to be *named* somewhere to be issued, and an unlisted place naming it
/// is a failure whatever calls it. `theAuthorityHoldsNoPlane` closes the other door, a plane
/// handed to the verb under a name the body scan would not see.
@Suite("§ 7's panic verb keeps its scope, or the documentation moves with it")
struct PanicPathScopeTripwireTests {

    /// Every documentation site that describes this verb's scope, named here so a failure
    /// message can hand a maintainer the list rather than a diff.
    ///
    /// This is the payload of the whole suite. A change to the verb's scope turns the tests
    /// below red **by design** — the correct response is to walk this list, then change the
    /// assertion, not to change it first. #104 did exactly that when it gave the verb its
    /// machine-wide restore.
    static let documentationSites = [
        "Sources/AeolusHelper/SupervisedFanAuthority.swift — restoreAllToAutomatic's own "
            + "paragraph, where the decision lives; its read-back note; and the type's header",
        "Sources/AeolusHelper/Lease/LeaseAuthority.swift — releaseEveryLease, and "
            + "confirmAcceptedHandbacks's \"no keystone queued behind the read\"",
        "docs/records/handback-ledger.md — \"`releaseEveryLease()`: what the sweep is, and "
            + "what it is not\", and \"Accepted is not automatic\"",
        "Sources/AeolusHelper/FanAuthority.swift — the protocol requirement",
        "Sources/AeolusXPC/AeolusXPCProtocol.swift — the declaration, and the ordering "
            + "paragraph above it",
        "docs/SAFETY.md — § 1's .everyFan call-site list and § 7's panic path",
        "docs/ADR/0005-xpc-authorisation.md — \"Why the panic path is exempt\"",
        "Tests/AeolusHelperTests/LeaseTeardownTests.swift — LeaseReleaseTests.everyLeaseIsDropped",
    ]

    private static var checklist: String {
        documentationSites.map { "  - \($0)" }.joined(separator: "\n")
    }

    // MARK: - The handler

    /// `SupervisedFanAuthority.restoreAllToAutomatic`'s body releases every lease, then issues
    /// the machine-wide restore behind a `.built` gate, then reads back — named once each, in
    /// that order, with no `try?`.
    ///
    /// Until #104 this asserted the opposite, that the body named no control-plane restore at
    /// all; ADR 0014 D5 inverted it, and the order is the half the old test could not have
    /// held. The read-back follows the keystone and is never queued ahead of it (ADR 0007's
    /// 2026-09-20 amendment). `PanicVerbMachineWideRestoreTests` observes that order and both
    /// capabilities' behaviour; this holds the text the documentation above describes.
    ///
    /// Scoped to the one function rather than the whole type deliberately: a `.everyFan`
    /// arriving elsewhere in the type must not be able to satisfy it, and
    /// `everyMachineWideRestoreIsOneOfTheKnownCallSites` is what sees one that does.
    ///
    /// **Mutation (`.built`):** drop the `if writeCapability.writeCapability == .built` gate,
    /// issuing the restore unconditionally. Run: red on the gate assertion, and
    /// `PanicVerbMachineWideRestoreTests.aPlaneThatCannotWriteGetsNoMachineWideRestore` red with
    /// it. **Mutation (`.notBuilt` — the shipped behaviour):** delete the
    /// `try await keystone.restoreToAutomatic(.everyFan)` statement. Run: red on the name count,
    /// and `aBuiltPlaneGetsTheMachineWideRestore` red with it.
    /// **Mutation:** move `await leases.confirmAcceptedHandbacks()` above the `.built` block. Run:
    /// red on the order. **Mutation:** delete `await leases.releaseEveryLease()`. Run: red on the
    /// coverage assertion — the guard against a scan that reads nothing and reports it clean.
    @Test("The panic verb issues the machine-wide restore only on a built plane, before the read")
    func thePanicVerbIssuesTheMachineWideRestoreOnlyOnABuiltPlane() throws {
        let body = try Self.functionBody(
            of: "restoreAllToAutomatic", inFile: "SupervisedFanAuthority.swift")

        // Coverage, not decoration. A body extractor that resolved to an empty string — a
        // renamed verb, a moved file, a brace scan that stopped matching — would satisfy a
        // negative assertion over a handler nobody read. The call the body is known to open
        // with is what proves the scan reached it.
        let release = try #require(
            body.range(of: "releaseEveryLease"),
            """
            restoreAllToAutomatic's body in SupervisedFanAuthority.swift does not call \
            releaseEveryLease. Either the panic verb no longer releases every lease — which is \
            docs/SAFETY.md § 7's first act — or this scan is not reading it.
            """)

        for (token, what) in [
            ("restoreToAutomatic", "the plane's restore verb"),
            (".everyFan", "the machine-wide scope"),
            ("writeCapability.writeCapability == .built", "the capability gate"),
        ] {
            let count = body.components(separatedBy: token).count - 1
            #expect(
                count == 1,
                """
                SupervisedFanAuthority.restoreAllToAutomatic names \(what) (`\(token)`) \
                \(count) times, not once. The verb issues one machine-wide restore, gated on a \
                plane that can write (ADR 0014 D5). If its scope has changed on purpose, every \
                site below has to say so in the same commit:
                \(Self.checklist)
                """)
        }
        #expect(!body.contains("try?"), "the panic verb swallows an error with try?")

        // #291: § 7 is the one caller of the read-back, and it comes after the keystone.
        //
        // **Mutation:** delete `await leases.confirmAcceptedHandbacks()` from the body. Run: red.
        let readBack = try #require(
            body.range(of: "confirmAcceptedHandbacks"),
            """
            restoreAllToAutomatic no longer reads back the fans whose handback the firmware \
            accepted, so nothing lifts a restoreAbandoned refusal for the life of the process.
            """)
        let gate = try #require(body.range(of: ".built"))
        let keystone = try #require(body.range(of: ".everyFan"))
        #expect(
            release.upperBound <= gate.lowerBound && gate.upperBound <= keystone.lowerBound
                && keystone.upperBound <= readBack.lowerBound,
            """
            restoreAllToAutomatic no longer reads: release every lease, then the .built gate \
            and the machine-wide restore, then the read-back. A read queued ahead of the \
            keystone holds it for as long as the read takes (ADR 0007's 2026-09-20 \
            amendment), and these say the order is this one:
            \(Self.checklist)
            """)
    }

    /// `SupervisedFanAuthority.swift` names no plane, no writer that can command a fan, no
    /// permit and no forward write verb: it is handed `KeystoneRestoring` and
    /// `FanWriteCapabilityReporting`, and nothing wider (ADR 0014 D5).
    ///
    /// The body scan above sees what the panic verb *calls*; it cannot see what the type
    /// *holds*. A whole plane in a stored property would put `commandTarget(_:)` one `await`
    /// from a decoded client message while every statement in the verb read exactly as before.
    /// Type names are matched as identifiers, qualified or not, through
    /// `WatchdogTripwireTests.mentions(of:in:)`, whose own fixtures cover that scan; the verbs
    /// are matched as text, because they arrive as member accesses that scan deliberately
    /// skips.
    ///
    /// **Mutation:** type `keystone` and its initialiser parameter as `any FanControlPlane` /
    /// `some FanControlPlane`, the composition passing `plane`. Run: red on `FanControlPlane`
    /// and on the coverage line — while every behavioural test stays green, because a plane
    /// behind a restore-only body restores exactly as the role does.
    @Test("The panic verb's type holds the keystone and the capability, and no plane")
    func theAuthorityHoldsNoPlane() throws {
        let url = try #require(
            try SeamScanner.swiftFiles().first {
                $0.lastPathComponent == "SupervisedFanAuthority.swift"
            })
        let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))

        // Coverage: the two roles are named, so the scan below is reading the file that holds
        // them rather than an empty one.
        #expect(code.contains("any KeystoneRestoring"), "the keystone role is not held")
        #expect(
            code.contains("any FanWriteCapabilityReporting"), "the capability role is not held")

        let types = try WatchdogTripwireTests.mentions(
            of: [
                "FanControlPlane", "SMCFanControlPlane", "FanStateSensing", "SafetyActorWriter",
                "GovernedFanWriter", "CommandableFan", "AuthorisedFanTarget", "FanTargetRPM",
                "SMCConnection",
            ],
            in: code)
        let verbs = ["commandTarget", "engageManualControl", "commandMaximum"].filter {
            code.contains($0)
        }
        #expect(
            types.isEmpty && verbs.isEmpty,
            """
            SupervisedFanAuthority.swift names \(types + verbs). It is where a decoded client \
            message lands, and it may hold the keystone and the capability and nothing that \
            commands a fan — the shape E2 froze this boundary to (ADR 0014 D5).
            """)
        // A role held as an existential can be cast back to what it wraps, and the cast need
        // not name the type the denylist knows: `keystone as? SomeAlias`.
        for cast in ["as?", "as!"] {
            #expect(!code.contains(cast), "SupervisedFanAuthority.swift casts with `\(cast)`")
        }
    }

    /// The authority's stored properties are exactly these declarations, by name **and** type.
    ///
    /// The denylist above names types, so a name it does not know evades it:
    /// `typealias WholePlane = any FanControlPlane` in another file, then a stored
    /// `WholePlane` here, reads as clean (the review of #349). An allowlist of whole
    /// declarations cannot be evaded by a new name, because every new name is a failure.
    /// Statics and an extension's members are scanned too: every `let` or `var` declared outside
    /// a function body in this file.
    ///
    /// **Mutation:** add `typealias WholePlane = any FanControlPlane` to `FanAuthority.swift`
    /// and `private let plane: WholePlane? = nil` to `SupervisedFanAuthority`. Run: red here and
    /// in `nothingInSourcesAliasesAWiderRole`, and nowhere else.
    @Test("The panic verb's type stores exactly the roles it is allowed, by name and type")
    func theAuthorityStoresOnlyItsAllowedProperties() throws {
        let allowed: Set<String> = [
            "private let reading: ReadOnlyFanAuthority",
            "private let leases: LeaseAuthority",
            "private let reconciliation: any ReconciliationBaselineReporting",
            "private let keystone: any KeystoneRestoring",
            "private let writeCapability: any FanWriteCapabilityReporting",
            "let controlGate = ControlMessageGate()",
            "private let log: HelperLog",
            "private static let shuttingDown = AeolusXPCFault.helperFailed(",
        ]
        let url = try #require(
            try SeamScanner.swiftFiles().first {
                $0.lastPathComponent == "SupervisedFanAuthority.swift"
            })
        let declared = Self.storedDeclarations(
            in: SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8)))

        // Coverage: a scan that found nothing would pass the comparison below vacuously.
        #expect(declared.contains("private let keystone: any KeystoneRestoring"))
        #expect(
            Set(declared) == allowed && declared.count == allowed.count,
            """
            SupervisedFanAuthority.swift declares \(declared.sorted()), not \
            \(allowed.sorted()). It may hold the keystone and the capability and nothing that \
            can command a fan (ADR 0014 D5). Every site below describes what it holds:
            \(Self.checklist)
            """)
    }

    /// Nothing under `Sources/` gives a wider role a second name.
    ///
    /// The allowlist above holds `SupervisedFanAuthority.swift`; this holds the names that file
    /// could import. A `typealias` whose right-hand side names the plane, its read half, or a
    /// writer that can command a fan is a way to spell one of them without the word.
    @Test("No typealias anywhere in Sources renames the plane or a commanding writer")
    func nothingInSourcesAliasesAWiderRole() throws {
        let wider = try NSRegularExpression(
            pattern: #"typealias\s+\w+[^=\n]*=[^\n]*\b(SMCFanControlPlane|FanControlPlane|"#
                + #"FanStateSensing|SafetyActorWriter|GovernedFanWriter)\b"#)
        var aliasing: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingComments(try String(contentsOf: file, encoding: .utf8))
            if wider.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                aliasing.append(file.lastPathComponent)
            }
        }
        #expect(aliasing.isEmpty, "\(aliasing) give the plane or a commanding writer a new name")
    }

    /// Every `let`/`var` declaration outside a function body: the text at brace depth 0 and 1,
    /// one declaration per line, whitespace collapsed.
    private static func storedDeclarations(in code: String) -> [String] {
        var shallow = ""
        var depth = 0
        for character in code {
            if character == "{" { depth += 1 }
            if depth <= 1, character != "{", character != "}" { shallow.append(character) }
            if character == "}" { depth -= 1 }
        }
        let declaration =
            #"^(?:(?:private|fileprivate|internal|public|package|static|"#
            + #"nonisolated|lazy|weak|unowned)\s+)*(?:let|var)\s"#
        return shallow.split(separator: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { $0.range(of: declaration, options: .regularExpression) != nil }
    }

    // MARK: - The machine-wide scope

    /// `restoreToAutomatic(.everyFan)` is named in exactly four files under `Sources/`.
    ///
    /// This is what keeps the test above from being evadable by one indirection: the handler
    /// could call a free function, a new restorer type, or the lease core, and the body scan
    /// would see nothing. `.everyFan` is the only scope that clears the Apple Silicon force key
    /// (`FanControlPlane.FanRestoreScope`), so it has to be *named* wherever it is issued, and an
    /// unlisted file naming it is a failure whatever reaches it.
    ///
    /// The four are `docs/SAFETY.md` § 1's list, verbatim, and none of them is a lease teardown:
    /// § 4's sleep handback, § 6's orderly exit, § 6's startup-reconciliation fallback, and — on a
    /// plane that can write — § 7's panic verb. On the E4 branch `SMCFanControlPlane.swift`
    /// joins them (ADR 0014 D5): its restore branches on the scope and its preparation step
    /// names it, and this scan, `code.contains(".everyFan")`, cannot tell either from a call
    /// site. Comments are stripped first, for the reason `WritePathAbsenceTests` records — the
    /// prose explaining these sites names the token repeatedly, and a tripwire that fires on the
    /// sentence stating the rule is a tripwire nobody keeps.
    ///
    /// **Mutation:** add `let plane: (any FanControlPlane)? = nil` and
    /// `try await plane?.restoreToAutomatic(.everyFan)` to
    /// `ReadOnlyFanAuthority.restoreAllToAutomatic`. Run: red **here only** — the tests above
    /// stay green, which is what proves this one discriminates rather than echoing them.
    @Test("The machine-wide restore is issued from exactly four known call sites")
    func everyMachineWideRestoreIsOneOfTheKnownCallSites() throws {
        let expected: Set<String> = [
            "SignalTeardown.swift",
            "SystemPowerResponder.swift",
            "StartupReconciliation.swift",
            "SupervisedFanAuthority.swift",
        ]

        var naming: Set<String> = []
        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            if code.contains(".everyFan") { naming.insert(file.lastPathComponent) }
        }

        #expect(
            naming == expected,
            """
            the machine-wide restore is named in \(naming.sorted()), not \(expected.sorted()). \
            `.everyFan` additionally clears the Apple Silicon force key, so every call site is a \
            machine-wide act: docs/SAFETY.md § 1 lists these four by name. A site added or \
            removed here contradicts that sentence, and these say the same thing:
            \(Self.checklist)
            """)
    }

    // MARK: - Parsing

    /// The brace-balanced body of the first `func <name>` in `file`, comments stripped.
    ///
    /// Local rather than in `SeamScanner`, following `WritePathAbsenceTests`'
    /// `smcConnectionExtensionBodies`: the scanner owns the primitives more than one suite needs
    /// to agree on, and a one-caller brace walk is not yet one of them. It reuses the scanner's
    /// `parameterListStart` and `closingParenthesis`, which are the parts that have been wrong
    /// before — a `[^)]*` parameter list and a `<[^>]*>` generic clause both fail *silently*, by
    /// matching nothing at all.
    private static func functionBody(of name: String, inFile file: String) throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))

        let declaration = try #require(
            code.range(of: #"func\s+\#(name)(?![A-Za-z0-9_])"#, options: .regularExpression),
            "\(file) declares no func \(name); the panic verb was renamed or moved")
        let open = try #require(
            SeamScanner.parameterListStart(in: code, after: declaration.upperBound),
            "func \(name) in \(file) has no parameter list this scan can find")
        let close = try #require(
            SeamScanner.closingParenthesis(in: code, openingAt: open),
            "func \(name) in \(file) has no closing parenthesis this scan can find")
        let brace = try #require(
            code.range(of: "{", range: close..<code.endIndex),
            "func \(name) in \(file) has no body")

        var depth = 1
        var index = brace.upperBound
        while index < code.endIndex, depth > 0 {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" { depth -= 1 }
            index = code.index(after: index)
        }
        #expect(depth == 0, "func \(name) in \(file) has an unbalanced body")
        return String(code[brace.upperBound..<code.index(before: index)])
    }
}
