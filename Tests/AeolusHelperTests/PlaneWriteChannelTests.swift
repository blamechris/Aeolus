import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The production plane holds an optional write channel, and on this build uses it for nothing
/// (ADR 0014's B1 amendment): `writeCapability` stays `.notBuilt`, every write verb still refuses
/// without touching the channel, and the fact that a channel is held is surfaced nowhere.
///
/// The channel here is `FirmwareSMC`, the one channel a test may give a plane.
@Suite("The plane holds a write channel and uses it for nothing", .timeLimit(.minutes(1)))
struct PlaneWriteChannelTests {

    private static func plane(channel: (any SMCWriteChannel)?) -> SMCFanControlPlane {
        SMCFanControlPlane(
            scheduler: SMCReadScheduler(provider: FirmwareSMC.mac16x5().provider),
            connection: InertSMCConnection(), channel: channel)
    }

    @Test("A plane given no channel holds none, and is not built")
    func aPlaneGivenNoChannelHoldsNone() {
        let plane = SMCFanControlPlane(
            scheduler: SMCReadScheduler(provider: FirmwareSMC.mac16x5().provider),
            connection: InertSMCConnection())
        #expect(!plane.holdsWriteChannel)
        #expect(plane.writeCapability == .notBuilt)
    }

    /// **Mutation:** make `writeCapability` follow `holdsWriteChannel`. Run: red.
    @Test("A plane given a channel holds it, is still not built, and touches it for nothing")
    func aPlaneGivenAChannelStillCannotWrite() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let plane = Self.plane(channel: firmware)

        #expect(plane.holdsWriteChannel)
        #expect(plane.writeCapability == .notBuilt, "a held channel is not a write path")
        await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(
            await plane.prepareWritePath(enumerating: ScriptedFanEnumeration(indices: [0])) == nil)
        #expect(
            firmware.log.operations.isEmpty,
            "the plane reached its channel: \(firmware.log.entries)")
    }

    // MARK: - At the source

    private static func code(of file: String) throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) was not found under Sources/")
        return WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(try String(contentsOf: url, encoding: .utf8)))
    }

    /// What "nothing uses it" means on this build, at the one holder: the stored channel is named
    /// in its declaration, the initialiser's assignment and `holdsWriteChannel`, and nowhere else.
    /// The change that gives the write verbs bodies replaces this pin with its turns' own.
    ///
    /// **Mutation:** read the channel in `restoreToAutomatic(_:)`. Run: red.
    @Test("The plane names its stored channel only to store it and to say it holds one")
    func theHeldChannelIsReadByNothingElse() throws {
        let code = try Self.code(of: "SMCFanControlPlane.swift")
        let named = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])writeChannel(?![A-Za-z0-9_])"#
        )
        .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
        #expect(
            named == 3,
            """
            SMCFanControlPlane.swift names its write channel \(named) times, not 3 (the \
            declaration, the assignment, holdsWriteChannel). Nothing on this build may use it: \
            no write turn exists and the plane answers .notBuilt.
            """)
    }

    /// **Mutation:** read `holdsWriteChannel` in `AeolusHelperMain`'s listening line. Run: red.
    @Test("Whether a channel is held is surfaced nowhere in Sources")
    func holdsWriteChannelIsSurfacedNowhere() throws {
        var naming: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let code = WriteSeamTestIsolationTests.strippingStringLiterals(
                SeamScanner.strippingAllComments(try String(contentsOf: file, encoding: .utf8)))
            if code.contains("holdsWriteChannel") { naming.append(file.lastPathComponent) }
        }
        #expect(
            naming == ["SMCFanControlPlane.swift"],
            """
            holdsWriteChannel is named in \(naming). It is a fact for tests: reported over XPC, in \
            a snapshot or a log line it would claim a write path nothing implements.
            """)
    }
}
