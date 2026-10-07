import Foundation
import SMCCore
import Testing

@testable import smc_sampler

/// The NDJSON shape of the two `--latency` records, and the classification that turns a
/// provider answer (or a provider that threw) into the `status` a `read` line carries.
@Suite("Latency records")
struct LatencyRecordTests {

    private func decode(_ line: String) throws -> [String: Any] {
        #expect(!line.contains("\n"), "an NDJSON line must not contain an embedded newline")
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a read line carries exactly the documented fields, with an explicit null reason")
    func readLineShape() throws {
        let record = LatencyReadRecord(
            index: 7, key: "F0Ac", status: "ok", failureReason: nil,
            continuousNanoseconds: 12_345, suspendingNanoseconds: 12_000,
            atContinuousNanoseconds: 9_000_000)
        let decoded = try decode(try NDJSON.line(record))

        #expect(
            Set(decoded.keys) == [
                "kind", "index", "key", "status", "failureReason",
                "continuousNanoseconds", "suspendingNanoseconds", "atContinuousNanoseconds",
            ])
        #expect(decoded["kind"] as? String == "read")
        #expect(decoded["index"] as? Int == 7)
        #expect(decoded["key"] as? String == "F0Ac")
        #expect(decoded["status"] as? String == "ok")
        #expect(decoded["continuousNanoseconds"] as? Int == 12_345)
        #expect(decoded["suspendingNanoseconds"] as? Int == 12_000)
        #expect(decoded["atContinuousNanoseconds"] as? Int == 9_000_000)
        // Present and null, not absent: an absent key could be a future version that stopped
        // reporting reasons, which is the ambiguity `SampleRecord.encode(to:)` documents.
        #expect(decoded["failureReason"] is NSNull)
    }

    @Test("a failed read line carries its reason")
    func failedReadLineCarriesReason() throws {
        let record = LatencyReadRecord(
            index: 0, key: "F0Ac", status: "readFailed", failureReason: "firmware said no",
            continuousNanoseconds: 1, suspendingNanoseconds: 1, atContinuousNanoseconds: 0)
        let decoded = try decode(try NDJSON.line(record))
        #expect(decoded["status"] as? String == "readFailed")
        #expect(decoded["failureReason"] as? String == "firmware said no")
    }

    @Test("a summary line has the documented fields, explicit nulls when empty, and the flags")
    func emptySummaryLineShape() throws {
        let accumulator = LatencyAccumulator()
        let summary = accumulator.summary(
            requestedCount: 20, warmup: [LatencyWarmupOutcome(key: "F0Ac", status: "ok")])
        let decoded = try decode(try NDJSON.line(summary))

        #expect(decoded["kind"] as? String == "latencySummary")
        for field in [
            "minContinuousNanoseconds", "p50ContinuousNanoseconds", "p99ContinuousNanoseconds",
            "p999ContinuousNanoseconds", "p9999ContinuousNanoseconds",
            "maxContinuousNanoseconds", "maxAllReadsContinuousNanoseconds",
        ] {
            let value = try #require(decoded[field], "\(field) must be present, as null")
            #expect(value is NSNull, "\(field) must be an explicit null with no reads")
        }
        #expect(decoded["count"] as? Int == 0)
        #expect(decoded["okCount"] as? Int == 0)
        #expect(decoded["failureCount"] as? Int == 0)
        #expect(decoded["requestedCount"] as? Int == 20)
        #expect(decoded["interrupted"] as? Bool == true)
        #expect(decoded["p999Meaningful"] as? Bool == false)
        #expect(decoded["p9999Meaningful"] as? Bool == false)
        #expect((decoded["slowest"] as? [Any])?.isEmpty == true)
        let warmup = try #require(decoded["warmup"] as? [[String: Any]])
        #expect(warmup.first?["key"] as? String == "F0Ac")
        #expect(warmup.first?["status"] as? String == "ok")
    }

    @Test("a populated summary line carries the percentile basis and the p99.99 warning text")
    func populatedSummaryLine() throws {
        var accumulator = LatencyAccumulator()
        for index in 0..<30 {
            accumulator.record(
                LatencyReadRecord(
                    index: index, key: "F0Ac", status: "ok", failureReason: nil,
                    continuousNanoseconds: Int64(1_000 + index), suspendingNanoseconds: 1,
                    atContinuousNanoseconds: Int64(index)))
        }
        let decoded = try decode(
            try NDJSON.line(accumulator.summary(requestedCount: 30, warmup: [])))

        #expect(decoded["count"] as? Int == 30)
        #expect(decoded["okCount"] as? Int == 30)
        #expect(decoded["percentileSampleSize"] as? Int == 30)
        #expect(decoded["interrupted"] as? Bool == false)
        #expect(decoded["maxContinuousNanoseconds"] as? Int == 1_029)
        #expect(decoded["minContinuousNanoseconds"] as? Int == 1_000)
        #expect(decoded["p9999Meaningful"] as? Bool == false)
        let note = try #require(decoded["p9999Note"] as? String)
        #expect(note.contains("10000"), "the note must say how many reads p99.99 needs")
        let basis = try #require(decoded["percentileBasis"] as? String)
        #expect(basis.contains("nearest-rank"))
        let slowest = try #require(decoded["slowest"] as? [[String: Any]])
        #expect(slowest.count == 10)
        #expect(
            Set(slowest[0].keys) == [
                "index", "key", "status", "continuousNanoseconds", "suspendingNanoseconds",
                "atContinuousNanoseconds",
            ])
        #expect(slowest[0]["index"] as? Int == 29)
    }

    // MARK: - Classification

    @Test("a successful outcome classifies as ok with no reason")
    func okClassification() {
        let outcome = SensorReadOutcome(
            key: "F0Ac",
            result: .success(
                SensorReading(key: "F0Ac", value: 1, kind: .rpm, providerIdentifier: "t")))
        let result = LatencyReadClassification.classify(
            .success([outcome]), key: "F0Ac")
        #expect(result.status == "ok")
        #expect(result.failureReason == nil)
    }

    @Test("each per-key failure keeps the status word KeyReading already uses")
    func failureClassificationUsesExistingVocabulary() {
        func classify(_ failure: SensorReadFailure) -> (status: String, failureReason: String?) {
            LatencyReadClassification.classify(
                .success([SensorReadOutcome(key: "F0Ac", result: .failure(failure))]),
                key: "F0Ac")
        }
        #expect(classify(.unknownKey("F0Ac")).status == "unknownKey")
        let read = classify(.readFailed(reason: "boom"))
        #expect(read.status == "readFailed")
        #expect(read.failureReason == "boom")
        let decode = classify(.notDecodable(reason: "not numeric"))
        #expect(decode.status == "notDecodable")
        #expect(decode.failureReason == "not numeric")
    }

    @Test("a provider that threw classifies as providerError, with the error as the reason")
    func thrownClassification() {
        struct Boom: Error, CustomStringConvertible { var description: String { "Boom!" } }
        let result = LatencyReadClassification.classify(.failure(Boom()), key: "F0Ac")
        #expect(result.status == "providerError")
        #expect(result.failureReason == "Boom!")
    }

    @Test("a provider that answered for some other key, or none, is a failure, not an ok")
    func missingOutcomeClassification() {
        let none = LatencyReadClassification.classify(.success([]), key: "F0Ac")
        #expect(none.status == "noOutcome")
        #expect(none.failureReason != nil)

        let other = SensorReadOutcome(
            key: "F1Ac",
            result: .success(
                SensorReading(key: "F1Ac", value: 1, kind: .rpm, providerIdentifier: "t")))
        let mismatched = LatencyReadClassification.classify(.success([other]), key: "F0Ac")
        #expect(mismatched.status == "noOutcome")
    }
}
