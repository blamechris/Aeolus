import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The production plane's write capability is what it holds (ADR 0014's B1 amendment): `.built`
/// exactly when it holds a write channel, `.notBuilt` and touching nothing when it holds none, and
/// every use of the held channel the channel argument of one write turn at the plane's admission
/// (#9's b2 checklist, from the sync's review).
///
/// The channel here is `FirmwareSMC`, the one channel a test may give a plane.
@Suite("The plane's write capability is the channel it holds", .timeLimit(.minutes(1)))
struct PlaneWriteChannelTests {

    private static func plane(channel: (any SMCWriteChannel)?) -> SMCFanControlPlane {
        SMCFanControlPlane(
            scheduler: SMCReadScheduler(provider: FirmwareSMC.mac16x5().provider),
            connection: InertSMCConnection(), channel: channel)
    }

    /// C1's first arm: no channel, `.notBuilt`, and every write verb refuses with nothing read,
    /// nothing written, and no restore requested — main's channel-less plane, unchanged.
    ///
    /// **Mutation:** make `writeCapability` the constant `.built`. Run: red here.
    @Test("A plane given no channel is not built, and every write verb refuses touching nothing")
    func aPlaneGivenNoChannelIsNotBuilt() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let plane = SMCFanControlPlane(
            scheduler: SMCReadScheduler(provider: firmware.provider),
            connection: InertSMCConnection())
        let fan = try commandableFan(0, declaring: .nominal)

        #expect(!plane.holdsWriteChannel)
        #expect(plane.writeCapability == .notBuilt)
        await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
            try await plane.restoreToAutomatic(.everyFan)
        }
        plane.beginEngagement(fanAt: 0)
        await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
            try await plane.engageManualControl(of: fan)
        }
        await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
            try await plane.commandTarget(fan.target(for: 2_000))
        }
        let bridge = await plane.bridgeThenRestore(fan.target(for: 5_777))
        #expect(throws: FanControlPlaneError.controlPathNotBuilt) { try bridge.maximum.get() }
        #expect(throws: FanControlPlaneError.controlPathNotBuilt) { try bridge.restore.get() }
        #expect(
            await plane.prepareWritePath(enumerating: ScriptedFanEnumeration(indices: [0])) == nil)
        #expect(firmware.log.entries.isEmpty, "the plane reached the SMC: \(firmware.log.entries)")
    }

    /// C1's second arm: a plane given a channel is `.built`, and a restore through it reaches the
    /// channel — the capability and the verbs answer from the same fact.
    ///
    /// **Mutation:** make `writeCapability` the constant `.notBuilt`. Run: red here.
    @Test("A plane given a channel is built, and its restore reaches that channel")
    func aPlaneGivenAChannelIsBuilt() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let plane = Self.plane(channel: firmware)

        #expect(plane.holdsWriteChannel)
        #expect(plane.writeCapability == .built)
        try await plane.restoreToAutomatic(.fan(0))
        #expect(firmware.log.operations == [.write(smcKey("F0Md"), [0x00], .answered)])
    }

    // MARK: - At the source

    private static func code(of file: String) throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) was not found under Sources/")
        return WriteSeamTestIsolationTests.strippingStringLiterals(
            SeamScanner.strippingAllComments(try String(contentsOf: url, encoding: .utf8)))
    }

    /// `code` with every run of whitespace collapsed to one space, so a shape reads the same
    /// however the formatter wraps it.
    private static func collapsed(_ code: String) -> String {
        code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ pattern: String, in code: String) throws -> Int {
        try NSRegularExpression(pattern: pattern)
            .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// The shapes the plane may name its stored channel in, and how many of each: its declaration,
    /// its assignment, `holdsWriteChannel`, and — once per write verb — the unwrap and the channel
    /// argument of that verb's one write turn, at the plane's own `admission`.
    static let channelShapes: [(shape: String, count: Int)] = [
        (#"private let writeChannel: \(any SMCWriteChannel\)\?"#, 1),
        (#"self\.writeChannel = channel"#, 1),
        (#"var holdsWriteChannel: Bool \{ writeChannel != nil \}"#, 1),
        (#"guard let writeChannel else"#, writeVerbs),
        (#"scheduler\.withWriteTurn\(at: admission, on: writeChannel\)"#, writeVerbs),
    ]

    /// The verbs that take a write turn: the restore, the step, the command, the bridge, and the
    /// preparation step's reads.
    static let writeVerbs = 5

    /// **Every use of the stored channel is the channel argument of exactly one write turn, taken
    /// at `self.admission`** (#9's b2 checklist). Read fail-closed: each permitted shape is counted
    /// and removed, and any mention left over — any other way of reaching the channel — fails, as
    /// does a write turn taken at any admission but the plane's own, or a write turn whose channel
    /// is anything else.
    ///
    /// **Mutations:** in `SMCFanControlPlane.restoreToAutomatic(_:)`, take the turn at
    /// `.supervisor`; and, separately, read `writeChannel` into a local before the turn. Run: red
    /// here, each.
    @Test("Every use of the stored channel is one write turn's argument at the plane's admission")
    func everyUseOfTheChannelIsOneTurnsArgument() throws {
        var code = Self.collapsed(try Self.code(of: "SMCFanControlPlane.swift"))
        #expect(
            try Self.count(#"withWriteTurn\("#, in: code) == Self.writeVerbs,
            "the plane takes a write turn somewhere other than its five write verbs")
        for (shape, expected) in Self.channelShapes {
            let found = try Self.count(shape, in: code)
            #expect(found == expected, "`\(shape)` appears \(found) times, not \(expected)")
            code = try NSRegularExpression(pattern: shape).stringByReplacingMatches(
                in: code, range: NSRange(code.startIndex..., in: code), withTemplate: "◊")
        }
        let leftOver = try Self.count(#"(?<![A-Za-z0-9_])writeChannel(?![A-Za-z0-9_])"#, in: code)
        #expect(
            leftOver == 0,
            """
            SMCFanControlPlane.swift names its write channel \(leftOver) more time(s) than its \
            declaration, its assignment, holdsWriteChannel, and each verb's unwrap and write turn. \
            A channel used outside a write turn is a write no turn admits.
            """)
    }

    /// A view is the plane with its admission changed and nothing else: `var view = self` (#9's
    /// b2 checklist). Rebuilding one through `init` drops the channel and the ledger at every lane
    /// site, which `PlaneViewTests+WriteChannel.swift` catches behaviourally; this holds the shape.
    ///
    /// **Mutation:** start `admitted(at:)`'s view from `SMCFanControlPlane(scheduler: scheduler,
    /// connection: connection)`. Run: red here (and at the lane-site scan).
    @Test("A view of the plane is a copy of it with the admission changed")
    func aViewIsACopyOfThePlane() throws {
        let code = Self.collapsed(try Self.code(of: "SMCFanControlPlane.swift"))
        let shape =
            #"func admitted\(at admission: PlaneAdmission\) -> SMCFanControlPlane \{ "#
            + #"var view = self view\.admission = admission return view \}"#
        #expect(try Self.count(shape, in: code) == 1, "admitted(at:) is not `var view = self`")
    }

    /// **Mutation:** read `holdsWriteChannel` in `AeolusHelperMain`'s listening line. Run: red.
    @Test("Whether a channel is held is surfaced nowhere in Sources but the plane")
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
            holdsWriteChannel is named in \(naming). It is the fact writeCapability answers from, \
            and a fact for tests: reported anywhere else it would be a second spelling of the \
            capability that could come to disagree with it.
            """)
    }
}
