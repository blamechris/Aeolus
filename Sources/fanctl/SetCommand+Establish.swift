import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

// The step between the lease and the hold: send the speed, keep the lease alive while the helper
// works, and see whether the helper says the fans are held. Everything that can go wrong in that
// step is here, because every one of them is a lease that was taken and a speed that may have
// been sent, and what `set` says about it must be true.
//
// **One rule covers every way this step ends short of `started`:** the lease is released, the
// safe state is looked at, and the exit is the worse of the failure's own code and the check's
// verdict (9, then 8). A refused `apply`, one nobody answered, a lease that went, a confirming
// snapshot that failed or showed no hold, and a keeper that could not pace itself are all a lease
// that was taken and a speed that may have been sent. None of them says what the fans are doing.

extension SetCommand {

    /// What `apply` itself said, when control was lost before the hold began.
    enum ApplyAnswer: Equatable, Sendable {
        /// It was accepted.
        case accepted
        /// The helper answered with a fault, in its own words.
        case answered(String)
        /// It got no answer, with what the client saw instead.
        case unanswered(String)
    }

    /// What the snapshot after an **accepted** `apply` came to, when that is why the hold never
    /// began.
    enum LapseConfirmation: Equatable, Sendable {
        /// It could not be read.
        case snapshotFailed(String)
        /// It does not show control held.
        case notHeld(Loss)
        /// The keeper that renews the lease could not pace itself.
        case timerFailed
    }

    /// Control was lost before the hold began: the lease could no longer be **shown** to be held
    /// while the speed was being applied. Exit 6, or worse.
    ///
    /// **Control lost, never a refusal, and never a claim that the lease ended.** A renewal
    /// failed or went unanswered, `apply` answered that the lease is gone, `apply` went
    /// unanswered, or the snapshot after it did not show the fan held. What this run knows is
    /// what it saw; what the helper did with the lease and the fans is what the check after the
    /// release found.
    struct Lapse: Equatable, Sendable {
        /// The helper's words for the renewal that failed while `apply` worked, if one did.
        let renewalFailure: String?
        /// What `apply` itself said. With no failed renewal and an answer, this is the answer
        /// that the lease is gone, which is then the whole of how this run knows.
        let apply: ApplyAnswer
        /// The snapshot after an accepted `apply`, if that is the reason.
        let confirmation: LapseConfirmation?

        init(
            renewalFailure: String?, apply: ApplyAnswer, confirmation: LapseConfirmation? = nil
        ) {
            self.renewalFailure = renewalFailure
            self.apply = apply
            self.confirmation = confirmation
        }
    }

    /// What `apply` and the snapshot that confirms it came to.
    private enum Attempt {
        /// `apply` threw.
        case applyFailed(any Error)
        /// `apply` was accepted; this is what the snapshot after it did.
        case applied(Result<SystemSnapshot, any Error>)
    }

    /// The lease is held and no speed has been sent: send it, keep the lease alive while the
    /// helper works, and see whether the helper says the fans are held.
    ///
    /// **The lease is renewed on the heartbeat the whole time** (`LeaseKeeper`), because `apply`
    /// may take a minute or more and the helper's thirty seconds started at the grant. The
    /// keeper is stopped, and any renewal on the wire answered, **before** anything is released
    /// or the hold's loop starts, so there is one renewal schedule and no renewal after a
    /// release.
    ///
    /// **A signal that landed while `apply` was outstanding** is noted on whatever report this
    /// returns, and if everything else is well it ends the run before `started`: "Holding" is
    /// not said to a person who has already asked to stop.
    static func establish(
        _ hold: Hold, leaseRequestedAt: ContinuousClock.Instant, in session: Session
    ) async -> Report {
        let keeper = LeaseKeeper(
            client: session.client, clock: session.clock, leaseID: hold.leaseID,
            renewedAt: leaseRequestedAt)
        await keeper.start()

        let attempt: Attempt
        do {
            try await session.client.apply(settings(for: hold.plans), leaseID: hold.leaseID)
            do {
                attempt = .applied(.success(try await session.client.snapshot()))
            } catch {
                attempt = .applied(.failure(error))
            }
        } catch {
            attempt = .applyFailed(error)
        }
        let kept = await keeper.stop()
        let signal = session.interrupt.pending

        let confirmation: Result<SystemSnapshot, any Error>
        switch attempt {
        case .applyFailed(let error):
            return await afterFailedApply(
                error, hold: hold, renewal: kept.failure, signal: signal, in: session)
        case .applied(let result):
            confirmation = result
        }

        // Each of these is a lease that was taken and a speed that was accepted, and none says
        // what the fans are doing: released, and the safe state looked at, before anything is
        // said.
        let lapse: Lapse
        switch (kept.failure, confirmation) {
        case (.renewal(let reason)?, _):
            lapse = Lapse(renewalFailure: reason, apply: .accepted)
        case (.timer?, _):
            lapse = Lapse(renewalFailure: nil, apply: .accepted, confirmation: .timerFailed)
        case (nil, .failure(let error)):
            lapse = Lapse(
                renewalFailure: nil, apply: .accepted,
                confirmation: .snapshotFailed(describe(error)))
        case (nil, .success(let read)):
            // The first snapshot after `apply` decides, because it cannot predate the
            // engagement: ADR 0013's 2026-10-18 amendment records why.
            guard let loss = Self.loss(in: read, leaseID: hold.leaseID, covering: hold.fans)
            else {
                return await begin(hold, from: read, kept: kept, signal: signal, in: session)
            }
            lapse = Lapse(renewalFailure: nil, apply: .accepted, confirmation: .notHeld(loss))
        }
        return await afterLapse(lapse, hold: hold, signal: signal, in: session)
    }

    /// The helper says the fans are held. If nobody has asked to stop, say so and hold them.
    private static func begin(
        _ hold: Hold, from snapshot: SystemSnapshot, kept: LeaseKeeper.Handoff,
        signal: HoldSignal?, in session: Session
    ) async -> Report {
        // A stop that was asked for while the helper worked (a Ctrl-C in the middle of a fifty
        // second unlock) ends the run before "Holding" is said. The lease is released and the
        // safe state looked at, as for every ordinary ending.
        if let signal {
            return await finish(
                .ended(.signalBeforeHold(signal)), hold: hold, snapshot: snapshot, in: session)
        }

        // Handed over, not written: nothing the hold does waits on a reader. If standard output
        // has failed or is not taking them, the first look in `heartbeats` finds out.
        session.output.started(hold, snapshot: snapshot)

        let (end, latest) = await heartbeats(
            hold, from: snapshot, renewedAt: kept.renewedAt,
            startingParent: session.startingParent, in: session)
        return await finish(end, hold: hold, snapshot: latest, in: session)
    }

    /// `apply` threw. The lease is given back, and **then the safe state is looked at, whatever
    /// the error was.**
    ///
    /// An `apply` that engaged a fan can answer with a fault afterwards: it can engage fan 0,
    /// fail on fan 1, have the undo refused and still answer only the original fault, or find
    /// the lease gone or a thermal emergency set once every fan was written. A refusal tells
    /// this run nothing about the fans, so it is never taken to mean none was touched.
    ///
    /// In this order:
    ///
    /// - **A renewal failed while it worked** (the keeper recorded it): control lost, whatever
    ///   `apply` then said. A renewal that timed out makes the client give up the connection,
    ///   and the `apply` in flight is then answered `connectionAbandoned`; reading that as "no
    ///   answer" and nothing more would never mention the renewal. The text states both facts.
    /// - **It did not answer** (`helperNeverAnswered`, `replyNotDelivered`, `helperRestarted`,
    ///   `connectionAbandoned`, or any transport failure): it may have applied the speed, as a
    ///   refused `apply` may have engaged a fan.
    /// - **It answered that the lease is gone**: control lost, with its own text and never a
    ///   refusal.
    /// - **It answered with another fault**: the helper said no. That is still all the answer
    ///   says: the words "did not accept the speed" are used only if the check that follows
    ///   found every fan automatic and no lease.
    ///
    /// In every case the exit is the check's verdict where that is worse (9, then 8), and
    /// otherwise the failure's own code.
    static func afterFailedApply(
        _ error: any Error, hold: Hold, renewal: LeaseKeeper.Failure?, signal: HoldSignal? = nil,
        in session: Session
    ) async -> Report {
        let classified = HelperCommandFailure(classifying: error, during: .beforeControl)
        let release = await release(hold.leaseID, using: session.client)
        let settlement = await checkSafeState(in: session)
        let answered = helperAnswered(error)
        if case .renewal(let reason)? = renewal {
            let said: ApplyAnswer =
                answered ? .answered(describe(error)) : .unanswered(describe(error))
            return .lapsed(
                Lapse(renewalFailure: reason, apply: said), hold: hold, release: release,
                settlement: settlement, signal: signal)
        }
        guard answered else {
            // The client's words for what it saw, not the error's own, which go on to claim what
            // the helper did with the fans and to advise what to do next (`describe`).
            let observed = HelperCommandFailure(classified.code, describe(error))
            return .applyUnanswered(
                observed, hold: hold, release: release, settlement: settlement, signal: signal)
        }
        if let lapse = lapse(afterApplyFault: error) {
            return .lapsed(
                lapse, hold: hold, release: release, settlement: settlement, signal: signal)
        }
        return .applyFaulted(
            classified, hold: hold, release: release, settlement: settlement, signal: signal)
    }

    /// Control was lost before the hold began, and `apply` was accepted or said nothing about
    /// it. Released, and the safe state looked at: that is all this run can say of the fans.
    private static func afterLapse(
        _ lapse: Lapse, hold: Hold, signal: HoldSignal?, in session: Session
    ) async -> Report {
        let release = await release(hold.leaseID, using: session.client)
        let settlement = await checkSafeState(in: session)
        return .lapsed(
            lapse, hold: hold, release: release, settlement: settlement, signal: signal)
    }

    /// Whether `apply` answered that the lease is not live.
    static func lapse(afterApplyFault error: any Error) -> Lapse? {
        guard let fault = error as? AeolusXPCFault else { return nil }
        switch fault {
        case .leaseExpired, .leaseUnknown, .leaseNotHeldByThisConnection:
            return Lapse(renewalFailure: nil, apply: .answered(describe(error)))
        case .handshakeRequired, .versionMismatch, .malformedPayload, .invalidParameter,
            .manualControlUnavailable, .thermalEmergencyActive, .reclaimedBySystem,
            .boundsImplausible, .helperFailed, .unknown:
            return nil
        }
    }

    /// Whether `error` is the helper answering. A fault is its answer; everything else is the
    /// transport failing, and says nothing about what the helper did with the message.
    static func helperAnswered(_ error: any Error) -> Bool {
        error is AeolusXPCFault
    }
}
