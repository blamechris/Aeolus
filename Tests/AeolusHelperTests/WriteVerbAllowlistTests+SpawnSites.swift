import Foundation
import Testing

/// `WriteVerbAllowlistTests`' spawn-site census, in a file of its own so the suite's body keeps
/// room under `type_body_length` for the rows A6's second step added. An extension of the same
/// suite, not a second one: the same `@Suite`, run and reported as before, and nothing in it is
/// shared with the population checks in `WriteVerbAllowlistTests.swift`.
extension WriteVerbAllowlistTests {

    // MARK: - The route around "a synchronous function cannot await"

    /// The suite doc's first stated limit, asserted rather than asserted *about*.
    ///
    /// An unstructured `Task` lets a synchronous function reach an `async` write, so every
    /// spawn site is a hole in the population — unless what it spawns is itself acknowledged.
    /// That is what holds here: none of the eighteen bodies writes, and each — bar #205's
    /// overrun alarm and A6's gate timer, below, which make a synchronous call — hands off to an
    /// `async` method in the population. (The three supervisors also await a synchronous
    /// `loopEnded(generation:)` that only clears a task handle; `BoundedFanRestorer`'s and
    /// `CriticalTemperatureCache`'s spawners are themselves `async`, so their `Task`s shield
    /// cancellation and share one read rather than bridging from synchronous code;
    /// `AeolusHelperMain`'s also signals a `DispatchSemaphore`, which is how the listener
    /// stays off the task that cannot safely carry it; and `ConnectionHealth`'s is an
    /// `AsyncStream` loop whose one statement awaits a population member — see the suite
    /// doc, which says all five rather than rounding them off.)
    ///
    /// [#167](https://github.com/blamechris/Aeolus/issues/167) added the last two, and they
    /// are the two shapes this rule is about. `SystemPowerObserver`'s is the *only* route from
    /// a `@convention(c)` IOKit callback — which cannot capture, let alone `await` — to an
    /// `async` handler, and its body is one `await` of `respond(to:)`.
    /// `SystemPowerResponder`'s is not a bridge from synchronous code at all: it runs § 4's
    /// acknowledgement budget beside a handback that `BoundedFanRestorer` makes uncancellable,
    /// so a task group — which waits for every child — could not express it. Its body sleeps
    /// and then awaits `SleepAcknowledgement.acknowledge(_:)`, and writes nothing.
    ///
    /// **Re-pinned by [#90](https://github.com/blamechris/Aeolus/issues/90):** nineteen to
    /// fourteen, because `HelperXPCService`'s seven became two — the single spawn inside
    /// `MessageSequencer.enqueue(_:)`, which six of its entry points then called instead, and
    /// the seventh's own `Task`. Those call sites are still a route around `await` and
    /// this scanner cannot see them; `MessageOrderingTests` pins them by the same
    /// discipline, and pins the *shape* of each closure too, because the body
    /// `MessageSequencer` awaits is an opaque `@Sendable` closure that no allowlist here can
    /// name.
    ///
    /// **Re-pinned again by [#229](https://github.com/blamechris/Aeolus/issues/229):** fourteen
    /// to sixteen, because `renewLease` and `releaseLease` came back out of the sequencer. A
    /// lease heartbeat queued behind the client's own 1 Hz reads could arrive after the TTL it
    /// was renewing had expired, and `docs/SAFETY.md` § 1's tolerance for two missed beats is a
    /// property of the client's sending that a helper-side backlog defeated. They are ordinary
    /// members of this population again: each body is one `await` of the matching
    /// `HelperConnectionSession` method, and neither writes.
    ///
    /// The third in that file is `restoreAllToAutomatic`, which keeps its `Task` because the
    /// panic path may not wait on a message sent before it (D27), on the same argument.
    ///
    /// **Re-pinned by [#205](https://github.com/blamechris/Aeolus/issues/205):** sixteen to
    /// seventeen, the second in `ReadOnlyFanAuthority.swift`. It is the discovery walk's
    /// overrun alarm, spawned inside `walkEveryKey()`, which is already `async` — so it is not
    /// a bridge from synchronous code either, and exists because the alarm must run *beside*
    /// a walk that may never return. Its body sleeps on the injected clock and then awaits
    /// `discoveryWalkOverran()`, which increments a counter and logs. It writes nothing.
    ///
    /// **[#329](https://github.com/blamechris/Aeolus/issues/329)** (ADR 0012) leaves it at
    /// seventeen, deliberately. `LivenessWatchdog.tick()` ends the process on its own dispatch
    /// queue, synchronously, and has no `Task`: a hand-off to the cooperative pool would never
    /// run in the one case the watchdog exists for, the pool not making progress. A spawn site
    /// added to `LivenessWatchdog.swift` is therefore not a number to update here but the
    /// hand-off that ADR 0012's amendment rejects.
    ///
    /// **Re-pinned by ADR 0014's A6 amendment:** one more, in `FanExaminationGate.swift`. It is
    /// a contended wait's timer, spawned inside `wait(_:fanAt:within:)`, which is already
    /// `async`: it runs beside the wait, as #205's alarm runs beside a walk. Its body sleeps on
    /// the injected clock and then, unless it was cancelled, makes one synchronous call,
    /// `decide(_:fanAt:_:)`, which takes the gate's lock, may log and may resume a waiter. It
    /// writes nothing, and it is cancelled however the wait ends.
    ///
    /// The count is asserted per file so it cannot drift silently. A nineteenth spawn site
    /// fails this with the file it was added to, and the maintainer either shows it hands off
    /// the same way and updates the number, or has found the hole.
    ///
    /// **The number churns, and that is the acknowledgment discipline #120 asked for, not an
    /// oversight.** Any helper PR that adds a `Task` reddens this until its author writes the
    /// new count down — the failure message names the file and prints both dictionaries, so
    /// what to update is never in doubt. A count that maintained itself would assert nothing.
    ///
    /// The pattern lives in `SeamScanner.unstructuredTaskSpawns(inSource:)` so a fixture can
    /// be put through it. Written inline here, its first spelling missed
    /// `Task<Void, Never> { … }` — a legal spelling of exactly the thing being counted — and
    /// nothing could have noticed, because the only thing exercising it was the tree whose
    /// shapes it already matched.
    @Test("Every unstructured Task in the helper hands off to an acknowledged verb")
    func everyUnstructuredTaskHandsOffToThePopulation() throws {
        let expected = [
            "AeolusHelperMain.swift": 1,
            "BoundedFanRestorer.swift": 1,
            "ConnectionHealth.swift": 1,
            "CriticalTemperatureCache.swift": 1,
            "FanExaminationGate.swift": 1,
            "HelperListenerDelegate.swift": 1,
            "HelperXPCService.swift": 3,
            "LeaseExpirySupervisor.swift": 1,
            "MessageSequencer.swift": 1,
            "ReadOnlyFanAuthority.swift": 2,
            "ReclamationSupervisor.swift": 1,
            "SignalTeardown.swift": 1,
            "SystemPowerObserver.swift": 1,
            "SystemPowerResponder.swift": 1,
            "ThermalSupervisor.swift": 1,
        ]

        var counted: [String: Int] = [:]

        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let matches = try SeamScanner.unstructuredTaskSpawns(
                inSource: try String(contentsOf: file, encoding: .utf8))
            if matches > 0 { counted[file.lastPathComponent] = matches }
        }

        #expect(
            counted == expected,
            """
            the unstructured `Task` spawn sites in Sources/AeolusHelper changed: found \
            \(counted.sorted(by: { $0.key < $1.key })), expected \
            \(expected.sorted(by: { $0.key < $1.key })). Each existing one writes nothing in \
            its own body: it awaits an `async` method that this suite acknowledges, or, as \
            #205's overrun alarm and A6's gate timer do, makes one synchronous call that writes \
            nothing. That is the only reason a synchronous spawner need not be in the \
            population. Show that a new one does the same — and if it writes in its own body, \
            that is the hole, not the count.
            """
        )
    }
}
