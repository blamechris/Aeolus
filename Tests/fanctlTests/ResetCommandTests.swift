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
/// trip that produces these errors is driven against a real `NSXPCListener` and the real
/// helper session in `Tests/AeolusHelperTests/FanctlResetTests.swift`; what cannot be reached
/// that way — a peer that rejects the signature, a refusal the helper cannot raise in this
/// build — is reached here by handing the command the error directly.
///
/// The seam is the `restoring:` closure. It is deliberately not a protocol with a fake
/// conformer: there is nothing here for a double to get wrong except throwing, and a double
/// that never suspends is how a concurrency claim becomes vacuous. Nothing in this file
/// asserts a concurrency claim.
@Suite("fanctl reset --all reports the helper's answer and nothing beyond it")
struct ResetCommandTests {

    /// One run's observable result: what swift-argument-parser would print, and what it
    /// would exit with.
    private struct Emitted {
        let message: String
        let exitCode: ExitCode
    }

    /// Parsed rather than constructed, so `--all` reaching the flag and `validate()`
    /// accepting the invocation are part of every case below.
    private static func resetAll() throws -> Fanctl.Reset {
        try #require(Fanctl.parseAsRoot(["reset", "--all"]) as? Fanctl.Reset)
    }

    /// Runs the command and captures how it left.
    ///
    /// `nil` means it returned without throwing, which is a failure of the command rather
    /// than of the test: both outcomes leave through an error, because that is the only way
    /// swift-argument-parser is told an exit code.
    private static func outcome(of restore: () async throws -> Void) async throws -> Emitted? {
        do {
            try await resetAll().run(restoring: restore)
            return nil
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
    func anAcceptedRequestIsNeverReportedAsARestore() async throws {
        let emitted = try #require(try await Self.outcome(of: {}))

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

    /// The success path does not send the reader to the daemon-stopping step.
    ///
    /// Not cosmetic: printing the recovery block on every outcome would make the two
    /// outcomes indistinguishable for anyone reading the terminal rather than `$?`, which is
    /// how a CLI is actually read.
    @Test("An accepted request does not print the stop-the-helper step")
    func anAcceptedRequestDoesNotPrintTheRecoveryCommand() async throws {
        let emitted = try #require(try await Self.outcome(of: {}))

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
    func anUnreachableHelperNamesBothPossibilities() async throws {
        let emitted = try #require(
            try await Self.outcome(of: {
                throw HelperClientError.helperUnreachable(code: 4097)
            }))

        #expect(emitted.exitCode != .success)
        #expect(emitted.message.contains("not installed"))
        #expect(emitted.message.contains("approved"))
        #expect(emitted.message.contains("refused"))
        #expect(emitted.message.contains("sudo launchctl bootout system/"))
    }

    /// A helper that accepted and never answered is reported as exactly that — not as a
    /// failure to restore, and not as a success.
    ///
    /// `docs/SAFETY.md` § 4's wedged `io_connect_t` is where this comes from, and it is the
    /// one outcome where *both* claims would be inventions: the helper may well have done the
    /// work, and it may well never do it.
    ///
    /// **Mutation:** change `ResetCommand.unconfirmed`'s lead line to "The reset failed."
    /// Run: red on the first expectation.
    @Test("A helper that never answered is reported as unconfirmed, not as failed")
    func aHelperThatNeverAnsweredIsReportedAsUnconfirmed() async throws {
        let emitted = try #require(
            try await Self.outcome(of: {
                throw HelperClientError.helperNeverAnswered(after: .seconds(10))
            }))

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
    func anUnsignedBuildSaysSoRatherThanBlamingTheDaemon() async throws {
        let emitted = try #require(
            try await Self.outcome(of: {
                throw HelperClientError.clientCannotVerifyHelper(
                    .runningProcessHasNoTeamIdentifier)
            }))

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
        let emitted = try #require(try await Self.outcome(of: { throw fault }))

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
