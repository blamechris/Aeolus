import AeolusXPC
import AeolusXPCClient
import ArgumentParser
import Foundation

/// `fanctl reset --all` — the panic path, and the only `fanctl` command that speaks to the
/// helper at all.
///
/// ## What this command is allowed to say
///
/// `restoreAllToAutomatic` answers **"accepted"**, never **"done"**. The helper's reply says
/// the request was taken; the restore itself is the control plane's to finish, and on the
/// wedged `io_connect_t` of `docs/SAFETY.md` § 4 it may never come. So every string below
/// reports the helper's own answer and stops there — `CLAUDE.md` rule 6, in the one place a
/// user reads *because* they no longer trust what the fans are doing.
///
/// Two claims this command is specifically forbidden from making, and neither is
/// hypothetical:
///
/// - **"Your fans are back on automatic."** Nothing in the reply carries that. A user who
///   read it would stop at step 3 of `docs/RECOVERY.md` with the fans still wrong.
/// - **"Nothing happened, because this build has no write path."** True of the helper that
///   ships today and not something *this* process can know: the panic path deliberately
///   sends no `hello`, so there is no `HelloReply.capabilities` in hand, and a `fanctl` from
///   one release talking to a helper from another is the ordinary case. Stating the helper's
///   build from the client would be the same defect pointed the other way.
///
/// ## Every failure ends at the same place
///
/// A user runs this because the fans are wrong. Whatever went wrong *here*, the next thing
/// they need is the step that needs neither this command nor a working connection — stopping
/// the daemon — so every unconfirmed outcome prints it. The reason above it is the error's
/// own `errorDescription` rather than a second set of strings written here: `HelperClient`
/// already distinguishes "unreachable", "never answered" and "answer lost", and a paraphrase
/// in this file would be free to drift away from what the client actually decided.
enum ResetCommand {

    /// What the command prints, and whether it exits non-zero.
    ///
    /// Two fields rather than a thrown error, so the text and the exit code are one value a
    /// test can assert as a pair. `Fanctl.Reset.emit(_:)` is the only thing that turns it
    /// into swift-argument-parser's vocabulary.
    struct Report: Equatable {
        let text: String
        let isFailure: Bool
    }

    /// What this client calls itself. Never sent by this command — the panic path carries no
    /// `hello` — but the connection is constructed with it, and a client that named itself
    /// something else here than in a later handshake would be two clients in the helper's log.
    static let clientDescription = "fanctl \(Fanctl.toolVersion)"

    /// `docs/RECOVERY.md` step 4, inline.
    ///
    /// The service name is read from `AeolusXPCService`, not typed out, because the launchd
    /// label and the mach service name are the same string and a recovery instruction that
    /// named a stale one would fail in exactly the situation it is printed in.
    static let stopTheHelper = """
        If the fans are still wrong, stop the helper. That is the next step in \
        docs/RECOVERY.md and it needs neither this command nor a working connection:

            sudo launchctl bootout system/\(AeolusXPCService.machServiceName)
        """

    /// The helper took the request. That is the whole of what it said.
    static let accepted = Report(
        text: """
            The helper accepted the reset request.

            That is all it confirmed. It has not reported that any fan is back under \
            automatic control, and this command will not say so on its behalf. Watch \
            whether the fans respond to load; if they do not, continue with \
            docs/RECOVERY.md.
            """,
        isFailure: false)

    /// No confirmed answer came back, for whatever reason the client gave.
    ///
    /// Deliberately not "the reset failed": on `helperNeverAnswered` and `replyNotDelivered`
    /// the helper may well have done the work, and claiming otherwise would be the same
    /// class of error as claiming success — a statement about the machine that nothing
    /// observed.
    static func unconfirmed(_ error: any Error) -> Report {
        Report(
            text: """
                The helper did not confirm the reset request.

                \(reason(for: error))

                \(stopTheHelper)
                """,
            isFailure: true)
    }

    /// Runs one restore attempt and reports what came back.
    ///
    /// **No retry, and none may be added here.** `HelperClient` does not retry by design —
    /// a client hammering a mach name that launchd may be restarting a daemon behind is a
    /// boot-loop amplifier — and a retry loop bolted on in the CLI would reintroduce exactly
    /// that, with a panicking user watching it.
    static func attempt(_ restore: () async throws -> Void) async -> Report {
        do {
            try await restore()
            return accepted
        } catch {
            return unconfirmed(error)
        }
    }

    /// The error's own words. `HelperClientError` and `AeolusXPCFault` are both
    /// `LocalizedError`, which covers every refusal and every transport failure that can
    /// reach here; `String(describing:)` is the backstop so an unanticipated error still
    /// reaches the terminal rather than vanishing.
    private static func reason(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Thrown so swift-argument-parser exits non-zero and prints the report.
    ///
    /// `LocalizedError` rather than `ValidationError`: nothing about the invocation was
    /// wrong, so a usage block below the message would send the reader looking for a typo
    /// instead of at the recovery step. Same reasoning as `FanctlError`'s.
    struct Unconfirmed: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
}

// MARK: - Command wiring

extension Fanctl.Reset {

    /// There is no per-fan reset, and saying so at parse time is cheaper than a connection
    /// that could only refuse.
    ///
    /// Taking one fan back means holding it, which means a lease, which means a write path;
    /// this build has none. `--all` is the whole of the command today, so a bare
    /// `fanctl reset` is an incomplete invocation rather than a runtime failure — which is
    /// what makes `ValidationError` the right type: it prints usage, where `--all` is listed.
    func validate() throws {
        guard all else {
            throw ValidationError(
                """
                fanctl reset returns every fan to automatic control and drops every lease, \
                and --all is how you ask for it. There is no per-fan reset: taking a single \
                fan back means holding it under a lease, and this build has no write path to \
                grant one. Run: fanctl reset --all
                """)
        }
    }

    func run() async throws {
        // `HelperClientDeadlines.default` — so this call waits `panicVerb` (10 s) rather
        // than a gated verb's 5 s. The panic path restores every fan and drops every lease
        // before it answers, and a client that gave up on it at a read's deadline would
        // report "no answer" about a helper that was working.
        let client = HelperClient(clientDescription: ResetCommand.clientDescription)
        let report = await ResetCommand.attempt { try await client.restoreAllToAutomatic() }

        // Invalidated rather than dropped, even though the process is about to exit and
        // this connection holds no lease. `HelperClient` releases a connection's helper-side
        // session from the invalidation handler; letting the reference die instead would
        // leave that teardown to whenever libxpc noticed the peer had gone.
        await client.disconnect()

        try Self.emit(report)
    }

    /// The same command with the round trip injected, so the suite can drive it against a
    /// real helper session over a real listener — and, in `fanctlTests`, against the specific
    /// failures a listener cannot conveniently produce.
    func run(restoring restore: () async throws -> Void) async throws {
        try Self.emit(await ResetCommand.attempt(restore))
    }

    /// Both outcomes leave through a thrown error, because that is how swift-argument-parser
    /// is told an exit code: `CleanExit` prints to stdout and exits 0, anything else prints
    /// to stderr and exits non-zero.
    private static func emit(_ report: ResetCommand.Report) throws -> Never {
        guard report.isFailure else { throw CleanExit.message(report.text) }
        throw ResetCommand.Unconfirmed(text: report.text)
    }
}
