import Foundation
import Testing

@testable import FanKit

@Suite("Hardware identity")
struct HardwareIdentityTests {

    // MARK: - Brand string → chip family

    @Test("The 'Apple ' marketing prefix is stripped from an Apple Silicon brand string")
    func appleSiliconPrefixIsStripped() {
        #expect(HardwareIdentity.chipFamily(fromBrandString: "Apple M4 Max") == "M4 Max")
        #expect(HardwareIdentity.chipFamily(fromBrandString: "Apple M1") == "M1")
        #expect(HardwareIdentity.chipFamily(fromBrandString: "Apple M1 Pro") == "M1 Pro")
    }

    @Test("A non-Apple brand string is left untouched")
    func nonAppleBrandStringIsUnchanged() {
        #expect(
            HardwareIdentity.chipFamily(fromBrandString: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz")
                == "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz")
    }

    @Test("A nil brand string produces a nil chip family")
    func nilBrandStringProducesNil() {
        #expect(HardwareIdentity.chipFamily(fromBrandString: nil) == nil)
    }

    // MARK: - Real hardware smoke test

    /// A fact about this project's sole verified machine (`Mac16,5`, `docs/SMC-RESEARCH.md`),
    /// not about every Mac — gated the same way `Tests/SMCCoreTests/DevelopmentMachine.swift`
    /// gates its own hardware-specific assertions, so a contributor on different hardware
    /// gets a skip, never a failure. `HardwareIdentity.current()` being the production
    /// reader (rather than a test-only duplicate) means this can call it directly instead
    /// of maintaining a second sysctl reader just to check "is this the dev machine".
    @Test(
        "current() reads this machine's real model identifier and chip family",
        .enabled(if: HardwareIdentity.current().modelIdentifier == "Mac16,5")
    )
    func currentReadsRealIdentity() {
        let identity = HardwareIdentity.current()

        #expect(identity.modelIdentifier == "Mac16,5")
        #expect(identity.chipFamily?.lowercased() == "m4 max")
    }
}
