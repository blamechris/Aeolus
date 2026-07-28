@testable import fanctl

/// A `SensorCatalogLookup` double that answers from a fixed dictionary, so
/// `SensorsCommand` tests can assert labelled and unlabelled behaviour without any real
/// catalog (E6) being wired in — matching how `fanctl sensors` actually runs today.
struct FakeSensorCatalogLookup: SensorCatalogLookup {
    let labels: [String: SensorCatalogLabel]

    func label(for key: String) -> SensorCatalogLabel? {
        labels[key]
    }
}
