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

/// Where a helper-talking command writes.
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
/// ## Two ways to write
///
/// - **`status`, `auto` and the other one-shot commands write here, to the end** (`say`,
///   `warn`, `deliver`). Every byte is delivered, and the write waits as long as the reader
///   needs: a reader that is slow is not a reader that is gone, and a document that arrives in
///   part is worse than one that arrives late. A reader that *has* gone is EPIPE, which neither
///   crashes the command nor changes its exit code — nobody is left to be misled by it. These
///   commands hold nothing, so a write that parks costs the caller its own time and no more.
/// - **`set` does not write here at all** (`lineSinks()`). A process holding a lease must keep
///   renewing it and must be able to stop, and a write to a pipe can park for as long as the
///   kernel makes it. `set` hands its lines to a `LinePump` per stream and never waits on one
///   except to close.
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

    /// A stream, a line; `true` if the line arrived.
    typealias Delivery = @Sendable (Stream, String) -> Bool

    private let delivery: Delivery
    private let makeSinks: @Sendable () -> OutputSinks

    /// A terminal whose writes cannot fail.
    init(_ sink: @escaping @Sendable (Stream, String) -> Void) {
        self.init(delivering: { stream, text in
            sink(stream, text)
            return true
        })
    }

    /// A terminal that says whether each line arrived. A suite's recorder either takes a line or
    /// does not, and never makes anyone wait, so `set`'s lines to it are written inline.
    init(delivering delivery: @escaping Delivery) {
        self.init(
            delivery: delivery,
            sinks: {
                OutputSinks(
                    standardOutput: LinePump(inline: { line in
                        delivery(.standardOutput, line) ? .delivered : .readerGone
                    }),
                    standardError: LinePump(inline: { line in
                        delivery(.standardError, line) ? .delivered : .readerGone
                    }))
            })
    }

    /// A terminal whose `set` lines go to the pumps `sinks` builds: the seam a suite uses to put
    /// a writer that blocks, or one that is slow, under a run.
    init(
        delivery: @escaping Delivery = { _, _ in true },
        sinks: @escaping @Sendable () -> OutputSinks
    ) {
        self.delivery = delivery
        self.makeSinks = sinks
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
    ///   - output: The descriptor `say` writes to.
    ///   - errors: The descriptor `warn` writes to.
    ///   - shouldIgnore: Whether each write ignores SIGPIPE while it is made. Always, outside
    ///     the suites that are not about it (`FileDescriptorWriter.writeLine`).
    /// - Returns: The terminal.
    static func writing(
        to output: Int32, errors: Int32, ignoringSIGPIPE shouldIgnore: Bool = true
    ) -> Terminal {
        Terminal(
            delivery: { stream, text in
                let descriptor = stream == .standardOutput ? output : errors
                let outcome = FileDescriptorWriter.writeLine(
                    text, to: descriptor, ignoringSIGPIPE: shouldIgnore)
                if case .failed(let code) = outcome, stream == .standardOutput {
                    let reason = String(cString: strerror(code))
                    _ = FileDescriptorWriter.writeLine(
                        "fanctl: could not write to standard output: \(reason)", to: errors,
                        ignoringSIGPIPE: shouldIgnore)
                }
                return outcome.isDelivered
            },
            sinks: {
                OutputSinks(
                    standardOutput: LinePump(threaded: "fanctl.standard-output") { line in
                        FileDescriptorWriter.writeLine(
                            line, to: output, ignoringSIGPIPE: shouldIgnore)
                    },
                    standardError: LinePump(threaded: "fanctl.standard-error") { line in
                        FileDescriptorWriter.writeLine(
                            line, to: errors, ignoringSIGPIPE: shouldIgnore)
                    })
            })
    }

    /// The pumps one `set` run writes through: one per stream, each with a thread of its own.
    func lineSinks() -> OutputSinks { makeSinks() }

    /// A result: what the command was asked for.
    func say(_ text: String) { _ = delivery(.standardOutput, text) }

    /// A diagnosis: why the command could not give it, or what the user should know about it.
    func warn(_ text: String) { _ = delivery(.standardError, text) }
}
