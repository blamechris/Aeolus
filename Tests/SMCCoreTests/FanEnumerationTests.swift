import SMCCore
import Testing

@Suite("SMC fan enumeration")
struct SMCFanEnumerationTests {

    @Test("A normal multi-fan machine enumerates every fan with all three keys")
    func multiFanMachineEnumerates() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(
                fanCount: 2,
                fans: [
                    FanFixture(actual: 1343.07),
                    FanFixture(actual: 1454.97),
                ]))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 2)
        #expect(enumeration.fanIndices == [0, 1])
        #expect(enumeration.enumeratedFanIndices == [0, 1])
        #expect(enumeration.fans[0].actual.key == "F0Ac")
        #expect(enumeration.fans[0].minimum.key == "F0Mn")
        #expect(enumeration.fans[0].maximum.key == "F0Mx")
        #expect(value(enumeration.fans[0].actual) == 1343.07)
        #expect(value(enumeration.fans[1].maximum) == 5777)
    }

    /// The set handed to `AeolusXPCValidation.validateFanIndices(_:enumeratedFanIndices:)`
    /// is what gates which fans a lease may cover, so it must be exactly the enumerated
    /// indices — not widened by a count, not narrowed by which keys happened to read.
    @Test("The lease-gating index set is exactly the enumerated indices")
    func indexSetMatchesEnumeratedFans() async throws {
        // Fan 1 reads nothing at all: every one of its keys is absent from the table.
        var table = machine(fanCount: 2, fans: [FanFixture(actual: 2000)])
        table["F1Ac"] = .failure(.unknownKey("F1Ac"))

        let provider = FakeSensorProvider(keyedResults: table)
        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.enumeratedFanIndices == [0, 1])
        #expect(enumeration.enumeratedFanIndices.count == enumeration.fanCount)
    }

    /// Enumeration derives every key it needs from `FNum` and must never fall back to a
    /// full walk, read `{fds`, or probe anything architecture-specific. That is a claim
    /// about the requests made, which no assertion on the results could establish.
    @Test("Only FNum and the three keys per fan are ever requested")
    func requestsOnlyTheKeysItNeeds() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(
                fanCount: 2,
                fans: [
                    FanFixture(actual: 1343.07),
                    FanFixture(actual: 1454.97),
                ]))

        _ = try await SMCFanEnumeration.enumerate(provider: provider)

        let requests = await provider.requests
        #expect(requests == [["FNum"], ["F0Ac", "F0Mn", "F0Mx", "F1Ac", "F1Mn", "F1Mx"]])
    }

    @Test(
        "An implausible FNum throws rather than sizing an enumeration by it",
        arguments: [
            Double(SMCFanEnumeration.maxPlausibleFanCount + 1), -1, 957_153_280,
            .nan, .infinity, -.infinity,
        ])
    func implausibleFanCountThrows(declared: Double) async {
        let provider = FakeSensorProvider(keyedResults: machine(fanCount: declared))

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .implausibleFanCount = error else {
            Issue.record(
                "expected .implausibleFanCount for \(declared), got \(String(describing: error))")
            return
        }
    }

    /// The bound is a ceiling, not a strict one: a machine declaring exactly
    /// `maxPlausibleFanCount` fans is trusted. Asserted so a future off-by-one that tightens
    /// the guard into rejecting the boundary value is a failure rather than a silent
    /// behaviour change.
    @Test("A fan count exactly at the ceiling is accepted")
    func ceilingItselfIsAccepted() async throws {
        let count = SMCFanEnumeration.maxPlausibleFanCount
        let provider = FakeSensorProvider(keyedResults: machine(fanCount: Double(count)))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == count)
    }

    /// A fanless Mac genuinely has no `FNum` in its key table. That is "this machine has no
    /// fans", which every read client must render, not an error it should refuse to work
    /// past — see `.github/ISSUE_TEMPLATE/hardware-report.yml`, whose whole purpose is that
    /// such a machine's owner can still file a report.
    @Test("FNum absent from the key table means zero fans, not an error")
    func absentFanCountKeyMeansZeroFans() async throws {
        let provider = FakeSensorProvider(
            keyedResults: ["FNum": .failure(.unknownKey("FNum"))])

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 0)
        #expect(enumeration.fans.isEmpty)
        #expect(enumeration.enumeratedFanIndices.isEmpty)
        // And it stops there: a machine with no fans must not go on to issue a second,
        // empty subset read. Asserted on the requests rather than the result because an
        // enumeration over an empty range returns the same empty answer either way.
        let requests = await provider.requests
        #expect(requests == [["FNum"]])
    }

    /// The other side of the same guard: `.unknownKey` is the *only* `FNum` failure treated
    /// as "no fans". A key that exists but would not read means something went wrong, and
    /// silently reporting zero fans there would hide it — and, in the helper, would hand
    /// lease validation an empty set built from a failure.
    @Test(
        "An FNum failure that is not absence throws rather than reporting zero fans",
        arguments: [
            SensorReadFailure.readFailed(reason: "firmware(code: 0x82)"),
            .notDecodable(reason: "{fds is not numeric"),
        ])
    func nonAbsenceFanCountFailureThrows(failure: SensorReadFailure) async {
        let provider = FakeSensorProvider(keyedResults: ["FNum": .failure(failure)])

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .readFailed = error else {
            Issue.record("expected .readFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("No SMC on this machine is refused up front, distinct from having no fans")
    func unavailableProviderThrowsNoSMC() async {
        let provider = FakeSensorProvider(isAvailable: false)

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .noSMC = error else {
            Issue.record("expected .noSMC, got \(String(describing: error))")
            return
        }
    }

    @Test("A whole-request provider failure throws rather than reporting an empty machine")
    func providerThrowIsSurfaced() async {
        let provider = FakeSensorProvider(
            keysError: FakeProviderError(description: "connection closed"))

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .readFailed(_, let reason) = error else {
            Issue.record("expected .readFailed, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("connection closed"))
    }

    /// A provider that answers `FNum` with no outcome at all breaks
    /// `SensorProvider.read(keys:)`'s one-outcome-per-key contract. Reported as a failure
    /// rather than force-unwrapped, so a violated assumption surfaces as an error instead of
    /// a crash in a root daemon.
    @Test("An FNum request answered with no outcome throws")
    func missingFanCountOutcomeThrows() async {
        let provider = FakeSensorProvider(
            keyedResults: machine(fanCount: 2), omittedKeys: ["FNum"])

        let error = await #expect(throws: SMCFanEnumerationError.self) {
            try await SMCFanEnumeration.enumerate(provider: provider)
        }
        guard case .readFailed = error else {
            Issue.record("expected .readFailed, got \(String(describing: error))")
            return
        }
    }

    /// The per-key tolerance rule. A machine reporting `F0Mn` but not `F0Mx` is a machine
    /// with a fan, and dropping the fan entirely would lose two readings that worked.
    @Test("A fan whose maximum is unreadable still enumerates, with that key unavailable")
    func unreadableMaximumDoesNotDropTheFan() async throws {
        var table = machine(fanCount: 1, fans: [FanFixture(actual: 1343.07)])
        table["F0Mx"] = .failure(.readFailed(reason: "firmware(code: 0x82)"))

        let provider = FakeSensorProvider(keyedResults: table)
        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 1)
        #expect(value(enumeration.fans[0].actual) == 1343.07)
        #expect(value(enumeration.fans[0].minimum) == 1350)
        #expect(value(enumeration.fans[0].maximum) == nil)
        #expect(failure(enumeration.fans[0].maximum) == .readFailed(reason: "firmware(code: 0x82)"))
        // The raw key is retained even on failure, so a caller can always say which key it
        // is reporting as unavailable.
        #expect(enumeration.fans[0].maximum.key == "F0Mx")
    }

    /// A key the provider drops from its response entirely is reported as unavailable,
    /// carrying its key — never omitted from the fan and never fabricated as a `0`, which
    /// would read to a user as "this fan has stopped".
    @Test("A fan key with no outcome at all is unavailable, not a fabricated zero")
    func missingFanKeyOutcomeIsUnavailable() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(fanCount: 1, fans: [FanFixture(actual: 1343.07)]),
            omittedKeys: ["F0Mn"])

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 1)
        #expect(value(enumeration.fans[0].minimum) == nil)
        #expect(enumeration.fans[0].minimum.key == "F0Mn")
        #expect(value(enumeration.fans[0].actual) == 1343.07)
    }

    /// **Load-bearing.** `F0Ac` was measured at 1343.07 against a declared `F0Mn` of 1350 on
    /// this project's own development hardware (`docs/SMC-RESEARCH.md`, "Disagreement 3").
    /// Actual fan speed is not bounded by the declared minimum, so an observation below it
    /// is real data and must arrive at the caller unchanged: not raised to the minimum, not
    /// swapped for it, not reported as a failure. Clamping governs targets Aeolus writes,
    /// never values it reads — and a test that asserted `actual >= minimum` would be
    /// encoding on this project's behalf exactly the assumption the hardware disproved.
    @Test("An actual reading below the declared minimum is surfaced as measured, never clamped")
    func actualBelowDeclaredMinimumIsNotClamped() async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(
                fanCount: 1, fans: [FanFixture(actual: 1343.07)]))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        let actual = try #require(value(enumeration.fans[0].actual))
        let minimum = try #require(value(enumeration.fans[0].minimum))
        #expect(actual == 1343.07)
        #expect(minimum == 1350)
        #expect(actual < minimum)
    }

    /// `SMCValue.scalar()` applies no finiteness guard, so a byte-swapped `flt` can decode to
    /// `±.infinity` or `.nan` on an otherwise-successful read. Refused here rather than
    /// propagated: `Double.infinity == Double.infinity.rounded()` is `true`, so a non-finite
    /// value can travel a long way downstream without ever looking wrong.
    @Test(
        "A non-finite reading is refused rather than propagated",
        arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteReadingIsRefused(bad: Double) async throws {
        let provider = FakeSensorProvider(
            keyedResults: machine(fanCount: 1, fans: [FanFixture(actual: bad)]))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(value(enumeration.fans[0].actual) == nil)
        let actual = enumeration.fans[0].actual
        guard case .notDecodable(let reason) = failure(actual) else {
            Issue.record("expected .notDecodable, got \(String(describing: actual))")
            return
        }
        #expect(reason.contains("non-finite"))
        // The rest of the fan is untouched — one bad key never voids the others.
        #expect(value(enumeration.fans[0].minimum) == 1350)
    }

    @Test("Fan keys follow the documented F<n>Ac/Mn/Mx convention")
    func keyBuildersFollowTheConvention() {
        #expect(SMCFanEnumeration.actualKey(forFan: 0) == "F0Ac")
        #expect(SMCFanEnumeration.minimumKey(forFan: 0) == "F0Mn")
        #expect(SMCFanEnumeration.maximumKey(forFan: 1) == "F1Mx")
        #expect(SMCFanEnumeration.fanCountKey == "FNum")
    }

    /// The number itself, pinned. It was two independent constants before this type existed
    /// (`FanPoller.maxPlausibleFanCount`, `ListCommand.maxPlausibleFanCount`), which both now
    /// read; a change here is a change everywhere, which is the point.
    @Test("The plausible fan-count ceiling is one shared constant")
    func ceilingIsOneSharedConstant() {
        #expect(SMCFanEnumeration.maxPlausibleFanCount == 64)
    }

    /// The key convention runs out at index 9 and the ceiling does not, so a machine
    /// declaring ten or more fans enumerates fans it can say nothing about.
    ///
    /// `F10Ac` is five characters and `SMCKey` requires exactly four, so the key cannot be
    /// formed at all. `SensorReadFailure.unknownKey` is the right outcome and says so in
    /// its own documentation — it covers "not well-formed for this provider's key space"
    /// as well as "absent" — so this is honest rather than a fabricated reading. It is
    /// pinned here because it was documented in a comment and asserted nowhere, and a
    /// documented behaviour with no test is the thing that rots first.
    ///
    /// No Mac this project has evidence of comes close to ten fans, so the behaviour is
    /// recorded rather than changed: narrowing the ceiling to 10 would refuse such a
    /// machine outright as "implausible", which is a different and less true claim than
    /// "this fan exists and nothing here can address it".
    @Test("A fan past the addressable key range enumerates as unreadable, not as zero")
    func fanBeyondAddressableIndexIsUnreadable() async throws {
        // Fans 0-9 are stubbed; fan 10's keys are deliberately absent, because a
        // five-character key is unrepresentable and no stub could be reached even if one
        // were written.
        let provider = FakeSensorProvider(
            keyedResults: machine(
                fanCount: 11,
                fans: Array(repeating: FanFixture(actual: 1800), count: 10)))

        let enumeration = try await SMCFanEnumeration.enumerate(provider: provider)

        #expect(enumeration.fanCount == 11)
        // The fan is present rather than silently dropped — hiding hardware the firmware
        // declared would be the worse of the two dishonesty modes.
        #expect(enumeration.enumeratedFanIndices.contains(10))

        let addressable = try #require(enumeration.fans.first { $0.index == 9 })
        #expect(value(addressable.actual) == 1800)

        let unaddressable = try #require(enumeration.fans.first { $0.index == 10 })
        for outcome in [unaddressable.actual, unaddressable.minimum, unaddressable.maximum] {
            // Specifically unknownKey, and specifically not a reading: the distinction is
            // what tells a bug reporter their fan was never asked about, rather than asked
            // about and found silent.
            #expect(value(outcome) == nil)
            #expect(failure(outcome) == .unknownKey(outcome.key))
        }
    }
}
