import SMCCore

/// The E5/hardware seam: everything E5 needs of the firmware, and nothing else.
///
/// `FanAuthority` is the seam between the privilege boundary and the safety subsystem.
/// This is the seam on the *other* side of the safety subsystem, between it and the SMC.
/// The supervisor, the lease enforcer and startup reconciliation all talk to this; none of
/// them talks to `SMCConnection` or to `SensorProvider` directly.
///
/// ## Internal, like `ConnectionID`
///
/// Declared in `AeolusHelper` rather than in `AeolusXPC` or `SMCCore`, for the same reason
/// `ConnectionID` is: a type a client cannot name is a type a client cannot reach. E2 froze
/// the boundary at seven messages behind `FanAuthority`, and nothing here widens that — the
/// operations below are how E5 speaks to the hardware, not a new thing anyone can ask for.
///
/// ## Why not `SensorProvider`
///
/// `SensorProvider` is a general sensor abstraction whose defining operation is
/// `readAll()`. On this project's development machine `readAll()` costs 2.2 s warm and
/// enumerates 2929 keys, and [ADR 0006](../../docs/ADR/0006-single-smc-reader.md) puts the
/// helper's snapshot on the same single SMC connection. The supervisor reads a handful of
/// curated keys on a tight cycle and must never queue behind a client's snapshot, so its
/// needs are stated here as a handful of named operations — **there is no `readAll()` on
/// this protocol and there must never be one.** Making the scheduling explicit is the point
/// of a separate seam; making every failure mode injectable without hardware is the other
/// half.
///
/// The scheduling this seam made *possible* is `SMCReadScheduler`'s, per
/// [#127](https://github.com/blamechris/Aeolus/issues/127): the production conformer issues
/// every read above at `.supervisor`, which is admitted ahead of a waiting snapshot turn.
/// Naming the keys was necessary and was never sufficient — a small read still waits for a
/// big one on a connection that grants no turns.
///
/// ## The keystone
///
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md) rests every safety mechanism on
/// one principle:
///
/// > Restore-to-automatic is a mode write, and must never depend on trusted data.
///
/// `restoreToAutomatic(_:)` is therefore its own operation, taking nothing but a scope. It
/// consumes no bounds, no clamp, no sensor reading, no lease and no prior call of any kind,
/// because a terminal action that needs a successful read is not available in the one case
/// it exists for — the helper that cannot read. That property is structural here: no
/// trusted value crosses the signature, so none can be depended on.
///
/// ## What conforms
///
/// `SMCFanControlPlane` is the production conformer. Its reads are real; **its writes throw
/// and will keep throwing until E3 and E4 build a write path.** E5 is what gates those
/// epics, so modelling the write side here — while implementing none of it — is the whole
/// shape of this seam. `ScriptedControlPlane`, in the test target, is the scriptable mock
/// every other E5 mechanism is tested through.
/// The read half of the seam: what a mechanism needs to know about one fan, and how to
/// try again when it can no longer find out.
///
/// ## Why the read half is a protocol of its own
///
/// So that `ReclamationWatchdog` **cannot command a fan**. § 5's watchdog has to read
/// (mode, target read-back, actual speed, and a fresh envelope before any re-assert) and
/// has to write (re-assert, and the restore it falls back to) — but its writes must go
/// through `SafetyActorWriter`, which is what keeps § 8's ramp governor away from a
/// safety-actor write by construction rather than by rule. Handing it a whole
/// `FanControlPlane` would put `commandTarget(_:)` in its hand, and the exclusion would
/// again be a thing a future edit must remember rather than a thing the compiler refuses.
/// It holds one of these and a writer, exactly as `ThermalEmergency` holds a
/// `CriticalTemperatureSensing` and a writer, and for the same reason.
///
/// `FanControlPlane` refines this, so every conformer answers both and no separate
/// production type is needed — the split is about what a *consumer* can be given, not
/// about what the hardware offers.
///
/// The envelope read is `FanEnvelopeReading`'s since
/// [#270](https://github.com/blamechris/Aeolus/issues/270), refined here unchanged, so the lease
/// core can be handed that one verb and nothing else this seam answers.
protocol FanStateSensing: FanModeSensing, FanEnvelopeReading, SMCConnectionRecovering {

    /// Reads one fan's control state: `F<n>Md`, the `F<n>Tg` read-back, and `F<n>Ac`.
    ///
    /// All three in one subset read, because every consumer wants them together: startup
    /// reconciliation asks "is this fan in manual with nobody holding it", and the
    /// reclamation watchdog compares the target read-back against the target it last
    /// commanded — `docs/SAFETY.md` § 5's primary signal — and the actual speed against
    /// that same commanded target behind a dwell, which is § 5's secondary one.
    ///
    /// **`F<n>Ac` is here rather than on a verb of its own, and that is a scheduling
    /// decision.** A separate `readActualRPM(ofFan:)` would take a second `.supervisor`
    /// turn per fan per cycle, and every extra supervisor waiter drags a quota-forced
    /// snapshot turn along with it once every `maxConsecutiveOvertakes` — see
    /// `SMCReadScheduler` for the arithmetic, and
    /// [#134](https://github.com/blamechris/Aeolus/issues/134) for why the count of
    /// outstanding supervisor reads is the number that matters. Three keys in one turn
    /// costs ~0.5 ms; a second turn costs a scheduling decision.
    func readControlState(ofFan index: Int) async throws -> FanControlState
}

// MARK: - Recovery

/// One verb: rebuild whatever the conformer uses to reach the SMC, because reading has
/// stopped working and the connection itself is the suspect.
///
/// ## Why it is a protocol of its own
///
/// The same argument `FanModeSensing` makes, in the same direction. `FanStateSensing`
/// refines this, so every plane answers it and no separate production type is needed — but
/// the two consumers want very different amounts of authority. `ReclamationWatchdog` reads
/// fans *and* reconnects, so it holds the wider seam; `ConnectionHealth` only ever
/// reconnects, and handing a lifecycle observer a seam that can also read fan state would be
/// an authority it has no use for and that a later edit could quietly spend.
///
/// `Sendable`, because the lifecycle owner holds one across an actor boundary. Every
/// conformer already is.
protocol SMCConnectionRecovering: Sendable {

    /// Rebuilds the connection to the SMC. One attempt.
    ///
    /// `docs/SAFETY.md` § 5's escalation for persistent read failure is *"attempt a
    /// reconnect, then restore automatic and report"*, and this is the first half. A stale
    /// `io_connect_t` after wake ([#68](https://github.com/blamechris/Aeolus/issues/68)) is
    /// the motivating case: every read fails, nothing else is wrong with the machine, and
    /// the fans stay wherever a lease left them.
    ///
    /// ## It is allowed to fail, and the caller must not depend on it
    ///
    /// This is deliberately **not** a keystone verb. It is one attempt, on a path that is
    /// already failing, and the mechanism that calls it — `ReclamationWatchdog` — treats a
    /// throw here exactly as it treats a reconnect that succeeded and changed nothing: it
    /// goes on to restore and report. Anything else would make recovery from blindness
    /// depend on the machinery that has gone blind, which is the shape ADR 0007's keystone
    /// exists to refuse.
    ///
    /// ## What returning proves, which is less than it looks
    ///
    /// That the handle was rebuilt, and nothing else. No read has been issued since, so a
    /// caller that treats a clean return as "reading works again" is claiming something it
    /// has not observed — `CLAUDE.md` rule 6, one level below the fans.
    /// `SafetyLog.reclamationReconnected(fan:)` says exactly this in the line it emits, and
    /// the watchdog restores regardless.
    ///
    /// - Important: `SMCFanControlPlane` implements this against the real `SMCConnection` as
    ///   of [#168](https://github.com/blamechris/Aeolus/issues/168) — a `close()` and an
    ///   `open()` taken under an exclusive scheduler turn. It threw `.reconnectNotBuilt`
    ///   until then, and that case is gone rather than deprecated: an error meaning "no
    ///   attempt was possible" is a lie the day an attempt is.
    func reconnect() async throws
}

// MARK: - The keystone, as a role

/// The keystone verb and nothing else: a role a mechanism can be handed so that it can return
/// fans to automatic control without being able to take one off it.
///
/// ## Why it is a role of its own
///
/// `FanWriteCapabilityReporting`'s argument, made for the one write a client message may cause.
/// `docs/SAFETY.md` § 7's panic verb issues the machine-wide restore, and the type it runs in,
/// `SupervisedFanAuthority`, is where a decoded client message lands. Handing that type a whole
/// `FanControlPlane` would put `commandTarget(_:)` and `engageManualControl(of:)` one `await`
/// from the wire, which is the shape E2 froze the boundary to prevent. It is handed this and the
/// capability instead ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D5), and
/// `AuthorityRoleTripwireTests` holds its file to those two roles.
///
/// `FanControlPlane` refines this, so every plane answers it. `SafetyActorWriter` conforms with
/// the verb it already had, and that is what the composition hands § 7 — typed as this role,
/// which is what makes it restore-only; the writer's own type is not.
protocol KeystoneRestoring: Sendable {

    /// Returns fans to the system's own thermal management.
    ///
    /// The terminal action of every safety mechanism, and the only write on the plane that
    /// takes no reading, no bound and no lease. It must stay that way: see `FanControlPlane`'s
    /// documentation.
    ///
    /// `.everyFan` additionally clears the Apple Silicon force key. It resolves the fan set
    /// from knowledge the conformer already holds — never from a read issued here, because
    /// a restore that must first read cannot run while reading is what has failed.
    ///
    /// ## The contract a plane that can write keeps
    ///
    /// [ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D4, D5 and D7:
    ///
    /// - **A call supersedes every engagement that took its ticket before it**, synchronously and
    ///   before it waits for a turn, so no step writes after a restore that was requested first.
    ///   `.forExit` also seals the plane against every later step and target command. What the
    ///   restore writes is decided when it is *issued*, inside its turn (`PlaneWriteLedger`).
    /// - **One turn, no read.** The writes are encoded from what the preparation step recorded.
    /// - **The unlock reversed**: every `F<n>Md = 0` in scope, then `Ftst = 0`, each attempted
    ///   whatever the others answered; the call throws only after all of them were.
    /// - **`.fan(n)` clears the force key when no engaged fan is left after it**, and never
    ///   while another engaged fan depends on it.
    /// - **`.everyFan` writes every enumerated fan and every fan this process engaged or
    ///   restored by index**, then the key. If the bring-up enumeration failed it writes what
    ///   it can name and throws `FanControlPlaneError.fanSetUnknown` after attempting it.
    ///
    /// `PlaneWriteLedger` holds that state and `RestorePlan` the order, so every such plane
    /// keeps it by the same code.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws
}

/// The seam itself: reads, the keystone, the write verbs — and, since
/// [#103](https://github.com/blamechris/Aeolus/issues/103), whether the writes are there at
/// all.
///
/// `FanWriteCapabilityReporting` is refined rather than restated, so every plane answers
/// `writeCapability` and the lease core can be handed *only* that question. See that
/// protocol for why the answer is synchronous and why it must be asked before any read.
/// `KeystoneRestoring` is refined for the same reason, one verb wider: § 7's panic verb is
/// handed the restore and nothing that commands a fan.
protocol FanControlPlane: FanStateSensing, FanWriteCapabilityReporting, KeystoneRestoring {

    // MARK: - Reads

    /// Reads the curated critical temperature keys, as one subset read.
    ///
    /// The set is the caller's — #102 curates it in code, per family, never from
    /// configuration — so it crosses as a parameter rather than being fixed here.
    ///
    /// - Throws: `FanControlPlaneError.criticalTelemetryUnavailable` when **no** requested
    ///   key produced a usable reading, including when the requested set is empty. A
    ///   supervisor that cannot see any temperature is blind, and blindness must not arrive
    ///   as a successful report of nothing — see `CriticalTemperatureReport`.
    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport

    // MARK: - The keystone

    // `restoreToAutomatic(_:)` is `KeystoneRestoring`'s requirement, refined above rather than
    // restated here: one declaration, so the plane's keystone and the role § 7 is handed cannot
    // come to differ.

    // MARK: - Manual control

    /// An engagement of fan `index` begins: the plane takes its ticket, the restore epoch now, and
    /// admits the engagement's first step only if no restore is requested before it
    /// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 amendment).
    ///
    /// Synchronous, index-only and write-free, so `EngagementDriver` takes it with no suspension
    /// before the entitlement, and its retry takes a fresh one; nothing else calls it, which
    /// `EngagementTicketTripwireTests` holds. A plane that can write forwards it to its
    /// `PlaneWriteLedger`, and one that cannot does nothing. Every conformer states it: there is no
    /// default. It takes no permit and is not `async`, so it reaches no write and is outside
    /// `WriteVerbAllowlistTests`' population by that suite's own rules.
    func beginEngagement(fanAt index: Int)

    /// Takes one fan off the system's thermal management: `F<n>Md`, plus whatever unlock
    /// the platform needs. The opposite direction to `restoreToAutomatic(_:)`, and
    /// deliberately not the same operation — this one is allowed to fail and be refused,
    /// where the restore verb is the one that has to work.
    ///
    /// It takes a `CommandableFan` rather than an index, so that a fan whose declared
    /// bounds the plausibility gate refused cannot be taken off automatic control at all.
    /// That is `docs/SAFETY.md` §2's closing rule — *"the only action such a fan is subject
    /// to is the bounds-free mode verb, restore-to-automatic"* — made structural. Engaging
    /// such a fan is the worst reachable state: off Apple's management, and holding a speed
    /// Aeolus may never lawfully command, because there is no envelope to clamp one into.
    ///
    /// ## One step, in one turn
    ///
    /// [ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D2, D3 and D7. The unlock's
    /// sequence is the conformer's — which keys, which values, what a refusal code means,
    /// whether the force key is needed — and its cadence is `EngagementDriver`'s. Each
    /// call performs one step inside one `.supervisor` turn (a fresh key info, the write, and
    /// its read-back) and returns `.engaged` or `.awaitingYield`; every refusal is a throw.
    /// Nothing calls this but the driver, which asks the entitlement around every step and
    /// undoes on any throw. The parameter list is still ADR 0008's: one permit and nothing
    /// beside it, so the fan whose lease the driver checks is the fan written.
    ///
    /// A step under a restore epoch older than the current one throws
    /// `FanControlPlaneError.superseded` and writes nothing. One that finds the epoch moved after
    /// its mode write, before the force key's, throws `.supersededAfterWrite`.
    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep

    /// Commands a target speed, `F<n>Tg`.
    ///
    /// The parameter carries both the speed and the fan, because they are one fact. See
    /// `AuthorisedFanTarget` for exactly what possessing one proves and — as importantly —
    /// what it does not.
    ///
    /// There is deliberately **no `ofFan:` parameter**. An index passed beside the target
    /// is an index that can disagree with the bounds the target was clamped into, and the
    /// first version of this signature had exactly that shape: it took a `FanTargetRPM`
    /// plus a separate index, so a target clamped through fan 0's envelope could be
    /// commanded to fan 1 whose declared maximum was lower. Removing the parameter is what
    /// makes the mismatch unrepresentable rather than merely discouraged.
    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget

    // MARK: - Bring-up

    /// The write path's preparation step, run once by `HelperComposition.bringUp()` between
    /// binding the safety registries and reconciliation
    /// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D5).
    ///
    /// It enumerates the fans through `fans` — the composition's own enumeration, the one
    /// reconciliation and `acquireLease` use, because a plane holds no provider of its own —
    /// records the restore keys' types and whether the force key exists, reads the key if it
    /// does, and issues `restoreToAutomatic(.everyFan)` once if it reads set, is unknown, or
    /// will not read. That covers a helper that died holding the key with every fan already
    /// back in automatic, which reconciliation's per-fan pass cannot see.
    ///
    /// It never throws and never blocks serving: what it found and did is returned for the
    /// composition to log. A plane that cannot write does nothing at all — no enumeration, no
    /// read, no write — and returns `nil`. It reaches a write only through
    /// `restoreToAutomatic(_:)`, so it is no new verb.
    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation?
}

// MARK: - Scope

/// Which fans a restore covers.
enum FanRestoreScope: Sendable, Hashable {
    /// One fan.
    case fan(Int)
    /// Every fan the bring-up enumeration found and every fan this process engaged or restored
    /// by index, plus the Apple Silicon force key (ADR 0014 D5). `SAFETY.md` §7's panic verb.
    case everyFan
    /// The orderly exit's restore: everything `.everyFan` writes, and from the moment it is
    /// requested the plane admits no forward write for the rest of the process — no engagement
    /// step and no target command — while every restore is still issued (ADR 0014's #410
    /// amendment). `SignalTeardown`'s two keystones are the only callers, and nothing unseals.
    ///
    /// Its name deliberately does not contain the other machine-wide scope's, so a substring scan
    /// for one cannot count the other.
    case forExit
}
