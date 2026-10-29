/// The Unicode code space, handed out a run at a time so a sweep gives the cooperative pool back
/// between runs (#570).
///
/// A test that walks every scalar is a synchronous loop. In an `async` test with no suspension
/// point it holds one cooperative-pool thread from its first scalar to its last, and CI runs
/// every test in one process on a pool three threads wide. On CI, three sweeps that started
/// together ran for about ten seconds with no other test finishing, and a 250 ms client deadline
/// in an unrelated suite, which needs a pool thread to be told its reply has arrived, ran out in
/// that window (inferred from the log's timing, not reproduced). A run that ends in
/// `Task.yield()` hands the thread to whatever is queued behind it.
///
/// **Every test target that sweeps the code space carries an identical copy of this file.** Test
/// targets cannot share code, and moving the helper into a product module to get round that would
/// ship test machinery in the product.
enum CodeSpace {

    /// Scalar values per run. A run is a millisecond or two of work in a debug build, so what is
    /// queued behind a sweep waits for a run, not for the sweep.
    static let runLength: UInt32 = 4_096

    /// Calls `body` with each run of scalars, in ascending order, covering U+0000 to U+10FFFF
    /// except the surrogates, and yields the pool after each.
    ///
    /// The yield is not a `throws` point: a cancelled sweep still finishes, because a sweep that
    /// stopped early would pass having looked at part of the code space.
    static func forEachRun(_ body: ([Unicode.Scalar]) -> Void) async {
        let end: UInt32 = 0x11_0000
        var start: UInt32 = 0
        while start < end {
            let stop = min(start + runLength, end)
            body((start..<stop).compactMap { Unicode.Scalar($0) })
            start = stop
            await Task.yield()
        }
    }
}
