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
// The graph this file used to build inline is now `HelperComposition`. What is left here is
// the *lifecycle*: resolve who to obey, build the graph, bring it up, advertise the service,
// and never return. Startup reconciliation (#164), sleep/wake (#167) and the orderly signal
// handlers (#166) each added a step to that bring-up and nothing to this file —
// `HelperComposition.bringUp()` installs the signal handlers last; connection health (#168)
// goes the same way — one step in the composition's bring-up, and nothing to the listener,
// the admission policy, the handshake gate, or the contract.
//
// The restart policy (#165) is the exception, and it touches no Swift at all: launchd is
// told to restart this process whenever it exits non-zero, which makes the exit code a
// contract this file keeps now that #166 has given it an orderly teardown to exit from.

/// The helper's entry point: resolve who this daemon will obey, bring the safety subsystem
/// up, stand up the listener, and wait.
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
/// What changed in #163 is that the refusal is no longer a literal in the type serving
/// clients. `SMCFanControlPlane` answers `FanWriteCapability.notBuilt`, `LeaseAuthority`
/// reads that at the top of every grant, and the mechanisms behind it — the lease table,
/// both teardown paths, § 3 and § 5 — are running rather than merely constructed.
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

        let helper = HelperComposition.production(log: log)

        let delegate = HelperListenerDelegate(
            authorisation: authorisation,
            authority: helper.authority,
            helperBuild: build,
            log: log
        )

        let listener = NSXPCListener(machServiceName: AeolusXPCService.machServiceName)
        // NSXPCListener holds its delegate weakly. Nothing else here holds it strongly, so
        // a deallocated `delegate` means `listener(_:shouldAcceptNewConnection:)` is never
        // called and **every** connection is accepted with nothing to apply the
        // code-signing requirement or set the exported object — the refuse-all path's own
        // failure state, reached by accident. `AnonymousListenerHarness` holds its delegate
        // explicitly for this reason and says so.
        //
        // The same rule is why the graph and the delegate are built *here* rather than
        // inside the bring-up task below: `main()` is the only frame in this process that
        // never returns, so it is the only place a weakly-held reference can be parked.
        listener.delegate = delegate

        bringUp(helper, advertising: listener, log: log)

        // A deliberately unbalanced +1 on each object, which is what makes the retention a
        // **guarantee** rather than an inference about codegen. Swift does not promise a
        // local outlives its lexical scope: the optimiser may end a variable's lifetime
        // after its last use, and `delegate`'s last use is the assignment above (#92).
        //
        // `withExtendedLifetime` cannot say this here, and the first draft of #92 was
        // wrong to use it. Its whole mechanism is `defer { _fixLifetime(x) }; body()`, it
        // is `@inlinable`, and `dispatchMain()` returns `Never` — so after inlining the
        // `defer` is unreachable, no `fix_lifetime` marker is emitted, and the emitted SIL
        // for `withExtendedLifetime(d) { dispatchMain() }` is byte-for-byte identical to a
        // bare `dispatchMain()`. It reads like a barrier and is not one.
        //
        // A retain is not elidable, because there is nothing for the optimiser to prove:
        // the reference count is raised and never lowered. The process never returns, so
        // the +1 is the honest statement of a process-lifetime object rather than a leak —
        // `main()` is the only frame here that outlives every connection, and these are the
        // objects that must outlive it too.
        _ = Unmanaged.passRetained(delegate)
        _ = Unmanaged.passRetained(listener)

        // `helper` is a `struct`, so there is no object to retain — `Unmanaged` takes a
        // class. It is parked in process-lifetime storage instead: a store to a `static`
        // is an observable side effect and a real strong reference to every mechanism the
        // composition holds. That matters more than it looks: all three supervisors run
        // their loop under `Task.detached { [weak self] … }`, so this value is their only
        // strong holder, and a composition released here is a safety subsystem released
        // with it. `authorisation` needs no separate hold — it is an `enum`, and the
        // `ConnectionAdmission` it resolved to is stored on the delegate above.
        //
        // `HelperCompositionTests.theProcessLifetimeObjectsAreRetainedBeforeDispatchMain`
        // is the tripwire on all three lines.
        processLifetimeComposition = helper

        // Never returns. The listener runs on libdispatch, so the main thread's only job
        // from here is to not exit.
        dispatchMain()
    }

    /// Holds the composition for the life of the process. See `main()`.
    ///
    /// `nonisolated(unsafe)` because it is written exactly once, on the main thread, before
    /// `dispatchMain()` is called and therefore before any connection exists to read it —
    /// and it is never read at all. The alternative shapes are worse: a `let` cannot be
    /// assigned after the graph is built, and a lock would suggest contention that the
    /// write-once-then-never ordering rules out.
    nonisolated(unsafe) private static var processLifetimeComposition:
        HelperComposition<SMCFanControlPlane>?

    /// Brings the safety subsystem up, then advertises the Mach service — in that order,
    /// and never the other one.
    ///
    /// `listener.resume()` is the **last statement**, because an advertised Mach service is
    /// a client that can acquire a lease over a fan whose reconciliation restore is still in
    /// flight (#103, decision A1). Everything that has to be true first is
    /// `HelperComposition.bringUp()`'s: the safety registries bound to the restorer, startup
    /// reconciliation run over every enumerated fan, and all three supervisors running.
    ///
    /// `HelperCompositionTests.theServiceIsAdvertisedOnlyAfterBringUp` asserts the ordering
    /// at the source. It has to: this function is reached once, in a process that never
    /// returns, so there is nothing to observe it from at runtime — the same reason the rest
    /// of that suite exists.
    ///
    /// The "listening" line is logged immediately *before* the resume rather than after it,
    /// so that the resume keeps the last-statement position the tripwire depends on. The gap
    /// is one statement; the alternative is a rule enforced by nothing.
    ///
    /// ## Why it blocks rather than awaits
    ///
    /// `main()` is synchronous and ends in `dispatchMain()`, and `NSXPCListener` is not
    /// `Sendable`, so handing it to an unstructured `Task` is a data race the compiler
    /// refuses — correctly, and the fix is not to annotate the refusal away. The listener
    /// therefore never leaves this thread: the asynchronous half runs in a `Task` that
    /// touches only the composition, and this frame waits for it.
    ///
    /// The wait is safe here and would not be safe elsewhere. It blocks the **main thread**,
    /// which at this point is an ordinary thread with nothing scheduled on it — `dispatchMain()`
    /// has not been called and nothing in this target is `@MainActor`-isolated, so no
    /// cooperative-pool thread is held and there is no actor for the awaited work to deadlock
    /// against. A daemon that cannot bring its safety subsystem up therefore never reaches
    /// `dispatchMain()` and serves nothing at all, which is the same fail-safe direction as
    /// a bring-up that hangs: refusing to serve is safe, serving over unreconciled fans is
    /// not.
    private static func bringUp(
        _ helper: HelperComposition<SMCFanControlPlane>,
        advertising listener: NSXPCListener,
        log: HelperLog
    ) {
        let broughtUp = DispatchSemaphore(value: 0)
        Task {
            await helper.bringUp()
            broughtUp.signal()
        }
        broughtUp.wait()

        log.listening(machServiceName: AeolusXPCService.machServiceName, build: build)
        listener.resume()
    }
}
