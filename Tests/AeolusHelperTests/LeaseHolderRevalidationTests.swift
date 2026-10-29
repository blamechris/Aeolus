import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `LeaseAuthority.acquireLease` checks the holder's description itself, on a build that can
/// write, whatever the caller before it has already checked (#569).
///
/// The check is `AeolusXPCValidation.validateHolderDescription` in `acquireLease`, after the
/// TTL's and before the first suspension point. Today unchecked text cannot reach it:
/// `HelperConnectionSession` validates first, and a shipping build refuses at
/// `refuseIfWritePathNotBuilt` before either. It is still the guard that keeps client-chosen
/// text out of a granted lease and out of the log line that names its holder, for a caller that
/// reaches the authority from the control plane and not from a message. Until this suite, the
/// reviewer of #563 deleted it and every test in the target stayed green.
///
/// The authority is built the way every lease test builds it: `LeaseFixture.authority`, whose
/// write capability is a scripted plane that answers `.built`. The log is a `LeaseLog` with a
/// recording sink (#560), so "no line names the holder" is read from the lines themselves.
@Suite("LeaseAuthority re-validates the holder description itself")
struct LeaseHolderRevalidationTests {

    /// A phrase no other line `LeaseLog` writes can contain, so a line that has it names the
    /// holder. It sits beside the hostile scalar in the description, and `LogText` escapes the
    /// scalar and leaves this alone: the marker is what survives into a line, not the scalar.
    private static let marker = "HOLDER-MARKER-9c41"

    /// One scalar from each of the four categories of `FaultText.isRemovedFromDisplay`: Zl and
    /// Zp, which `CharacterSet.controlCharacters` let through until #483, and Cc and Cf.
    struct HostileScalar: Sendable, CustomTestStringConvertible {
        let name: String
        let scalar: String

        var testDescription: String { name }

        static let all = [
            HostileScalar(name: "U+2028 LINE SEPARATOR (Zl)", scalar: "\u{2028}"),
            HostileScalar(name: "U+2029 PARAGRAPH SEPARATOR (Zp)", scalar: "\u{2029}"),
            HostileScalar(name: "U+000A LINE FEED (Cc)", scalar: "\u{000A}"),
            HostileScalar(name: "U+202E RIGHT-TO-LEFT OVERRIDE (Cf)", scalar: "\u{202E}"),
        ]
    }

    /// An authority over a plane that can write, whose lease lines land in `lines`.
    private static func authority(recordingInto lines: RecordedLeaseLines) -> LeaseAuthority {
        LeaseFixture.authority(
            writeCapability: LeaseFixture.writePathBuilt(),
            log: LeaseLog(
                subsystem: "dev.aeolus.AeolusHelperTests", category: "Lease",
                recording: { lines.append($0, $1) }))
    }

    /// A hostile holder reaches `acquireLease` directly and is refused by name, with no lease
    /// in the table and no line that names it.
    ///
    /// Three observations, and each is what a grant would have changed: the refusal, the table,
    /// and the `granted` line, which quotes the holder at `notice`.
    /// `aCleanHolderIsGrantedAndLogged` below shows all three are visible, so their absence here
    /// is a result and not a seam that sees nothing.
    ///
    /// **Mutation (#569):** delete `try AeolusXPCValidation.validateHolderDescription(
    /// request.holderDescription)` from `LeaseAuthority.acquireLease`. Run: red on the refusal,
    /// on `leaseCount == 0`, on `activeLease() == nil` and on the log lines, for every row. Nothing
    /// else in `AeolusHelperTests` is red.
    @Test(
        "A hostile holder is refused, holds no lease, and is named in no log line",
        arguments: HostileScalar.all)
    func aHostileHolderIsRefusedAtTheAuthority(_ hostile: HostileScalar) async {
        let lines = RecordedLeaseLines()
        let authority = Self.authority(recordingInto: lines)
        let request = LeaseFixture.request(
            fans: [0], holder: "\(Self.marker)\(hostile.scalar)forged")

        await #expect {
            _ = try await authority.acquireLease(request, from: ConnectionID())
        } throws: { error in
            guard case .invalidParameter(let name, _) = error as? AeolusXPCFault else {
                return false
            }
            return name == "holderDescription"
        }

        #expect(await authority.leaseCount == 0, "a lease was created for a hostile holder")
        #expect(await authority.activeLease() == nil, "a hostile holder's lease is active")
        #expect(
            lines.levels(containing: Self.marker).isEmpty,
            "a log line names the refused holder: \(lines.lines.map(\.text))")
    }

    /// The control: the same request with a holder that carries none of the four categories is
    /// granted, held, and named at `notice`. It is what makes the absences above able to fail.
    ///
    /// **Mutation:** in `LeaseLog.granted`, drop `holder` from the line. Run: red on the line's
    /// level; the refusal rows above stay green, as they should, since they assert an absence.
    @Test("The same request with a clean holder is granted, held and named in the log")
    func aCleanHolderIsGrantedAndLogged() async throws {
        let lines = RecordedLeaseLines()
        let authority = Self.authority(recordingInto: lines)
        let request = LeaseFixture.request(fans: [0], holder: "\(Self.marker) forged")

        let lease = try await authority.acquireLease(request, from: ConnectionID())

        #expect(lease.holderDescription == "\(Self.marker) forged")
        #expect(await authority.leaseCount == 1)
        #expect(await authority.activeLease() != nil)
        #expect(lines.levels(containing: Self.marker) == [.notice])
    }
}
