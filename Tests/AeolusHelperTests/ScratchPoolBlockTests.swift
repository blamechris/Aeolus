import Dispatch
import Testing

/// SCRATCH, never merged (#593). Parks a pool thread on a release that only the pool can
/// deliver, which is the shape docs/TESTING.md forbids. It passes where the pool has a second
/// thread and wedges where it has one.
@Suite("SCRATCH pool-blocking demonstration")
struct ScratchPoolBlockTests {

    private static func parkUntil(_ release: DispatchSemaphore) {
        release.wait()
    }

    @Test("A pool thread is held on a release the pool must deliver")
    func holdsAPoolThreadOnAPoolDeliveredRelease() async {
        let release = DispatchSemaphore(value: 0)
        Task.detached { release.signal() }
        Self.parkUntil(release)
    }
}
