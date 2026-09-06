import Foundation

/// How many bytes of JSON the helper will look at before it decides whether a message is
/// a message.
///
/// `AeolusXPCValidation` bounds the *fields* of a decoded request. Nothing bounded the
/// envelope, so `JSONDecoder` ran on whatever arrived — and `hello(request:)` is reachable
/// **before** the handshake by construction, because it *is* the handshake. The
/// code-signing requirement is the only thing between that decode and an unbounded
/// allocation in a root daemon, and one control is not a design
/// ([#91](https://github.com/blamechris/Aeolus/issues/91)).
///
/// ## Refused, never repaired
///
/// An over-size payload throws `AeolusXPCFault.malformedPayload`, which is exactly what
/// that code is for: a statement about what the client sent. There is no new fault code,
/// and the detail names the limit — never the payload, whose bytes are the one thing that
/// must not reach a root daemon's log line.
///
/// ## What "largest legal payload" means here, and what it excludes
///
/// The caps below are derived from the largest payload an **honest** peer emits: each
/// field at its validated maximum, encoded by a conforming JSON encoder, plus headroom.
/// JSON has three ways to make a payload arbitrarily large without changing what it
/// decodes to — whitespace between tokens, redundant digits in a number, and keys this
/// build ignores — and a payload using any of them is refused. That is the intended
/// answer: a megabyte of spaces around a two-field object is not something a client of
/// this protocol sends, and admitting it would leave the check with nothing to bound.
///
/// The one expansion that *is* admitted in full is string escaping, because a peer need
/// not be Foundation: a conforming encoder may write every UTF-16 code unit of a string as
/// a six-byte `\uXXXX` escape, and several in common use do exactly that for every
/// non-ASCII scalar. See `jsonEscapeExpansion`.
///
/// ## Three caps, not one
///
/// `hello` and `acquireLease` land within a factor of two of each other; `apply` carries an
/// array of per-fan curves and is two orders of magnitude larger. One shared bound would
/// therefore have to be `apply`'s, which would hand the pre-handshake message an envelope
/// half a megabyte wide — giving away the whole point of bounding it. Each message gets
/// the cap its own fields derive, so a later field change to one cannot silently widen
/// another.
public enum AeolusXPCPayloadBounds {

    // MARK: - Derivation terms

    /// Worst-case bytes of encoded JSON per UTF-8 byte of a decoded string.
    ///
    /// A conforming encoder may write any character as `\uXXXX` — six bytes per UTF-16
    /// code unit — and Python's `json.dumps` does so for every non-ASCII scalar by
    /// default, so this is a real client, not a hypothetical hostile one.
    ///
    /// Six times the field's **byte** cap bounds it without a second argument from the
    /// character cap. A string's UTF-16 code-unit count never exceeds its UTF-8 byte
    /// count: ASCII is the only 1:1 case, and every other scalar spends two to four UTF-8
    /// bytes on one or two code units. So `6 × maxUTF8Bytes ≥ 6 × codeUnits ≥` the escaped
    /// form, for any string the field validator would accept.
    static let jsonEscapeExpansion = 6

    /// Longest canonical JSON number the numeric fields here can produce.
    ///
    /// `Int` reaches 20 characters (`-9223372036854775808`) and `Double` 24
    /// (`-1.7976931348623157e+308`). A payload padding a number with redundant digits or
    /// zeros is refused, per the note on this type.
    static let maxNumberBytes = 32

    /// `false`, the longer of the two JSON boolean literals.
    static let maxBooleanBytes = 5

    /// Doubles every derived maximum.
    ///
    /// `AeolusXPCVersion`'s bump policy permits adding an *optional* DTO field without a
    /// bump, so a peer one release ahead may legitimately send a field this build does not
    /// decode. An envelope sized exactly to today's fields would refuse it, turning a
    /// change the policy calls additive into a breaking one. Doubling admits as much
    /// additive growth again as the whole of v1 carries today.
    static let headroomFactor = 2

    /// The largest number of fans one `apply` payload may carry settings for.
    ///
    /// The same 64 that `SMCFanEnumeration.maxPlausibleFanCount` refuses an `FNum` above,
    /// restated rather than imported: `AeolusXPC` depends on `FanKit` alone, and a payload
    /// bound is not a reason to give the shared contract an IOKit dependency. It need only
    /// be an *upper* bound on that constant rather than equal to it, and
    /// `XPCPayloadBoundsTests.envelopeAdmitsEveryFanThisProjectWillEnumerate` is what fails
    /// if enumeration ever outgrows it.
    static let maxFansPerPayload = 64

    /// The largest curve one fan's settings may carry.
    ///
    /// `FanCurve` puts no ceiling on `points` — E8b owns curve acceptance — so the
    /// envelope has to state one. Macs Fan Control offers two points and this project's
    /// reason for a curve engine is to go past that; 32 is more points than a temperature
    /// axis a human reads has room for.
    static let maxCurvePoints = 32

    /// The largest sensor group a curve may be driven by. SMC keys are four characters, so
    /// this is 16 of them, aggregated.
    static let maxSensorKeysPerCurve = 16

    /// An SMC key is four characters — `TC0P`, `F0Ac`. Named so the sensor-key term below
    /// says what it is measuring.
    static let smcKeyCharacters = 4

    /// `SensorGroup.Aggregation`'s longest raw value is `maximum`, seven characters. Eight
    /// so that a third aggregation one character longer needs no arithmetic here.
    static let maxAggregationBytes = 8

    // MARK: - Per-message caps

    /// Largest `hello(request:)` payload the helper will decode.
    ///
    /// `{"clientProtocolVersion":<number>,"clientDescription":"<escaped>"}` — the object's
    /// keys and punctuation, one number, and `clientDescription` at its validated
    /// `maxClientDescriptionUTF8Bytes` fully escaped.
    public static let maxHelloRequestBytes =
        headroomFactor
        * (objectBytes(keys: ["clientProtocolVersion", "clientDescription"])
            + maxNumberBytes
            + stringBytes(utf8Cap: AeolusXPCValidation.maxClientDescriptionUTF8Bytes))

    /// Largest `acquireLease(request:)` payload the helper will decode.
    ///
    /// `holderDescription` at its validated byte cap fully escaped, one fan index per fan
    /// this project will enumerate, a TTL, and a flag.
    public static let maxLeaseRequestBytes =
        headroomFactor
        * (objectBytes(keys: ["holderDescription", "fanIndices", "timeToLive", "isSelfRenewing"])
            + stringBytes(utf8Cap: AeolusXPCValidation.maxHolderDescriptionUTF8Bytes)
            + arrayBytes(count: maxFansPerPayload, elementBytes: maxNumberBytes)
            + maxNumberBytes
            + maxBooleanBytes)

    /// Largest `apply(settings:)` payload the helper will decode.
    ///
    /// One `FanSetting` per fan, each carrying the largest `Control` arm — a curve, whose
    /// synthesised encoding nests the associated value under `_0`.
    public static let maxFanSettingsBytes =
        headroomFactor
        * arrayBytes(count: maxFansPerPayload, elementBytes: maxFanSettingBytes)

    /// One `FanSetting` at its largest: an index, and a `Control` holding a full curve.
    private static let maxFanSettingBytes =
        objectBytes(keys: ["fanIndex", "control"])
        + maxNumberBytes
        + objectBytes(keys: ["curve"])
        + objectBytes(keys: ["_0"])
        + maxFanCurveBytes

    /// One `FanCurve` at its largest: `maxCurvePoints` points, a sensor group, and the two
    /// scalar margins.
    private static let maxFanCurveBytes =
        objectBytes(keys: [
            "points", "source", "hysteresisCelsius", "maximumRampRPMPerSecond",
        ])
        + arrayBytes(count: maxCurvePoints, elementBytes: maxCurvePointBytes)
        + maxSensorGroupBytes
        + 2 * maxNumberBytes

    private static let maxCurvePointBytes =
        objectBytes(keys: ["temperatureCelsius", "rpm"]) + 2 * maxNumberBytes

    /// `SensorGroup`: the keys, and the longest `Aggregation` raw value (`maximum`).
    private static let maxSensorGroupBytes =
        objectBytes(keys: ["sensorKeys", "aggregation"])
        + arrayBytes(
            count: maxSensorKeysPerCurve,
            elementBytes: stringBytes(utf8Cap: smcKeyCharacters))
        + stringBytes(utf8Cap: maxAggregationBytes)

    // MARK: - The check

    /// Refuses a payload larger than `limit` before anything decodes it.
    ///
    /// The one mechanism, called from each of the three decode entry points rather than
    /// from the helper's message handlers, so that no payload-carrying path can reach a
    /// decoder without passing it — including a client pre-checking its own request
    /// through the same shared functions.
    ///
    /// - Parameters:
    ///   - payload: The bytes the client sent.
    ///   - limit: The cap for this message.
    /// - Throws: `AeolusXPCFault.malformedPayload`, whose detail names the limit and never
    ///   the payload — not even its size, which is still a number the client chose.
    static func requireWithinEnvelope(_ payload: Data, limit: Int) throws {
        guard payload.count <= limit else {
            throw AeolusXPCFault.malformedPayload(
                detail: "is larger than the \(limit)-byte limit for this message")
        }
    }

    // MARK: - Encoded sizes

    /// Bytes an object costs beyond its values: two braces, and per field a quoted key, a
    /// colon, and a separating comma. One comma too many, which is headroom rather than an
    /// error.
    static func objectBytes(keys: [String]) -> Int {
        2 + keys.reduce(0) { $0 + $1.utf8.count + 4 }
    }

    /// Bytes a JSON string costs: two quotes, and the escaped form of a value validated at
    /// `utf8Cap` UTF-8 bytes.
    static func stringBytes(utf8Cap: Int) -> Int {
        2 + jsonEscapeExpansion * utf8Cap
    }

    /// Bytes an array costs: two brackets, and per element its own size and a separating
    /// comma. One comma too many, as above.
    static func arrayBytes(count: Int, elementBytes: Int) -> Int {
        2 + count * (elementBytes + 1)
    }
}
