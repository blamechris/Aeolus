import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

/// `fanctl status` — what the helper says about every fan, and who holds them.
///
/// ## What this command is allowed to say
///
/// Only what one `snapshot()` reply carried, attributed to the moment the helper captured it.
/// Nothing is inferred and nothing is cached. In particular:
///
/// - **The lease is reported apart from the fans.** A lease is a claim on the fans; a fan's
///   `mode` and `targetRPM` are what the helper observed. A lease that exists while a fan
///   reads `automatic` is two facts, and printing them side by side is how a user sees that
///   whoever holds the lease is not driving that fan.
/// - **`targetRPM` is labelled as a target**, never as a speed. The speed is `actualRPM`.
/// - **A reclaimed fan says so** on its own line (`CLAUDE.md` rule 6).
/// - **Manual-control availability carries its reason and the advice for it** —
///   `ManualControlAvailability.Reason`'s own summary and recovery text from #310, not a
///   paraphrase that could drift from them.
/// - **The version line says "negotiated"** because, unlike `fanctl --version`, this command
///   has completed a `hello` with the helper that answered.
enum StatusCommand {

    typealias Reason = ManualControlAvailability.Reason

    /// Everything one run reports: the snapshot and the handshake it was taken under.
    struct Observation: Equatable, Sendable {
        let snapshot: SystemSnapshot
        let helper: HelloReply?
    }

    // MARK: - Text

    static func text(for observation: Observation) -> String {
        let snapshot = observation.snapshot
        var lines: [String] = []
        lines.append(versionLine(for: observation))
        lines.append("Captured by the helper at \(iso8601(snapshot.capturedAt)).")
        lines.append("")
        lines.append(contentsOf: leaseLines(snapshot.activeLease, capturedAt: snapshot.capturedAt))
        lines.append(
            snapshot.isThermalEmergencyActive
                ? "Thermal emergency: ACTIVE — the helper's override outranks manual control."
                : "Thermal emergency: not active.")
        if snapshot.fans.isEmpty {
            lines.append("")
            lines.append("The helper reported no fans.")
        }
        for fan in snapshot.fans {
            lines.append("")
            lines.append(contentsOf: fanLines(fan))
        }
        return lines.joined(separator: "\n")
    }

    static func versionLine(for observation: Observation) -> String {
        let snapshotVersion = observation.snapshot.protocolVersion
        guard let helper = observation.helper else {
            return """
                XPC protocol \(snapshotVersion) (this snapshot); fanctl \(Fanctl.toolVersion) \
                speaks \(AeolusXPCVersion.current).
                """
        }
        let range = helper.helperProtocolRange
        return """
            Helper \(DisplayText.sanitised(helper.helperBuild)), negotiated XPC protocol \
            \(snapshotVersion) (helper accepts \(range.minimumSupported)–\(range.current); \
            fanctl \(Fanctl.toolVersion) speaks \(AeolusXPCVersion.current)).
            """
    }

    static func leaseLines(_ lease: Lease?, capturedAt: Date) -> [String] {
        guard let lease else {
            return ["Manual-control lease: none. No client holds the fans."]
        }
        let remaining = lease.expiresAt.timeIntervalSince(capturedAt)
        let expiry =
            remaining > 0
            ? "expires \(iso8601(lease.expiresAt)) (\(Formatting.number(remaining.rounded())) s "
                + "after capture)"
            : "expired \(iso8601(lease.expiresAt)), at or before capture"
        return [
            "Manual-control lease: held by \"\(DisplayText.sanitised(lease.holderDescription))\"",
            "  \(expiry); renewed every heartbeat or it ends and the helper restores automatic "
                + "control",
            "  self-renewing: \(lease.isSelfRenewing ? "yes" : "no") · id \(lease.id.uuidString)",
        ]
    }

    static func fanLines(_ fan: FanState) -> [String] {
        var title = "Fan \(fan.index)"
        if let name = fan.firmwareName {
            title += " (firmware name \"\(DisplayText.sanitised(name))\")"
        }
        let range = "\(rpm(fan.minimumRPM)) to \(rpm(fan.maximumRPM))"
        let target = fan.targetRPM.map { "\(Formatting.number($0)) RPM" } ?? "none"
        var lines = [
            title,
            "  actual \(rpm(fan.actualRPM)) · range \(range)",
            "  mode \(fan.mode.rawValue) · target \(target)",
        ]
        if fan.isReclaimedBySystem {
            lines.append(
                "  RECLAIMED BY THE SYSTEM: Aeolus is not driving this fan right now, whatever "
                    + "the target says.")
        }
        lines.append("  manual control: \(availability(fan.manualControlAvailability))")
        return lines
    }

    static func availability(_ availability: ManualControlAvailability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            let shown = displayable(reason)
            return "unavailable — \(shown.recoveryDescription) (reason: \(shown.wireValue))"
        }
    }

    /// `.unknown`'s payload is helper-authored free text, sanitised before it is printed.
    static func displayable(_ reason: Reason) -> Reason {
        guard case .unknown(let raw) = reason else { return reason }
        return .unknown(DisplayText.sanitised(raw))
    }

    /// Read through `FanReading.value`, not by matching the measured case:
    /// `MeasuredFiniteConstructionSiteTests` reserves that spelling for `Fan.swift`.
    static func rpm(_ reading: FanReading) -> String {
        if let value = reading.value { return "\(Formatting.number(value)) RPM" }
        return "unavailable (\(DisplayText.sanitised(unavailableReason(reading))))"
    }

    /// The reason a reading carries when it has no value.
    static func unavailableReason(_ reading: FanReading) -> String {
        guard case .unavailable(let reason) = reading else { return "no reason given" }
        return reason
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Command wiring

extension Fanctl.Status {

    /// One handshake, one snapshot, one disconnect.
    ///
    /// Everything here is asserted end to end by `FanctlStatusTests`, which reaches this
    /// function itself by setting `helper` and `terminal`.
    func run() async throws {
        let format: HelperCommandOutput.Format = json ? .document : .text
        let client = helper.client()
        let outcome: Result<StatusCommand.Observation, any Error>
        do {
            let snapshot = try await client.snapshot()
            outcome = .success(
                StatusCommand.Observation(snapshot: snapshot, helper: await client.negotiated))
        } catch {
            outcome = .failure(error)
        }
        await client.disconnect()

        switch outcome {
        case .success(let observation):
            if json {
                try HelperCommandOutput.emit(
                    StatusDocumentJSON(observation), as: format, on: terminal)
            } else {
                terminal.say(StatusCommand.text(for: observation))
            }
        case .failure(let error):
            try HelperCommandOutput.fail(
                HelperCommandFailure(classifying: error, during: .beforeControl),
                as: format, on: terminal)
        }
    }
}
