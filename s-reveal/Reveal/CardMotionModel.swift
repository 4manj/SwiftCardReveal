import SwiftUI
import Observation

/// Motion model for the 3D card. Owns all per-frame physics state and is
/// driven by `TimelineView(.animation)` rather than a Timer.publish, so it
/// no longer triggers full SwiftUI body re-evaluation at 120 Hz. Existing
/// behavior preserved end-to-end:
///
/// - Inertial zero-gravity wander with two-octave value-noise perturbations
/// - Carry-over of release momentum into ambient drift (state continuity)
/// - Pinch-cancellation watchdog (no `.onEnded` after a system gesture
///   interrupt → recover after 120 ms of silence)
/// - Settle window after release before ambient ramps in
/// - ±240 px clamped gesture input → ±20° clamped tilt
@Observable
final class CardMotionModel {

    // Public, read-only physics state consumed by views.
    private(set) var dragOffset: CGSize = .zero
    private(set) var velocity: CGSize = .zero
    private(set) var isHolding: Bool = false

    /// `0..1` magnitude of the current tilt, normalized against the soft cap.
    /// Used downstream for shine/glow brightness scaling.
    var tiltMagnitude: CGFloat {
        min(hypot(dragOffset.width, dragOffset.height) / 170, 1)
    }

    // MARK: - Internal state

    private var targetDragOffset: CGSize = .zero
    private var ambientTime: CGFloat = 0
    private var lastStepAt: Date?
    private var lastGestureSampleAt: Date?
    private var lastInteractionEndedAt: Date = .distantPast
    private var lastDragSampleAt: Date?
    private var lastDragSampleOffset: CGSize = .zero

    // MARK: - Gesture API (called from the SwiftUI gesture handlers)

    func beginGesture() {
        isHolding = true
        lastGestureSampleAt = Date()
    }

    func updateGesture(translation: CGSize) {
        let now = Date()
        lastGestureSampleAt = now
        if !isHolding { isHolding = true }

        let clamped = CGSize(
            width: clamp(translation.width, -240, 240),
            height: clamp(translation.height, -240, 240)
        )
        targetDragOffset = clamped

        // Track gesture velocity so the inertial sim can pick up release
        // momentum instead of starting from zero.
        if let prev = lastDragSampleAt {
            let dt = max(now.timeIntervalSince(prev), 1.0 / 240.0)
            let vx = (clamped.width - lastDragSampleOffset.width) / dt
            let vy = (clamped.height - lastDragSampleOffset.height) / dt
            velocity = CGSize(
                width: clamp(velocity.width * 0.65 + vx * 0.35, -520, 520),
                height: clamp(velocity.height * 0.65 + vy * 0.35, -520, 520)
            )
        }
        lastDragSampleAt = now
        lastDragSampleOffset = clamped
    }

    func endGesture() {
        isHolding = false
        lastGestureSampleAt = nil
        lastDragSampleAt = nil
        lastDragSampleOffset = dragOffset
        lastInteractionEndedAt = Date()
    }

    // MARK: - Per-tick physics step (called by TimelineView)

    func step(at now: Date) {
        // dt clamped to handle pause / very long gaps without exploding.
        let dt: CGFloat
        if let last = lastStepAt {
            dt = clamp(CGFloat(now.timeIntervalSince(last)), 1.0 / 240.0, 1.0 / 30.0)
        } else {
            dt = 1.0 / 120.0
        }
        lastStepAt = now
        ambientTime += dt

        // Pinch-cancellation watchdog. If `.onEnded` never fires (because a
        // system gesture interrupted the drag), state would otherwise stay
        // stuck. After 120 ms of silence, recover.
        if isHolding,
           let lastSample = lastGestureSampleAt,
           now.timeIntervalSince(lastSample) > 0.12 {
            isHolding = false
            lastGestureSampleAt = nil
            lastDragSampleAt = nil
            lastInteractionEndedAt = now
            targetDragOffset = dragOffset
        }

        if isHolding {
            // While pressed: smooth toward the gesture target.
            let follow: CGFloat = 0.28
            dragOffset.width  += (targetDragOffset.width  - dragOffset.width)  * follow
            dragOffset.height += (targetDragOffset.height - dragOffset.height) * follow
            return
        }

        // Idle: deterministic cyclic orbit. The drag target traces a circle
        // (one full 0°→360° revolution per `cyclePeriod` seconds) inside the
        // ±5° rotation cap.
        let idleElapsed = now.timeIntervalSince(lastInteractionEndedAt)
        // Hold target at center for the first 100 ms after release so the
        // user's release momentum dissipates, then ramp the orbit in over
        // 600 ms — total ~700 ms settle window before the cycle is at
        // full radius.
        let cycleRamp = CGFloat(clamp((idleElapsed - 0.10) / 0.6, 0, 1))

        let cyclePeriod: CGFloat = 8.0
        let orbitRadius: CGFloat = 60   // = 5° tilt at /12 px-per-degree
        let phase = ambientTime * (.pi * 2) / cyclePeriod
        let target = CGSize(
            width:  cos(phase) * orbitRadius * cycleRamp,
            height: sin(phase) * orbitRadius * cycleRamp
        )

        // Soft ease toward the orbit point. Factor tuned so the card "follows"
        // the target without snapping — release momentum decays naturally
        // because target starts at (0,0) during the settle, then transitions
        // smoothly into the cycle.
        let follow: CGFloat = 0.10
        let prevX = dragOffset.width
        let prevY = dragOffset.height
        dragOffset.width  += (target.width  - dragOffset.width)  * follow
        dragOffset.height += (target.height - dragOffset.height) * follow

        // Track velocity from the position delta — keeps the gesture-velocity
        // estimator sensible if the user grabs the card again.
        if dt > 0 {
            velocity = CGSize(
                width:  (dragOffset.width  - prevX) / dt,
                height: (dragOffset.height - prevY) / dt
            )
        }

        // Defensive ±5° hard-bound clamp + bounce. Should be unreachable
        // with orbitRadius matching hardBound exactly, but kept as belt-and-
        // braces against edge cases (large dt during pause/resume, etc.).
        let hardBound: CGFloat = 60
        if abs(dragOffset.width) > hardBound {
            dragOffset.width = sign(dragOffset.width) * hardBound
            velocity.width  *= -0.18
        }
        if abs(dragOffset.height) > hardBound {
            dragOffset.height = sign(dragOffset.height) * hardBound
            velocity.height  *= -0.18
        }

        targetDragOffset = dragOffset
    }

    // MARK: - Helpers

    private func hash(_ x: CGFloat) -> CGFloat {
        let s = sin(x * 127.1 + 311.7) * 43758.5453123
        return s - floor(s)
    }

    private func smoothNoise(_ t: CGFloat, seed: CGFloat) -> CGFloat {
        let i = floor(t)
        let f = t - i
        let u = f * f * (3 - 2 * f)
        let a = hash(i + seed)
        let b = hash(i + 1 + seed)
        return ((a + (b - a) * u) * 2) - 1
    }

    private func sign(_ x: CGFloat) -> CGFloat { x < 0 ? -1 : 1 }
    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
    private func clamp(_ v: TimeInterval, _ lo: TimeInterval, _ hi: TimeInterval) -> TimeInterval { min(max(v, lo), hi) }
}
