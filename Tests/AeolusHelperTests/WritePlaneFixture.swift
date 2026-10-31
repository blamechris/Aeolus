import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The production write plane over `FirmwareSMC`: the real `SMCReadScheduler`, the real
/// `PlaneWriteLedger`, the real turn bodies, and only IOKit faked (the B1 plan's rule for every b2
/// test). The scheduler reports its turns into the fake's log, so an assertion can say where a
/// firmware operation fell relative to a turn and at which admission.
///
/// No real `SMCConnection` is anywhere in reach: the channel, the provider and the recycler are
/// the fake's three views of one set of registers.
struct WritePlaneFixture {

    let firmware: FirmwareSMC
    let scheduler: SMCReadScheduler
    let plane: SMCFanControlPlane
    let lines = RecordedLog()

    /// `Mac16,5` over `unlock`, with every fan in `stoppedByApple` in Apple's rest state: raw
    /// `F<n>Md = 3`, target and actual 0 (`FirmwareSMC.stopByApple(fan:)`).
    init(unlock: FirmwareSMC.Unlock = .naive, stoppedByApple: Set<Int> = []) {
        firmware = FirmwareSMC.mac16x5(unlock: unlock, stoppedByApple: stoppedByApple)
        scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        plane = SMCFanControlPlane(
            scheduler: scheduler, connection: firmware.recycler, channel: firmware,
            log: SafetyLog(recording: { [lines] in lines.append($0, $1) }))
    }

    /// The plane's one ledger, by reflection: it is `private`, as it should be.
    var ledger: PlaneWriteLedger {
        get throws {
            try #require(
                Mirror(reflecting: plane).children.first { $0.label == "ledger" }?.value
                    as? PlaneWriteLedger, "the plane stores no ledger")
        }
    }

    /// Runs the preparation step over `fans` as bring-up does, and returns the log's length after
    /// it, so a test reads only what followed.
    @discardableResult
    func prepared(fans: Set<Int> = [0, 1]) async -> Int {
        _ = await plane.prepareWritePath(enumerating: ScriptedFanEnumeration(indices: fans))
        return firmware.log.entries.count
    }

    /// Everything logged after `mark`.
    func entries(since mark: Int) -> [FirmwareLog.Entry] {
        Array(firmware.log.entries.dropFirst(mark))
    }

    /// The firmware operations logged after `mark`, without turns or hooks.
    func operations(since mark: Int) -> [FirmwareLog.Entry] {
        entries(since: mark).filter {
            switch $0 {
            case .keyInfo, .read, .write: return true
            default: return false
            }
        }
    }

    /// The writes logged after `mark`, as `key = bytes`.
    func writes(since mark: Int) -> [String] {
        operations(since: mark).compactMap {
            guard case .write(let key, let bytes, _) = $0 else { return nil }
            return "\(key.rawValue)=\(bytes.map { String($0) }.joined(separator: ","))"
        }
    }

    /// The fan's permit, over the bounds `mac16x5()` declares (1350 and 5777 RPM).
    static func fan(_ index: Int) throws -> CommandableFan {
        try commandableFan(index, declaring: .nominal)
    }

    /// One engagement the way the driver takes one: the ticket, then steps until it reads back.
    func engage(_ index: Int, steps: Int = 8) async throws {
        plane.beginEngagement(fanAt: index)
        for _ in 0..<steps {
            if try await plane.engageManualControl(of: Self.fan(index)) == .engaged { return }
        }
        Issue.record("fan \(index) did not engage in \(steps) steps")
    }

    /// Each scheduler turn logged after `mark`: its admission, and the firmware operations it held,
    /// so a test can count a turn's round trips and see which turn an operation fell in.
    func turns(since mark: Int) -> [(priority: SMCReadPriority, operations: [FirmwareLog.Entry])] {
        var turns: [(priority: SMCReadPriority, operations: [FirmwareLog.Entry])] = []
        var open: (priority: SMCReadPriority, operations: [FirmwareLog.Entry])?
        for entry in entries(since: mark) {
            switch entry {
            case .turnGranted(let priority):
                open = (priority, [])
            case .turnEnded:
                if let finished = open { turns.append(finished) }
                open = nil
            case .keyInfo, .read, .write:
                open?.operations.append(entry)
            default:
                break
            }
        }
        return turns
    }

    /// The round trips each turn after `mark` made — every operation that reached the firmware.
    func roundTripsPerTurn(since mark: Int) -> [Int] {
        turns(since: mark).map { $0.operations.filter(\.isRoundTrip).count }
    }
}

extension FirmwareLog.Entry {

    /// Whether this is a write.
    var isWrite: Bool {
        if case .write = self { return true }
        return false
    }

    /// Whether this is a read of a value — not key info.
    var isValueRead: Bool {
        if case .read = self { return true }
        return false
    }
}
