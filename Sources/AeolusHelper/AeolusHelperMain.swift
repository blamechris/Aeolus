import AeolusXPC
import FanKit
import Foundation
@_spi(FanWrite) import SMCCore

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
/// On the E4 branch it serves `snapshot` from real hardware and, on macOS 14 or later, writes:
/// this is the one caller that gives the production graph a write channel —
/// `DaemonWriteChannel`, below, over the graph's own connection — so the daemon's plane holds
/// one and answers `.built`, and no test composition's does. `SMCConnection.write(_:to:)` is
/// SPI-gated, and its one caller in the helper is `DaemonWriteChannel.write`, which the plane's
/// write turns reach through one call of the channel's requirement (`SMCWriteTurns.issue`),
/// each in a scheduler write turn behind the safety subsystem.
///
/// What changed in #163 is that the refusal is no longer a literal in the type serving
/// clients. `SMCFanControlPlane` answers its `FanWriteCapability` from the channel it holds,
/// `LeaseAuthority` reads that at the top of every grant, and the mechanisms behind it — the
/// lease table, both teardown paths, § 3 and § 5 — are running rather than merely constructed.
///
/// ## Refusing every client is a running state, not a crash
///
/// When `ClientAuthorisation` cannot establish who to obey — an ad-hoc-signed helper, a
/// requirement that would not compile, a negative control that fired — the listener still
/// comes up and refuses each connection with a logged reason. Exiting instead would leave
/// launchd restarting a daemon on every connection attempt and a user with nothing in
/// `log show` to explain why Aeolus does nothing.
///
/// ## Why it is `private`
///
/// `main()` composes the daemon's graph, gives it `DaemonWriteChannel`, and runs bring-up before
/// `dispatchMain()`. Once the plane can write, that is a write. A test that could name this type
/// could run it, through `@testable import AeolusHelper`, by any spelling a name scan might miss —
/// a typealias, `.self.main()`. So the type is `private` and no other file, in this module or a
/// test's, can name it at all (ADR 0014's B1 seam amendment, fix round 2). `@main` needs no
/// access: the compiler's entry point is synthesised in this file. The build string it used to
/// hold is `HelperBuild.string`.
@main
private enum AeolusHelperMain {

    static func main() {
        let log = HelperLog()

        // Resolved once, at startup, and held: it does file I/O for the negative control
        // and must not be on a per-connection path.
        let authorisation = ClientAuthorisation.resolveForRunningProcess()

        // The one composition given a write channel: the forwarder over the graph's own
        // connection, through which the plane's write turns write and on which it answers
        // `.built`. Every other composition, every test's included, is given none
        // (`HelperComposition.production`'s default).
        //
        // Only on macOS 14 or later. A channel is a job run on the connection's executor, and
        // executor sharing (SE-0392's custom `unownedExecutor`) is runtime behaviour that begins
        // with the macOS 14 runtime; this target deploys to 13, where it is unobserved. The gate
        // narrows a capability and claims nothing: below 14 the plane holds no channel and
        // answers `.notBuilt`.
        let helper = HelperComposition.production(
            log: log,
            writeChannel: { connection in
                guard #available(macOS 14, *) else { return nil }
                return DaemonWriteChannel(over: connection)
            })

        let delegate = HelperListenerDelegate(
            authorisation: authorisation,
            authority: helper.authority,
            helperBuild: HelperBuild.string,
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
        // composition holds.
        //
        // What dies with it is not the supervisors' loops. Those run under
        // `Task.detached { [weak self] … }` but capture their collaborators — the emergency
        // latch, the watchdog, the authority, the clock, the log — *strongly*, so a released
        // supervisor object keeps looping. What the composition alone holds is the
        // machinery underneath: `powerObserver`'s registration with the power-management
        // root (§ 4 stops hearing sleep and wake), `signalTeardown`'s `DispatchSourceSignal`
        // owners (a `DispatchSourceSignal` released by ARC is cancelled, so `SIGTERM` stops
        // being served at the moment the machine is shutting down), and the `SMCConnection`
        // handle behind `plane` that every one of those loops reads through.
        // `authorisation` needs no separate hold — it is an `enum`, and the
        // `ConnectionAdmission` it resolved to is stored on the delegate above.
        //
        // `HelperCompositionTests.theProcessLifetimeObjectsAreRetainedBeforeDispatchMain`
        // is the tripwire on all three lines, and on their position before `dispatchMain()`.
        processLifetimeComposition = helper

        // Never returns. The listener runs on libdispatch, so the main thread's only job
        // from here is to not exit.
        dispatchMain()
    }

    /// Holds the composition for the life of the process. See `main()`.
    ///
    /// `@MainActor`, which is what makes this store need no unsafe claim: the `main()` of an
    /// `@main` type is main-actor-isolated, so the one write below is checked by the
    /// compiler rather than asserted past it. `nonisolated(unsafe)` was the first spelling
    /// and was wrong twice over — CLAUDE.md rule 10 does not admit an unsafe claim in this
    /// target, and `.swiftlint.yml`'s `no_unchecked_sendable_in_helper` does not match
    /// `nonisolated(unsafe)`, so it would have been an *unreviewed* claim rather than a
    /// reviewed one.
    ///
    /// The store is safe because **nothing reads it**. It exists only to pin the value for
    /// the process lifetime. The ordering argument that stood here — "before `dispatchMain()`
    /// and therefore before any connection exists" — was false: `bringUp` resumes the
    /// listener three statements earlier, so the Mach service is already advertised when
    /// this runs. If a reader is ever added, isolation stops being a formality and this
    /// declaration has to be revisited with it.
    ///
    /// A `let` is not available: it cannot be assigned after the graph is built.
    @MainActor private static var processLifetimeComposition: HelperComposition<SMCFanControlPlane>?

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
    ///
    /// **Do not inline this into `main()`.** `main()` is `@MainActor`, and this works only
    /// because this function is a nonisolated static: its `Task` inherits no actor, so the
    /// bring-up runs on the cooperative pool while the main thread waits. Written inside
    /// `main()` the `Task` would inherit the main actor, `broughtUp.wait()` would block the
    /// very thread it needs, and the daemon would deadlock before `HelperComposition.bringUp()`
    /// had armed the liveness watchdog — the one mechanism that would have noticed. (The
    /// sentence above that "nothing in this target is `@MainActor`-isolated" is about this
    /// frame, not about `main()`.)
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

        log.listening(
            machServiceName: AeolusXPCService.machServiceName, build: HelperBuild.string,
            writeCapability: helper.plane.writeCapability)
        listener.resume()
    }
}

/// The daemon's write channel: the four `SMCWriteChannel` requirements forwarded to the
/// connection, on the connection's own executor.
///
/// ADR 0014's B1 seam amendment. `SMCConnection` does not conform to `SMCWriteChannel` — a
/// conformance would let any `@testable` test write through a real connection without the SPI
/// opt-in — so the daemon needs a channel of its own, and this is it.
///
/// - **`private`, so nothing but this file can name it.** `@testable import AeolusHelper` does not
///   reach a `private` declaration, and this file is the one place in the helper, beside the
///   reachability probe, that imports the write SPI. `WriteChannelSeamTests` pins its text, its
///   access and its two mentions.
/// - **It adopts the connection's executor** (`unownedExecutor`), so a job run on it is a job run
///   on the connection's actor: `assumeIsolated` holds, nothing suspends between the job's
///   operations, and nothing else on the connection — a read through the scheduler, a discovery
///   walk's hop — runs inside one. Without the shared executor the first `assumeIsolated` traps,
///   before any member is reached.
/// - **Each member is the same-named `SMCConnection` member**, so a write still crosses the one
///   stamped `IOConnectCallStructMethod` site (ADR 0012), and this body is the helper's only use
///   of `SMCConnection.write(_:to:)` (`WritePathAbsenceTests.helperNeverCallsWrite`).
///
/// No test can construct one; its mechanism is tested on a stand-in written the same way
/// (`ExecutorSharingTests`), in debug and release.
private actor DaemonWriteChannel: SMCWriteChannel {
    private let connection: SMCConnection
    init(over connection: SMCConnection) { self.connection = connection }
    nonisolated var unownedExecutor: UnownedSerialExecutor { connection.unownedExecutor }
    var interfaceGeneration: SMCInterfaceGeneration? {
        connection.assumeIsolated { $0.interfaceGeneration }
    }
    func freshKeyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        try connection.assumeIsolated { try $0.freshKeyInfo(for: key) }
    }
    func read(_ key: SMCKey) throws -> SMCValue {
        try connection.assumeIsolated { try $0.read(key) }
    }
    func write(_ bytes: [UInt8], to key: SMCKey) throws {
        try connection.assumeIsolated { try $0.write(bytes, to: key) }
    }
}
