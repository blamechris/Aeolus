// expect-line: 11
// expect: 'HeartbeatHandle' is inaccessible due to 'internal' protection level
// see: the AeolusLeaseControl target in Package.swift, and the doc on LeaseDriver.runningHeartbeat (#489, #491)
// Not a lending shape. The handle `runningHeartbeat` returns is `internal` too, and this names its
// type from another module, which is what any route that returns the handle has to be able to do.
// So it goes red if the handle is made nameable (the accessor probe next to it would stay green
// if a second member returned it), and it does not hold a route that hides the handle, such as a
// public method that waits on it: only review holds that. A plain `import`, never `@testable`.
import AeolusLeaseControl

func holdTheHandle(_ handle: LeaseDriver.HeartbeatHandle) {}
