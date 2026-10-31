import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper

/// A `LeaseLog` sink a test can read back, **with the level**, for the same reason
/// `RecordedHelperLines` and `RecordedLog` carry it: the level is half of what a line asserts.
///
/// An `OSAllocatedUnfairLock` rather than an `NSLock` beside an `@unchecked Sendable` class, so
/// an assertion reads it without an `await` and the compiler, not a comment, holds the claim
/// that it is safe to share.
final class RecordedLeaseLines: Sendable {

    struct Line: Sendable {
        let level: LeaseLog.Level
        let text: String
    }

    private let recorded = OSAllocatedUnfairLock<[Line]>(initialState: [])

    func append(_ level: LeaseLog.Level, _ text: String) {
        recorded.withLock { $0.append(Line(level: level, text: text)) }
    }

    var lines: [Line] { recorded.withLock { $0 } }

    /// The levels of the lines containing `needle`, in order.
    ///
    /// Substring matching on a phrase only the intended line can produce: asserting a whole
    /// prose line is a test that fails on a comma, and matching text a *different* line could
    /// also satisfy is a test that passes for the wrong reason.
    func levels(containing needle: String) -> [LeaseLog.Level] {
        recorded.withLock { $0.filter { $0.text.contains(needle) }.map(\.level) }
    }
}

/// `LeaseLog` writes every line through one route, so the level a test reads from the sink is
/// the level the unified log was given (#560).
///
/// Before #560 it made 28 direct `log.<level>(` calls and had no seam a test could read, so the
/// level of each was a claim nothing could check: demoting a `.fault` to a `.notice` left every
/// test green. The two tests below are `HelperLogTests`' pair, and a third holds the table
/// complete.
@Suite("LeaseLog writes each line once, at the level its sink is told")
struct LeaseLogTests {

    /// Each level maps to the unified log's type of the same name; notice is `.default`, which
    /// is what `Logger.notice` writes.
    ///
    /// **Mutation:** in `LeaseLog.osLogType(for:)`, map `.fault` to `.default`. Run: red here
    /// and nowhere else, because the sink is told the level, not the type.
    @Test("Every level is written at the unified log's type of the same name")
    func everyLevelMapsToItsOwnType() {
        let expected: [LeaseLog.Level: OSLogType] = [
            .debug: .debug, .info: .info, .notice: .default, .fault: .fault,
        ]
        #expect(Set(expected.keys) == Set(LeaseLog.Level.allCases), "a level has no mapping")
        for level in LeaseLog.Level.allCases {
            #expect(
                LeaseLog.osLogType(for: level) == expected[level],
                "\(level) is written at \(LeaseLog.osLogType(for: level).rawValue)")
        }
    }

    private struct Row {
        let name: String
        let level: LeaseLog.Level
        let write: @Sendable (LeaseLog) -> Void
    }

    private static let connection = ConnectionID()
    private static let fans: Set<Int> = [0, 1]
    private static let reason = ManualControlAvailability.Reason.reclaimedBySystem

    /// One row per line `LeaseLog` writes, with the level it has always been written at. Taken
    /// from the 28 `log.<level>(` calls #560 replaced, read at 548d467.
    private static let rows: [Row] = [
        Row(name: "sealedForSleep", level: .notice) { $0.sealedForSleep() },
        Row(name: "declinedASealItsWakeAlreadyAnswered", level: .fault) {
            $0.declinedASealItsWakeAlreadyAnswered()
        },
        Row(name: "unsealedAfterWake", level: .notice) { $0.unsealedAfterWake() },
        Row(name: "evictedTombstone", level: .notice) {
            $0.evictedTombstone(connection, capacity: 8)
        },
        Row(name: "supervisorStopped", level: .notice) {
            $0.supervisorStopped(leasesOutstanding: 1)
        },
        Row(name: "granted", level: .notice) {
            $0.granted(connection, holder: "Aeolus.app", fans: fans, timeToLive: 30)
        },
        Row(name: "renewed", level: .debug) { $0.renewed(connection, timeToLive: 30) },
        Row(name: "restored", level: .notice) { $0.restored(fans: fans, because: .leaseExpired) },
        Row(name: "revoked", level: .fault) {
            $0.revoked(connection, fans: fans, because: .thermalEmergencyRevocation)
        },
        Row(name: "abandonedHandback", level: .fault) {
            $0.abandonedHandback(
                fanAt: 0, because: .leaseExpired, after: 3,
                error: FakeProviderError(description: "firmware refused"))
        },
        Row(name: "recoveredAbandonedHandback", level: .notice) {
            $0.recoveredAbandonedHandback(fans: fans)
        },
        Row(name: "abandonedHandbackAcceptedUnconfirmed", level: .notice) {
            $0.abandonedHandbackAcceptedUnconfirmed(fans: fans, because: .leaseExpired)
        },
        Row(name: "abandonedHandbackStillUnconfirmed", level: .notice) {
            $0.abandonedHandbackStillUnconfirmed(fans: fans)
        },
        Row(name: "refusedAbandonedHandback", level: .notice) {
            $0.refusedAbandonedHandback(connection, fans: fans)
        },
        Row(name: "restoredWithoutSafetyRegistries", level: .fault) {
            $0.restoredWithoutSafetyRegistries(fans: fans, because: .leaseExpired)
        },
        Row(name: "refusedMidHandback", level: .notice) {
            $0.refusedMidHandback(connection, fans: fans)
        },
        Row(name: "refusedLapsedExemption", level: .notice) {
            $0.refusedLapsedExemption(connection, fans: fans)
        },
        Row(name: "refusedUnconfirmedHandback", level: .notice) {
            $0.refusedUnconfirmedHandback(connection, fans: fans)
        },
        Row(name: "refusedThermalEmergency", level: .notice) {
            $0.refusedThermalEmergency(connection)
        },
        Row(name: "refusedInFlightBinding", level: .notice) {
            $0.refusedInFlightBinding(connection)
        },
        Row(name: "refusedNoWritePath", level: .info) { $0.refusedNoWritePath(connection) },
        Row(name: "refusedSelfRenewal", level: .info) { $0.refusedSelfRenewal(connection) },
        Row(name: "refusedForeignManualControl", level: .notice) {
            $0.refusedForeignManualControl(connection, fans: fans, reason: reason)
        },
        Row(name: "refusedBlindTelemetry", level: .fault) {
            $0.refusedBlindTelemetry(connection, detail: "no die reading")
        },
        Row(name: "refusedImplausibleBounds", level: .notice) {
            $0.refusedImplausibleBounds(connection, fan: 0, failure: .notMeasured, unread: nil)
        },
        Row(name: "refusedSystemSleeping", level: .notice) {
            $0.refusedSystemSleeping(connection)
        },
        Row(name: "refusedDuringMachineWideRestore", level: .notice) {
            $0.refusedDuringMachineWideRestore(connection)
        },
        Row(name: "refusedConcurrentLease", level: .info) { $0.refusedConcurrentLease(connection) },
    ]

    /// Every line is written exactly once, at the level it was written at before #560 moved
    /// them behind `emit`. A level is the difference between a line that persists and one that
    /// does not, and a `.fault` demoted to `.notice` says "this is routine" about something
    /// that is not.
    ///
    /// **Mutation:** in `LeaseLog.abandonedHandback`, change `.fault` to `.notice`. Run: red
    /// here, naming that row, and nowhere else.
    @Test("Every LeaseLog line is written once, at the level it has always had")
    func everyLineIsWrittenOnceAtItsLevel() {
        var wrong: [String] = []
        for row in Self.rows {
            let recorded = RecordedLeaseLines()
            row.write(
                LeaseLog(
                    subsystem: "dev.aeolus.AeolusHelperTests", category: "LeaseLevels",
                    recording: { recorded.append($0, $1) }))
            let levels = recorded.lines.map(\.level)
            if levels != [row.level] {
                wrong.append("\(row.name): wrote \(levels), not \(row.level)")
            }
        }
        #expect(wrong.isEmpty, "a line was not written once at its level: \(wrong)")
    }

    /// The table is every line. `emit(` is called once per line and nowhere else, so a line
    /// added without a row is a count that no longer matches.
    ///
    /// **Mutation:** add a method to `LeaseLog` that calls `emit(.info, "x")`. Run: red here
    /// alone.
    @Test("The level table has a row for every line LeaseLog writes")
    func theTableHasARowForEveryLine() throws {
        let calls = try LogSource.matches(
            of: #"\bemit\("#, in: try LogSource.stripped("Lease/LeaseLog.swift"))
        #expect(
            calls.count == Self.rows.count,
            "LeaseLog.swift calls emit \(calls.count) times; the table has \(Self.rows.count) rows")
        #expect(Set(Self.rows.map(\.name)).count == Self.rows.count, "a row name is repeated")
    }
}
