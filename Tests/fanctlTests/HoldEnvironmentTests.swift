import Foundation
import Testing

@testable import fanctl

/// The production signal handlers and parent reader, which every other test substitutes.
///
/// Serialised, because a signal disposition belongs to the whole process. SIGHUP is the one sent
/// here: while handlers are installed it is ignored by the process and delivered to the handler,
/// so a missing handler is a loud failure (the default action is to terminate the test process)
/// and never a silent pass.
@Suite("The production hold environment", .serialized)
struct HoldEnvironmentTests {

    /// 0 for `SIG_DFL`, 1 for `SIG_IGN`, anything else is a handler.
    private static func disposition(of signal: Int32) -> Int {
        var action = sigaction()
        sigaction(signal, nil, &action)
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
    }

    @Test("The parent is this process's parent")
    func parent() {
        #expect(HoldEnvironment.production.parentProcessID() == getppid())
        #expect(HoldEnvironment.production.parentProcessID() > 0)
    }

    /// The first signal the stream delivers, or `nil` if none comes within `limit`. The limit
    /// matters only when the handler is broken: delivery is immediate otherwise.
    private static func first(
        of stream: AsyncStream<HoldSignal>, within limit: Duration
    ) async -> HoldSignal? {
        await withTaskGroup(of: HoldSignal?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
    }

    /// **Mutation:** make the dispatch source's event handler do nothing
    /// (`source.setEventHandler { }` in `HoldEnvironment.production`). Run: red — nothing is
    /// delivered. Not stopping at `source.resume()`: a source that is never activated traps in
    /// libdispatch when it is released, after the assertion has already failed.
    @Test(
        "A signal sent to the process reaches the handler, and cancelling restores the process",
        .timeLimit(.minutes(1)))
    func signalIsDelivered() async throws {
        let before = Self.disposition(of: SIGHUP)
        let (stream, continuation) = AsyncStream.makeStream(of: HoldSignal.self)
        let subscription = HoldEnvironment.production.installSignals { continuation.yield($0) }
        defer { subscription.cancel() }
        try #require(Self.disposition(of: SIGHUP) == 1, "ignored while the handler is installed")

        kill(getpid(), SIGHUP)

        #expect(await Self.first(of: stream, within: .seconds(10)) == .hangup)
        subscription.cancel()
        #expect(Self.disposition(of: SIGHUP) == before, "the previous disposition is back")
    }

    /// A write to a closed pipe must come back as an error, not kill a process holding a lease.
    ///
    /// **Mutation:** delete the `SIGPIPE` line in `HoldEnvironment.production`. Run: red.
    @Test("SIGPIPE is ignored while installed, and restored after")
    func sigpipeIsIgnored() {
        let before = Self.disposition(of: SIGPIPE)
        let subscription = HoldEnvironment.production.installSignals { _ in }
        #expect(Self.disposition(of: SIGPIPE) == 1)
        subscription.cancel()
        #expect(Self.disposition(of: SIGPIPE) == before)
    }

    @Test("Cancelling twice puts back what was found, once")
    func cancelTwice() {
        let before = Self.disposition(of: SIGTERM)
        let subscription = HoldEnvironment.production.installSignals { _ in }
        #expect(Self.disposition(of: SIGTERM) == 1)
        subscription.cancel()
        subscription.cancel()
        #expect(Self.disposition(of: SIGTERM) == before)
    }
}
