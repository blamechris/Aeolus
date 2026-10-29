import Testing

/// The Unicode code space, handed out a run at a time so a sweep gives the cooperative pool back
/// between runs (#570).
///
/// A test that walks every scalar is a synchronous loop. In an `async` test with no suspension
/// point it holds one cooperative-pool thread from its first scalar to its last, and CI runs
/// every test in one process on a pool three threads wide. That is real load on the pool: on a
/// pool of one thread, a task asking to be resumed every 10 ms came back 1.1 to 1.9 s late with
/// the sweeps unbroken, and 11 to 12 ms late with them in runs (five debug runs each). Whether
/// they contributed to the CI failure that raised #570, a 250 ms client deadline in
/// `HelperClientTeardownTests` that ran out, was not shown: a CI run with the sweeps in runs
/// still had the same silent first seconds, and that deadline's exposure is #421's. A run that
/// ends in `Task.yield()` hands the thread to whatever is queued behind it.
///
/// **Every test target that sweeps the code space carries an identical copy of this file.** Test
/// targets cannot share code, and moving the helper into a product module to get round that would
/// ship test machinery in the product. `CodeSpaceTests` holds the `AeolusHelperTests` copy to its
/// yield; the other three are held to it only by being byte-identical, by convention.
enum CodeSpace {

    /// Scalar values per run. A run is a millisecond or two of work in a debug build, so what is
    /// queued behind a sweep waits for a run, not for the sweep.
    static let runLength: UInt32 = 4_096

    /// How many Unicode scalar values there are: U+0000 to U+10FFFF, less the 2,048 surrogates.
    /// A literal, not derived from the loop's own bounds, so a walk that stopped short is red.
    static let scalarCount = 1_112_064

    /// Calls `body` with each run of scalars, in ascending order, covering U+0000 to U+10FFFF
    /// except the surrogates, and yields the pool after each.
    ///
    /// A sweep that quietly looked at part of the code space would pass, so the walk counts what
    /// it handed out and records an issue at the caller's line if that is not every scalar. The
    /// yield is not a `throws` point for the same reason: a cancelled sweep still finishes.
    static func forEachRun(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: ([Unicode.Scalar]) -> Void
    ) async {
        let end: UInt32 = 0x11_0000
        var start: UInt32 = 0
        var visited = 0
        while start < end {
            let stop = min(start + runLength, end)
            let run = (start..<stop).compactMap { Unicode.Scalar($0) }
            visited += run.count
            body(run)
            start = stop
            await Task.yield()
        }
        #expect(
            visited == scalarCount, "the walk handed out \(visited) of \(scalarCount) scalars",
            sourceLocation: sourceLocation)
    }
}
