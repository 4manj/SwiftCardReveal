import SwiftUI

/// 2-second splash shown at app launch before transitioning to `RevealView`.
/// Centered minimal wordmark, fades out into the main scene.

struct SplashView: View {
    @State private var done = false
    @State private var pulse: CGFloat = 0

    var body: some View {
        ZStack {
            if done {
                RevealView()
                    .transition(.opacity)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()

                    Text("Suzi")
                        .font(.system(size: 40, weight: .ultraLight, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .pink.opacity(0.20 + pulse * 0.18),
                                radius: 30 + pulse * 14)
                        .shadow(color: .white.opacity(0.05),
                                radius: 60)
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.55), value: done)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = 1
            }
        }
        .task {
            #if os(iOS)
            // Build + start the Core Haptics engine, cache patterns, prime
            // the actuator. The 2 s splash hides the warm-up so the user's
            // first tap doesn't pay engine cold-start cost.
            RevealHaptics.shared.prewarm()
            #endif
            // Front-load the Metal pipeline specialization during the splash.
            // Renderer init still does a non-blocking prewarm, but by the time
            // the reveal scene appears the process-wide pipeline cache is
            // usually already hot.
            Task.detached(priority: .userInitiated) {
                MetalPipelinePrewarmer.prewarm()
                _ = PnlCard3DView.bundledCardImage
            }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                done = true
            }
        }
    }
}
