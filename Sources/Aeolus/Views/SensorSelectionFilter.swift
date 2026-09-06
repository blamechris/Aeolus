/// Applies `Preferences.selectedSensorKeys` to a live poll's sensor list.
enum SensorSelectionFilter {
    /// - Parameters:
    ///   - selectedKeys: `Preferences.selectedSensorKeys`. An empty set means "no
    ///     filter" — see that property's own documentation for why this is the default
    ///     rather than "show nothing."
    ///   - sensors: `PollingViewModel.sensors` at the moment of rendering.
    /// - Returns: Every sensor whose raw `key` is in `selectedKeys`, in `sensors`' own
    ///   order — matched by key, never by `decoration?.label`, per this project's rule
    ///   that a label is decoration, not an identity.
    static func apply(
        _ selectedKeys: Set<String>, to sensors: [SensorPollingReading]
    ) -> [SensorPollingReading] {
        guard !selectedKeys.isEmpty else { return sensors }
        return sensors.filter { selectedKeys.contains($0.key) }
    }
}
