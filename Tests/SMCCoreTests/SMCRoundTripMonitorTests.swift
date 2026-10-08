import Foundation
import Testing
import os

@testable import SMCCore

// The round-trip stamp (ADR 0012 I1, I2, I3): what `SMCRoundTripMonitor` publishes, and the
// properties the watchdog built on it depends on. The monitor is exercised on its own here;
// that `SMCConnection` really routes every IOKit call through it is the tripwire's job — see
// `RoundTripStampTripwireTests`.
//
// ## Nothing here reads the stamp from inside the body on the body's own thread
//
// `bracket` runs its body with no lock held, so a body *may* call `inFlight()` on its own
// thread. A test that did would, under the one mutation that matters most (the lock held
// across the body), re-enter a non-recursive lock and trap the whole test process with no
// message about the cause. Every read made while a bracket is open therefore goes through
// `observeInFlight`, on a dedicated thread with a bound: under that mutation it fails an
// assertion that names the cause.

/// A thrown error for the throwing-body cases; the monitor must not care what it is.
private struct BodyFailure: Error, Equatable {}

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
            insideReturn = observeInFlight(monitor)
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
                insideThrow = observeInFlight(monitor)
                throw BodyFailure()
            }
        }
        #expect(insideThrow?.operation == .open, "a throwing body is stamped too")
        #expect(monitor.inFlight() == nil, "a round trip that threw leaves nothing in flight")
    }

    @Test("Sequence numbers start at 1, strictly increase across returns and throws, never repeat")
    func sequenceNumbersStrictlyIncrease() {
        let monitor = SMCRoundTripMonitor()
        var seen: [UInt64] = []

        for step in 0..<4 {
            // A throw in the middle must not reset or repeat the counter: the watchdog's
            // "same sequence on two ticks" test is only sound if a new round trip is always a
            // new number.
            _ = try? monitor.bracket(.close) {
                if let stamp = observeInFlight(monitor) { seen.append(stamp.sequence) }
                if step == 1 { throw BodyFailure() }
            }
        }

        #expect(seen.count == 4)
        // The first stamp is 1, not 0: a watchdog that starts its "last sequence seen" at 0
        // would otherwise take the first round trip of a process for one it had already seen.
        #expect(seen.first == 1, "\(seen) does not start at 1")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "\(seen) is not increasing")
        #expect(monitor.issuedCount == 4)
    }

    @Test("A reader is never blocked by a round trip that has not returned")
    func theLockIsNotHeldAcrossTheCall() {
        let monitor = SMCRoundTripMonitor()
        let parked = ParkedRoundTrip(monitor, .call(key: 0x4630_4163, selector: 5))
        defer { parked.finish() }

        guard parked.waitUntilParked() else {
            Issue.record("the round trip never started")
            return
        }

        // A watchdog reads from its own thread while the call is out. If the stamp's lock were
        // held across the call, this read would block until the call returned.
        let seen = observeInFlight(monitor, within: 5)
        #expect(
            seen?.operation == .call(key: 0x4630_4163, selector: 5),
            "the reader did not see the parked round trip's stamp")
    }

    // MARK: - One slot

    /// A and B overlap, which the debug assertion forbids and so goes through the test seam. A
    /// returns first. B's stamp must still be in the slot: A's return clears A's stamp or
    /// nothing, never whatever is there.
    ///
    /// This is what every build does on an overlap, and the debug trap is how the overlap is
    /// found; the stamp A set was already replaced when B began, so this limits the damage and
    /// does not undo it.
    @Test("A round trip that returns clears only its own stamp")
    func aRoundTripClearsOnlyItsOwnStamp() {
        let monitor = SMCRoundTripMonitor()
        let first = ParkedRoundTrip(monitor, .open, allowingOverlap: true)
        var second: ParkedRoundTrip?
        defer {
            first.letReturn()
            second?.letReturn()
            first.finish()
            second?.finish()
        }
        guard first.waitUntilParked() else {
            Issue.record("the first round trip never started")
            return
        }

        second = ParkedRoundTrip(monitor, .close, allowingOverlap: true)
        guard second?.waitUntilParked(within: 5) == true else {
            Issue.record("the second round trip never began while the first was in flight")
            return
        }

        first.letReturn()
        guard first.waitUntilReturned() else {
            Issue.record("the first round trip never returned")
            return
        }
        let afterFirst = observeInFlight(monitor)
        #expect(afterFirst?.operation == .close, "the first return erased the second's stamp")
        #expect(afterFirst?.sequence == 2)

        second?.letReturn()
        guard second?.waitUntilReturned() == true else {
            Issue.record("the second round trip never returned")
            return
        }
        #expect(monitor.inFlight() == nil, "the last round trip to return clears the slot")
    }

    // MARK: - The age

    /// A reader asking for the age while a writer stamps as fast as it can must never see a
    /// negative one. "Now" is read after the stamp is copied out, so it cannot precede that
    /// stamp's start; read before the copy, a stamp begun in between has a start later than
    /// "now".
    ///
    /// It terminates on counts, not on a clock: the writer runs until the reader has seen enough
    /// stamps, or has read ten million times, whichever comes first. The second bound is what
    /// ends it when no stamp is ever visible (a lock held across the body hides every one), and
    /// the test asserts nothing about how many it saw: on a loaded machine that would be a
    /// flake, and the lock test is the one that holds that line. Nothing asserts how long it took.
    @Test("An age is never negative while a writer stamps and a reader reads")
    func anAgeIsNeverNegativeUnderContention() {
        let monitor = SMCRoundTripMonitor()
        let stop = OSAllocatedUnfairLock(initialState: false)
        let writerFinished = DispatchSemaphore(value: 0)

        let writer = Thread {
            while !stop.withLock({ $0 }) {
                monitor.bracket(.call(key: 0x4630_4163, selector: 5)) {}
            }
            writerFinished.signal()
        }
        writer.start()

        var observed = 0
        var negative = 0
        var reads = 0
        while observed < 50_000 && reads < 10_000_000 {
            reads += 1
            if let reading = monitor.inFlight() {
                observed += 1
                if reading.age < .zero { negative += 1 }
            }
        }
        stop.withLock { $0 = true }
        _ = writerFinished.wait(timeout: .now() + .seconds(10))

        #expect(negative == 0, "\(negative) of \(observed) readings had a negative age")
    }

    // MARK: - ADR 0012 I2: the stamp is readable while the connection is held

    /// The actor's executor is the cooperative pool, so holding the actor parks one of its
    /// threads. This test therefore needs a second pool thread to run on, and it waits on none:
    /// it polls with `Task.sleep`, reads from a dedicated thread, and a failsafe on a GCD queue
    /// releases the held actor even if the pool is too narrow to schedule the rest. On a pool of
    /// one, the test fails after the failsafe instead of hanging the process.
    ///
    /// It asserts two things that must hold together. The actor really is held — a call that has
    /// to enter it stays queued — and the stamp is readable regardless. Without the first, the
    /// second proves nothing: a body that never occupied the actor would be "readable" too.
    ///
    /// What actually stops the stamp's read from needing the actor is `nonisolated` on
    /// `SMCConnection.roundTrips`, and that is checked by the compiler: without it, the
    /// synchronous read below does not compile.
    @Test("Reading the stamp does not enter the connection that is stamped")
    func theStampIsReadableWhileTheConnectionIsOccupied() async {
        let connection = SMCConnection()
        let monitor = connection.roundTrips
        let release = DispatchSemaphore(value: 0)
        let probeFinished = OSAllocatedUnfairLock(initialState: false)

        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(30)) { release.signal() }

        let occupation = Task {
            await connection.occupyForTesting {
                monitor.bracket(.open) { release.wait() }
            }
        }

        guard await poll(until: { monitor.inFlight() != nil }) else {
            Issue.record("the connection was never occupied")
            release.signal()
            await occupation.value
            return
        }

        // A call that has to enter the actor, queued behind the occupation.
        let probe = Task {
            await connection.close()
            probeFinished.withLock { $0 = true }
        }

        // `roundTrips` is `nonisolated`: a synchronous read, with no `await`, while the actor is
        // held. On a thread of its own so that a read which did block fails by timing out.
        let reading = await readOnDedicatedThread(connection.roundTrips)

        // The probe must still be waiting after a window in which a free actor would have run
        // it. A window can only fail to catch a probe that was slow; it cannot invent one.
        for _ in 0..<25 { try? await Task.sleep(for: .milliseconds(10)) }
        let probeRanWhileHeld = probeFinished.withLock { $0 }

        release.signal()
        await occupation.value
        await probe.value

        #expect(reading != nil, "the stamp could not be read while the connection was occupied")
        #expect(reading?.value?.operation == .open)
        #expect(!probeRanWhileHeld, "the connection was not actually held while the stamp was read")
        #expect(probeFinished.withLock { $0 }, "the queued call never ran once the actor was free")
        #expect(connection.roundTrips.inFlight() == nil)
    }

    // MARK: - ADR 0012 I3: the CI half of `aRoundTripSpanningSleepIsNotAWedge`

    /// Age must not grow across a system sleep, so it is measured on the suspending clock — a
    /// property of one `typealias`, asserted here as a property of the type — and it must be
    /// **computed by the monitor, from its own clock, when it is asked, from the moment the
    /// call began**. The comparer mints the instant: a caller-supplied or begin-time age could
    /// not be told apart from a different clock family by anything but a real sleep, and an age
    /// that ran from the monitor's creation would make every round trip as old as the process.
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
        // The monitor has existed for seven seconds when the call begins. An age measured from
        // anywhere but the start of the call reads seven seconds too many.
        clock.advance(by: .seconds(7))

        var ages: [Duration] = []
        monitor.bracket(.call(key: 0x4630_4163, selector: 5)) {
            ages.append(observeInFlight(monitor)?.age ?? .seconds(-1))
            clock.advance(by: .seconds(2))
            ages.append(observeInFlight(monitor)?.age ?? .seconds(-1))
            clock.advance(by: .seconds(3))
            ages.append(observeInFlight(monitor)?.age ?? .seconds(-1))
        }

        // Each reading is the monitor's own clock at the moment of the read, less the moment
        // the call began: zero, then 2 s, then 5 s. An age fixed when the stamp was taken
        // would read zero all three times.
        #expect(ages == [.zero, .seconds(2), .seconds(5)])
        #expect(monitor.inFlight() == nil)
    }
}
