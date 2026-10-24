/// The menu bar item's icon: never identical to the normal state while the helper reports an
/// emergency or a reclaimed fan, or while a build that has a helper cannot say whether there is
/// an emergency.
///
/// Pure, so each rule is a unit test rather than a look at the menu bar.
///
/// - An emergency the helper reports: the filled warning triangle.
/// - Any fan the helper reports reclaimed — any fan, not only a selected readout's: the open
///   triangle.
/// - Unknown, in a build with a helper — connecting, waiting, unreachable, or a wedge during
///   what may be an emergency: a question mark. Before #478's fold that state fell back to the
///   plain fan, so a helper that stopped answering mid-emergency read as "all clear".
/// - Otherwise the plain fan. In a build with no helper the emergency is always unknown, and a
///   question mark that never goes away would say nothing; the dropdown says why instead.
enum MenuBarIcon {
    static func systemName(
        thermalEmergency: ThermalEmergencyState,
        controlSource: ControlSource,
        anyFanReportedReclaimed: Bool
    ) -> String {
        if thermalEmergency == .active { return "exclamationmark.triangle.fill" }
        if anyFanReportedReclaimed { return "exclamationmark.triangle" }
        if thermalEmergency == .unknown, expectsHelper(controlSource) {
            return "questionmark.circle"
        }
        return "fan"
    }

    /// Whether this build has a helper the app is reading, or trying to.
    private static func expectsHelper(_ source: ControlSource) -> Bool {
        switch source {
        case .helperSnapshot:
            return true
        case .notTracked(let why):
            switch why {
            case .noHelperInThisBuild, .helperInstallIncomplete, .nothingReadYet:
                return false
            case .helperConnection, .awaitingSnapshot, .snapshotRequestFailed,
                .snapshotContradicted, .snapshotStale:
                return true
            }
        }
    }
}
