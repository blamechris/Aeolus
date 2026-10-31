import AeolusXPCClient
import Foundation

/// Where a helper-talking `fanctl` command looks for the helper, who it will accept as one, how
/// long it waits, and how the client it waits through is made.
///
/// **This exists so that `run()` is the thing under test.** It replaced a test-only
/// `run(restoring:)` overload that every test called and nothing shipped, which left the
/// decisions the shipping path actually makes — which verb is sent, which deadlines it waits
/// with, and the teardown afterwards — covered by nothing. A `run()` rewritten to
/// `try emit(accepted)` printed "the helper accepted the reset request" having contacted
/// nothing, and the whole suite stayed green. The seam therefore sits **below** all of those:
/// it carries only where to look, who may answer, how long to wait and how the client is made,
/// and each command's `run()` keeps everything else.
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
///
/// ## The fourth member, and why it is a maker rather than a clock
///
/// A deadline counted on the wall clock is one a stalled CI runner runs out for a command that
/// did nothing wrong ([#583](https://github.com/blamechris/Aeolus/issues/583)): the suites that
/// drive `run()` against an in-process helper wait 10 s, and a run that stood still for longer
/// than that failed them together. The client can count its deadlines on any `Clock`, but only
/// through an initialiser that is `internal` to `AeolusXPCClient`, which `fanctl` cannot name
/// and which is not widened for the sake of a test. So what this carries is the **making** of
/// the client, handed the other three members and the description, and the suite's maker
/// supplies the clock from where the initialiser is visible to it.
///
/// It chooses nothing else. The maker is given where to look, who may answer, how long to wait
/// and what to call itself, and builds a client from exactly those. `production` and the decoded
/// value carry `shippingClient`, which can only be `HelperClient`'s public initialiser: this
/// module cannot name the one that takes a clock, so the compiler, rather than a test, is what
/// keeps the shipping binary on the wall clock with the deadlines it was given.
struct HelperConnection: Decodable, Sendable {

    /// How a client is made from the parts of a connection.
    typealias ClientMaker =
        @Sendable (
            _ transport: HelperClientTransport,
            _ pinning: any HelperConnectionPinning,
            _ clientDescription: String,
            _ deadlines: HelperClientDeadlines
        ) -> HelperClient

    let transport: HelperClientTransport
    let pinning: any HelperConnectionPinning
    let deadlines: HelperClientDeadlines
    let makeClient: ClientMaker

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

    /// `HelperClient`'s public initialiser, which counts its deadlines on `ContinuousClock`. The
    /// only maker a shipping binary carries.
    static let shippingClient: ClientMaker = { transport, pinning, clientDescription, deadlines in
        HelperClient(
            transport: transport,
            pinning: pinning,
            clientDescription: clientDescription,
            deadlines: deadlines)
    }

    init(
        transport: HelperClientTransport,
        pinning: any HelperConnectionPinning,
        deadlines: HelperClientDeadlines,
        makeClient: @escaping ClientMaker = HelperConnection.shippingClient
    ) {
        self.transport = transport
        self.pinning = pinning
        self.deadlines = deadlines
        self.makeClient = makeClient
    }

    init(from decoder: Decoder) throws {
        self = .production
    }

    /// A client on this connection. Each command builds exactly one and disconnects it before
    /// it exits: `HelperClient` releases a connection's helper-side session from the
    /// invalidation handler, and a reference left to die with the process would leave that
    /// teardown to whenever libxpc noticed the peer had gone.
    func client() -> HelperClient {
        makeClient(transport, pinning, Self.clientDescription, deadlines)
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
/// Unbuffered `FileHandle` writes rather than `print`, so an NDJSON event piped into another
/// process arrives when it happens instead of when a stdio buffer fills.
///
/// `Decodable` by hand for the same reason as `HelperConnection`: it is not an argument, the
/// suite substitutes a recorder, and nothing on a command line may reach it.
struct Terminal: Decodable, Sendable {

    enum Stream: Sendable, Hashable {
        case standardOutput
        case standardError
    }

    private let sink: @Sendable (Stream, String) -> Void

    init(_ sink: @escaping @Sendable (Stream, String) -> Void) {
        self.sink = sink
    }

    init(from decoder: Decoder) throws {
        self = .process
    }

    /// This process's own standard output and standard error.
    static let process = Terminal { stream, text in
        let data = Data((text + "\n").utf8)
        switch stream {
        case .standardOutput: FileHandle.standardOutput.write(data)
        case .standardError: FileHandle.standardError.write(data)
        }
    }

    /// A result: what the command was asked for.
    func say(_ text: String) { sink(.standardOutput, text) }

    /// A diagnosis: why the command could not give it, or what the user should know about it.
    func warn(_ text: String) { sink(.standardError, text) }
}
