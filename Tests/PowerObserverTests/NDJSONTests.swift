import Foundation
import Testing

@testable import power_observer

@Suite("NDJSON")
struct NDJSONTests {

    @Test("an event record encodes as one line of valid JSON with the documented keys")
    func eventRecordEncodesAsOneValidJSONLine() throws {
        let record = PowerEventRecord(
            messageTypeDecimal: 0xE000_0280,
            messageTypeHex: "0xE0000280",
            name: "kIOMessageSystemWillSleep",
            argument: 7,
            monotonicNanoseconds: 123_456_789,
            wallClockUTC: "2026-09-06T00:00:00.000Z",
            ackLatencyMicroseconds: 42,
            uid: 501,
            pid: 9999)

        let line = try NDJSON.line(record)

        #expect(!line.contains("\n"), "an NDJSON line must not contain an embedded newline")

        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let expectedKeys: Set<String> = [
            "kind", "messageTypeDecimal", "messageTypeHex", "name", "argument",
            "monotonicNanoseconds", "wallClockUTC", "ackLatencyMicroseconds", "uid", "pid",
        ]
        #expect(Set(decoded.keys) == expectedKeys)
        #expect(decoded["kind"] as? String == "event")
        #expect(decoded["name"] as? String == "kIOMessageSystemWillSleep")
        #expect(decoded["argument"] as? Int == 7)
        #expect(decoded["ackLatencyMicroseconds"] as? Int == 42)
    }

    @Test("a message needing no acknowledgement encodes a null latency, not a zero")
    func noAcknowledgementEncodesNullLatency() throws {
        let record = PowerEventRecord(
            messageTypeDecimal: 0xE000_0300,
            messageTypeHex: "0xE0000300",
            name: "kIOMessageSystemHasPoweredOn",
            argument: 0,
            monotonicNanoseconds: 1,
            wallClockUTC: "2026-09-06T00:00:00.000Z",
            ackLatencyMicroseconds: nil,
            uid: 501,
            pid: 9999)

        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["ackLatencyMicroseconds"] is NSNull)
    }

    @Test("a heartbeat line carries both clocks and its own kind")
    func heartbeatLineCarriesBothClocks() throws {
        let record = PowerHeartbeatRecord(
            monotonicNanoseconds: 555, wallClockUTC: "2026-09-06T00:00:01.000Z")
        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["kind"] as? String == "heartbeat")
        #expect(decoded["monotonicNanoseconds"] as? UInt64 == 555)
        #expect(decoded["wallClockUTC"] as? String == "2026-09-06T00:00:01.000Z")
    }

    @Test("a start line names the process and whether the helper was loaded")
    func startLineNamesTheProcess() throws {
        let record = PowerStartRecord(
            hostname: "test-host", hwModel: "Mac16,5", osVersion: "macOS 26.6.2", uid: 501,
            pid: 4242, helperLoaded: true)
        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["kind"] as? String == "start")
        #expect(decoded["helperLoaded"] as? Bool == true)
        #expect(decoded["hwModel"] as? String == "Mac16,5")
    }

    @Test("a stop line carries the per-type counts")
    func stopLineCarriesCounts() throws {
        let record = PowerStopRecord(counts: ["kIOMessageSystemWillSleep": 7, "unknown": 1])
        let line = try NDJSON.line(record)
        let data = try #require(line.data(using: .utf8))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["kind"] as? String == "stop")
        let counts = try #require(decoded["counts"] as? [String: Int])
        #expect(counts["kIOMessageSystemWillSleep"] == 7)
        #expect(counts["unknown"] == 1)
    }
}
