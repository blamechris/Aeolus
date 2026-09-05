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
///   That is the one route around "a synchronous function cannot `await`".
///   `Sources/AeolusHelper` has **fifteen** such spawn sites today, and an earlier draft of
///   this bullet said five and called them all supervisors — which was both the wrong number
///   and the wrong description, so the containment argument it offered was not the one the
///   tree supports. The real one, asserted by `everyUnstructuredTaskHandsOffToThePopulation`
///   below: **no spawn site writes in its own body; each hands off to an `async` method that
///   is itself in this population.** Seven are `HelperXPCService`'s XPC entry points hopping
///   a message onto `HelperConnectionSession`; one is `HelperListenerDelegate`'s invalidation
///   hop onto the same actor; one is `ReadOnlyFanAuthority`'s single-flight sensor walk;
///   three are the supervisors' `Task.detached` handing control to an `async run(…)`; one
///   is `BoundedFanRestorer.attemptUncancellably(fanAt:)`, added by
///   [#175](https://github.com/blamechris/Aeolus/pull/175); one is
///   `AeolusHelperMain.bringUp(_:advertising:log:)`, added by
///   [#163](https://github.com/blamechris/Aeolus/issues/163); and one is
///   `CriticalTemperatureCache.sighting()`, added by
///   [#134](https://github.com/blamechris/Aeolus/issues/134).
///
///   **The `CriticalTemperatureCache` one is `BoundedFanRestorer`'s shape, not this bullet's
///   hazard.** Its spawner is already `async`, so it is not a synchronous function reaching a
///   write; the `Task` is there to make one read joinable by every caller that arrives during
///   it, which is `ReadOnlyFanAuthority.discoverSensorKeys()`'s pattern exactly. Its body is a
///   single `await` of `CriticalTemperatureSensing.readCriticalTemperatures()`, which
///   `permitFreeFunctions` acknowledges, and the seam it reaches is a **read** — the type
///   holds no writer and no plane.
///
///   **The `AeolusHelperMain` one is the only site that is this bullet's hazard exactly**:
///   `main()` is synchronous and cannot `await`, `NSXPCListener` is not `Sendable` so the
///   listener may not cross into the task, and the body therefore spawns, awaits
///   `HelperComposition.bringUp()` — which `permitFreeFunctions` acknowledges — and signals a
///   `DispatchSemaphore`. Neither statement touches a fan, and the composition's own
///   `bringUp()` binds registries and starts supervisors rather than writing.
///
///   **The `BoundedFanRestorer` one is not an instance of this bullet's hazard at all, and
///   saying so is worth more than the tidier sentence.** Its spawner is already `async`, so
///   it is not a synchronous function reaching a write; the `Task` is there because an
///   unstructured one does not inherit cancellation, and ADR 0007's keystone must not be
///   abandoned because the caller went away. It is counted here anyway, because the count is
///   of the *shape* the scanner can see — a body that could write out of the population's
///   reach — and exempting a spawn site on the strength of what its author meant is how a
///   count stops being a guard. Its body awaits `restoreOnce(fanAt:)`, which `restoreVerbs`
///   acknowledges, so the containment argument holds for it by the same route as the rest.
///
///   An earlier draft of this bullet said each body was *a single* `await` of a population
///   member. That is true of eleven of the fifteen and **false of the three supervisors**,
///   whose bodies await `run(…)` and then `loopEnded(generation:)` — a private, synchronous,
///   actor-isolated method whose entire body is `task = nil`, so it is in no population here
///   and could not be: it is neither `async` nor permit-bearing — **and false of
///   `AeolusHelperMain`'s**, which awaits one population member and then signals a semaphore.
///   None of the four touches a fan, which is why the containment still holds; but "a single
///   await" was a stronger sentence than the tree supports, and this suite exists to stop
///   exactly that.
/// - **A verb listed on the wrong list on purpose.** Putting a writer in
///   `permitFreeFunctions` is a lie a reviewer can read, which is the trade every allowlist
///   makes; what it buys is that the lie has to be written down.
/// - **A computed property.** The permit mint is one — `FanEnvelope.commandable` — and what
///   confines it is the access levels
///   `WriteAuthorisationTests.anAuthorisationTypeCannotBeMintedElsewhere` asserts.
/// - **A `subscript`, and its `get async throws` accessor.** `func <name>` is what is
///   scanned. There is none in the target; one vending a permit would be as invisible as a
///   computed property, and is confined by the same access levels.
/// - **A stored closure.** `let write: (CommandableFan) async throws -> Void` capturing the
///   plane is a verb by any useful definition and is not a `func`, so it is not here either.
///   This one is worth naming separately because, unlike the two above, it needs no new type
///   to express — only a `let`.
/// - **An operator.** `SeamScanner.functions(in:)` scans `func <name>`, so
///   `SafetyPrecedence.swift`'s synchronous `static func <` is not in the population at all.
///
/// One gap runs the *other* way and is stated for symmetry: a `func` written inside a string
/// literal is scanned as a declaration, because the comment stripper preserves literals
/// rather than lexing them. That adds a phantom to the population, so it fails loudly on
/// `everyVerbIsAcknowledged` rather than concealing anything — which is the direction a
/// tripwire may err in.
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
        "FanControlPlane.swift: commandTarget(_: AuthorisedFanTarget)",
        "FanControlPlane.swift: engageManualControl(of: CommandableFan)",
        "SMCFanControlPlane.swift: commandTarget(_: AuthorisedFanTarget)",
        "SMCFanControlPlane.swift: engageManualControl(of: CommandableFan)",
        "SafetyWriters.swift: command(_: Double, of: CommandableFan)",
        "SafetyWriters.swift: command(towards: Double, of: CommandableFan, since: Duration)",
        "SafetyWriters.swift: commandMaximum(of: CommandableFan)",
        "SafetyWriters.swift: engageManualControl(of: CommandableFan)",
        "FanWriteAuthorisation.swift: target(for: Double)",
        "ThermalEmergency.swift: manualControlEngaged(_: CommandableFan)",
        "ThermalEmergency.swift: bridgeToMaximumThenRelease(_: CommandableFan)",
        "ReclamationWatchdog.swift: manualControlEngaged(_: CommandableFan)",
    ]

    /// The keystone verbs, which take no authorisation of any kind and must not start.
    ///
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md): restore-to-automatic must
    /// never depend on trusted data, because it is the action that must remain available to
    /// a helper that cannot read. A permit *is* trusted data.
    ///
    /// The list names the keystone verbs a maintainer has acknowledged; it does not by
    /// itself assert that they are all of them. Exhaustiveness comes from
    /// `everyVerbIsAcknowledged`, whose union of the three lists must equal the scanned
    /// population in both directions — an unlisted restore verb fails there, not here. An
    /// earlier version of this comment claimed this list "asserts what there is to find",
    /// which is a claim about a test that does not exist.
    ///
    /// [#175](https://github.com/blamechris/Aeolus/pull/175) added the first two entries
    /// naming neither a plane nor an authority.
    /// `BoundedFanRestorer.restoreToAutomatic(fans:because:)` is the shipped `FanRestoring`
    /// conformer — [#110](https://github.com/blamechris/Aeolus/issues/110)'s bound — and
    /// `restoreOnce(fanAt:)` is the `FanRestoreAttempting` requirement it spends that budget
    /// against: the keystone at its narrowest, one fan and one attempt.
    /// `restoreToAutomatic` takes a set of indices and a cause, `restoreOnce` a single index
    /// — and neither takes anything else, which is the property this list holds them to. **A
    /// bound on the attempts is not authorisation**, and the distinction is the reason they
    /// belong here rather than reading as a hedged keystone: the budget decides how many
    /// times to try the write, never whether the caller is entitled to it, and it is spent
    /// without consulting a lease, a sensor or a permit.
    private static let restoreVerbs: Set<String> = [
        "BoundedFanRestorer.swift: restoreOnce(fanAt: Int)",
        "HelperFanRestorer.swift: restoreOnce(fanAt: Int)",
        "HelperFanRestorer.swift: restoreToAutomatic(fans: Set<Int>, "
            + "because: FanRestoreCause)",
        "SupervisedFanAuthority.swift: restoreAllToAutomatic(from: ConnectionID)",
        "BoundedFanRestorer.swift: restoreToAutomatic(fans: Set<Int>, "
            + "because: FanRestoreCause)",
        "FanControlPlane.swift: restoreToAutomatic(_: FanRestoreScope)",
        "SMCFanControlPlane.swift: restoreToAutomatic(_: FanRestoreScope)",
        "SafetyWriters.swift: restoreToAutomatic(_: FanRestoreScope)",
        "FanRestoring.swift: restoreToAutomatic(fans: Set<Int>, because: FanRestoreCause)",
        "LeaseAuthority.swift: restore(_: Set<Int>, because: FanRestoreCause)",
        "FanAuthority.swift: restoreAllToAutomatic(from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: restoreAllToAutomatic(from: ConnectionID)",
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
    ///
    /// `BoundedFanRestorer.attemptUncancellably(fanAt:)` is the entry most likely to be
    /// read as misfiled, so the reason is written down rather than left to be re-derived. It
    /// sits *between* two entries on the restore list — `restoreToAutomatic(fans:because:)`
    /// calls it and it calls `restoreOnce(fanAt:)` — and holds no permit, which is the same
    /// shape as every other function here that reaches the keystone: `LeaseAuthority`'s
    /// `revokeEveryLease(because:)` and `ReclamationWatchdog.finaliseRelease(fanAt:because:)`
    /// are on this list for exactly that reason. What it adds is a `Task` that does not
    /// inherit cancellation, not a decision about whether the restore may happen — so
    /// `restoreVerbs`, whose entries are the verbs ADR 0007 names, would be the misfiling.
    private static let permitFreeFunctions: Set<String> = [
        "BoundedFanRestorer.swift: attemptUncancellably(fanAt: Int)",
        // `CriticalTemperatureRecording`'s single requirement, declared beside the cache in
        // the same file. The scan sees it because the requirement is `async` — an actor's
        // isolated method witnesses it — and it is permit-free for the same reason
        // `sighting()` below is: the type holds no writer and no plane, and the whole of the
        // conformer's body is an assignment to a stored property.
        "CriticalTemperatureCache.swift: record(_: CriticalTemperatureSighting)",
        "CriticalTemperatureCache.swift: sighting()",
        "CriticalTemperatureSensing.swift: readCriticalTemperatures()",
        "FanAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "FanAuthority.swift: apply(_: [FanSetting], leaseID: UUID, from: ConnectionID)",
        "FanAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        "FanAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        "FanAuthority.swift: renewLease(id: UUID, from: ConnectionID)",
        "FanAuthority.swift: snapshot()",
        "FanControlPlane.swift: readControlState(ofFan: Int)",
        "FanControlPlane.swift: readCriticalTemperatures(_: [SMCKey])",
        "FanControlPlane.swift: readEnvelope(ofFan: Int)",
        "FanControlPlane.swift: reconnect()",
        "FanModeSensing.swift: modes(ofFans: [Int])",
        "FanModeSensing.swift: readMode(ofFan: Int)",
        "FanRestoring.swift: enumeratedFanIndices()",
        "HelperComposition.swift: bindSafetyRegistries()",
        "HelperComposition.swift: bringUp()",
        "HelperComposition.swift: shutDown()",
        "HelperConnectionSession.swift: acquireLease(payload: Data)",
        "HelperConnectionSession.swift: apply(settings: Data, leaseID: String)",
        "HelperConnectionSession.swift: hello(payload: Data)",
        "HelperConnectionSession.swift: invalidate()",
        "HelperConnectionSession.swift: releaseLease(id: String)",
        "HelperConnectionSession.swift: renewLease(id: String)",
        "HelperConnectionSession.swift: snapshot()",
        "LeaseAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "LeaseAuthority.swift: activeLease()",
        "LeaseAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        "LeaseAuthority.swift: expireLapsedLeases()",
        "LeaseAuthority.swift: refuseIfBlind(_: ConnectionID)",
        "LeaseAuthority.swift: refuseIfThermalEmergencyActive(_: ConnectionID)",
        "LeaseAuthority.swift: releaseEveryLease()",
        "LeaseAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        "LeaseAuthority.swift: revokeEveryLease(because: FanRestoreCause)",
        "LeaseAuthority.swift: revokeLeases(coveringFan: Int, because: FanRestoreCause)",
        "LeaseClock.swift: sleep(until: ContinuousClock.Instant)",
        "LeaseExpirySupervisor.swift: run(authority: LeaseAuthority, "
            + "clock: some MonotonicClock, idleInterval: Duration, log: LeaseLog)",
        "ReadOnlyFanAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: apply(_: [FanSetting], leaseID: UUID, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        "ReadOnlyFanAuthority.swift: discoverSensorKeys()",
        "ReadOnlyFanAuthority.swift: enumeratedFanIndices()",
        "ReadOnlyFanAuthority.swift: readSensors()",
        "ReadOnlyFanAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: renewLease(id: UUID, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: snapshot()",
        "ReadOnlyFanAuthority.swift: walkEveryKey()",
        "ReclamationSupervisor.swift: run(watchdog: ReclamationWatchdog<Plane>, "
            + "clock: some MonotonicClock, interval: Duration, log: SafetyLog)",
        "ReclamationWatchdog.swift: currentRuling()",
        "ReclamationWatchdog.swift: cycle()",
        "ReclamationWatchdog.swift: cycleCouldNotSee(fanAt: Int, detail: String)",
        "ReclamationWatchdog.swift: diverged(_: ReclamationDivergence, fanAt: Int)",
        "ReclamationWatchdog.swift: examine(fanAt: Int)",
        "ReclamationWatchdog.swift: finaliseRelease(fanAt: Int, because: FanRestoreCause)",
        "ReclamationWatchdog.swift: manualControlReleased(fanAt: Int)",
        "ReclamationWatchdog.swift: reassert(_: CommandedTarget, fanAt: Int, attempt: Int)",
        "ReclamationWatchdog.swift: releaseToThermalEmergency(fanAt: Int)",
        "SMCFanControlPlane.swift: readControlState(ofFan: Int)",
        "SMCFanControlPlane.swift: readCriticalTemperatures(_: [SMCKey])",
        "SMCFanControlPlane.swift: readEnvelope(ofFan: Int)",
        "SMCFanControlPlane.swift: readSubset(_: [SMCKey], context: String)",
        "SMCFanControlPlane.swift: reconnect()",
        "SMCReadScheduler.swift: read(keys: [String], at: SMCReadPriority)",
        "SMCReadScheduler.swift: readAll()",
        "SMCReadScheduler.swift: takeTurn(at: SMCReadPriority)",
        "SMCReadScheduler.swift: yieldTurn(at: SMCReadPriority)",
        "SnapshotSensorReads.swift: read(keys: [String])",
        "SnapshotSensorReads.swift: readAll()",
        "SupervisedFanAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "SupervisedFanAuthority.swift: apply(_: [FanSetting], leaseID: UUID, "
            + "from: ConnectionID)",
        "SupervisedFanAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        "SupervisedFanAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        "SupervisedFanAuthority.swift: renewLease(id: UUID, from: ConnectionID)",
        "SupervisedFanAuthority.swift: snapshot()",
        "ThermalEmergency.swift: cycle()",
        "ThermalEmergency.swift: cycleSawNothing(_: String)",
        "ThermalEmergency.swift: fire(_: CriticalTemperature, from: CriticalTemperatureReport)",
        "ThermalEmergency.swift: takeBackAnythingEngagedSinceFiring()",
        "ThermalSupervisor.swift: run(emergency: ThermalEmergency<Plane>, "
            + "clock: some MonotonicClock, interval: Duration, log: SafetyLog)",
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

        // Distinct keys, not `bearing.count`: a protocol requirement and its same-file
        // conformer are two declarations sharing one key, exactly as `LeaseClock` and
        // `CriticalTemperatureSensing` are written today. Counting declarations made a
        // permit-bearing verb written that way fail this guard with **no entry a maintainer
        // could add** — the list is keyed, so it can never hold the second one.
        let bearingKeys = Set(bearing.map(\.key))
        #expect(
            bearingKeys == Self.permitBearingVerbs,
            "this scan is looking at \(bearingKeys.count) verbs, not the acknowledged list")

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

    /// ADR 0007's keystone, said in one place and failing with the ADR's own words.
    ///
    /// **This test cannot fail alone, and that is stated rather than hidden.** A restore verb
    /// that grew a permit also reddens `onlyAcknowledgedVerbsNameAPermit` (its key joins the
    /// bearing set), and moving the entry to `permitBearingVerbs` to quiet that reddens
    /// `everyVerbIsAcknowledged`'s two-lists-at-once check. What this adds is the failure
    /// *message*: a set difference tells a maintainer which key moved, and only this says why
    /// a restore verb may not hold one. That is the whole of its job.
    ///
    /// It iterates every population member whose key is acknowledged rather than collapsing
    /// the population into a dictionary first. A dictionary keeps one declaration per key, so
    /// the earlier form examined the protocol requirement and never the same-file conformer
    /// beneath it — the one shape where the two can disagree.
    @Test("Every acknowledged restore verb is in the tree and carries no authorisation")
    func restoreVerbsCarryNoAuthorisation() throws {
        let scanned = try population()

        for key in Self.restoreVerbs.sorted() {
            let declarations = scanned.filter { $0.key == key }
            #expect(!declarations.isEmpty, "\(key) is acknowledged but not in the tree")

            for verb in declarations {
                #expect(
                    !verb.mentions(anyOf: Self.permits),
                    """
                    \(verb.file) declares `\(verb.text)`. Restore-to-automatic must never \
                    depend on trusted data — ADR 0007's keystone — and a permit is trusted \
                    data.
                    """
                )
            }
        }
    }

    // MARK: - The route around "a synchronous function cannot await"

    /// The suite doc's first stated limit, asserted rather than asserted *about*.
    ///
    /// An unstructured `Task` lets a synchronous function reach an `async` write, so every
    /// spawn site is a hole in the population — unless what it spawns is itself acknowledged.
    /// That is what holds here: none of the fifteen bodies writes, and each hands off to an
    /// `async` method in the population. (The three supervisors also await a synchronous
    /// `loopEnded(generation:)` that only clears a task handle; `BoundedFanRestorer`'s and
    /// `CriticalTemperatureCache`'s spawners are themselves `async`, so their `Task`s shield
    /// cancellation and share one read rather than bridging from synchronous code; and
    /// `AeolusHelperMain`'s also signals a `DispatchSemaphore`, which
    /// is how the listener stays off the task that cannot safely carry it — see the suite
    /// doc, which says all four rather than rounding them off.)
    ///
    /// The count is asserted per file so it cannot drift silently. A sixteenth spawn site
    /// fails this with the file it was added to, and the maintainer either shows it hands off
    /// the same way and updates the number, or has found the hole.
    ///
    /// **The number churns, and that is the acknowledgment discipline #120 asked for, not an
    /// oversight.** Any helper PR that adds a `Task` reddens this until its author writes the
    /// new count down — the failure message names the file and prints both dictionaries, so
    /// what to update is never in doubt. A count that maintained itself would assert nothing.
    ///
    /// The pattern lives in `SeamScanner.unstructuredTaskSpawns(inSource:)` so a fixture can
    /// be put through it. Written inline here, its first spelling missed
    /// `Task<Void, Never> { … }` — a legal spelling of exactly the thing being counted — and
    /// nothing could have noticed, because the only thing exercising it was the tree whose
    /// shapes it already matched.
    @Test("Every unstructured Task in the helper hands off to an acknowledged verb")
    func everyUnstructuredTaskHandsOffToThePopulation() throws {
        let expected = [
            "AeolusHelperMain.swift": 1,
            "BoundedFanRestorer.swift": 1,
            "CriticalTemperatureCache.swift": 1,
            "HelperListenerDelegate.swift": 1,
            "HelperXPCService.swift": 7,
            "LeaseExpirySupervisor.swift": 1,
            "ReadOnlyFanAuthority.swift": 1,
            "ReclamationSupervisor.swift": 1,
            "ThermalSupervisor.swift": 1,
        ]

        var counted: [String: Int] = [:]

        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let matches = try SeamScanner.unstructuredTaskSpawns(
                inSource: try String(contentsOf: file, encoding: .utf8))
            if matches > 0 { counted[file.lastPathComponent] = matches }
        }

        #expect(
            counted == expected,
            """
            the unstructured `Task` spawn sites in Sources/AeolusHelper changed: found \
            \(counted.sorted(by: { $0.key < $1.key })), expected \
            \(expected.sorted(by: { $0.key < $1.key })). Each existing one is a single \
            `await` of an `async` method that this suite acknowledges, which is the only \
            reason a synchronous spawner need not be in the population. Show that a new one \
            does the same — and if it writes in its own body, that is the hole, not the count.
            """
        )
    }
}
