import SMCCore
import Testing

@testable import smc_sampler

@Suite("KeyReading")
struct KeyReadingTests {

    @Test("a successful outcome maps to status ok with the value and kind carried")
    func successfulOutcomeMapsToOk() {
        let reading = SensorReading(
            key: "TPD0", value: 55.5, kind: .temperatureCelsius, providerIdentifier: "smc")
        let outcome = SensorReadOutcome(key: "TPD0", result: .success(reading))

        let mapped = KeyReading.from(outcome)
        #expect(mapped.key == "TPD0")
        #expect(mapped.status == "ok")
        #expect(mapped.value == 55.5)
        #expect(mapped.kind == "temperatureCelsius")
        #expect(mapped.failureReason == nil)
    }

    @Test("an unknown key maps to status unknownKey with no value and no reason")
    func unknownKeyMapsToUnknownKeyStatus() {
        let outcome = SensorReadOutcome(key: "ZZZZ", result: .failure(.unknownKey("ZZZZ")))
        let mapped = KeyReading.from(outcome)
        #expect(mapped.status == "unknownKey")
        #expect(mapped.value == nil)
        #expect(mapped.failureReason == nil)
    }

    @Test("a read failure maps to status readFailed and carries the reason")
    func readFailureMapsToReadFailedStatus() {
        let outcome = SensorReadOutcome(
            key: "TPD0", result: .failure(.readFailed(reason: "no SMC")))
        let mapped = KeyReading.from(outcome)
        #expect(mapped.status == "readFailed")
        #expect(mapped.value == nil)
        #expect(mapped.failureReason == "no SMC")
    }

    @Test("a non-decodable value maps to status notDecodable and carries the reason")
    func notDecodableMapsToNotDecodableStatus() {
        let outcome = SensorReadOutcome(
            key: "TPD0", result: .failure(.notDecodable(reason: "not numeric")))
        let mapped = KeyReading.from(outcome)
        #expect(mapped.status == "notDecodable")
        #expect(mapped.value == nil)
        #expect(mapped.failureReason == "not numeric")
    }
}
