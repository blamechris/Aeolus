import FanKit

@testable import AeolusUI

/// A `SensorLabelSource` double answering from a fixed dictionary, so `PollingEngine`/
/// `SensorPoller` tests can assert a `SensorPollingReading.decoration` was actually
/// threaded through without depending on `FanKit.CatalogLoader`'s real bundled resource.
struct FakeSensorLabelSource: SensorLabelSource {
    let decorationsByKey: [String: CatalogDecoration]

    init(decorationsByKey: [String: CatalogDecoration] = [:]) {
        self.decorationsByKey = decorationsByKey
    }

    func decoration(for key: String) -> CatalogDecoration? {
        decorationsByKey[key]
    }
}
