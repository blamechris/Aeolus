import AeolusXPC
import FanKit
import Foundation
import SMCCore

// AeolusHelper — the privileged daemon.
//
// This process is the only thing in Aeolus that writes to the SMC, and it runs as root.
// Three rules govern every line added to this target:
//
//   1. Nothing merges here without review by the orchestrating model. See CLAUDE.md.
//   2. No write path merges before the safety subsystem (E5) exists and is tested.
//   3. Every client is authenticated by its code-signing requirement before it is
//      obeyed. Being able to connect is not authorisation.
//
// The control loop lives here rather than in the app on purpose: if the curve engine ran
// in the GUI, quitting or crashing the GUI would leave the fans pinned wherever they were
// last set. The helper is always the authority on fan state.
//
// TODO(E5): Lease supervisor, thermal emergency override, sleep/wake handling via
//           IORegisterForSystemPower, reclamation watchdog, restore-on-exit paths. All of
//           it goes behind FanAuthority, replacing ReadOnlyFanAuthority. Nothing in the
//           listener, the admission policy, the handshake gate, or the contract changes.

/// The helper's entry point: resolve who this daemon will obey, stand up the listener,
/// and wait.
///
/// ## What this build can and cannot do
///
/// It serves `snapshot` from real hardware and refuses everything that would need a write.
/// `SMCConnection.write(_:to:)` is still `package`-scoped and still throws, and no write
/// selector exists anywhere in `Sources/` — the read selectors are 5, 8, and 9. **E2's
/// strongest safety property is structural: it cannot fail open into a write, because
/// there is no write to fail into.** Adding one "ready for E5" would spend that property
/// for nothing.
///
/// ## Refusing every client is a running state, not a crash
///
/// When `ClientAuthorisation` cannot establish who to obey — an ad-hoc-signed helper, a
/// requirement that would not compile, a negative control that fired — the listener still
/// comes up and refuses each connection with a logged reason. Exiting instead would leave
/// launchd restarting a daemon on every connection attempt and a user with nothing in
/// `log show` to explain why Aeolus does nothing.
@main
enum AeolusHelperMain {

    /// Advertised in `HelloReply.helperBuild`. Display-grade: never parsed to decide
    /// behaviour, because that would be a second version vocabulary competing with
    /// `helperProtocolRange`.
    static let build = "0.0.0 (E2)"

    static func main() {
        let log = HelperLog()

        // Resolved once, at startup, and held: it does file I/O for the negative control
        // and must not be on a per-connection path.
        let authorisation = ClientAuthorisation.resolveForRunningProcess()

        // One latch for the whole process. Nothing engages it in this build — no lease can
        // be granted, so no fan is ever off automatic control — but it is constructed here
        // rather than defaulted inside the authority so that the day E3's control plane and
        // `ThermalSupervisor` arrive, the snapshot and the lease core are already reading
        // the same bit as the mechanism that sets it.
        let thermalEmergency = ThermalEmergencyLatch()

        // § 5's ledger, for the same reason and on the same terms: nothing marks a fan
        // reclaimed in this build, because no fan is ever off automatic control to be taken
        // back. Constructed here so that the snapshot reads the mechanism's bit from the day
        // `ReclamationWatchdog` is started rather than a literal that has to be found and
        // rewired — which is the defect the latch's own comment records.
        let reclamation = ReclamationLedger()

        // ADR 0006's one continuous reader, and the thing that decides who gets it when
        // two things want it at once. In *this* build only one does — nothing constructs
        // `SMCFanControlPlane`, because no lease can be granted and so § 3 has no fan to
        // protect — so every turn granted below is a snapshot turn, and honestly so.
        //
        // **The hazard for whoever wires E5's lifecycle:** the supervisor's control plane
        // must be built from *this* scheduler — `SMCFanControlPlane(scheduler: scheduler)`
        // — and not from a second one. Two schedulers arbitrate nothing while looking
        // exactly like one that does: each would grant turns against a queue the other
        // cannot see, and the contention #127 exists to fix would be back with the
        // machinery for fixing it still in the build. See
        // [#103](https://github.com/blamechris/Aeolus/issues/103).
        let scheduler = SMCReadScheduler(provider: SMCSensorProvider())
        let authority = ReadOnlyFanAuthority(
            provider: scheduler.snapshotReader,
            log: log,
            thermalEmergency: thermalEmergency,
            reclamation: reclamation)
        let delegate = HelperListenerDelegate(
            authorisation: authorisation,
            authority: authority,
            helperBuild: build,
            log: log
        )

        let listener = NSXPCListener(machServiceName: AeolusXPCService.machServiceName)
        // NSXPCListener holds its delegate weakly. `delegate` is a local of a function
        // that never returns, which is what keeps it alive; a `listener.delegate = ...`
        // with a temporary on the right-hand side would deallocate it immediately and
        // every connection would be accepted with no delegate to configure it.
        listener.delegate = delegate
        listener.resume()

        log.listening(machServiceName: AeolusXPCService.machServiceName, build: build)

        // Never returns. The listener runs on libdispatch, so the main thread's only job
        // from here is to not exit.
        dispatchMain()
    }
}
