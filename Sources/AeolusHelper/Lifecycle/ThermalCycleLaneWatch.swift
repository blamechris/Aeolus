/// Writes `SchedulerEvent.thermalCycleLaneOverlapped` to the safety log, and hears nothing else.
///
/// The scheduler reports the event when a request arrives in § 3's lane while another is
/// outstanding: at each new depth, and each time the overlapping arrivals reach a power of two
/// (`SMCReadScheduler.noteThermalCycleRequest()`), and this is where the
/// report becomes a line somebody can find afterwards: a `.fault`, because the premise both of
/// ADR 0012's lane bounds rest on did not hold, and the wait the second request had was not the
/// one derived for it. Nothing is acted on — the request was admitted in the lane as normal — so
/// the observer holds no state and takes no lock, which is what `SchedulerObserving` asks of a
/// conformer called from inside the scheduler's isolation.
///
/// `HelperComposition.production` hands it to the scheduler beside `ConnectionHealth` and the
/// gate monitor; `GateMonitorWiringTests` holds the wiring.
struct ThermalCycleLaneWatch: SchedulerObserving {

    let log: SafetyLog

    func schedulerDidObserve(_ event: SchedulerEvent) {
        guard case .thermalCycleLaneOverlapped(let outstanding, let arrivals) = event else {
            return
        }
        log.thermalCycleLaneOverlapped(outstanding: outstanding, overlappingArrivals: arrivals)
    }
}
