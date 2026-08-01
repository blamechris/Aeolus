import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// Returns the fault a body threw, or `nil` if it threw something else or nothing.
private func fault(from body: () throws -> Void) -> AeolusXPCFault? {
    do {
        try body()
        return nil
    } catch let fault as AeolusXPCFault {
        return fault
    } catch {
        return nil
    }
}

/// The name of the parameter a body's refusal blamed, or `nil` if it did not refuse or
/// refused for some other reason. Asserting on the *name* is what makes these tests able
/// to fail: "something threw" passes just as happily when an unrelated earlier guard
/// fires, which is how a check ends up looking tested while never being reached.
private func refusedParameter(_ body: () throws -> Void) -> String? {
    guard case .invalidParameter(let name, _)? = fault(from: body) else { return nil }
    return name
}

/// These are the checks that stand between a hostile payload and a root daemon, so the
/// suite is deliberately weighted towards refusals rather than acceptances: the
/// interesting failure is never "a valid request was rejected", it is "an invalid one was
/// not".
@Suite("XPC request validation")
struct XPCValidationTests {

    private let fans: Set<Int> = [0, 1]

    private func encoded(_ request: LeaseRequest) throws -> Data {
        try AeolusXPCCoding.encoder().encode(request)
    }

    private func valid(
        holder: String = "fanctl",
        indices: [Int] = [0],
        ttl: TimeInterval = 30
    ) -> LeaseRequest {
        LeaseRequest(holderDescription: holder, fanIndices: indices, timeToLive: ttl)
    }

    // MARK: - Acceptance

    @Test("A well-formed lease request is accepted unchanged")
    func wellFormedRequestIsAccepted() throws {
        let request = valid()
        let decoded = try AeolusXPCValidation.leaseRequest(
            from: try encoded(request),
            enumeratedFanIndices: fans
        )
        #expect(decoded == request)
    }

    /// The default the rest of the project uses has to be inside the envelope this
    /// module enforces, or the common case is refused by the safety check meant to catch
    /// the uncommon one.
    @Test("The project's default lease lifetime is inside the accepted range")
    func defaultTTLIsAccepted() throws {
        #expect(AeolusXPCValidation.leaseTTLRange.contains(Lease.defaultTimeToLive))
        try AeolusXPCValidation.validateTimeToLive(Lease.defaultTimeToLive)
    }

    @Test("Both ends of the TTL range are accepted")
    func rangeEndpointsAreAccepted() throws {
        try AeolusXPCValidation.validateTimeToLive(AeolusXPCValidation.leaseTTLRange.lowerBound)
        try AeolusXPCValidation.validateTimeToLive(AeolusXPCValidation.leaseTTLRange.upperBound)
    }

    @Test("A description of exactly the maximum length is accepted")
    func maximumLengthDescriptionIsAccepted() throws {
        let atLimit = String(repeating: "a", count: AeolusXPCValidation.maxHolderDescriptionLength)
        try AeolusXPCValidation.validateHolderDescription(atLimit)
    }

    // MARK: - Decoding

    @Test("Undecodable JSON is refused as a malformed payload")
    func undecodableJSONIsRefused() {
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeLeaseRequest(from: Data("not json at all".utf8))
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }

    @Test("Empty data is refused as a malformed payload")
    func emptyDataIsRefused() {
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeLeaseRequest(from: Data())
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }

    /// Absent fields are refused rather than defaulted. `LeaseRequest`'s Swift
    /// initialiser has defaults for `timeToLive` and `isSelfRenewing`; a payload that
    /// omits them is a client that did not say how long it wants the fans held, and the
    /// helper does not get to decide that on its behalf.
    @Test(
        "A payload missing any required field is refused",
        arguments: [
            #"{"fanIndices":[0],"timeToLive":30,"isSelfRenewing":false}"#,
            #"{"holderDescription":"fanctl","timeToLive":30,"isSelfRenewing":false}"#,
            #"{"holderDescription":"fanctl","fanIndices":[0],"isSelfRenewing":false}"#,
            #"{"holderDescription":"fanctl","fanIndices":[0],"timeToLive":30}"#,
        ]
    )
    func missingRequiredFieldIsRefused(_ json: String) {
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeLeaseRequest(from: Data(json.utf8))
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }

    @Test("A field of the wrong type is refused")
    func wrongTypeIsRefused() {
        let json = """
            {"holderDescription":"fanctl","fanIndices":"zero","timeToLive":30,\
            "isSelfRenewing":false}
            """
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeLeaseRequest(from: Data(json.utf8))
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }

    /// A decoding error's own description embeds the offending value. That value is
    /// client-chosen data on its way into a helper log line, so the fault must describe
    /// the violation instead of quoting it.
    @Test("A malformed-payload refusal does not quote the client's data back")
    func malformedRefusalDoesNotEchoClientData() throws {
        let marker = "sentinelValueFromTheClient"
        let json = """
            {"holderDescription":"\(marker)","fanIndices":"\(marker)","timeToLive":30,\
            "isSelfRenewing":false}
            """
        let thrown = try #require(
            fault(from: {
                _ = try AeolusXPCValidation.decodeLeaseRequest(from: Data(json.utf8))
            })
        )
        #expect(thrown.errorDescription?.contains(marker) == false)
    }

    // MARK: - Time to live

    @Test(
        "A TTL outside the envelope is refused",
        arguments: [
            AeolusXPCValidation.leaseTTLRange.lowerBound - 1,
            AeolusXPCValidation.leaseTTLRange.upperBound + 1,
            0,
            -30,
            86_400,
        ]
    )
    func outOfRangeTTLIsRefused(_ ttl: TimeInterval) {
        #expect(
            refusedParameter({ try AeolusXPCValidation.validateTimeToLive(ttl) }) == "timeToLive")
    }

    /// NaN compares false against everything, so a bare range test rejects it by
    /// accident. Checked deliberately, because "rejected for the wrong reason" is one
    /// refactor away from "not rejected".
    @Test(
        "A non-finite TTL is refused",
        arguments: [Double.nan, .infinity, -.infinity, .signalingNaN]
    )
    func nonFiniteTTLIsRefused(_ ttl: TimeInterval) {
        #expect(
            refusedParameter({ try AeolusXPCValidation.validateTimeToLive(ttl) }) == "timeToLive")
    }

    @Test("An out-of-range TTL is refused through the full decode-and-validate path")
    func outOfRangeTTLIsRefusedEndToEnd() throws {
        let payload = try encoded(valid(ttl: 86_400))
        let thrown = refusedParameter({
            _ = try AeolusXPCValidation.leaseRequest(from: payload, enumeratedFanIndices: fans)
        })
        #expect(thrown == "timeToLive")
    }

    // MARK: - Fan indices

    @Test("An empty fan list is refused")
    func emptyFanListIsRefused() {
        let refused = refusedParameter({
            try AeolusXPCValidation.validateFanIndices([], enumeratedFanIndices: fans)
        })
        #expect(refused == "fanIndices")
    }

    /// De-duplicating silently would grant a lease over a set the client did not ask
    /// for, and a repeated index is a client bug worth surfacing rather than absorbing.
    @Test("A repeated fan index is refused, not de-duplicated")
    func duplicateFanIndexIsRefused() {
        let refused = refusedParameter({
            try AeolusXPCValidation.validateFanIndices([0, 1, 0], enumeratedFanIndices: fans)
        })
        #expect(refused == "fanIndices")
    }

    @Test(
        "A fan index this machine did not enumerate is refused",
        arguments: [[2], [0, 2], [-1], [Int.max]]
    )
    func unenumeratedFanIndexIsRefused(_ indices: [Int]) {
        let refused = refusedParameter({
            try AeolusXPCValidation.validateFanIndices(indices, enumeratedFanIndices: fans)
        })
        #expect(refused == "fanIndices")
    }

    /// A machine with no fans enumerated grants no leases. The empty set is the case a
    /// subset test gets wrong if it is written the other way round.
    @Test("No fan can be leased on a machine where none were enumerated")
    func noFansMeansNoLease() {
        let refused = refusedParameter({
            try AeolusXPCValidation.validateFanIndices([0], enumeratedFanIndices: [])
        })
        #expect(refused == "fanIndices")
    }

    // MARK: - Descriptions

    @Test(
        "An empty or blank description is refused",
        arguments: ["", " ", "\t", "   \t  "]
    )
    func blankDescriptionIsRefused(_ description: String) {
        let refused = refusedParameter({
            try AeolusXPCValidation.validateHolderDescription(description)
        })
        #expect(refused == "holderDescription")
    }

    @Test("A description one character over the cap is refused")
    func overlongDescriptionIsRefused() {
        let tooLong = String(
            repeating: "a",
            count: AeolusXPCValidation.maxHolderDescriptionLength + 1
        )
        #expect(
            refusedParameter({ try AeolusXPCValidation.validateHolderDescription(tooLong) })
                == "holderDescription"
        )
    }

    /// A character cap alone does not bound a log line: one grapheme cluster can carry
    /// an unbounded run of combining marks, so a string well inside the character cap can
    /// still be enormous. Both caps have to hold.
    @Test("A description inside the character cap but over the byte cap is refused")
    func byteHeavyDescriptionIsRefused() {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 400)
        #expect(zalgo.count <= AeolusXPCValidation.maxHolderDescriptionLength)
        #expect(zalgo.utf8.count > AeolusXPCValidation.maxHolderDescriptionUTF8Bytes)
        #expect(
            refusedParameter({ try AeolusXPCValidation.validateHolderDescription(zalgo) })
                == "holderDescription"
        )
    }

    /// The hostile case this cap exists for. A newline forges a second `log show` entry;
    /// U+202E reverses the reading order of everything after it in a UI row; NUL
    /// truncates the string for anything that reads it as C.
    @Test(
        "A description containing a control or formatting character is refused",
        arguments: [
            "fanctl\u{0}",
            "fanctl\nsomething else entirely",
            "fanctl\r\n",
            "fanctl\u{7F}",
            "fanctl\u{202E}ecived",
            "\u{200F}fanctl",
            "fan\tctl",
        ]
    )
    func controlCharacterInDescriptionIsRefused(_ description: String) {
        let refused = refusedParameter({
            try AeolusXPCValidation.validateHolderDescription(description)
        })
        #expect(refused == "holderDescription")
    }

    /// Refused, not repaired — the distinction the whole module turns on. If this ever
    /// starts returning a cleaned-up string, a lease will be displayed under a name its
    /// holder never chose.
    @Test("A hostile description is refused rather than sanitised into acceptance")
    func hostileDescriptionIsNotSanitised() {
        let hostile = "fanctl\nroot: granted"
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.validate(
                valid(holder: hostile),
                enumeratedFanIndices: fans
            )
        })
        #expect(thrown != nil)
        #expect(thrown?.errorDescription?.contains("\n") == false)
    }

    @Test("A hostile description is refused through the full decode-and-validate path")
    func hostileDescriptionIsRefusedEndToEnd() throws {
        let payload = try encoded(valid(holder: "fanctl\u{202E}"))
        let refused = refusedParameter({
            _ = try AeolusXPCValidation.leaseRequest(from: payload, enumeratedFanIndices: fans)
        })
        #expect(refused == "holderDescription")
    }
}

/// The handshake is the gate every other message sits behind, so its refusals are the
/// ones that decide whether an unnegotiated client can proceed at all.
@Suite("XPC handshake validation")
struct XPCHandshakeValidationTests {

    @Test("A hello inside the helper's range is accepted")
    func compatibleHelloIsAccepted() throws {
        let request = HelloRequest(
            clientProtocolVersion: AeolusXPCVersion.current,
            clientDescription: "fanctl 0.1.0"
        )
        let payload = try AeolusXPCCoding.encoder().encode(request)
        #expect(try AeolusXPCValidation.helloRequest(from: payload) == request)
    }

    @Test("A hello outside the helper's range is refused with both sides' numbers")
    func incompatibleHelloIsRefused() throws {
        let helperRange = ProtocolVersionRange(minimumSupported: 2, current: 4)
        let request = HelloRequest(clientProtocolVersion: 1, clientDescription: "fanctl")
        let thrown = try #require(
            fault(from: {
                try AeolusXPCValidation.validate(request, helperRange: helperRange)
            })
        )
        #expect(thrown == .versionMismatch(clientVersion: 1, helperRange: helperRange))
    }

    @Test("A hello from a client newer than the helper is refused")
    func newerClientIsRefused() {
        let request = HelloRequest(
            clientProtocolVersion: AeolusXPCVersion.current + 1,
            clientDescription: "Aeolus.app"
        )
        let thrown = fault(from: { try AeolusXPCValidation.validate(request) })
        #expect(thrown?.wireCode == "versionMismatch")
    }

    @Test("A hello with a hostile client description is refused")
    func hostileClientDescriptionIsRefused() {
        let request = HelloRequest(
            clientProtocolVersion: AeolusXPCVersion.current,
            clientDescription: "Aeolus.app\u{0}"
        )
        #expect(
            refusedParameter({ try AeolusXPCValidation.validate(request) }) == "clientDescription")
    }

    /// The description is judged before the version. A client that is both out of range
    /// and misbehaved is told about the misbehaviour, because updating fixes the version
    /// and would leave the bug in place.
    @Test("A hello that is both out of range and misbehaved reports the misbehaviour")
    func descriptionIsCheckedBeforeVersion() {
        let request = HelloRequest(
            clientProtocolVersion: 99,
            clientDescription: "Aeolus.app\n"
        )
        #expect(
            refusedParameter({ try AeolusXPCValidation.validate(request) }) == "clientDescription")
    }

    @Test("Undecodable hello JSON is refused as a malformed payload")
    func undecodableHelloIsRefused() {
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeHelloRequest(from: Data("{".utf8))
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }

    @Test("A hello missing its version is refused rather than defaulted")
    func helloWithoutVersionIsRefused() {
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeHelloRequest(
                from: Data(#"{"clientDescription":"fanctl"}"#.utf8)
            )
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }
}
