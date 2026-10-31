import Foundation
import os

@testable import AeolusHelper
@testable import SMCCore

/// Everything a `FirmwareSMC` did, in order, and every turn the scheduler over it granted: one
/// lock-guarded list, so an assertion can say where an operation fell **relative to a turn**.
///
/// It is the scheduler's observer as well (`SMCReadScheduler(provider:observer:)`), and the
/// scheduler reports synchronously from inside the turn it describes, so a turn event and the
/// firmware operations around it land in the order they happened. `SchedulerObserving` asks a
/// conformer to return promptly; appending under an unfair lock does.
final class FirmwareLog: SchedulerObserving, Sendable {

    /// How one operation was answered.
    enum Answer: Sendable, Equatable {
        /// Result byte `0x00`.
        case answered
        /// The round trip was made, and ended in this.
        case threw(SMCError)
        /// Refused before any round trip: nothing reached the firmware.
        case unsent(SMCError)

        /// Whether a round trip was made — what `WatchdogLimits.writeTurnRoundTrips` counts.
        var madeARoundTrip: Bool {
            if case .unsent = self { return false }
            return true
        }
    }

    /// One thing that happened.
    enum Entry: Sendable, Equatable {
        case keyInfo(SMCKey, Answer)
        case read(SMCKey, Answer)
        case write(SMCKey, [UInt8], Answer)
        case hookFired(FirmwareSMC.Operation)
        case afterHookFired(FirmwareSMC.Operation)
        case providerReadBegan([String])
        case providerReadEnded
        case walkBegan
        case walkEnded
        case closed
        case opened
        case turnGranted(SMCReadPriority)
        case turnEnded(SMCReadPriority)

        /// Whether this is a firmware operation that made a round trip.
        var isRoundTrip: Bool {
            switch self {
            case .keyInfo(_, let answer), .read(_, let answer), .write(_, _, let answer):
                return answer.madeARoundTrip
            default:
                return false
            }
        }
    }

    /// Where an operation was made, waiting for its answer.
    enum Site: Sendable {
        case keyInfo(SMCKey)
        case read(SMCKey)
        case write(SMCKey, [UInt8])

        func entry(_ answer: Answer) -> Entry {
            switch self {
            case .keyInfo(let key): return .keyInfo(key, answer)
            case .read(let key): return .read(key, answer)
            case .write(let key, let bytes): return .write(key, bytes, answer)
            }
        }
    }

    private let recorded = OSAllocatedUnfairLock<[Entry]>(initialState: [])

    var entries: [Entry] { recorded.withLock { $0 } }

    /// The firmware operations alone, without turns, hooks or the views' brackets.
    var operations: [Entry] {
        entries.filter {
            switch $0 {
            case .keyInfo, .read, .write: return true
            default: return false
            }
        }
    }

    func record(_ entry: Entry) {
        recorded.withLock { $0.append(entry) }
    }

    func schedulerDidObserve(_ event: SchedulerEvent) {
        switch event {
        case .turnGranted(let priority, _): record(.turnGranted(priority))
        case .turnEnded(let priority): record(.turnEnded(priority))
        default: break
        }
    }
}

// MARK: - The views

extension FirmwareSMC {

    /// The reading half of the same firmware, as the `SensorProvider` a scheduler reads through.
    struct Provider: SensorProvider {
        static let identifier = "firmware-smc"

        let firmware: FirmwareSMC

        var identifier: String { Self.identifier }

        var isAvailable: Bool {
            get async { true }
        }

        func readAll() async throws -> [SensorReading] {
            await firmware.walk()
        }

        func read(keys: [String]) async throws -> [SensorReadOutcome] {
            await firmware.providerRead(keys)
        }
    }

    /// The lifecycle half of the same firmware, as the two verbs a reconnect needs.
    struct Recycler: SMCConnectionRecycling {
        let firmware: FirmwareSMC

        func close() async { await firmware.close() }

        func open() async throws { await firmware.open() }
    }

    nonisolated var provider: Provider { Provider(firmware: self) }

    nonisolated var recycler: Recycler { Recycler(firmware: self) }
}

// MARK: - The development machine

extension FirmwareSMC {

    /// `Mac16,5`, from what the repository records and nothing else: the key table as observed on
    /// macOS 27.0.1 (26A434), and register bytes from 26.5.2 and 26.6.2 where 27.0.1 recorded a
    /// range rather than bytes. Each value names where, and on which release, it was observed; the
    /// sections are `docs/SMC-RESEARCH.md`'s unless another file is named. Vary a key or a register
    /// with `declare(_:_:)` and `setRegister(_:_:)`, and build `flt` bytes with `flt(rpm:)`.
    ///
    /// - `F0Md`, `F1Md`, `Ftst`: `ui8`, size 1, attributes `0xD0`, register `00` — the table in
    ///   "Mode keys and `Ftst` re-checked on macOS 27.0.1".
    /// - `F0Mn`, `F1Mn`: `flt`, `0x84`, `00c0a844` (1350 RPM); `F0Mx`, `F1Mx`: `flt`, `0x85`,
    ///   `0088b445` (5777 RPM) — the same table, and the line under it for fan 1.
    /// - `F0Tg`, `F1Tg`: `flt`, `0xD4` — the line under that table. Their bytes, `00c0a844` and
    ///   `0040b644` (1350 and 1458 RPM), are the 2026-09-06 `fanctl dump` in "The fans stop in
    ///   sleep and dark wake" (26.6.2).
    /// - `F0Ac`: `flt`, `0x84` — the 27.0.1 table, which records a range and not bytes; the bytes,
    ///   `57e2a744` (1343.07 RPM), are "Fan topology and the `Ftst` key" (26.5.2).
    /// - `F1Ac`: `flt`, `0x84` — `docs/ARCHITECTURE.md`'s byte-order note, which gives `F1Ac` as
    ///   132; the bytes, `383eb644` (1457.94 RPM), are "Fan topology" (26.5.2).
    /// - `FNum`: `ui8`, size 1 — `docs/ARCHITECTURE.md`'s byte-order note; register `02`, the
    ///   value on all 10,570 ticks of the 26.6.2 lid-close capture. Its attribute byte is **not
    ///   recorded**, so it carries only `0x80`, the readable bit every key that read has ("The
    ///   attribute byte").
    ///
    /// The interface generation is `.modern`: `IOProviderClass` `RTBuddyEndpointService`, observed
    /// on this machine ("Interface generation, detected from IORegistry provenance"). No key is
    /// absent, because no absent key's answer is recorded; a scenario that needs one scripts it.
    ///
    /// Every fan in `stoppedByApple` starts in Apple's rest state instead (`stopByApple(fan:)`):
    /// raw `F<n>Md = 3`, target and actual 0, as P1 recorded it on macOS 27.2.
    static func mac16x5(unlock: Unlock = .naive, stoppedByApple: Set<Int> = []) -> FirmwareSMC {
        var keys: [SMCKey: Key] = [:]
        var registers: [SMCKey: [UInt8]] = [:]
        func declare(_ raw: String, _ type: SMCKeyType, _ attributes: UInt8, _ bytes: [UInt8]) {
            let key = smcKey(raw)
            keys[key] = .present(
                SMCKeyInfo(key: key, type: type, dataSize: bytes.count, attributes: attributes))
            registers[key] = bytes
        }
        for fan in 0...1 {
            declare("F\(fan)Md", .ui8, 0xD0, [0x00])
            declare("F\(fan)Mn", .flt, 0x84, [0x00, 0xC0, 0xA8, 0x44])
            declare("F\(fan)Mx", .flt, 0x85, [0x00, 0x88, 0xB4, 0x45])
        }
        declare("F0Tg", .flt, 0xD4, [0x00, 0xC0, 0xA8, 0x44])
        declare("F1Tg", .flt, 0xD4, [0x00, 0x40, 0xB6, 0x44])
        declare("F0Ac", .flt, 0x84, [0x57, 0xE2, 0xA7, 0x44])
        declare("F1Ac", .flt, 0x84, [0x38, 0x3E, 0xB6, 0x44])
        declare("Ftst", .ui8, 0xD0, [0x00])
        declare("FNum", .ui8, 0x80, [0x02])
        for fan in stoppedByApple {
            for (key, bytes) in restState(ofFan: fan) { registers[key] = bytes }
        }
        return FirmwareSMC(keys: keys, registers: registers, generation: .modern, unlock: unlock)
    }

    /// Apple's controller has fan `index` stopped, as P1 recorded it on `Mac16,5` under macOS 27.2
    /// (ADR 0014's P1′ amendment; `docs/SMC-RESEARCH.md`'s P1 section): raw `F<n>Md = 3`, `F<n>Tg`
    /// 0 and `F<n>Ac` 0 — this machine's rest state, and the bytes of the scripted plane's
    /// `FanCondition.stoppedByApple`. Set as the firmware sets them: no write is answered and
    /// nothing is logged.
    func stopByApple(fan index: Int) {
        for (key, bytes) in Self.restState(ofFan: index) { setRegister(key, bytes) }
    }

    /// Apple's controller spinning fan `index` with its target at `rpm`: raw `F<n>Md = 0`, and
    /// `F<n>Tg` and `F<n>Ac` at `rpm` (P1's sixteen-way plateau was 3455 and 3731). Set as
    /// `stopByApple(fan:)` sets its bytes.
    func spinByApple(fan index: Int, at rpm: Float) {
        setRegister(smcKey("F\(index)Md"), [0x00])
        setRegister(smcKey("F\(index)Tg"), Self.flt(rpm: rpm))
        setRegister(smcKey("F\(index)Ac"), Self.flt(rpm: rpm))
    }

    /// Apple's rest state for fan `index`, as register bytes.
    private static func restState(ofFan index: Int) -> [SMCKey: [UInt8]] {
        [
            smcKey("F\(index)Md"): [0x03], smcKey("F\(index)Tg"): flt(rpm: 0),
            smcKey("F\(index)Ac"): flt(rpm: 0),
        ]
    }

    /// The `flt` bytes a `.modern` register holds for `rpm`: an IEEE 754 single, least significant
    /// byte first, as `mac16x5()`'s recorded fan bytes are (`00c0a844` is 1350). Built here, not by
    /// `SMCKeyType.encode(scalar:byteOrder:)`, which is SPI and which no test file outside
    /// `WriteSeamTestIsolationTests.allowedImporters` may name.
    static func flt(rpm: Float) -> [UInt8] {
        withUnsafeBytes(of: rpm.bitPattern.littleEndian) { Array($0) }
    }
}
