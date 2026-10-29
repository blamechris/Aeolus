import Foundation

@testable import AeolusXPCClient
@testable import fanctl

/// What the client behind a `fanctl` command counts its deadlines on, named at every call that
/// builds one ([#583](https://github.com/blamechris/Aeolus/issues/583)).
enum FanctlDeadlineClock: Sendable {

    /// `ClientListenerHarness.clock`: a deadline runs out when the test moves it past the figure,
    /// or when the harness's backstop does after 30 s of scheduled waiting time. A runner stall
    /// spends none of it. What a test whose claim is not about time takes, and what a test whose
    /// claim *is* a deadline moves and asserts.
    case harness

    /// The shipping client's own clock, `ContinuousClock`, through `HelperConnection`'s default
    /// maker: the deadline runs out by itself, and a stall spends it. Taken only where that is
    /// the claim, because it is the one path a shipping binary has.
    case wall
}

extension ClientListenerHarness {

    /// The connection a `fanctl` command is given to talk to this harness, with its deadlines
    /// counted on `clock`.
    ///
    /// `HelperConnection` makes its client through a maker, and `fanctl` cannot name the
    /// initialiser that takes a clock, so the maker for `.harness` is built here, where
    /// `@testable import AeolusXPCClient` reaches it. It passes through every part the
    /// connection hands it and adds the clock, so the command still decides which verb it sends
    /// and how long it waits for it.
    ///
    /// - Parameters:
    ///   - deadlines: how long the command waits for one message. No default, as
    ///     `FanctlResetTests.emitted(over:waiting:counting:)` has none: a suite names the figure.
    ///   - clock: what those deadlines are counted on. No default either, for the same reason.
    /// - Returns: a connection to this harness's listener, pinned by nothing, for a command's
    ///   `helper`.
    func fanctlConnection(
        waiting deadlines: HelperClientDeadlines,
        counting clock: FanctlDeadlineClock
    ) -> HelperConnection {
        switch clock {
        case .wall:
            return HelperConnection(
                transport: .endpoint(endpoint),
                pinning: UnenforcedClientPinning(),
                deadlines: deadlines)
        case .harness:
            let harnessClock = self.clock
            return HelperConnection(
                transport: .endpoint(endpoint),
                pinning: UnenforcedClientPinning(),
                deadlines: deadlines,
                makeClient: { transport, pinning, clientDescription, deadlines in
                    HelperClient(
                        transport: transport,
                        pinning: pinning,
                        clientDescription: clientDescription,
                        deadlines: deadlines,
                        clock: harnessClock)
                })
        }
    }
}
