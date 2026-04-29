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
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        pulse = 1
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.55), value: done)
        .onAppear {
            #if os(iOS)
            // Build + start the Core Haptics engine, cache patterns, prime
            // the actuator. The 2 s splash hides the warm-up so the user's
            // first tap doesn't pay engine cold-start cost.
            RevealHaptics.shared.prewarm()
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                done = true
            }
        }
    }
}
