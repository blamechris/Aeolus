import AeolusXPC
import ArgumentParser
import FanKit
import Foundation

/// What `fanctl set` writes, and how it keeps a reader from holding the hold.
///
/// ## Text
///
/// At the start, one standard-output line per fan, the lease and the way out. **Then silence on
/// standard output while holding:** a line every ten seconds is chatter for a person and noise
/// for a script, and there is no change during a hold that does not end it. One closing line
/// says why it ended and what the helper reports.
///
/// ## `--json`
///
/// NDJSON throughout (`SetJSON.swift`). `holding` after every successful heartbeat is the
/// liveness signal, and also **the line that discovers a consumer is not draining**.
///
/// ## The hold never writes, and never waits on a write
///
/// Every line is handed to a `LinePump`, which writes it on a thread of its own. Handing a line
/// over never blocks, so no reader, however slow, stopped or wedged, can keep a hold from
/// renewing its lease, noticing a signal, or reaching its deadline. A write may park for as long
/// as the kernel makes it; the hold never waits on it.
///
/// A consumer that is not draining is judged by the writer's **progress**: if the oldest line
/// handed over has not been completely written `stallBound` after it was handed over, or the
/// writer has failed, the hold ends as `outputClosed` (`hasTrouble`). A stop request (a signal,
/// the parent exiting, the deadline) is the reason the hold ends whenever there is one, and never
/// waits on the writer.
///
/// ## The ending
///
/// The lease is released and the safe state checked before any of this is written, so nothing
/// that follows can delay either. Then the closing event is handed to **standard output if that
/// stream is idle (every line handed over has been written, so it is at a line boundary),
/// otherwise to standard error, as the same line**: `deliverClosing`. Exactly one closing event
/// is attempted on exactly one stream, and standard output never receives an event glued onto a
/// fragment. Waiting for either stream is bounded by `closingBound`; a line still parked then is
/// abandoned with the process, and the process exits.
struct SetOutput: Sendable {
    let sinks: OutputSinks
    let format: HelperCommandOutput.Format
    let clock: SettleClock

    /// How long a line handed to standard output may go unfinished, counted from when it was
    /// handed over, before the hold treats the consumer as gone. Well under the heartbeat
    /// (10 s).
    static let stallBound = Duration.seconds(2)

    /// How long the ending waits, in all, for standard output to be idle and take the closing
    /// event, and then separately for standard error to take what was handed to it.
    static let closingBound = Duration.seconds(1)

    /// How long the ending sleeps between looks at a stream it is waiting for: it starts short,
    /// since a line in flight at the end of a run is usually written within microseconds, and
    /// doubles up to this.
    static let longestWaitSlice = Duration.milliseconds(100)

    // MARK: - While holding

    /// The `started` event, or the start lines. Handed over; whether they arrive is found out by
    /// `hasTrouble`.
    func started(_ hold: SetCommand.Hold, snapshot: SystemSnapshot) {
        switch format {
        case .text:
            for line in SetMessages.startLines(hold) { hand(line) }
        case .lines:
            hand(SetStartedEventJSON(at: Date(), hold: hold, snapshot: snapshot))
        case .document:
            break
        }
    }

    /// The `holding` event. Text says nothing here.
    func holding(_ hold: SetCommand.Hold, snapshot: SystemSnapshot, remaining: Duration) {
        guard format == .lines else { return }
        hand(
            SetHoldingEventJSON(
                at: Date(), hold: hold, snapshot: snapshot,
                remainingSeconds: Int(remaining.components.seconds)))
    }

    /// Whether standard output has failed, or its oldest line has gone unfinished for at least
    /// `stallBound` since it was handed over: the consumer is gone or not draining.
    func hasTrouble(at now: ContinuousClock.Instant) -> Bool {
        let status = sinks.standardOutput.status
        if status.isBroken { return true }
        guard let since = status.oldestUnfinished else { return false }
        return now - since >= Self.stallBound
    }

    /// How long until `hasTrouble` would become true for the oldest unfinished line, or `nil`
    /// when there is none. The longest the hold may sleep without looking again.
    func untilTrouble(from now: ContinuousClock.Instant) -> Duration? {
        guard let since = sinks.standardOutput.status.oldestUnfinished else { return nil }
        return max(since + Self.stallBound - now, .zero)
    }

    /// The per-fan objects for `hold`'s plans, each beside what the snapshot reports for it.
    static func fans(of hold: SetCommand.Hold, in snapshot: SystemSnapshot) -> [SetFanJSON] {
        hold.plans.map { plan in
            SetFanJSON(plan: plan, observed: snapshot.fans.first { $0.index == plan.index })
        }
    }

    private func hand(_ event: some Encodable) {
        guard let line = try? FanctlJSON.encodeLine(event) else { return }
        hand(line)
    }

    private func hand(_ line: String) {
        sinks.standardOutput.enqueue(line, at: clock.now())
    }

    // MARK: - The ending

    /// Hands the closing event to the stream that can take it whole.
    ///
    /// Standard output, if it becomes idle within `closingBound` and takes the line within what
    /// is left of it. Otherwise standard error: a stream with a line parked half-way would have
    /// the event glued to a fragment, which parses as neither, and one that has failed cannot
    /// take it at all. If the line was already half-way when the bound passed it is not written
    /// again on the same stream; the consumer sees a fragment and the event is on standard error.
    func deliverClosing(_ line: String) async {
        let deadline = clock.now() + Self.closingBound
        let out = sinks.standardOutput
        if await Self.waitUntilIdle(out, until: deadline, on: clock) {
            out.enqueue(line, at: clock.now())
            if await Self.waitUntilIdle(out, until: deadline, on: clock) { return }
        }
        sinks.standardError.enqueue(line, at: clock.now())
    }

    /// Gives standard error `closingBound` to write what it has been handed.
    func flushStandardError() async {
        _ = await Self.waitUntilIdle(
            sinks.standardError, until: clock.now() + Self.closingBound, on: clock)
    }

    /// Whether `pump` has written everything handed to it, at the latest by `deadline` on
    /// `clock`. A broken pump never is.
    static func waitUntilIdle(
        _ pump: LinePump, until deadline: ContinuousClock.Instant, on clock: SettleClock
    ) async -> Bool {
        var slice = Duration.milliseconds(1)
        while true {
            let status = pump.status
            if status.isBroken { return false }
            if status.isIdle { return true }
            let now = clock.now()
            if now >= deadline { return false }
            do {
                try await clock.sleep(min(slice, deadline - now))
            } catch {
                return false
            }
            slice = min(slice * 2, longestWaitSlice)
        }
    }
}

extension SetCommand {

    /// Writes how the run ended and leaves with its exit code.
    ///
    /// The diagnosis goes to standard error and the closing event to standard output, or, when
    /// standard output cannot take it whole, to standard error as the same line
    /// (`SetOutput.deliverClosing`). Under `--json` there is exactly one closing event, `ended`
    /// for exit 0 and `failed` for every other exit, whatever happened first, and it reaches
    /// exactly one stream: the one place a script that reads one stream never has to filter the
    /// other, and the one place a fragment cannot swallow it.
    static func emit(
        _ report: Report, as format: HelperCommandOutput.Format, output: SetOutput
    ) async throws {
        if let failure = report.failure {
            output.sinks.standardError.enqueue(failure.message, at: output.clock.now())
        }
        if let closing = closingLine(of: report, as: format) {
            await output.deliverClosing(closing)
        }
        await output.flushStandardError()
        if let failure = report.failure { throw failure.code.exitCode }
    }

    /// The one line that closes the run on a stream: the closing sentence in text, the `ended` or
    /// `failed` event under `--json`. Text says nothing more for a failure, whose diagnosis is
    /// the closing statement.
    private static func closingLine(
        of report: Report, as format: HelperCommandOutput.Format
    ) -> String? {
        switch format {
        case .text:
            return report.closingLine
        case .lines:
            if let failure = report.failure {
                return try? FanctlJSON.encodeLine(
                    HelperCommandOutput.FailureEventJSON(
                        failure: HelperCommandOutput.FailureJSON(failure), at: Date(),
                        closing: report.facts))
            }
            return try? FanctlJSON.encodeLine(
                SetEndedEventJSON(at: Date(), facts: report.facts))
        case .document:
            return nil
        }
    }
}

// MARK: - Command wiring

extension Fanctl.Set {

    /// Grammar only: nothing here connects. A malformed fan, speed or duration is exit 64 before
    /// any helper is contacted. Whether a speed fits a fan is exit 2, decided later against
    /// the helper's own report of the fan (`SetPlan`).
    func validate() throws {
        _ = try SetArguments.request(fan: fan, speed: speed, holdFor: holdFor)
    }

    /// Signals first, then one handshake, one lease, the hold, the release, one disconnect.
    ///
    /// Everything here is asserted end to end by `FanctlSetTests`, which reaches this function
    /// itself by setting `helper`, `terminal`, `clock` and `environment`.
    func run() async throws {
        let request = try SetArguments.request(fan: fan, speed: speed, holdFor: holdFor)
        let format: HelperCommandOutput.Format = json ? .lines : .text

        // Installed before anything is sent, so a Ctrl-C at any point is a request to stop and
        // not the default disposition killing a process that is about to hold a lease.
        let interrupt = HoldInterrupt()
        // Taken down last, after the closing event: SIGPIPE stays ignored until the final write,
        // so a consumer that has gone costs a line and not the exit code.
        let signals = environment.installSignals { interrupt.post($0) }
        defer { signals.cancel() }

        // Every line this run writes goes through a pump of its own, and nothing the hold does
        // waits on one. When the run is over the pumps are told to finish; a thread still parked
        // in a write is abandoned with the process.
        let startingParent = environment.parentProcessID()
        let sinks = terminal.lineSinks()
        defer {
            sinks.standardOutput.close()
            sinks.standardError.close()
        }
        let output = SetOutput(sinks: sinks, format: format, clock: clock)

        let client = helper.client()
        let session = SetCommand.Session(
            client: client, clock: clock, environment: environment, interrupt: interrupt,
            output: output, startingParent: startingParent)
        let report = await SetCommand.perform(request, in: session)
        await client.disconnect()

        try await SetCommand.emit(report, as: format, output: output)
    }
}
