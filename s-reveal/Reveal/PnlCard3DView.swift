import SwiftUI
import Observation

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// The Polymarket card. The view itself is now slim — all per-frame physics
/// lives in `CardMotionModel` (an `@Observable`), and all per-frame visual
/// effects (inner glow / shine sweep / edge rim) are drawn by a single
/// `Canvas` inside `CardEffectsLayer`. That keeps the body's invalidation
/// surface tiny: dragging the card no longer rebuilds the whole subtree at
/// 120 Hz.
struct PnlCard3DView: View {

    @State private var model = CardMotionModel()
    @State private var hapticAnchor: CGSize = .zero

    private let cornerRadius: CGFloat = 18

    var body: some View {
        let dragOffset = model.dragOffset
        let dragNorm = model.tiltMagnitude
        let holdBoost: CGFloat = model.isHolding ? 1 : 0

        // Halo color/intensity for the layered drop shadows. The inner halo
        // breathing animation is gone (was driven by @State + repeatForever);
        // those values are now baked into a single mid-tone constant — tiny
        // visual loss, big rebuild-cost savings.
        let organicBreath: CGFloat = 0.62
        let haloEnergy = min(1.45, organicBreath + dragNorm * 0.24 + holdBoost * 0.42)
        let haloWarmth = min(1, 0.34 + haloEnergy * 0.44)

        let nearHalo = Color(
            red: 1.00,
            green: 0.47 + haloWarmth * 0.16,
            blue: 0.77 + haloWarmth * 0.10
        )
        let farHalo = Color(
            red: 1.00,
            green: 0.36 + haloWarmth * 0.08,
            blue: 0.72 + haloWarmth * 0.08
        )

        ZStack {
            cardImage
                .overlay {
                    CardEffectsLayer(model: model, cornerRadius: cornerRadius)
                }
                .clipShape(cardShape)
                .overlay(
                    cardShape
                        .stroke(Color.white.opacity(0.10 + holdBoost * 0.06), lineWidth: 1)
                )
                // Tilt clamped to ±20° on both axes — prevents the card from
                // flipping past 90° if the user keeps dragging.
                .rotation3DEffect(
                    .degrees(Double(clamp(-dragOffset.height / 12, -20, 20))),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.7
                )
                .rotation3DEffect(
                    .degrees(Double(clamp(dragOffset.width / 12, -20, 20))),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.7
                )
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in
                            if !model.isHolding {
                                model.beginGesture()
                                hapticAnchor = .zero
                                #if os(iOS)
                                RevealHaptics.shared.playCardPress()
                                #endif
                            }
                            let translation = CGSize(
                                width: v.location.x - v.startLocation.x,
                                height: v.location.y - v.startLocation.y
                            )
                            model.updateGesture(translation: translation)

                            // Detent tick haptic, throttled by ~44 px of finger
                            // travel. Compares against clamped translation so
                            // the threshold is consistent across drag ranges.
                            let clamped = CGSize(
                                width: clamp(translation.width, -240, 240),
                                height: clamp(translation.height, -240, 240)
                            )
                            let dx = clamped.width - hapticAnchor.width
                            let dy = clamped.height - hapticAnchor.height
                            if dx * dx + dy * dy > 1936 {
                                #if os(iOS)
                                let progress = min(hypot(clamped.width, clamped.height) / 240, 1)
                                RevealHaptics.shared.playTiltDetent(progress: progress)
                                #endif
                                hapticAnchor = clamped
                            }
                        }
                        .onEnded { _ in
                            model.endGesture()
                            hapticAnchor = .zero
                        }
                )
                // Disable inherited animation transactions on the rotated
                // subtree. Required to prevent the composed-3D-matrix wrap
                // bug that produced multi-360° spins under perspective.
                .transaction { $0.animation = nil }
                // Halos OUTSIDE the no-animation zone so the press change
                // (½ × opacity, 2× blur) springs smoothly.
                .shadow(
                    color: nearHalo.opacity((0.16 + haloEnergy * 0.18) * (model.isHolding ? 0.25 : 1.0)),
                    radius: (24 + haloEnergy * 18) * (model.isHolding ? 2.0 : 1.0),
                    x: 0,
                    y: 8 + holdBoost * 2
                )
                .shadow(
                    color: farHalo.opacity((0.10 + haloEnergy * 0.12) * (model.isHolding ? 0.25 : 1.0)),
                    radius: (54 + haloEnergy * 20) * (model.isHolding ? 2.0 : 1.0),
                    x: 0,
                    y: 18 + holdBoost * 4
                )
                .scaleEffect(model.isHolding ? 1.05 : 1.0)
                .animation(.snappy(duration: 0.32, extraBounce: 0.06), value: model.isHolding)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
    }

    // MARK: - Card image

    @ViewBuilder
    private var cardImage: some View {
        if let img = Self.bundledCardImage {
            #if os(macOS)
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
            #else
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
            #endif
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.1))
                .aspectRatio(512.0 / 308.0, contentMode: .fit)
        }
    }

    // MARK: - Shared shape

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    // MARK: - Image loading

    static let bundledCardImage: PlatformImage? = {
        guard let url = Bundle.main.url(forResource: "pnl-card", withExtension: "jpg") else {
            return nil
        }
        #if os(macOS)
        return NSImage(contentsOf: url)
        #else
        return UIImage(contentsOfFile: url.path)
        #endif
    }()
}

// MARK: - Canvas-driven effects layer
//
// One TimelineView + one Canvas draw the inner glow + shine sweep + edge rim
// shine in a single pass. Replaces the previous stack of overlay views (a
// RadialGradient, an AngularGradient.blur(26), two blurred Ellipses, a
// masked Capsule with multiple gradient strokes, and 288 trim-stroke shapes
// for the rim) with one render node — collapsing the per-frame rebuild
// surface from "hundreds of views" to "one Canvas".

struct CardEffectsLayer: View {
    let model: CardMotionModel
    let cornerRadius: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            // Step physics first so the Canvas reads fresh values. Idempotent
            // when called with the same date (internal dt clamp).
            let _ = stepModel(at: timeline.date)

            Canvas(rendersAsynchronously: false) { context, size in
                drawEffects(
                    in: &context,
                    size: size,
                    now: timeline.date
                )
            }
            .allowsHitTesting(false)
        }
    }

    private func stepModel(at date: Date) {
        model.step(at: date)
    }

    // MARK: - Draw

    private func drawEffects(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let drag = model.dragOffset
        let dragNorm = model.tiltMagnitude
        let holdBoost: CGFloat = model.isHolding ? 1 : 0
        let t = now.timeIntervalSinceReferenceDate

        // Time-derived ambient cycles. No @State / repeatForever needed.
        let glowPulse  = 0.5 + 0.5 * sin(t * (.pi * 2) / 1.6)
        let haloDrift  = 0.5 + 0.5 * sin(t * (.pi * 2) / 2.7)
        let shineSweep = ((t + 0.2).truncatingRemainder(dividingBy: 3.2)) / 3.2 * 2.4 - 1.0
        let organicBreath = 0.52 + CGFloat(glowPulse) * 0.30 + CGFloat(haloDrift) * 0.18

        let tiltX = clamp(drag.width  / 140, -1, 1)
        let tiltY = clamp(drag.height / 140, -1, 1)
        let primaryX = clamp(0.50 - tiltX * 0.22, 0.14, 0.86)
        let primaryY = clamp(0.42 - tiltY * 0.18, 0.14, 0.82)
        let secondaryX = clamp(primaryX + tiltX * 0.10 - 0.08, 0.12, 0.88)
        let secondaryY = clamp(primaryY + tiltY * 0.08 + 0.08, 0.10, 0.88)

        // Clip everything to the rounded card silhouette.
        let rect = CGRect(origin: .zero, size: size)
        let clip = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.clip(to: clip)
        context.blendMode = .plusLighter

        drawInnerGlow(
            in: &context,
            rect: rect,
            dragNorm: dragNorm,
            holdBoost: holdBoost,
            organicBreath: organicBreath,
            primaryX: primaryX, primaryY: primaryY,
            secondaryX: secondaryX, secondaryY: secondaryY,
            tiltX: tiltX, tiltY: tiltY
        )

        if holdBoost > 0 {
            drawShineSweep(
                in: &context,
                rect: rect,
                drag: drag,
                dragNorm: dragNorm,
                holdBoost: holdBoost,
                shineSweep: CGFloat(shineSweep),
                tiltX: tiltX, tiltY: tiltY
            )
        }

        drawEdgeRim(
            in: &context,
            rect: rect,
            drag: drag,
            dragNorm: dragNorm,
            isHolding: model.isHolding
        )
    }

    // MARK: - Inner glow (white halo + angular sheen + 2 specular hot spots)

    private func drawInnerGlow(
        in context: inout GraphicsContext,
        rect: CGRect,
        dragNorm: CGFloat,
        holdBoost: CGFloat,
        organicBreath: CGFloat,
        primaryX: CGFloat, primaryY: CGFloat,
        secondaryX: CGFloat, secondaryY: CGFloat,
        tiltX: CGFloat, tiltY: CGFloat
    ) {
        let w = rect.width, h = rect.height
        let p = CGPoint(x: rect.minX + primaryX * w, y: rect.minY + primaryY * h)
        let s = CGPoint(x: rect.minX + secondaryX * w, y: rect.minY + secondaryY * h)

        // Soft white halo (always on).
        var halo = context
        halo.opacity = 0.42 + holdBoost * 0.20 + dragNorm * 0.06
        halo.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [
                    .white.opacity(0.10 + holdBoost * 0.06),
                    .white.opacity(0.04 + holdBoost * 0.03),
                    .clear
                ]),
                center: p,
                startRadius: 0,
                endRadius: max(w, h) * (0.42 + dragNorm * 0.03 + holdBoost * 0.05)
            )
        )

        // Specular hot spot — only on press.
        if holdBoost > 0 {
            let hotW = w * (0.22 + dragNorm * 0.04)
            let hotH = h * 0.16
            let hot = CGRect(x: p.x - hotW * 0.5, y: p.y - hotH * 0.5, width: hotW, height: hotH)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 7.5))
                layer.opacity = holdBoost * 0.85 * organicBreath
                layer.fill(
                    Path(ellipseIn: hot),
                    with: .radialGradient(
                        Gradient(colors: [
                            .white.opacity(0.34),
                            .white.opacity(0.08),
                            .clear
                        ]),
                        center: CGPoint(x: hot.midX, y: hot.midY),
                        startRadius: 0,
                        endRadius: max(w, h) * 0.15
                    )
                )
            }

            // Secondary, even softer.
            let secW = w * 0.14, secH = h * 0.11
            let sec = CGRect(x: s.x - secW * 0.5, y: s.y - secH * 0.5, width: secW, height: secH)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 8.5))
                layer.opacity = holdBoost * 0.7
                layer.fill(
                    Path(ellipseIn: sec),
                    with: .radialGradient(
                        Gradient(colors: [
                            .white.opacity(0.14),
                            .white.opacity(0.04),
                            .clear
                        ]),
                        center: CGPoint(x: sec.midX, y: sec.midY),
                        startRadius: 0,
                        endRadius: max(w, h) * 0.10
                    )
                )
            }
        }
    }

    // MARK: - Shine sweep (capsule diagonal, press-only)

    private func drawShineSweep(
        in context: inout GraphicsContext,
        rect: CGRect,
        drag: CGSize,
        dragNorm: CGFloat,
        holdBoost: CGFloat,
        shineSweep: CGFloat,
        tiltX: CGFloat, tiltY: CGFloat
    ) {
        let w = rect.width, h = rect.height
        let bandWidth = w * (0.26 + dragNorm * 0.05 + holdBoost * 0.03)
        let bandRect = CGRect(
            x: -bandWidth * 0.5,
            y: -h * 1.55 * 0.5,
            width: bandWidth,
            height: h * 1.55
        )
        let sweepBase = (shineSweep * (w * 1.55)) - (w * 0.78)
        let centerX = rect.midX + sweepBase + drag.width * 0.92
        let centerY = rect.midY + drag.height * 0.34 - drag.width * 0.12

        context.drawLayer { layer in
            // 0.2 = shine intensity multiplier. The gradient was visibly
            // blowing out the highlight; scaling the whole layer keeps the
            // sweep shape intact while taking the peak from ~0.86 down to
            // ~0.17 alpha at full press.
            layer.opacity = holdBoost * 0.2
            layer.translateBy(x: centerX, y: centerY)
            layer.rotate(by: .degrees(14 + tiltX * 12 - tiltY * 6))

            let p = Path(roundedRect: bandRect, cornerRadius: bandRect.width * 0.5)
            layer.fill(
                p,
                with: .linearGradient(
                    Gradient(colors: [
                        .clear,
                        .white.opacity(0.03),
                        .white.opacity(0.20 + holdBoost * 0.04),
                        .white.opacity(0.72 + holdBoost * 0.14),
                        .white.opacity(0.18 + holdBoost * 0.04),
                        .clear
                    ]),
                    startPoint: CGPoint(x: bandRect.minX, y: 0),
                    endPoint:   CGPoint(x: bandRect.maxX, y: 0)
                )
            )
            layer.stroke(
                p,
                with: .linearGradient(
                    Gradient(colors: [
                        .clear,
                        .white.opacity(0.08),
                        .white.opacity(0.28 + holdBoost * 0.08),
                        .clear
                    ]),
                    startPoint: CGPoint(x: bandRect.minX, y: 0),
                    endPoint:   CGPoint(x: bandRect.maxX, y: 0)
                ),
                lineWidth: 1
            )
        }
    }

    // MARK: - Edge rim shine (two tapered arcs along the perimeter)

    private func drawEdgeRim(
        in context: inout GraphicsContext,
        rect: CGRect,
        drag: CGSize,
        dragNorm: CGFloat,
        isHolding: Bool
    ) {
        let angle = CGFloat(atan2(Double(drag.height), Double(drag.width)))
        let normalized = wrappedUnit((angle / (.pi * 2)) + 0.125)
        let primaryLength = 0.10 + dragNorm * 0.08
        let secondaryLength = primaryLength * (0.92 + dragNorm * 0.05)
        let secondaryOffset = 0.5 + drag.width / 2400 - drag.height / 2600
        // Subtle baseline at rest, full punch on press.
        let activation: CGFloat = isHolding ? (0.34 + dragNorm * 0.66) : 0.12

        strokeTaperedArc(
            in: &context,
            rect: rect,
            start: normalized - primaryLength * 0.5,
            length: primaryLength,
            opacity: activation * 0.95
        )
        strokeTaperedArc(
            in: &context,
            rect: rect,
            start: normalized + secondaryOffset - secondaryLength * 0.5,
            length: secondaryLength,
            opacity: activation * 0.78
        )
    }

    /// Approximates a variable-width stroke along the rounded-rect perimeter
    /// by sampling the trim into N small segments and stroking each at a
    /// width determined by a smoothstep ramp + plateau (0 at ends → max in
    /// middle → 0 at end). 64 samples is well below the 288 Shape views the
    /// previous SwiftUI implementation rebuilt every frame.
    private func strokeTaperedArc(
        in context: inout GraphicsContext,
        rect: CGRect,
        start: CGFloat,
        length: CGFloat,
        opacity: CGFloat
    ) {
        guard opacity > 0.005 else { return }
        let samples = 64
        let segLen = length / CGFloat(samples)
        let plateau: CGFloat = 0.55
        let ramp = (1 - plateau) / 2

        let basePath = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect)

        for i in 0 ..< samples {
            let t = (CGFloat(i) + 0.5) / CGFloat(samples)
            let w = taperWeight(t: t, ramp: ramp)
            if w <= 0.005 { continue }

            let segStart = wrappedUnit(start + CGFloat(i) * segLen)
            let segEnd = segStart + segLen * 1.18
            let p = perimeterArc(of: basePath, from: segStart, to: segEnd)

            context.stroke(p, with: .color(.white.opacity(opacity * 0.22)),
                           style: StrokeStyle(lineWidth: 5.5 * w, lineCap: .butt, lineJoin: .round))
            context.stroke(p, with: .color(.white.opacity(opacity * 0.55)),
                           style: StrokeStyle(lineWidth: 2.6 * w, lineCap: .butt, lineJoin: .round))
            context.stroke(p, with: .color(.white.opacity(min(1, opacity * 1.15))),
                           style: StrokeStyle(lineWidth: 1.1 * w, lineCap: .butt, lineJoin: .round))
        }
    }

    private func perimeterArc(of basePath: Path, from: CGFloat, to: CGFloat) -> Path {
        var out = Path()
        if to <= 1 {
            out.addPath(basePath.trimmedPath(from: from, to: to))
        } else {
            // Wraps around the 0/1 seam — draw two pieces.
            out.addPath(basePath.trimmedPath(from: from, to: 1))
            out.addPath(basePath.trimmedPath(from: 0, to: to - 1))
        }
        return out
    }

    private func taperWeight(t: CGFloat, ramp: CGFloat) -> CGFloat {
        if t < ramp {
            let u = t / ramp
            return u * u * (3 - 2 * u)
        } else if t > (1 - ramp) {
            let u = (1 - t) / ramp
            return u * u * (3 - 2 * u)
        } else {
            return 1
        }
    }

    private func wrappedUnit(_ v: CGFloat) -> CGFloat {
        let r = v.truncatingRemainder(dividingBy: 1)
        return r >= 0 ? r : r + 1
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}
