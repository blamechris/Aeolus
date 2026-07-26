import Foundation
import Testing

@testable import SMCCore

// swiftlint:disable force_unwrapping

@Suite("SMC key four-character code round trip")
struct SMCKeyTests {

    @Test("A key round-trips through its FourCharCode")
    func roundTripsThroughFourCharCode() {
        let key = SMCKey("F0Ac")!
        let rebuilt = SMCKey(fourCharCode: key.fourCharCode)
        #expect(rebuilt == key)
    }

    /// `#KEY` itself: `SMCConnection.keyCount()` reads through this stored constant
    /// rather than re-parsing a literal, so this constant is the single source of truth
    /// its round trip must hold for.
    @Test("The key-count key round-trips")
    func keyCountKeyRoundTrips() {
        #expect(SMCKey.keyCount.rawValue == "#KEY")
        let rebuilt = SMCKey(fourCharCode: SMCKey.keyCount.fourCharCode)
        #expect(rebuilt == SMCKey.keyCount)
    }

    /// `READ_INDEX` returns firmware data, not something this project controls. A
    /// non-ASCII code must fail to decode rather than producing a key nothing else in
    /// `SMCKey` could have constructed.
    @Test("A code with a non-ASCII byte fails to decode rather than crashing")
    func nonASCIICodeFailsToDecode() {
        let code: FourCharCode = 0xFF41_4243  // 0xFF is not ASCII
        #expect(SMCKey(fourCharCode: code) == nil)
    }

    @Test("Every named convenience key is a valid four-character code")
    func namedConveniencesRoundTrip() {
        let keys: [SMCKey] = [
            .keyCount, .fanCount, .fanForceBitmask, .forceTest,
        ]
        for key in keys {
            #expect(SMCKey(fourCharCode: key.fourCharCode) == key)
        }
    }
}

// swiftlint:enable force_unwrapping
