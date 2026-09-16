import Testing

@testable import smc_sampler

@Suite("MeasurementKeySet")
struct MeasurementKeySetTests {

    @Test("Mac16,5 resolves to the 34-key TPD*/TRD* die cluster")
    func mac16x5ResolvesToDieCluster() {
        let keys = MeasurementKeySet.criticalKeys(forModel: "Mac16,5")
        #expect(keys.count == 34)
        #expect(keys.contains("TPD0"))
        #expect(keys.contains("TRDX"))
        #expect(keys.allSatisfy { $0.hasPrefix("TPD") || $0.hasPrefix("TRD") })
    }

    @Test("an unrecognised or nil model resolves to the empty critical set — blindness, not a guess")
    func unrecognisedModelResolvesToEmptySet() {
        #expect(MeasurementKeySet.criticalKeys(forModel: "Mac99,9").isEmpty)
        #expect(MeasurementKeySet.criticalKeys(forModel: nil).isEmpty)
    }

    @Test("fan keys follow the F<n>Ac/Mn/Mx convention for every requested index")
    func fanKeysFollowConvention() {
        let keys = MeasurementKeySet.fanKeys(forFanIndices: [0, 1])
        #expect(keys == ["F0Ac", "F0Mn", "F0Mx", "F1Ac", "F1Mn", "F1Mx"])
    }

    @Test("no fan indices produces no fan keys")
    func noFanIndicesProducesNoFanKeys() {
        #expect(MeasurementKeySet.fanKeys(forFanIndices: []).isEmpty)
    }

    @Test("the default set is critical keys followed by fan keys, in that order")
    func defaultSetOrdersCriticalThenFan() {
        let keys = MeasurementKeySet.defaultKeys(model: "Mac16,5", fanIndices: [0])
        #expect(keys.count == 37)
        #expect(Array(keys.prefix(34)) == MeasurementKeySet.criticalKeys(forModel: "Mac16,5"))
        #expect(Array(keys.suffix(3)) == ["F0Ac", "F0Mn", "F0Mx"])
    }

    @Test("duplicate keys across critical and fan sets are collapsed to one, first occurrence wins")
    func duplicatesAreCollapsed() {
        // A contrived overlap: today's curated sets never collide, but the dedup itself must
        // hold regardless of what the two source lists happen to contain.
        let keys = MeasurementKeySet.defaultKeys(model: nil, fanIndices: [0])
            + MeasurementKeySet.fanKeys(forFanIndices: [0])
        let deduped = MeasurementKeySet.resolvedKeys(custom: keys, model: nil, fanIndices: [])
        #expect(deduped == ["F0Ac", "F0Mn", "F0Mx"])
    }

    @Test("a non-empty custom key list is used verbatim, ignoring the machine's default set")
    func customKeysOverrideTheDefault() {
        let resolved = MeasurementKeySet.resolvedKeys(
            custom: ["Tf06"], model: "Mac16,5", fanIndices: [0, 1])
        #expect(resolved == ["Tf06"])
    }

    @Test("an empty custom key list falls back to the default set rather than sampling nothing")
    func emptyCustomKeysFallsBackToDefault() {
        let resolved = MeasurementKeySet.resolvedKeys(
            custom: [], model: "Mac16,5", fanIndices: [0])
        #expect(resolved == MeasurementKeySet.defaultKeys(model: "Mac16,5", fanIndices: [0]))
    }
}

@Suite("KeyListParsing")
struct KeyListParsingTests {

    @Test("splits on commas and trims whitespace")
    func splitsAndTrims() {
        #expect(KeyListParsing.parse("F0Ac, F0Mn ,F0Mx") == ["F0Ac", "F0Mn", "F0Mx"])
    }

    @Test("drops empty entries from a trailing comma or repeated commas")
    func dropsEmptyEntries() {
        #expect(KeyListParsing.parse("F0Ac,,F0Mn,") == ["F0Ac", "F0Mn"])
    }

    @Test("an empty string parses to an empty list")
    func emptyStringParsesToEmptyList() {
        #expect(KeyListParsing.parse("").isEmpty)
    }
}
