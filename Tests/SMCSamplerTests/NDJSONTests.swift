import Foundation
import Testing

@testable import smc_sampler

@Suite("NDJSON")
struct NDJSONTests {

    @Test("a start line names the resolved key list and its source")
    func startLineNamesKeysAndSource() throws {
        let record = SamplerStartRecord(
            hostname: "test-host", hwModel: "Mac16,5", osVersion: "macOS 26.6.2", uid: 501,
            pid: 4242, intervalSeconds: 1.0, keys: ["TPD0", "F0Ac"],
            keySource: "default(model:Mac16,5,fans:1)")

        let line = try NDJSON.line(record)
        #expect(!line.contains("\n"), "an NDJSON line must not contain an embedded newline")

        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["kind"] as? String == "start")
        #expect(decoded["keys"] as? [String] == ["TPD0", "F0Ac"])
        #expect(decoded["keySource"] as? String == "default(model:Mac16,5,fans:1)")
    }

    @Test("a sample line carries both clocks and a null delta on the first tick")
    func sampleLineCarriesBothClocksWithNoDeltaOnTick0() throws {
        let reading = KeyReading(
            key: "TPD0", status: "ok", value: 42.5, kind: "temperatureCelsius",
            failureReason: nil)
        let record = SampleRecord(
            tick: 0, wallClockUTC: "2026-09-16T00:00:00.000Z", continuousNanoseconds: 100,
            continuousDeltaNanoseconds: nil, suspendingNanoseconds: 100,
            suspendingDeltaNanoseconds: nil, readings: [reading])

        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["kind"] as? String == "sample")
        #expect(decoded["continuousNanoseconds"] as? Int64 == 100)
        #expect(decoded["suspendingNanoseconds"] as? Int64 == 100)
        #expect(decoded["continuousDeltaNanoseconds"] is NSNull)
        #expect(decoded["suspendingDeltaNanoseconds"] is NSNull)

        let readings = try #require(decoded["readings"] as? [[String: Any]])
        #expect(readings.count == 1)
        #expect(readings[0]["key"] as? String == "TPD0")
        #expect(readings[0]["status"] as? String == "ok")
        #expect(readings[0]["value"] as? Double == 42.5)
    }

    @Test("a sample line's delta fields carry a real number on a later tick")
    func sampleLineCarriesDeltaOnLaterTick() throws {
        let record = SampleRecord(
            tick: 1, wallClockUTC: "2026-09-16T00:00:01.000Z", continuousNanoseconds: 1_000,
            continuousDeltaNanoseconds: 900, suspendingNanoseconds: 1_000,
            suspendingDeltaNanoseconds: 900, readings: [])

        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["continuousDeltaNanoseconds"] as? Int64 == 900)
        #expect(decoded["suspendingDeltaNanoseconds"] as? Int64 == 900)
    }

    @Test("a failed reading carries a status and a failure reason, never a fabricated value")
    func failedReadingCarriesStatusAndReason() throws {
        let reading = KeyReading(
            key: "ZZZZ", status: "unknownKey", value: nil, kind: nil, failureReason: nil)
        let line = try NDJSON.line(reading)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["status"] as? String == "unknownKey")
        #expect(decoded["value"] is NSNull)
        #expect(decoded["kind"] is NSNull)
        #expect(decoded["failureReason"] is NSNull)
    }

    @Test("a heartbeat line carries both clocks and its own kind")
    func heartbeatLineCarriesBothClocks() throws {
        let record = SamplerHeartbeatRecord(
            wallClockUTC: "2026-09-16T00:00:01.000Z", continuousNanoseconds: 555,
            suspendingNanoseconds: 550)
        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["kind"] as? String == "heartbeat")
        #expect(decoded["continuousNanoseconds"] as? Int64 == 555)
        #expect(decoded["suspendingNanoseconds"] as? Int64 == 550)
    }

    @Test("a stop line carries the final tick count and both final clocks")
    func stopLineCarriesFinalCounts() throws {
        let record = SamplerStopRecord(
            totalTicks: 42, finalContinuousNanoseconds: 42_000, finalSuspendingNanoseconds: 41_000)
        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["kind"] as? String == "stop")
        #expect(decoded["totalTicks"] as? Int == 42)
        #expect(decoded["finalContinuousNanoseconds"] as? Int64 == 42_000)
        #expect(decoded["finalSuspendingNanoseconds"] as? Int64 == 41_000)
    }

    @Test("text containing a literal newline is rejected rather than shipped as two lines")
    func embeddedNewlineIsRejected() {
        #expect(throws: NDJSON.EncodingFailure.embeddedNewline) {
            try NDJSON.rejectingEmbeddedNewline("{\"a\":1}\n{\"b\":2}")
        }
    }

    @Test("text with no embedded newline passes through unchanged")
    func noEmbeddedNewlinePassesThrough() throws {
        #expect(try NDJSON.rejectingEmbeddedNewline("{\"a\":1}") == "{\"a\":1}")
    }
}
