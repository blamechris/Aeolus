import AeolusXPC
import FanKit
import Foundation
import SMCCore

/// How one enumerated fan and one sensor kind are stated on the wire.
///
/// **Pure functions in their own type, rather than an extension on the actor.** The rules
/// here — what may be clamped, what may be claimed, what a raw mode byte is allowed to be
/// read as — are the part of the snapshot path worth reading on its own, and they need none
/// of the authority's state to apply. Splitting them out is what keeps
/// `ReadOnlyFanAuthority.swift` inside the 400-line limit without making the actor's
/// `private` state module-visible, which is the trade `SnapshotSensorReads` refused for the
/// same reason and [#128](https://github.com/blamechris/Aeolus/issues/128) records.
///
/// **The availability ladder is in `AvailabilityRestatement.swift`**, which holds the
/// re-statements `SupervisedFanAuthority.snapshot()` makes over this file's answer and states
/// the full order in one place. Read it before changing
/// `availability(writeCapabilityIs:bounds:)` below: that method produces three of the ladder's
/// eight rows and the other five can overwrite them.
enum ReadOnlyFanReport {

    /// One enumerated fan as the wire reports it.
    ///
    /// Nothing here is clamped, floored, or nudged: `F0Ac` was measured at 1343.07 against
    /// a declared `F0Mn` of 1350 on this project's development machine, so a reading below
    /// the declared minimum is a legitimate observation. Clamping governs targets on the
    /// write path, never observations — see `SMCFanEnumeration`.
    ///
    /// `mode` is what `F<n>Md` said for this fan this tick, or `nil` when it could not be
    /// read. That distinction is the whole of
    /// [#148](https://github.com/blamechris/Aeolus/issues/148) — see `controlMode(_:)`.
    static func fanState(
        for fan: SMCFanEnumeration.Fan,
        reclamation: [Int: ReclamationLedger.Cause],
        mode: FirmwareFanMode?,
        writeCapability: FanWriteCapability
    ) -> FanState {
        let cause = reclamation[fan.index]
        // Read once and named, because the availability below is a function of them: the
        // bounds gate needs both declarations, and `FanState.controlEnvelope` is unreachable
        // from inside the initialiser of the value that would answer it.
        let minimumRPM = reading(for: fan.minimum)
        let maximumRPM = reading(for: fan.maximum)
        return FanState(
            index: fan.index,
            // `{fds`, the firmware fan-descriptor struct, is absent on this project's
            // development machine and is not read anywhere in the tree. No name is
            // honest; an invented one is not.
            firmwareName: nil,
            actualRPM: reading(for: fan.actual),
            minimumRPM: minimumRPM,
            maximumRPM: maximumRPM,
            // Not this path's to state: on a `.notBuilt` seam no fan is ever commanded, and on a
            // `.built` one the supervised snapshot states the target § 5 holds for the live lease.
            //
            // Deliberately **not** sourced from `F<n>Tg`, which #148 raised alongside the
            // mode. That register carries whatever Apple's thermal manager last asked for on
            // an automatic fan, and `FanState.targetRPM` is documented as "the speed the
            // helper is currently asking for" — so reporting it here would say Aeolus is
            // commanding a speed it is not. Repurposing the field to mean the firmware's
            // target changes what a v1 field means, which `AeolusXPCVersion`'s policy makes a
            // protocol bump; the wire needs a field of its own for it.
            targetRPM: nil,
            mode: controlMode(mode),
            // From § 5's ledger, never a literal — see `reclamation`. Always `false` in
            // this build because no fan is ever off automatic control here, but the field
            // now moves when the mechanism does.
            //
            // **`.systemReclaimed` and nothing else.** The ledger's other cause is a helper
            // that went blind on the fan, which is not a statement about the operating
            // system at all, and this field's contract — rendered verbatim as "Reclaimed by
            // system" — cannot carry it. #140.
            //
            // **And this is the only place the ledger reaches the wire** (#355). The
            // availability below does not read it: a reclamation is a fact about what already
            // happened, and the grant path never asks it.
            isReclaimedBySystem: cause == .systemReclaimed,
            manualControlAvailability: availability(
                writeCapabilityIs: writeCapability,
                bounds: FanState.controlEnvelope(
                    declaredMinimum: minimumRPM, declaredMaximum: maximumRPM))
        )
    }

    /// What the **machine and the build** say about whether this fan could be leased: steps
    /// 6, 8 and 9 of the ladder in `AvailabilityRestatement.swift`.
    ///
    /// ## `.writePathNotBuilt` comes from the seam, and that is
    /// [#194](https://github.com/blamechris/Aeolus/issues/194)
    ///
    /// It was a **literal** here until #194 — `.unavailable(.writePathNotBuilt)` written out,
    /// while `LeaseAuthority.acquireLease` sourced the identical refusal from
    /// `FanControlPlane.writeCapability`. The literal was true of every build that had then
    /// shipped, because `SMCFanControlPlane` answered `.notBuilt`, and it would have stayed
    /// written here once the write path made that answer `.built`: every client would then be
    /// told manual control does not exist by the same helper that was granting leases. That is
    /// `CLAUDE.md` rule 6 arriving through the read path, and it is the same defect this file's
    /// three other fields were each corrected for — the latch, the ledger and the fan mode were
    /// all literals that stayed true only until the mechanism behind them arrived.
    ///
    /// It is checked **before** the bounds gate, which preserves the argument the literal
    /// carried: a build-level fact outranks a per-fan one, so reporting `.boundsImplausible` on
    /// a build that can write nothing would imply that better bounds would grant control. What
    /// changes is that the argument is now *conditional* — on a `.built` seam the per-fan gates
    /// below are reached, which is exactly what #194 asks for.
    ///
    /// ## The bounds gate, now that it is reachable
    ///
    /// `FanState.controlEnvelope` — E5's § 2 gate, whose failures all map to
    /// `.boundsImplausible` through `FanBoundsImplausibility.manualControlAvailability`, so no
    /// second vocabulary is invented here. It was deliberately not consulted while the answer
    /// above was unconditional. Since [#270](https://github.com/blamechris/Aeolus/issues/270)
    /// `acquireLease` reads the same two keys afresh and judges them with the same static
    /// `FanState.controlEnvelope(declaredMinimum:declaredMaximum:)`, so the grant refuses what
    /// this reports.
    ///
    /// ## § 5's ledger is history, and is not read here
    ///
    /// [#355](https://github.com/blamechris/Aeolus/issues/355). Until it, this method read the
    /// ledger: `.supervisorBlind` for a fan § 5 gave up blind, on any seam, and
    /// `.reclaimedBySystem` for one the system took, on a `.built` one. `acquireLease` never
    /// consults the ledger, and since #354 the terminal action keeps its entry, so after a
    /// terminal action the snapshot refused — for the life of the process — a lease the helper
    /// would grant. Only an engagement or a release clears the entry, and both need that lease:
    /// #189's register that seals its own exit.
    ///
    /// The ladder's rule settles it: an availability is computed from current evidence the
    /// grant path consults. What the ledger holds is a diagnosis of something that already
    /// happened, and it is reported as one — a system reclamation on `isReclaimedBySystem`,
    /// beside this field, and § 5's blindness in its fault lines and in the revocation that
    /// ended the lease. #140's rule is unchanged: blindness is never `isReclaimedBySystem`.
    /// Blindness was also the wrong tense here. "Cannot currently read" was false whenever the
    /// reconnect § 5 attempts before giving up had worked.
    ///
    /// **What this leaves, and where it is answered.** A fan § 5 gave up blind that is *still*
    /// unreadable reads `.available` here, while the grant's fresh read refuses it
    /// `.supervisorBlind`. That is the gap every unreadable fan has at this step (see
    /// `controlMode(_:)` and [#178](https://github.com/blamechris/Aeolus/issues/178)). Since
    /// [#360](https://github.com/blamechris/Aeolus/issues/360) it is closed one step later, on a
    /// seam that can write: step 5 judges the snapshot's own `F<n>Md` answer as the grant judges
    /// its read, and states `.supervisorBlind` for such a fan unless Aeolus is accountable for
    /// it. On a `.notBuilt` seam the fan reads `.writePathNotBuilt`, as every grant there does.
    private static func availability(
        writeCapabilityIs capability: FanWriteCapability,
        bounds: Result<FanControlEnvelope, FanBoundsImplausibility>
    ) -> ManualControlAvailability {
        guard capability == .built else { return .unavailable(.writePathNotBuilt) }
        if case .failure(let implausibility) = bounds {
            return implausibility.manualControlAvailability
        }
        return .available
    }

    /// What the wire is told about who owns a fan, given what `F<n>Md` said.
    ///
    /// ## Observed automatic, observed manual
    ///
    /// `.automatic` is now a statement about the machine rather than about the build. The
    /// firmware's `.manual` becomes `.manualFixed`, which is the strongest true thing v1's
    /// vocabulary can carry: the fan is off Apple's thermal management and is being held at a
    /// speed. `FanControlMode.manualFixed`'s own doc says "Aeolus is holding the fan … under
    /// an active lease", and in this build nothing is — `activeLease` is `nil` and
    /// `manualControlAvailability` is `.unavailable(.writePathNotBuilt)` on the same fan, so
    /// a client reading all three sees a fan held by *something else*, which is exactly the
    /// state `docs/SAFETY.md` § 6's startup reconciliation exists to clean up. `manualCurve`
    /// would be worse and would be an invention: a curve is Aeolus's own intent and `F<n>Md`
    /// is a mode byte that has never heard of one.
    ///
    /// ## Unreadable, and the gap this leaves
    ///
    /// A mode that could not be read falls back to `.automatic`, and that is a **documented
    /// compromise, not the right answer.** The right answer is "not known", and v1 cannot say
    /// it: `FanControlMode` is a plain string vocabulary with no forward tolerance, so adding
    /// an `unknown` case makes an older client fail to decode the entire snapshot — every
    /// sensor and both fans with it. By `AeolusXPCVersion`'s policy that is a bump, and it is
    /// not one to make in passing.
    ///
    /// Given only the two expressible answers, the fallback goes to `.automatic` because the
    /// other direction is worse *at scale*: `F<n>Md` does not exist on Intel Macs, which
    /// express the same fact as bit *n* of the `FS! ` bitmask, so a `.manualFixed` fallback
    /// would report every fan on an entire family as held by something, permanently. That is
    /// a false claim about far more machines than the one this change fixes. The helper logs
    /// the reason for every fan it could not read — `HelperLog.fanModeUnreadable` — so the
    /// gap is visible in `log show` rather than only here, and
    /// [#178](https://github.com/blamechris/Aeolus/issues/178) holds it open.
    ///
    /// **On a seam that can write, the availability beside it says so**
    /// ([#360](https://github.com/blamechris/Aeolus/issues/360)). Step 5 of the ladder is handed
    /// the read this fold discards — `ReadOnlyFanAuthority.observe()` — and states
    /// `.supervisorBlind`, the grant's own answer, for an unread fan Aeolus is not accountable
    /// for. The fold itself is unchanged, because it is the wire's limit rather than the
    /// ladder's. On a `.notBuilt` seam, every build that has shipped, nothing beside this field
    /// says the mode is not known, and that is still #178's.
    ///
    /// Note the asymmetry with `FirmwareFanMode(declaredByFirmware:)`, which resolves an
    /// *ambiguous value* toward manual. That is a different question: there, the machine
    /// answered and the answer is odd; here, the machine did not answer at all, and the cost
    /// of guessing falls on a whole architecture. A wrong manual there costs a restore write to a
    /// fan that is already automatic, and a snapshot that blames another program until the fan
    /// reads one of Apple's values again — which is why Apple's own values are a set
    /// ([#633](https://github.com/blamechris/Aeolus/issues/633)).
    private static func controlMode(_ observed: FirmwareFanMode?) -> FanControlMode {
        switch observed {
        case .automatic: return .automatic
        case .manual: return .manualFixed
        case nil: return .automatic
        }
    }

    private static func reading(for outcome: SensorReadOutcome) -> FanReading {
        switch outcome.result {
        case .success(let value):
            return .measured(value.value)
        case .failure(.unknownKey(let key)):
            return .unavailable(reason: "\(key) is not present on this machine")
        case .failure(.readFailed(let reason)), .failure(.notDecodable(let reason)):
            return .unavailable(reason: reason)
        }
    }

    /// Maps `SMCCore`'s physical kind onto the wire's unit vocabulary.
    ///
    /// `SMCSensorProvider` classifies conservatively — only the fan-key naming convention
    /// is treated as known, everything else is `.unknown` — and that conservatism is
    /// carried across the boundary rather than improved on here. A helper guessing
    /// "starts with T, therefore Celsius" would be inventing the decoration this type has
    /// just finished declining to attach.
    static func unit(for kind: SensorReading.Kind) -> SensorSample.Unit {
        switch kind {
        case .temperatureCelsius: return .celsius
        case .rpm: return .rpm
        case .watts: return .watts
        case .volts: return .volts
        case .amps: return .amps
        case .percent: return .percent
        case .unknown: return .unknown
        }
    }
}
