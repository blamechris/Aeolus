import Foundation
import Testing

@testable import SMCCore

/// The line `KeyTableWalk.finish(probe:)` logs for refused codes. SMCCore logs without an
/// escape, so the line must hold nothing that can break or hide it; see
/// `KeyTableWalk.refusedCodesMessage()`.
@Suite("Key-table walk, the refused-code log line")
struct KeyTableWalkRefusedCodeLogTests {

    /// A walk of `declaredCount` indices that met `refused` at indices 0, 1, 2 and so on, then
    /// a key after them unless `withKey` is false. Without a key, no refused code is walked.
    static func walk(
        refusing refused: [FourCharCode], declaredCount: Int, withKey: Bool = true
    ) -> KeyTableWalk {
        var walk = KeyTableWalk(declaredCount: declaredCount)
        for (index, code) in refused.enumerated() {
            _ = walk.record(.refused(code), at: index)
        }
        if withKey {
            _ = walk.record(.key(KeyTableCodes.fan), at: refused.count)
        }
        return walk
    }

    /// Codes spread across `UInt32`, with the ones whose bytes decode to NUL, a line feed or
    /// U+2028, which are what a decoded code would put on the line.
    static let spread: [FourCharCode] = [
        0, 1, 0x0000_000A, 0x0A0A_0A0A, 0x0000_0041, 0x4100_0000, 0xE280_A841, 0xE280_A800,
        0x4630_0A63, 0x7F7F_7F7F, 0x8000_0000, 0xDEAD_BEEF, UInt32.max,
    ]

    @Test("No refused code, no line")
    func noRefusedCodeNoLine() {
        #expect(KeyTableWalk(declaredCount: 3).refusedCodesMessage() == nil)
    }

    @Test("hexadecimal(_:) is 0x and eight lower-case digits, for any code", arguments: spread)
    func hexadecimalIsEightLowerCaseDigits(code: FourCharCode) {
        let written = KeyTableWalk.hexadecimal(code)

        #expect(written.wholeMatch(of: /0x[0-9a-f]{8}/) != nil)
        #expect(UInt32(written.dropFirst(2), radix: 16) == code)
    }

    @Test("Each refused code is written in hexadecimal beside its index, with the count")
    func refusedCodesAreWrittenInHexadecimal() throws {
        let walk = Self.walk(refusing: [0x4630_0A63, 0x0000_0041, 0xE280_A841], declaredCount: 7)

        let message = try #require(walk.refusedCodesMessage())

        #expect(message.contains("3 of 7 index-table entries"))
        #expect(message.contains("index 0: 0x46300a63, index 1: 0x00000041, index 2: 0xe280a841"))
        #expect(message.contains("Each counts as walked"))
    }

    /// The reason the codes are hexadecimal. Decoded, these codes put NUL, a line feed and
    /// U+2028 on the line, and the last two read in `log show` as a second entry.
    @Test("Every scalar in the line is printable ASCII")
    func lineIsPrintableASCII() throws {
        let walk = Self.walk(refusing: Self.spread, declaredCount: 20)

        let message = try #require(walk.refusedCodesMessage())

        #expect(message.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) })
    }

    @Test("Past the cap on walked refused codes, the line says none counts as walked")
    func lineSaysNoneCountsPastTheCap() throws {
        let cap = KeyTableWalk.maximumWalkedRefusedCodes
        let walk = Self.walk(
            refusing: Array(repeating: 0x0000_000A, count: cap + 1), declaredCount: 100)

        let message = try #require(walk.refusedCodesMessage())

        #expect(message.contains("None counts as walked: more than \(cap)"))
        #expect(!message.contains("Each counts as walked"))
    }

    @Test("With no key beside them, the line says none counts as walked, and why")
    func lineSaysNoneCountsWithNoKey() throws {
        let walk = Self.walk(
            refusing: [0x0000_000A, 0x4630_0A63], declaredCount: 2, withKey: false)

        let message = try #require(walk.refusedCodesMessage())

        #expect(message.contains("None counts as walked: the walk found no key"))
        #expect(!message.contains("Each counts as walked"))
    }

    @Test("Past the listing limit, the rest are counted rather than kept or listed")
    func refusedCodesPastTheLimitAreCounted() throws {
        let limit = KeyTableWalk.maximumListedRefusedCodes
        let walk = Self.walk(
            refusing: Array(repeating: 0x0000_000A, count: limit + 4), declaredCount: 100)

        #expect(walk.refusedCodeCount == limit + 4)
        #expect(walk.listedRefusedCodes.count == limit)
        let message = try #require(walk.refusedCodesMessage())
        #expect(message.contains("\(limit + 4) of 100"))
        #expect(message.contains("index \(limit - 1): 0x0000000a, and 4 more"))
        #expect(!message.contains("index \(limit): "))
    }
}
