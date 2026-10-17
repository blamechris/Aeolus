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
/// is a failure whatever calls it. `AuthorityRoleTripwireTests` closes the other door, a plane
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
        "Sources/AeolusHelper/Lease/LeaseAuthority.swift — releaseEveryLease, sealingGrants, "
            + "and confirmAcceptedHandbacks's \"no keystone queued behind the read\"",
        "docs/records/handback-ledger.md — \"`releaseEveryLease()`: what the sweep is, and "
            + "what it is not\", \"Accepted is not automatic\", and \"The machine-wide "
            + "restore seal\"",
        "Sources/AeolusHelper/FanAuthority.swift — the protocol requirement",
        "Sources/AeolusXPC/AeolusXPCProtocol.swift — the declaration, and the ordering "
            + "paragraph above it",
        "docs/SAFETY.md — § 1's .everyFan call-site list and § 7's panic path",
        "docs/ADR/0005-xpc-authorisation.md — \"Why the panic path is exempt\"",
        "Tests/AeolusHelperTests/LeaseTeardownTests.swift — LeaseReleaseTests.everyLeaseIsDropped",
    ]

    /// The sites as a failure message's list. `AuthorityRoleTripwireTests` prints it too.
    static var checklist: String {
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

        // #350: all three acts run inside the grant seal, which is named once.
        //
        // **Today only this holds the read-back's place.** `ControlStateGatePlane` parks every
        // mode read, so a grant asked while the read-back is parked parks on its own
        // foreign-control read before it reaches the seal; a per-fan mode park could hold it
        // behaviourally, and none exists yet. `PanicGrantSealTests` holds the sweep and restore.
        //
        // **Mutation:** move `await leases.confirmAcceptedHandbacks()` below the closure. Run:
        // red here only — every behavioural test of the seal stays green. **Mutation:** the same,
        // leaving `return machineWide  // confirmAcceptedHandbacks: see below` inside it. Run:
        // red, because `functionBody` strips trailing comments too.
        try Self.expectInsideTheSeal(
            [
                (release, "the lease release"), (gate, "the capability gate"),
                (keystone, "the machine-wide restore"), (readBack, "the read-back"),
            ], of: body, in: "restoreAllToAutomatic")
    }

    /// Each of `acts` lies inside the one `sealingGrants` closure in `body`, `caller`'s.
    private static func expectInsideTheSeal(
        _ acts: [(Range<String.Index>, String)], of body: String, in caller: String
    ) throws {
        let seals = body.components(separatedBy: "sealingGrants").count - 1
        #expect(seals == 1, "\(caller) names sealingGrants \(seals) times, not once")
        let sealed = try #require(
            Self.closureBody(after: "sealingGrants", in: body),
            "\(caller) runs its acts in no sealingGrants closure this scan can find")
        for (act, what) in acts {
            #expect(
                sealed.contains(act.lowerBound) && sealed.contains(act.upperBound),
                """
                \(caller) runs \(what) outside LeaseAuthority.sealingGrants(during:), so a lease \
                can be granted while it runs and undone by its machine-wide restore (#350, \
                #364). docs/SAFETY.md § 1 and these say what the seal covers:
                \(Self.checklist)
                """)
        }
    }

    /// Each machine-wide restore issued after bring-up is issued after its grant interlock is
    /// called (`docs/SAFETY.md` § 1), and § 7's and § 4's inside the machine-wide restore seal.
    ///
    /// § 4 seals the table before its teardown and runs the teardown inside `sealingGrants`, § 6's
    /// signal teardown closes the control gate before its first keystone, and § 7 issues
    /// `.everyFan` inside `sealingGrants`. Bring-up's fallback runs before the listener is
    /// resumed, which `HelperCompositionTests` holds. § 4's restore is `.everyFan`; § 6's first
    /// keystone is `.everyFan` and its last the exit's own `.forExit` (ADR 0014's #410
    /// ticket-and-seal amendment), each checked by name where it is chosen.
    ///
    /// **§ 7's, § 4's and bring-up's interlocks are airtight; § 6's is narrower, and harmless.**
    /// Since [#364](https://github.com/blamechris/Aeolus/issues/364) every call of § 4's
    /// `handBackEveryFan(` lies inside the one `sealingGrants` closure in
    /// `allowSleepAfterHandback`. § 6's gate refuses a grant on arrival rather than in flight: one
    /// in flight can land, and `apply` is refused by the same gate before the process exits.
    ///
    /// Calls are matched as identifiers with optional whitespace before `(`, because
    /// `keystone ()` compiles, and a `func` declaration is not counted as one.
    ///
    /// **Mutation:** delete `await leases.sealForSleep(generation: notification.generation)` from
    /// `SystemPowerResponder.allowSleepAfterHandback`. Run: red. **Mutation:** move
    /// `await gate.close()` below the first `_ = await keystone(.everyFan)` in
    /// `SignalTeardown.run`. Run: red. **Mutation:** the same, with that call spelled
    /// `_ = await keystone (.everyFan)` and the second left after the close. Run: red.
    /// **Mutations (#364):** call `handBackEveryFan(` bare in `allowSleepAfterHandback`;
    /// `sealingGrants {}` and then the bare call; the same with
    /// `// handBackEveryFan(reportingTo: acknowledgement)` inside the empty closure; and a second
    /// bare call elsewhere in the file. Run: red on each.
    @Test("Each runtime machine-wide restore is issued after its grant interlock")
    func everyRuntimeMachineWideRestoreFollowsItsGrantInterlock() throws {
        for site in [
            (
                file: "SystemPowerResponder.swift", caller: "allowSleepAfterHandback",
                interlock: #"(?<![A-Za-z0-9_])sealForSleep\s*\("#, issuer: "handBackEveryFan",
                scopes: [".everyFan"], chosenIn: "handBackEveryFan"
            ),
            (
                file: "SignalTeardown.swift", caller: "run",
                interlock: #"(?<![A-Za-z0-9_])gate\s*\.\s*close\s*\("#, issuer: "keystone",
                scopes: [".everyFan", ".forExit"], chosenIn: "run"
            ),
        ] {
            let choosing = try Self.functionBody(of: site.chosenIn, inFile: site.file)
            for scope in site.scopes {
                #expect(
                    choosing.contains(scope),
                    "\(site.file)'s \(site.chosenIn) no longer issues \(scope); walk this tripwire")
            }

            let code = HelperCompositionTests.strippingComments(try Self.source(of: site.file))
            let caller = try Self.functionBody(of: site.caller, inFile: site.file)
            let interlock = try #require(
                caller.range(of: site.interlock, options: .regularExpression),
                "\(site.file)'s \(site.caller) no longer calls its grant interlock")
            let calls = Self.calls(of: site.issuer, in: caller)
            let first = try #require(calls.first, "\(site.caller) no longer calls \(site.issuer)")
            #expect(
                calls.count == Self.calls(of: site.issuer, in: code).count
                    && interlock.upperBound <= first.lowerBound,
                """
                \(site.file) issues \(site.scopes) through \(site.issuer) somewhere its grant \
                interlock does not precede, so a lease can be granted that the machine-wide \
                restore undoes. docs/SAFETY.md § 1 says which call sites are interlocked.
                """)
        }

        let panic = try Self.functionBody(
            of: "restoreAllToAutomatic", inFile: "SupervisedFanAuthority.swift")
        let keystone = try #require(panic.range(of: ".everyFan"), "§ 7 names no .everyFan")
        try Self.expectInsideTheSeal(
            [(keystone, "the machine-wide restore")], of: panic, in: "restoreAllToAutomatic")

        // #364: every call of § 4's teardown — the count above says they are all here.
        let sleep = try Self.functionBody(
            of: "allowSleepAfterHandback", inFile: "SystemPowerResponder.swift")
        try Self.expectInsideTheSeal(
            Self.calls(of: "handBackEveryFan", in: sleep).map { ($0, "§ 4's teardown") },
            of: sleep, in: "allowSleepAfterHandback")
    }

    // MARK: - The machine-wide scopes

    /// The machine-wide restore is named in exactly four call-site files under `Sources/`, and in
    /// the one file that decides what each scope writes.
    ///
    /// This is what keeps the test above from being evadable by one indirection: the handler
    /// could call a free function, a new restorer type, or the lease core, and the body scan
    /// would see nothing. The machine-wide scopes are the only ones that clear the Apple Silicon
    /// force key (`FanControlPlane.FanRestoreScope`), so each has to be *named* wherever it is
    /// issued, and an unlisted file naming one is a failure whatever reaches it.
    ///
    /// The four are `docs/SAFETY.md` § 1's list, verbatim, and none of them is a lease teardown:
    /// § 4's sleep handback, § 6's startup-reconciliation fallback and — on a plane that can
    /// write — § 7's panic verb name `.everyFan`; § 6's orderly exit names `.everyFan` at its first
    /// keystone and its own `.forExit` at its last, which writes the same and seals the plane (ADR
    /// 0014's #410 ticket-and-seal amendment), so it is counted through either token. The
    /// fifth file is `PlaneWriteLedger.swift`, which names both to decide their plan and the seal:
    /// it holds no plane and cannot issue a restore. On the E4 branch `SMCFanControlPlane.swift`
    /// joins them (ADR 0014 D5): its preparation step names `.everyFan`, and this scan cannot
    /// tell it from a call site. Comments are stripped first, for the reason
    /// `WritePathAbsenceTests` records — the prose explaining these sites names the tokens
    /// repeatedly, and a tripwire that fires on the sentence stating the rule is a tripwire nobody
    /// keeps.
    ///
    /// `.forExit`'s name does not contain `.everyFan`, so neither substring scan counts the other.
    ///
    /// **Mutation:** add `let plane: (any FanControlPlane)? = nil` and
    /// `try await plane?.restoreToAutomatic(.everyFan)` to
    /// `ReadOnlyFanAuthority.restoreAllToAutomatic`. Run: red **here only** — the tests above
    /// stay green, which is what proves this one discriminates rather than echoing them.
    /// **Mutation:** make `SignalTeardown.run`'s final keystone `.everyFan`. Run: red here, on the
    /// exit scope's set.
    @Test("The machine-wide restores are issued from exactly four known call sites")
    func everyMachineWideRestoreIsOneOfTheKnownCallSites() throws {
        let expected: [String: Set<String>] = [
            ".everyFan": [
                "SignalTeardown.swift", "SystemPowerResponder.swift", "StartupReconciliation.swift",
                "SupervisedFanAuthority.swift", "PlaneWriteLedger.swift",
            ],
            ".forExit": ["SignalTeardown.swift", "PlaneWriteLedger.swift"],
        ]

        var naming: [String: Set<String>] = [".everyFan": [], ".forExit": []]
        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            for scope in expected.keys where code.contains(scope) {
                naming[scope, default: []].insert(file.lastPathComponent)
            }
        }

        for (scope, files) in expected {
            #expect(
                naming[scope] == files,
                """
                \(scope) is named in \((naming[scope] ?? []).sorted()), not \(files.sorted()). \
                A machine-wide restore also clears the Apple Silicon force key, so every call \
                site is a machine-wide act: docs/SAFETY.md § 1 lists the four by name. A site \
                added or removed here contradicts that sentence, and these say the same thing:
                \(Self.checklist)
                """)
        }
    }

    /// The exit's scope is named only where it is declared, decided and issued:
    /// `FanControlPlane.swift`, `PlaneWriteLedger.swift` and `SignalTeardown.swift` (ADR 0014's
    /// #410 ticket-and-seal amendment).
    ///
    /// `.forExit` seals the plane for the rest of the process. A non-exit caller issuing it would
    /// leave every later `apply` refused with a reason that is false, and § 4's handback issuing it
    /// would seal the plane at every sleep. So the identifier is held, comments stripped, as a
    /// whole word — the declaration has no dot in front of it.
    ///
    /// **Mutation:** make `SystemPowerResponder.handBackEveryFan(reportingTo:)` issue `.forExit`.
    /// Run: red here, and on the census above.
    @Test("The exit's scope is named only by the orderly exit, the scope and the ledger")
    func theExitScopeIsNamedOnlyByTheOrderlyExit() throws {
        let word = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])forExit(?![A-Za-z0-9_])"#)
        var naming: Set<String> = []
        for file in try SeamScanner.swiftFiles() {
            let code = SeamScanner.strippingAllComments(
                try String(contentsOf: file, encoding: .utf8))
            if word.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                naming.insert(file.lastPathComponent)
            }
        }

        #expect(
            naming == ["FanControlPlane.swift", "PlaneWriteLedger.swift", "SignalTeardown.swift"],
            """
            the exit's scope is named in \(naming.sorted()). It seals the write path for the rest \
            of the process, so only the orderly exit may issue it, and only its declaration and \
            the ledger that decides it may name it.
            """)
    }

    // MARK: - Parsing

    /// The brace-balanced body of the first `func <name>` in `file`, comments stripped —
    /// trailing `//` comments included, through `HelperCompositionTests.strippingComments`,
    /// because `SeamScanner`'s stripper drops whole comment lines only and a trailing comment
    /// naming an act would otherwise stand in for it.
    ///
    /// Local rather than in `SeamScanner`, following `WritePathAbsenceTests`'
    /// `smcConnectionExtensionBodies`: the scanner owns the primitives more than one suite needs
    /// to agree on, and a one-caller brace walk is not yet one of them. It reuses the scanner's
    /// `parameterListStart` and `closingParenthesis`, which are the parts that have been wrong
    /// before — a `[^)]*` parameter list and a `<[^>]*>` generic clause both fail *silently*, by
    /// matching nothing at all.
    private static func functionBody(of name: String, inFile file: String) throws -> String {
        let code = HelperCompositionTests.strippingComments(try Self.source(of: file))

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

        let body = Self.balancedBody(openingAt: brace.lowerBound, in: code)
        #expect(body != nil, "func \(name) in \(file) has an unbalanced body")
        return body.map { String(code[$0]) } ?? ""
    }

    /// The range inside the first `{ … }` after `token` in `code` — the trailing closure of a
    /// call — or `nil` when there is none or it does not balance.
    private static func closureBody(after token: String, in code: String) -> Range<String.Index>? {
        guard let call = code.range(of: token),
            let brace = code[call.upperBound...].firstIndex(of: "{")
        else { return nil }
        return balancedBody(openingAt: brace, in: code)
    }

    /// The range between the `{` at `open` and the `}` that closes it, by depth count.
    private static func balancedBody(
        openingAt open: String.Index, in code: String
    ) -> Range<String.Index>? {
        var depth = 1
        var index = code.index(after: open)
        while index < code.endIndex, depth > 0 {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" { depth -= 1 }
            index = code.index(after: index)
        }
        guard depth == 0 else { return nil }
        return code.index(after: open)..<code.index(before: index)
    }

    /// Every call of `name` in `code`: the whole identifier, optional whitespace, then `(`.
    /// A `func name(` declaration is not a call and is left out.
    private static func calls(of name: String, in code: String) -> [Range<String.Index>] {
        let pattern = #"(?<![A-Za-z0-9_])"# + name + #"\s*\("#
        var found: [Range<String.Index>] = []
        var start = code.startIndex
        while true {
            let rest = start..<code.endIndex
            guard let match = code.range(of: pattern, options: .regularExpression, range: rest)
            else { break }
            let before = code[..<match.lowerBound]
            if before.range(of: #"(^|[^A-Za-z0-9_])func\s+$"#, options: .regularExpression) == nil {
                found.append(match)
            }
            start = match.upperBound
        }
        return found
    }

    private static func source(of file: String) throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
