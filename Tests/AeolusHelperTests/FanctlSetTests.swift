import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set`, end to end, for a hold that goes right: the shipping `run()`, the real
/// `HelperClient`, a real `NSXPCListener` and the real `HelperConnectionSession` behind it. Only
/// the authority is a double (`SimulatedFanAuthority`), and only where to look, where to write,
/// how time passes and what the process is are substituted on the command.
///
/// **Time is virtual.** A thirty-second hold is walked by a clock that advances exactly as far
/// as it is asked to sleep, so no test waits and none asserts a wall-clock upper bound
/// ([#319](https://github.com/blamechris/Aeolus/issues/319)). Every message is still a real XPC
/// round trip.
///
/// What none of it proves: that a **signed** `fanctl` is admitted by an **installed** helper
/// (blocked on #82), or what a fan does when held (blocked on E4). `set` is **held**: it does not
/// merge before E5 (#7) and the owner-supervised E4 acceptance (#9), per #15, and a green run here
/// is the contract held against a double.
@Suite("fanctl set against a real helper session", .timeLimit(.minutes(1)))
struct FanctlSetTests {

    typealias Harness = SetHarness

    // MARK: - A hold that goes right

    /// The whole contract on its happy path, in one place: the order of the calls, one
    /// `acquireLease`, a renewal then a snapshot every ten virtual seconds, a release, and the
    /// safe-state read after it.
    ///
    /// **Mutation:** in `SetCommand.heartbeats`, sleep the whole remaining time in one step
    /// (`remaining` in place of `min(heartbeat, remaining)`). Run: red — no renewal, and the
    /// sleeps are one thirty-second sleep.
    @Test("A thirty-second hold renews every ten seconds, releases, and checks the safe state")
    func aHoldRunsItsCourse() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == nil)
        #expect(
            await Harness.writes(authority).joined(separator: " ")
                == [
                    "acquireLease", "apply", "renewLease", "renewLease", "releaseLease",
                ].joined(separator: " "))
        // Reads: first, the one that lists the lease after apply, one after each renewal, and the
        // safe-state read after the release.
        #expect(await authority.snapshotsServed == 5)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        #expect(await authority.renewals == 2)
        #expect(run.time.sleeps == Array(repeating: .seconds(10), count: 3))
        #expect(run.time.elapsed == .seconds(30))
        #expect(await authority.currentLease == nil)
        #expect(await authority.modes() == [.automatic, .automatic])
        #expect(run.desk.installs == 1)
        let session = try #require(harness.sessions.first)
        #expect(await session.handshakeState != nil, "set must handshake")
    }

    /// What the helper is asked for: a 30-second lease that is not self-renewing, held by this
    /// tool, over exactly the fan named, at the speed that fan's own envelope gives.
    ///
    /// **Mutation:** set `isSelfRenewing: true` in `SetCommand.leaseRequest`. Run: red.
    @Test("The lease request names this tool, a 30-second lifetime, and does not self-renew")
    func theLeaseRequest() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == nil)
        let request = try #require(await authority.acquiredRequests.first)
        #expect(await authority.acquiredRequests.count == 1)
        #expect(request.holderDescription == "fanctl \(Fanctl.toolVersion) (pid \(getpid()))")
        #expect(request.fanIndices == [0])
        #expect(request.timeToLive == 30)
        #expect(request.isSelfRenewing == false)
        let applied = await authority.appliedSettings
        #expect(applied == [[FanSetting(fanIndex: 0, control: .fixed(rpm: 4670))]])
        _ = harness.sessions
    }

    @Test("all holds every fan under one lease, each at its own speed")
    func allHoldsEveryFan() async throws {
        let authority = SimulatedFanAuthority(fans: [
            SimulatedFanAuthority.fan(0),
            SimulatedFanAuthority.fan(1, minimum: 2000, maximum: 6000),
        ])
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["all", "75%", "--for", "10s"], over: harness)

        #expect(run.code == nil)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        #expect(try #require(await authority.acquiredRequests.first).fanIndices == [0, 1])
        #expect(
            await authority.appliedSettings == [
                [
                    FanSetting(fanIndex: 0, control: .fixed(rpm: 4670)),
                    FanSetting(fanIndex: 1, control: .fixed(rpm: 5000)),
                ]
            ])
        let text = run.output.standardOutput.split(separator: "\n").map(String.init)
        try #require(text.count == 3, "a start line per fan, and one closing line: \(text)")
        #expect(text[0].hasPrefix("Holding fan 0 at 75% (4670 RPM target; firmware 1350–5777 RPM)"))
        #expect(text[1].hasPrefix("Holding fan 1 at 75% (5000 RPM target; firmware 2000–6000 RPM)"))
        #expect(text[1].hasSuffix("Ctrl-C returns them to automatic sooner."))
        #expect(!text[0].contains("Ctrl-C"))
        _ = harness.sessions
    }

    @Test("An rpm speed is held as asked, and said to be a target")
    func anRPMSpeed() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["1", "3000RPM", "--for", "10s"], over: harness)

        #expect(run.code == nil)
        #expect(
            await authority.appliedSettings == [
                [FanSetting(fanIndex: 1, control: .fixed(rpm: 3000))]
            ])
        let start = try #require(run.output.standardOutput.split(separator: "\n").first)
        #expect(
            start.hasPrefix(
                "Holding fan 1 at 3000 RPM target (firmware 1350–5777 RPM) for 10s under lease "))
        _ = harness.sessions
    }

    /// The contract's own sentence, and silence between the start and the end: a line every ten
    /// seconds is chatter, and a script reading standard output would see a change that is not
    /// one.
    ///
    /// **Mutation:** write a line from `SetOutput.holding` in text mode. Run: red on the count.
    @Test("Text prints the start line and one closing line, and nothing on stdout in between")
    func textIsQuietWhileHolding() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["0", "75%", "--for", "10m"], over: harness)

        #expect(run.code == nil)
        let lines = run.output.standardOutput.split(separator: "\n").map(String.init)
        try #require(lines.count == 2, "\(lines)")
        #expect(
            lines[0].hasPrefix(
                "Holding fan 0 at 75% (4670 RPM target; firmware 1350–5777 RPM) for 10m under "
                    + "lease "))
        #expect(lines[0].hasSuffix(". Ctrl-C returns it to automatic sooner."))
        #expect(lines[1].hasPrefix("The hold ended: the 10m it was asked for has passed. "))
        #expect(lines[1].contains("The helper accepted the release of lease "))
        #expect(
            lines[1].contains(
                "The helper now reports every fan automatic and no manual-control lease"))
        #expect(run.output.standardError.isEmpty)
        // Ten minutes is sixty heartbeats, the last of them the deadline itself.
        #expect(await authority.renewals == 59)
        _ = harness.sessions
    }

    // MARK: - --json

    /// started once, holding after each heartbeat, exactly one closing event, in that order; and
    /// every line carries `schema`, `event` and `at`.
    ///
    /// **Mutation:** emit `started` from `SetCommand.perform` after the loop instead of before.
    /// Run: red on the order.
    @Test("--json is started, a holding per heartbeat, and exactly one ended, in order")
    func jsonEventOrder() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == nil)
        let events = try run.output.events()
        #expect(
            events.map { $0["event"] as? String } == ["started", "holding", "holding", "ended"])
        for event in events {
            #expect(event["schema"] as? Int == 1)
            #expect(event["at"] is String)
        }
        #expect(run.output.standardError.isEmpty)
        // One line per event: NDJSON, not a pretty-printed document.
        #expect(run.output.lines.filter { $0.stream == .standardOutput }.count == 4)
        _ = harness.sessions
    }

    @Test("started names the lease, the duration and each fan's request, command and observation")
    func jsonStarted() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        let events = try run.output.events()
        let started = try #require(events.first)
        let leaseID = try #require(started["leaseID"] as? String)
        #expect(UUID(uuidString: leaseID) != nil)
        #expect(started["durationSeconds"] as? Int == 30)
        let fans = try #require(started["fans"] as? [[String: Any]])
        try #require(fans.count == 1)
        let fan = fans[0]
        #expect(fan["index"] as? Int == 0)
        #expect(fan["commandedRPM"] as? Double == 4670)
        let requested = try #require(fan["requested"] as? [String: Any])
        #expect(requested["unit"] as? String == "percent")
        #expect(requested["value"] as? Int == 75)
        let observed = try #require(fan["observed"] as? [String: Any])
        #expect(observed["index"] as? Int == 0)
        #expect(observed["mode"] as? String == "manualFixed")
        #expect(observed["targetRPM"] as? Double == 4670)
        let actual = try #require(observed["actualRPM"] as? [String: Any])
        #expect(actual["value"] is Double, "the fan's own reading travels beside the target")
        _ = harness.sessions
    }

    @Test("holding carries the remaining seconds, counting down, and the lease")
    func jsonHolding() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        let events = try run.output.events()
        let id = try #require(events.first?["leaseID"] as? String)
        let holding = Harness.event("holding", in: events)
        #expect(holding.map { $0["remainingSeconds"] as? Int } == [20, 10])
        #expect(holding.allSatisfy { $0["leaseID"] as? String == id })
        #expect(holding.allSatisfy { ($0["fans"] as? [[String: Any]])?.count == 1 })
        _ = harness.sessions
    }

    @Test("ended names the lease, why, the release and what the helper reported")
    func jsonEnded() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        let events = try run.output.events()
        let id = try #require(events.first?["leaseID"] as? String)
        let ended = try #require(events.last)
        #expect(ended["event"] as? String == "ended")
        #expect(ended["leaseID"] as? String == id)
        #expect(ended["endedBecause"] as? String == "durationElapsed")
        #expect(ended["signal"] is NSNull)
        #expect(ended["releaseAccepted"] as? Bool == true)
        #expect(ended["snapshotFollowsRelease"] as? Bool == true)
        #expect(ended["listedLeaseID"] is NSNull)
        #expect(ended["failure"] is NSNull)
        #expect(ended["capturedAt"] is String)
        let fans = try #require(ended["fans"] as? [[String: Any]])
        let observed = try #require(fans.first?["observed"] as? [String: Any])
        #expect(
            observed["mode"] as? String == "automatic", "after the release, as the helper reports")
        _ = harness.sessions
    }

    /// The deadline is measured on a monotonic clock, so no document may say when it ends: a
    /// step in the wall clock must not be able to make one lie.
    ///
    /// **Mutation:** add an `endsAt` date to `SetStartedEventJSON`. Run: red.
    @Test("No event carries a wall-clock end time")
    func noWallClockEnd() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        let forbidden = ["endsAt", "endTime", "expiresAt", "deadline", "until", "end"]
        for event in try run.output.events() {
            for key in forbidden {
                #expect(event[key] == nil, "\(event["event"] ?? "?") carries `\(key)`")
            }
        }
        #expect(!run.output.standardOutput.contains("expiresAt"))
        _ = harness.sessions
    }

    // MARK: - Never trust the mode alone

    /// `apply` is accepted and the fan reads automatic with no target: the helper reports an
    /// unread mode as automatic, and a lease it lists says it is the holder. That is not a loss.
    /// `started` does not claim the fan reached its speed either, and says what it reads.
    ///
    /// **Mutation:** in `SetCommand.loss(in:leaseID:covering:)`, report a loss for a covered fan
    /// whose `mode == .automatic`. Run: red — exit 6.
    @Test("A fan that reads automatic beside a listed lease is not a loss, and not a speed")
    func modeAloneIsNotALoss() async throws {
        let authority = SimulatedFanAuthority()
        await authority.ignoringApply()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == nil)
        let events = try run.output.events()
        #expect(
            events.map { $0["event"] as? String } == ["started", "holding", "holding", "ended"])
        let started = try #require(events.first)
        let fan = try #require((started["fans"] as? [[String: Any]])?.first)
        #expect(fan["commandedRPM"] as? Double == 4670, "what was asked for")
        let observed = try #require(fan["observed"] as? [String: Any])
        #expect(observed["mode"] as? String == "automatic", "what the helper reports")
        #expect(observed["targetRPM"] is NSNull)
        #expect(await Harness.count("renewLease", in: authority) == 2)
        _ = harness.sessions
    }
}
