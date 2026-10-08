import AeolusXPCClient
import Foundation

/// Where a helper-talking `fanctl` command looks for the helper, who it will accept as one, and
/// how long it waits.
///
/// **This exists so that `run()` is the thing under test.** It replaced a test-only
/// `run(restoring:)` overload that every test called and nothing shipped, which left the
/// decisions the shipping path actually makes — which verb is sent, which deadlines it waits
/// with, and the teardown afterwards — covered by nothing. A `run()` rewritten to
/// `try emit(accepted)` printed "the helper accepted the reset request" having contacted
/// nothing, and the whole suite stayed green. The seam therefore sits **below** all of those:
/// it carries only where to look, who may answer, and how long to wait, and each command's
/// `run()` keeps everything else.
///
/// It was `ResetCommand.HelperConnection` while `reset --all` was the only command that spoke
/// to the helper. `status`, `set` and `auto` share it rather than each growing a copy, because
/// a second copy is a second place where a test could select a transport and production could
/// select a different one.
///
/// `Decodable` by hand, and that is what makes it injectable at all. swift-argument-parser
/// decodes every stored property of a command, this one included, through a decoder that
/// knows only about parsed arguments; answering it with `production` regardless is how a
/// property that is not an argument, and can never come from a command line, still satisfies
/// the conformance. There is no flag that reaches it and there must never be one: a
/// `--helper-endpoint` option would let anything on the machine tell `fanctl` which process to
/// treat as the root daemon.
struct HelperConnection: Decodable, Sendable {

    let transport: HelperClientTransport
    let pinning: any HelperConnectionPinning
    let deadlines: HelperClientDeadlines

    /// What this client calls itself in the helper's log. One string for every command, so a
    /// `status` and a `set` from the same binary are recognisably the same tool.
    static let clientDescription = "fanctl \(Fanctl.toolVersion)"

    /// The installed daemon, pinned to the signature this build requires, on the shipping
    /// deadlines — `HelperClientDeadlines.panicVerb` (10 s) for `reset --all`, `gatedVerb`
    /// (5 s) for everything else.
    static let production = HelperConnection(
        transport: .machService,
        pinning: SignedHelperPinning(),
        deadlines: .default)

    init(
        transport: HelperClientTransport,
        pinning: any HelperConnectionPinning,
        deadlines: HelperClientDeadlines
    ) {
        self.transport = transport
        self.pinning = pinning
        self.deadlines = deadlines
    }

    init(from decoder: Decoder) throws {
        self = .production
    }

    /// A client on this connection. Each command builds exactly one and disconnects it before
    /// it exits: `HelperClient` releases a connection's helper-side session from the
    /// invalidation handler, and a reference left to die with the process would leave that
    /// teardown to whenever libxpc noticed the peer had gone.
    func client() -> HelperClient {
        HelperClient(
            transport: transport,
            pinning: pinning,
            clientDescription: Self.clientDescription,
            deadlines: deadlines)
    }
}

/// Where a helper-talking command writes, one line at a time.
///
/// **Why these commands do not print through swift-argument-parser's error path, as `reset`
/// does.** Two reasons, both about the contract a remote caller depends on. The exit code
/// table in `FanctlExitCode` needs codes other than 0, 1 and 64, and swift-argument-parser
/// prints a message only for errors it exits 1 with — an `ExitCode` is silent. And `set`
/// streams: its lines have to reach the terminal while the lease is held, not in one block
/// when the process ends. So these commands write their own lines here and leave through
/// `ExitCode`.
///
/// Unbuffered `write(2)` rather than `print`, so an NDJSON event piped into another process
/// arrives when it happens instead of when a stdio buffer fills, and rather than
/// `FileHandle.write`, which raises an Objective-C exception on EPIPE.
///
/// ## Two kinds of terminal
///
/// - **`status`, `auto` and the other one-shot commands write to the end.** Every byte is
///   delivered, and the write waits as long as the reader needs: a reader that is slow is not a
///   reader that is gone, and a document that arrives in part is worse than one that arrives
///   late. A reader that *has* gone is EPIPE, which neither crashes the command nor changes its
///   exit code — nobody is left to be misled by it.
/// - **`set` writes within a bound** (`bounded(stopping:)`). A process holding a lease must keep
///   renewing it, so no write may park it past a signal, a renewal or its deadline. A line is
///   written in chunks no larger than the room a pipe promises, each after the pipe has said it
///   has room, with a short wait between; a stop request ends the wait, and a reader that has not
///   made room within the bound is treated as gone. See `FileDescriptorWriter`.
///
/// `reset --all` does not use this type, and must not.
///
/// `Decodable` by hand for the same reason as `HelperConnection`: it is not an argument, the
/// suite substitutes a recorder, and nothing on a command line may reach it.
struct Terminal: Decodable, Sendable {

    enum Stream: Sendable, Hashable {
        case standardOutput
        case standardError
    }

    /// How long a bounded write may wait for room, in all, for one line. Well under the
    /// heartbeat (10 s), so a stalled consumer costs the lease one late renewal at most, never
    /// the two the lease can miss.
    static let writeBound = Duration.seconds(2)

    /// The longest single wait before a bounded write asks whether it should stop.
    static let writeSlice = Duration.milliseconds(100)

    /// A stream, a line, and whether to give up when asked (`nil` writes to the end); `true` if
    /// the line arrived.
    typealias Delivery = @Sendable (Stream, String, (@Sendable () -> Bool)?) -> Bool

    private let delivery: Delivery
    private let stopping: (@Sendable () -> Bool)?

    /// A terminal whose writes cannot fail.
    init(_ sink: @escaping @Sendable (Stream, String) -> Void) {
        self.init(
            delivery: { stream, text, _ in
                sink(stream, text)
                return true
            })
    }

    /// A terminal that says whether each line arrived. It has no patience to apply: a suite's
    /// recorder either takes a line or does not.
    init(delivering delivery: @escaping @Sendable (Stream, String) -> Bool) {
        self.init(delivery: { stream, text, _ in delivery(stream, text) })
    }

    private init(delivery: @escaping Delivery, stopping: (@Sendable () -> Bool)? = nil) {
        self.delivery = delivery
        self.stopping = stopping
    }

    init(from decoder: Decoder) throws {
        self = .process
    }

    /// This process's own standard output and standard error.
    static let process = Terminal.writing(to: STDOUT_FILENO, errors: STDERR_FILENO)

    /// A terminal over two file descriptors.
    ///
    /// A failure other than a reader that has gone, to a one-shot command's standard output, is
    /// said on its standard error (`status >&-` would otherwise exit 0 having written nothing).
    /// The command's exit code is not changed by it.
    ///
    /// - Parameters:
    ///   - output: The descriptor `say` and `deliver` write to.
    ///   - errors: The descriptor `warn` writes to.
    ///   - wait: Waits up to a slice for room to write. `FileDescriptorWriter.pollForRoom` in
    ///     production; a suite substitutes one that costs no real time.
    ///   - shouldIgnore: Whether each write ignores SIGPIPE while it is made. Always, outside
    ///     the suites that are not about it (`FileDescriptorWriter.writeLine`).
    /// - Returns: The terminal.
    static func writing(
        to output: Int32, errors: Int32,
        waiting wait: @escaping @Sendable (Int32, Duration) -> FileDescriptorWriter.Wait =
            FileDescriptorWriter.pollForRoom,
        ignoringSIGPIPE shouldIgnore: Bool = true
    ) -> Terminal {
        Terminal(
            delivery: { stream, text, stop in
                let descriptor = stream == .standardOutput ? output : errors
                let patience = stop.map {
                    FileDescriptorWriter.Patience(
                        limit: writeBound, slice: writeSlice, stop: $0, wait: wait)
                }
                let outcome = FileDescriptorWriter.writeLine(
                    text, to: descriptor, patience: patience, ignoringSIGPIPE: shouldIgnore)
                if case .failed(let code) = outcome, stream == .standardOutput, stop == nil {
                    let reason = String(cString: strerror(code))
                    _ = FileDescriptorWriter.writeLine(
                        "fanctl: could not write to standard output: \(reason)", to: errors,
                        ignoringSIGPIPE: shouldIgnore)
                }
                return outcome.isDelivered
            })
    }

    /// The same terminal, every write of which gives up when `stop` says so or when the reader
    /// has not made room within `writeBound`. For `set`, whose lease must not wait on a reader.
    func bounded(stopping stop: @escaping @Sendable () -> Bool) -> Terminal {
        Terminal(delivery: delivery, stopping: stop)
    }

    /// A result: what the command was asked for.
    func say(_ text: String) { _ = delivery(.standardOutput, text, stopping) }

    /// A result, and whether it arrived. `false` is a consumer that has gone, or one that did not
    /// make room in time when this terminal is bounded.
    func deliver(_ text: String) -> Bool { delivery(.standardOutput, text, stopping) }

    /// A diagnosis: why the command could not give it, or what the user should know about it.
    func warn(_ text: String) { _ = delivery(.standardError, text, stopping) }
}
