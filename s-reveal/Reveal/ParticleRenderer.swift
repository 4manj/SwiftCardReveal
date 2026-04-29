import MetalKit
import MetalPerformanceShaders
import simd

#if os(iOS)
import UIKit
import CoreHaptics
#endif

// MARK: - Haptics
//
// One central, Core-Haptics-backed system shared by both the dust burst tap
// (`registerTap`) and the SwiftUI card view (`PnlCard3DView`). Replaces the
// scattered `UIImpactFeedbackGenerator` calls that felt chaotic.

#if os(iOS)
/// Single Core-Haptics-backed surface for every haptic in the app. One engine,
/// cached patterns, and a cancellable advanced player for the 4-second reveal
/// tail so Skip can cut it without tearing down the engine.
final class RevealHaptics {
    static let shared = RevealHaptics()

    private var engine: CHHapticEngine?
    private var isPrepared = false
    private var needsRestart = false

    // Cached fixed patterns. Pattern construction is cheap but not RT-safe;
    // we still build them once so re-fires only allocate a player.
    private var revealBurstPattern: CHHapticPattern?
    private var revealTailPattern: CHHapticPattern?
    private var cardPressPattern: CHHapticPattern?
    private var skipPattern: CHHapticPattern?
    private var tiltLightPattern: CHHapticPattern?
    private var tiltMediumPattern: CHHapticPattern?
    private var tiltStrongPattern: CHHapticPattern?

    /// Held while the reveal tail is in flight so Skip can stop it. Cleared
    /// when the tail completes naturally or when `stopReveal()` is called.
    private var activeRevealTailPlayer: CHHapticAdvancedPatternPlayer?

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent. Builds and starts the engine, wires interruption handlers,
    /// caches every fixed pattern, and primes the actuator with a near-silent
    /// transient so the user's first real haptic doesn't pay cold-start cost.
    func prewarm() {
        guard !isPrepared else {
            ensureRunning()
            return
        }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            // Both handlers fire off-main; bounce all mutable state writes to
            // main so the reveal-player ref + needsRestart flag aren't racing
            // with `playReveal` / `stopReveal`.
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.needsRestart = true
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Players become invalid after reset; drop the retained one
                    // so the next playReveal builds a fresh player.
                    self.activeRevealTailPlayer = nil
                    do {
                        try self.engine?.start()
                        self.needsRestart = false
                    } catch {
                        // Keep needsRestart=true so the next play retries.
                        self.needsRestart = true
                    }
                }
            }
            try engine.start()
            self.engine = engine

            try buildPatterns()
            isPrepared = true
            primeActuator()
        } catch {
            // Haptics are non-critical — silent failure is fine.
        }
    }

    private func ensureRunning() {
        // Self-heal if a haptic surface fires before SplashView wired prewarm.
        if !isPrepared {
            prewarm()
            return
        }
        guard let engine else { return }
        if needsRestart {
            do {
                try engine.start()
                needsRestart = false
            } catch {
                // Stay flagged — the next play will retry.
            }
        }
    }

    /// Near-silent transient that finishes initializing the actuator path.
    /// Same trick `UIFeedbackGenerator.prepare()` uses internally.
    private func primeActuator() {
        guard let engine else { return }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                .init(parameterID: .hapticIntensity, value: 0.001),
                .init(parameterID: .hapticSharpness, value: 0)
            ],
            relativeTime: 0
        )
        if let pattern = try? CHHapticPattern(events: [event], parameters: []),
           let player = try? engine.makePlayer(with: pattern) {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }

    // MARK: - Pattern construction

    private func buildPatterns() throws {
        revealBurstPattern  = try Self.makeRevealBurstPattern()
        revealTailPattern   = try Self.makeRevealTailPattern()
        cardPressPattern    = try Self.makeCardPressPattern()
        skipPattern         = try Self.makeSkipPattern()
        tiltLightPattern    = try Self.makeTiltPattern(intensity: 0.40, sharpness: 0.55)
        tiltMediumPattern   = try Self.makeTiltPattern(intensity: 0.55, sharpness: 0.60)
        tiltStrongPattern   = try Self.makeTiltPattern(intensity: 0.70, sharpness: 0.65)
    }

    // MARK: - Public play surface

    /// Tap-reveal: dense burst cluster (allowed to finish) layered with a
    /// 4-second cancellable tail (continuous bed + landing ticks + +2.0 s
    /// accent that lands with the share button reveal).
    func playReveal() {
        ensureRunning()
        guard let engine else { return }

        if let burst = revealBurstPattern,
           let burstPlayer = try? engine.makePlayer(with: burst) {
            try? burstPlayer.start(atTime: CHHapticTimeImmediate)
        }

        if let tail = revealTailPattern,
           let tailPlayer = try? engine.makeAdvancedPlayer(with: tail) {
            tailPlayer.completionHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.activeRevealTailPlayer = nil
                }
            }
            activeRevealTailPlayer = tailPlayer
            try? tailPlayer.start(atTime: CHHapticTimeImmediate)
        }
    }

    /// Hard-cut the in-flight tail. Burst (if still playing) is left alone —
    /// it's <200 ms and finishing it avoids a clipped feel on Skip.
    func stopReveal() {
        try? activeRevealTailPlayer?.stop(atTime: CHHapticTimeImmediate)
        activeRevealTailPlayer = nil
    }

    /// Solid initial transient + tiny sustained body. Used for card press
    /// and the Share button.
    func playCardPress() {
        play(cardPressPattern)
    }

    /// Single soft transient for the Skip cancel action — deliberately lighter
    /// than card press so the cancel reads as secondary, not celebratory.
    func playSkip() {
        play(skipPattern)
    }

    /// Quantized 3-step detent for the card tilt drag. Quantizing avoids
    /// per-event synthesis and keeps the feel consistent across tilt ranges.
    func playTiltDetent(progress: CGFloat) {
        let pattern: CHHapticPattern?
        if progress < 0.34 {
            pattern = tiltLightPattern
        } else if progress < 0.67 {
            pattern = tiltMediumPattern
        } else {
            pattern = tiltStrongPattern
        }
        play(pattern)
    }

    // MARK: - Internals

    private func play(_ pattern: CHHapticPattern?) {
        ensureRunning()
        guard let engine, let pattern,
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    // MARK: - Pattern factories

    private static func transient(at time: TimeInterval,
                                  intensity: Float,
                                  sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                .init(parameterID: .hapticIntensity, value: intensity),
                .init(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time
        )
    }

    private static func continuous(at time: TimeInterval,
                                   duration: TimeInterval,
                                   intensity: Float,
                                   sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                .init(parameterID: .hapticIntensity, value: intensity),
                .init(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time,
            duration: duration
        )
    }

    private static func makeRevealBurstPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            transient(at: 0.000, intensity: 0.95, sharpness: 0.85),
            transient(at: 0.040, intensity: 0.70, sharpness: 0.75),
            transient(at: 0.090, intensity: 0.50, sharpness: 0.65),
            transient(at: 0.160, intensity: 0.35, sharpness: 0.55)
        ], parameters: [])
    }

    private static func makeRevealTailPattern() throws -> CHHapticPattern {
        // Continuous bed starts at 0.20 so it doesn't pile on the burst.
        // Intensity / sharpness curves shape the "felt presence" of the fall.
        let bed = continuous(at: 0.20, duration: 3.80, intensity: 0.22, sharpness: 0.45)

        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0.20, value: 0.10),
                .init(relativeTime: 0.50, value: 0.30),
                .init(relativeTime: 1.00, value: 0.22),
                .init(relativeTime: 2.00, value: 0.18),
                .init(relativeTime: 3.30, value: 0.10),
                .init(relativeTime: 4.00, value: 0.00)
            ],
            relativeTime: 0
        )
        let sharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                .init(relativeTime: 0.20, value: 0.30),
                .init(relativeTime: 1.00, value: 0.55),
                .init(relativeTime: 3.50, value: 0.70)
            ],
            relativeTime: 0
        )

        // Sparse landing ticks across the fall window.
        let ticks: [CHHapticEvent] = [
            transient(at: 1.55, intensity: 0.55, sharpness: 0.70),
            transient(at: 1.78, intensity: 0.40, sharpness: 0.60),
            transient(at: 2.10, intensity: 0.45, sharpness: 0.65),
            transient(at: 2.55, intensity: 0.35, sharpness: 0.55),
            transient(at: 2.95, intensity: 0.50, sharpness: 0.65),
            transient(at: 3.35, intensity: 0.30, sharpness: 0.50),
            transient(at: 3.75, intensity: 0.45, sharpness: 0.60)
        ]

        // Main accent at the moment RevealOrchestrator flips `showButtons`.
        let accent = transient(at: 2.00, intensity: 0.75, sharpness: 0.55)

        return try CHHapticPattern(
            events: [bed] + ticks + [accent],
            parameterCurves: [intensityCurve, sharpnessCurve]
        )
    }

    private static func makeCardPressPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            transient(at: 0.00, intensity: 0.88, sharpness: 0.28),
            continuous(at: 0.01, duration: 0.08, intensity: 0.16, sharpness: 0.08)
        ], parameters: [])
    }

    private static func makeSkipPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            transient(at: 0.00, intensity: 0.50, sharpness: 0.40)
        ], parameters: [])
    }
   
    private static func makeTiltPattern(intensity: Float,
                                        sharpness: Float) throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            transient(at: 0.00, intensity: intensity, sharpness: sharpness)
        ], parameters: [])
    }
}
#endif

/// Owns Metal device, pipelines, buffers, textures, and the per-frame encode.
/// Lives on the SwiftUI Coordinator so it survives view updates.
final class ParticleRenderer: NSObject, MTKViewDelegate {
    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Metal core

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let drawablePixelFormat: MTLPixelFormat

    // MARK: - Pipelines

    private var simulatePipeline: MTLComputePipelineState!
    private var rescalePipeline: MTLComputePipelineState!
    private var simulatePetalsPipeline: MTLComputePipelineState!
    private var particleColorPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!
    private var downsamplePipeline: MTLRenderPipelineState!
    private var petalRenderPipeline: MTLRenderPipelineState!

    // MARK: - Buffers

    private var particleBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var particleCountBuffer: MTLBuffer!

    // Petal confetti buffers
    private var petalBuffer: MTLBuffer!
    private var petalUniformBuffer: MTLBuffer!
    private var petalAtlasTexture: MTLTexture!
    private var petalStartTime: CFTimeInterval?

    /// True while a petal burst is in progress. Used by RevealCoordinator to
    /// gate further taps so a second tap doesn't restart the effect mid-flight.
    var isAnimatingPetals: Bool {
        guard let start = petalStartTime else { return false }
        return Float(CACurrentMediaTime() - start) < PetalSystem.animationDuration
    }

    // MARK: - Textures

    private var particleColorTexture: MTLTexture?  // full-res, cleared each frame
    private var bloomDownsampled: MTLTexture?      // quarter-res
    private var bloomBlurred: MTLTexture?          // quarter-res
    private var maskShapeTexture: MTLTexture!

    // MARK: - State

    private var params: SimulationParameters
    private var drawableSize: CGSize = .zero
    private var aspect: Float = 1.0
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval?

    private var tapPos: SIMD2<Float> = .zero
    private var tapTime: Float = 100   // huge value = no recent tap

    /// Set when the user taps, used to drive the post-tap dust fade-out.
    private var revealedAt: CFTimeInterval?

    /// Weak handle on the MTKView so we can pause it when there's nothing to
    /// render (dust faded + no petals) and unpause on tap.
    private weak var hostView: MTKView?

    /// True when this renderer feeds the transparent overlay above the card.
    /// Foreground renderers skip dust/composite/bloom and only run the petal
    /// sim + render onto a transparent drawable, layering a second cohort of
    /// petals in front of the SwiftUI card.
    let isForegroundLayer: Bool

    /// Per-renderer petal count. Foreground gets a quarter of the background's
    /// cohort so it reads as a sparse highlight layer instead of doubling the
    /// confetti density.
    private let petalCount: Int

    // MARK: - Bloom (lazy — MPS allocation isn't free)

    private lazy var gaussianBlur: MPSImageGaussianBlur = {
        // Source-space target ≈ 6 px; bloom textures are 1/4 res, so divide.
        let blur = MPSImageGaussianBlur(device: device, sigma: 1.5)
        blur.edgeMode = .clamp
        return blur
    }()

    // MARK: - Init

    init?(view: MTKView, isForegroundLayer: Bool = false) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            print("[ParticleRenderer] Metal not available")
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.drawablePixelFormat = view.colorPixelFormat
        self.params = SimulationParameters.recommended()
        self.hostView = view
        self.isForegroundLayer = isForegroundLayer
        self.petalCount = isForegroundLayer ? PetalSystem.count / 4 : PetalSystem.count

        super.init()

        do {
            try buildPipelines()
            buildBuffers()
            try loadMaskShapeTexture()
            try loadPetalAtlas()
        } catch {
            print("[ParticleRenderer] init failed: \(error)")
            return nil
        }

        // Sanity: Swift and Metal must agree on the particle stride. If this
        // ever fails, the GPU is reading garbage.
        assert(MemoryLayout<Particle>.stride == 32,
               "Particle stride changed; update Common.h to match.")
        assert(MemoryLayout<FrameUniforms>.stride == 80,
               "FrameUniforms stride changed; update Common.h to match.")
        assert(MemoryLayout<Petal>.stride == 56,
               "Petal stride changed; update Common.h to match.")
        assert(MemoryLayout<PetalUniforms>.stride == 48,
               "PetalUniforms stride changed; update Common.h to match.")
    }

    // MARK: - Pipeline construction

    private func buildPipelines() throws {
        // Compute
        guard let simFn = library.makeFunction(name: "simulateParticles") else {
            throw RendererError.missingFunction("simulateParticles")
        }
        simulatePipeline = try device.makeComputePipelineState(function: simFn)

        guard let rescaleFn = library.makeFunction(name: "rescaleParticlesX") else {
            throw RendererError.missingFunction("rescaleParticlesX")
        }
        rescalePipeline = try device.makeComputePipelineState(function: rescaleFn)

        guard let simPetalFn = library.makeFunction(name: "simulatePetals") else {
            throw RendererError.missingFunction("simulatePetals")
        }
        simulatePetalsPipeline = try device.makeComputePipelineState(function: simPetalFn)

        // Petal render pipeline (alpha-blended on top of composite).
        let petalDesc = MTLRenderPipelineDescriptor()
        petalDesc.label = "PetalRender"
        petalDesc.vertexFunction = library.makeFunction(name: "petalVertex")
        petalDesc.fragmentFunction = library.makeFunction(name: "petalFragment")
        let petalAtt = petalDesc.colorAttachments[0]!
        petalAtt.pixelFormat = drawablePixelFormat
        petalAtt.isBlendingEnabled = true
        petalAtt.rgbBlendOperation = .add
        petalAtt.alphaBlendOperation = .add
        // Source is already premultiplied (fragment outputs `tint * alpha`).
        petalAtt.sourceRGBBlendFactor = .one
        petalAtt.destinationRGBBlendFactor = .oneMinusSourceAlpha
        petalAtt.sourceAlphaBlendFactor = .one
        petalAtt.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        petalRenderPipeline = try device.makeRenderPipelineState(descriptor: petalDesc)

        // Particle color pass
        particleColorPipeline = try makeAdditiveRenderPipeline(
            vertex: "particleVertex",
            fragment: "particleFragment",
            colorFormat: .bgra8Unorm,
            label: "ParticleColor"
        )

        // Composite (no blending, writes opaque to drawable)
        let compositeDesc = MTLRenderPipelineDescriptor()
        compositeDesc.label = "Composite"
        compositeDesc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        compositeDesc.fragmentFunction = library.makeFunction(name: "compositeFragment")
        compositeDesc.colorAttachments[0].pixelFormat = drawablePixelFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDesc)

        // Downsample (used to feed bloom)
        let downsampleDesc = MTLRenderPipelineDescriptor()
        downsampleDesc.label = "Downsample"
        downsampleDesc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        downsampleDesc.fragmentFunction = library.makeFunction(name: "downsampleFragment")
        downsampleDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        downsamplePipeline = try device.makeRenderPipelineState(descriptor: downsampleDesc)
    }

    private func makeAdditiveRenderPipeline(vertex: String,
                                            fragment: String,
                                            colorFormat: MTLPixelFormat,
                                            label: String) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = colorFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private func buildBuffers() {
        particleBuffer = device.makeBuffer(
            length: params.particleCount * MemoryLayout<Particle>.stride,
            options: .storageModeShared
        )!
        particleBuffer.label = "Particles"
        seedParticles(into: particleBuffer)

        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<FrameUniforms>.stride,
            options: .storageModeShared
        )!
        uniformBuffer.label = "Uniforms"

        var count: UInt32 = UInt32(params.particleCount)
        particleCountBuffer = device.makeBuffer(
            bytes: &count,
            length: MemoryLayout<UInt32>.size,
            options: .storageModeShared
        )!
        particleCountBuffer.label = "ParticleCount"

        // Petals: allocate the cohort once; refilled on each tap.
        petalBuffer = device.makeBuffer(
            length: petalCount * MemoryLayout<Petal>.stride,
            options: .storageModeShared
        )!
        petalBuffer.label = "Petals"

        petalUniformBuffer = device.makeBuffer(
            length: MemoryLayout<PetalUniforms>.stride,
            options: .storageModeShared
        )!
        petalUniformBuffer.label = "PetalUniforms"
    }

    private func seedParticles(into buffer: MTLBuffer) {
        let seeded = ParticleSystem.makeInitialParticles(
            count: params.particleCount,
            seed: 0xC0FFEE_BABE,
            aspect: max(aspect, 0.001),
            params: params
        )
        buffer.contents().copyMemory(
            from: seeded,
            byteCount: seeded.count * MemoryLayout<Particle>.stride
        )
    }

    private func loadPetalAtlas() throws {
        guard let cgImage = PetalArt.makeAtlasCGImage() else {
            throw RendererError.artGenerationFailed
        }
        let loader = MTKTextureLoader(device: device)
        petalAtlasTexture = try loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .generateMipmaps: false
        ])
        petalAtlasTexture.label = "PetalAtlas"
    }

    private func loadMaskShapeTexture() throws {
        let loader = MTKTextureLoader(device: device)

        let cgImage: CGImage
        if let rasterized = MaskShape.rasterize(size: 512) {
            cgImage = rasterized
        } else {
            print("[ParticleRenderer] Failed to rasterize mask-shape.svg path; falling back to procedural circle mask.")
            guard let fallback = MaskShape.rasterizeFallbackCircle(size: 512) else {
                throw RendererError.artGenerationFailed
            }
            cgImage = fallback
        }

        maskShapeTexture = try loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
        maskShapeTexture.label = "MaskShape"
    }

    // MARK: - Resize

    private func rebuildOffscreenTextures(drawableSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))

        particleColorTexture = makeRenderTarget(
            format: .bgra8Unorm, width: w, height: h,
            usage: [.renderTarget, .shaderRead], label: "ParticleColor")

        let bw = max(1, w / 4)
        let bh = max(1, h / 4)
        bloomDownsampled = makeRenderTarget(
            format: .bgra8Unorm, width: bw, height: bh,
            usage: [.renderTarget, .shaderRead, .shaderWrite], label: "BloomDownsampled")
        bloomBlurred = makeRenderTarget(
            format: .bgra8Unorm, width: bw, height: bh,
            usage: [.renderTarget, .shaderRead, .shaderWrite], label: "BloomBlurred")

    }

    private func makeRenderTarget(format: MTLPixelFormat,
                                  width: Int,
                                  height: Int,
                                  usage: MTLTextureUsage,
                                  label: String) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = label
        return tex
    }

    // MARK: - Public input

    func registerTap(viewLocation: CGPoint, viewSize: CGSize, playHaptics: Bool = true) {
        tapPos = CoordinateSpace.tapToParticleSpace(
            viewLocation: viewLocation,
            viewSize: viewSize,
            aspect: aspect
        )
        tapTime = 0

        // Petals always spawn from CARD CENTER (screen center), regardless of
        // where the user tapped — they should look like they're erupting from
        // behind the card, not the tap point. Foreground layer XORs in a fixed
        // mask so its cohort visibly differs from the background layer's.
        let baseSeed = UInt64(CACurrentMediaTime() * 1_000_000)
        let seed = isForegroundLayer ? baseSeed ^ 0xCAFE_BABE_DEAD_BEEF : baseSeed
        let petals = PetalSystem.makePetals(at: .zero, seed: seed, count: petalCount)
        petalBuffer.contents().copyMemory(
            from: petals,
            byteCount: petals.count * MemoryLayout<Petal>.stride
        )
        petalStartTime = CACurrentMediaTime()
        if revealedAt == nil { revealedAt = CACurrentMediaTime() }
        // Wake the renderer if it had paused itself after the previous burst.
        hostView?.isPaused = false

        #if os(iOS)
        // Burst cluster + 4-second cancellable tail. The tail's continuous bed
        // and landing ticks fill the petal-fall window the old single-arc left
        // silent; the +2.0 s accent inside the tail aligns with showButtons.
        // Suppressed for the foreground layer so the user only hears one arc.
        if playHaptics {
            RevealHaptics.shared.playReveal()
        }
        #endif
    }

    func resetReveal() {
    }

    /// Restore the pre-tap state — dust comes back to full opacity, any
    /// in-flight petal burst stops, the reveal mask is cleared, and the
    /// renderer un-pauses so it can redraw the dust-only scene immediately.
    /// Used by the Skip button.
    func resetToInitial() {
        #if os(iOS)
        // Cut the haptic tail before the visual reset so they finish together.
        RevealHaptics.shared.stopReveal()
        #endif
        revealedAt = nil
        petalStartTime = nil
        tapTime = 100   // huge value = no recent tap
        seedParticles(into: particleBuffer)
        hostView?.isPaused = false
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        let newAspect = size.height > 0 ? Float(size.width / size.height) : 1.0
        // Particles are seeded at aspect 1.0; rescale x on every change so the
        // cloud fills landscape / iPad / macOS / visionOS windows correctly.
        if newAspect > 0, abs(newAspect - aspect) > 1e-3 {
            enqueueAspectRescale(scale: newAspect / aspect)
            aspect = newAspect
        }
        rebuildOffscreenTextures(drawableSize: size)
    }

    private func enqueueAspectRescale(scale: Float) {
        // Same queue serializes ordering: this runs before the next frame's
        // simulate kernel, so we don't race with in-flight work.
        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        cb.label = "AspectRescale"
        enc.label = "RescaleX"

        var s = scale
        var n = UInt32(params.particleCount)
        enc.setComputePipelineState(rescalePipeline)
        enc.setBuffer(particleBuffer, offset: 0, index: 0)
        enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 1)
        enc.setBytes(&n, length: MemoryLayout<UInt32>.size, index: 2)

        let tew = rescalePipeline.threadExecutionWidth
        let groups = (params.particleCount + tew - 1) / tew
        enc.dispatchThreadgroups(
            MTLSize(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
        )
        enc.endEncoding()
        cb.commit()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let particleColor = particleColorTexture,
              let bloomA = bloomDownsampled,
              let bloomB = bloomBlurred,
              let cb = commandQueue.makeCommandBuffer() else {
            return
        }
        cb.label = "Frame"

        // ----- Frame timing -----
        let now = CACurrentMediaTime()
        let dt = FrameTiming.clampedDt(now: now, last: lastFrameTime)
        lastFrameTime = now
        tapTime += dt

        let hasTapped = revealedAt != nil
        let pretapRadiusX: Float = 0.30
        let pretapRadiusY: Float = 0.30
        let postTapRadius = max(aspect, 1.0) * 1.8

        let maskRadiusX: Float
        let maskRadiusY: Float
        let edgeGlowStrength: Float
        if hasTapped {
            let t = simd_clamp(tapTime / 0.85, 0, 1)
            let eased = 1 - pow(1 - t, 3)
            maskRadiusX = pretapRadiusX + (postTapRadius - pretapRadiusX) * eased
            maskRadiusY = pretapRadiusY + (postTapRadius - pretapRadiusY) * eased
            edgeGlowStrength = sin(.pi * t)
        } else {
            maskRadiusX = pretapRadiusX
            maskRadiusY = pretapRadiusY
            edgeGlowStrength = 0
        }

        let burstEnvelope: Float
        if hasTapped {
            let t = tapTime
            if t < 0.05 {
                burstEnvelope = 0
            } else if t < 0.45 {
                burstEnvelope = Self.smoothstep(0.05, 0.20, t)
            } else {
                burstEnvelope = 1.0 - Self.smoothstep(0.45, 0.95, t)
            }
        } else {
            burstEnvelope = 0
        }

        // Dust fades out shortly after the tap so the SwiftUI card overlay
        // can take over the screen cleanly. Hold full for 0.18s after tap
        // (the dramatic burst moment), then linear-fade over 0.55s.
        let dustOpacity: Float
        if let rt = revealedAt {
            let since = Float(now - rt)
            let holdEnd: Float = 0.18
            let fadeDur: Float = 0.55
            let progress = max(0, since - holdEnd) / fadeDur
            dustOpacity = max(0, 1 - progress)
        } else {
            dustOpacity = 1
        }

        let bloomIntensity: Float = hasTapped
            ? params.bloomIntensity * (1.15 + 0.55 * (1.0 - Self.smoothstep(0.45, 1.2, tapTime)))
            : params.bloomIntensity * 1.05

        let uniforms = FrameUniforms(
            tapPos:         tapPos,
            time:           Float(now - startTime),
            dt:             dt,
            aspect:         aspect,
            noiseScale:     params.noiseScale,
            idleStrength:   params.idleStrength,
            upwardFlowSpeed: params.upwardFlowSpeed,
            bloomIntensity: bloomIntensity,
            dustOpacity:    dustOpacity,
            maskCenterY:    0.05,
            maskRadiusX:    maskRadiusX,
            maskRadiusY:    maskRadiusY,
            maskFeather:    0.42,
            edgeGlowStrength: edgeGlowStrength,
            tapTime:        tapTime,
            burstEnvelope:  burstEnvelope,
            pad0:           0,
            pad1:           0
        )
        uniformBuffer.contents().copyMemory(
            from: [uniforms],
            byteCount: MemoryLayout<FrameUniforms>.stride
        )

        // ----- Dust pipeline (background layer only) -----
        // Foreground renderer only produces the petal overlay above the card,
        // so we skip dust simulate / particle pass / bloom entirely there.
        if !isForegroundLayer {
            // ----- 1. Compute simulate -----
            if let enc = cb.makeComputeCommandEncoder() {
                enc.label = "Simulate"
                enc.setComputePipelineState(simulatePipeline)
                enc.setBuffer(particleBuffer, offset: 0, index: 0)
                enc.setBuffer(uniformBuffer, offset: 0, index: 1)
                enc.setBuffer(particleCountBuffer, offset: 0, index: 2)

                let tew = simulatePipeline.threadExecutionWidth
                let groups = (params.particleCount + tew - 1) / tew
                enc.dispatchThreadgroups(
                    MTLSize(width: groups, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
                )
                enc.endEncoding()
            }

            // ----- 2. Particle color render pass -----
            encodeParticlePass(into: cb,
                               target: particleColor,
                               pipeline: particleColorPipeline,
                               label: "ParticleColor",
                               loadAction: .clear)

            // ----- 3. Bloom: downsample → MPS Gaussian blur -----
            // Skip entirely when dust is faded — composite multiplies the bloom
            // sample by `dustOpacity` so a stale/zero texture is fine. Bloom +
            // MPS blur is one of the heaviest passes; gating it off saves real
            // GPU time post-tap once everything has settled.
            if dustOpacity > 0.01 {
                encodeDownsample(into: cb, source: particleColor, target: bloomA)
                gaussianBlur.encode(commandBuffer: cb, sourceTexture: bloomA, destinationTexture: bloomB)
            }
        }

        // ----- 4. Petal confetti simulate (only while a burst is active) -----
        let petalActive: Bool
        let petalElapsed: Float
        if let start = petalStartTime {
            let elapsed = Float(now - start)
            if elapsed < PetalSystem.animationDuration {
                petalActive = true
                petalElapsed = elapsed
            } else {
                petalStartTime = nil
                petalActive = false
                petalElapsed = 0
            }
        } else {
            petalActive = false
            petalElapsed = 0
        }

        if petalActive {
            // Petal-flow physics:
            //   - gentle gravity (lazy float-down)
            //   - light horizontal drag (lateral motion persists)
            //   - heavy vertical drag while falling (low terminal velocity, ~0.5 u/s)
            //   - flutterBoost amplifies sin-wave swirl during descent so they
            //     visibly sway side-to-side
            // `timeScale` fast-forwards the petal physics so the whole arc
            // (rise + flutter + fall) compresses into ~4 s wall-clock without
            // truncating the trajectory. Drag is computed against the scaled
            // dt so per-second damping rescales consistently.
            let petalDt = dt * PetalSystem.timeScale
            let petalUniforms = PetalUniforms(
                origin:           tapPos,
                elapsed:          petalElapsed * PetalSystem.timeScale,
                dt:               petalDt,
                aspect:           aspect,
                gravity:          4.4,                              // faster fall — petals were dragging
                dragPerFrame:     pow(0.992, petalDt * 60.0),
                fallDragPerFrame: pow(0.985, petalDt * 60.0),       // even less drag → snappier descent
                flutterBoost:     4.5,                              // stronger lateral sway during descent
                totalCount:       UInt32(petalCount),
                sizeMul:          isForegroundLayer ? 1.35 : 1.0,
                flipX:            isForegroundLayer ? -1.0 : 1.0
            )
            petalUniformBuffer.contents().copyMemory(
                from: [petalUniforms],
                byteCount: MemoryLayout<PetalUniforms>.stride
            )

            if let enc = cb.makeComputeCommandEncoder() {
                enc.label = "SimulatePetals"
                enc.setComputePipelineState(simulatePetalsPipeline)
                enc.setBuffer(petalBuffer, offset: 0, index: 0)
                enc.setBuffer(petalUniformBuffer, offset: 0, index: 1)

                let tew = simulatePetalsPipeline.threadExecutionWidth
                let groups = (petalCount + tew - 1) / tew
                enc.dispatchThreadgroups(
                    MTLSize(width: groups, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
                )
                enc.endEncoding()
            }
        }

        // ----- 5. Composite to drawable -----
        // Foreground layer skips the composite triangle; the MTKView's clear
        // colour is alpha-zero so the drawable starts fully transparent and
        // only the petal pass writes pixels.
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: renderPassDesc) {
            enc.label = isForegroundLayer ? "ForegroundPetals" : "Composite"

            if !isForegroundLayer {
                enc.setRenderPipelineState(compositePipeline)
                enc.setFragmentTexture(particleColor, index: 0)
                enc.setFragmentTexture(bloomB, index: 1)
                enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            // ----- 6. Petals on top, same render pass — saves a load/store -----
            if petalActive {
                enc.setRenderPipelineState(petalRenderPipeline)
                enc.setVertexBuffer(petalBuffer, offset: 0, index: 0)
                enc.setVertexBuffer(petalUniformBuffer, offset: 0, index: 1)
                enc.setFragmentTexture(petalAtlasTexture, index: 0)
                enc.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: petalCount
                )
            }

            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()

        // Pause the MTKView once dust is fully faded and no petals are
        // animating — Metal has nothing to draw, no reason to keep ticking
        // at full frame rate. `registerTap` re-enables on the next tap.
        if dustOpacity <= 0.001, !petalActive {
            hostView?.isPaused = true
        }
    }

    // MARK: - Pass helpers

    private func encodeParticlePass(into cb: MTLCommandBuffer,
                                    target: MTLTexture,
                                    pipeline: MTLRenderPipelineState,
                                    label: String,
                                    loadAction: MTLLoadAction) {
        let desc = MTLRenderPassDescriptor()
        let att = desc.colorAttachments[0]!
        att.texture = target
        att.loadAction = loadAction
        att.storeAction = .store
        att.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.label = label
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(maskShapeTexture, index: 0)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: params.particleCount)
        enc.endEncoding()
    }

    private func encodeDownsample(into cb: MTLCommandBuffer,
                                  source: MTLTexture,
                                  target: MTLTexture) {
        let desc = MTLRenderPassDescriptor()
        let att = desc.colorAttachments[0]!
        att.texture = target
        att.loadAction = .dontCare
        att.storeAction = .store

        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.label = "BloomDownsample"
        enc.setRenderPipelineState(downsamplePipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - Errors

    enum RendererError: Error {
        case missingFunction(String)
        case artGenerationFailed
    }
}
