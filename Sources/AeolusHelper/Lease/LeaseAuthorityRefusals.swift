import AeolusXPC
import FanKit

// The three refusals the lease core makes about the **machine and the build**, lifted out of
// `LeaseAuthority.swift` by [#128](https://github.com/blamechris/Aeolus/issues/128). Every
// body, every doc comment and every statement order is unchanged; only the file is.
//
// ## The doctrine is stated once, and it is not stated here
//
// `LeaseAuthority.swift`'s type-level comment is the only place the actor's reentrancy rule
// is written down — *suspend for whatever you need, then decide in one straight-line region
// containing no `await`* — and every method here is bound by it exactly as if it had stayed
// in that file. Read it there before editing anything below. A second copy in this file is
// the failure mode the rule itself warns about: two statements of one rule disagree the
// moment either moves.
//
// ## Why these three and not the others
//
// The line is **what a guard consults**, not what it refuses.
//
// Each of these asks a *stateless query role* — a protocol whose every member is a read —
// and touches nothing this actor owns: `FanWriteCapabilityReporting` (a get-only property),
// `SightednessProving` (`sighting()`), `ForeignManualControlSensing` (`refusalForGrant`).
// So they can be reached from another file by widening only the references to those roles,
// plus `log`. Nothing that decides who may hold or release a fan crosses.
//
// The guards that stayed behind are the ones that consult state the actor owns, and each is
// in `LeaseAuthority.swift` beside that state:
//
// - `refuseIfInvalidated(_:)` reads `tombstones`, the ledger of connections that may never
//   bind a lease again.
// - `refuseIfThermalEmergencyActive(_:)` reads `ThermalEmergencyLatch` — which is *not* a
//   query role. It is a concrete actor with mutators, so widening this actor's reference to
//   it would hand every file in the module a route to engage or release `docs/SAFETY.md`
//   § 3's latch through the lease core. The refusal is a read; the reference is not, and
//   the reference is what a widening exposes.
// - The three refusals inside `acquireLease`'s straight-line region read `restoreAbandoned`,
//   `sleepSeal`, `table` and `releasing` directly, and stay inside it for the reason that
//   region exists at all.
//
// `LeaseAuthorityAccessTests` enforces that split rather than leaving it to this comment.
//
// ## What this does not fix
//
// `LeaseAuthority.swift` is still over the 400-line threshold #128 was filed about, and no
// further cut is available at the price this one paid. The three groups #128 names —
// acquisition, renewal/release, teardown — every one of them mutates `table` or calls
// `restore(_:because:)`, and those are precisely the members that decide who may hold a fan
// and who may hand one back. #128's own later comments declined `SMCReadScheduler` and
// `ReclamationWatchdog` on that exact trade; this file does not take it.

extension LeaseAuthority {

    /// Refuses the grant when this build has no SMC write path.
    ///
    /// **Synchronous, and first in `acquireLease`.** Both halves are the point.
    ///
    /// *First*, because this is the only refusal in the method that no client and no machine
    /// can change. `refuseIfBlind` can cost a real 34-key `.supervisor` read — it does
    /// whenever § 3's last reading has aged out, and always on a helper whose supervisor is
    /// not running — so ordering it
    /// ahead of this one would spend a hardware round trip to produce an answer about the
    /// *sensors* for a request that was never going to be granted whatever they said — and a
    /// client told `noThermalTelemetry` reasonably retries when the machine recovers, into a
    /// refusal that is not about the machine at all. `LeaseWriteCapabilityTests` asserts the
    /// read count, not merely the fault, because a check that is merely *present* can be
    /// moved below the read by an ordinary-looking edit and nothing else would notice.
    ///
    /// *Synchronous*, because `FanWriteCapabilityReporting` has no `async` on it: "before
    /// any hardware round trip" is then a property of the type rather than a claim about
    /// where this line sits. See that protocol.
    ///
    /// It replaces `ReadOnlyFanAuthority`'s hard-coded `Self.noWritePath` — the same fault,
    /// the same reason case, sourced from the seam that would have to perform the write
    /// instead of from a literal. `AeolusXPCFault.manualControlUnavailable(reason:)` and
    /// `.writePathNotBuilt` both already exist, so `AeolusXPCVersion` does not move.
    ///
    /// `internal` rather than `private` **only because this file is not**
    /// `LeaseAuthority.swift` — a Swift extension in another file cannot see a `private`
    /// member. Nothing widens with it: calling this from elsewhere in the module can
    /// produce a refusal and nothing else, and it reads no state the actor owns.
    func refuseIfWritePathNotBuilt(_ connection: ConnectionID) throws {
        guard writeCapability.writeCapability == .notBuilt else { return }
        log.refusedNoWritePath(connection)
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    /// Refuses the grant if the helper cannot currently see a critical temperature.
    ///
    /// **`docs/SAFETY.md` § 3 is a precondition of § 1.** A lease is a promise that
    /// something is watching the fans it pins; a helper that cannot read a temperature is
    /// not watching anything, and the thermal override, the reclamation watchdog and the
    /// sleep supervisor are all equally blind. What is left is the TTL, which
    /// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) accepts as a *backstop*
    /// and nowhere accepts as the whole mechanism.
    ///
    /// ## What it costs, since #134
    ///
    /// Not a read per call. `SightednessProving` is answered by `CriticalTemperatureCache`,
    /// which serves § 3's own most recent reading while it is less than one cycle period
    /// old and coalesces concurrent callers onto a single read when it is not — so a client
    /// retrying `acquireLease` in a tight loop can no longer queue an unbounded number of
    /// `.supervisor` turns ahead of the cycle that would take its fans back. A cold cache,
    /// or a helper whose thermal supervisor is not running, still costs one real 34-key read
    /// per grant. [ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md) records
    /// why that staleness is exact rather than tolerated: this method asks whether § 3 can
    /// see, and § 3's own cycle is the authoritative answer to that question.
    ///
    /// ## Why it sits here in the order
    ///
    /// It is above the straight-line region because it suspends, and it must be: the proof
    /// is the point. That places it ahead of the concurrent-lease and mid-handback
    /// refusals, so a client asking during blindness is told about the blindness even when
    /// another client holds the fans. Both facts are true and this is the one worth
    /// telling: `leaseHeldByAnotherClient` invites "wait for them to finish", which is
    /// wrong advice on a machine where nobody can be granted anything.
    ///
    /// It also lands ahead of `validateFanIndices`, which is the one ordering here that is
    /// a consequence rather than a choice — everything in the straight-line region is below
    /// every suspension point by construction. So a request naming a fan that does not
    /// exist, sent to a blind machine, is answered `noThermalTelemetry` rather than
    /// `invalidFanIndex`. That is tolerable (both are refusals, and the blindness is the
    /// more consequential fact) but it is not a judgement anybody made, and a future reader
    /// comparing this against the validation-first ordering elsewhere should know that.
    ///
    /// ## Why it catches everything except cancellation
    ///
    /// Every failure to obtain telemetry is blindness, whatever its type. There is no
    /// allow-list of error cases that count, because an allow-list means the next error case
    /// somebody adds silently defaults to *granted*, and this guard exists precisely to stop
    /// a lease being handed out on a machine nothing can see. The default is refuse.
    ///
    /// `CancellationError` is the one exception, and it is not a hole in that rule — it is
    /// the one error that is definitionally **not a statement about the machine**. A
    /// cancelled request says the caller went away; it says nothing about whether the SMC
    /// answered. Folding it in would tell a client "no thermal telemetry" when telemetry was
    /// never the problem, and — worse — write a `.fault` line into a root daemon's log
    /// claiming the sensors went silent on a machine whose sensors are fine. That log is
    /// meant to be the record a user reaches for when asking whether the mechanism was
    /// watching; a false entry in it is worse than no entry.
    ///
    /// Re-throwing is also still fail-safe: the lease is not granted either way. Only the
    /// reported reason differs, and `CLAUDE.md` rule 6 is about exactly that — never report
    /// a state that is not the one you are in.
    ///
    /// `internal` rather than `private` **only because this file is not**
    /// `LeaseAuthority.swift` — a Swift extension in another file cannot see a `private`
    /// member. Nothing widens with it: calling this from elsewhere in the module can
    /// produce a refusal and nothing else, and it reads no state the actor owns.
    func refuseIfBlind(_ connection: ConnectionID) async throws {
        do {
            _ = try await telemetry.sighting()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            log.refusedBlindTelemetry(connection, detail: String(describing: error))
            throw AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        }
    }

    /// `docs/SAFETY.md` § 6's baseline, asked immediately after the blindness gate.
    ///
    /// **Last of the four things `acquireLease` suspends on, and last of the three refusals
    /// among them — and the position is reasoned.** The four are the fan enumeration, § 3's
    /// latch, the sightedness proof, and this; the enumeration is the one that is not a
    /// refusal, and the sweep of lapsed leases runs ahead of all four rather than being one
    /// of them. Step 3 of `acquireLease` lists them in that order, and says which count is
    /// which for the same reason this does: two nearby sentences counting different things
    /// with the same word is how the previous "three" and "four" came to disagree. § 3's
    /// latch
    /// and the sightedness proof are both properties of the *machine* and answer for
    /// every fan at once; this one costs one `.supervisor` turn **per requested fan**, so it
    /// is the most expensive question here and the one most worth not asking when a cheaper
    /// refusal already applies. `refuseIfWritePathNotBuilt` running first (step 0) is what
    /// keeps it off today's helper's grant path entirely.
    ///
    /// `fansAeolusIsAccountableFor` is read here rather than passed in because it must be
    /// this actor's state as it stands at the moment of the question — see that property for
    /// the three registers it unions and the more precise refusal each of them already has.
    ///
    /// `internal` rather than `private` **only because this file is not**
    /// `LeaseAuthority.swift` — a Swift extension in another file cannot see a `private`
    /// member. Nothing widens with it: calling this from elsewhere in the module can
    /// produce a refusal and nothing else, and it reads no state the actor owns.
    func refuseIfForeignManualControl(
        _ connection: ConnectionID, wanting fans: Set<Int>
    ) async throws {
        let reason = await foreignControl.refusalForGrant(
            overFans: fans, heldByAeolus: fansAeolusIsAccountableFor)
        guard let reason else { return }
        log.refusedForeignManualControl(connection, fans: fans, reason: reason)
        throw AeolusXPCFault.manualControlUnavailable(reason: reason)
    }
}
