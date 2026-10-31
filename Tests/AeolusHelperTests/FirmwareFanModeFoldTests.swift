import Testing

@testable import AeolusHelper

/// The fold of raw `F<n>Md`, D3's pre-state and the engaged value, as the P1′ amendment decides
/// them ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md);
/// [#633](https://github.com/blamechris/Aeolus/issues/633)).
///
/// Apple's management is a set of raw values, `{0, 3}`: P1 recorded `0` while Apple spun a fan and
/// `3` while it had one stopped, and nothing else. The fold calls exactly those bytes automatic;
/// the pre-state admits exactly what the fold calls automatic; and the value an engagement writes
/// stays outside the set, so a read-back of it is the plane's own write.
///
/// Every byte is asked, not a sample of them: a set that gained a member, or a fold that went back
/// to `!= 0`, changes the answer for some byte, and a table of all 256 cannot miss which.
@Suite("Apple's raw modes, the fold, the pre-state and the engaged value")
struct FirmwareFanModeFoldTests {

    /// What the P1′ amendment says each byte is.
    private static func isApplesValue(_ byte: UInt8) -> Bool { byte == 0 || byte == 3 }

    // MARK: - The fold

    /// **Mutation:** in `FirmwareFanMode(rawByte:)`, fold as before P1′,
    /// `self = rawByte == 0 ? .automatic : .manual`. Run: red on byte 3 here, on `3.0` in
    /// `theIssuesTable`, and on byte 3 in `thePreStateAdmitsExactlyApplesSet`, with every
    /// consumer case in `AppleStoppedFanTests`. `aDecodedValueFoldsAsItsByte` stays green under it,
    /// because both of its sides answer through this initialiser.
    @Test("A raw byte is automatic exactly when it is 0 or 3, Apple's own values")
    func everyByteFoldsAsTheAmendmentSays() {
        for byte in UInt8.min...UInt8.max {
            #expect(
                FirmwareFanMode(rawByte: byte) == (Self.isApplesValue(byte) ? .automatic : .manual),
                "raw F<n>Md = \(byte)")
        }
    }

    /// The decoded value folds exactly as its byte does, for every byte: the snapshot's read and
    /// the plane's, which decode a `ui8` to a `Double`, cannot disagree with D3's raw pre-state.
    ///
    /// **Mutation:** in `init(declaredByFirmware:)`, fold as before P1′ without going through
    /// `init(rawByte:)` — `self = value == 0 ? .automatic : .manual`. Run: red on byte 3 here
    /// and on `3.0` in `theIssuesTable`, with every consumer case in `AppleStoppedFanTests` but
    /// the engagement's, which reads the raw byte; the pre-state table stays green.
    @Test("A decoded value that is exactly a byte folds as that byte")
    func aDecodedValueFoldsAsItsByte() {
        for byte in UInt8.min...UInt8.max {
            #expect(
                FirmwareFanMode(declaredByFirmware: Double(byte)) == FirmwareFanMode(rawByte: byte),
                "F<n>Md decoded to \(byte)")
        }
    }

    /// Anything that is not exactly a byte is manual: a fraction near either of Apple's values,
    /// a value outside a byte, and a value that is not finite. Rounding first would read `0.4`
    /// as Apple's `0` and `3.0000001` as Apple's `3`, which is the asymmetry the fold refuses.
    ///
    /// **Mutation:** in `init(declaredByFirmware:)`, round before the exact conversion —
    /// `guard value.isFinite, let byte = UInt8(exactly: value.rounded())`. Run: red on `0.4`,
    /// `3.0000001`, `2.9999999` and `.ulpOfOne`.
    @Test(
        "A value that is not exactly a byte is manual",
        arguments: [
            0.4, 3.0000001, 2.9999999, -3, 256, 1e14, Double.nan, .infinity, -.infinity,
            .ulpOfOne,
        ])
    func aValueThatIsNotExactlyAByteIsManual(_ value: Double) {
        #expect(FirmwareFanMode(declaredByFirmware: value) == .manual)
    }

    /// The bytes the issue names, by value, so a reader of #633's acceptance finds them here.
    @Test(
        "The issue's table: 0 and 3 are automatic, and 1, 2 and 255 are manual",
        arguments: [(0.0, true), (3.0, true), (1.0, false), (2.0, false), (255.0, false)])
    func theIssuesTable(_ value: Double, isAutomatic: Bool) {
        #expect(
            FirmwareFanMode(declaredByFirmware: value) == (isAutomatic ? .automatic : .manual))
    }

    /// The production plane's own read folds every byte as `init(rawByte:)` does:
    /// `SMCFanControlPlane.readControlState(ofFan:)`, through its private decode, over a provider
    /// answering each byte in turn. The tables above call the initialisers directly, so they could
    /// not see the plane's decode spelt a second way.
    ///
    /// **Mutation:** in `SMCFanControlPlane.mode(from:)`, decode as before P1′,
    /// `value == 0 ? .automatic : .manual`. Run: red here on byte 3, on both assertions, and
    /// nowhere else in the suite: every other reader of the plane's decode is a double.
    @Test("The production plane's read folds every byte as the amendment says")
    func theProductionPlaneFoldsEveryByte() async throws {
        for byte in UInt8.min...UInt8.max {
            let plane = supervisorPlane(
                over: FakeSensorProvider(keyedResults: [
                    "F0Md": .reading("F0Md", Double(byte)),
                    "F0Tg": .reading("F0Tg", 0),
                ]))

            let state = try await plane.readControlState(ofFan: 0)

            #expect(state.mode == FirmwareFanMode(rawByte: byte), "raw F<n>Md = \(byte)")
            #expect(state.mode == (Self.isApplesValue(byte) ? .automatic : .manual))
        }
    }

    // MARK: - The engaged value

    /// The value an engagement writes is outside Apple's set, and is the only value that reads as
    /// engaged. D3 step 2 attributes a read-back of it to the plane's own write only because
    /// Apple's management never produces it; a set that held it would let Apple's state confirm an
    /// engagement that never happened.
    ///
    /// **Mutation:** add `1` to `FirmwareFanMode.systemManagedRawModes`. Run: red here on the set
    /// and the fold of `1`, and in the fold's and the pre-state's tables.
    @Test("The engaged value is outside Apple's set, and the only value that reads as engaged")
    func theEngagedValueIsDisjointFromApplesSet() {
        #expect(EngagementRules.engagedRawMode == 1, "U4: the value D3 writes is the reported 1")
        #expect(
            FirmwareFanMode.systemManagedRawModes.contains(EngagementRules.engagedRawMode) == false)
        #expect(FirmwareFanMode(rawByte: EngagementRules.engagedRawMode) == .manual)
        for byte in UInt8.min...UInt8.max {
            #expect(
                EngagementRules.isEngagedMode(byte) == (byte == EngagementRules.engagedRawMode),
                "raw F<n>Md = \(byte)")
        }
    }

    // MARK: - D3 step 1's pre-state

    /// The pre-state admits exactly what the fold calls automatic, so a fan the grant read as
    /// automatic is never refused `.notAutomatic`, and the reverse. `3`, Apple's stopped fan, is
    /// admitted; `1`, and every byte outside the set, is refused with the byte it read.
    ///
    /// **Mutation:** in `EngagementRules.requireAutomatic`, admit `1` as well —
    /// `guard FirmwareFanMode(rawByte: rawMode) == .automatic || rawMode == 1`. Run: red on byte 1.
    /// **Mutation:** restore the pre-P1′ guard, `guard rawMode == 0`. Run: red on byte 3, and on
    /// every engagement of a fan Apple has stopped (`AppleStoppedFanTests`,
    /// `EngagedTargetRuleTests`).
    @Test("D3's pre-state admits 0 and 3, and refuses every other byte with what it read")
    func thePreStateAdmitsExactlyApplesSet() {
        for byte in UInt8.min...UInt8.max {
            if Self.isApplesValue(byte) {
                #expect(throws: Never.self, "raw F<n>Md = \(byte)") {
                    try EngagementRules.requireAutomatic(rawMode: byte, fanAt: 1)
                }
            } else {
                #expect(
                    throws: FanControlPlaneError.notAutomatic(index: 1, rawMode: byte),
                    "raw F<n>Md = \(byte)"
                ) {
                    try EngagementRules.requireAutomatic(rawMode: byte, fanAt: 1)
                }
            }
        }
    }
}
