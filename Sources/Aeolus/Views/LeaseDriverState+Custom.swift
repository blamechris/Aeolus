import AeolusLeaseControl

/// What a driver report says is in Custom, for each fan's row (#154): read by
/// `FanRowControlPresentation` and by `AppComposition.releaseFan(_:)`, so the row and the root
/// read one answer.
extension LeaseDriverState {

    /// The fans this report names in Custom, ascending, as the driver composes per-fan requests
    /// over them (#154's ruling, Q1), or `nil` when it does not say.
    ///
    /// - `held`: the target queued, or else the one in flight or confirmed.
    /// - `acquiring`: the fans asked for.
    /// - `releasing`: **unknown**. The driver may be holding a target to acquire once the release
    ///   answers, and the report does not carry it.
    /// - `idle`, `released`, `lost`, `refused`: none. A loss is final.
    var fansInCustom: [Int]? {
        switch self {
        case .held(let held):
            return held.phase.newest.fans
        case .acquiring(let fans):
            return fans
        case .releasing:
            return nil
        case .idle, .released, .lost, .refused:
            return []
        }
    }

    /// The speed this report says the driver asks fan `index` to hold, or `nil`. Only `held`
    /// carries a target: an acquisition's speeds are not in the report.
    func target(forFan index: Int) -> FanRowControlPresentation.DriverTarget? {
        guard case .held(let held) = self, let speed = held.phase.newest.speeds[index] else {
            return nil
        }
        if case .applying = held.phase {
            return FanRowControlPresentation.DriverTarget(speed: speed, isPending: true)
        }
        return FanRowControlPresentation.DriverTarget(speed: speed, isPending: false)
    }
}

extension HeldLease.Phase {

    /// The newest target asked for under the lease: the one queued, or else the one in flight or
    /// confirmed.
    fileprivate var newest: LeaseTarget {
        switch self {
        case .applying(let sending, let queued): return queued ?? sending
        case .confirmed(let confirmed): return confirmed
        }
    }
}
