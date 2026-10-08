import AeolusXPC
import AeolusXPCClient
import ArgumentParser
import FanKit
import Foundation

/// `fanctl set <fan|all> <N%|Nrpm> --for <duration>` — a bounded hold for the life of the process.
///
/// The contract is [#317](https://github.com/blamechris/Aeolus/issues/317), decided on architect
/// review, and [ADR 0013](../../docs/ADR/0013-fanctl-control-contract.md) D1. **This command does
/// not merge before E5 and the owner-supervised E4 acceptance** (#7, #9, #15): it is built and
/// tested against a simulated helper, and nothing here has driven a fan.
///
/// ## The sequence
///
/// Handshake, one snapshot, validate (exit 2), **one** `acquireLease` (30-second lifetime, not
/// self-renewing, held by `fanctl <version> (pid N)`), `apply`, a snapshot that lists this
/// lease, `started`. Then every ten seconds: renew, then snapshot. When the hold ends: release,
/// and the safe-state check `fanctl auto` ends on (`SafeState`, exit 0, 8 or 9).
///
/// ## Why it never retries and never re-acquires
///
/// A lease is the proof that something still wants the fans. Re-acquiring one after losing it
/// would be this process deciding, alone, that it still does, over a machine that may be hot
/// because the helper took the fans back for a reason. Every loss the helper reports is exit 6
/// after a best-effort release, and the person or script that wants the fans again asks again.
///
/// ## What a loss is, and what it is not
///
/// A renewal that errored, a snapshot that does not list this lease, `isReclaimedBySystem` on a
/// fan this lease covers, or a thermal emergency. **Never `mode` alone:** the helper reports an
/// unreadable `F<n>Md` as `automatic` ([#178](https://github.com/blamechris/Aeolus/issues/178)),
/// so a fan that reads automatic beside a lease the helper lists is not evidence of anything.
///
/// ## What it may say
///
/// "Holding" is said once, after `apply` was accepted and a snapshot listed this lease; the
/// speed is a **target**, never the fan's speed, and the helper's own reading travels beside it
/// (`observed`). Nothing is claimed to have reached a fan.
enum SetCommand {

    /// The fans `set` took, and for how long it asked to keep them.
    struct Hold: Sendable {
        let leaseID: UUID
        let plans: [SetFanPlan]
        let duration: Duration

        var fans: [Int] { plans.map(\.index) }
        var durationSeconds: Int { Int(duration.components.seconds) }
    }

    /// Everything a run is wired to. The suite substitutes each seam; `Fanctl.Set.run()` builds
    /// this from its own properties and nothing else.
    struct Session: Sendable {
        let client: HelperClient
        let clock: SettleClock
        let environment: HoldEnvironment
        let interrupt: HoldInterrupt
        let output: SetOutput
    }

    /// The ordinary ways a hold ends. Each releases the lease and checks the safe state.
    enum Ending: Equatable, Sendable {
        case durationElapsed
        case signal(HoldSignal)
        case parentExited
        case outputClosed

        /// The stable identifier `--json` carries as `endedBecause`.
        var endedBecause: String {
            switch self {
            case .durationElapsed: return "durationElapsed"
            case .signal: return "signal"
            case .parentExited: return "parentExited"
            case .outputClosed: return "outputClosed"
            }
        }

        var signal: HoldSignal? {
            guard case .signal(let signal) = self else { return nil }
            return signal
        }
    }

    /// What the helper reported that means the lease is no longer proof of control. Exit 6.
    enum Loss: Equatable, Sendable {
        case renewalFailed(String)
        case snapshotFailed(String)
        /// The snapshot does not list this run's lease; it lists `listed`, or none.
        case leaseNotListed(listed: ListedLease?)
        case reclaimed(fan: Int)
        case thermalEmergency
        case fanNotReported(Int)
    }

    /// Another client's lease, as a snapshot named it.
    struct ListedLease: Equatable, Sendable {
        let id: UUID
        let holder: String
    }

    /// What became of the request to release the lease. Best-effort: nothing waits on it.
    enum Release: Equatable, Sendable {
        case accepted
        case failed(String)

        var isAccepted: Bool { self == .accepted }
    }

    /// How the loop stopped.
    enum HoldEnd: Sendable {
        case ended(Ending)
        case lost(Loss)
        /// The loop's own timer failed. It cannot pace heartbeats without one.
        case timerFailed
    }

    // MARK: - The run

    /// One run, start to finish: everything that reaches the helper, and the report of it.
    static func perform(_ request: SetArguments.Request, in session: Session) async -> Report {
        let startingParent = session.environment.parentProcessID()

        let first: SystemSnapshot
        do {
            first = try await session.client.snapshot()
        } catch {
            return .notStarted(HelperCommandFailure(classifying: error, during: .beforeControl))
        }

        let plans: [SetFanPlan]
        switch SetPlan.make(selection: request.selection, speed: request.speed, snapshot: first) {
        case .failure(let failure): return .notStarted(failure)
        case .success(let made): plans = made
        }

        // A signal that arrived while connecting. Nothing is held yet, so nothing is written
        // for a person who has already asked to stop.
        if let signal = session.interrupt.pending { return .interruptedBeforeControl(signal) }

        let lease: Lease
        do {
            lease = try await session.client.acquireLease(leaseRequest(for: plans))
        } catch {
            return .notStarted(HelperCommandFailure(classifying: error, during: .beforeControl))
        }

        let hold = Hold(leaseID: lease.id, plans: plans, duration: request.duration)
        do {
            try await session.client.apply(settings(for: plans), leaseID: lease.id)
        } catch {
            // The lease exists and nothing was accepted under it: give it back, and leave with
            // the code `apply`'s own failure classifies to.
            let release = await release(lease.id, using: session.client)
            return .refused(
                HelperCommandFailure(classifying: error, during: .beforeControl), hold: hold,
                release: release)
        }

        // Control is held from here: `apply` was accepted. What is still to be seen is whether
        // the helper lists this lease.
        let confirmation: SystemSnapshot
        do {
            confirmation = try await session.client.snapshot()
        } catch {
            return await finish(
                .lost(.snapshotFailed(describe(error))), hold: hold, snapshot: nil, in: session)
        }
        if let loss = loss(in: confirmation, leaseID: lease.id, covering: hold.fans) {
            return await finish(.lost(loss), hold: hold, snapshot: confirmation, in: session)
        }
        guard session.output.started(hold, snapshot: confirmation) else {
            return await finish(
                .ended(.outputClosed), hold: hold, snapshot: confirmation, in: session)
        }

        let (end, latest) = await heartbeats(
            hold, from: confirmation, startingParent: startingParent, in: session)
        return await finish(end, hold: hold, snapshot: latest, in: session)
    }

    /// The holder the helper lists: this tool, its version, and the process, so a person looking
    /// at `fanctl status` can find the terminal it is in.
    static var holderDescription: String {
        "fanctl \(Fanctl.toolVersion) (pid \(getpid()))"
    }

    /// The one lease request a run makes. Not self-renewing, and the default lifetime: a hold
    /// that outlives its process is persistence, which ADR 0007 refuses in v1.
    static func leaseRequest(for plans: [SetFanPlan]) -> LeaseRequest {
        LeaseRequest(
            holderDescription: holderDescription, fanIndices: plans.map(\.index),
            timeToLive: Lease.defaultTimeToLive, isSelfRenewing: false)
    }

    static func settings(for plans: [SetFanPlan]) -> [FanSetting] {
        plans.map { FanSetting(fanIndex: $0.index, control: .fixed(rpm: $0.commandedRPM)) }
    }

    // MARK: - The hold

    /// How often the lease is renewed and the snapshot read: a third of its lifetime, so two
    /// heartbeats can be missed before the helper lets go.
    static let heartbeat = Duration.seconds(Lease.defaultHeartbeatInterval)

    /// Renews and looks, every `heartbeat`, until something ends the hold.
    ///
    /// **The deadline is minted here, on `session.clock`, and compared here.** `Lease.expiresAt`
    /// is the helper's wall-clock estimate and is never consulted: a step in the wall clock
    /// must not lengthen or shorten a hold. A deadline handed in from outside would be an
    /// instant minted somewhere else, which a clock that does not move can never reach.
    ///
    /// Returns the snapshot the loop last read, for the closing report.
    static func heartbeats(
        _ hold: Hold, from confirmation: SystemSnapshot, startingParent: Int32, in session: Session
    ) async -> (end: HoldEnd, snapshot: SystemSnapshot) {
        var latest = confirmation
        let deadline = session.clock.now() + hold.duration
        while true {
            let remaining = deadline - session.clock.now()
            if remaining <= .zero { return (.ended(.durationElapsed), latest) }

            // A signal that arrived while the loop was busy with the helper is not looked for
            // separately: the sleep ends at once for a signal already pending.
            let woke = await session.interrupt.sleep(
                for: min(heartbeat, remaining), on: session.clock)
            switch woke {
            case .signal(let signal): return (.ended(.signal(signal)), latest)
            case .failed: return (.timerFailed, latest)
            case .elapsed: break
            }
            // Not renewed at the deadline: the lease is about to be released.
            if session.clock.now() >= deadline { return (.ended(.durationElapsed), latest) }
            if session.environment.parentProcessID() != startingParent {
                return (.ended(.parentExited), latest)
            }

            do {
                _ = try await session.client.renewLease(id: hold.leaseID)
            } catch {
                return (.lost(.renewalFailed(describe(error))), latest)
            }

            do {
                latest = try await session.client.snapshot()
            } catch {
                return (.lost(.snapshotFailed(describe(error))), latest)
            }
            if let loss = loss(in: latest, leaseID: hold.leaseID, covering: hold.fans) {
                return (.lost(loss), latest)
            }
            let left = max(deadline - session.clock.now(), .zero)
            if !session.output.holding(hold, snapshot: latest, remaining: left) {
                return (.ended(.outputClosed), latest)
            }
        }
    }

    /// Whether `snapshot` says the lease is no longer proof of control.
    ///
    /// In this order: the lease is not listed, a thermal emergency is active, or a fan the lease
    /// covers is reclaimed (or is no longer reported at all, which this run cannot call holding).
    /// **`mode` is not read.** A fan that reads automatic beside a lease the helper lists is the
    /// helper's report of a mode it could not read as often as it is anything else.
    static func loss(in snapshot: SystemSnapshot, leaseID: UUID, covering fans: [Int]) -> Loss? {
        guard let listed = snapshot.activeLease, listed.id == leaseID else {
            return .leaseNotListed(
                listed: snapshot.activeLease.map {
                    ListedLease(id: $0.id, holder: DisplayText.sanitised($0.holderDescription))
                })
        }
        if snapshot.isThermalEmergencyActive { return .thermalEmergency }
        for index in fans {
            guard let fan = snapshot.fans.first(where: { $0.index == index }) else {
                return .fanNotReported(index)
            }
            if fan.isReclaimedBySystem { return .reclaimed(fan: index) }
        }
        return nil
    }

    // MARK: - The ending

    /// Releases the lease, and for an ordinary ending checks the safe state.
    ///
    /// The release is **best-effort and nothing waits on its answer**: a refusal is reported and
    /// the check that follows decides the exit. A loss (6) and a refusal skip the check — there
    /// is nothing to confirm a return to, and `fanctl auto` is how to ask — and a signal that
    /// arrives from here on is ignored: the loop is no longer looking.
    static func finish(
        _ end: HoldEnd, hold: Hold, snapshot: SystemSnapshot?, in session: Session
    ) async -> Report {
        let release = await release(hold.leaseID, using: session.client)
        switch end {
        case .lost(let loss):
            return .lost(loss, hold: hold, release: release, snapshot: snapshot)
        case .timerFailed:
            return .timerFailed(hold: hold, release: release, snapshot: snapshot)
        case .ended(let ending):
            let settlement = await SafeState.settle(
                reading: { try await session.client.snapshot() }, clock: session.clock)
            return .ended(
                ending, hold: hold, release: release, settlement: settlement, before: snapshot)
        }
    }

    static func release(_ id: UUID, using client: HelperClient) async -> Release {
        do {
            try await client.releaseLease(id: id)
            return .accepted
        } catch {
            return .failed(describe(error))
        }
    }

    /// An error in the words the client chose, for a message about a lease already held: every
    /// failure there is a loss of control whatever its type.
    static func describe(_ error: any Error) -> String {
        HelperCommandFailure(classifying: error, during: .holdingControl).message
    }
}
