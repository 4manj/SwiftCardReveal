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
}
