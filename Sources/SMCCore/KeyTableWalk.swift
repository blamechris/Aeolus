import Foundation
import os

/// What `READ_INDEX` gave back for one index of the key table, sorted the way the `#KEY`
/// cross-check (ADR 0003) counts it.
///
/// `SMCConnection.verifyKeyCountCrossCheck()` and `SMCSensorProvider.readAll()` each walk the
/// table and sort every index into one of these. `KeyTableWalk.walkedCount` says how the walk
/// counts them inside the bound, and `isKeyPastDeclaredCount` how the probe one past it does.
/// The two deliberately disagree about `.refused`.
enum KeyTableEntry: Sendable, Equatable {
    /// A code `SMCKey` represents.
    case key(SMCKey)
    /// A nonzero code `SMCKey` refuses, because a byte is outside `SMCKey.permittedBytes`: a C0
    /// control, DEL, or anything past ASCII. The firmware answered for the index, but the
    /// answer has no name in this project. `key(at:)` reports it as `SMCError.malformedKeyCode`.
    case refused(FourCharCode)
    /// No code the firmware can be shown to have written: the connection failed, the firmware's
    /// result byte was not zero, the reply was cut short, or the code is zero.
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

    /// Sorts a lookup that threw.
    ///
    /// **A code of zero is `.unanswered`, not `.refused`.** `SMCConnection`'s wire call decodes
    /// its reply from a zero-filled buffer and reads result byte 0 as success, so a reply whose
    /// key field the firmware never wrote reads as code zero, and nothing tells it apart from
    /// an answer of zero. A refused code counts as walked on the strength of "the firmware
    /// answered for this index", and zero cannot show that. At the probe this changes nothing:
    /// a refused code is no key there either.
    private init(failure: any Error) {
        guard case SMCError.malformedKeyCode(let code) = failure, code != 0 else {
            self = .unanswered
            return
        }
        self = .refused(code)
    }

    /// Whether this entry, found at index `declaredCount`, shows a key past the bound `#KEY`
    /// declared. See `KeyCountCrossCheck.keyExistsPastDeclaredCount`.
    ///
    /// **Only a key does. A refused code does not, though inside the bound one can count as
    /// walked (`KeyTableWalk.walkedCount`), and that is deliberate (#623).** The probe asks
    /// whether `#KEY` undercounts, so that the walk stopped short of a key it should have
    /// recorded. A refused code could never have been recorded: nothing can name it, so it is
    /// in no reading and no discovered key set. And a firmware that answered past its table
    /// with a filler code would fail the cross-check on every walk if the filler counted. That
    /// is #623's failure moved one index over.
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

/// One index the walk found, whose code `SMCKey` refuses.
struct RefusedKeyCode: Sendable, Equatable {
    let index: Int
    let code: FourCharCode
}

/// One walk over `0..<declaredCount`, tallied for the `#KEY` cross-check, and for whether the
/// keys it found could be a key table at all (`keySetIsPlausible`, #628).
///
/// Shared by `SMCConnection.walkKeyTable(declaredCount:keyAt:)` and
/// `SMCSensorProvider.readAll(declaredCount:keyAt:)`, which walk on either side of the actor:
/// the cross-check inside it, and `readAll()` from outside, one hop per index, so a
/// supervisor read can take its turn between two of them.
struct KeyTableWalk: Sendable {
    let declaredCount: Int
    /// Indices that resolved to a key.
    private(set) var keyCount = 0
    /// Every distinct key the walk resolved: what `readAll(declaredCount:keyAt:)` records as
    /// the discovered key set. `keyCount` counts a key each time it is found, and this once.
    private(set) var keys: Set<SMCKey> = []
    /// Indices whose code `SMCKey` refused, all of them.
    private(set) var refusedCodeCount = 0
    /// The first `maximumListedRefusedCodes` refused codes, for the log line. The rest are
    /// counted in `refusedCodeCount` and not kept.
    private(set) var listedRefusedCodes: [RefusedKeyCode] = []

    /// The most refused codes a walk counts as walked. Past it, the walk counts none of them.
    /// See `refusedCodesAreWalked` for the other condition, that the walk found a key.
    ///
    /// A refused code is walked on the reading that the firmware holds a key this project's
    /// alphabet cannot name (#623). That reading is credible for a few. A misread of the
    /// reply's key field can refuse every index. Read one byte forward on this little-endian
    /// host, the field keeps each key's first three characters and takes reply byte 4, the
    /// version, as its first: `TC0P` reads as `"\0TC0"`. Byte 4 was zero in all 3,514
    /// `READ_INDEX` replies on `Mac16,5` (macOS 27.2, #628), so there every such code holds a
    /// zero byte and `SMCKey` refuses it. Read one byte back, the field keeps the last three
    /// characters and takes its last from the byte before, refused when that byte is zero, as
    /// `MisreadIndexTables.shifted` models it. Counting those would let a walk that
    /// resolved no key at all match `#KEY` and complete discovery with an empty key set. Every
    /// named read would then report its key absent, and a Mac with fans would be reported as
    /// having none (the #627 review). Past the cap the walk does what it did before #623: the
    /// cross-check fails, its fault is logged, and discovery does not complete.
    ///
    /// **Why 8.** `Mac16,5` refuses none of its 3,514 codes (macOS 27.2). Eight leaves room for
    /// a small family of unrepresentable keys on a table nobody here has read. It is also under
    /// a quarter of one percent of this table, so a misread anywhere near a real table's size
    /// is far past it. A table that really holds more than eight loses discovery, as one with a
    /// single refused code did before #623. That fails toward `.readFailed`, never toward a
    /// false `.keyNotFound`.
    ///
    /// **What it still lets through.** Up to eight refused codes are counted, beside at least
    /// one key, wherever they sit. So the cross-check cannot see `#KEY` overcounting by eight
    /// or fewer when the firmware answers each index past its real table with a nonzero
    /// refused code; a zero filler is `.unanswered` and still fails it. Nor can it see a misread
    /// that refuses eight codes or fewer. On `Mac16,5` the firmware answers past its table with
    /// result byte `0xB8`, which is `.unanswered`. Either way the refused-code line is logged.
    ///
    /// **What the index-count cross-check cannot see.** A misread whose codes stay printable
    /// resolves every index to a key, only the wrong one: a field read onto a printable
    /// neighbouring byte, or with its bytes reordered. The cross-check counts indices, so it
    /// matches. Checks of *which* keys were found do see both, and `keySetIsPlausible` holds
    /// them (#628): a one-byte misread repeats keys, and a reordered field moves `#KEY`.
    static let maximumWalkedRefusedCodes = 8

    init(declaredCount: Int) {
        self.declaredCount = declaredCount
        keys.reserveCapacity(declaredCount)
    }

    /// Whether this walk's refused codes count as walked: the walk found at least one key, and
    /// there are at most `maximumWalkedRefusedCodes` refused codes.
    ///
    /// **The key is needed because the cap is absolute.** A `#KEY` of eight or fewer, with every
    /// reply a nonzero refused code, would otherwise walk every index, match, and complete
    /// discovery with an empty key set: the #627 review's blocker, at a small declared count.
    /// A walk that found no key has no evidence that the firmware's table is being read at all,
    /// so its refused codes count for nothing. The misreads described above act on every reply
    /// alike, refusing every code or none, so refused codes beside a key look like a real
    /// table. A majority rule (more keys than refused codes) would differ from this only on
    /// tables of sixteen entries or fewer, and no table this project has seen is near that.
    var refusedCodesAreWalked: Bool {
        keyCount > 0 && refusedCodeCount <= Self.maximumWalkedRefusedCodes
    }

    /// The indices `0..<declaredCount` this walk counts as walked, for
    /// `KeyCountCrossCheck.walkedCount`: every key, and every refused code while
    /// `refusedCodesAreWalked`. An `.unanswered` index never counts.
    var walkedCount: Int {
        keyCount + (refusedCodesAreWalked ? refusedCodeCount : 0)
    }

    /// Whether the keys this walk resolved could be an SMC key table, whatever their count: at
    /// least one, none twice, and not `#KEY`'s bytes in another order where `#KEY` should be.
    /// `SMCSensorProvider.readAll(declaredCount:keyAt:)` completes discovery only when this
    /// holds and the cross-check matches.
    ///
    /// **Why the count is not enough.** The cross-check compares the indices the walk resolved
    /// with `#KEY`, so a misread that turns each code into another printable one matches it.
    /// Discovery would then complete on a set holding none of the machine's real keys, every
    /// named read would report its key absent, and a Mac with fans would be reported as having
    /// none (rule 6). Against the shapes measured on `Mac16,5`'s 3,514 keys (#627's review,
    /// #628):
    ///
    /// - **A one-byte misread repeats keys.** With a printable byte where the field lost one,
    ///   a read one byte forward leaves 1,048 distinct codes, and one byte back 3,216.
    ///   `duplicateKeyCount` sees both, and a walk that finds one key at every index, as one
    ///   whose index never reached the firmware would.
    /// - **A reordered field moves `#KEY`.** Byte-reversed, the codes stay 3,514 distinct, so
    ///   no key repeats, but `#KEY` reads as `YEK#`. Every reordering of the four bytes turns
    ///   `#KEY` into one of `reorderedKeyCountKeys`; `holdsReorderedKeyCountKey` sees it.
    /// - **A walk that finds no key has read no table.** `#KEY` declaring 0, with nothing
    ///   answered past it, walks nothing and matches. `keyCount()` read `#KEY` by name before
    ///   the walk, so the firmware holds at least one key.
    ///
    /// **`#KEY` is evidence here, not a requirement.** It is index 0 of `Mac16,5`'s table, whose
    /// codes ascend from it. Whether Intel, M1 or M2 tables list it is not known: this project
    /// has read none, and the Asahi Linux SMC documentation calls `#KEY` the number of keys
    /// without saying where the index table puts it. Requiring it would refuse discovery for
    /// ever on a table that does not list it. A table without `#KEY` passes here, unless it
    /// holds `#KEY`'s bytes in another order instead. So a reordered field on a table that
    /// does not list `#KEY` goes unseen.
    ///
    /// **Which way a wrong rejection fails.** As when the cross-check fails: discovery does not
    /// complete, so each absent key costs a round trip and reads as a failed read, not absent.
    /// That is never a key reported absent that the firmware holds.
    var keySetIsPlausible: Bool {
        keyCount > 0 && duplicateKeyCount == 0 && !holdsReorderedKeyCountKey
    }

    /// How many of the keys this walk resolved repeat one it had already resolved. A key table
    /// lists each key once; `Mac16,5`'s 3,514 are 3,514 distinct.
    var duplicateKeyCount: Int {
        keyCount - keys.count
    }

    /// Whether the walk resolved one of `reorderedKeyCountKeys`, and not `#KEY` itself.
    var holdsReorderedKeyCountKey: Bool {
        !keys.contains(SMCKey.keyCount) && !keys.isDisjoint(with: Self.reorderedKeyCountKeys)
    }

    /// `#KEY`'s four bytes in each of their 23 other orders: what `#KEY` reads as through a key
    /// field whose bytes are reordered, whichever the reordering. `YEK#` is the byte-reversed one.
    static let reorderedKeyCountKeys: Set<SMCKey> = {
        let code = SMCKey.keyCount.fourCharCode
        let bytes = [24, 16, 8, 0].map { FourCharCode(UInt8(truncatingIfNeeded: code >> $0)) }
        var reordered: Set<SMCKey> = []
        for first in 0..<4 {
            for second in 0..<4 where second != first {
                for third in 0..<4 where third != first && third != second {
                    let order = [first, second, third, 6 - first - second - third]
                    let candidate = order.reduce(FourCharCode(0)) { $0 << 8 | bytes[$1] }
                    if candidate != code, let key = SMCKey(fourCharCode: candidate) {
                        reordered.insert(key)
                    }
                }
            }
        }
        return reordered
    }()

    /// Records `entry`, found at `index`, and returns its key if it has one. A refused code
    /// returns `nil`, so a caller has nothing to put in a reading or a discovered key set.
    /// Whether it counts as walked is decided in `walkedCount`, once the whole walk is known.
    mutating func record(_ entry: KeyTableEntry, at index: Int) -> SMCKey? {
        switch entry {
        case .key(let key):
            keyCount += 1
            keys.insert(key)
            return key
        case .refused(let code):
            refusedCodeCount += 1
            if listedRefusedCodes.count < Self.maximumListedRefusedCodes {
                listedRefusedCodes.append(RefusedKeyCode(index: index, code: code))
            }
            return nil
        case .unanswered:
            return nil
        }
    }

    /// Ends the walk with `probe`, the entry at index `declaredCount`, logs what it found, and
    /// returns the cross-check.
    ///
    /// Three lines, never one, each on its own condition. The cross-check fault blames ADR
    /// 0003's byte order and says nothing when the counts agree; the refused-code line says
    /// what the table held that `SMCKey` cannot represent, whether the counts agree or not; the
    /// key-set fault says the keys found are no key table, which agreeing counts cannot show.
    func finish(probe: KeyTableEntry) -> KeyCountCrossCheck {
        let result = KeyCountCrossCheck(
            declaredCount: declaredCount, walkedCount: walkedCount,
            keyExistsPastDeclaredCount: probe.isKeyPastDeclaredCount)
        SMCConnection.logCrossCheck(result)
        if let message = refusedCodesMessage() {
            Self.logger.error("\(message, privacy: .public)")
        }
        if let message = implausibleKeySetMessage() {
            Self.logger.fault("\(message, privacy: .public)")
        }
        return result
    }

    /// The line `finish(probe:)` logs when `keySetIsPlausible` is false, or `nil`. Counts and
    /// fixed text only, so nothing a misread table holds reaches the line.
    func implausibleKeySetMessage() -> String? {
        guard !keySetIsPlausible else { return nil }
        var findings: [String] = []
        if keyCount == 0 {
            findings.append("it resolved no key")
        }
        if duplicateKeyCount > 0 {
            findings.append(
                "\(duplicateKeyCount) of its \(keyCount) keys repeat one already walked, "
                    + "leaving \(keys.count) distinct")
        }
        if holdsReorderedKeyCountKey {
            findings.append("it holds #KEY's four bytes in another order, and not #KEY")
        }
        return """
            #KEY walk: the keys a walk of \(declaredCount) index-table entries resolved are no \
            SMC key table: \(findings.joined(separator: "; ")). READ_INDEX's reply is likelier \
            misread than the table real. Discovery does not complete on a walk that finds this, \
            so no key is reported absent on its strength (#628). This line is not the ADR 0003 \
            byte-order cross-check.
            """
    }

    private static let logger = Logger(subsystem: "dev.aeolus.SMCCore", category: "SMCConnection")

    /// How many refused codes the walk keeps and the log line lists; the rest are counted. A
    /// single unified-log line is truncated past about a kilobyte, and a table this project has
    /// never seen could refuse every entry. Listing the first few and counting the rest says so
    /// on the line, where silent truncation would not. A formatting limit only: what counts as
    /// walked is `maximumWalkedRefusedCodes`.
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
    func refusedCodesMessage() -> String? {
        guard refusedCodeCount > 0 else { return nil }
        let listed =
            listedRefusedCodes
            .map { "index \($0.index): \(Self.hexadecimal($0.code))" }
            .joined(separator: ", ")
        let unlisted = refusedCodeCount - listedRefusedCodes.count
        let more = unlisted > 0 ? ", and \(unlisted) more" : ""
        let counted: String
        if refusedCodesAreWalked {
            counted = "Each counts as walked, since the firmware answered for it"
        } else {
            let reason =
                keyCount == 0
                ? "the walk found no key, so they are"
                : "more than \(Self.maximumWalkedRefusedCodes) is"
            counted = """
                None counts as walked: \(reason) likelier a misread of the index table than keys \
                SMCKey cannot name, so the #KEY cross-check is left to fail on them
                """
        }
        return """
            #KEY walk: \(refusedCodeCount) of \(declaredCount) index-table entries returned a \
            key code SMCKey cannot represent, with a byte outside printable ASCII: \
            \(listed)\(more). \(counted). None is in the readings or the discovered key set. \
            This line is not the ADR 0003 byte-order cross-check.
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
    /// with `keyAt`, probe index `declaredCount`, log, and return the tally with the cross-check.
    ///
    /// Static, with the lookup a parameter, because `SMCConnection` has no scripted transport:
    /// this is the seam through which a test hands the walk an index table no real Mac has
    /// produced, as `SMCConnectionKeyCountDecodeTests` hands `#KEY` a value through
    /// `decodeKeyCount(value:)`. Production passes `key(at:)`. What the seam costs: a test of
    /// it never reaches `keyCount()` or the real `key(at:)`, so the hand-off between them and
    /// this is pinned only on hardware, by `SMCConnectionMac165Tests`'s live cross-check.
    static func walkKeyTable(
        declaredCount: Int, keyAt: (Int) throws -> SMCKey
    ) -> (tally: KeyTableWalk, crossCheck: KeyCountCrossCheck) {
        var walk = KeyTableWalk(declaredCount: declaredCount)
        for index in 0..<declaredCount {
            _ = walk.record(KeyTableEntry(lookingUp: index, in: keyAt), at: index)
        }
        let crossCheck = walk.finish(probe: KeyTableEntry(lookingUp: declaredCount, in: keyAt))
        return (walk, crossCheck)
    }

    /// `verifyKeyCountCrossCheck()`'s walk with its tally, so the live test on `Mac16,5` can
    /// assert that every entry in the real table was a key: none refused, none unanswered.
    /// Internal; the public method returns only the cross-check.
    func walkKeyTable() throws -> (tally: KeyTableWalk, crossCheck: KeyCountCrossCheck) {
        Self.walkKeyTable(declaredCount: try keyCount(), keyAt: key(at:))
    }
}
