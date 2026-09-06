import Testing

@testable import AeolusUI

@Suite("LoginItemStatusDisplay — never says 'enabled' unless the status actually is")
struct LoginItemStatusDisplayTests {

    @Test("Every status produces distinct, non-empty text")
    func everyStatusProducesText() {
        let statuses: [LoginItemStatus] = [
            .notRegistered, .enabled, .requiresApproval, .notFound,
            .unavailable(reason: "not wired up"),
        ]
        let texts = statuses.map(LoginItemStatusDisplay.text(for:))

        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == texts.count, "Every status must read differently")
    }

    @Test("Only .enabled ever renders the word 'launches'")
    func onlyEnabledClaimsItLaunches() {
        #expect(LoginItemStatusDisplay.text(for: .enabled).lowercased().contains("launches"))
        #expect(
            !LoginItemStatusDisplay.text(for: .notRegistered).lowercased().contains("launches"))
        #expect(
            !LoginItemStatusDisplay.text(for: .unavailable(reason: "x")).lowercased()
                .contains("launches"))
    }

    @Test(".unavailable surfaces its own reason verbatim, never a generic substitute")
    func unavailableSurfacesItsOwnReason() {
        #expect(
            LoginItemStatusDisplay.text(for: .unavailable(reason: "custom reason"))
                == "custom reason")
    }
}
