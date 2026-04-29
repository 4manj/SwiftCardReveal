import Testing
@testable import s_reveal

struct RevealOrchestratorTests {
    @Test
    @MainActor
    func resetCancelsPendingShareReveal() async {
        let orchestrator = RevealOrchestrator(
            timing: .init(
                showButtonsDelay: .milliseconds(50),
                showSkipDelay: .milliseconds(80)
            )
        )

        orchestrator.triggerRevealForTesting()
        orchestrator.reset()

        try? await Task.sleep(for: .milliseconds(120))

        #expect(orchestrator.showButtons == false)
        #expect(orchestrator.showSkip == false)
    }

    @Test
    @MainActor
    func setEffectsForPnLDisablesBothWhenNegative() {
        let orchestrator = RevealOrchestrator()
        #expect(orchestrator.cloudEnabled == true)
        #expect(orchestrator.petalsEnabled == true)

        orchestrator.setEffectsForPnL(isPositive: false)
        #expect(orchestrator.cloudEnabled == false)
        #expect(orchestrator.petalsEnabled == false)

        orchestrator.setEffectsForPnL(isPositive: true)
        #expect(orchestrator.cloudEnabled == true)
        #expect(orchestrator.petalsEnabled == true)
    }
}
