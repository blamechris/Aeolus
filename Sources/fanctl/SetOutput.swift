import AeolusXPC
import ArgumentParser
import FanKit
import Foundation

/// What `fanctl set` writes while it holds, and how a write that did not arrive ends the hold.
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
/// liveness signal, and also **the write that discovers a consumer has gone**: a line to a pipe
/// whose reader has exited fails, and a failed write to standard output is one of the ways a
/// hold ends (`outputClosed`). In text there is nothing written while holding, so a closed
/// standard output is found by the parent check and by `--for`, both of which bound it.
///
/// Every write goes through `Terminal.deliver`, which is `write(2)` and says whether the line
/// arrived. A `false` is returned to the loop, which ends the hold; the process never crashes
/// on a closed pipe.
///
/// **No write may park the hold.** The terminal `set` writes to is a *bounded* one
/// (`Terminal.bounded(stopping:)`): a line is written in chunks the pipe has promised room for,
/// the wait between them is short, a stop request (a signal, the parent exiting, the deadline)
/// ends it, and a reader that has not made room within `Terminal.writeBound` is treated as gone.
/// A stalled consumer therefore costs the lease one late renewal and the hold an `outputClosed`
/// ending, never a process that cannot be stopped (`FileDescriptorWriter`).
struct SetOutput: Sendable {
    let terminal: Terminal
    let format: HelperCommandOutput.Format

    /// The same output, whose writes give up when `stop` says so.
    func stopping(when stop: @escaping @Sendable () -> Bool) -> SetOutput {
        SetOutput(terminal: terminal.bounded(stopping: stop), format: format)
    }

    /// The `started` event, or the start lines. `false` if standard output did not take them.
    func started(_ hold: SetCommand.Hold, snapshot: SystemSnapshot) -> Bool {
        switch format {
        case .text:
            // Every line is attempted: the first to fail does not excuse the rest from being
            // tried, and the answer is that all of them arrived.
            return SetMessages.startLines(hold).map { terminal.deliver($0) }.allSatisfy { $0 }
        case .lines:
            return write(SetStartedEventJSON(at: Date(), hold: hold, snapshot: snapshot))
        case .document:
            return true
        }
    }

    /// The `holding` event. Text says nothing here.
    func holding(_ hold: SetCommand.Hold, snapshot: SystemSnapshot, remaining: Duration) -> Bool {
        guard format == .lines else { return true }
        return write(
            SetHoldingEventJSON(
                at: Date(), hold: hold, snapshot: snapshot,
                remainingSeconds: Int(remaining.components.seconds)))
    }

    /// The per-fan objects for `hold`'s plans, each beside what the snapshot reports for it.
    static func fans(of hold: SetCommand.Hold, in snapshot: SystemSnapshot) -> [SetFanJSON] {
        hold.plans.map { plan in
            SetFanJSON(plan: plan, observed: snapshot.fans.first { $0.index == plan.index })
        }
    }

    private func write(_ event: some Encodable) -> Bool {
        guard let line = try? FanctlJSON.encodeLine(event) else { return false }
        return terminal.deliver(line)
    }
}

extension SetCommand {

    /// Writes how the run ended and leaves with its exit code.
    ///
    /// The result goes to standard output and the diagnosis to standard error, so a script that
    /// reads one never has to filter the other. Under `--json` there is exactly one closing
    /// event, `ended` for exit 0 and `failed` for every other exit, whatever happened first.
    ///
    /// **A closed standard output cannot be told anything.** When that is why the hold ended, the
    /// closing line goes to standard error as well, because it is the only stream left that
    /// anyone can read.
    static func emit(
        _ report: Report, as format: HelperCommandOutput.Format, on terminal: Terminal
    ) throws {
        if let failure = report.failure {
            try HelperCommandOutput.fail(failure, as: format, on: terminal, closing: report.facts)
        }
        let outputClosed = report.endedBecause == Ending.outputClosed.endedBecause
        switch format {
        case .text:
            guard let line = report.closingLine else { return }
            if outputClosed { terminal.warn(line) } else { terminal.say(line) }
        case .lines:
            try HelperCommandOutput.emit(
                SetEndedEventJSON(at: Date(), facts: report.facts), as: format, on: terminal)
            if outputClosed, let line = report.closingLine { terminal.warn(line) }
        case .document:
            return
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

        // Every write `set` makes is bounded, outside the hold as well as in it: the closing line
        // and the diagnosis come after the lease is released, and a process that cannot be
        // stopped while it waits on them is still a process that cannot be stopped. What stops a
        // wait is what stops the hold: a signal, or the parent having gone.
        let startingParent = environment.parentProcessID()
        let watch = SetCommand.StopWatch(
            interrupt: interrupt, environment: environment, clock: clock,
            startingParent: startingParent, deadline: nil)
        let patient = terminal.bounded(stopping: { watch.reason != nil })

        let client = helper.client()
        let session = SetCommand.Session(
            client: client, clock: clock, environment: environment, interrupt: interrupt,
            output: SetOutput(terminal: patient, format: format), startingParent: startingParent)
        let report = await SetCommand.perform(request, in: session)
        await client.disconnect()

        try SetCommand.emit(report, as: format, on: patient)
    }
}
