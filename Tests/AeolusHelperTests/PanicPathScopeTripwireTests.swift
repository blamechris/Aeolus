import Foundation
import Testing

@testable import AeolusHelper

/// § 7's panic verb is **lease-scoped in effect and global in contract**, and the gap between
/// those two is a documentation claim rather than an observable behaviour — so it is asserted
/// against the source tree.
///
/// [#228](https://github.com/blamechris/Aeolus/issues/228) is what this exists for, and the
/// defect it records is worth restating because it is not a typo. The issue names three sites;
/// `documentationSites` below is the verified list, and it has **seven entries**.
/// `SupervisedFanAuthority.restoreAllToAutomatic` has always been right. Four said, in plain
/// present indicative, that the verb additionally restores every enumerated fan —
/// `LeaseAuthority.releaseEveryLease`, `LeaseTeardownTests`,
/// `AeolusXPCProtocol.restoreAllToAutomatic`'s declaration, which named the `Ftst` force key
/// outright beside `fanctl reset --all`, and `ADR 0005`. A fifth, the ordering paragraph above
/// that declaration, said "each fan" where it meant the fans the dropped leases covered. The
/// seventh, `FanAuthority`'s requirement, was merely silent about the gap. `docs/SAFETY.md` § 7
/// inherited the claim and [#222](https://github.com/blamechris/Aeolus/issues/222) corrected
/// the document side without touching the source comments it came from.
///
/// **Why a tripwire and not a behavioural test.** A behavioural test can only assert what the
/// handler does, and what the handler does is already covered —
/// `SupervisedFanAuthorityTests.restoreAllToAutomaticReachesTheLeaseCore` drives it and
/// `LeaseReleaseTests.everyLeaseIsDropped` pins the lease core's half. Neither can fail when a
/// comment starts promising something else, which is the failure #228 actually records: every
/// one of those four sentences was written beside green tests. What has to be pinned is the
/// **coupling** — the handler may not quietly acquire the machine-wide restore while the prose
/// describing it stays as it is — and a coupling between code and prose has nothing to observe
/// at runtime.
///
/// **The limit, stated rather than discovered later.** This is text matching over stripped
/// source, so it catches the realistic regression — somebody wiring E3/E4's write path into the
/// panic verb and not revisiting the list below — and not a plane call reached through a name it
/// cannot recognise. `everyMachineWideRestoreIsOneOfTheThreeKnownCallSites` is what narrows
/// that: the machine-wide scope has to be *named* somewhere to be issued, and a fourth place
/// naming it is a failure whatever calls it.
@Suite("§ 7's panic verb stays lease-scoped, or the documentation moves with it")
struct PanicPathScopeTripwireTests {

    /// Every documentation site that describes this verb's scope, named here so a failure
    /// message can hand a maintainer the list rather than a diff.
    ///
    /// This is the payload of the whole suite. When E3/E4 gives the panic verb a real
    /// machine-wide restore, the two tests below go red **by design** — the correct response is
    /// to walk this list, then invert or delete the assertion, not to delete it first.
    static let documentationSites = [
        "Sources/AeolusHelper/SupervisedFanAuthority.swift — restoreAllToAutomatic's own "
            + "paragraph, where the decision lives",
        "Sources/AeolusHelper/Lease/LeaseAuthority.swift — releaseEveryLease",
        "Sources/AeolusHelper/FanAuthority.swift — the protocol requirement",
        "Sources/AeolusXPC/AeolusXPCProtocol.swift — the declaration, and the ordering "
            + "paragraph above it",
        "docs/SAFETY.md — § 5's .everyFan call-site list and § 7's panic path",
        "docs/ADR/0005-xpc-authorisation.md — \"Why the panic path is exempt\"",
        "Tests/AeolusHelperTests/LeaseTeardownTests.swift — LeaseReleaseTests.everyLeaseIsDropped",
    ]

    private static var checklist: String {
        documentationSites.map { "  - \($0)" }.joined(separator: "\n")
    }

    // MARK: - The handler

    /// `SupervisedFanAuthority.restoreAllToAutomatic`'s body names no control-plane restore.
    ///
    /// The body is `await leases.releaseEveryLease()` and a log line. Both halves of that are
    /// observable and tested; what is not observable is that nothing *else* is there, and the
    /// four corrected comments are all statements that something else is.
    ///
    /// Scoped to the one function rather than the whole type deliberately. The type composes
    /// `ReadOnlyFanAuthority` and forwards the lease core, so a `restoreToAutomatic` legitimately
    /// arriving elsewhere in it one day must not be able to redden this — and equally must not be
    /// able to satisfy it.
    ///
    /// The mutations are cited as run, not as they would read most neatly. The type holds no
    /// plane, so the shortest thing that both compiles and has the defect's shape is a `nil`
    /// existential — an implementer wiring E3/E4 would inject a real one, and the scan cannot
    /// tell the two apart, which is the point.
    ///
    /// **Mutation:** add `let plane: (any FanControlPlane)? = nil` and
    /// `try await plane?.restoreToAutomatic(.everyFan)` to the body. Run: red at both
    /// forbidden tokens, and red at `everyMachineWideRestoreIsOneOfTheThreeKnownCallSites` too.
    /// **Mutation:** delete `await leases.releaseEveryLease()` from the body. Run: red on the
    /// coverage assertion — the guard against a scan that reads nothing and reports it clean.
    @Test("The shipped panic verb issues no control-plane restore")
    func theShippedPanicVerbIssuesNoControlPlaneRestore() throws {
        let body = try Self.functionBody(
            of: "restoreAllToAutomatic", inFile: "SupervisedFanAuthority.swift")

        // Coverage, not decoration. A body extractor that resolved to an empty string — a
        // renamed verb, a moved file, a brace scan that stopped matching — would satisfy every
        // assertion below over a handler nobody read. The one call the body is known to contain
        // is what proves the scan reached it.
        #expect(
            body.contains("releaseEveryLease"),
            """
            restoreAllToAutomatic's body in SupervisedFanAuthority.swift does not call \
            releaseEveryLease. Either the panic verb no longer releases every lease — which is \
            docs/SAFETY.md § 7's whole remaining substance — or this scan is not reading it, in \
            which case the assertions below are green over nothing.
            """)

        // #291: § 7 is the one caller that lifts a refusal whose handback the firmware
        // accepted, because it is the one with no keystone queued behind the read.
        //
        // **Mutation:** delete `await leases.confirmAcceptedHandbacks()` from the body. Run: red.
        #expect(
            body.contains("confirmAcceptedHandbacks"),
            """
            restoreAllToAutomatic no longer reads back the fans whose handback the firmware \
            accepted, so nothing lifts a restoreAbandoned refusal for the life of the process.
            """)

        for verb in ["restoreToAutomatic", "everyFan"] {
            #expect(
                !body.contains(verb),
                """
                SupervisedFanAuthority.restoreAllToAutomatic names `\(verb)`. That is the \
                machine-wide restore, and the whole of #228 is that seven places describe this \
                verb and four of them used to claim it already issues one. If the write path \
                now exists and this is intended, every site below has to say so in the same \
                commit:
                \(Self.checklist)
                Until then: the plane verb throws `.controlPathNotBuilt`, so issuing it converts \
                a v1 message that succeeds into one that always fails for no change in machine \
                state, and the contract is frozen at v1 (#159).
                """)
        }
    }

    // MARK: - The machine-wide scope

    /// `restoreToAutomatic(.everyFan)` is named in exactly three files under `Sources/`, and the
    /// panic path is not among them.
    ///
    /// This is what keeps the test above from being evadable by one indirection: the handler
    /// could call a free function, a new restorer type, or the lease core, and the body scan
    /// would see nothing. `.everyFan` is the only scope that clears the Apple Silicon force key
    /// (`FanControlPlane.FanRestoreScope`), so it has to be *named* wherever it is issued, and a
    /// fourth file naming it is a failure whatever reaches it.
    ///
    /// The three are `docs/SAFETY.md` § 5's list, verbatim, and the reason each is legitimate is
    /// that none of them is a lease teardown: § 4's sleep handback, § 6's orderly exit, and
    /// § 6's startup-reconciliation fallback. Comments are stripped first, for the reason
    /// `WritePathAbsenceTests` records — the prose explaining that the panic path is *not* one of
    /// these sites names the token repeatedly, and a tripwire that fires on the sentence stating
    /// the rule is a tripwire nobody keeps.
    ///
    /// **Mutation:** add `let plane: (any FanControlPlane)? = nil` and
    /// `try await plane?.restoreToAutomatic(.everyFan)` to
    /// `ReadOnlyFanAuthority.restoreAllToAutomatic`. Run: red **here only** — the test above
    /// stays green, which is what proves this one discriminates rather than echoing it.
    @Test("The machine-wide restore is issued from exactly three non-lease paths")
    func everyMachineWideRestoreIsOneOfTheThreeKnownCallSites() throws {
        let expected: Set<String> = [
            "SignalTeardown.swift",
            "SystemPowerResponder.swift",
            "StartupReconciliation.swift",
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
            machine-wide act: docs/SAFETY.md § 5 lists these three by name and says § 7's panic \
            path is not among them. A site added or removed here contradicts that sentence, and \
            these say the same thing:
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
