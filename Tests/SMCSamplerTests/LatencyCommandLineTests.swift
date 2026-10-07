import Testing

@testable import smc_sampler

/// `--latency`'s command-line contract: it needs `--count` (rejected at parse time, in
/// either argument order), it reads back to back unless `--interval` was given explicitly,
/// it defaults to `F0Ac`, and none of the existing modes moved.
@Suite("CommandLineOptions --latency")
struct LatencyCommandLineTests {

    @Test("--latency without --count is rejected at parse time")
    func latencyWithoutCountIsRejected() {
        #expect(throws: CommandLineOptions.ParseError.latencyRequiresCount) {
            try CommandLineOptions.parse(["--latency"])
        }
        #expect(throws: CommandLineOptions.ParseError.latencyRequiresCount) {
            try CommandLineOptions.parse(["--latency", "--keys=F0Ac", "--interval=0.5"])
        }
    }

    @Test("--latency with --count parses in either order")
    func latencyWithCountParsesInEitherOrder() throws {
        let first = try CommandLineOptions.parse(["--latency", "--count=5"])
        let second = try CommandLineOptions.parse(["--count", "5", "--latency"])
        #expect(first == second)
        #expect(first.latency == true)
        #expect(first.tickCount == 5)
        #expect(first.keys.isEmpty, "the F0Ac default is resolved later, not baked into parsing")
    }

    @Test("--latency is a bare flag: a value is rejected, not swallowed")
    func latencyTakesNoValue() {
        #expect(throws: CommandLineOptions.ParseError.unrecognizedArgument("--latency=1")) {
            try CommandLineOptions.parse(["--latency=1", "--count=5"])
        }
        // `--latency 5` must not read "5" as its value; "5" is then an argument nobody owns.
        #expect(throws: CommandLineOptions.ParseError.unrecognizedArgument("5")) {
            try CommandLineOptions.parse(["--latency", "5", "--count=5"])
        }
    }

    @Test("an invalid --count is still reported as an invalid --count under --latency")
    func invalidCountUnderLatency() {
        #expect(throws: CommandLineOptions.ParseError.invalidCount("0")) {
            try CommandLineOptions.parse(["--latency", "--count=0"])
        }
    }

    @Test("--latency reads back to back unless --interval was given explicitly")
    func latencyIntervalIsZeroUnlessGiven() throws {
        let backToBack = try CommandLineOptions.parse(["--latency", "--count=5"])
        #expect(backToBack.intervalWasGiven == false)
        #expect(backToBack.effectiveIntervalSeconds == 0)

        let paced = try CommandLineOptions.parse(["--latency", "--count=5", "--interval=0.25"])
        #expect(paced.intervalWasGiven == true)
        #expect(paced.effectiveIntervalSeconds == 0.25)

        // An explicit interval equal to the default is still explicit.
        let explicitDefault = try CommandLineOptions.parse(
            ["--latency", "--count=5", "--interval=1"])
        #expect(explicitDefault.intervalWasGiven == true)
        #expect(explicitDefault.effectiveIntervalSeconds == 1.0)
    }

    @Test("the existing sampler mode is unchanged: default interval 1, no latency")
    func existingModeIsUnchanged() throws {
        let plain = try CommandLineOptions.parse([])
        #expect(plain.latency == false)
        #expect(plain.intervalSeconds == 1.0)
        #expect(plain.intervalWasGiven == false)
        #expect(plain.effectiveIntervalSeconds == 1.0)
        #expect(plain.tickCount == nil)

        let counted = try CommandLineOptions.parse(["--count=5", "--interval=2"])
        #expect(counted.latency == false)
        #expect(counted.effectiveIntervalSeconds == 2.0)
        #expect(counted.tickCount == 5)
    }

    // MARK: - Diagnostics

    @Test("the missing --count diagnostic names both flags and says what --count means here")
    func latencyRequiresCountDiagnostic() {
        let message = CommandLineOptions.diagnostic(
            for: CommandLineOptions.ParseError.latencyRequiresCount)
        #expect(message.contains("--latency"))
        #expect(message.contains("--count"))
    }

    @Test("every other parse error keeps its existing rendering")
    func otherDiagnosticsAreUnchanged() {
        #expect(
            CommandLineOptions.diagnostic(
                for: CommandLineOptions.ParseError.invalidInterval("0"))
                == "\(CommandLineOptions.ParseError.invalidInterval("0"))")
        struct Opaque: Error {}
        #expect(CommandLineOptions.diagnostic(for: Opaque()) == "\(Opaque())")
    }

    // MARK: - Key resolution

    @Test("the latency default key set is F0Ac alone, and says where it came from")
    func latencyDefaultKeys() {
        let selection = MeasurementKeySet.resolvedLatencyKeys(custom: [])
        #expect(selection.keys == ["F0Ac"])
        #expect(selection.keySource == "latency-default")
    }

    @Test("--keys overrides the latency default, deduplicated and in order")
    func latencyCustomKeys() {
        let selection = MeasurementKeySet.resolvedLatencyKeys(custom: ["TPD0", "F0Ac", "TPD0"])
        #expect(selection.keys == ["TPD0", "F0Ac"])
        #expect(selection.keySource == "custom")
    }

    @Test("selection: --latency takes the latency set whatever the machine and fans are")
    func selectionForLatency() throws {
        let options = try CommandLineOptions.parse(["--latency", "--count=3"])
        let selection = MeasurementKeySet.selection(
            for: options, model: "Mac16,5", fanIndices: [0, 1])
        #expect(selection.keys == ["F0Ac"])
        #expect(selection.keySourceWhenNoOutcome == "latency-default")
    }

    @Test("selection: --latency with --keys times those keys, reported as custom")
    func selectionForLatencyWithCustomKeys() throws {
        let options = try CommandLineOptions.parse(["--latency", "--count=3", "--keys=TPD0,F1Ac"])
        let selection = MeasurementKeySet.selection(
            for: options, model: "Mac16,5", fanIndices: [0])
        #expect(selection.keys == ["TPD0", "F1Ac"])
        #expect(selection.keySourceWhenNoOutcome == "custom")
    }

    @Test("selection: the ordinary mode is exactly what resolvedKeys already produced")
    func selectionForTheOrdinaryMode() throws {
        let defaults = try CommandLineOptions.parse([])
        #expect(
            MeasurementKeySet.selection(for: defaults, model: "Mac16,5", fanIndices: [0]).keys
                == MeasurementKeySet.defaultKeys(model: "Mac16,5", fanIndices: [0]))

        let custom = try CommandLineOptions.parse(["--keys=TPD0,F0Ac"])
        let selection = MeasurementKeySet.selection(
            for: custom, model: "Mac16,5", fanIndices: [0])
        #expect(selection.keys == ["TPD0", "F0Ac"])
        #expect(selection.keySourceWhenNoOutcome == "custom")
    }

    @Test("the start record takes the latency key source when no enumeration ran")
    func startRecordCarriesTheLatencyKeySource() {
        let record = SamplerStartRecord.startRecord(
            outcome: nil, keySourceWhenNoOutcome: "latency-default",
            hostname: "h", hwModel: "Mac16,5", osVersion: "v", uid: 501, pid: 1,
            intervalSeconds: 0, keys: ["F0Ac"])
        #expect(record.keySource == "latency-default")
        #expect(record.intervalSeconds == 0)
        #expect(record.fanEnumerationFailed == false)
        #expect(record.fanEnumerationFailureReason == nil)
    }

    @Test("without the new argument the start record still says \"custom\"")
    func startRecordDefaultsToCustom() {
        let record = SamplerStartRecord.startRecord(
            outcome: nil, hostname: "h", hwModel: "Mac16,5", osVersion: "v", uid: 501, pid: 1,
            intervalSeconds: 1.0, keys: ["F0Ac"])
        #expect(record.keySource == "custom")
    }
}
