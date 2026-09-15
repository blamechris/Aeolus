import Foundation
import IOKit
import IOKit.pwr_mgt
import os

// power-observer: a maintainer measurement tool, never shipped.
//
// It exists to answer docs/SAFETY.md row 14 — how many `willSleep`/`didWake` pairs a real
// lid close delivers to a process holding an `IORegisterForSystemPower` port — and to do so
// without filtering anything the way
// `Sources/AeolusHelper/Lifecycle/SystemPowerObserver.swift` deliberately does. See
// `Tools/PowerObserver/README.md` for how to run it and how to read the result. This file
// depends on nothing in this package: only Foundation and IOKit, so it cannot become a
// second way to reach the SMC or the helper by accident.
//
// The pure parts — the NDJSON encoder, the message-name table, the latency arithmetic and
// the per-type counters — live in `PowerObserverCore.swift`, where `PowerObserverTests` can
// `@testable import` them. Everything below is the IOKit/signal wiring no automated test can
// exercise, mirroring the shape (and the reasoning in its comments)
// `Sources/AeolusHelper/Lifecycle/SystemPowerObserver.swift` already uses for the same call.
//
// An `@main` type rather than a `main.swift` script, for the same reason
// `AeolusHelperMain.swift` is one: `static func main()` is `@MainActor`-isolated, so what
// would otherwise be top-level global mutable state — the notification port, the retained
// registration, the signal sources — is instead state a single isolation domain owns, which
// is what Swift 6's strict concurrency checking asks a daemon-shaped process for.

/// `hw.model` via `sysctlbyname`, read directly rather than through `FanKit.HardwareIdentity`
/// — this target imports nothing else in the package. See that type's doc comment for why a
/// two-call `sysctlbyname` (size probe, then read) is the correct shape.
func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    let bytes = buffer.map { UInt8(bitPattern: $0) }
    let nullTerminatorIndex = bytes.firstIndex(of: 0) ?? bytes.endIndex
    return String(decoding: bytes[..<nullTerminatorIndex], as: UTF8.self)
}

/// `launchctl print system/com.blamechris.Aeolus.Helper`'s exit status, recorded and never
/// acted on. The label is written out rather than imported from
/// `AeolusXPCService.machServiceName` because this target depends on nothing in this
/// package — see this file's header note.
func helperIsLoaded() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "system/com.blamechris.Aeolus.Helper"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

/// Writes one NDJSON line straight to the stdout file descriptor via `FileHandle`, bypassing
/// the C library's own `stdout` buffer that `print` goes through.
///
/// Mixing the two was a real bug the smoke test in this tool's PR caught: `print`'s buffer
/// is fully buffered rather than line-buffered once stdout is a pipe or a redirected file —
/// which is every real use of this tool — so a `start` line written with `print` sat in that
/// buffer while every later heartbeat, written with `FileHandle.write`, went straight through
/// and appeared first. A reader piping this tool's output live would have seen nothing until
/// the process exited and flushed. Every line, `start` included, goes out this one way now.
private func writeLineDirectly(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

/// Serializes every NDJSON line onto one lock, so the heartbeat timer and the power
/// notification callback — two independent dispatch queues — never interleave a write.
///
/// This is a lock, not an actor. An actor's `write` would be `async`, and the whole point
/// of writing the event line on the callback frame (see
/// `PowerObserverRegistration.received(messageType:argument:)`) is that nothing between
/// the acknowledgement and the write goes through the scheduler: a `Task` that has not yet
/// been given a scheduling quantum cannot write anything before this process is suspended
/// for sleep. `OSAllocatedUnfairLock` gives every caller a synchronous, mutually exclusive
/// `write` instead, at the cost of the caller's own thread blocking for the — always short
/// — duration of one `FileHandle.write`.
final class StandardOutputSink: Sendable {
    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())

    func write(_ line: String) {
        lock.withLock { _ in writeLineDirectly(line) }
    }
}

/// What the `@convention(c)` callback needs, retained for the life of the process — the
/// same lifetime argument `SystemPowerRegistration` makes: a daemon-shaped tool with no
/// return path has no teardown branch for a test to reach, and this one never exits except
/// through the signal handler `PowerObserverMain` installs.
final class PowerObserverRegistration: Sendable {
    private let rootPort = OSAllocatedUnfairLock<io_connect_t>(initialState: 0)
    private let counters: EventCounters
    private let sink: StandardOutputSink

    init(counters: EventCounters, sink: StandardOutputSink) {
        self.counters = counters
        self.sink = sink
    }

    func adopt(rootPort port: io_connect_t) {
        rootPort.withLock { $0 = port }
    }

    /// Translates and reports every message IOKit sends — never filtered, unlike
    /// `SystemPowerRegistration.received(messageType:argument:)`, which this mirrors in
    /// shape and deliberately not in scope.
    func received(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let receiptNanoseconds = DispatchTime.now().uptimeNanoseconds
        let token = Int(bitPattern: argument)
        let port = rootPort.withLock { $0 }
        let name = PowerMessageName.name(for: messageType)

        // Only these two are questions IOKit is waiting on an answer to. Every other
        // message needs no acknowledgement at all — see `PowerMessage`'s per-case comments
        // — and this tool must never call `IOCancelPowerChange` or delay either answer.
        let needsAcknowledgement =
            messageType == PowerMessage.canSystemSleep
            || messageType == PowerMessage.systemWillSleep

        var ackLatencyMicroseconds: Int?
        if needsAcknowledgement {
            IOAllowPowerChange(port, token)
            let ackNanoseconds = DispatchTime.now().uptimeNanoseconds
            ackLatencyMicroseconds = PowerLatency.microseconds(
                fromNanoseconds: receiptNanoseconds, toNanoseconds: ackNanoseconds)
        }

        let record = PowerEventRecord(
            messageTypeDecimal: messageType,
            messageTypeHex: String(format: "0x%08X", messageType),
            name: name,
            argument: token,
            monotonicNanoseconds: receiptNanoseconds,
            wallClockUTC: WallClock.iso8601UTC(),
            ackLatencyMicroseconds: ackLatencyMicroseconds,
            uid: getuid(),
            pid: getpid())

        // Written on this callback frame, after the acknowledgement above and never
        // before it — encoding and writing are both synchronous and cost microseconds, so
        // doing them here, rather than handing the record to a `Task`, is what makes the
        // `willSleep` line survive a process suspension that a detached `Task`'s first
        // scheduling quantum might not win the race against. `sink.write` takes a lock
        // rather than `await`ing an actor for exactly this reason: a task that has not yet
        // run cannot write anything before this process is frozen for sleep. This is the
        // one place in this file that deliberately does *not* mirror
        // `SystemPowerObserver.swift`'s "write nothing on this frame" rule — that rule is
        // right for the helper, whose handler runs safety-critical work no callback frame
        // should carry; this tool's handler does nothing but serialize the message it just
        // received, so carrying it costs nothing else waiting behind it.
        if let line = try? NDJSON.line(record) {
            sink.write(line)
        }

        // The only route from a `@convention(c)` callback to the `async` counters. Its
        // body does the one `await` the actor needs and writes nothing — see above.
        Task {
            await counters.increment(name)
        }
    }
}

/// The `@convention(c)` trampoline. It cannot capture, so everything it needs arrives in
/// `context` — see `PowerObserverRegistration` for why that object is safe to touch here.
private let powerObserverCallback: IOServiceInterestCallback = { context, _, message, argument in
    guard let context else { return }
    Unmanaged<PowerObserverRegistration>.fromOpaque(context)
        .takeUnretainedValue()
        .received(messageType: message, argument: argument)
}

/// The 1 Hz proof of life. Its own queue, so a delivery backlog on the power-notification
/// queue cannot make a suspended process look merely quiet.
private func makeHeartbeatSource(sink: StandardOutputSink) -> DispatchSourceTimer {
    let queue = DispatchQueue(label: "dev.aeolus.power-observer.heartbeat")
    let heartbeat = DispatchSource.makeTimerSource(queue: queue)
    heartbeat.schedule(deadline: .now(), repeating: 1.0)
    heartbeat.setEventHandler {
        let record = PowerHeartbeatRecord(
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            wallClockUTC: WallClock.iso8601UTC())
        // Written on this timer frame, synchronously, for the same reason the event
        // callback now is: `sink.write` needs no `await`, so there is no `Task` here to
        // race the process's own suspension for sleep.
        if let line = try? NDJSON.line(record) {
            sink.write(line)
        }
    }
    return heartbeat
}

/// `SIGINT`/`SIGTERM`/`SIGHUP`: `SIG_IGN` first so the kernel's default disposition
/// (terminate immediately) never races the `DispatchSourceSignal` this installs — the
/// same ordering `Sources/AeolusHelper/Lifecycle/SignalTeardown.swift`'s
/// `DispatchSignalSources` uses and explains. `SIGHUP` is in this set for a reason that
/// does not apply to the helper: an attended capture across a real lid close runs for
/// minutes in a foreground terminal, and a dropped terminal (an SSH disconnect, a closed
/// Terminal.app window) sends `SIGHUP` to every process in the session. Left at its
/// default disposition, that kills this tool with no `stop` line and no final counts —
/// exactly the data loss row 14's capture cannot afford. Returns the sources, which the
/// caller must hold: one released by ARC is cancelled, and a signal nobody serves fails
/// silently.
private func installOrderlyExit(
    counters: EventCounters, sink: StandardOutputSink
) -> [DispatchSourceSignal] {
    let queue = DispatchQueue(label: "dev.aeolus.power-observer.signals")
    let stopAndExit: @Sendable () -> Void = {
        Task {
            // Still a `Task`: `counters.snapshot()` is the one `await` here, over the
            // actor. `sink.write` itself needs none — see `StandardOutputSink`.
            let finalCounts = await counters.snapshot()
            if let line = try? NDJSON.line(PowerStopRecord(counts: finalCounts)) {
                sink.write(line)
            }
            exit(0)
        }
    }

    return [SIGINT, SIGTERM, SIGHUP].map { number in
        _ = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler(handler: stopAndExit)
        source.resume()
        return source
    }
}

@main
struct PowerObserverMain {

    static func main() throws {
        let counters = EventCounters()
        let sink = StandardOutputSink()

        let startRecord = PowerStartRecord(
            hostname: ProcessInfo.processInfo.hostName,
            hwModel: hardwareModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            uid: getuid(),
            pid: getpid(),
            helperLoaded: helperIsLoaded())
        // Through the sink, not `writeLineDirectly` directly, so every line in this
        // process's stdout — start, event, heartbeat, stop — goes out the one locked path.
        // Nothing else is running yet to race this one, but that stops being true the
        // moment the queues below are started.
        sink.write(try NDJSON.line(startRecord))

        let registration = PowerObserverRegistration(counters: counters, sink: sink)
        let context = Unmanaged.passRetained(registration).toOpaque()

        var notificationPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        let connection = IORegisterForSystemPower(
            context, &notificationPort, powerObserverCallback, &notifier)

        guard connection != MACH_PORT_NULL, let notificationPort else {
            _ = Unmanaged<PowerObserverRegistration>.fromOpaque(context).takeRetainedValue()
            FileHandle.standardError.write(
                Data("power-observer: IORegisterForSystemPower refused registration\n".utf8))
            exit(1)
        }

        registration.adopt(rootPort: connection)

        let powerQueue = DispatchQueue(label: "dev.aeolus.power-observer.system-power")
        IONotificationPortSetDispatchQueue(notificationPort, powerQueue)

        let heartbeat = makeHeartbeatSource(sink: sink)
        heartbeat.resume()

        let signalSources = installOrderlyExit(counters: counters, sink: sink)

        // A deliberately unbalanced +1 on `heartbeat` and each signal source — the same
        // reasoning `AeolusHelperMain.swift`'s `main()` gives for `delegate` and
        // `listener`. Swift does not promise a local outlives its lexical scope: the
        // optimiser may end a variable's lifetime after its last use, which for
        // `heartbeat` is `heartbeat.resume()` two statements above and for each element of
        // `signalSources` is the `map` that built the array. A released `DispatchSourceSignal`
        // is cancelled, so `SIGINT`/`SIGTERM` would stop being served, silently, at
        // whatever point ARC decided the array's last use had passed — and a released
        // `heartbeat` timer stops proving the process is alive.
        //
        // `withExtendedLifetime` cannot say this: its whole mechanism is
        // `defer { _fixLifetime(x) }; body()`, it is `@inlinable`, and `dispatchMain()`
        // returns `Never` — so after inlining, the `defer` is unreachable, no
        // `fix_lifetime` marker is emitted, and `withExtendedLifetime(x) { dispatchMain() }`
        // compiles to a bare `dispatchMain()`. A retain is not elidable, because there is
        // nothing for the optimiser to prove: the reference count is raised and never
        // lowered, and the process never returns to lower it.
        for source in signalSources {
            _ = Unmanaged.passRetained(source)
        }
        _ = Unmanaged.passRetained(heartbeat)
        dispatchMain()
    }
}
