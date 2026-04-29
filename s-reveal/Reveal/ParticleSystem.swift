import Foundation
import simd

// MARK: - GPU-shared structs
//
// Layouts must match `Particle` and `FrameUniforms` in `Shaders/Common.h`.
// `assertLayoutCompatibility()` is called once at renderer init.

struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var life: Float
    var size: Float
    var hueOffset: Float
    var seedBias: Float
}

struct FrameUniforms {
    var tapPos: SIMD2<Float>
    var time: Float
    var dt: Float
    var aspect: Float
    var noiseScale: Float
    var idleStrength: Float
    var upwardFlowSpeed: Float
    var bloomIntensity: Float
    var dustOpacity: Float
    var maskCenterY: Float
    var maskRadiusX: Float
    var maskRadiusY: Float
    var maskFeather: Float
    var edgeGlowStrength: Float
    var tapTime: Float
    var burstEnvelope: Float
    var pad0: Float
    var pad1: Float
}

struct CloudUniforms {
    var time: Float
    var aspect: Float
    var opacity: Float
    var bloomIntensity: Float
    /// 0 = centered single cloud, 1 = fully split into a small top + bottom
    /// pair with a clear middle. Ramps in just after `opacity` so the cloud
    /// reads as appearing centered for a moment, then separating.
    var splitProgress: Float
}

// MARK: - Tunable parameters

struct SimulationParameters {
    var particleCount: Int    = 4_000
    var noiseScale: Float     = 1.6
    var idleStrength: Float   = 0.04
    var upwardFlowSpeed: Float = 0.12
    var bloomIntensity: Float = 0.45
    var pointSizeRange: ClosedRange<Float> = 2.0 ... 7.0

    // Phase 7: device tier presets.
    static let phoneBaseline: SimulationParameters = {
        var p = SimulationParameters()
        p.particleCount = 4_000
        return p
    }()

    static let highEnd: SimulationParameters = {
        var p = SimulationParameters()
        p.particleCount = 8_000
        return p
    }()

    static func recommended() -> SimulationParameters {
        // Cheap heuristic: high-RAM iPhones / iPads / Macs run the high-end preset.
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return memGB >= 5.5 ? .highEnd : .phoneBaseline
    }
}

// MARK: - CPU-side particle initialization
//
// Deterministic for a given (count, seed, aspect) — exercised in unit tests.

enum ParticleSystem {
    /// Linear congruential RNG. We avoid `SystemRandomNumberGenerator` so
    /// the output is reproducible for tests and for visual A/B work.
    private struct PRNG {
        var state: UInt64
        init(seed: UInt64) { state = seed != 0 ? seed : 0xDEAD_BEEF_CAFE_F00D }

        mutating func nextU32() -> UInt32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 32)
        }
        mutating func nextUnit() -> Float {
            return Float(nextU32()) / Float(UInt32.max)
        }
        mutating func nextRange(_ lo: Float, _ hi: Float) -> Float {
            return lo + nextUnit() * (hi - lo)
        }
    }

    static func makeInitialParticles(count: Int,
                                     seed: UInt64,
                                     aspect: Float,
                                     params: SimulationParameters = .phoneBaseline) -> [Particle] {
        precondition(count >= 0, "count must be non-negative")
        var rng = PRNG(seed: seed)

        var out: [Particle] = []
        out.reserveCapacity(count)

        let lo = params.pointSizeRange.lowerBound
        let hi = params.pointSizeRange.upperBound
        for _ in 0 ..< count {
            let position = SIMD2(
                rng.nextRange(-aspect, aspect),
                rng.nextRange(-1.05, 1.05)
            )
            let velocity = SIMD2<Float>(0, 0)
            let particle = Particle(
                position: position,
                velocity: velocity,
                life: 1.0,
                size: rng.nextRange(lo, hi),
                hueOffset: rng.nextUnit(),
                seedBias: rng.nextUnit()
            )
            out.append(particle)
        }
        return out
    }
}

// MARK: - View ↔ particle space conversion
//
// The renderer uses particle space: x ∈ [-aspect, aspect], y ∈ [-1, 1],
// with +y pointing up. View space has top-left origin and +y pointing down.

enum CoordinateSpace {
    /// Converts a tap location (UIKit/AppKit-flipped, top-left origin) in points
    /// into particle space. `aspect = drawableWidth / drawableHeight`.
    static func tapToParticleSpace(viewLocation: CGPoint,
                                   viewSize: CGSize,
                                   aspect: Float) -> SIMD2<Float> {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }
        let nx = Float(viewLocation.x / viewSize.width) * 2.0 - 1.0
        let ny = -(Float(viewLocation.y / viewSize.height) * 2.0 - 1.0)
        return SIMD2(nx * max(aspect, 0.001), ny)
    }
}

// MARK: - dt clamp
//
// Backgrounded apps and stalled windows can deliver enormous deltas. Clamp
// before integrating so a paused app doesn't yeet every particle off-screen
// the moment it resumes.

enum FrameTiming {
    static let maxDt: Float = 1.0 / 20.0    // 50 ms

    static func clampedDt(now: CFTimeInterval, last: CFTimeInterval?) -> Float {
        guard let last = last else { return 1.0 / 60.0 }
        return min(Float(now - last), maxDt)
    }
}
