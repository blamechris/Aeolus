@testable import fanctl

/// A `SensorCatalogLookup` double that answers from a fixed dictionary, so
/// `SensorsCommand` tests can assert labelled and unlabelled behaviour without depending
/// on `CatalogSensorLookup`'s real catalog-loading and resolution machinery.
struct FakeSensorCatalogLookup: SensorCatalogLookup {
    let labels: [String: SensorCatalogLabel]

    func label(for key: String) -> SensorCatalogLabel? {
        labels[key]
    }
}
