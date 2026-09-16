import Testing

@testable import smc_sampler

@Suite("CommandLineOptions")
struct CommandLineOptionsTests {

    @Test("no arguments produces the documented defaults")
    func noArgumentsProducesDefaults() throws {
        let options = try CommandLineOptions.parse([])
        #expect(options.intervalSeconds == 1.0)
        #expect(options.tickCount == nil)
        #expect(options.keys.isEmpty)
    }

    @Test("--flag=value and --flag value are equivalent")
    func inlineAndSpaceSeparatedValuesAreEquivalent() throws {
        let inline = try CommandLineOptions.parse(["--interval=2.5", "--count=10"])
        let spaced = try CommandLineOptions.parse(["--interval", "2.5", "--count", "10"])
        #expect(inline == spaced)
        #expect(inline.intervalSeconds == 2.5)
        #expect(inline.tickCount == 10)
    }

    @Test("--keys splits, trims, and validates every key")
    func keysSplitsAndValidates() throws {
        let options = try CommandLineOptions.parse(["--keys=F0Ac, Tf06"])
        #expect(options.keys == ["F0Ac", "Tf06"])
    }

    @Test("a non-positive or non-finite interval is rejected")
    func nonPositiveIntervalIsRejected() {
        #expect(throws: CommandLineOptions.ParseError.invalidInterval("0")) {
            try CommandLineOptions.parse(["--interval=0"])
        }
        #expect(throws: CommandLineOptions.ParseError.invalidInterval("-1")) {
            try CommandLineOptions.parse(["--interval=-1"])
        }
        #expect(throws: CommandLineOptions.ParseError.invalidInterval("nan")) {
            try CommandLineOptions.parse(["--interval=nan"])
        }
    }

    @Test("a non-positive count is rejected")
    func nonPositiveCountIsRejected() {
        #expect(throws: CommandLineOptions.ParseError.invalidCount("0")) {
            try CommandLineOptions.parse(["--count=0"])
        }
    }

    @Test("a key that is not exactly four ASCII characters is rejected at parse time")
    func malformedKeyIsRejectedAtParseTime() {
        #expect(throws: CommandLineOptions.ParseError.malformedKey("TooLong")) {
            try CommandLineOptions.parse(["--keys=F0Ac,TooLong"])
        }
    }

    @Test("an unrecognised flag is rejected")
    func unrecognisedFlagIsRejected() {
        #expect(throws: CommandLineOptions.ParseError.unrecognizedArgument("--bogus")) {
            try CommandLineOptions.parse(["--bogus"])
        }
    }

    @Test("a flag missing its value is rejected rather than silently consuming the next flag")
    func flagMissingItsValueIsRejected() {
        #expect(throws: CommandLineOptions.ParseError.unrecognizedArgument("--interval")) {
            try CommandLineOptions.parse(["--interval"])
        }
    }
}
