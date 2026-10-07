import AeolusXPC
import ArgumentParser
import FanKit
import Foundation
import Testing

@testable import fanctl

/// What `fanctl auto` prints and exits with for each thing the helper can say, and how an
/// invocation is accepted or refused. The round trip against a real helper session is
/// `FanctlAutoTests`, in `AeolusHelperTests`.
@Suite("fanctl auto rendering")
struct AutoCommandTests {

    typealias Fixtures = SafeStateTests

    static func observation(
        _ snapshot: SystemSnapshot,
        restoreRequested: Bool = true,
        restoreFailure: String? = nil,
        endedLease: Lease? = nil,
        interruption: String? = nil,
        snapshotFollowsRestore: Bool? = nil,
        firstSnapshotFailure: String? = nil
    ) -> AutoCommand.Observation {
        AutoCommand.Observation(
            restoreRequested: restoreRequested, restoreFailure: restoreFailure,
            endedLease: endedLease, snapshot: snapshot,
            verdict: interruption == nil ? SafeState.verdict(for: snapshot) : .notConfirmed,
            interruption: interruption,
            snapshotFollowsRestore: snapshotFollowsRestore ?? restoreRequested,
            firstSnapshotFailure: firstSnapshotFailure)
    }

    /// Fan 1 carries `reason`, reading `mode` — manual by default, automatic for the helper's
    /// report of a mode it could not read.
    static func pinned(
        _ reason: ManualControlAvailability.Reason, index: Int = 1,
        reading mode: FanControlMode = .manualFixed
    ) -> SystemSnapshot {
        Fixtures.snapshot([
            Fixtures.fan(0),
            Fixtures.fan(index, mode: mode, availability: .unavailable(reason)),
        ])
    }

    // MARK: - The invocation

    @Test("auto and auto all parse to the same command")
    func autoAndAutoAllParse() throws {
        let bare = try #require(Fanctl.parseAsRoot(["auto"]) as? Fanctl.Auto)
        let all = try #require(Fanctl.parseAsRoot(["auto", "all"]) as? Fanctl.Auto)
        #expect(bare.target == nil)
        #expect(all.target == "all")
        #expect(!bare.json)
        let json = try #require(Fanctl.parseAsRoot(["auto", "--json"]) as? Fanctl.Auto)
        #expect(json.json)
    }

    /// No wire verb returns one fan on behalf of another process, so an index would either do
    /// nothing or quietly return other fans too. 64, with the reason, before any connection.
    ///
    /// **Mutation:** delete `Fanctl.Auto.validate()`'s guard (or make it accept an integer).
    /// Run: red — parsing succeeds and nothing is thrown.
    @Test("auto <index> is a usage error that says why")
    func aFanIndexIsRefused() {
        for argument in ["0", "1", "12"] {
            do {
                _ = try Fanctl.parseAsRoot(["auto", argument])
                Issue.record("`fanctl auto \(argument)` was accepted")
            } catch {
                #expect(Fanctl.exitCode(for: error) == .validationFailure, "\(argument)")
                let message = Fanctl.message(for: error)
                #expect(message.contains("no fan index"), "\(argument): \(message)")
                #expect(message.contains("fanctl auto"), "\(argument): \(message)")
            }
        }
    }

    @Test("Anything but all is a usage error")
    func anythingButAllIsRefused() {
        for argument in ["fan0", "both", "0,1", ""] {
            do {
                _ = try Fanctl.parseAsRoot(["auto", argument])
                Issue.record("`fanctl auto \(argument)` was accepted")
            } catch {
                #expect(Fanctl.exitCode(for: error) == .validationFailure, "\(argument)")
            }
        }
    }

    @Test("auto is a registered subcommand, and the root help names exit code 9")
    func autoIsRegisteredAndNinesDocumented() {
        #expect(Fanctl.configuration.subcommands.contains { $0 == Fanctl.Auto.self })
        // The discussion itself, not the wrapped help: wrapping may split a phrase.
        let discussion = Fanctl.configuration.discussion
        #expect(discussion.contains("8 safe state not confirmed, 9 cannot return to automatic"))
        #expect(Fanctl.helpMessage(columns: 1_000).contains("auto"))
    }

    // MARK: - Exit codes

    @Test("An automatic verdict has no failure, and nothing else is silent")
    func verdictToExitCode() {
        let leased = Self.observation(Fixtures.leasedManual)
        let strandedManual = Self.observation(
            Fixtures.snapshot([Fixtures.fan(0, mode: .manualFixed)]))
        let pinned = Self.observation(Self.pinned(.foreignManualControl))

        #expect(Self.observation(Fixtures.automatic).failure == nil)
        #expect(leased.failure?.code == .heldByAnotherClient)
        #expect(strandedManual.failure?.code == .safeStateNotConfirmed)
        #expect(pinned.failure?.code == .cannotReturnToAutomatic)
    }

    /// The helper's report of a mode it could not read is `automatic`; the reason beside it is
    /// what says the fan has not been cleared. 9 for a durable one, 8 for a pending one, and
    /// nothing for a silent one — which is every fan on today's helper.
    ///
    /// **Mutation:** classify by `fan.mode != .automatic` first in `SafeState.verdict(for:)`
    /// (the old rule). Run: red on each of the first two.
    @Test("A reason beside a mode of automatic still decides the exit")
    func aReasonBesideAnAutomaticModeDecidesTheExit() {
        let foreign = Self.observation(Self.pinned(.foreignManualControl, reading: .automatic))
        let failed = Self.observation(Self.pinned(.restoreToAutomaticFailed, reading: .automatic))
        let blind = Self.observation(Self.pinned(.supervisorBlind, reading: .automatic))
        let handback = Self.observation(Self.pinned(.handbackUnconfirmed, reading: .automatic))
        let shipping = Self.observation(
            Fixtures.snapshot([
                Fixtures.fan(0, availability: .unavailable(.writePathNotBuilt)),
                Fixtures.fan(1, availability: .unavailable(.writePathNotBuilt)),
            ]), restoreRequested: false)

        #expect(foreign.failure?.code == .cannotReturnToAutomatic)
        #expect(failed.failure?.code == .cannotReturnToAutomatic)
        #expect(blind.failure?.code == .safeStateNotConfirmed, "a blind fan is unknown, not manual")
        #expect(handback.failure?.code == .safeStateNotConfirmed)
        #expect(shipping.failure == nil, "writePathNotBuilt on every fan is today's helper")
    }

    /// 9, then 5, then 8. A pinned fan and a lease together are a 9: retrying cannot change it.
    ///
    /// **Mutation:** in `AutoCommand.Observation.failure`, test the lease before the verdict's
    /// `.cannotReturn`. Run: red.
    @Test("A durable pin and a lease together exit 9")
    func nineOutranksFive() {
        let snapshot = Fixtures.snapshot(
            [
                Fixtures.fan(0, mode: .manualFixed),
                Fixtures.fan(
                    1, mode: .manualFixed, availability: .unavailable(.foreignManualControl)),
            ], lease: Fixtures.lease)
        #expect(Self.observation(snapshot).failure?.code == .cannotReturnToAutomatic)
    }

    /// A lease in the last snapshot is evidence of the end of the window only if the window
    /// ended by looking. When the helper stopped answering, that lease may be long gone, and
    /// 5 would name a holder nobody has seen since.
    ///
    /// **Mutation:** drop the `interruption == nil` condition from the lease test in
    /// `AutoCommand.Observation.failure`. Run: red — exits 5.
    @Test("A lease seen before the helper stopped answering is not a lease at the end")
    func aStaleLeaseIsNotFive() {
        let observation = Self.observation(Fixtures.leasedManual, interruption: "it went away")
        #expect(observation.failure?.code == .safeStateNotConfirmed)
    }

    // MARK: - Text: what it may say

    @Test("Already safe: one sentence from the helper's report, and no restore claimed")
    func alreadyAutomaticText() {
        let observation = Self.observation(Fixtures.automatic, restoreRequested: false)
        let text = AutoCommand.text(for: observation)
        #expect(text.contains("The helper reports every fan automatic and no manual-control lease"))
        #expect(text.contains("captured at 2026-09-21T14:13:20Z"))
        #expect(text.contains("No restore request was sent."))
        #expect(!text.contains("Asked the helper"))
        #expect(text.contains("Fan 0"))
        #expect(text.contains("mode automatic · target none"))
    }

    @Test("A machine with no fans says so rather than claiming every fan is automatic")
    func noFansText() {
        let observation = Self.observation(Fixtures.snapshot([]), restoreRequested: false)
        let text = AutoCommand.text(for: observation)
        #expect(text.contains("The helper reports no fans and no manual-control lease"))
        #expect(!text.contains("every fan automatic"))
    }

    @Test("After a restore that settled: what was asked, which lease is gone, what is reported")
    func settledText() {
        let ended = Lease(
            holderDescription: "Aeolus.app 0.3.0",
            expiresAt: Fixtures.captured.addingTimeInterval(9))
        let observation = Self.observation(Fixtures.automatic, endedLease: ended)
        let text = AutoCommand.text(for: observation)
        #expect(text.contains("The manual-control lease held by \"Aeolus.app 0.3.0\""))
        #expect(text.contains("is no longer listed"))
        #expect(text.contains("id \(ended.id.uuidString)"))
        #expect(text.contains("Asked the helper once to return every fan to automatic control"))
        #expect(text.contains("it accepted the request"))
        #expect(
            text.contains("The helper now reports every fan automatic and no manual-control lease"))
    }

    /// A lease that is no longer listed was not necessarily ended by this run: the request may
    /// have been refused, or its reply lost, while the lease's own TTL ran out. The output says
    /// what was observed, and never that the run ended anything.
    ///
    /// **Mutation:** restore "Ended the manual-control lease held by" in `AutoCommand.text(for:)`.
    /// Run: red.
    @Test("A lease that is no longer listed is not claimed as ended by this run")
    func noLongerListedIsNotEnded() {
        let gone = Lease(holderDescription: "Aeolus.app 0.3.0", expiresAt: Fixtures.captured)
        let text = AutoCommand.text(
            for: Self.observation(
                Fixtures.automatic, restoreFailure: "no reply", endedLease: gone))
        #expect(text.contains("is no longer listed"))
        #expect(text.contains("it may have expired"))
        #expect(text.contains("it did not confirm the request"))
        #expect(!text.contains("Ended"))
        #expect(!text.contains("ended"))
    }

    /// The run that sent the request on a handshake alone says why it did.
    @Test("A first snapshot that failed is said, and the request is still reported")
    func firstSnapshotFailureText() {
        let observation = Self.observation(
            Fixtures.automatic, firstSnapshotFailure: "The helper failed: boom.")
        let text = AutoCommand.text(for: observation)
        #expect(text.contains("The helper's first snapshot failed (The helper failed: boom.)"))
        #expect(text.contains("completed its handshake"))
        #expect(text.contains("Asked the helper once"))
        #expect(!AutoCommand.text(for: Self.observation(Fixtures.automatic)).contains("first"))
    }

    /// The holder's description is another process's words, printed on a terminal.
    @Test("An ended holder's description is sanitised")
    func holderIsSanitised() {
        let ended = Lease(
            holderDescription: "evil\u{1B}[2J\u{202E}tool", expiresAt: Fixtures.captured)
        let text = AutoCommand.text(for: Self.observation(Fixtures.automatic, endedLease: ended))
        #expect(text.contains("held by \"evil[2Jtool\""))
        #expect(!text.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{202E}" })
    }

    @Test("A restore the helper did not confirm is reported as such")
    func unacknowledgedRestoreText() {
        let observation = Self.observation(
            Fixtures.automatic, restoreFailure: "The helper did not answer within 10 seconds.")
        let text = AutoCommand.text(for: observation)
        #expect(
            text.contains(
                "it did not confirm the request: The helper did not answer within 10 seconds."))
        #expect(!text.contains("it accepted the request"))
    }

    @Test("A thermal emergency is said when the helper reports one, and only then")
    func thermalEmergencyText() {
        let emergency = SystemSnapshot(
            fans: [Fixtures.fan(0, mode: .manualFixed)], sensors: [], activeLease: nil,
            isThermalEmergencyActive: true, capturedAt: Fixtures.captured)
        let text = AutoCommand.text(for: Self.observation(emergency))
        #expect(text.contains("Thermal emergency: ACTIVE"))
        #expect(!AutoCommand.text(for: Self.observation(Fixtures.automatic)).contains("Thermal"))
    }

    /// Rule 6, in the one place a user reads to learn whether the fans are fine. Nothing on
    /// either stream of a run that did not end in the safe state may say it did.
    ///
    /// **Mutation:** make `AutoCommand.verdictLine(for:)` return the settled sentence for every
    /// verdict. Run: red on each case.
    @Test("No outcome short of the safe state claims it")
    func noFailureClaimsSuccess() {
        let cases: [(String, AutoCommand.Observation)] = [
            ("lease", Self.observation(Fixtures.leasedManual)),
            (
                "stranded",
                Self.observation(Fixtures.snapshot([Fixtures.fan(0, mode: .manualFixed)]))
            ),
            ("foreign", Self.observation(Self.pinned(.foreignManualControl))),
            ("failed", Self.observation(Self.pinned(.restoreToAutomaticFailed))),
            ("interrupted", Self.observation(Fixtures.leasedManual, interruption: "gone")),
            (
                "foreign, reads automatic",
                Self.observation(Self.pinned(.foreignManualControl, reading: .automatic))
            ),
            (
                "blind, reads automatic",
                Self.observation(Self.pinned(.supervisorBlind, reading: .automatic))
            ),
            (
                "handback, reads automatic",
                Self.observation(Self.pinned(.handbackUnconfirmed, reading: .automatic))
            ),
        ]
        for (name, observation) in cases {
            let failure = observation.failure?.message ?? ""
            let everything = AutoCommand.text(for: observation) + "\n" + failure
            #expect(!failure.isEmpty, "\(name)")
            for claim in [
                "reports every fan automatic", "now reports", "are back under automatic",
                "fans are automatic", "have been returned", "were returned", "restored",
                "is back under automatic",
            ] {
                #expect(!everything.contains(claim), "\(name) claimed \"\(claim)\"")
            }
        }
    }
}
