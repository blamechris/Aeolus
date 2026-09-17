import Darwin
import Dispatch
import FanKit
import Foundation
import SMCCore
import os

// smc-sampler: a maintainer measurement tool, never shipped. See
// Tools/SMCSampler/README.md for how to run it and how to read the result, and
// Tools/SMCSampler/SMCSamplerCore.swift's header note for why this target depends on
// SMCCore and FanKit — on purpose, unlike Tools/PowerObserver — but never on AeolusHelper.
//
// The pure parts — key-set resolution, the NDJSON encoder, the clock arithmetic, the
// command-line parser and the per-key outcome mapping — live in SMCSamplerCore.swift,
// where SMCSamplerTests can `@testable import` them. Everything below is the IOKit-free but
// still untestable-without-a-process wiring: the SMC connection, the tick loop, the
// heartbeat timer and the signal handling.
//
// `@main` with an `async` `main()` rather than `AeolusHelperMain`/`PowerObserverMain`'s
// `dispatchMain()` shape: this tool's core loop is itself `async` (`SensorProvider.read
// (keys:)` and `Task.sleep`), so awaiting it to completion is the natural way to let a
// bounded `--count` run return normally, the same shape `fanctl watch`'s
// `Fanctl.Watch.run()` already uses for the identical reason.

/// Writes one NDJSON line straight to the stdout file descriptor via `FileHandle`,
/// bypassing the C library's own `stdout` buffer — the same bug `PowerObserverMain.swift`
/// documents `print` having once it is a pipe or a redirected file, and the same fix.
private func writeLineDirectly(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

/// Serializes every NDJSON line onto one lock, so the sample loop and the heartbeat timer
/// — independent tasks/queues — never interleave one line into another. Identical in shape
/// to `PowerObserverMain.swift`'s `StandardOutputSink`; not shared for the reason
/// `SMCSamplerCore.swift`'s `WallClock`/`NDJSON` documentation gives for those two types.
final class StandardOutputSink: LineSink {
    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())

    func write(_ line: String) {
        lock.withLock { _ in writeLineDirectly(line) }
    }
}

/// `hw.model` via `HardwareIdentity.current()` — unlike `PowerObserverMain.swift`, this
/// target already depends on `FanKit`, so there is no reason for a second `sysctlbyname`
/// reader here.
private func hardwareModel() -> String {
    HardwareIdentity.current().modelIdentifier ?? "unknown"
}

/// The 1 Hz proof of life, both clocks. Its own queue, so a stall in the sample loop's own
/// `SensorProvider.read(keys:)` call cannot make a suspended-or-stalled process look merely
/// quiet — the same argument `PowerObserverMain.swift`'s heartbeat makes for its own queue.
private func makeHeartbeatSource(
    sink: StandardOutputSink,
    continuousStart: ContinuousClock.Instant,
    suspendingStart: SuspendingClock.Instant
) -> DispatchSourceTimer {
    let queue = DispatchQueue(label: "dev.aeolus.smc-sampler.heartbeat")
    let heartbeat = DispatchSource.makeTimerSource(queue: queue)
    heartbeat.schedule(deadline: .now(), repeating: 1.0)
    heartbeat.setEventHandler {
        let record = SamplerHeartbeatRecord(
            wallClockUTC: WallClock.iso8601UTC(),
            continuousNanoseconds: ClockNanoseconds.nanoseconds(
                from: ContinuousClock.now - continuousStart),
            suspendingNanoseconds: ClockNanoseconds.nanoseconds(
                from: SuspendingClock.now - suspendingStart))
        if let line = try? NDJSON.line(record) {
            sink.write(line)
        }
    }
    return heartbeat
}

/// `SIGINT`/`SIGTERM`/`SIGHUP`: `SIG_IGN` first, then a `DispatchSourceSignal` — the same
/// ordering `PowerObserverMain.swift`'s own `installOrderlyExit` uses, `SIGHUP` included for
/// the same unattended-capture reason.
///
/// Only cancels `task`; it does not write the `stop` line or exit itself. Earlier revisions
/// of this file did both here — snapshotting the tick count and calling `exit(0)`
/// independently of the cancelled loop's own unwind — and that produced **two** `stop`
/// lines on a real `Ctrl-C`: the loop's `Task.sleep` observed the cancellation and returned
/// normally, `main()`'s `try await task.value` therefore also returned normally and wrote
/// its own "ran to completion" `stop` line, racing this handler's independent one. There is
/// now exactly one place that writes a `stop` line — the end of `main()`, after `task.value`
/// — whether the run got there by exhausting `--count` or by being cancelled; see that
/// function for why a single code path covers both.
///
/// The signal's default disposition is restored the instant this fires, not only
/// cancelling `task`: cancellation is cooperative (`SensorProvider.read(keys:)` is not
/// itself a cancellation point mid-call, matching `Sources/fanctl/WatchCommand.swift`'s own
/// note on this), and a tick wedged inside a read with no timeout would otherwise make a
/// second `Ctrl-C` do nothing — the same two-stage convention
/// `Fanctl.Watch`'s own `installSIGINTHandler` documents for its single signal, applied
/// here to all three.
private func installOrderlyExit(cancelling task: Task<Void, Error>) -> [DispatchSourceSignal] {
    let queue = DispatchQueue(label: "dev.aeolus.smc-sampler.signals")
    return [SIGINT, SIGTERM, SIGHUP].map { number in
        _ = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler {
            task.cancel()
            signal(number, SIG_DFL)
        }
        source.resume()
        return source
    }
}

@main
struct SMCSamplerMain {

    static func main() async throws {
        let options: CommandLineOptions
        do {
            options = try CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("smc-sampler: \(error)\n".utf8))
            exit(64)  // EX_USAGE
        }

        // Line-buffered even off a terminal — see `WatchCommand.swift`'s identical call for
        // why a fully-buffered pipe would silently defeat NDJSON's "one line per tick"
        // contract for a script reading this tool's output live.
        setvbuf(stdout, nil, _IOLBF, 0)

        let sink = StandardOutputSink()
        let provider = SMCSensorProvider()
        let identity = HardwareIdentity.current()

        var fanIndices: [Int] = []
        var enumerationOutcome: FanEnumerationOutcome?
        if options.keys.isEmpty {
            // Fan enumeration failing does not make this run pointless — the critical set
            // alone may still be readable — so the outcome is reported and continued past,
            // not thrown. A genuinely unavailable SMC still surfaces: the sample loop's own
            // first `read(keys:)` call throws the same underlying error. The mapping from
            // "did it throw" to `keySource`/`fanEnumerationFailed`/`fanEnumerationFailureReason`
            // lives in `FanEnumerationOutcome.from(_:model:)`, a pure function
            // `FanEnumerationOutcomeTests` exercises directly — this `do`/`catch` only
            // supplies the `Result` that function needs.
            let enumerationResult: Result<[Int], Error>
            do {
                let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)
                enumerationResult = .success(enumeration.fanIndices)
            } catch {
                enumerationResult = .failure(error)
            }
            let outcome = FanEnumerationOutcome.from(
                enumerationResult, model: identity.modelIdentifier)
            enumerationOutcome = outcome
            fanIndices = outcome.fanIndices

            // Reported twice, deliberately: stderr for a maintainer watching the terminal
            // live, and `fanEnumerationFailureReason` on the `start` line itself for the
            // common invocation that redirects only stdout to a file — see that field's
            // documentation for why stderr alone leaves the capture indistinguishable from
            // a fanless machine.
            if let reason = outcome.fanEnumerationFailureReason {
                FileHandle.standardError.write(
                    Data(
                        "smc-sampler: fan enumeration failed, continuing with 0 fans: \(reason)\n"
                            .utf8))
            }
        }
        // `enumerationOutcome` stays `nil` when `options.keys` was non-empty — no
        // enumeration was attempted, and `SamplerStartRecord.startRecord(outcome:...)`
        // below maps a `nil` outcome to `keySource: "custom"` the same way this branch used
        // to wire it inline.

        let keys = MeasurementKeySet.resolvedKeys(
            custom: options.keys, model: identity.modelIdentifier, fanIndices: fanIndices)

        guard !keys.isEmpty else {
            FileHandle.standardError.write(
                Data(
                    """
                    smc-sampler: no keys to sample — this machine has no measured critical \
                    sensor set and no fans were enumerated. Pass \
                    --keys=<comma-separated keys> to select some.

                    """.utf8))
            exit(1)
        }

        // `FanEnumerationOutcome`'s own documentation explains why that type exists;
        // `startRecord(outcome:...)`'s documentation explains why `main()` calls it here
        // rather than re-deriving `keySource`/`fanEnumerationFailed`/
        // `fanEnumerationFailureReason` itself — that re-derivation was the exact
        // untested passthrough round-3 delta review of #248 found.
        let startRecord = SamplerStartRecord.startRecord(
            outcome: enumerationOutcome,
            hostname: ProcessInfo.processInfo.hostName,
            hwModel: hardwareModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            uid: getuid(),
            pid: getpid(),
            intervalSeconds: options.intervalSeconds,
            keys: keys)
        sink.write(try NDJSON.line(startRecord))

        let continuousStart = ContinuousClock.now
        let suspendingStart = SuspendingClock.now
        let tickState = TickState()

        let heartbeat = makeHeartbeatSource(
            sink: sink, continuousStart: continuousStart, suspendingStart: suspendingStart)
        heartbeat.resume()

        let task = Task {
            try await runSampleLoop(
                provider: provider, keys: keys, options: options, sink: sink,
                continuousStart: continuousStart, suspendingStart: suspendingStart,
                tickState: tickState)
        }

        let signalSources = installOrderlyExit(cancelling: task)

        // A deliberate, unbalanced +1 on the heartbeat and each signal source — see
        // `PowerObserverMain.swift`'s identical retain for the full argument (a local's
        // lifetime is not guaranteed to extend to the end of its lexical scope, and a
        // released `DispatchSourceSignal`/timer is a cancelled one). This function does
        // return normally on a bounded `--count` run, unlike `PowerObserverMain`'s
        // `dispatchMain()`, but the retain still matters for every tick before that: nothing
        // else keeps these two alive across the `await` below.
        for source in signalSources {
            _ = Unmanaged.passRetained(source)
        }
        _ = Unmanaged.passRetained(heartbeat)

        try await task.value

        // Reached whether the run got here by exhausting `--count` or by a signal
        // cancelling `task` — see `installOrderlyExit`'s documentation for why a signal no
        // longer writes its own, independent `stop` line. One code path, one `stop` line,
        // whatever ended the run.
        let finalTicks = await tickState.tickCount()
        let stopRecord = SamplerStopRecord(
            totalTicks: finalTicks,
            finalContinuousNanoseconds: ClockNanoseconds.nanoseconds(
                from: ContinuousClock.now - continuousStart),
            finalSuspendingNanoseconds: ClockNanoseconds.nanoseconds(
                from: SuspendingClock.now - suspendingStart))
        sink.write(try NDJSON.line(stopRecord))
        heartbeat.cancel()
        for source in signalSources { source.cancel() }
    }
}
