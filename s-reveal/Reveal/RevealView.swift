import SwiftUI
import MetalKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Public SwiftUI entry

struct RevealView: View {
    @StateObject private var orchestrator = RevealOrchestrator()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Metal: dust cloud + petal confetti. Dust fades out after tap;
            // petals continue independently for the full animation duration.
            MetalRevealView(orchestrator: orchestrator)
                .ignoresSafeArea()

            // Pre-tap label: "Closing your position" + three Y-axis bouncing
            // dots, with a single shimmer wave sweeping across the whole row
            // (text + dots together).
            ClosingPositionLabel(
                font: .system(size: 16, weight: .medium, design: .rounded)
            )
            .allowsHitTesting(false)
            .opacity(orchestrator.revealed ? 0 : 1)
            .animation(.smooth(duration: 0.35), value: orchestrator.revealed)

            // Card pops in after tap with a spring-y scale + opacity, then
            // becomes interactive once the share buttons fade up (2s delay).
            // Hit testing is disabled until then so users can't grab the card
            // before the entire reveal animation has completed.
            if orchestrator.revealed {
                VStack(spacing: 36) {
                    PnlCard3DView()
                        .allowsHitTesting(orchestrator.showButtons)
                    if orchestrator.showButtons {
                        ShareButtonsRow()
                            .transition(
                                .opacity
                                .combined(with: .scale(scale: 0.85))
                                .combined(with: .offset(y: 12))
                            )
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.84)
                            .combined(with: .opacity)
                            .combined(with: .offset(y: 24)),
                        removal: .opacity
                    )
                )
            }

            // Foreground petal layer — second cohort drawn *above* the card
            // on a transparent Metal drawable so some petals visibly fall in
            // front of the P&L. Hit-test-disabled so taps still pass through
            // to nothing (or, post-reveal, to the card / share / skip).
            MetalRevealView(orchestrator: orchestrator, isForegroundLayer: true)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Skip → reset to the pre-tap state. Pinned to the bottom of the
            // screen; appears 0.5 s after the share button (last element to
            // arrive on screen so it doesn't pull focus from the reveal).
            if orchestrator.showSkip {
                VStack {
                    Spacer()
                    Button {
                        #if os(iOS)
                        // Soft Core-Haptics transient. Same engine as every
                        // other haptic surface, lighter than card press so
                        // cancel reads as secondary.
                        RevealHaptics.shared.playSkip()
                        #endif
                        orchestrator.reset()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            // Two-stop white halo, slightly hotter than before
                            // so Skip's glow still reads as a discrete element
                            // when it sits in front of the bottom cloud's
                            // pink haze.
                            .shadow(color: .white.opacity(0.42), radius: 5)
                            .shadow(color: .white.opacity(0.22), radius: 12)
                            // Plus-lighter blend: Skip text + halo are added
                            // on top of whatever is behind, so the bottom
                            // cloud's pink can never wash the label out — on
                            // black background (pre-tap) it reads as before.
                            .compositingGroup()
                            .blendMode(.plusLighter)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .frame(minWidth: 88, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 48)
                }
                .transition(.opacity)
            }
        }
        // Auto-reveal countdown: the wait state plays for 5 s, then the card
        // reveals on its own. `.task(id:)` re-runs whenever `revealed` flips,
        // so Skip → reset → revealed=false restarts the timer cleanly.
        .task(id: orchestrator.revealed) {
            guard !orchestrator.revealed else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, !orchestrator.revealed {
                orchestrator.autoReveal()
            }
        }
    }
}

// MARK: - Orchestrator
//
// Single ObservableObject coordinating the Metal renderer, the SwiftUI card,
// and the gating of taps. All flow goes through here so the parent View and
// the Metal Coordinator share the same `revealed` flag.

@MainActor
final class RevealOrchestrator: ObservableObject {
    struct Timing {
        var showButtonsDelay: Duration = .seconds(2)
        var showSkipDelay: Duration = .seconds(2.5)
    }

    @Published var revealed: Bool = false
    @Published var showButtons: Bool = false
    @Published var showSkip: Bool = false

    /// Whether the bloomed cloud effect plays for the next reveal. Defaults
    /// true; flip to false (e.g. when the P&L is negative) to suppress it.
    @Published var cloudEnabled: Bool = true
    /// Whether petal confetti plays for the next reveal. Independent of
    /// `cloudEnabled` so callers can mix-and-match if needed.
    @Published var petalsEnabled: Bool = true

    weak var renderer: ParticleRenderer?       // strongly held by RevealCoordinator
    /// Optional second renderer that draws a petal cohort *in front* of the
    /// SwiftUI card. Same simulation, different seed, transparent drawable.
    weak var foregroundRenderer: ParticleRenderer?
    private let timing: Timing
    private var showButtonsTask: Task<Void, Never>?
    private var showSkipTask: Task<Void, Never>?

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    func handleTap(at viewLocation: CGPoint, in viewSize: CGSize) {
        triggerReveal(at: viewLocation, in: viewSize)
    }

    /// Convenience for the common case: positive P&L gets the full celebratory
    /// cloud + petal confetti, negative P&L stays subdued (both effects off).
    /// Call this from wherever the P&L sign is known *before* the reveal fires.
    func setEffectsForPnL(isPositive: Bool) {
        cloudEnabled = isPositive
        petalsEnabled = isPositive
    }

    /// Fired by the 5-second countdown in `RevealView.task`. Synthesizes a
    /// center "tap" so the burst origin lands at the visual middle of the
    /// mask instead of an arbitrary edge.
    func autoReveal() {
        triggerReveal(
            at: CGPoint(x: 50, y: 50),
            in: CGSize(width: 100, height: 100)
        )
    }

    private func triggerReveal(at viewLocation: CGPoint, in viewSize: CGSize) {
        guard let renderer = renderer else { return }
        // Already revealed (or petal animation in flight): no-op.
        guard !revealed, !renderer.isAnimatingPetals else { return }
        cancelPendingRevealTasks()

        renderer.registerTap(
            viewLocation: viewLocation,
            viewSize: viewSize,
            cloudEnabled: cloudEnabled,
            petalsEnabled: petalsEnabled
        )
        // Foreground layer fires a second cohort with haptics suppressed —
        // only one playReveal arc per tap. Cloud is always disabled here
        // since the foreground renderer skips the cloud pass anyway.
        foregroundRenderer?.registerTap(
            viewLocation: viewLocation,
            viewSize: viewSize,
            playHaptics: false,
            cloudEnabled: false,
            petalsEnabled: petalsEnabled
        )

        withAnimation(.bouncy(duration: 0.55, extraBounce: 0.12)) {
            revealed = true
        }

        // Share buttons fade up 2 s after the reveal completes — gives the
        // card pop + petals time to play before the secondary UI lands.
        showButtonsTask = Task { [weak self, delay = timing.showButtonsDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.revealButtons()
        }

        // Skip text fades in 0.5 s after the share button — last element to
        // arrive on screen.
        showSkipTask = Task { [weak self, delay = timing.showSkipDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.revealSkip()
        }
    }

    /// Skip back to the pre-tap state. Renderer drops its post-tap state
    /// (dust restores to full, petals stop, reveal mask clears, MTKView
    /// un-pauses); the orchestrator clears the SwiftUI flags. The user is
    /// back at the "Closing your position…" label, ready to tap again.
    func reset() {
        cancelPendingRevealTasks()
        renderer?.resetToInitial()
        foregroundRenderer?.resetToInitial()
        withAnimation(.smooth(duration: 0.35)) {
            revealed = false
            showButtons = false
            showSkip = false
        }
    }

    private func cancelPendingRevealTasks() {
        showButtonsTask?.cancel()
        showSkipTask?.cancel()
        showButtonsTask = nil
        showSkipTask = nil
    }

    private func revealButtons() {
        withAnimation(.bouncy(duration: 0.55, extraBounce: 0.06)) {
            showButtons = true
        }
        showButtonsTask = nil
    }

    private func revealSkip() {
        withAnimation(.smooth(duration: 0.35)) {
            showSkip = true
        }
        showSkipTask = nil
    }

#if DEBUG
    func triggerRevealForTesting() {
        guard !revealed else { return }
        cancelPendingRevealTasks()
        withAnimation(.bouncy(duration: 0.55, extraBounce: 0.12)) {
            revealed = true
        }
        showButtonsTask = Task { [weak self, delay = timing.showButtonsDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.revealButtons()
        }
        showSkipTask = Task { [weak self, delay = timing.showSkipDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.revealSkip()
        }
    }
#endif
}

// MARK: - Platform bridge

#if os(macOS)
struct MetalRevealView: NSViewRepresentable {
    let orchestrator: RevealOrchestrator
    var isForegroundLayer: Bool = false
    func makeNSView(context: Context) -> MTKView {
        configureMetalView(coordinator: context.coordinator)
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
    func makeCoordinator() -> RevealCoordinator {
        RevealCoordinator(orchestrator: orchestrator)
    }
}
#else
struct MetalRevealView: UIViewRepresentable {
    let orchestrator: RevealOrchestrator
    var isForegroundLayer: Bool = false
    func makeUIView(context: Context) -> MTKView {
        configureMetalView(coordinator: context.coordinator)
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    func makeCoordinator() -> RevealCoordinator {
        RevealCoordinator(orchestrator: orchestrator)
    }
}
#endif

extension MetalRevealView {
    fileprivate func configureMetalView(coordinator: RevealCoordinator) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false

        // Foreground layer renders petals onto a transparent drawable so the
        // SwiftUI card behind shows through everywhere petals aren't drawn.
        view.clearColor = isForegroundLayer
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        #if os(macOS)
        view.layer?.isOpaque = !isForegroundLayer
        #else
        // Match the display's max refresh rate (120 Hz on ProMotion, 60 Hz
        // elsewhere). Hard-coding 60 was fighting the 120 Hz card smoothing
        // timer on Pro iPhones, producing a visible cadence mismatch.
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.isMultipleTouchEnabled = false
        view.isOpaque = !isForegroundLayer
        if isForegroundLayer {
            view.backgroundColor = .clear
        }
        #endif

        if let renderer = ParticleRenderer(view: view, isForegroundLayer: isForegroundLayer) {
            coordinator.renderer = renderer
            if isForegroundLayer {
                coordinator.orchestrator.foregroundRenderer = renderer
            } else {
                coordinator.orchestrator.renderer = renderer
            }
            view.delegate = renderer
        }

        // Foreground layer is hit-test-disabled by the parent; no gesture.
        if !isForegroundLayer {
            attachGesture(to: view, coordinator: coordinator)
        }
        return view
    }

    fileprivate func attachGesture(to view: MTKView, coordinator: RevealCoordinator) {
        #if os(macOS)
        let click = NSClickGestureRecognizer(
            target: coordinator,
            action: #selector(RevealCoordinator.handleClick(_:))
        )
        view.addGestureRecognizer(click)
        #else
        let tap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(RevealCoordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        #endif
    }
}

// MARK: - Coordinator

@MainActor
final class RevealCoordinator: NSObject {
    let orchestrator: RevealOrchestrator
    var renderer: ParticleRenderer?            // strong — keeps renderer alive

    init(orchestrator: RevealOrchestrator) {
        self.orchestrator = orchestrator
    }

    #if os(macOS)
    @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view as? MTKView else { return }
        let location = recognizer.location(in: view)
        let topLeft: CGPoint = view.isFlipped
            ? location
            : CGPoint(x: location.x, y: view.bounds.height - location.y)
        orchestrator.handleTap(at: topLeft, in: view.bounds.size)
    }
    #else
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view as? MTKView else { return }
        let location = recognizer.location(in: view)
        orchestrator.handleTap(at: location, in: view.bounds.size)
    }
    #endif
}

// MARK: - Shimmering text

// MARK: - Closing-position label
//
// "Closing your position" with shimmer + three Y-axis bouncing dots. Both
// shimmer and bounces use SwiftUI's native `withAnimation(...).repeatForever`
// so interpolation happens in Core Animation — far cheaper than TimelineView
// rebuilding the whole HStack at every animation frame.
//
// The shimmer mask is the static phrase only (no bouncing). The dots ride
// alongside; they don't get the shimmer band but at 16 pt the visual
// difference is imperceptible and the perf saving is real.

private struct ClosingPositionLabel: View {
    let font: Font
    @State private var pulse = false
    private let hotPink = Color(red: 1.0, green: 0.42, blue: 0.78)

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 1) {
            ShimmerText(text: "Closing your position", font: font, tint: hotPink, pulse: pulse)
            BouncingDot(font: font, tint: hotPink, delay: 0.00)
            BouncingDot(font: font, tint: hotPink, delay: 0.15)
            BouncingDot(font: font, tint: hotPink, delay: 0.30)
        }
        .compositingGroup()
        .blendMode(.screen)
        .shadow(color: hotPink.opacity(pulse ? 0.80 : 0.45), radius: pulse ? 10 : 6)
        .shadow(color: .white.opacity(pulse ? 0.55 : 0.35), radius: pulse ? 18 : 14)
        .shadow(color: hotPink.opacity(0.22), radius: 28)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct BouncingDot: View {
    let font: Font
    let tint: Color
    let delay: Double
    @State private var up = false

    var body: some View {
        Text(".")
            .font(font)
            .foregroundStyle(tint)
            .offset(y: up ? -4.5 : 0)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.45)
                    .delay(delay)
                    .repeatForever(autoreverses: true)
                ) {
                    up = true
                }
            }
    }
}

private struct ShimmerText: View {
    let text: String
    let font: Font
    let tint: Color
    let pulse: Bool
    @State private var animate = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(tint)
            .overlay {
                GeometryReader { proxy in
                    let bandWidth = max(160, proxy.size.width * 1.4)
                    LinearGradient(
                        colors: [.clear, tint.opacity(0.15), .white.opacity(0.95), tint.opacity(0.9), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: animate
                            ? proxy.size.width + bandWidth
                            : -bandWidth)
                }
                .mask {
                    Text(text).font(font)
                }
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 1.7)
                    .delay(0.2)
                    .repeatForever(autoreverses: false)
                ) {
                    animate = true
                }
            }
    }
}
