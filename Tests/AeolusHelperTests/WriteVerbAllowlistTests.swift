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
/// `SafetyActorWriter.command(_:of:)`, `SafetyActorWriter.commandMaximum(of:)` (since #332 the
/// bridge verb `bridgeToMaximumThenRestore(of:)`), and
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
///   `Sources/AeolusHelper` has **eighteen** such spawn sites today, and an earlier draft of
///   this bullet said five and called them all supervisors — which was both the wrong number
///   and the wrong description, so the containment argument it offered was not the one the
///   tree supports. The count then said fourteen for one wave after
///   [#167](https://github.com/blamechris/Aeolus/issues/167) added two and updated only the
///   dictionary below, which is the same defect one layer up: the enforced number moved and
///   the argument that justifies it did not. The real one, asserted by
///   `everyUnstructuredTaskHandsOffToThePopulation` in `WriteVerbAllowlistTests+SpawnSites.swift`:
///   **no spawn site writes in its own body; each hands off to an `async` method that is itself
///   in this population**, bar #205's overrun alarm and A6's gate timer, which each make one
///   synchronous call that writes nothing. One is
///   `MessageSequencer.enqueue(_:)`, which replaced six of `HelperXPCService`'s seven XPC
///   entry points in [#90](https://github.com/blamechris/Aeolus/issues/90) — four of them
///   today — and is pinned by `MessageOrderingTests`; **three** are `HelperXPCService`'s
///   `restoreAllToAutomatic(reply:)`, `renewLease(id:reply:)` and `releaseLease(id:reply:)`,
///   which keep their own `Task`s because a queue is a precondition the panic path may not
///   acquire (D27) and a lease heartbeat may not either
///   ([#229](https://github.com/blamechris/Aeolus/issues/229)), and whose bodies are each a
///   single `await` of the matching `HelperConnectionSession` method; one is
///   `HelperListenerDelegate`'s
///   invalidation hop; one is
///   `ReadOnlyFanAuthority`'s single-flight sensor walk; three are the supervisors'
///   `Task.detached` handing control to an `async run(…)`; one is
///   `BoundedFanRestorer.attemptUncancellably(fanAt:)`, added by
///   [#175](https://github.com/blamechris/Aeolus/pull/175); one is
///   `AeolusHelperMain.bringUp(_:advertising:log:)`, added by
///   [#163](https://github.com/blamechris/Aeolus/issues/163); one is
///   `CriticalTemperatureCache.sighting()`, added by
///   [#134](https://github.com/blamechris/Aeolus/issues/134); one is
///   `SystemPowerRegistration.deliver(_:acknowledging:)`, the only route from a
///   `@convention(c)` IOKit callback — which cannot capture, let alone `await` — to an
///   `async` handler; and one is `SystemPowerResponder.allowSleepAfterHandback(_:)`'s
///   acknowledgement budget, which runs beside a handback `BoundedFanRestorer` makes
///   uncancellable and therefore cannot be a task group, since a group waits for every child;
///   one is `SignalTeardown.install(stoppingSupervisorsWith:)`, added by
///   [#166](https://github.com/blamechris/Aeolus/issues/166) — the two before it are #167's —
///   and one is `ConnectionHealth.start(recovering:)`'s event pump, added by
///   [#168](https://github.com/blamechris/Aeolus/issues/168).
///
///   **The `CriticalTemperatureCache` one is `BoundedFanRestorer`'s shape, not this bullet's
///   hazard.** Its spawner is already `async`, so it is not a synchronous function reaching a
///   write; the `Task` is there to make one read joinable by every caller that arrives during
///   it, which is `ReadOnlyFanAuthority.discoverSensorKeys()`'s pattern exactly. Its body is a
///   single `await` of `CriticalTemperatureSensing.readCriticalTemperatures()`, which
///   `permitFreeFunctions` acknowledges, and the seam it reaches is a **read** — the type
///   holds no writer and no plane.
///
///   **Three sites are this bullet's hazard exactly, and each bridges from a callback the
///   runtime hands it.** `SignalTeardown`'s is the newest: `DispatchSourceSignal`'s event
///   handler is a synchronous block, the teardown it runs is `async`, and there is no other
///   way across. Its body is one `await` of `run(stoppingSupervisorsWith:)`, which
///   `permitFreeFunctions` acknowledges, and it touches no fan of its own.
///   `SystemPowerRegistration`'s is the IOKit one described above.
///
///   **The `ConnectionHealth` one is not this bullet's hazard either**, and for a further
///   distinct reason worth writing down rather than rounding off. Its spawner is
///   actor-isolated and not `async`, so it *is* a synchronous function spawning a task — but
///   the task's body is an `AsyncStream` loop whose only statement awaits
///   `handle(_:recovering:)`, which `permitFreeFunctions` acknowledges. The `Task` is there
///   because the work has to leave the scheduler's call stack: `SchedulerObserving` is
///   reported synchronously from inside `SMCReadScheduler`'s actor, and a reconnect takes a
///   scheduler turn.
///
///   **The `AeolusHelperMain` one is the third**:
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
///   member. That is true of nine of the fourteen and **false of the three supervisors**,
///   whose bodies await `run(…)` and then `loopEnded(generation:)` — a private, synchronous,
///   actor-isolated method whose entire body is `task = nil`, so it is in no population here
///   and could not be: it is neither `async` nor permit-bearing — **false of
///   `AeolusHelperMain`'s**, which awaits one population member and then signals a semaphore,
///   **and false of `SystemPowerResponder`'s budget**, which awaits `MonotonicClock.sleep`
///   and then `SleepAcknowledgement.acknowledge(_:)`. None of the five touches a fan, which
///   is why the containment still holds; but "a single await" was a stronger sentence than
///   the tree supports, and this suite exists to stop exactly that.
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

    /// Companions allowed beside a permit for **one named key**, and for no other verb.
    ///
    /// `ReclamationWatchdog.manualControlEngaged(_:under:)` carries the `UUID` of the lease the
    /// fan was engaged under (#357). A registration writes nothing, and its lease is judged
    /// against the permit's own fan at registration and at every examination, so a mismatched
    /// pair ends as a refused registration or `.leaseLapsed`, never as a write. Keyed rather
    /// than added to `clampedCompanions`, so no write verb can take a `UUID` beside its permit:
    /// this suite stays red for one that does, and so does `everyEngageVerbTakesAPermit` unless
    /// the parameter has a default containing parentheses, such as `= UUID()`, whose
    /// declaration its scan misses ([#362](https://github.com/blamechris/Aeolus/issues/362)).
    ///
    /// A key is a file and a signature, not a declaring type, so a second declaration with the
    /// same signature in the same file — an extension on a writer, say — would share the
    /// exemption. `aPermitTravelsBesideNothingThatNamesAFan` therefore requires exactly one
    /// declaration per keyed key (#361's panel).
    ///
    /// The second entry is the same registration as a requirement of
    /// `ReclamationRegistrationRole`, the role level 6 tells § 5 through (ADR 0014's A6 PR-2
    /// amendment). The watchdog's method is its one witness, so it carries nothing the first
    /// entry does not.
    private static let keyedCompanions: [String: Set<String>] = [
        "ReclamationWatchdog.swift: manualControlEngaged(_: CommandableFan, under: UUID)": ["UUID"],
        "ReclamationRegistrationRole.swift: manualControlEngaged(_: CommandableFan, under: UUID)": [
            "UUID"
        ],
    ]

    /// The verbs that carry a permit: they command a fan, take one off automatic control,
    /// mint the permit, or hold one for a safety actor that will.
    ///
    /// Each is legitimate for a stated reason:
    ///
    /// - `FanControlPlane` / `SMCFanControlPlane`: `commandTarget(_:)` and
    ///   `engageManualControl(of:)` are the seam itself — the protocol requirement and its
    ///   production conformer. `bridgeThenRestore(_:)` is § 3's bridge job (ADR 0012's
    ///   2026-10-18 amendment): the permit's target, then the `.fan` restore of the permit's own
    ///   fan, so the restore it carries can name no fan but the one the permit was minted for.
    /// - `SafetyWriters`: `bridgeToMaximumThenRestore(of:)` is § 3's emergency write, the bridge
    ///   job at the permit's highest commandable speed; `command(_:of:)`
    ///   is § 5's bounded re-assert, which needs the number it last commanded rather than
    ///   the loudest one; `engageManualControl(of:)` is the step an engagement driver takes,
    ///   § 5's and level 6's; `command(towards:of:since:)` is the control loop's governed step,
    ///   and `hold(_:of:)` its one whole write of a fixed setting (ADR 0014's A6 amendments),
    ///   clamped through the permit like every other.
    /// - `FanWriteAuthorisation.target(for:)` is the *producer*: it clamps into the permit's
    ///   own envelope and stamps the permit's own index. It writes nothing.
    /// - `ThermalEmergency.manualControlEngaged(_:)` stores a permit minted elsewhere, so the
    ///   emergency's maximum write needs no read while the machine is above ceiling.
    ///   `bridgeToMaximumThenRelease(_:)` is what spends it.
    ///   `ReclamationWatchdog.manualControlEngaged(_:under:)` reads only the permit's index and
    ///   writes nothing; its `UUID` is `keyedCompanions`' first entry, and the same requirement
    ///   on `ReclamationRegistrationRole`, which it witnesses, the second.
    ///   `ThermalEmergency.restoredByEmergency(_:)` keeps a permit § 3 already held, for a
    ///   fan whose own restore is unconfirmed, so the next emergency can spend it (#300). It
    ///   writes nothing. `bridgeThenFileRestored(_:)` passes the same permit to those two in
    ///   turn, and only decides whether the second runs (#305).
    /// - `EngagementDriver` ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D2):
    ///   `engageManualControl(of:)` is the cadence around the plane's one-step verb, and the
    ///   permit is the only thing it takes, so the lease it checks is the permit's own fan.
    ///   `requireEntitlement(for:)` asks the latch and the lease about that permit and writes
    ///   nothing. `firstStep(of:)` is the engage verb's first step and its one retry after the
    ///   admission's `.superseded`, which is thrown before anything is written; a
    ///   `.supersededAfterWrite` is never retried. `manualControlEngaged(_:)` is § 3's registration
    ///   role (#181), the requirement `ThermalEmergency`'s entry above already witnesses.
    ///   `reAdopted(_:)` hands that role the permit of a fan level 6 holds again without an
    ///   engagement, and writes nothing: the permit goes only to § 3's registration, so the
    ///   emergency bridges every fan level 6 commands (ADR 0014's #410 refused-hand-back
    ///   amendment).
    private static let permitBearingVerbs: Set<String> = [
        "FanControlPlane.swift: commandTarget(_: AuthorisedFanTarget)",
        "FanControlPlane.swift: engageManualControl(of: CommandableFan)",
        "FanControlPlane.swift: bridgeThenRestore(_: AuthorisedFanTarget)",
        "SMCFanControlPlane.swift: commandTarget(_: AuthorisedFanTarget)",
        "SMCFanControlPlane.swift: engageManualControl(of: CommandableFan)",
        "SMCFanControlPlane.swift: bridgeThenRestore(_: AuthorisedFanTarget)",
        "SafetyWriters.swift: command(_: Double, of: CommandableFan)",
        "SafetyWriters.swift: command(towards: Double, of: CommandableFan, since: Duration)",
        "SafetyWriters.swift: hold(_: Double, of: CommandableFan)",
        "SafetyWriters.swift: bridgeToMaximumThenRestore(of: CommandableFan)",
        "SafetyWriters.swift: engageManualControl(of: CommandableFan)",
        "FanWriteAuthorisation.swift: target(for: Double)",
        "ThermalEmergency.swift: manualControlEngaged(_: CommandableFan)",
        "ThermalEmergency.swift: bridgeToMaximumThenRelease(_: CommandableFan)",
        "ThermalEmergency.swift: restoredByEmergency(_: CommandableFan)",
        "ThermalEmergency.swift: bridgeThenFileRestored(_: CommandableFan)",
        "ReclamationWatchdog.swift: manualControlEngaged(_: CommandableFan, under: UUID)",
        "ReclamationRegistrationRole.swift: manualControlEngaged(_: CommandableFan, under: UUID)",
        "EngagementDriver.swift: engageManualControl(of: CommandableFan)",
        "EngagementDriver.swift: requireEntitlement(for: CommandableFan)",
        "EngagementDriver.swift: firstStep(of: CommandableFan)",
        "EngagementDriver.swift: manualControlEngaged(_: CommandableFan)",
        "EngagementDriver.swift: reAdopted(_: CommandableFan)",
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
    ///
    /// `SignalTeardown.keystone(_:)` is here for the same reason and takes nothing but a scope:
    /// it is `restoreToAutomatic(.everyFan)` at the first keystone and `.forExit` at the last,
    /// plus the mapping from what that write answered to the process's exit code (ADR 0014's #410
    /// ticket-and-seal amendment). Naming no fan is what makes it the keystone at its widest — no
    /// reading, no bound, no lease — which is exactly the shape ADR 0007 defines it to have, and
    /// the reason a helper on its way out can always issue it.
    ///
    /// [#440](https://github.com/blamechris/Aeolus/issues/440) added three, each the keystone over
    /// a restorer it is lent rather than one it holds:
    /// `LeaseAuthority.restore(_:because:through:)`, the bracket's body for every teardown and for
    /// § 3's borrowed handback;
    /// `HelperFanRestorer.handBack(_:because:through:)`, the notices around a lent bound; and
    /// `ThermalCycleHandback.restoreToAutomatic(fans:because:)`, § 3's lane bound behind them. The
    /// lent restorer is a `FanRestoring` — fans and a cause in, the refused fans out — so the
    /// shape this list holds them to is unchanged: no permit, no bound, no reading.
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
        "LeaseAuthority.swift: restore(_: Set<Int>, because: FanRestoreCause, "
            + "through: borrowing Handback)",
        "HelperFanRestorer.swift: handBack(_: Set<Int>, because: FanRestoreCause, "
            + "through: borrowing Bound)",
        "ThermalCycleHandback.swift: restoreToAutomatic(fans: Set<Int>, "
            + "because: FanRestoreCause)",
        "StartupReconciliation.swift: restore(fanAt: Int)",
        "StartupReconciliation.swift: restoreEveryFan(because: SafetyLog.KeystoneReason, "
            + "until: ContinuousClock.Instant)",
        "FanAuthority.swift: restoreAllToAutomatic(from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: restoreAllToAutomatic(from: ConnectionID)",
        "HelperConnectionSessionMessages.swift: restoreAllToAutomatic()",
        "SignalTeardown.swift: keystone(_: FanRestoreScope)",
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
    /// `BoundedFanRestorer.attemptUncancellably(fanAt:)` is the entry most likely to be read as
    /// misfiled, so the reason is written down rather than left to be re-derived. It sits *between*
    /// two entries on the restore list — `restoreToAutomatic(fans:because:)` calls it and it calls
    /// `restoreOnce(fanAt:)` — and holds no permit, which is the same shape as every other function
    /// here that reaches the keystone: `LeaseAuthority`'s
    /// `revokeEveryLease(handingBackThrough:)` and
    /// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)` are on this list for exactly
    /// that reason. What it adds is a `Task` that does not inherit cancellation, not a decision
    /// about whether the restore may happen — so `restoreVerbs`, whose entries are the verbs ADR
    /// 0007 names, would be the misfiling.
    ///
    /// [#167](https://github.com/blamechris/Aeolus/issues/167)'s five entries are filed here on the
    /// same rule, and the one worth defending is
    /// `SystemPowerResponder.handBackEveryFan(reportingTo:)`. It drops every lease and then issues
    /// the machine-wide keystone, so it *causes* two writes — and causing a write is not what the
    /// restore list is for. Its entries are the verbs ADR 0007 names, spelled as ADR 0007 spells
    /// them; this one reaches the firmware only through `SafetyActorWriter.restoreToAutomatic(_:)`
    /// and `LeaseAuthority.releaseEveryLease()`, both already acknowledged, which is exactly the
    /// shape of `revokeEveryLease(handingBackThrough:)` and
    /// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)` here.
    /// `allowSleepAfterHandback` and `respond(to:)` are its callers, and the two `acknowledge`
    /// verbs put no fan write on any wire at all — one of them calls `IOAllowPowerChange`, which is
    /// a kernel message about power state and nothing to do with a fan.
    ///
    /// [#164](https://github.com/blamechris/Aeolus/issues/164) added five here and two to
    /// `restoreVerbs`, and the split is worth stating because startup reconciliation both
    /// reads the firmware and restores it. `StartupReconciliation.restore(fanAt:)` and
    /// `restoreEveryFan(because:until:)` are on the restore list for
    /// `LeaseAuthority.restore(_:because:)`'s reason — an index, or nothing at all, and no
    /// permit anywhere. `reconcile()` and `reconcileFans()` are here for
    /// `ReclamationWatchdog.cycle()`'s: they reach the keystone, and can only do it through
    /// those two. `refusalForGrant(overFans:heldByAeolus:awaitingConfirmation:)`
    /// and `refuseIfForeignManualControl(_:wanting:)` read `F<n>Md` and return a refusal — they
    /// are the half of ADR 0011 that exists **so that** no second restore happens, which is
    /// the opposite of a write verb. `activeLeaseView()` reads the lease table.
    ///
    /// **Two keys moved file in [#128](https://github.com/blamechris/Aeolus/issues/128) and
    /// are re-pinned rather than relaxed.** `refuseIfBlind(_:)` and
    /// `refuseIfForeignManualControl(_:wanting:)` are declared in
    /// `LeaseAuthorityRefusals.swift` now — the same declarations, in an extension in a
    /// second file, because `LeaseAuthority.swift` was over the lint threshold. `key` is
    /// `file: signature`, so a split moves an entry even when nothing about the verb
    /// changes; the entries follow the declarations, and `everyVerbIsAcknowledged`'s
    /// `departed` half is what makes leaving the old key behind a failure rather than dead
    /// weight. Their classification is unchanged: both refuse, neither writes.
    ///
    /// **Five more moved in [#98](https://github.com/blamechris/Aeolus/issues/98)**, plus
    /// `restoreAllToAutomatic()` on `restoreVerbs`, when `HelperConnectionSession.swift` was
    /// split three ways at the 400-line limit. The five gated messages are declared in
    /// `HelperConnectionSessionMessages.swift` now; `hello(payload:)` and `invalidate()` are
    /// still in `HelperConnectionSession.swift`, because they are the two that *write* this
    /// connection's state and the split deliberately left the storage with them. Same
    /// re-pin, same reason as #128's — and this suite going red before the entries were
    /// updated is the evidence that a file split in the helper cannot happen quietly.
    private static let permitFreeFunctions: Set<String> = [
        "BoundedFanRestorer.swift: attemptUncancellably(fanAt: Int)",
        // `CriticalTemperatureRecording`'s two requirements, declared beside the cache in the
        // same file. The scan sees them because the requirements are `async` — an actor's
        // isolated methods witness them — and they are permit-free for the same reason
        // `sighting()` below is: the type holds no writer and no plane, and the whole of the
        // conformer's body is a comparison and an assignment to a stored property.
        //
        // There was one of these until [#280](https://github.com/blamechris/Aeolus/issues/280),
        // and the first version of this note overclaimed what replaced it — corrected here
        // rather than quietly reworded. `beganReading()` is not a way into the cache's memory
        // at all: it mints an instant and returns it, and compares nothing. And
        // `record(_:since:)` compares only a `.sighted`; a `.blind` bypasses on purpose.
        //
        // The true property, which is the one worth an allowlist entry: `record(_:since:)` is
        // the **only recording requirement on the protocol**, and the unguarded
        // `record(_: CriticalTemperatureSighting)` that used to sit here is `private` now and
        // out of this scan entirely. Re-adding an unguarded recorder to the protocol is
        // caught mechanically — it would be `async`, enter `population()`, and fail this test
        // as unlisted. Where it is *called* is `SightingRecordingSeamTests`' property, not
        // this one.
        "CriticalTemperatureCache.swift: beganReading()",
        "CriticalTemperatureCache.swift: record(_: CriticalTemperatureSighting, "
            + "since: CriticalTemperatureReadingStart)",
        "CriticalTemperatureCache.swift: sighting()",
        "HelperComposition.swift: reconcileFans()",
        "LeaseAuthority.swift: activeLeaseView()",
        "StartupReconciliation.swift: reconcile()",
        "StartupReconciliation.swift: refusalForGrant(overFans: Set<Int>, "
            + "heldByAeolus: Set<Int>, awaitingConfirmation: Set<Int>)",
        // #204's four. `confirmKeystone(until:)` is the keystone's read-back: it follows
        // `restoreEveryFan(because:until:)` and reads `F<n>Md`, and writes nothing. The two
        // `baseline()` entries are the snapshot's seam and its one conformer, which return a
        // value. `refusalForGrant` in `ReconciliationBaseline.swift` is the protocol
        // declaration, moved out of `StartupReconciliation.swift` with no change to it.
        "StartupReconciliation.swift: confirmKeystone(until: ContinuousClock.Instant)",
        "StartupReconciliation.swift: baseline()",
        "ReconciliationBaseline.swift: baseline()",
        "ReconciliationBaseline.swift: refusalForGrant(overFans: Set<Int>, "
            + "heldByAeolus: Set<Int>, awaitingConfirmation: Set<Int>)",
        // #291's five. `readBack(_:until:)` is the loop `confirmKeystone(until:)` used to
        // hold, and `confirmHandbacksByName(until:fans:)` calls it for a complete pass: both
        // read `F<n>Md` and write nothing. `fansReadingAutomatic(among:)` is the lease core's
        // read-back seam and its one conformer — a read per fan, and no writer in reach.
        "StartupReconciliation.swift: readBack(_: Set<Int>, until: ContinuousClock.Instant)",
        "StartupReconciliation.swift: confirmHandbacksByName("
            + "until: ContinuousClock.Instant, fans: Int)",
        "StartupReconciliation.swift: fansReadingAutomatic(among: Set<Int>)",
        "ReconciliationBaseline.swift: fansReadingAutomatic(among: Set<Int>)",
        // And the lease core's caller of it, which § 7 alone invokes: a read and two set
        // subtractions, no restorer and no plane in its body.
        "LeaseAuthority.swift: confirmAcceptedHandbacks()",
        // #350's grant seal, filed here on `withExclusiveAccess`'s rule below: it runs a body the
        // caller supplies, so what that body may do is the caller's classification. Its two
        // callers are `SupervisedFanAuthority.restoreAllToAutomatic`, on the restore list, and
        // `SystemPowerResponder.allowSleepAfterHandback` (#364), below. Its own body is a counter
        // and the call; it names no permit, restorer or plane.
        "LeaseAuthority.swift: sealingGrants(during: @Sendable () async -> Outcome)",
        // #368's outwait: a `releasing` lookup and a continuation parked until `restore`'s
        // `defer` resumes it. Private, and it names no permit, restorer or plane: it waits for a
        // write somebody else issued and issues none.
        "LeaseAuthority.swift: outwaitHandback(of: Int)",
        // #295's three. `handbackReadings(of:)` is § 3's non-logging read-back seam and its
        // one conformer, which `fansReadingAutomatic(among:)` is now built on: a read per fan
        // and no writer in reach. `readBackAcceptedHandbacks()` is § 3's caller of it — a read
        // and dictionary removals, no writer call in its body.
        "StartupReconciliation.swift: handbackReadings(of: Set<Int>)",
        "ReconciliationBaseline.swift: handbackReadings(of: Set<Int>)",
        "ThermalEmergency.swift: readBackAcceptedHandbacks()",
        // #168's five. None of them can express a fan write: `withExclusiveAccess` runs an
        // arbitrary body under a scheduler turn and could in principle carry one — but the
        // body is supplied by the caller, so what it may do is the *caller's* classification,
        // and its one caller is `SMCFanControlPlane.reconnect()` on this list. `close()` and
        // `open()` are `SMCConnectionRecycling`'s two verbs: connection lifecycle, no key, no
        // fan, no value on the wire.
        "ConnectionHealth.swift: attemptReconnect(through: some SMCConnectionRecovering)",
        // #205's one: the run's increment, lifted out of `handle(_:recovering:)` so a walk's
        // outcome and a subset read's are counted by the same line. It reaches a write only
        // through `attemptReconnect(through:)`, above, which is connection lifecycle.
        "ConnectionHealth.swift: countFailure(recovering: some SMCConnectionRecovering)",
        "ConnectionHealth.swift: handle(_: SequencedOutcome, "
            + "recovering: some SMCConnectionRecovering)",
        "SMCFanControlPlane.swift: close()",
        "SMCFanControlPlane.swift: open()",
        "SMCReadScheduler.swift: withExclusiveAccess(_: @Sendable () async throws -> T)",
        // B1's write turn, on `withExclusiveAccess`'s rule: one `.supervisor` turn around a
        // synchronous job the caller supplies, on the channel it is handed, so what the job may
        // do is the caller's classification. It has no caller yet; the plane's write turns, when
        // they exist, are classified where they are declared. Its own body is the turn and the
        // call.
        "SMCReadScheduler.swift: withWriteTurn(on: any SMCWriteChannel, "
            + "_: @Sendable (isolated any SMCWriteChannel) throws -> T)",
        "CriticalTemperatureSensing.swift: readCriticalTemperatures()",
        "FanAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "FanAuthority.swift: apply(_: [FanSetting], leaseID: UUID, from: ConnectionID)",
        "FanAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        "FanAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        "FanAuthority.swift: renewLease(id: UUID, from: ConnectionID)",
        "FanAuthority.swift: snapshot()",
        "FanControlPlane.swift: readControlState(ofFan: Int)",
        "FanControlPlane.swift: readCriticalTemperatures(_: [SMCKey])",
        // #270 moved this requirement into a role of its own, refined by `FanStateSensing`
        // unchanged, so the lease core can hold the one read verb. Re-pinned, not relaxed: it
        // returns the declared bounds and writes nothing.
        "FanEnvelopeReading.swift: readEnvelope(ofFan: Int)",
        // ADR 0014's A6 amendment: the examination gate's entries and its wait. Each touches the
        // gate's own lock and continuations, and a timer that sleeps on the composition's clock;
        // none reaches a plane, a writer or a fan, and nothing on a write path names the gate.
        "FanExaminationGate.swift: enter(fanAt: Int, as: Party, within: Duration)",
        "FanExaminationGate.swift: enterForExamination(fanAt: Int)",
        "FanExaminationGate.swift: enterForStep(fanAt: Int)",
        "FanExaminationGate.swift: wait(_: UInt64, fanAt: Int, within: Duration)",
        "FanControlPlane.swift: reconnect()",
        "FanModeSensing.swift: modes(ofFans: [Int])",
        "FanModeSensing.swift: readMode(ofFan: Int)",
        "FanRestoring.swift: enumeratedFanIndices()",
        "HelperComposition.swift: bindSafetyRegistries()",
        "HelperComposition.swift: bringUp()",
        "HelperComposition.swift: shutDown()",
        "HelperConnectionSession.swift: hello(payload: Data)",
        "HelperConnectionSession.swift: invalidate()",
        "HelperConnectionSessionMessages.swift: acquireLease(payload: Data)",
        "HelperConnectionSessionMessages.swift: apply(settings: Data, leaseID: String)",
        "HelperConnectionSessionMessages.swift: releaseLease(id: String)",
        "HelperConnectionSessionMessages.swift: renewLease(id: String)",
        "HelperConnectionSessionMessages.swift: snapshot()",
        "LeaseAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "LeaseAuthority.swift: activeLease()",
        "LeaseAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        "LeaseAuthority.swift: expireLapsedLeases()",
        "LeaseAuthority.swift: refuseIfThermalEmergencyActive(_: ConnectionID)",
        "LeaseAuthority.swift: releaseEveryLease()",
        "LeaseAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        // § 3's revocation since #440: it borrows the restorer it hands back through, and reaches
        // a write only through `restore(_:because:through:)`, as the two beside it do.
        "LeaseAuthority.swift: revokeEveryLease(handingBackThrough: borrowing Handback)",
        // #353's: § 5's terminal revocation, scoped to the lease it held the fan for. It
        // reaches a write only through `restore(_:because:)`, as the two beside it do.
        "LeaseAuthority.swift: revokeLease(id: UUID, forFan: Int, because: FanRestoreCause)",
        // § 5's role over the lease core (#357's review): the same two calls, as requirements
        // `LeaseAuthority` witnesses. Asking writes nothing; revoking reaches a write only
        // through the conformer's `restore(_:because:)`.
        "HeldLeaseRole.swift: hasLiveLease(id: UUID, coveringFan: Int)",
        "HeldLeaseRole.swift: revokeLease(id: UUID, forFan: Int, because: FanRestoreCause)",
        // § 5's role over the ledger (#380): the three calls it makes, as requirements
        // `ReclamationLedger` witnesses with synchronous, isolated methods. Each records or clears
        // why a fan was given up, which the snapshot reads; none reaches a restorer, a writer or
        // the plane. The latch's role carries one `get async` property, which this scan does
        // not read, and which writes nothing either.
        "ReclamationLedgerRole.swift: markReclaimed(fanAt: Int)",
        "ReclamationLedgerRole.swift: markSupervisorBlind(fanAt: Int)",
        "ReclamationLedgerRole.swift: clearReclaimed(fanAt: Int)",
        "LeaseAuthority.swift: revokeLeases(coveringFan: Int, because: FanRestoreCause)",
        "LeaseAuthorityRefusals.swift: refuseIfBlind(_: ConnectionID)",
        "LeaseAuthorityRefusals.swift: refuseIfForeignManualControl(_: ConnectionID, "
            + "wanting: Set<Int>)",
        // #270's bounds gate: a read through `FanEnvelopeReading` and a refusal. It names no
        // permit, restorer or plane, and `LeaseAuthorityAccessTests.theLeaseCoreMintsNoPermit`
        // holds that it never turns what it reads into one.
        "LeaseAuthorityRefusals.swift: refuseIfBoundsImplausible(_: ConnectionID, "
            + "wanting: Set<Int>)",
        "LeaseClock.swift: sleep(until: ContinuousClock.Instant)",
        "LeaseExpirySupervisor.swift: run(authority: LeaseAuthority, "
            + "clock: some MonotonicClock, idleInterval: Duration, log: LeaseLog)",
        // ADR 0012's liveness watchdog (#329). Neither writes to a fan or can: the watchdog
        // holds a lock-guarded stamp, a lock-guarded progress object and a
        // `ProcessTermination`, and the plane is named by none of them (the tripwire in
        // `WatchdogTripwireTests` holds that). `arm()` starts a timer, and `start(_:)` is the
        // tick source's requirement and its one conformer, with one signature. The verdict
        // itself — `tick()` and `ProcessTermination.claim(_:)` / `end(_:)` — is synchronous and
        // so is outside this population; it issues no restore, which is why the restart and the
        // reconciliation behind it exist.
        "LivenessWatchdog.swift: arm()",
        "LivenessWatchdog.swift: start(_: @escaping @Sendable () -> Void)",
        "ReadOnlyFanAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: apply(_: [FanSetting], leaseID: UUID, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        "ReadOnlyFanAuthority.swift: discoverSensorKeys()",
        "ReadOnlyFanAuthority.swift: enumeratedFanIndices()",
        // #360's: the snapshot's body, returning the mode answers beside it. Reads only.
        "ReadOnlyFanAuthority.swift: observe()",
        "ReadOnlyFanAuthority.swift: readSensors()",
        "ReadOnlyFanAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: renewLease(id: UUID, from: ConnectionID)",
        "ReadOnlyFanAuthority.swift: snapshot()",
        "ReadOnlyFanAuthority.swift: walkEveryKey()",
        "ReclamationSupervisor.swift: run(watchdog: ReclamationWatchdog<Plane>, "
            + "clock: some MonotonicClock, interval: Duration, log: SafetyLog)",
        // #353's: the command write's refusal, out of `reassert` for its complexity budget. It
        // reaches a write only through `restoreAndForget` and `finaliseRelease`, beside it here.
        "ReclamationWatchdog.swift: commandWriteFailed(fanAt: Int, heldUnder: UUID, "
            + "detail: String)",
        "ReclamationWatchdog.swift: currentRuling()",
        "ReclamationWatchdog.swift: cycle()",
        "ReclamationWatchdog.swift: cycleCouldNotSee(fanAt: Int, heldUnder: UUID, "
            + "detail: String)",
        "ReclamationWatchdog.swift: diverged(_: ReclamationDivergence, fanAt: Int, "
            + "heldUnder: UUID)",
        "ReclamationWatchdog.swift: examine(fanAt: Int, inBound: Bool)",
        "ReclamationWatchdog.swift: finaliseRelease(fanAt: Int, heldUnder: UUID, "
            + "because: FanRestoreCause)",
        "ReclamationWatchdog.swift: manualControlReleased(fanAt: Int)",
        // A6's hand-back notice: a registry transition and the ledger's clear, as the release
        // notice beside it is. It takes an index and a lease and reaches no writer.
        "ReclamationWatchdog.swift: manualControlHandedBack(fanAt: Int, under: UUID)",
        "ReclamationRegistrationRole.swift: manualControlHandedBack(fanAt: Int, under: UUID)",
        // Level 6's `apply` (ADR 0014's A6 PR-2 amendment). None takes a permit: `step` mints one
        // from the envelope it reads and hands it only to the driver, § 5's registration and
        // `GovernedFanWriter.hold(_:of:)`, all acknowledged, so a fan is written only through
        // them. `undo` reaches a write only through the driver's `handBack(fanAt:)`, and
        // `refusal` asks the lease core and writes nothing.
        "LeaseApplier.swift: apply(_: [FanSetting], leaseID: UUID, from: ConnectionID)",
        "LeaseApplier.swift: step(_: Double, toFanAt: Int, under: UUID, "
            + "engaging: inout ApplyEngagements)",
        "LeaseApplier.swift: undo(_: [Int], under: UUID)",
        "LeaseApplier.swift: refusal(for: any Error, leaseID: UUID, from: ConnectionID)",
        // The role the authority reaches level 6 through (ADR 0014's A6 PR-3 amendment): the
        // same verb, as a requirement, with no permit. Its one conformer is `LeaseApplier`'s,
        // above, and `LeaseApplyingTripwireTests` holds that it is never widened.
        "LeaseApplying.swift: apply(_: [FanSetting], leaseID: UUID, from: ConnectionID)",
        "ReclamationWatchdog.swift: reassert(fanAt: Int, heldUnder: UUID, attempt: Int, "
            + "reengaging: Bool)",
        // #381's: the re-fetch after the re-assert's first step, out of `reassert` for its
        // complexity budget. It reaches a write only through `restoreAndForget`, beside it here.
        "ReclamationWatchdog.swift: reassertStoppedAfterItsFirstStep(fanAt: Int, heldUnder: UUID)",
        "ReclamationWatchdog.swift: restoreAndForget(fanAt: Int, heldUnder: UUID)",
        // #128's two, the blocks `restoreAndForget` and `finaliseRelease` shared, lifted into
        // private methods on the same actor. `handBack(fanAt:)` takes an index and reaches a
        // write only through `EngagementDriver.handBack(fanAt:)`, acknowledged below;
        // `clearReclamationMark(fanAt:)` asks the ledger and writes nothing.
        "ReclamationWatchdog.swift: handBack(fanAt: Int)",
        "ReclamationWatchdog.swift: clearReclamationMark(fanAt: Int)",
        "SMCFanControlPlane.swift: readControlState(ofFan: Int)",
        "SMCFanControlPlane.swift: readCriticalTemperatures(_: [SMCKey])",
        "SMCFanControlPlane.swift: readEnvelope(ofFan: Int)",
        "SMCFanControlPlane.swift: readSubset(_: [SMCKey], context: String)",
        "SMCFanControlPlane.swift: reconnect()",
        "SMCReadScheduler.swift: read(keys: [String], at: SMCReadPriority)",
        "SMCReadScheduler.swift: readAll()",
        "SMCReadScheduler.swift: takeTurn(at: SMCReadPriority)",
        "SMCReadScheduler.swift: yieldTurn(at: SMCReadPriority)",
        "SignalTeardown.swift: install(stoppingSupervisorsWith: "
            + "@escaping @Sendable () async -> Void)",
        "SignalTeardown.swift: run(stoppingSupervisorsWith: @Sendable () async -> Void)",
        "SignalTeardown.swift: serve(_: [Int32], with: @escaping @Sendable () -> Void)",
        "SnapshotSensorReads.swift: read(keys: [String])",
        "SnapshotSensorReads.swift: readAll()",
        "SupervisedFanAuthority.swift: acquireLease(_: LeaseRequest, from: ConnectionID)",
        "SupervisedFanAuthority.swift: apply(_: [FanSetting], leaseID: UUID, "
            + "from: ConnectionID)",
        "SupervisedFanAuthority.swift: connectionDidInvalidate(_: ConnectionID)",
        // #269's step-12 check: one `sighting()` of the cache, on a `.built` seam only, and a
        // `Bool` back. The authority's `telemetry` is a `SightednessProving`, whose one verb reads.
        "SupervisedFanAuthority.swift: isBlind()",
        "SupervisedFanAuthority.swift: releaseLease(id: UUID, from: ConnectionID)",
        "SupervisedFanAuthority.swift: refuseIfShuttingDown(_: ConnectionID, message: String)",
        "SupervisedFanAuthority.swift: renewLease(id: UUID, from: ConnectionID)",
        "SupervisedFanAuthority.swift: snapshot()",
        "SystemPowerObserver.swift: acknowledge()",
        "SystemPowerResponder.swift: acknowledge(_: Outcome)",
        "SystemPowerResponder.swift: allowSleepAfterHandback(_: SystemPowerNotification)",
        "SystemPowerResponder.swift: handBackEveryFan(reportingTo: SleepAcknowledgement)",
        "SystemPowerResponder.swift: respond(to: SystemPowerNotification)",
        "ThermalEmergency.swift: cycle()",
        "ThermalEmergency.swift: cycleSawNothing(_: String)",
        "ThermalEmergency.swift: fire(_: CriticalTemperature, from: CriticalTemperatureReport)",
        "ThermalEmergency.swift: takeBackAnythingEngagedSinceFiring()",
        "ThermalSupervisor.swift: run(emergency: ThermalEmergency<Plane>, "
            + "clock: some MonotonicClock, interval: Duration, progress: ThermalCycleProgress, "
            + "log: SafetyLog)",
        // ADR 0014's index-taking and permit-free entries. `handBack(fanAt:)` is the driver's
        // undo, and § 5's hand-back: it takes the fan's index, never the permit, and reaches a
        // write only through `restoreToAutomatic(_:)`, whose `restoreVerbs` entry is the
        // keystone (D2). `handbackAccepted(fanAt:)` is § 3's role's mark, which writes nothing.
        // The preparation step's requirement, its conformer and the composition's call reach a
        // write only through `restoreToAutomatic(.everyFan)` (D5): no new verb and no new scope.
        "EngagementDriver.swift: handBack(fanAt: Int)",
        "EngagementDriver.swift: handbackAccepted(fanAt: Int)",
        // #406's: § 5's re-assert engages through it, so its one catch reads a refused undo's
        // cause. It takes no permit and names no writer: the engagement it runs is the closure
        // `reassert` hands it, whose step is the driver's, acknowledged above.
        "EngagementUndoRefused.swift: throwingTheCause(of: @Sendable () async throws -> Void)",
        "FanControlPlane.swift: prepareWritePath(enumerating: any FanEnumerating)",
        "SMCFanControlPlane.swift: prepareWritePath(enumerating: any FanEnumerating)",
        "HelperComposition.swift: prepareWritePath()",
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
        for key in Self.keyedCompanions.keys.sorted() {
            let carriers = bearing.filter { $0.key == key }
            #expect(
                carriers.count == 1,
                """
                \(carriers.count) declarations carry the keyed exemption `\(key)`. It is for one \
                registration verb; a second declaration with the same signature in that file \
                would travel a `UUID` beside a permit under its exemption.
                """)
        }
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
            let keyed = Self.keyedCompanions[verb.key] ?? []
            for type in verb.parameterTypes where !Self.permits.contains(type) {
                #expect(
                    Self.clampedCompanions.contains(type) || keyed.contains(type),
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
}
