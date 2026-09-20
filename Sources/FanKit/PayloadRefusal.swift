import Foundation

/// The reasons **this project's own** decoders refuse a payload — a closed vocabulary, so a
/// refusal can be surfaced to a client without surfacing anything the client wrote.
///
/// ## Why a type rather than a string
///
/// `AeolusXPCValidation.malformedDetail(for:)` exists to stop a decoding failure quoting a
/// client's own bytes into a **root daemon's** log line, and `DecodingError`'s own
/// `debugDescription` is the thing it is guarding against: for a genuine syntax error that
/// text is Foundation-authored and can carry fragments of the payload. So it cannot be passed
/// through, and for a long time nothing was — every `.dataCorrupted` collapsed to *"is not
/// well-formed JSON"*, including the refusals this project writes itself. A client that sent
/// syntactically perfect JSON containing a non-finite curve point was told its JSON was
/// malformed and went looking for a syntax error that did not exist
/// ([#276](https://github.com/blamechris/Aeolus/issues/276)).
///
/// The fix cannot be "surface `debugDescription` when we wrote it", because nothing in a
/// `String` says who wrote it. It is this: our refusals travel as a **value** in the error's
/// `underlyingError`, and `malformedDetail` maps a recognised value back to a fixed sentence.
/// What reaches a client is therefore always one of the sentences below — never a string a
/// decoder composed, and never a byte of the payload.
///
/// **What does the discriminating is the type, not the slot.** Foundation puts an
/// `underlyingError` there too: a `JSONSerialization` failure arrives as a `.dataCorrupted`
/// carrying an `NSCocoaError` whose description quotes the client's literal and the parser's
/// column. An earlier version of this paragraph said Foundation never sets it, which is
/// false and was the more dangerous kind of wrong — it made the conditional cast in
/// `malformedDetail` look like defensive noise that a later edit could simplify away. It
/// cannot: the cast is the guard. A fabricated `NSError` cannot satisfy it either, because
/// Swift carries an `Error` enum's payload in `userInfo` rather than in the domain and code.
///
/// It covers this project's **hand-written** refusals only. A synthesised `Codable`
/// conformance — a raw-value enum meeting an unrecognised string — throws a `.dataCorrupted`
/// no scan can route through here, and it is still flattened. That is the safe answer and
/// the under-informative one; [#284](https://github.com/blamechris/Aeolus/issues/284)
/// carries it.
///
/// ## The descriptions are value-free by construction
///
/// `FanBoundsImplausibility.description`'s discipline, for its reason, and here it is load
/// bearing rather than tidy: these strings *are* the wire text. A case that interpolated a
/// value would put it in front of a client and into a helper log. That is not hypothetical —
/// `FanReading.init(from:)` used to throw `"a fan reading must be finite, got \(value)"`, and
/// only the flattening this type replaces kept it out of the log.
///
/// Keeping the vocabulary closed is also what makes it **testable**: a test can compare the
/// detail a client actually receives against a case's description, which is the assertion
/// #276 found missing.
public enum PayloadRefusal: Error, Sendable, Hashable, CaseIterable, CustomStringConvertible {

    /// A `FanCurve` carried a NaN or infinite point. See `FanCurve.init(from:)`.
    case curvePointNotFinite

    /// A `FanSetting` named a control this helper cannot carry out — a non-finite fixed
    /// RPM, or a shape it does not honour. See `FanSetting.init(from:)`.
    case controlNotHonourable

    /// A `FanReading` carried a NaN or infinite measurement.
    case fanReadingNotFinite

    /// A `FanReading` carried neither a value nor a reason it is unavailable — the
    /// `(nil, nil)` shape `AeolusXPCProtocol` calls a protocol violation.
    case fanReadingCarriesNeitherValueNorReason

    /// A `FanReading` carried both a value and a reason it is unavailable: a peer
    /// disagreeing with itself about whether it has a reading.
    case fanReadingCarriesBothValueAndReason

    /// The sentence a client is shown, and the `debugDescription` the error carries.
    ///
    /// One string for both, deliberately: a second wording for the log would be a second
    /// thing to keep value-free, and the first one to drift.
    public var description: String {
        switch self {
        case .curvePointNotFinite:
            return "a curve point is not finite"
        case .controlNotHonourable:
            return "the control names nothing this helper can carry out"
        case .fanReadingNotFinite:
            return "a fan reading is not finite"
        case .fanReadingCarriesNeitherValueNorReason:
            return "a fan reading carries neither a value nor a reason it is unavailable"
        case .fanReadingCarriesBothValueAndReason:
            return "a fan reading carries both a value and a reason it is unavailable"
        }
    }
}

extension DecodingError {

    /// Refuses a payload with one of **this project's** reasons, recognisably.
    ///
    /// The single constructor for a `.dataCorrupted` anywhere in `Sources`, and a test
    /// asserts that — see `PayloadRefusalTests.everyRefusalInSourcesTravelsAsAValue`.
    /// `DecodingError.dataCorruptedError(forKey:in:debugDescription:)`, the convenience every
    /// one of these call sites used to use, has no parameter for an `underlyingError`, so a
    /// site that reaches for it produces a refusal `malformedDetail(for:)` cannot tell from
    /// Foundation's own and silently flattens to *"is not well-formed JSON"*. The ban is on
    /// the convenience rather than on forgetting, because forgetting is what happened.
    ///
    /// - Parameters:
    ///   - refusal: Why the payload is being refused.
    ///   - key: The field at fault, for the coding path. The path is drawn from this
    ///     project's own key names, never from the client's text, which is why it is safe to
    ///     carry.
    ///   - container: The container being decoded from, for its coding path.
    /// - Returns: A `.dataCorrupted` carrying `refusal` as its `underlyingError`, which is
    ///   what `AeolusXPCValidation.malformedDetail(for:)` recognises.
    public static func refusing<Key: CodingKey>(
        _ refusal: PayloadRefusal,
        forKey key: Key,
        in container: KeyedDecodingContainer<Key>
    ) -> DecodingError {
        .dataCorrupted(
            Context(
                codingPath: container.codingPath + [key],
                debugDescription: refusal.description,
                underlyingError: refusal
            )
        )
    }
}
