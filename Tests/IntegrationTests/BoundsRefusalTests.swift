import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// A refused fan has to say *why*, in one vocabulary, whichever direction the answer
/// travels: as `manualControlAvailability` inside a snapshot, or as a fault refusing a
/// request. Both come from `FanKit`'s bounds gate, and this is where the two halves are
/// checked against each other — `FanKitTests` cannot see `AeolusXPC`, and the helper has
/// no write path for either half to be raised from yet.
///
/// No protocol bump is involved and none is possible from here:
/// `ManualControlAvailability.Reason.boundsImplausible` and
/// `AeolusXPCFault.boundsImplausible` were both written in E2, for exactly this.
@Suite("Bounds refusals cross the boundary")
struct BoundsRefusalTests {

    static let everyImplausibility: [FanBoundsImplausibility] = [
        .notMeasured,
        .notFinite,
        .negativeMinimum,
        .notAscending,
        .maximumBelowFloor,
        .maximumAboveCeiling,
    ]

    /// The reason a snapshot carries and the reason a refusal carries must be the same
    /// answer to the same question, so a client sees one story rather than two.
    @Test(
        "Every bounds refusal is boundsImplausible in both vocabularies",
        arguments: everyImplausibility)
    func bothVocabulariesAgree(implausibility: FanBoundsImplausibility) throws {
        #expect(
            implausibility.manualControlAvailability == .unavailable(.boundsImplausible))

        let fault = AeolusXPCFault.boundsImplausible(
            fanIndex: 0, implausibility: implausibility)
        #expect(fault.wireCode == "boundsImplausible")

        let data = try AeolusXPCCoding.encoder().encode(fault)
        let decoded = try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: data)
        #expect(decoded == fault)
    }

    /// The detail is the model's own description rather than a string written at the call
    /// site, so the two cannot drift — and because it is helper-authored, nothing a client
    /// sent can steer the log line it lands in.
    @Test("The fault detail comes from the gate, not from the call site")
    func detailComesFromTheGate() {
        let fault = AeolusXPCFault.boundsImplausible(
            fanIndex: 2, implausibility: .maximumAboveCeiling)

        guard case .boundsImplausible(let fanIndex, let detail) = fault else {
            Issue.record("the constructed fault was not boundsImplausible")
            return
        }
        #expect(fanIndex == 2)
        #expect(detail == FanBoundsImplausibility.maximumAboveCeiling.description)
        #expect(fault.errorDescription?.contains("Fan 2") == true)
    }

    /// A refusal is distinct from "no helper" and from "no such fan". All three are
    /// reachable states of the same client and must not render as each other.
    @Test("A bounds refusal is not confusable with the other ways control is refused")
    func distinctFromTheOtherRefusals() {
        let bounds = ManualControlAvailability.unavailable(.boundsImplausible)
        let noWritePath = ManualControlAvailability.unavailable(.writePathNotBuilt)

        #expect(bounds != noWritePath)
        #expect(bounds != .available)
        // "No such fan" is not an availability at all — it is a rejected parameter, which
        // is the distinction the vocabulary exists to keep.
        let noSuchFan = AeolusXPCFault.invalidParameter(
            name: "fanIndices", detail: "names a fan this machine did not enumerate")
        #expect(
            noSuchFan.wireCode
                != AeolusXPCFault.boundsImplausible(
                    fanIndex: 0, implausibility: .notAscending
                ).wireCode)
    }
}
