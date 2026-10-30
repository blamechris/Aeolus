import FanKit
import Foundation

/// The sensor-key half of `AeolusXPCValidation`: what a curve in an `apply` payload may name as
/// the sensors that drive it (#566).
///
/// Its own file for the reason `AeolusXPCHandshakeValidation.swift` is one:
/// `AeolusXPCValidation.swift` sits at this repository's 400-line limit.
///
/// ## Shape, not membership
///
/// A key is accepted here when it has the shape of an SMC key, and this machine is not asked
/// whether it has that sensor:
///
/// - **Which keys exist is hardware state.** The SMC's own index table says, and reading it
///   belongs to whatever owns the enumeration, not to this pure module (`FanAuthority` records
///   the split). A curve's keys are read when the curve is evaluated (#17), and a key this
///   machine lacks is answered there by the firmware, as `SensorReadFailure.unknownKey`.
/// - **The catalog cannot be the set.** It only decorates (`docs/ARCHITECTURE.md`): a machine
///   with no catalog entries works completely, so refusing an uncatalogued key would leave every
///   sensor on a Mac nobody has catalogued unusable by a curve. The helper does not load it.
/// - **One alphabet serves every machine** (`CLAUDE.md` rule 9). An SMC key is a four-character
///   code on Intel and Apple Silicon alike, so nothing here branches on the architecture, and
///   nothing narrows to the keys the one tested machine happens to use.
///
/// ## The alphabet: ASCII, less what the display rule removes
///
/// This admits the scalars for which `FaultText.isRemovedFromDisplay` is false and that are
/// ASCII, which is U+0020 to U+007E: the one rule the description fields are refused by (#483),
/// narrowed to what an SMC key is written in. A key is client-chosen text that a root daemon
/// will read, and later log and show beside a reading, so it is held to the shared rule; and it
/// names a four-byte code, so it is held to ASCII. Space is admitted, because `FS! `, Intel's
/// force bitmask, has one. On `Mac16,5` (macOS 27.2) all 3,514 keys the SMC enumerates are four
/// bytes in this alphabet, and the only characters among them that are not letters or digits
/// are `!`, `#`, `-` and `?`.
///
/// `SMCKey` holds to the same alphabet, four bytes of it (#620). That is a second definition
/// and not a call into this one, because `SMCCore` and this module do not depend on each other
/// and joining them is a change to the target graph. `SMCKeyBoundaryAgreementTests` pins the
/// two equal.
///
/// ## Refused, never repaired
///
/// As everywhere in `AeolusXPCValidation`: one fault, `invalidParameter` named `sensorKeys`,
/// for the first violation found, with a detail that never quotes the key back.
extension AeolusXPCValidation {

    /// The exact length of an SMC key, in UTF-8 bytes.
    ///
    /// Bytes rather than characters, because the key is a four-byte code and a `Character`
    /// count does not bound bytes: `"ab\r\nc"` is four characters, every one of them ASCII by
    /// `Character.isASCII`, and five bytes, so a `count == 4` check admits it. `SMCKey` made one
    /// until #620.
    public static let sensorKeyUTF8Bytes = 4

    /// The most sensors one curve may be driven by.
    ///
    /// The number `AeolusXPCPayloadBounds` sized the `apply` envelope for (#91). Until #566 it
    /// was a term in that derivation and nothing held a client to it: the envelope bounds a
    /// whole payload, not a curve, so one curve could name tens of thousands of keys inside it.
    /// Raising it raises the envelope with it, because the envelope reads it from here.
    public static let maxSensorKeysPerCurve = 16

    /// Checks the sensor keys of every curve in an `apply` payload's settings.
    ///
    /// The helper runs it on the decoded settings before they reach `FanAuthority`, so before
    /// anything there can store, log or read a key (`CLAUDE.md` rule 7).
    ///
    /// A `switch` rather than a `guard case .curve`, for the reason `FanSetting.Control`'s
    /// `isHonourable` gives: a fourth control naming a sensor group is a compile error here
    /// rather than a group that crosses unchecked.
    ///
    /// - Parameter settings: The decoded settings, in the order the client sent them.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `sensorKeys`.
    public static func validateSensorKeys(in settings: [FanSetting]) throws {
        for setting in settings {
            switch setting.control {
            case .automatic, .fixed:
                continue
            case .curve(let curve):
                try validateSensorKeys(curve.source.sensorKeys)
            }
        }
    }

    /// Checks one curve's sensor group.
    ///
    /// The list first, then each key, then repetition. The count is checked before any key is
    /// looked at, so the work done on a hostile list is bounded by the cap rather than by the
    /// envelope. Repetition is checked last, over keys already known to be ASCII, because
    /// `String`'s `==` is canonical equivalence and only in ASCII is that byte equality. A
    /// repeated key is refused rather than collapsed: under `.average` it would count one
    /// sensor twice, a curve the client did not describe.
    ///
    /// - Parameter keys: The `SensorGroup.sensorKeys` of one curve.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `sensorKeys`.
    public static func validateSensorKeys(_ keys: [String]) throws {
        guard !keys.isEmpty else {
            throw AeolusXPCFault.invalidParameter(
                name: "sensorKeys",
                detail: "a curve must name at least one sensor"
            )
        }
        guard keys.count <= maxSensorKeysPerCurve else {
            throw AeolusXPCFault.invalidParameter(
                name: "sensorKeys",
                detail: "a curve may name at most \(maxSensorKeysPerCurve) sensors"
            )
        }
        for key in keys {
            try validateSensorKey(key)
        }
        guard Set(keys).count == keys.count else {
            throw AeolusXPCFault.invalidParameter(
                name: "sensorKeys",
                detail: "a curve names the same sensor twice"
            )
        }
    }

    /// Checks that one key has the shape of an SMC key: exactly `sensorKeyUTF8Bytes` bytes,
    /// each in `isSensorKeyScalar(_:)`.
    ///
    /// The length is checked first and in bytes, which is constant time on a native string, so
    /// the alphabet is only ever walked over four bytes.
    ///
    /// - Parameter key: One client-supplied sensor key.
    /// - Throws: `AeolusXPCFault.invalidParameter` named `sensorKeys`.
    public static func validateSensorKey(_ key: String) throws {
        guard key.utf8.count == sensorKeyUTF8Bytes else {
            throw AeolusXPCFault.invalidParameter(
                name: "sensorKeys",
                detail: "each key must be exactly \(sensorKeyUTF8Bytes) bytes, as an SMC key is"
            )
        }
        guard key.unicodeScalars.allSatisfy(isSensorKeyScalar) else {
            throw AeolusXPCFault.invalidParameter(
                name: "sensorKeys",
                detail: "each key must be printable ASCII, as an SMC key is"
            )
        }
    }

    /// Whether `scalar` may appear in a sensor key: ASCII, and not removed by the display rule.
    ///
    /// Both halves do work. `isASCII` alone admits NUL, the newline and the rest of C0, which
    /// are Cc; the display rule alone admits every printable scalar past ASCII.
    static func isSensorKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && !FaultText.isRemovedFromDisplay(scalar)
    }
}
