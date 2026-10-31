import Foundation
import Testing

@testable import AeolusHelper

/// § 3's telemetry holds the plane through a read-only role (#9's b2 checklist, from the sync's
/// review): `CuratedCriticalTemperatures` is generic over `CriticalTemperatureReading`, which
/// declares the curated read and the view and nothing that writes, so the compiler — not
/// `WriteVerbAllowlistTests`' lexical population — keeps the telemetry site from commanding a
/// fan whose plane holds the write channel.
///
/// What the compiler holds needs no runtime test; what this pins is that the constraint stays the
/// role. Read fail-closed: the role's requirements are exactly the two, and the telemetry's
/// generic clause is exactly the role.
@Suite("§ 3's telemetry holds a read-only role", .timeLimit(.minutes(1)))
struct TelemetryReadOnlyRoleTests {

    private static func code(of file: String) throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) was not found under Sources/")
        return SeamScanner.strippingAllComments(try String(contentsOf: url, encoding: .utf8))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// **Mutation:** declare `struct CuratedCriticalTemperatures<Plane: FanControlPlane>`. Run:
    /// red here.
    @Test("The telemetry is generic over the read role, which declares only the read and the view")
    func theTelemetryHoldsTheReadRole() throws {
        let code = try Self.code(of: "CriticalTemperatureSensing.swift")
        #expect(
            code.contains(
                "struct CuratedCriticalTemperatures<Plane: CriticalTemperatureReading>:"),
            "the telemetry is no longer generic over the read-only role")

        let start = try #require(code.range(of: "protocol CriticalTemperatureReading: Sendable {"))
        let body = try #require(code[start.upperBound...].range(of: "}"))
        let requirements = try SeamScanner.functions(
            inSource: String(code[start.upperBound..<body.lowerBound]), file: "role")
        #expect(
            Set(requirements.map(\.key)) == [
                "role: readCriticalTemperatures(_: [SMCKey])",
                "role: admitted(at: PlaneAdmission)",
            ], "\(requirements.map(\.key))")
    }
}
