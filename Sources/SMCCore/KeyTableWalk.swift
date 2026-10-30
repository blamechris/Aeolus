import os

/// What `READ_INDEX` gave back for one index of the key table, sorted the way the `#KEY`
/// cross-check (ADR 0003) counts it.
///
/// `SMCConnection.verifyKeyCountCrossCheck()` and `SMCSensorProvider.readAll()` each walk the
/// table and sort every index into one of these. The two properties below are the whole of
/// how the walk counts, and they deliberately disagree about `.refused`.
enum KeyTableEntry: Sendable, Equatable {
    /// A code `SMCKey` represents.
    case key(SMCKey)
    /// A code `SMCKey` refuses, because a byte is outside `SMCKey.permittedBytes`: a C0
    /// control, DEL, or anything past ASCII. The firmware answered for the index, but the
    /// answer has no name in this project. `key(at:)` reports it as `SMCError.malformedKeyCode`.
    case refused(FourCharCode)
    /// No code at all: the connection failed, the firmware's result byte was not zero, or the
    /// reply was cut short.
    case unanswered

    /// Looks `index` up with `keyAt`, and sorts what comes back.
    init(lookingUp index: Int, in keyAt: (Int) throws -> SMCKey) {
        do {
            self = .key(try keyAt(index))
        } catch {
            self = Self(failure: error)
        }
    }

    /// Looks `index` up with `keyAt`, and sorts what comes back.
    init(lookingUp index: Int, in keyAt: (Int) async throws -> SMCKey) async {
        do {
            self = .key(try await keyAt(index))
        } catch {
            self = Self(failure: error)
        }
    }

    private init(failure: any Error) {
        guard case SMCError.malformedKeyCode(let code) = failure else {
            self = .unanswered
            return
        }
        self = .refused(code)
    }

    /// Whether the walk over `0..<declaredCount` counts this index as walked.
    ///
    /// **A refused code is walked (#623).** `#KEY` declared an entry at this index and the
    /// firmware answered with one; all that failed is this project's alphabet. Until #623 the
    /// walk skipped it uncounted, so one such code anywhere in a table failed the cross-check,
    /// logged a fault blaming ADR 0003's byte-order hypothesis for an alphabet decision (#620),
    /// and left discovery incomplete. `knownKeys` then stayed `nil`, and a key the machine
    /// lacks read as `.readFailed` rather than `.keyNotFound`.
    ///
    /// The cost is on the other side of the tripwire. If `#KEY` overcounts and a firmware
    /// answers the indices past its real table with refused codes, this counts them and the
    /// cross-check matches. The refused-code line `KeyTableWalk.finish(probe:)` logs is then
    /// the only record. On `Mac16,5` (macOS 27.2) the firmware does not answer past its table
    /// at all: `READ_INDEX` at 3,514, 3,515 and 3,614 each returned result byte `0xB8`, which
    /// is `.unanswered` here and still fails the cross-check.
    ///
    /// `.unanswered` is not walked: nothing answered for the index.
    var isWalked: Bool {
        switch self {
        case .key, .refused: return true
        case .unanswered: return false
        }
    }

    /// Whether this entry, found at index `declaredCount`, shows a key past the bound `#KEY`
    /// declared. See `KeyCountCrossCheck.keyExistsPastDeclaredCount`.
    ///
    /// **Only a key does. A refused code does not, which is the opposite of `isWalked`, and
    /// deliberately so (#623).** The probe asks whether `#KEY` undercounts, so that the walk
    /// stopped short of a key it should have recorded. A refused code could never have been
    /// recorded: nothing can name it, so it is in no reading and no discovered key set. And a
    /// firmware that answered past its table with a filler code would fail the cross-check on
    /// every walk if the filler counted: zero is the obvious filler, and `SMCKey` refuses zero.
    /// That is #623's failure moved one index over.
    ///
    /// The probe reads one index, and always has. Whether a real key sits past a refused code
    /// at `declaredCount`, it does not look.
    var isKeyPastDeclaredCount: Bool {
        switch self {
        case .key: return true
        case .refused, .unanswered: return false
        }
    }
}

/// One index the walk counted, whose code `SMCKey` refuses.
struct RefusedKeyCode: Sendable, Equatable {
    let index: Int
    let code: FourCharCode
}

/// One walk over `0..<declaredCount`, tallied for the `#KEY` cross-check.
///
/// Shared by `SMCConnection.walkKeyTable(declaredCount:keyAt:)` and
/// `SMCSensorProvider.readAll(declaredCount:keyAt:)`, which walk on either side of the actor:
/// the cross-check inside it, and `readAll()` from outside, one hop per index, so a
/// supervisor read can take its turn between two of them.
struct KeyTableWalk {
    let declaredCount: Int
    private(set) var walkedCount = 0
    private(set) var refusedCodes: [RefusedKeyCode] = []

    init(declaredCount: Int) {
        self.declaredCount = declaredCount
    }

    /// Counts `entry`, found at `index`, and returns its key if it has one. A refused code
    /// returns `nil`, so a caller has nothing to put in a reading or a discovered key set.
    mutating func record(_ entry: KeyTableEntry, at index: Int) -> SMCKey? {
        if entry.isWalked {
            walkedCount += 1
        }
        switch entry {
        case .key(let key):
            return key
        case .refused(let code):
            refusedCodes.append(RefusedKeyCode(index: index, code: code))
            return nil
        case .unanswered:
            return nil
        }
    }

    /// Ends the walk with `probe`, the entry at index `declaredCount`, logs what it found, and
    /// returns the cross-check.
    ///
    /// Two lines, never one. The cross-check fault blames ADR 0003's byte order and says
    /// nothing when the counts agree; the refused-code line says what the table held that
    /// `SMCKey` cannot represent, and appears whether the counts agree or not.
    func finish(probe: KeyTableEntry) -> KeyCountCrossCheck {
        let result = KeyCountCrossCheck(
            declaredCount: declaredCount, walkedCount: walkedCount,
            keyExistsPastDeclaredCount: probe.isKeyPastDeclaredCount)
        SMCConnection.logCrossCheck(result)
        if let message = Self.refusedCodesMessage(refusedCodes, declaredCount: declaredCount) {
            Self.logger.error("\(message, privacy: .public)")
        }
        return result
    }

    private static let logger = Logger(subsystem: "dev.aeolus.SMCCore", category: "SMCConnection")

    /// How many refused codes the log line lists; the rest are counted. A single unified-log
    /// line is truncated past about a kilobyte, and a table this project has never seen could
    /// refuse every entry. Listing the first few and counting the rest says so on the line,
    /// where silent truncation would not.
    static let maximumListedRefusedCodes = 16

    /// The line `finish(probe:)` logs, or `nil` when no code was refused.
    ///
    /// **Codes are written in hexadecimal, never decoded.** SMCCore logs straight to `os.Logger`,
    /// with no escape: `LogText`'s, which `SafetyLog`, `HelperLog` and `LeaseLog` apply, is in
    /// `AeolusHelper`. Decoding is how a refused code's bytes would reach the line raw, and those
    /// bytes are the ones the alphabet refuses: a line feed starts what reads as a second entry,
    /// and the three bytes `E2 80 A8` decode to U+2028. A `UInt32` in hexadecimal is drawn from
    /// `0`–`9`, `a`–`f` and the `0x` before it, so nothing in it can break or hide a line, and
    /// it is logged `.public` for that reason.
    static func refusedCodesMessage(_ refused: [RefusedKeyCode], declaredCount: Int) -> String? {
        guard !refused.isEmpty else { return nil }
        let listed = refused.prefix(maximumListedRefusedCodes)
            .map { "index \($0.index): \(hexadecimal($0.code))" }
            .joined(separator: ", ")
        let unlisted = refused.count - min(refused.count, maximumListedRefusedCodes)
        let more = unlisted > 0 ? ", and \(unlisted) more" : ""
        return """
            #KEY walk: \(refused.count) of \(declaredCount) index-table entries returned a key \
            code SMCKey cannot represent, with a byte outside printable ASCII: \(listed)\(more). \
            Each counts as walked, since the firmware answered for it, and none is in the \
            readings or the discovered key set. This is not the ADR 0003 byte-order cross-check.
            """
    }

    /// `code` as `0x` and eight lower-case hexadecimal digits.
    static func hexadecimal(_ code: FourCharCode) -> String {
        let digits = String(code, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }
}

extension SMCConnection {
    /// The key `READ_INDEX`'s reply code names, or `SMCError.malformedKeyCode` when `SMCKey`
    /// refuses it. What `key(at:)` does with a reply, split out so a test can hand the walk a
    /// firmware code, not a key.
    static func indexedKey(fromCode code: FourCharCode) throws -> SMCKey {
        guard let key = SMCKey(fourCharCode: code) else {
            throw SMCError.malformedKeyCode(code)
        }
        return key
    }

    /// Everything `verifyKeyCountCrossCheck()` does once it has `#KEY`: walk `0..<declaredCount`
    /// with `keyAt`, probe index `declaredCount`, log, and return the cross-check.
    ///
    /// Static, with the lookup a parameter, because `SMCConnection` has no scripted transport:
    /// this is the seam through which a test hands the walk an index table no real Mac has
    /// produced, as `SMCConnectionKeyCountDecodeTests` hands `#KEY` a value through
    /// `decodeKeyCount(value:)`. Production passes `key(at:)`. What the seam costs: a test of
    /// it never reaches `keyCount()` or the real `key(at:)`, so the hand-off between them and
    /// this is pinned only on hardware, by `SMCConnectionMac165Tests`'s live cross-check.
    static func walkKeyTable(
        declaredCount: Int, keyAt: (Int) throws -> SMCKey
    ) -> KeyCountCrossCheck {
        var walk = KeyTableWalk(declaredCount: declaredCount)
        for index in 0..<declaredCount {
            _ = walk.record(KeyTableEntry(lookingUp: index, in: keyAt), at: index)
        }
        return walk.finish(probe: KeyTableEntry(lookingUp: declaredCount, in: keyAt))
    }
}
