import SMCCore

// The write turns' reads and encoding, and the preparation step's one read turn, in a file of their
// own so `SMCWriteTurns` stays inside `type_body_length`. Everything here takes the channel
// `isolated`, as the turn bodies in `SMCWriteTurns.swift` do, and nothing here writes: the one
// write call is `SMCWriteTurns.issue`.
extension SMCWriteTurns {

    // MARK: - The preparation step's reads (D5 steps 2 and 3)

    /// What the preparation step's one turn found.
    struct Survey: Sendable, Hashable {
        /// Each restore key's declared size, for every key-info read that answered.
        let declaredSizes: [SMCKey: Int]
        let forceKey: WritePathPreparation.ForceKey
    }

    /// The preparation step's reads, in one turn, before anything is written: each enumerated
    /// fan's `F<n>Md` key info (its declared size, what a restore writes zeros of) and its
    /// `F<n>Tg` key info, then `Ftst`'s key info and, if it answered, its raw value. Never throws.
    ///
    /// **`F<n>Tg`'s key info is taken here and recorded nowhere.** It fills the connection's
    /// key-info cache, which nothing in the helper clears, so the target read in the turn that
    /// reads `.engaged` (`holdFloor`) is one round trip: five when the target holds the floor,
    /// eight when it is raised. A fan whose target key info did not answer here costs that turn one
    /// more round trip, once, if the key answers later — six, or nine — and
    /// `WatchdogLimits.engagedStepRoundTrips` counts the nine, so this priming saves a round trip
    /// and bounds nothing.
    ///
    /// `Ftst` is `.absent` only when its key info answered `notFound`, the firmware's not-found
    /// answer (`forceKeyNotFoundAnswer`, which P1 did not probe, so `nil`), and `.unknown` on every
    /// other failure; a present key whose value will not read is `.unreadable`.
    static func survey(
        fans enumerated: Set<Int>?, notFound: SMCError?, on channel: isolated any SMCWriteChannel
    ) -> Survey {
        var sizes: [SMCKey: Int] = [:]
        for index in (enumerated ?? []).sorted() {
            for key in [SMCKey.fanMode(index), SMCKey.fanTargetRPM(index)].compactMap({ $0 }) {
                do {
                    let info = try channel.freshKeyInfo(for: key)
                    if key == SMCKey.fanMode(index) { sizes[key] = info.dataSize }
                } catch {
                    continue
                }
            }
        }

        let key = SMCKey.forceTest
        let info: SMCKeyInfo
        do {
            info = try channel.freshKeyInfo(for: key)
        } catch let error as SMCError where notFound == error {
            return Survey(declaredSizes: sizes, forceKey: .absent)
        } catch {
            return Survey(declaredSizes: sizes, forceKey: .unknown(detail: "\(error)"))
        }
        sizes[key] = info.dataSize
        do {
            return Survey(declaredSizes: sizes, forceKey: .reads(try rawByte(of: key, on: channel)))
        } catch {
            return Survey(declaredSizes: sizes, forceKey: .unreadable(detail: "\(error)"))
        }
    }

    // MARK: - Reading and encoding

    /// `key`'s raw value, as one byte: the `ui8` mode and force keys D3 reads raw, never through
    /// `FirmwareFanMode`'s fold.
    static func rawByte(
        of key: SMCKey, on channel: isolated any SMCWriteChannel
    ) throws -> UInt8 {
        let bytes = try channel.read(key).bytes
        guard bytes.count == 1, let byte = bytes.first else {
            throw FanControlPlaneError.readFailed(
                detail: "\(key) read \(bytes.count) bytes, not the one it declares")
        }
        return byte
    }

    /// `value` as `info` declares it, in the order this connection's generation gives — encoded
    /// before anything is written; a refusal is the turn's, with nothing written.
    static func encoded(
        _ value: Double, as info: SMCKeyInfo, on channel: isolated any SMCWriteChannel
    ) throws -> [UInt8] {
        do {
            return try SMCWriteEncoding.bytes(
                for: value, declaredBy: info, generation: channel.interfaceGeneration)
        } catch {
            throw WriteTurnRefusal(key: info.key, detail: "\(value) did not encode: \(error)")
        }
    }

    /// A forward write requires the declared type observed on `Mac16,5` (the B1 amendment):
    /// `F<n>Md` and `Ftst` `ui8` of one byte, `F<n>Tg` `flt` of four. Anything else is refused.
    static func requireObserved(_ type: SMCKeyType, size: Int, _ info: SMCKeyInfo) throws {
        guard info.type == type, info.dataSize == size else {
            throw FanControlPlaneError.readFailed(
                detail: """
                    \(info.key) declares \(info.type.fourCharString) of \(info.dataSize) byte(s), \
                    not the \(type.fourCharString) of \(size) observed
                    """)
        }
    }

    static func readFailed(_ what: String, _ error: any Error) -> any Error {
        if error is FanControlPlaneError { return error }
        return FanControlPlaneError.readFailed(detail: "\(what): \(error)")
    }

    static func describe(_ answer: FirmwareWriteAnswer) -> String {
        switch answer {
        case .accepted: return "0x00"
        case .heldBySystem: return "0x82"
        case .refused(let code): return hex(code)
        case .unanswered(let detail): return "no answer (\(detail))"
        }
    }

    static func hex(_ byte: UInt8) -> String { "0x" + String(byte, radix: 16, uppercase: false) }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "(none)" : bytes.map { hex($0) }.joined(separator: " ")
    }
}
