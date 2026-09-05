import Foundation
import Testing

/// The inverted write-verb tripwire: an allowlist of every verb in the helper, rather than a
/// pattern that recognises the ones somebody thought to name.
///
/// ## Why the name-anchored scans were not enough
///
/// `WriteAuthorisationTests` asserts the shape of a write verb's signature, and finds the
/// verbs by name stem — `\w*[Tt]arget\w*`, `engage\w*`, `restore\w*`. That family is wider
/// than one name and it is still a family.
/// [#120](https://github.com/blamechris/Aeolus/issues/120) predicted the failure and
/// [#141](https://github.com/blamechris/Aeolus/issues/141) recorded it arriving: by the time
/// #136 landed, **three** write verbs matched none of the three stems —
/// `SafetyActorWriter.command(_:of:)`, `SafetyActorWriter.commandMaximum(of:)`, and
/// `GovernedFanWriter.command(towards:of:since:)`. Every tripwire stayed green while the
/// unseen population grew to be the majority.
///
/// #120's own deferral rationale — *"no such verb exists today"* — is the shape of argument
/// this suite exists to stop relying on. A guard whose coverage depends on nobody choosing a
/// new name is not a guard; it is a naming convention with a test attached.
///
/// ## What is asserted instead
///
/// Every function in `Sources/AeolusHelper` that could reach a firmware write is named in
/// exactly one of three lists below, and **an unlisted one fails**. That is the same
/// discipline `WritePathAbsenceTests` uses for SMC selectors, where the allowed set is
/// `{5, 8, 9}`: a new verb has to be *acknowledged* by whoever writes it, rather than merely
/// spelled outside a regex.
///
/// The population is `async` functions plus any function naming a permit, and that pair is
/// the point rather than a convenience. Reaching `FanControlPlane`'s write half requires
/// `await`, which a synchronous function cannot do — so scanning `async` is not the
/// heuristic #120 worried it was, with one named exception below. Permit-naming is scanned
/// alongside it because actor isolation makes a method `async` **at the call site while it
/// is declared without the keyword**: `ThermalEmergency.manualControlEngaged(_:)` is exactly
/// that, and an `async`-only scan does not see it.
///
/// ## What this still cannot see, stated rather than discovered later
///
/// - **A synchronous function that spawns an unstructured `Task` and writes inside it.**
///   That is the one route around "a synchronous function cannot `await`". `Sources` has
///   five such spawn sites today, all of them supervisors handing control to an `async run`
///   that *is* in this population.
/// - **A verb listed on the wrong list on purpose.** Putting a writer in
///   `permitFreeFunctions` is a lie a reviewer can read, which is the trade every allowlist
///   makes; what it buys is that the lie has to be written down.
/// - **A computed property.** The permit mint is one — `FanEnvelope.commandable` — and what
///   confines it is the access levels
///   `WriteAuthorisationTests.anAuthorisationTypeCannotBeMintedElsewhere` asserts.
///
/// The maintenance cost is real and is the intended cost: a new `async` helper function does
/// not compile a green suite until it is classified here.
@Suite("Every helper verb that could reach a write is acknowledged")
struct WriteVerbAllowlistTests {

    /// The types that authorise a write. Holding one is what `ADR 0008` calls a permit.
    private static let permits = ["CommandableFan", "AuthorisedFanTarget", "FanTargetRPM"]

    /// The types a permit may legally travel beside.
    ///
    /// `expectPermitIsTheOnlyParameter`'s rule — *"a value passed beside a permit is a value
    /// that can disagree with it"* — is about disagreement over **which fan** and **what
    /// bounds**. A `Double` speed cannot disagree: `SafetyActorWriter.command(_:of:)` and
    /// `GovernedFanWriter.command(towards:of:since:)` both put theirs through
    /// `CommandableFan.target(for:)`, so § 2's bounds and the 0 RPM floor bind it exactly as
    /// they bind every other write. A `Duration` is the ramp's elapsed time and names no fan
    /// either. An `Int` is precisely the thing that can disagree, and is absent by design —
    /// it is the signature ADR 0008 exists to make unrepresentable.
    private static let clampedCompanions = ["Double", "Duration"]

    /// The verbs that carry a permit: they command a fan, take one off automatic control,
    /// mint the permit, or hold one for a safety actor that will.
    ///
    /// Each is legitimate for a stated reason:
    ///
    /// - `FanControlPlane` / `SMCFanControlPlane`: `commandTarget(_:)` and
    ///   `engageManualControl(of:)` are the seam itself — the protocol requirement and its
    ///   production conformer.
    /// - `SafetyWriters`: `commandMaximum(of:)` is § 3's emergency write; `command(_:of:)`
    ///   is § 5's bounded re-assert, which needs the number it last commanded rather than
    ///   the loudest one; `engageManualControl(of:)` is § 5's precondition, because a fan
    ///   the system reclaimed must come off automatic before its target means anything;
    ///   `command(towards:of:since:)` is the control loop's governed step.
    /// - `FanWriteAuthorisation.target(for:)` is the *producer*: it clamps into the permit's
    ///   own envelope and stamps the permit's own index. It writes nothing.
    /// - `ThermalEmergency` / `ReclamationWatchdog`'s `manualControlEngaged(_:)` store a
    ///   permit minted elsewhere, so the emergency's maximum write needs no read while the
    ///   machine is above ceiling. `bridgeToMaximumThenRelease(_:)` is what spends it.
    private static let permitBearingVerbs: Set<String> = [
        "FanControlPlane.swift: commandTarget(_:)",
        "FanControlPlane.swift: engageManualControl(of:)",
        "SMCFanControlPlane.swift: commandTarget(_:)",
        "SMCFanControlPlane.swift: engageManualControl(of:)",
        "SafetyWriters.swift: command(_:of:)",
        "SafetyWriters.swift: command(towards:of:since:)",
        "SafetyWriters.swift: commandMaximum(of:)",
        "SafetyWriters.swift: engageManualControl(of:)",
        "FanWriteAuthorisation.swift: target(for:)",
        "ThermalEmergency.swift: manualControlEngaged(_:)",
        "ThermalEmergency.swift: bridgeToMaximumThenRelease(_:)",
        "ReclamationWatchdog.swift: manualControlEngaged(_:)",
    ]

    /// The keystone verbs, which take no authorisation of any kind and must not start.
    ///
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md): restore-to-automatic must
    /// never depend on trusted data, because it is the action that must remain available to
    /// a helper that cannot read. A permit *is* trusted data. This list is the population
    /// half of `theRestoreVerbTakesNoAuthorisation` — that test asserts the property on
    /// whatever it finds, this one asserts what there is to find.
    private static let restoreVerbs: Set<String> = [
        "FanControlPlane.swift: restoreToAutomatic(_:)",
        "SMCFanControlPlane.swift: restoreToAutomatic(_:)",
        "SafetyWriters.swift: restoreToAutomatic(_:)",
        "FanRestoring.swift: restoreToAutomatic(fans:because:)",
        "LeaseAuthority.swift: restore(_:because:)",
        "FanAuthority.swift: restoreAllToAutomatic(from:)",
        "ReadOnlyFanAuthority.swift: restoreAllToAutomatic(from:)",
        "HelperConnectionSession.swift: restoreAllToAutomatic()",
    ]

    /// Everything else in the target.
    ///
    /// These hold no permit, so the only way any of them reaches a fan write is by calling
    /// one of the two lists above — which is where the gate is, and is the whole reason the
    /// permit types exist. Several of them do exactly that: `ReclamationWatchdog.cycle()`
    /// and `ThermalEmergency.fire(_:from:)` both end in a write. Being here is not a claim
    /// that a function never causes a write; it is a claim that it cannot express one
    /// without going through a permit.
    ///
    /// The list is long on purpose. Its job is not to be read, it is to make a new verb
    /// impossible to add silently.
    private static let permitFreeFunctions: Set<String> = [
        "CriticalTemperatureSensing.swift: readCriticalTemperatures()",
        "FanAuthority.swift: acquireLease(_:from:)",
        "FanAuthority.swift: apply(_:leaseID:from:)",
        "FanAuthority.swift: connectionDidInvalidate(_:)",
        "FanAuthority.swift: releaseLease(id:from:)",
        "FanAuthority.swift: renewLease(id:from:)",
        "FanAuthority.swift: snapshot()",
        "FanControlPlane.swift: readControlState(ofFan:)",
        "FanControlPlane.swift: readCriticalTemperatures(_:)",
        "FanControlPlane.swift: readEnvelope(ofFan:)",
        "FanControlPlane.swift: reconnect()",
        "FanRestoring.swift: enumeratedFanIndices()",
        "HelperConnectionSession.swift: acquireLease(payload:)",
        "HelperConnectionSession.swift: apply(settings:leaseID:)",
        "HelperConnectionSession.swift: hello(payload:)",
        "HelperConnectionSession.swift: invalidate()",
        "HelperConnectionSession.swift: releaseLease(id:)",
        "HelperConnectionSession.swift: renewLease(id:)",
        "HelperConnectionSession.swift: snapshot()",
        "LeaseAuthority.swift: acquireLease(_:from:)",
        "LeaseAuthority.swift: activeLease()",
        "LeaseAuthority.swift: connectionDidInvalidate(_:)",
        "LeaseAuthority.swift: expireLapsedLeases()",
        "LeaseAuthority.swift: refuseIfBlind(_:)",
        "LeaseAuthority.swift: refuseIfThermalEmergencyActive(_:)",
        "LeaseAuthority.swift: releaseEveryLease()",
        "LeaseAuthority.swift: releaseLease(id:from:)",
        "LeaseAuthority.swift: revokeEveryLease(because:)",
        "LeaseAuthority.swift: revokeLeases(coveringFan:because:)",
        "LeaseClock.swift: sleep(until:)",
        "LeaseExpirySupervisor.swift: run(authority:clock:idleInterval:log:)",
        "ReadOnlyFanAuthority.swift: acquireLease(_:from:)",
        "ReadOnlyFanAuthority.swift: apply(_:leaseID:from:)",
        "ReadOnlyFanAuthority.swift: connectionDidInvalidate(_:)",
        "ReadOnlyFanAuthority.swift: discoverSensorKeys()",
        "ReadOnlyFanAuthority.swift: enumeratedFanIndices()",
        "ReadOnlyFanAuthority.swift: readSensors()",
        "ReadOnlyFanAuthority.swift: releaseLease(id:from:)",
        "ReadOnlyFanAuthority.swift: renewLease(id:from:)",
        "ReadOnlyFanAuthority.swift: snapshot()",
        "ReclamationSupervisor.swift: run(watchdog:clock:interval:log:)",
        "ReclamationWatchdog.swift: currentRuling()",
        "ReclamationWatchdog.swift: cycle()",
        "ReclamationWatchdog.swift: cycleCouldNotSee(fanAt:detail:)",
        "ReclamationWatchdog.swift: diverged(_:fanAt:)",
        "ReclamationWatchdog.swift: examine(fanAt:)",
        "ReclamationWatchdog.swift: finaliseRelease(fanAt:because:)",
        "ReclamationWatchdog.swift: manualControlReleased(fanAt:)",
        "ReclamationWatchdog.swift: reassert(_:fanAt:attempt:)",
        "ReclamationWatchdog.swift: releaseToThermalEmergency(fanAt:)",
        "SMCFanControlPlane.swift: readControlState(ofFan:)",
        "SMCFanControlPlane.swift: readCriticalTemperatures(_:)",
        "SMCFanControlPlane.swift: readEnvelope(ofFan:)",
        "SMCFanControlPlane.swift: readSubset(_:context:)",
        "SMCFanControlPlane.swift: reconnect()",
        "SMCReadScheduler.swift: read(keys:at:)",
        "SMCReadScheduler.swift: readAll()",
        "SMCReadScheduler.swift: takeTurn(at:)",
        "SMCReadScheduler.swift: yieldTurn(at:)",
        "SnapshotSensorReads.swift: read(keys:)",
        "SnapshotSensorReads.swift: readAll()",
        "ThermalEmergency.swift: cycle()",
        "ThermalEmergency.swift: cycleSawNothing(_:)",
        "ThermalEmergency.swift: fire(_:from:)",
        "ThermalEmergency.swift: takeBackAnythingEngagedSinceFiring()",
        "ThermalSupervisor.swift: run(emergency:clock:interval:log:)",
    ]

    /// Every function in the helper that could reach a firmware write: the `async` ones,
    /// plus the actor-isolated ones that carry a permit without the keyword.
    private func population() throws -> [SeamScanner.Function] {
        try SeamScanner.functions(in: "AeolusHelper")
            .filter { $0.isAsync || $0.mentions(anyOf: Self.permits) }
    }

    // MARK: - The allowlist

    /// The scan #120 asks for, and the one that catches a verb named outside every stem.
    ///
    /// Both directions are asserted. An unlisted function is the new-verb case. A listed
    /// function that is no longer in the tree is list rot, and a rotting allowlist is how an
    /// entry survives the deletion of the thing it was acknowledging.
    @Test("Every function that could reach a write is on exactly one acknowledged list")
    func everyVerbIsAcknowledged() throws {
        let acknowledged = Self.permitBearingVerbs
            .union(Self.restoreVerbs)
            .union(Self.permitFreeFunctions)
        #expect(
            Self.permitBearingVerbs.count + Self.restoreVerbs.count
                + Self.permitFreeFunctions.count == acknowledged.count,
            "a verb is on two lists at once — its classification is the thing being asserted")

        let scanned = Set(try population().map(\.key))

        let unlisted = scanned.subtracting(acknowledged).sorted()
        #expect(
            unlisted.isEmpty,
            """
            \(unlisted.count) function(s) in Sources/AeolusHelper are not acknowledged: \
            \(unlisted). Classify each one: `permitBearingVerbs` if it names a permit, \
            `restoreVerbs` if it is ADR 0007's keystone, `permitFreeFunctions` otherwise — \
            and if it writes to a fan without a permit, that is the defect, not the list.
            """
        )

        let departed = acknowledged.subtracting(scanned).sorted()
        #expect(
            departed.isEmpty,
            """
            \(departed.count) acknowledged function(s) are no longer in the tree: \
            \(departed). Remove the entry, so the list keeps naming what exists.
            """
        )
    }

    // MARK: - The property each list claims

    /// The half that keeps the allowlist from being bookkeeping.
    ///
    /// The lists are written by hand, so nothing stops a new write verb being filed under
    /// `permitFreeFunctions` — except this: a function that names a permit must be on the
    /// permit list, and the check runs in both directions. Handing a permit to something
    /// filed as permit-free fails here rather than passing quietly.
    @Test("Exactly the acknowledged permit-bearing verbs name a permit")
    func onlyAcknowledgedVerbsNameAPermit() throws {
        let bearing = Set(
            try population().filter { $0.mentions(anyOf: Self.permits) }.map(\.key))

        #expect(
            bearing == Self.permitBearingVerbs,
            """
            the set of functions naming a permit has changed. Added: \
            \(bearing.subtracting(Self.permitBearingVerbs).sorted()). Removed: \
            \(Self.permitBearingVerbs.subtracting(bearing).sorted()). A permit is the \
            authority to write to a fan — acknowledge who holds one.
            """
        )
    }

    /// `expectPermitIsTheOnlyParameter`'s rule, restated for the verbs that legitimately
    /// take a companion value.
    ///
    /// Sole-parameter is the right rule for `commandTarget(_:)` and `engageManualControl`
    /// and stays asserted there. It is not the rule the two `command` verbs can satisfy, and
    /// #141's point is that the honest response to that is to say what a companion may be
    /// rather than to stop looking. So: at most one permit, and every other parameter drawn
    /// from a vocabulary that cannot name a fan or its bounds.
    ///
    /// **The two matches are deliberately different strengths, and the asymmetry is the
    /// point.** Deciding *whether a verb must be acknowledged* is a substring match, so a
    /// parameter of type `AuthorisedFanTargetPair` pulls its verb into the population rather
    /// than out of it. Deciding *whether a parameter is a permit* is exact equality, because
    /// that impersonating type is freely constructible and is the second draft `ADR 0008`
    /// records passing a "names a permit" check while naming no permit — so it counts as a
    /// companion here, and fails as one.
    @Test("A permit travels beside nothing that can name a different fan")
    func aPermitTravelsBesideNothingThatNamesAFan() throws {
        let bearing = try population().filter { $0.mentions(anyOf: Self.permits) }

        #expect(
            bearing.count == Self.permitBearingVerbs.count,
            "this scan is looking at \(bearing.count) verbs, not the acknowledged list")

        for verb in bearing {
            let permits = verb.parameterTypes.filter(Self.permits.contains)
            #expect(
                permits.count <= 1,
                """
                \(verb.file) declares `\(verb.text)`, taking \(permits.count) permits. Two \
                permits are two fans that can disagree — ADR 0008.
                """
            )
            for type in verb.parameterTypes where !Self.permits.contains(type) {
                #expect(
                    Self.clampedCompanions.contains(type),
                    """
                    \(verb.file) declares `\(verb.text)`, passing a `\(type)` beside a \
                    permit. Only \(Self.clampedCompanions) may travel with one: they name \
                    no fan and no bounds, and a speed among them is clamped through the \
                    permit's own envelope. An index is exactly what ADR 0008 removed, and a \
                    type whose name merely contains a permit's is not a permit.
                    """
                )
            }
        }
    }

    /// The keystone's population half. `theRestoreVerbTakesNoAuthorisation` asserts the
    /// property on the verbs a `restore\w*` pattern finds; this asserts that the verbs the
    /// pattern finds are the verbs there are.
    @Test("Every acknowledged restore verb is in the tree and carries no authorisation")
    func restoreVerbsCarryNoAuthorisation() throws {
        let byKey = Dictionary(
            try population().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for key in Self.restoreVerbs.sorted() {
            let verb = try #require(byKey[key], "\(key) is acknowledged but not in the tree")
            #expect(
                !verb.mentions(anyOf: Self.permits),
                """
                \(verb.file) declares `\(verb.text)`. Restore-to-automatic must never depend \
                on trusted data — ADR 0007's keystone — and a permit is trusted data.
                """
            )
        }
    }
}
