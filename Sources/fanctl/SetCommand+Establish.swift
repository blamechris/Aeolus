import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

// The step between the lease and the hold: send the speed, keep the lease alive while the helper
// works, and see whether the helper says the fans are held. Everything that can go wrong in that
// step is here, because every one of them is a lease that was taken and a speed that may have
// been sent, and what `set` says about it must be true.

extension SetCommand {

    /// What `apply` itself said, when the lease ended while it was being applied.
    enum ApplyAnswer: Equatable, Sendable {
        /// It was accepted, after (or despite) the lease ending.
        case accepted
        /// The helper answered with a fault, in its own words.
        case answered(String)
    }

    /// The lease ended while the speed was still being applied: a renewal was refused or went
    /// unanswered, or `apply` itself answered that the lease is gone. Exit 6, or worse.
    ///
    /// **Control lost, never a refusal.** The helper may have engaged a fan before the lease
    /// ended, and what it did about the fan when it did is not something `apply`'s answer says.
    struct Lapse: Equatable, Sendable {
        /// The helper's words for the renewal that failed while `apply` worked, if one did.
        let renewalFailure: String?
        /// What `apply` itself said. With no failed renewal this is the answer that the lease
        /// is gone, which is then the whole of how this run knows.
        let apply: ApplyAnswer
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

        let confirmation: Result<SystemSnapshot, any Error>
        switch attempt {
        case .applyFailed(let error):
            return await afterFailedApply(error, hold: hold, renewal: kept.failure, in: session)
        case .applied(let result):
            confirmation = result
        }

        switch kept.failure {
        case .renewal(let reason)?:
            // The lease ended while the speed was being applied, whatever `apply` then said.
            return await afterLapse(
                Lapse(renewalFailure: reason, apply: .accepted), hold: hold, in: session)
        case .timer?:
            return await finish(.timerFailed, hold: hold, snapshot: nil, in: session)
        case nil:
            break
        }

        let snapshot: SystemSnapshot
        switch confirmation {
        case .failure(let error):
            return await finish(
                .lost(.snapshotFailed(describe(error))), hold: hold, snapshot: nil, in: session)
        case .success(let read):
            snapshot = read
        }
        // The first snapshot after `apply` decides, because it cannot predate the engagement:
        // ADR 0013's 2026-10-18 amendment records why.
        if let loss = loss(in: snapshot, leaseID: hold.leaseID, covering: hold.fans) {
            return await finish(.lost(loss), hold: hold, snapshot: snapshot, in: session)
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
    /// - **It did not answer** (`helperNeverAnswered`, `replyNotDelivered`, `helperRestarted`,
    ///   `connectionAbandoned`, or any transport failure): it may have applied the speed. The
    ///   exit is the code the failure classifies to, whatever the check finds.
    /// - **It answered that the lease is gone, or a renewal failed while it worked**: the lease
    ///   lapsed. Control lost, with its own text and never a refusal.
    /// - **It answered with another fault**: the helper said no. That is still all the answer
    ///   says: the words "did not accept the speed" are used only if the check that follows
    ///   found every fan automatic and no lease.
    ///
    /// For the last two the exit is the check's verdict where that is worse (9, then 8), and
    /// otherwise the fault's own code.
    static func afterFailedApply(
        _ error: any Error, hold: Hold, renewal: LeaseKeeper.Failure?, in session: Session
    ) async -> Report {
        let failure = HelperCommandFailure(classifying: error, during: .beforeControl)
        let release = await release(hold.leaseID, using: session.client)
        let settlement = await checkSafeState(in: session)
        guard helperAnswered(error) else {
            return .applyUnanswered(failure, hold: hold, release: release, settlement: settlement)
        }
        if let lapse = lapse(afterApplyFault: error, renewal: renewal) {
            return .lapsed(lapse, hold: hold, release: release, settlement: settlement)
        }
        return .applyFaulted(failure, hold: hold, release: release, settlement: settlement)
    }

    /// The lease ended while the speed was being applied, and `apply` said nothing about it.
    /// Released, and the safe state looked at: the lease is gone, which says nothing of the
    /// fans.
    private static func afterLapse(
        _ lapse: Lapse, hold: Hold, in session: Session
    ) async -> Report {
        let release = await release(hold.leaseID, using: session.client)
        let settlement = await checkSafeState(in: session)
        return .lapsed(lapse, hold: hold, release: release, settlement: settlement)
    }

    /// Whether the lease ended during `apply`: a renewal failed while it worked, or `apply`
    /// answered with a fault that says the lease is not live.
    static func lapse(
        afterApplyFault error: any Error, renewal: LeaseKeeper.Failure?
    ) -> Lapse? {
        let answered = ApplyAnswer.answered(describe(error))
        if case .renewal(let reason)? = renewal {
            return Lapse(renewalFailure: reason, apply: answered)
        }
        guard let fault = error as? AeolusXPCFault else { return nil }
        switch fault {
        case .leaseExpired, .leaseUnknown, .leaseNotHeldByThisConnection:
            return Lapse(renewalFailure: nil, apply: answered)
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
