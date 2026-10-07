import AeolusXPC
import AeolusXPCClient
import ArgumentParser
import FanKit
import Foundation

/// `fanctl auto` — ask the helper to return every fan to automatic control, then look.
///
/// The contract is [ADR 0013](../../docs/ADR/0013-fanctl-control-contract.md) D2 and D3.
///
/// ## What it does
///
/// Handshake, then one snapshot. If the helper reports no lease and every fan cleared — mode
/// automatic, and no availability that says otherwise (`SafeState`) — that is the answer: exit
/// 0, and **nothing was written**. Otherwise it sends `restoreAllToAutomatic` **once** and reads
/// the snapshot until the helper reports the safe state or ten seconds have passed
/// (`SafeState.settle`). It is never re-sent in a run, so there is no tug-of-war with whatever
/// else writes to the fans. A fan the helper has not cleared, whatever its mode reads, is a
/// reason to send it: the request carries the `restoreAbandoned` sweep, which is a stranded
/// fan's only route out (#189).
///
/// ## What it does not do
///
/// - **Take a lease.** Not to return a fan, not briefly, not to make a per-fan form possible.
///   A per-fan "acquire, apply automatic, release" reaches only fans that are already
///   automatic, and the release then writes a restore to every fan the lease covered.
/// - **Take one fan.** `auto <index>` is refused at parse time (exit 64): no request the
///   helper accepts returns a fan on behalf of another process, so an index would either do
///   nothing or quietly return other fans too.
/// - **Retry, back off or escalate.** One request, one wait, one verdict.
///
/// ## It may end another client's lease, and says whose
///
/// A command that moves toward the safe state may override another client; one that moves away
/// from it may not (`set` gets exit 5). Refusing here would fail exactly when a hold was
/// orphaned or forgotten. A lease the first snapshot listed that the last no longer does is
/// named in the text and in `--json`'s `endedLease`, as **no longer listed** — it may also have
/// expired inside the window, and the output says only what was observed. If it was this
/// request that dropped it, that client sees its lease lost, which is accurate.
///
/// ## What it is allowed to say
///
/// Exit 0 means **"the helper reports every fan automatic and no lease"** — not "the fans are".
/// An unreadable `F<n>Md` is also reported as automatic ([#178]), which is why the availability
/// is read beside the mode, but even so the strongest honest sentence is the one that names its
/// source, and no string here says more. A run that did not end in the safe state never says it
/// did, on either stream.
///
/// [#178]: https://github.com/blamechris/Aeolus/issues/178
enum AutoCommand {

    // MARK: - What a run observed

    /// Everything a run learned from the helper, once at least one snapshot was read.
    struct Observation: Sendable {
        /// Whether this run sent `restoreAllToAutomatic`. `false` only when the first snapshot
        /// already reported the safe state.
        let restoreRequested: Bool
        /// Why the helper did not confirm that request, if it did not. The wait still ran: a
        /// request whose reply was lost may well have landed, and the snapshot decides.
        let restoreFailure: String?
        /// The lease the first snapshot listed that the last one no longer does. **Not** a claim
        /// that this run ended it: the lease may equally have expired inside the window, and
        /// the output says only what was observed.
        let endedLease: Lease?
        /// The last snapshot the helper returned. If `interruption` is set it may predate the
        /// end of the wait.
        let snapshot: SystemSnapshot
        let verdict: SafeState.Verdict
        /// Why the wait stopped early, in the error's own words.
        let interruption: String?
        /// Whether `snapshot` was read after the restore request was sent, so `fans` and
        /// `lease` describe the helper after the request rather than before it. `false` when
        /// no request was sent, and when the wait could not read a second snapshot and
        /// `snapshot` is the one from before.
        let snapshotFollowsRestore: Bool
        /// Why the first snapshot could not be read, when the run went on without it. Set only
        /// on the run that sent the request on a handshake alone.
        let firstSnapshotFailure: String?

        init(
            restoreRequested: Bool, restoreFailure: String?, endedLease: Lease?,
            snapshot: SystemSnapshot, verdict: SafeState.Verdict, interruption: String?,
            snapshotFollowsRestore: Bool, firstSnapshotFailure: String? = nil
        ) {
            self.restoreRequested = restoreRequested
            self.restoreFailure = restoreFailure
            self.endedLease = endedLease
            self.snapshot = snapshot
            self.verdict = verdict
            self.interruption = interruption
            self.snapshotFollowsRestore = snapshotFollowsRestore
            self.firstSnapshotFailure = firstSnapshotFailure
        }

        /// The lease present when the wait ended — only if the wait ended by looking. After an
        /// interruption the last snapshot's lease is the last thing seen, not the thing there.
        var leaseAtEnd: Lease? { interruption == nil ? snapshot.activeLease : nil }

        /// The exit, in the order 9, 5, 8; `nil` for the safe state.
        var failure: HelperCommandFailure? {
            switch verdict {
            case .automatic:
                return nil
            case .cannotReturn(let fans):
                return HelperCommandFailure(
                    .cannotReturnToAutomatic, AutoCommand.cannotReturnMessage(self, pinned: fans))
            case .notConfirmed:
                if let lease = leaseAtEnd {
                    return HelperCommandFailure(
                        .heldByAnotherClient, AutoCommand.leasePresentMessage(self, lease: lease))
                }
                return HelperCommandFailure(
                    .safeStateNotConfirmed, AutoCommand.notConfirmedMessage(self))
            }
        }
    }

    /// How a run ended.
    enum Outcome: Sendable {
        /// At least one snapshot was read: the exit follows the observation, and `--json` still
        /// carries the fans.
        case observed(Observation)
        /// No snapshot could be read: 3, 7 or 1, and `--json` is the plain failure document.
        case unreadable(HelperCommandFailure)
    }

    // MARK: - The run

    /// One handshake, one snapshot, at most one restore, and the wait for its result.
    ///
    /// `Fanctl.Auto.run()` is the only caller; `FanctlAutoTests` reaches this through `run()`.
    static func perform(on client: HelperClient, clock: SettleClock) async -> Outcome {
        let first: SystemSnapshot
        do {
            first = try await client.snapshot()
        } catch {
            return await afterUnreadableFirstSnapshot(error, on: client, clock: clock)
        }

        if SafeState.verdict(for: first) == .automatic {
            return .observed(
                Observation(
                    restoreRequested: false, restoreFailure: nil, endedLease: nil, snapshot: first,
                    verdict: .automatic, interruption: nil, snapshotFollowsRestore: false))
        }

        let restoreFailure = await requestRestore(on: client)
        let settlement = await SafeState.settle(
            reading: { try await client.snapshot() }, clock: clock)
        let last = settlement.snapshot ?? first
        return .observed(
            Observation(
                restoreRequested: true, restoreFailure: restoreFailure,
                endedLease: endedLease(first: first, last: last), snapshot: last,
                verdict: settlement.verdict,
                interruption: settlement.interruption.map(describe),
                snapshotFollowsRestore: settlement.snapshot != nil))
    }

    /// **The one request, and the only call site of `restoreAllToAutomatic` in `fanctl auto`.**
    ///
    /// Returns why the helper did not confirm it, or `nil`. Whether it was acknowledged does not
    /// change what happens next: a reply that never arrived does not mean the restore did not
    /// land, and the snapshot is the only thing this command trusts either way.
    private static func requestRestore(on client: HelperClient) async -> String? {
        do {
            try await client.restoreAllToAutomatic()
            return nil
        } catch {
            return describe(error)
        }
    }

    /// The first lease, if the last snapshot no longer lists *that* lease.
    ///
    /// By identity, not by presence: a lease that is gone and one that was replaced by another
    /// client's are both no longer listed; one the restore left standing is not, and saying it
    /// was would be a claim about an outcome the helper contradicts. Absent from the last
    /// snapshot is all this establishes — it does not say the restore was the cause.
    static func endedLease(first: SystemSnapshot?, last: SystemSnapshot) -> Lease? {
        guard let before = first?.activeLease else { return nil }
        return last.activeLease?.id == before.id ? nil : before
    }

    /// The first snapshot could not be read.
    ///
    /// - **A version mismatch** still sends the request: `restoreAllToAutomatic` is exempt from
    ///   the version gate (ADR 0005), because a fence that stopped the way back to automatic
    ///   control would defeat its own purpose. Nothing can then be verified across the
    ///   versions, and the message says so.
    /// - **A handshake that succeeded** (`negotiated` is in force) also sends it, once. The
    ///   helper is identified and answered `hello`; its *snapshot* is what failed, which is what
    ///   `docs/SAFETY.md` § 7 means by "when the helper's state is inconsistent" — a stale SMC
    ///   handle fails the snapshot while the lease core, and the `restoreAbandoned` sweep that
    ///   is a stranded fan's only route out, still work. The wait then runs as usual.
    /// - **Anything else** sends nothing: there is no identified peer to send a write request
    ///   to. Two failures *after* a successful handshake land here too, because each clears
    ///   `negotiated`: a snapshot that is never answered discards its connection, and a helper
    ///   that restarts under the snapshot (4097) drops the handshake it had negotiated.
    ///   `fanctl reset --all` is the way out, and the message opens by saying nothing was sent
    ///   and names it.
    private static func afterUnreadableFirstSnapshot(
        _ error: any Error, on client: HelperClient, clock: SettleClock
    ) async -> Outcome {
        let failure = HelperCommandFailure(classifying: error, during: .beforeControl)
        if failure.code == .protocolVersionMismatch {
            return await versionMismatch(failure, on: client)
        }
        guard await client.negotiated != nil else {
            guard failure.code == .failure else { return .unreadable(failure) }
            return .unreadable(
                HelperCommandFailure(.failure, nothingSentMessage(cause: failure.message)))
        }

        let restoreFailure = await requestRestore(on: client)
        let settlement = await SafeState.settle(
            reading: { try await client.snapshot() }, clock: clock)
        guard let snapshot = settlement.snapshot else {
            return .unreadable(
                HelperCommandFailure(
                    .safeStateNotConfirmed,
                    snapshotUnavailableMessage(
                        firstFailure: failure.message,
                        laterFailure: settlement.interruption.map(describe),
                        restoreFailure: restoreFailure)))
        }
        return .observed(
            Observation(
                restoreRequested: true, restoreFailure: restoreFailure, endedLease: nil,
                snapshot: snapshot, verdict: settlement.verdict,
                interruption: settlement.interruption.map(describe),
                snapshotFollowsRestore: true, firstSnapshotFailure: failure.message))
    }

    private static func versionMismatch(
        _ failure: HelperCommandFailure, on client: HelperClient
    ) async -> Outcome {
        let refusal = await requestRestore(on: client)
        let sent =
            refusal.map { "The helper did not confirm the request: \($0)" }
            ?? "The helper accepted the request."
        return .unreadable(
            HelperCommandFailure(
                .protocolVersionMismatch,
                """
                \(failure.message)

                fanctl sent the helper one request to return every fan to automatic control \
                anyway, because the helper exempts that request from the version check. \
                \(sent) fanctl cannot verify the result across protocol versions, so it reports \
                nothing about the fans. Use a fanctl built for the helper's protocol version \
                and run `fanctl status`; if the fans are still wrong, continue with \
                docs/RECOVERY.md.
                """))
    }

    private static func describe(_ error: any Error) -> String {
        HelperCommandFailure(classifying: error, during: .beforeControl).message
    }

    // MARK: - Leaving

    /// Writes what the run learned and leaves with its exit code.
    ///
    /// The result goes to standard output and the diagnosis to standard error, so a script that
    /// reads one never has to filter the other. Under `--json` standard output is the one
    /// document, whatever the exit code, and a run that read no snapshot prints the plain
    /// failure document instead.
    static func emit(
        _ outcome: Outcome, as format: HelperCommandOutput.Format, on terminal: Terminal
    ) throws {
        switch outcome {
        case .unreadable(let failure):
            try HelperCommandOutput.fail(failure, as: format, on: terminal)
        case .observed(let observation):
            switch format {
            case .text:
                terminal.say(text(for: observation))
            case .document, .lines:
                try HelperCommandOutput.emit(
                    AutoDocumentJSON(observation), as: format, on: terminal)
            }
            guard let failure = observation.failure else { return }
            terminal.warn(failure.message)
            throw failure.code.exitCode
        }
    }
}

// MARK: - Command wiring

extension Fanctl.Auto {

    /// Only `all`, or nothing.
    ///
    /// An index is refused here, before any connection: no request the helper accepts returns
    /// one fan on behalf of another process. A per-fan `auto` can be added later without
    /// breaking anyone; accepting an index now and doing something else would break whoever
    /// relied on it.
    func validate() throws {
        guard let target, target != "all" else { return }
        if !target.isEmpty, target.allSatisfy(\.isNumber) {
            throw ValidationError(
                """
                fanctl auto takes no fan index. No request the helper accepts returns one fan \
                on behalf of another process, so an index would either do nothing or quietly \
                return other fans too. fanctl auto returns every fan: run `fanctl auto`.
                """)
        }
        throw ValidationError(
            "fanctl auto takes no argument but `all` (the default); got '\(target)'. "
                + "Run `fanctl auto`.")
    }

    /// One handshake, at most one restore, the wait for its result, one disconnect.
    ///
    /// Everything here is asserted end to end by `FanctlAutoTests`, which reaches this function
    /// itself by setting `helper`, `terminal` and `clock`.
    func run() async throws {
        let format: HelperCommandOutput.Format = json ? .document : .text
        let client = helper.client()
        let outcome = await AutoCommand.perform(on: client, clock: clock)
        await client.disconnect()
        try AutoCommand.emit(outcome, as: format, on: terminal)
    }
}
