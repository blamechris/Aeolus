import Foundation
import Testing

@testable import AeolusUI

@Suite("PreferencesRefreshInterval — the clamp is the control, not a courtesy")
struct PreferencesRefreshIntervalTests {

    @Test("The minimum matches PollingViewModel's own floor exactly")
    func minimumMatchesPollingViewModel() {
        #expect(PreferencesRefreshInterval.minimum == PollingViewModel.minimumRefreshInterval)
    }

    @Test("A value within bounds is returned unchanged")
    func withinBoundsIsUnchanged() {
        #expect(PreferencesRefreshInterval.clamped(2.5) == 2.5)
    }

    @Test("A value below the minimum is raised to it")
    func belowMinimumIsRaised() {
        #expect(PreferencesRefreshInterval.clamped(0.01) == PreferencesRefreshInterval.minimum)
    }

    @Test("Zero is clamped to the minimum, never accepted as a busy-loop cadence")
    func zeroIsClampedToMinimum() {
        #expect(PreferencesRefreshInterval.clamped(0) == PreferencesRefreshInterval.minimum)
    }

    @Test("A negative value is clamped to the minimum")
    func negativeIsClampedToMinimum() {
        #expect(PreferencesRefreshInterval.clamped(-5) == PreferencesRefreshInterval.minimum)
    }

    @Test("A value above the maximum is lowered to it")
    func aboveMaximumIsLowered() {
        #expect(PreferencesRefreshInterval.clamped(3600) == PreferencesRefreshInterval.maximum)
    }

    @Test("Exactly the minimum and maximum are accepted as-is")
    func boundsThemselvesAreAccepted() {
        #expect(
            PreferencesRefreshInterval.clamped(PreferencesRefreshInterval.minimum)
                == PreferencesRefreshInterval.minimum)
        #expect(
            PreferencesRefreshInterval.clamped(PreferencesRefreshInterval.maximum)
                == PreferencesRefreshInterval.maximum)
    }

    @Test("NaN falls back to the default, not to either bound")
    func nanFallsBackToDefault() {
        #expect(PreferencesRefreshInterval.clamped(.nan) == PreferencesRefreshInterval.defaultValue)
    }

    @Test("Positive infinity falls back to the default")
    func positiveInfinityFallsBackToDefault() {
        #expect(
            PreferencesRefreshInterval.clamped(.infinity) == PreferencesRefreshInterval.defaultValue
        )
    }

    @Test("Negative infinity falls back to the default")
    func negativeInfinityFallsBackToDefault() {
        #expect(
            PreferencesRefreshInterval.clamped(-.infinity)
                == PreferencesRefreshInterval.defaultValue)
    }
}
