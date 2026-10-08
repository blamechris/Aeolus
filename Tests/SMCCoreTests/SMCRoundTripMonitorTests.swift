import Foundation
import Testing
import os

@testable import SMCCore

// The round-trip stamp (ADR 0012 I1, I2, I3): what `SMCRoundTripMonitor` publishes, and the
// two properties the watchdog built on it depends on. The monitor is exercised on its own
// here; that `SMCConnection` really routes every IOKit call through it is the tripwire's
// job — see `RoundTripStampTripwireTests`.

/// A clock the test moves by hand, on the monitor's own `Instant`.
///
/// It is typed `SMCRoundTripMonitor.Instant` and takes its starting point from the monitor's
/// own `MeasuringClock`, rather than being declared over `SuspendingClock.Instant` directly.
/// That is deliberate: the clock family is one line in the monitor, and a helper that named
/// it a second time would stop compiling the moment that line changed — turning the
/// assertion that pins the family into a build error instead of a failure.
final class SteppedClock: Clock, Sendable {
    typealias Instant = SMCRoundTripMonitor.Instant

    private let base = SMCRoundTripMonitor.MeasuringClock().now
    private let elapsed = OSAllocatedUnfairLock(initialState: Duration.zero)

    var now: Instant { base.advanced(by: elapsed.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by amount: Duration) {
        elapsed.withLock { $0 += amount }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()
    }
}

/// A thrown error for the throwing-body cases; the monitor must not care what it is.
private struct BodyFailure: Error, Equatable {}

/// A bounded wait, in a synchronous function so an `async` test may call it: the compiler
/// refuses `DispatchSemaphore.wait` directly in an async context, and the bound is what keeps
/// a failing test from hanging instead of failing.
private func signalled(_ semaphore: DispatchSemaphore, within seconds: Int) -> Bool {
    semaphore.wait(timeout: .now() + .seconds(seconds)) == .success
}

@Suite("SMC round-trip stamp", .timeLimit(.minutes(1)))
struct SMCRoundTripMonitorTests {

    private static let readBytes = SMCRoundTripOperation.call(key: 0x4630_4163, selector: 5)

    @Test("The stamp is visible for exactly as long as the body runs, on return and on throw")
    func theStampBracketsTheIOKitCall() {
        let monitor = SMCRoundTripMonitor()
        #expect(monitor.inFlight() == nil, "nothing is in flight before any round trip")

        // On return: stamped inside the body, cleared the moment it returns, and the value the
        // body produced comes back untouched.
        var insideReturn: SMCRoundTripInFlight?
        let produced = monitor.bracket(Self.readBytes) { () -> Int in
            insideReturn = monitor.inFlight()
            return 42
        }
        #expect(produced == 42)
        #expect(insideReturn?.operation == Self.readBytes, "the body runs under its own stamp")
        #expect(monitor.inFlight() == nil, "a round trip that returned leaves nothing in flight")

        // On throw: the same, and the error reaches the caller. A stamp left behind by a
        // throwing round trip would read as a wedge that never ended.
        var insideThrow: SMCRoundTripInFlight?
        #expect(throws: BodyFailure.self) {
            try monitor.bracket(.open) {
                insideThrow = monitor.inFlight()
                throw BodyFailure()
            }
        }
        #expect(insideThrow?.operation == .open, "a throwing body is stamped too")
        #expect(monitor.inFlight() == nil, "a round trip that threw leaves nothing in flight")
    }

    @Test("Sequence numbers strictly increase across returns and throws, and are never reused")
    func sequenceNumbersStrictlyIncrease() {
        let monitor = SMCRoundTripMonitor()
        var seen: [UInt64] = []

        for step in 0..<6 {
            // A throw in the middle must not reset or repeat the counter: the watchdog's
            // "same sequence on two ticks" test is only sound if a new round trip is always a
            // new number.
            _ = try? monitor.bracket(.close) {
                if let stamp = monitor.inFlight() { seen.append(stamp.sequence) }
                if step == 2 { throw BodyFailure() }
            }
        }

        #expect(seen.count == 6)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "\(seen) is not increasing")
        #expect(monitor.issuedCount == 6)
    }

    @Test("A reader is never blocked by a round trip that has not returned")
    func theLockIsNotHeldAcrossTheCall() {
        let monitor = SMCRoundTripMonitor()
        let bodyEntered = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        let bodyFinished = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        let observation = OSAllocatedUnfairLock<SMCRoundTripInFlight?>(initialState: nil)

        // The "IOKit call": it parks until the test lets it go. This is a real blocked
        // thread, not a suspended task, which is what a wedged `IOConnectCallStructMethod` is.
        let caller = Thread {
            monitor.bracket(.call(key: 0x4630_4163, selector: 5)) {
                bodyEntered.signal()
                releaseBody.wait()
            }
            bodyFinished.signal()
        }
        caller.start()

        // Whatever happens below, the parked body is released and the threads are joined, so a
        // failing run cannot leave a thread parked for the rest of the test process. The reader
        // is only joined here if the test body did not already consume its signal.
        var readerJoined = false
        defer {
            releaseBody.signal()
            _ = bodyFinished.wait(timeout: .now() + .seconds(10))
            if !readerJoined { _ = readerFinished.wait(timeout: .now() + .seconds(10)) }
        }

        guard bodyEntered.wait(timeout: .now() + .seconds(10)) == .success else {
            Issue.record("the round trip never started")
            return
        }

        // A watchdog reads from its own thread while the call is out. If the stamp's lock were
        // held across the call, this read would block until the call returned.
        let reader = Thread {
            // Read first, store second: the read is the thing that may block, and it must not
            // do so holding the lock the test thread needs to look at the result.
            let seen = monitor.inFlight()
            observation.withLock { $0 = seen }
            readerFinished.signal()
        }
        reader.start()

        let readerReturned = readerFinished.wait(timeout: .now() + .seconds(5)) == .success
        readerJoined = readerReturned
        #expect(readerReturned, "inFlight() blocked behind a round trip that had not returned")
        #expect(
            observation.withLock { $0 }?.operation == .call(key: 0x4630_4163, selector: 5),
            "the reader did not see the parked round trip's stamp")
    }

    @Test("Reading the stamp does not enter the connection that is stamped")
    func theStampIsReadableWhileTheConnectionIsOccupied() async {
        let connection = SMCConnection()
        let monitor = connection.roundTrips
        let occupied = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        let observation = OSAllocatedUnfairLock<SMCRoundTripInFlight?>(initialState: nil)

        // Occupy the actor with a body that holds a stamp open, as a wedged round trip would.
        let occupation = Task {
            await connection.occupyForTesting {
                monitor.bracket(.open) {
                    occupied.signal()
                    release.wait()
                }
            }
        }

        guard signalled(occupied, within: 10) else {
            Issue.record("the connection was never occupied")
            release.signal()
            await occupation.value
            return
        }

        // `roundTrips` is `nonisolated`: this is a synchronous read with no `await`, while the
        // actor is held. It runs on its own thread so that a read which did block fails by
        // timing out, rather than hanging the test behind the call it was meant to observe.
        let reader = Thread {
            let seen = connection.roundTrips.inFlight()
            observation.withLock { $0 = seen }
            readerFinished.signal()
        }
        reader.start()
        let readerReturned = signalled(readerFinished, within: 5)

        release.signal()
        await occupation.value

        #expect(readerReturned, "the stamp could not be read while the connection was occupied")
        #expect(observation.withLock { $0 }?.operation == .open)
        #expect(connection.roundTrips.inFlight() == nil)
    }

    // MARK: - ADR 0012 I3: the CI half of `aRoundTripSpanningSleepIsNotAWedge`

    /// Age must not grow across a system sleep, so it is measured on the suspending clock — a
    /// property of one `typealias`, asserted here as a property of the type — and it must be
    /// **computed by the monitor, from its own clock, when it is asked**. The comparer mints
    /// the instant: a caller-supplied or begin-time age could not be told apart from a
    /// different clock family by anything but a real sleep.
    ///
    /// This is the half CI can run. The other half — a real lid close with a round trip in
    /// flight — is a hardware observation and has not been made (ADR 0012 H1 conditions 3–4).
    @Test("The monitor measures on the suspending clock, and ages a stamp from its own clock")
    func aRoundTripSpanningSleepIsNotAWedge() {
        #expect(
            SMCRoundTripMonitor.Instant.self == SuspendingClock.Instant.self,
            "ADR 0012 I3: a round trip in flight across a sleep must not age")

        let clock = SteppedClock()
        let monitor = SMCRoundTripMonitor(clock: clock)

        var ages: [Duration] = []
        monitor.bracket(.call(key: 0x4630_4163, selector: 5)) {
            ages.append(monitor.inFlight()?.age ?? .seconds(-1))
            clock.advance(by: .seconds(2))
            ages.append(monitor.inFlight()?.age ?? .seconds(-1))
            clock.advance(by: .seconds(3))
            ages.append(monitor.inFlight()?.age ?? .seconds(-1))
        }

        // Each reading is the monitor's own clock at the moment of the read, less the moment
        // the stamp was taken: zero, then 2 s, then 5 s. An age fixed when the stamp was
        // taken would read zero all three times.
        #expect(ages == [.zero, .seconds(2), .seconds(5)])
        #expect(monitor.inFlight() == nil)
    }
}
