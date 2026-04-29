import Foundation
import simd
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - GPU-shared structs
//
// Layouts must match `Petal` and `PetalUniforms` in `Shaders/Common.h`.
// `Petal` stride is asserted at renderer init.

struct Petal {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var angle: Float
    var angularVel: Float
    var life: Float
    var scale: Float
    var swirl: Float
    var swirlFreq: Float
    var swirlPhase: Float
    var spawnDelay: Float
    var petalIdx: UInt32
    var colorIdx: UInt32
}

struct PetalUniforms {
    /// Reserved for shader compatibility; petal spawn is driven by `Petal.position`.
    var _unusedOrigin: SIMD2<Float>
    var elapsed: Float
    var dt: Float
    var aspect: Float
    var gravity: Float
    var dragPerFrame: Float
    var fallDragPerFrame: Float
    var flutterBoost: Float
    var totalCount: UInt32
    /// Per-cohort size multiplier. Foreground layer renders larger to read as
    /// "closer to the camera" depth.
    var sizeMul: Float = 1.0
    /// −1 for the foreground cohort to mirror trajectories around the y-axis,
    /// so the same XOR'd seed produces a visibly different fall pattern.
    var flipX: Float = 1.0
}

// MARK: - Spawner
//
// Generates the 130-petal burst. Values ported from `PnlCardLive.jsx`'s
// `launchPetals`, scaled from pixel-space to particle-space.

enum PetalSystem {
    static let count = 320
    static let animationDuration: Float = 4.0
    /// Physics is fast-forwarded by this factor relative to wall-clock — the
    /// shader sees `dt * timeScale` per frame, so the same 5 s arc plays out
    /// in `5 / timeScale` seconds. Keep `animationDuration ≈ 5 / timeScale`
    /// so petals don't get gated off mid-fall.
    static let timeScale: Float = 1.25

    static func makePetals(at origin: SIMD2<Float>, seed: UInt64, count: Int = count) -> [Petal] {
        var rng = PRNG(seed: seed)
        var out: [Petal] = []
        out.reserveCapacity(count)

        for _ in 0 ..< count {
            // Tighter cone, biased upward — most petals shoot near-vertical so
            // there are more of them visibly falling back down through frame.
            let cone = Float.pi / 2 + rng.range(-0.75, 0.75)
            let speed = rng.range(2.7, 4.65)       // particle units / sec

            // +y is up in particle space, so velocity uses +sin(angle).
            let vx = cos(cone) * speed
            let vy = sin(cone) * speed

            out.append(Petal(
                position:    origin,
                velocity:    SIMD2(vx, vy),
                angle:       rng.range(0, 2 * .pi),
                angularVel:  rng.range(-3.5, 3.5),
                life:        1.0,
                scale:       rng.range(0.35, 0.9),
                swirl:       rng.range(0.020, 0.058),
                swirlFreq:   rng.range(0.6, 1.7),
                swirlPhase:  rng.range(0, 2 * .pi),
                spawnDelay:  rng.range(0.0, 0.08), // single instant burst
                petalIdx:    UInt32(rng.intRange(0, 3)),
                colorIdx:    UInt32(rng.intRange(0, 9))
            ))
        }
        return out
    }

    private struct PRNG {
        var state: UInt64
        init(seed: UInt64) { state = seed != 0 ? seed : 0xBE_E5_F1_07_BA_BE_CA_FE }
        mutating func nextU32() -> UInt32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 32)
        }
        mutating func range(_ lo: Float, _ hi: Float) -> Float {
            return lo + Float(nextU32()) / Float(UInt32.max) * (hi - lo)
        }
        mutating func intRange(_ lo: Int, _ hi: Int) -> Int {
            return lo + Int(nextU32() % UInt32(hi - lo))
        }
    }
}

// MARK: - Atlas generator
//
// Rasterizes the three petal SVG paths from JSX into a single
// horizontally-tiled CGImage that becomes a Metal texture.

enum PetalArt {
    // 256 per cell gives 4× the anti-aliased detail of the original 128, which
    // matters because the fragment shader only samples alpha — the edge softness
    // is the entire silhouette transition.
    static let cellSize: Int = 256

    static func makeAtlasCGImage() -> CGImage? {
        guard let crisp = renderCrispAtlas() else { return nil }
        // CG path AA is only ~1 px wide. On a 3x retina screen the petal
        // renders at ~70 px from a ~210 px source, so 1 src px → ~0.3 dst px:
        // the edge transition collapses into a single hard pixel. Gaussian-
        // blurring the atlas widens the alpha falloff to several pixels, which
        // gives the soft sakura look the JSX original has.
        return softened(crisp, radius: 3.0) ?? crisp
    }

    private static func renderCrispAtlas() -> CGImage? {
        let cell = cellSize
        let width = cell * 3
        let height = cell
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        // Tighter than 0.8 to leave breathing room for the post-blur halo so
        // it doesn't bleed across cell boundaries.
        let scale = CGFloat(cell) * 0.62 / 32.0

        for variant in 0 ..< 3 {
            let path = petalPath(variant: variant)

            ctx.saveGState()
            let cx = CGFloat(variant) * CGFloat(cell) + CGFloat(cell) / 2
            let cy = CGFloat(cell) / 2
            ctx.translateBy(x: cx, y: cy)
            ctx.scaleBy(x: scale, y: scale)

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()

            ctx.restoreGState()
        }

        return ctx.makeImage()
    }

    private static let blurContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func softened(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input
        filter.radius = Float(radius)
        // Blur enlarges the extent — crop back to the input rect so atlas UVs
        // stay aligned with the cells.
        guard let output = filter.outputImage else { return nil }
        return blurContext.createCGImage(output, from: input.extent)
    }

    private static func petalPath(variant: Int) -> CGPath {
        let path = CGMutablePath()
        switch variant {
        case 0:
            // JSX: M0,-14 C5,-12 13,-6 15,2 C17,10 13,18 6,22 C2,24 -2,24 -6,22 C-13,18 -17,10 -15,2 C-13,-6 -5,-12 0,-14 Z
            path.move(to: CGPoint(x: 0, y: -14))
            path.addCurve(to: CGPoint(x:  15, y:   2), control1: CGPoint(x:   5, y: -12), control2: CGPoint(x:  13, y:  -6))
            path.addCurve(to: CGPoint(x:   6, y:  22), control1: CGPoint(x:  17, y:  10), control2: CGPoint(x:  13, y:  18))
            path.addCurve(to: CGPoint(x:  -6, y:  22), control1: CGPoint(x:   2, y:  24), control2: CGPoint(x:  -2, y:  24))
            path.addCurve(to: CGPoint(x: -15, y:   2), control1: CGPoint(x: -13, y:  18), control2: CGPoint(x: -17, y:  10))
            path.addCurve(to: CGPoint(x:   0, y: -14), control1: CGPoint(x: -13, y:  -6), control2: CGPoint(x:  -5, y: -12))
        case 1:
            // JSX: M0,-13 C6,-10 12,-4 13,3 C15,11 10,19 4,22 C1,24 -3,23 -7,21 C-14,17 -16,9 -14,2 C-12,-5 -5,-11 0,-13 Z
            path.move(to: CGPoint(x: 0, y: -13))
            path.addCurve(to: CGPoint(x:  13, y:   3), control1: CGPoint(x:   6, y: -10), control2: CGPoint(x:  12, y:  -4))
            path.addCurve(to: CGPoint(x:   4, y:  22), control1: CGPoint(x:  15, y:  11), control2: CGPoint(x:  10, y:  19))
            path.addCurve(to: CGPoint(x:  -7, y:  21), control1: CGPoint(x:   1, y:  24), control2: CGPoint(x:  -3, y:  23))
            path.addCurve(to: CGPoint(x: -14, y:   2), control1: CGPoint(x: -14, y:  17), control2: CGPoint(x: -16, y:   9))
            path.addCurve(to: CGPoint(x:   0, y: -13), control1: CGPoint(x: -12, y:  -5), control2: CGPoint(x:  -5, y: -11))
        default:
            // JSX: M0,-15 C4,-12 11,-5 14,3 C16,11 12,20 5,23 C1,25 -3,24 -7,21 C-14,17 -17,8 -15,1 C-12,-6 -4,-12 0,-15 Z
            path.move(to: CGPoint(x: 0, y: -15))
            path.addCurve(to: CGPoint(x:  14, y:   3), control1: CGPoint(x:   4, y: -12), control2: CGPoint(x:  11, y:  -5))
            path.addCurve(to: CGPoint(x:   5, y:  23), control1: CGPoint(x:  16, y:  11), control2: CGPoint(x:  12, y:  20))
            path.addCurve(to: CGPoint(x:  -7, y:  21), control1: CGPoint(x:   1, y:  25), control2: CGPoint(x:  -3, y:  24))
            path.addCurve(to: CGPoint(x: -15, y:   1), control1: CGPoint(x: -14, y:  17), control2: CGPoint(x: -17, y:   8))
            path.addCurve(to: CGPoint(x:   0, y: -15), control1: CGPoint(x: -12, y:  -6), control2: CGPoint(x:  -4, y: -12))
        }
        path.closeSubpath()
        return path
    }
}
