import AeolusXPC
import FanKit

// The three refusals the lease core makes about the **machine and the build**, lifted out of
// `LeaseAuthority.swift` by [#128](https://github.com/blamechris/Aeolus/issues/128). Every
// body and every statement order is unchanged; each doc comment gained the paragraph
// explaining why the member is `internal` rather than `private`. A fourth of the same kind,
// § 2's bounds gate, was written here rather than moved (#270).
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
// ## Why these four and not the others
//
// The line is **what a guard consults**, not what it refuses.
//
// Each of these asks a *stateless query role* — a protocol whose every member is a read —
// and touches nothing this actor owns: `FanWriteCapabilityReporting` (a get-only property),
// `SightednessProving` (`sighting()`), `ForeignManualControlSensing` (`refusalForGrant`), and
// since [#270](https://github.com/blamechris/Aeolus/issues/270) `FanEnvelopeReading`
// (`readEnvelope(ofFan:)`), for the fourth, `refuseIfBoundsImplausible(_:wanting:)`.
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
// - The refusals inside `acquireLease`'s straight-line region read `restoreAbandoned`,
//   `handbackUnconfirmed`, `sleepSeal`, `table` and `releasing` directly, and stay inside it
//   for the reason that region exists at all.
//
// **One addition reads this actor's state, and only through a view already on the seam.**
// `refuseIfExemptionLapsed(_:exempted:)` ([#311](https://github.com/blamechris/Aeolus/issues/311))
// runs inside the straight-line region, and consults `fansAeolusIsAccountableFor` — the
// derived, read-only union #128 already made `internal`, which
// `refuseIfForeignManualControl(_:wanting:)` above it reads too. No register it is derived
// from crosses, and nothing it can do changes who holds or releases a fan: it only refuses.
// It lives here for the line budget `LeaseAuthority.swift` has left, not as an exception to
// the split.
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
    /// which serves the most recent reading while it is less than one cycle period old —
    /// § 3's own in the usual case, or a grant-path read's *failure*, which is remembered
    /// ahead of a later cycle sighting (ADR 0010's 2026-09-20 amendment) — and coalesces
    /// concurrent callers onto a single read when there is none. So a client
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
    /// **Fourth of the five things `acquireLease` suspends on, and third of the four refusals
    /// among them — and the position is reasoned.** The five are the fan enumeration, § 3's
    /// latch, the sightedness proof, this, and the bounds read (#270); the enumeration is the
    /// one that is not a refusal, and the sweep of lapsed leases runs ahead of all five rather
    /// than being one of them. Step 3 of `acquireLease` lists them in that order, and says
    /// which count is which for the same reason this does: two nearby sentences counting
    /// different things with the same word is how an earlier "three" and "four" came to
    /// disagree. § 3's latch and the sightedness proof are both properties of the *machine*
    /// and answer for every fan at once; this one and the bounds read each cost one
    /// `.supervisor` turn **per requested fan**, so they are the most expensive questions here
    /// and the ones most worth not asking when a cheaper refusal already applies. This one goes
    /// first of the two: see `refuseIfBoundsImplausible(_:wanting:)` for why.
    /// `refuseIfWritePathNotBuilt` running first (step 0) is what keeps both off today's
    /// helper's grant path entirely.
    ///
    /// `fansAeolusIsAccountableFor` is read here rather than passed in, as this actor's state
    /// at the moment of the question — see that property for the three registers it unions
    /// and the more precise refusal each of them already has. **The moment of the question
    /// is not the moment of the grant**, and that is #311: the fans it exempts are never read,
    /// and this suspends before `acquireLease` decides. So it returns them, and
    /// `refuseIfExemptionLapsed(_:exempted:)` asks again once nothing can suspend.
    ///
    /// `internal` rather than `private` **only because this file is not**
    /// `LeaseAuthority.swift` — a Swift extension in another file cannot see a `private`
    /// member. Nothing widens with it: calling this from elsewhere in the module can produce a
    /// refusal and nothing else, and what it returns is a subset of what the caller asked for.
    func refuseIfForeignManualControl(
        _ connection: ConnectionID, wanting fans: Set<Int>
    ) async throws -> Set<Int> {
        // § 3's set before this actor's union, for the order `activeLeaseView()` gives: a fan
        // leaving § 3's set by being engaged again is then held by the union read after it.
        let awaiting = await emergencyRestores?.fansAwaitingRestoreConfirmation ?? []
        let held = fansAeolusIsAccountableFor
        let reason = await foreignControl.refusalForGrant(
            overFans: fans, heldByAeolus: held, awaitingConfirmation: awaiting)
        if let reason {
            log.refusedForeignManualControl(connection, fans: fans, reason: reason)
            throw AeolusXPCFault.manualControlUnavailable(reason: reason)
        }
        return fans.intersection(held)
    }

    /// Refuses the grant over a fan whose firmware bounds `docs/SAFETY.md` § 2's gate rejects
    /// ([#270](https://github.com/blamechris/Aeolus/issues/270)).
    ///
    /// Such a fan has no envelope, so no target could ever be produced for it: the snapshot
    /// has reported it `.boundsImplausible` since #194, and a grant over it was a lease that
    /// could never be used. Each fan in `fans` is read afresh, sorted, one at a time, and
    /// judged by `FanState.controlEnvelope(declaredMinimum:declaredMaximum:)` — the snapshot's
    /// own derivation, so the two sides cannot disagree about which declarations pass. A read
    /// that throws is `.notMeasured`, exactly as the snapshot's failed read of a bound is, and
    /// the default is refuse for `refuseIfBlind`'s reason: an allow-list of errors would let
    /// the next one grant. `CancellationError` is rethrown, for that method's reason: a caller
    /// that went away says nothing about the firmware, and is not logged as if it had.
    ///
    /// **After the foreign-control read, and only over the fans it did not exempt.** A fan
    /// whose mode will not read is told `.supervisorBlind` there, which the ladder's step 5 also
    /// ranks above step 8, so the two sides keep one order. A fan Aeolus is accountable for is
    /// answered by the register below the marker that holds it, as the snapshot answers it; a
    /// handback landing during this read is `refuseIfExemptionLapsed(_:exempted:)`'s, as one
    /// landing during the foreign read is. Above the marker because it suspends, and nothing it
    /// reads is kept: the evidence is current, and a cache would make it stale.
    ///
    /// It mints no permit and holds no plane — it judges the envelope and drops it — and costs
    /// one `.supervisor` turn per fan it reads, bounded by per-connection serialisation, as the
    /// foreign read is. `internal` for `refuseIfForeignManualControl(_:wanting:)`'s reason; it
    /// can produce a refusal and nothing else.
    func refuseIfBoundsImplausible(
        _ connection: ConnectionID, wanting fans: Set<Int>
    ) async throws {
        for fan in fans.sorted() {
            let bounds: Result<FanControlEnvelope, FanBoundsImplausibility>
            var unread: String?
            do {
                let declared = try await envelopes.readEnvelope(ofFan: fan)
                bounds = FanState.controlEnvelope(
                    declaredMinimum: .measured(declared.minimumRPM),
                    declaredMaximum: .measured(declared.maximumRPM))
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                bounds = .failure(.notMeasured)
                unread = String(describing: error)
            }
            guard case .failure(let failure) = bounds else { continue }
            log.refusedImplausibleBounds(connection, fan: fan, failure: failure, unread: unread)
            throw AeolusXPCFault.manualControlUnavailable(reason: .boundsImplausible)
        }
    }

    /// Refuses a fan the foreign-control step exempted as Aeolus's own that no longer is
    /// ([#311](https://github.com/blamechris/Aeolus/issues/311)).
    ///
    /// **Synchronous, because it has to be in `acquireLease`'s straight-line region.** An
    /// exempted fan is never read, on the argument that a more precise refusal below the marker
    /// answers for it. That holds only while the fan is still in `fansAeolusIsAccountableFor`,
    /// and the foreign-control step suspends — once on the reconciliation actor and once per
    /// fan it reads — so a handback can land in between. Its `releasing` entry clears, the
    /// `.releaseInProgress` guard no longer sees it, and before this check nothing refused it
    /// however it read: a lease over a fan in manual that nothing had read since its restore.
    ///
    /// `.releaseInProgress` is the honest answer, not a guess: the fan's handback finished
    /// inside this request, a retry reads it fresh, and the retry is told whatever is true of
    /// it then — granted if it reads automatic, and the foreign-control step's answer if not.
    /// Asked last, because it is the least durable refusal here.
    ///
    /// `internal` for `refuseIfForeignManualControl(_:wanting:)`'s reason; it can produce a
    /// refusal and nothing else.
    func refuseIfExemptionLapsed(_ connection: ConnectionID, exempted: Set<Int>) throws {
        let lapsed = exempted.subtracting(fansAeolusIsAccountableFor)
        guard lapsed.isEmpty else {
            log.refusedLapsedExemption(connection, fans: lapsed)
            throw AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)
        }
    }
}
