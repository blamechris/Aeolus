import AeolusXPC
import AeolusXPCClient
import ArgumentParser
import FanKit
import Foundation

/// `fanctl set <fan|all> <N%|Nrpm> --for <duration>` — a bounded hold for the life of the process.
///
/// The contract is [#317](https://github.com/blamechris/Aeolus/issues/317), decided on architect
/// review, and [ADR 0013](../../docs/ADR/0013-fanctl-control-contract.md) D1. **This command does
/// not reach `main` before E5 and the owner-supervised E4 acceptance** (#7, #9, #15): it is
/// built and tested against a simulated helper, and nothing here has driven a fan. Today `set`
/// exits 4 against every helper that has shipped, and that holds until the branch's write plane
/// is built.
///
/// ## The sequence
///
/// Handshake, one snapshot, validate (exit 2), **one** `acquireLease` (30-second lifetime, not
/// self-renewing, held by `fanctl <version> (pid N)`), `apply`, a snapshot in which every
/// covered fan carries the helper's held target, `started`. Then every ten seconds: renew, then
/// snapshot. When the hold ends: release, and the safe-state check `fanctl auto` ends on
/// (`SafeState`, exit 0, 8 or 9).
///
/// **The lease is renewed from the moment it is asked for**, not from the moment `apply`
/// answers: the helper's thirty seconds start at the grant and `apply` may take a minute or
/// more (`LeaseKeeper`). One schedule runs the whole way, and a lapse during `apply` is control
/// lost, never a refusal.
///
/// ## Why it never retries and never re-acquires
///
/// A lease is the proof that something still wants the fans. Re-acquiring one after losing it
/// would be this process deciding, alone, that it still does, over a machine that may be hot
/// because the helper took the fans back for a reason. Every loss the helper reports is exit 6
/// (or 8 or 9, if the safe-state check after the best-effort release finds worse), and the person
/// or script that wants the fans again asks again.
///
/// ## What a loss is, and what it is not
///
/// A renewal that errored, a snapshot that does not list this lease, `isReclaimedBySystem` on
/// a fan this lease covers, a thermal emergency, or a covered fan the helper states **no held
/// target** for. **Never `mode` alone:** the helper reports an unreadable `F<n>Md` as
/// `automatic` ([#178](https://github.com/blamechris/Aeolus/issues/178)), so a fan that reads
/// automatic beside a lease the helper lists is not evidence of anything. The held target is:
/// the helper states one only while the same snapshot shows the fan held under the live lease,
/// with no reclamation and no thermal override (`FanState.targetRPM`, #426).
///
/// ## What it may say
///
/// "Holding" is said once, after `apply` was accepted and a snapshot showed every covered fan
/// with the helper's held target under this lease; the speed is a **target**, never the fan's
/// speed, and the helper's own reading travels beside it (`observed`). Nothing is claimed to
/// have reached a fan.
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
        /// The parent's process ID when the run began, to be compared with at every heartbeat and
        /// by every write that waits.
        let startingParent: Int32
    }

    /// The ordinary ways a hold ends. Each releases the lease and checks the safe state.
    enum Ending: Equatable, Sendable {
        case durationElapsed
        case signal(HoldSignal)
        /// A signal that landed while the speed was being applied or confirmed, and ended the run
        /// before `started`: no hold was begun, so the text does not say one ended. `--json`
        /// gives it the same `endedBecause` as `signal`; no `started` comes before it.
        case signalBeforeHold(HoldSignal)
        case parentExited
        case outputClosed

        /// The stable identifier `--json` carries as `endedBecause`.
        var endedBecause: String {
            switch self {
            case .durationElapsed: return "durationElapsed"
            case .signal, .signalBeforeHold: return "signal"
            case .parentExited: return "parentExited"
            case .outputClosed: return "outputClosed"
            }
        }

        var signal: HoldSignal? {
            switch self {
            case .signal(let signal), .signalBeforeHold(let signal): return signal
            case .durationElapsed, .parentExited, .outputClosed: return nil
            }
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
        /// The snapshot lists this run's lease and states **no held target** for a fan it
        /// covers: the helper does not say the fan is held. `FanState.targetRPM` is non-nil only
        /// while the same snapshot shows the fan in manual under the live lease, with no
        /// reclamation and no thermal override.
        case fanNotHeld(Int)
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

        // **Before the request is sent**, never after it is answered. The helper's thirty
        // seconds start at the grant, which is no earlier than this instant, so a renewal
        // scheduled from here is due no later than the helper's own clock says. Taken after the
        // answer it would be late by however long the answer took.
        let requestedAt = session.clock.now()
        let lease: Lease
        do {
            lease = try await session.client.acquireLease(leaseRequest(for: plans))
        } catch {
            return .notStarted(HelperCommandFailure(classifying: error, during: .beforeControl))
        }

        let hold = Hold(leaseID: lease.id, plans: plans, duration: request.duration)

        // A signal that landed while the lease was in flight. The lease is held and no speed
        // has been sent: give it back without sending one, for a person who asked to stop.
        if let signal = session.interrupt.pending {
            let release = await release(lease.id, using: session.client)
            return .interruptedBeforeApply(signal, hold: hold, release: release)
        }

        return await establish(hold, leaseRequestedAt: requestedAt, in: session)
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
    /// **It takes the schedule over from `LeaseKeeper`**: `renewedAt` is when the last renewal
    /// was sent, or when the lease was asked for if the keeper sent none. A loop that started
    /// its own schedule here, at the moment the hold begins, would leave up to a whole
    /// `apply` between the last renewal and the next, and there would be two schedules.
    ///
    /// **The deadline is minted here, on `session.clock`, and compared here.** `Lease.expiresAt`
    /// is the helper's wall-clock estimate and is never consulted: a step in the wall clock
    /// must not lengthen or shorten a hold. A deadline handed in from outside would be an
    /// instant minted somewhere else, which a clock that does not move can never reach.
    ///
    /// **Each renewal is scheduled from the last one, not from the end of the work after it.** A
    /// loop that slept a whole heartbeat after every renewal, snapshot and write would renew
    /// every ten seconds *plus* whatever those took, and a slow hand-over would eat the two
    /// missed heartbeats the lease can spare. Here a late one shortens the next sleep.
    ///
    /// **Nothing in the loop waits on standard output.** Lines are handed to a pump; the loop
    /// looks at the pump, which never blocks. A sleep is cut short at the moment the oldest
    /// unfinished line would count as stalled, so a consumer that stops draining ends the hold
    /// two seconds after the line it stopped on, whatever the heartbeat is doing. When a stop
    /// request (a signal, the parent exiting, the deadline) and a stalled consumer are both
    /// true, the stop request is the reason.
    ///
    /// Returns the snapshot the loop last read, for the closing report.
    static func heartbeats(
        _ hold: Hold, from confirmation: SystemSnapshot,
        renewedAt lastRenewal: ContinuousClock.Instant,
        startingParent: Int32, in session: Session
    ) async -> (end: HoldEnd, snapshot: SystemSnapshot) {
        var latest = confirmation
        let deadline = session.clock.now() + hold.duration
        let watch = StopWatch(
            interrupt: session.interrupt, environment: session.environment, clock: session.clock,
            startingParent: startingParent, deadline: deadline)
        let output = session.output
        var renewedAt = lastRenewal
        while true {
            var now = session.clock.now()
            let remaining = deadline - now
            // Why to stop, in the order a stop request is judged (a signal, the parent, the
            // deadline), and only then that standard output is not taking lines.
            if let reason = watch.reason { return (.ended(reason), latest) }
            if output.hasTrouble(at: now) { return (.ended(.outputClosed), latest) }

            // A signal that arrived while the loop was busy with the helper is not looked for
            // separately: the sleep ends at once for a signal already pending.
            let untilNextRenewal = max(renewedAt + heartbeat - now, .zero)
            var sleeping = min(untilNextRenewal, remaining)
            if let untilTrouble = output.untilTrouble(from: now) {
                sleeping = min(sleeping, untilTrouble)
            }
            let woke = await session.interrupt.sleep(for: sleeping, on: session.clock)
            switch woke {
            case .signal(let signal): return (.ended(.signal(signal)), latest)
            case .failed: return (.timerFailed, latest)
            case .elapsed: break
            }
            // Not renewed at the deadline: the lease is about to be released.
            now = session.clock.now()
            if let reason = watch.reason { return (.ended(reason), latest) }
            // Woken to look at standard output, not to renew: the top of the loop judges it.
            if now < renewedAt + heartbeat { continue }

            renewedAt = now
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
            output.holding(hold, snapshot: latest, remaining: left)
        }
    }

    /// Whether `snapshot` says the lease is no longer proof of control, which is also whether it
    /// is evidence of control at all: this is the one judgement behind `started` and behind every
    /// `holding`.
    ///
    /// In this order: the lease is not listed, a thermal emergency is active, or a fan the lease
    /// covers is no longer reported at all, is reclaimed, or carries **no held target**.
    ///
    /// **The held target is the evidence a fan is held.** `FanState.targetRPM` is non-nil only
    /// while the same snapshot shows the fan in manual under the live lease, with no
    /// reclamation and no thermal override (#426). A fan beside a lease the helper lists that
    /// carries none, because the firmware took it back and the watchdog has not marked it yet,
    /// is not held, and "holding" is not said about it. A target that is not positive is no
    /// target: nothing is ever held at 0 RPM.
    ///
    /// **`mode` is not read.** A fan that reads automatic beside a lease the helper lists is the
    /// helper's report of a mode it could not read as often as it is anything else; the held
    /// target already says what the mode could not.
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
            guard let held = fan.targetRPM, held > 0 else { return .fanNotHeld(index) }
        }
        return nil
    }

    // MARK: - The ending

    /// Releases the lease and checks the safe state, **whatever ended the hold**.
    ///
    /// The release is **best-effort and nothing waits on its answer**: a refusal is reported and
    /// the check that follows decides the exit. A loss (6) used to skip the check, on the
    /// grounds that there was nothing to confirm a return to and that the check can take its
    /// whole ten-second window against a thermal emergency that will not clear. But a fan can
    /// be engaged, the release answered accepted and its restore refused, and "nothing is held"
    /// said over a fan that is still pinned is a claim nothing observed (`CLAUDE.md` rule 6).
    /// The window costs the fans nothing: during an emergency § 3 is driving them either way.
    /// A signal that arrives from here on is ignored: the loop is no longer looking. (Nothing
    /// that ends before `started` skips the check either: see `establish`.)
    static func finish(
        _ end: HoldEnd, hold: Hold, snapshot: SystemSnapshot?, in session: Session
    ) async -> Report {
        let release = await release(hold.leaseID, using: session.client)
        let settlement = await checkSafeState(in: session)
        switch end {
        case .lost(let loss):
            return .lost(
                loss, hold: hold, release: release, settlement: settlement, before: snapshot)
        case .timerFailed:
            return .timerFailed(
                hold: hold, release: release, settlement: settlement, before: snapshot)
        case .ended(let ending):
            return .ended(
                ending, hold: hold, release: release, settlement: settlement, before: snapshot)
        }
    }

    /// The check `fanctl auto` ends on, after a release. A signal that arrives from here on is
    /// not looked at.
    static func checkSafeState(in session: Session) async -> SafeState.Settlement {
        await SafeState.settle(
            reading: { try await session.client.snapshot() }, clock: session.clock)
    }

    static func release(_ id: UUID, using client: HelperClient) async -> Release {
        do {
            try await client.releaseLease(id: id)
            return .accepted
        } catch {
            return .failed(describe(error))
        }
    }
}
