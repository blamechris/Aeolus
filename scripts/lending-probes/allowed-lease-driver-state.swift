// The positive control for refused-heartbeat-accessor.swift: the same import and the same driver,
// naming a member that is `public`. It must compile, or the refusal next to it could be the
// module failing to import, or the driver having lost its API, rather than the accessor being out
// of reach.
import AeolusLeaseControl

func readTheState(_ driver: LeaseDriver) async -> LeaseDriverState {
    await driver.state
}
