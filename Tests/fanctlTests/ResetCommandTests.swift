import AeolusXPC
import AeolusXPCClient
import ArgumentParser
import Foundation
import Testing

@testable import fanctl

/// What `fanctl reset --all` says, and what it exits with, for each answer the client can
/// give it.
///
/// **These are about the rendering and the exit code, not about the round trip.** The round
/// trip — and `Fanctl.Reset.run()` itself — is driven against a real `NSXPCListener` and the
/// real helper session in `Tests/AeolusHelperTests/FanctlResetTests.swift`; what cannot be
/// reached that way, because no listener can cause it, is reached here by handing the
/// renderer the error directly.
///
/// The real `ResetCommand.attempt` and the real `ResetCommand.emit` are both in the loop, so
/// what is asserted is the shipping error-to-text and report-to-exit-code mappings rather
/// than a copy of either.
@Suite("fanctl reset --all reports the helper's answer and nothing beyond it")
struct ResetCommandTests {

    /// One run's observable result: what swift-argument-parser would print, and what it
    /// would exit with.
    private struct Emitted {
        let message: String
        let exitCode: ExitCode
    }

    /// Renders one attempt the way the command does, and captures how it would leave.
    private static func emitted(whenRestoreThrows error: (any Error)? = nil) async -> Emitted {
        let report = await ResetCommand.attempt {
            if let error { throw error }
        }
        do {
            try ResetCommand.emit(report)
        } catch {
            return Emitted(
                message: Fanctl.message(for: error),
                exitCode: Fanctl.exitCode(for: error))
        }
    }

    // MARK: - The helper accepted

    /// Acceptance is reported as acceptance of a **request**, and the difference is spelled
    /// out rather than implied.
    ///
    /// `CLAUDE.md` rule 6 in the place it costs the most: this text is read by somebody whose
    /// fans are wrong, and "restored" would send them away from step 4 of `docs/RECOVERY.md`
    /// believing the problem was solved. `restoreAllToAutomatic` answers "accepted", never
    /// "done" — see `HelperClient.restoreAllToAutomatic()`.
    ///
    /// **Mutation:** change `ResetCommand.accepted`'s text to "Every fan was restored to
    /// automatic control." Run: red on the second expectation, which is the one that matters.
    @Test("An accepted request is reported as accepted, never as fans restored")
    func anAcceptedRequestIsNeverReportedAsARestore() async {
        let emitted = await Self.emitted()

        #expect(emitted.exitCode == .success)
        #expect(emitted.message.contains("accepted the reset request"))
        #expect(
            emitted.message.contains(
                "has not reported that any fan is back under automatic control"),
            """
            the success text was "\(emitted.message)". It must state what the helper did not \
            confirm, because the helper confirmed only that it took the request — the \
            restore's completion is not carried by that reply.
            """)
    }

    /// No restoration claim can be **added** to the success text either, which the three
    /// `contains` checks above cannot see.
    ///
    /// They are all positive, so prepending "Every fan is back under automatic control." to
    /// the accepted text leaves every one of them satisfied — with the forbidden sentence
    /// leading the output a panicking user reads first. Two assertions close it, and they have
    /// to be different in kind:
    ///
    /// - The **first paragraph is exactly** the acceptance line, against a literal rather than
    ///   against `ResetCommand.acceptanceLine`, which would compare the constant to itself.
    ///   That catches an addition above the disclaimer.
    /// - With the disclaimer sentence **removed**, nothing that remains says a fan is back
    ///   under automatic control or was restored. That catches an addition below it, in the
    ///   paragraph where the only legitimate occurrence of those words already lives.
    ///
    /// **Mutation:** prepend "Every fan is back under automatic control.\n\n" to
    /// `ResetCommand.accepted`'s text. Run: red on the first expectation. Move the same
    /// sentence into the second paragraph instead: red on the second.
    @Test("No restoration claim can be added to the success text")
    func noRestorationClaimCanBeAddedToTheSuccessText() async {
        let emitted = await Self.emitted()
        let paragraphs = emitted.message.components(separatedBy: "\n\n")

        #expect(
            paragraphs.first == "The helper accepted the reset request.",
            """
            the success text leads with "\(paragraphs.first ?? "")". Exactly one sentence may \
            come first, and it is the one that claims an accepted request and nothing else.
            """)

        let disclaimer = "It has not reported that any fan is back under automatic control"
        let beyondTheDisclaimer = emitted.message.replacingOccurrences(of: disclaimer, with: "")
        #expect(!beyondTheDisclaimer.contains("back under automatic control"))
        #expect(!beyondTheDisclaimer.lowercased().contains("restored"))
        #expect(
            !beyondTheDisclaimer.lowercased().contains("respond to load"),
            """
            the success text tells the reader to watch the fans under load. That is not a test \
            of this command — on a build with no write path the fans respond because Apple's \
            controller is driving them, which it was throughout — and a fan pinned by a \
            foreign tool responds too. It licenses exactly the success inference the rest of \
            this text refuses to make.
            """)
    }

    /// The success path does not send the reader to the daemon-stopping step.
    ///
    /// Not cosmetic: printing the recovery block on every outcome would make the two
    /// outcomes indistinguishable for anyone reading the terminal rather than `$?`, which is
    /// how a CLI is actually read.
    @Test("An accepted request does not print the stop-the-helper step")
    func anAcceptedRequestDoesNotPrintTheRecoveryCommand() async {
        let emitted = await Self.emitted()

        #expect(!emitted.message.contains("launchctl bootout"))
    }

    // MARK: - The helper did not confirm

    /// An unreachable helper names **both** possibilities, because from here they cannot be
    /// told apart.
    ///
    /// ADR 0005 measured it: libxpc drops a peer that fails the code-signing requirement and
    /// invalidates the connection with nothing delivered — the same thing a client that
    /// connected to nothing sees. The app narrows it with `HelperInstallationState`; `fanctl`
    /// has no such source, so naming one alone would be a guess printed as a diagnosis.
    ///
    /// **Mutation:** in `ResetCommand.reason(for:)`, return a fixed string such as "the
    /// helper could not be reached" instead of the error's `errorDescription`. Run: red on
    /// all three possibility expectations.
    @Test("An unreachable helper names both possibilities and the way out")
    func anUnreachableHelperNamesBothPossibilities() async {
        let emitted = await Self.emitted(
            whenRestoreThrows: HelperClientError.helperUnreachable(code: 4097))

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains("not installed"))
        #expect(emitted.message.contains("approved"))
        #expect(emitted.message.contains("refused"))
        #expect(emitted.message.contains("sudo launchctl bootout system/"))
    }

    /// The closing sentence's count must match the number of possibilities it closes —
    /// three items enumerated above it, so the sentence must not narrow that to two, or to
    /// any other number, when it says they cannot be told apart.
    ///
    /// This is `HelperClientError.helperUnreachable`'s `errorDescription` directly, not
    /// `fanctl`'s rendering of it, because the defect (#246) was in the string itself: it
    /// listed three states — not installed, not yet approved, signature refused — and then
    /// said "these two". A fixed numeral would only move the bug; asserting the actual
    /// closing clause is what keeps the count from drifting out of sync with the list again.
    ///
    /// **Mutation:** in `HelperClientError.errorDescription`, revert the closing clause to
    /// "These two cannot be told apart from here." Run: red on the "These two" negative match
    /// and the closing-sentence pin below (the "These three" negative match stays green — the
    /// mutation never introduces that string).
    @Test("helperUnreachable's closing sentence does not miscount its own list")
    func helperUnreachableClosingSentenceMatchesItsList() {
        let described = HelperClientError.helperUnreachable(code: 4097).errorDescription ?? ""

        #expect(described.contains("not installed"))
        #expect(described.contains("not yet"))
        #expect(described.contains("approved"))
        #expect(described.contains("refused"))
        #expect(!described.contains("These two"))
        #expect(!described.contains("These three"))
        #expect(described.contains("These possibilities cannot be told apart from here."))
    }

    /// A helper that accepted and never answered is reported as exactly that — not as a
    /// failure to restore, and not as a success.
    ///
    /// `docs/SAFETY.md` § 4's wedged `io_connect_t` is where this comes from, and it is the
    /// one outcome where *both* claims would be inventions: the helper may well have done the
    /// work, and it may well never do it.
    ///
    /// **Mutation:** change `ResetCommand.unconfirmed`'s lead line to "The reset failed."
    /// Run: red on the second expectation.
    @Test("A helper that never answered is reported as unconfirmed, not as failed")
    func aHelperThatNeverAnsweredIsReportedAsUnconfirmed() async {
        let emitted = await Self.emitted(
            whenRestoreThrows: HelperClientError.helperNeverAnswered(after: .seconds(10)))

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains("did not confirm the reset request"))
        #expect(emitted.message.contains("Nothing can be said about whether it took effect"))
        #expect(emitted.message.contains("sudo launchctl bootout system/"))
    }

    /// The ordinary outcome of every unsigned build, including this one, told apart from a
    /// missing daemon.
    ///
    /// A `swift build` `fanctl` has no Team ID, so "the helper signed by whoever signed me"
    /// names nobody and the connection is never made. That is a different problem from an
    /// absent helper, with a different fix (#82), and it is the one case the client can be
    /// sure about.
    @Test("An unsigned build says so rather than blaming the daemon")
    func anUnsignedBuildSaysSoRatherThanBlamingTheDaemon() async {
        let emitted = await Self.emitted(
            whenRestoreThrows: HelperClientError.clientCannotVerifyHelper(
                .runningProcessHasNoTeamIdentifier))

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains("cannot be used to control fans"))
        #expect(emitted.message.contains("reads do not need the helper"))
    }

    /// A refusal from the helper is printed in the helper's own words, not flattened into
    /// "something went wrong".
    ///
    /// `AeolusXPCFault` is the vocabulary for "the helper said no" and is deliberately not a
    /// `HelperClientError` case. A CLI that rendered the two identically would hide the one
    /// distinction the boundary spent a whole type preserving.
    @Test("A refusal from the helper is reported in the helper's own words")
    func aRefusalFromTheHelperIsReportedInItsOwnWords() async throws {
        let fault = AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        let emitted = await Self.emitted(whenRestoreThrows: fault)

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains(try #require(fault.errorDescription)))
    }

    // MARK: - The invocation

    /// `fanctl reset` with no `--all` is an incomplete invocation, and says what to type.
    ///
    /// Exit 64 (`EX_USAGE`) with a usage block, which is swift-argument-parser's treatment of
    /// `ValidationError` and nothing else's. The alternative — connecting, and letting the
    /// helper refuse — would spend a round trip to learn something this build already knows.
    ///
    /// **Mutation:** delete `Fanctl.Reset.validate()`. Run: red — parsing succeeds and
    /// nothing is thrown.
    @Test("fanctl reset without --all is a usage error that names --all")
    func resetWithoutAllIsAUsageErrorThatNamesTheFlag() throws {
        do {
            _ = try Fanctl.parseAsRoot(["reset"])
            Issue.record("`fanctl reset` with no --all was accepted")
        } catch {
            #expect(Fanctl.exitCode(for: error) == .validationFailure)
            #expect(Fanctl.message(for: error).contains("fanctl reset --all"))
        }
    }

    /// The usage error does not claim a restoration either.
    ///
    /// It said the command "returns every fan to automatic control" until review caught it:
    /// a flat assertion that the fans are restored, in user-facing text, thirty lines below
    /// the report that carefully refuses to make one. Intent — *asks the helper to* — is the
    /// only shape any string in this command may take.
    @Test("The usage error describes intent, not an accomplished restore")
    func theUsageErrorDescribesIntentNotAnAccomplishedRestore() throws {
        do {
            _ = try Fanctl.parseAsRoot(["reset"])
            Issue.record("`fanctl reset` with no --all was accepted")
        } catch {
            let message = Fanctl.message(for: error)
            #expect(message.contains("asks the helper to return every fan to automatic"))
            #expect(!message.contains("fanctl reset returns every fan"))
        }
    }

    // MARK: - What the shipping command is wired to

    /// `run()`'s production connection talks to the installed daemon, pins it, and waits the
    /// panic deadline.
    ///
    /// **A memo pin, and the numbers are literals on purpose.** D26 item 4 fixes 5 s for gated
    /// verbs and 10 s for `restoreAllToAutomatic`; comparing the constant to itself would pass
    /// under any change, so the figures are written out where a reviewer can check them
    /// against the memo. `FanctlResetTests` asserts the other half — that `run()` actually
    /// waits the deadline it is handed rather than one of its own.
    ///
    /// The transport and the pinning matter for a different reason: `HelperClientTransport`
    /// has an `.endpoint` case that exists so the suite can drive a real listener, and
    /// `HelperConnection` exists so a test can select it. Nothing but a test may, and this is
    /// what says so.
    @Test("The shipping command connects to the daemon, pinned, on the panic deadline")
    func theShippingConnectionIsTheDaemonPinnedOnThePanicDeadline() {
        let production = ResetCommand.HelperConnection.production

        guard case .machService = production.transport else {
            Issue.record("the shipping command does not connect to the mach service")
            return
        }
        #expect(
            production.pinning is SignedHelperPinning,
            "the shipping command would talk to whoever answered the mach name")
        #expect(production.deadlines.panicVerb == .seconds(10))
        #expect(production.deadlines.gatedVerb == .seconds(5))
    }

    // MARK: - The recovery step

    /// The `bootout` line names the service the helper actually registers.
    ///
    /// Asserted against the **literal** rather than against `AeolusXPCService.machServiceName`
    /// — comparing the constant to itself would pass under any rename, and this string is
    /// printed in the one situation where a stale name cannot be worked around: the user's
    /// connection to the helper has already failed. `LaunchDaemonPlistTests` holds the launchd
    /// job's Label to the same constant from the other side, so a rename that reached one and
    /// not the other fails somewhere.
    @Test("The stop-the-helper step names the real launchd label")
    func theRecoveryStepNamesTheRealLaunchdLabel() {
        #expect(
            ResetCommand.stopTheHelper.contains(
                "sudo launchctl bootout system/com.blamechris.Aeolus.Helper"),
            """
            the recovery step reads "\(ResetCommand.stopTheHelper)". docs/RECOVERY.md step 4 \
            is the same command, and this is printed to a user whose helper connection has \
            already failed — a name that has drifted cannot be recovered from at that point.
            """)
    }
}
