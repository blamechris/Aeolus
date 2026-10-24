// expect-line: 13
// expect: 'runningHeartbeat' is inaccessible due to 'internal' protection level
// see: the AeolusLeaseControl target in Package.swift, and the doc on LeaseDriver.runningHeartbeat (#489, #491)
// Not a lending shape. The driver's heartbeat accessor is `internal`, for the test suite alone, and
// the module boundary is what keeps the rest of the app from naming it: `internal` does not cross
// a module. A plain `import`, never `@testable`, is the app's side of that boundary. This probe
// goes red if the accessor is widened to `package` (this file is not in the package, so the
// refusal would say "package") or to `public` (it would compile), or if the target is folded back
// into `AeolusUI` (this module would not exist).
import AeolusLeaseControl

func nameTheHeartbeat(_ driver: LeaseDriver) async {
    _ = await driver.runningHeartbeat
}
