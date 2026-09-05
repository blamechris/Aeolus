import AeolusXPC
import FanKit
import Foundation
import SMCCore

/// How one enumerated fan and one sensor kind are stated on the wire.
///
/// **Pure functions in their own type, rather than an extension on the actor.** The rules
/// here — what may be clamped, what may be claimed, what a firmware bit is allowed to be
/// read as — are the part of the snapshot path worth reading on its own, and they need none
/// of the authority's state to apply. Splitting them out is what keeps
/// `ReadOnlyFanAuthority.swift` inside the 400-line limit without making the actor's
/// `private` state module-visible, which is the trade `SnapshotSensorReads` refused for the
/// same reason and [#128](https://github.com/blamechris/Aeolus/issues/128) records.
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
        mode: FirmwareFanMode?
    ) -> FanState {
        let cause = reclamation[fan.index]
        return FanState(
            index: fan.index,
            // `{fds`, the firmware fan-descriptor struct, is absent on this project's
            // development machine and is not read anywhere in the tree. No name is
            // honest; an invented one is not.
            firmwareName: nil,
            actualRPM: reading(for: fan.actual),
            minimumRPM: reading(for: fan.minimum),
            maximumRPM: reading(for: fan.maximum),
            // "No target is set" rather than "the target could not be read": this helper is
            // asking for nothing, and that is an answer — a build-level fact of the same kind
            // as `activeLease: nil`, not an unconfirmed observation. `SMCConnection.write` is
            // `package` and throws and no write selector exists in `Sources`, so there is no
            // configuration of this executable in which it asks a fan for a speed.
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
            isReclaimedBySystem: cause == .systemReclaimed,
            manualControlAvailability: availability(whenLedgerSays: cause)
        )
    }

    /// What a fan's disposition means for whether it could be leased.
    ///
    /// `.writePathNotBuilt` is the build-level answer, and it stays the answer for every
    /// fan whose bounds this executable could not judge either: E5's bounds gate —
    /// `FanKit.FanControlEnvelope.validating(declaredMinimumRPM:declaredMaximumRPM:)`,
    /// whose failures map to `.boundsImplausible` — is deliberately not consulted here,
    /// because a build-level fact outranks a per-fan one. No fan in this build can be
    /// controlled, so reporting `.boundsImplausible` on one would imply that better bounds
    /// would grant control, which is false of every fan this executable serves. The gate
    /// plugs in here in the epic that also brings the write path it guards.
    ///
    /// **Blindness is the exception, and it is not one of those per-fan facts.** It is § 5
    /// saying it gave a fan up because it could not see it — a claim about the supervisor,
    /// not about what stands between a client and a lease, so it cannot imply that anything
    /// would grant control. It is also the only honest thing the snapshot can say about
    /// such a fan, `isReclaimedBySystem` having said it wrongly as a system reclamation. In
    /// this build it is unreachable for the ledger's own reason — nothing is ever held, so
    /// nothing can go blind — and what changed is where the answer comes from.
    private static func availability(
        whenLedgerSays cause: ReclamationLedger.Cause?
    ) -> ManualControlAvailability {
        switch cause {
        case .supervisorBlind: return .unavailable(.supervisorBlind)
        case .systemReclaimed, nil: return .unavailable(.writePathNotBuilt)
        }
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
    /// is one bit that has never heard of one.
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
    /// Note the asymmetry with `FirmwareFanMode(declaredByFirmware:)`, which resolves an
    /// *ambiguous value* toward manual. That is a different question: there, the machine
    /// answered and the answer is odd; here, the machine did not answer at all, and the cost
    /// of guessing falls on a whole architecture rather than on one redundant restore.
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
