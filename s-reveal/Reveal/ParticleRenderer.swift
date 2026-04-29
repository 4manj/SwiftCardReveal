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
    private var cloudPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!
    private var downsamplePipeline: MTLRenderPipelineState!
    private var petalRenderPipeline: MTLRenderPipelineState!

    // MARK: - Buffers

    private var particleBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var cloudUniformBuffer: MTLBuffer!
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
    private var cloudColorTexture: MTLTexture?     // full-res, procedural cloud
    private var bloomDownsampled: MTLTexture?      // quarter-res
    private var bloomBlurred: MTLTexture?          // quarter-res
    private var cloudBloomBlurred: MTLTexture?     // quarter-res
    private var maskShapeTexture: MTLTexture!

    // MARK: - State

    private var params: SimulationParameters
    private var drawableSize: CGSize = .zero
    private var aspect: Float = 1.0
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval?

    private var tapTime: Float = 100   // huge value = no recent tap

    /// Set when the user taps, used to drive the post-tap dust fade-out.
    private var revealedAt: CFTimeInterval?

    /// Per-reveal effect toggles, captured at `registerTap`. Defaults true so
    /// existing callers get the original behaviour. Flip to false (e.g. when
    /// the P&L is negative) to suppress the cloud or petal effect for the
    /// current reveal without altering any of the underlying animation code.
    private var cloudEnabled: Bool = true
    private var petalsEnabled: Bool = true

    /// Weak handle on the MTKView for lifecycle coordination.
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

    // MARK: - Bloom

    private let gaussianBlur: MPSImageGaussianBlur

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
        let blur = MPSImageGaussianBlur(device: device, sigma: 1.5)
        blur.edgeMode = .clamp
        self.gaussianBlur = blur
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
            // Keep renderer-local warm-up non-blocking; SplashView kicks off a
            // process-level prewarm earlier so this usually just tops up cache.
            prewarmPipelines()
        } catch {
            print("[ParticleRenderer] init failed: \(error)")
            return nil
        }

        // Sanity: Swift and Metal must agree on the particle stride. If this
        // ever fails, the GPU is reading garbage.
        assert(MemoryLayout<Particle>.stride == 32,
               "Particle stride changed; update Common.h to match.")
        assert(MemoryLayout<FrameUniforms>.stride == 60,
               "FrameUniforms stride changed; update Common.h to match.")
        assert(MemoryLayout<CloudUniforms>.stride == 20,
               "CloudUniforms stride changed; update Common.h to match.")
        assert(MemoryLayout<Petal>.stride == 56,
               "Petal stride changed; update Common.h to match.")
        assert(MemoryLayout<PetalUniforms>.stride == 40,
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

        // Cloud renders into a half-float intermediate so the wide gaussian
        // gradients survive without 8-bit banding before final composite.
        let cloudDesc = MTLRenderPipelineDescriptor()
        cloudDesc.label = "Cloud"
        cloudDesc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        cloudDesc.fragmentFunction = library.makeFunction(name: "cloudFragment")
        cloudDesc.colorAttachments[0].pixelFormat = .rgba16Float
        cloudPipeline = try device.makeRenderPipelineState(descriptor: cloudDesc)

        // Composite (no blending, writes opaque to drawable)
        let compositeDesc = MTLRenderPipelineDescriptor()
        compositeDesc.label = "Composite"
        compositeDesc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        compositeDesc.fragmentFunction = library.makeFunction(name: "compositeFragment")
        compositeDesc.colorAttachments[0].pixelFormat = drawablePixelFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDesc)

        // Downsample (used to feed bloom). Output format must match the
        // bloom intermediates above — fp16 to avoid banding on big soft
        // gradients before MPS blurs them.
        let downsampleDesc = MTLRenderPipelineDescriptor()
        downsampleDesc.label = "Downsample"
        downsampleDesc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        downsampleDesc.fragmentFunction = library.makeFunction(name: "downsampleFragment")
        downsampleDesc.colorAttachments[0].pixelFormat = .rgba16Float
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

        cloudUniformBuffer = device.makeBuffer(
            length: MemoryLayout<CloudUniforms>.stride,
            options: .storageModeShared
        )!
        cloudUniformBuffer.label = "CloudUniforms"

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
            print("[ParticleRenderer] Failed to rasterize embedded mask-shape path; falling back to procedural circle mask.")
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

    private func prewarmPipelines() {
        let warmParticleBuffer = device.makeBuffer(
            length: params.particleCount * MemoryLayout<Particle>.stride,
            options: .storageModeShared
        )
        let warmUniformBuffer = device.makeBuffer(
            length: MemoryLayout<FrameUniforms>.stride,
            options: .storageModeShared
        )
        let warmCloudUniformBuffer = device.makeBuffer(
            length: MemoryLayout<CloudUniforms>.stride,
            options: .storageModeShared
        )
        let warmPetalBuffer = device.makeBuffer(
            length: petalCount * MemoryLayout<Petal>.stride,
            options: .storageModeShared
        )
        let warmPetalUniformBuffer = device.makeBuffer(
            length: MemoryLayout<PetalUniforms>.stride,
            options: .storageModeShared
        )

        guard let warmParticleBuffer,
              let warmUniformBuffer,
              let warmCloudUniformBuffer,
              let warmPetalBuffer,
              let warmPetalUniformBuffer else {
            return
        }

        seedParticles(into: warmParticleBuffer)

        let particleWarm = isForegroundLayer ? nil : makeRenderTarget(
                format: .bgra8Unorm,
                width: 4,
                height: 4,
                usage: [.renderTarget, .shaderRead],
                label: "PrewarmParticle"
              )
        let cloudWarm = isForegroundLayer ? nil : makeRenderTarget(
                format: .rgba16Float,
                width: 4,
                height: 4,
                usage: [.renderTarget, .shaderRead],
                label: "PrewarmCloud"
              )
        let bloomWarmA = isForegroundLayer ? nil : makeRenderTarget(
                format: .rgba16Float,
                width: 4,
                height: 4,
                usage: [.renderTarget, .shaderRead, .shaderWrite],
                label: "PrewarmBloomA"
              )
        let bloomWarmB = isForegroundLayer ? nil : makeRenderTarget(
                format: .rgba16Float,
                width: 4,
                height: 4,
                usage: [.renderTarget, .shaderRead, .shaderWrite],
                label: "PrewarmBloomB"
              )
        let compositeWarm = isForegroundLayer ? nil : makeRenderTarget(
                format: drawablePixelFormat,
                width: 4,
                height: 4,
                usage: [.renderTarget, .shaderRead],
                label: "PrewarmComposite"
              )

        guard (isForegroundLayer || (particleWarm != nil && cloudWarm != nil && bloomWarmA != nil && bloomWarmB != nil && compositeWarm != nil)),
              let cb = commandQueue.makeCommandBuffer() else {
            return
        }

        cb.label = "RendererPrewarm"

        let warmUniforms = FrameUniforms(
            time: 0,
            dt: 1.0 / 60.0,
            aspect: 1,
            noiseScale: params.noiseScale,
            idleStrength: params.idleStrength,
            upwardFlowSpeed: params.upwardFlowSpeed,
            bloomIntensity: params.bloomIntensity,
            dustOpacity: 1,
            maskCenterY: 0.05,
            maskRadiusX: 0.30,
            maskRadiusY: 0.30,
            maskFeather: 0.42,
            edgeGlowStrength: 0,
            tapTime: 0.25,
            burstEnvelope: 0.8
        )
        warmUniformBuffer.contents().copyMemory(
            from: [warmUniforms],
            byteCount: MemoryLayout<FrameUniforms>.stride
        )

        let warmCloudUniforms = CloudUniforms(
            time: 0,
            aspect: 1,
            opacity: 1,
            bloomIntensity: 1,
            splitProgress: 0.6
        )
        warmCloudUniformBuffer.contents().copyMemory(
            from: [warmCloudUniforms],
            byteCount: MemoryLayout<CloudUniforms>.stride
        )

        let warmPetals = PetalSystem.makePetals(at: .zero, seed: 1, count: petalCount)
        warmPetalBuffer.contents().copyMemory(
            from: warmPetals,
            byteCount: warmPetals.count * MemoryLayout<Petal>.stride
        )
        let warmPetalUniforms = PetalUniforms(
            elapsed: 0.3,
            dt: 1.0 / 60.0,
            aspect: 1,
            gravity: 4.4,
            dragPerFrame: 0.992,
            fallDragPerFrame: 0.985,
            flutterBoost: 4.5,
            totalCount: UInt32(petalCount),
            sizeMul: isForegroundLayer ? 1.35 : 1.0,
            flipX: isForegroundLayer ? -1.0 : 1.0
        )
        warmPetalUniformBuffer.contents().copyMemory(
            from: [warmPetalUniforms],
            byteCount: MemoryLayout<PetalUniforms>.stride
        )

        if !isForegroundLayer, let enc = cb.makeComputeCommandEncoder() {
            enc.label = "PrewarmSimulate"
            enc.setComputePipelineState(simulatePipeline)
            enc.setBuffer(warmParticleBuffer, offset: 0, index: 0)
            enc.setBuffer(warmUniformBuffer, offset: 0, index: 1)
            enc.setBuffer(particleCountBuffer, offset: 0, index: 2)
            let tew = simulatePipeline.threadExecutionWidth
            enc.dispatchThreads(
                MTLSize(width: params.particleCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
            )
            enc.endEncoding()
        }

        if !isForegroundLayer, let enc = cb.makeComputeCommandEncoder() {
            enc.label = "PrewarmRescale"
            var scale: Float = 1
            var count = UInt32(params.particleCount)
            enc.setComputePipelineState(rescalePipeline)
            enc.setBuffer(warmParticleBuffer, offset: 0, index: 0)
            enc.setBytes(&scale, length: MemoryLayout<Float>.size, index: 1)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
            let tew = rescalePipeline.threadExecutionWidth
            enc.dispatchThreads(
                MTLSize(width: params.particleCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
            )
            enc.endEncoding()
        }

        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "PrewarmPetals"
            enc.setComputePipelineState(simulatePetalsPipeline)
            enc.setBuffer(warmPetalBuffer, offset: 0, index: 0)
            enc.setBuffer(warmPetalUniformBuffer, offset: 0, index: 1)
            let tew = simulatePetalsPipeline.threadExecutionWidth
            enc.dispatchThreads(
                MTLSize(width: petalCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
            )
            enc.endEncoding()
        }

        if !isForegroundLayer,
           let particleWarm,
           let cloudWarm,
           let bloomWarmA,
           let bloomWarmB,
           let compositeWarm {
            encodeParticlePass(
                into: cb,
                target: particleWarm,
                pipeline: particleColorPipeline,
                label: "PrewarmParticleColor",
                loadAction: .clear,
                particleBuffer: warmParticleBuffer,
                uniformBuffer: warmUniformBuffer
            )
            encodeCloudPass(
                into: cb,
                target: cloudWarm,
                uniformBuffer: warmCloudUniformBuffer
            )
            encodeDownsample(into: cb, source: particleWarm, target: bloomWarmA)
            gaussianBlur.encode(commandBuffer: cb, sourceTexture: bloomWarmA, destinationTexture: bloomWarmB)
            encodeDownsample(into: cb, source: cloudWarm, target: bloomWarmA)
            gaussianBlur.encode(commandBuffer: cb, sourceTexture: bloomWarmA, destinationTexture: bloomWarmB)

            let compositeDesc = MTLRenderPassDescriptor()
            let compositeAttachment = compositeDesc.colorAttachments[0]!
            compositeAttachment.texture = compositeWarm
            compositeAttachment.loadAction = .clear
            compositeAttachment.storeAction = .store
            compositeAttachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let enc = cb.makeRenderCommandEncoder(descriptor: compositeDesc) {
                enc.label = "PrewarmComposite"
                enc.setRenderPipelineState(compositePipeline)
                enc.setFragmentTexture(particleWarm, index: 0)
                enc.setFragmentTexture(bloomWarmB, index: 1)
                enc.setFragmentTexture(cloudWarm, index: 2)
                enc.setFragmentTexture(bloomWarmB, index: 3)
                enc.setFragmentBuffer(warmUniformBuffer, offset: 0, index: 0)
                enc.setFragmentBuffer(warmCloudUniformBuffer, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                enc.setRenderPipelineState(petalRenderPipeline)
                enc.setVertexBuffer(warmPetalBuffer, offset: 0, index: 0)
                enc.setVertexBuffer(warmPetalUniformBuffer, offset: 0, index: 1)
                enc.setFragmentTexture(petalAtlasTexture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: petalCount)
                enc.endEncoding()
            }
        } else {
            let desc = MTLRenderPassDescriptor()
            let attachment = desc.colorAttachments[0]!
            attachment.texture = hostView?.currentDrawable?.texture
            attachment.loadAction = .dontCare
            attachment.storeAction = .dontCare
            if attachment.texture == nil,
               let scratch = makeRenderTarget(
                format: drawablePixelFormat,
                width: 4,
                height: 4,
                usage: [.renderTarget],
                label: "PrewarmForeground"
               ) {
                attachment.texture = scratch
            }
            if let enc = attachment.texture.flatMap({ _ in cb.makeRenderCommandEncoder(descriptor: desc) }) {
                enc.label = "PrewarmForegroundPetals"
                enc.setRenderPipelineState(petalRenderPipeline)
                enc.setVertexBuffer(warmPetalBuffer, offset: 0, index: 0)
                enc.setVertexBuffer(warmPetalUniformBuffer, offset: 0, index: 1)
                enc.setFragmentTexture(petalAtlasTexture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: petalCount)
                enc.endEncoding()
            }
        }

        cb.commit()
    }

    // MARK: - Resize

    private func rebuildOffscreenTextures(drawableSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))

        if isForegroundLayer {
            particleColorTexture = nil
            cloudColorTexture = nil
            bloomDownsampled = nil
            bloomBlurred = nil
            cloudBloomBlurred = nil
            return
        }

        particleColorTexture = makeRenderTarget(
            format: .bgra8Unorm, width: w, height: h,
            usage: [.renderTarget, .shaderRead], label: "ParticleColor")
        cloudColorTexture = makeRenderTarget(
            format: .rgba16Float, width: w, height: h,
            usage: [.renderTarget, .shaderRead], label: "CloudColor")

        let bw = max(1, w / 4)
        let bh = max(1, h / 4)
        // Half-float bloom intermediates: fp16 preserves the wide
        // low-frequency gaussian gradients without 8-bit banding when
        // the cloud lights up large areas of the screen.
        bloomDownsampled = makeRenderTarget(
            format: .rgba16Float, width: bw, height: bh,
            usage: [.renderTarget, .shaderRead, .shaderWrite], label: "BloomDownsampled")
        bloomBlurred = makeRenderTarget(
            format: .rgba16Float, width: bw, height: bh,
            usage: [.renderTarget, .shaderRead, .shaderWrite], label: "BloomBlurred")
        cloudBloomBlurred = makeRenderTarget(
            format: .rgba16Float, width: bw, height: bh,
            usage: [.renderTarget, .shaderRead, .shaderWrite], label: "CloudBloomBlurred")
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

    func registerTap(viewLocation: CGPoint, viewSize: CGSize,
                     playHaptics: Bool = true,
                     cloudEnabled: Bool = true,
                     petalsEnabled: Bool = true) {
        self.cloudEnabled = cloudEnabled
        self.petalsEnabled = petalsEnabled

        tapTime = 0

        if petalsEnabled {
            // Petals always spawn from CARD CENTER (screen center), regardless
            // of where the user tapped — they should look like they're erupting
            // from behind the card, not the tap point. Foreground layer XORs in
            // a fixed mask so its cohort visibly differs from the background's.
            let baseSeed = UInt64(CACurrentMediaTime() * 1_000_000)
            let seed = isForegroundLayer ? baseSeed ^ 0xCAFE_BABE_DEAD_BEEF : baseSeed
            let petals = PetalSystem.makePetals(at: .zero, seed: seed, count: petalCount)
            petalBuffer.contents().copyMemory(
                from: petals,
                byteCount: petals.count * MemoryLayout<Petal>.stride
            )
            petalStartTime = CACurrentMediaTime()
        } else {
            // Effect off: skip petal seeding so `petalActive` stays false; the
            // simulate kernel + petal render pass are gated on it and won't run.
            petalStartTime = nil
        }
        if revealedAt == nil { revealedAt = CACurrentMediaTime() }
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

    /// Restore the pre-tap state — dust comes back to full opacity, any
    /// in-flight petal burst stops, the reveal mask is cleared, and the
    /// renderer un-pauses so it can redraw the dust-only scene immediately.
    /// Used by the Skip button. Snaps instantly with no fade.
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
              let cb = commandQueue.makeCommandBuffer() else {
            return
        }
        let particleColor = particleColorTexture
        let cloudColor = cloudColorTexture
        let bloomA = bloomDownsampled
        let bloomB = bloomBlurred
        let cloudBloomB = cloudBloomBlurred
        let compositeParticleColor: MTLTexture?
        let compositeCloudColor: MTLTexture?
        let compositeBloomB: MTLTexture?
        let compositeCloudBloomB: MTLTexture?
        if !isForegroundLayer,
           (particleColor == nil || cloudColor == nil || bloomA == nil || bloomB == nil || cloudBloomB == nil) {
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
        // 4.0 pushes the burst expansion well past the visible viewport so
        // the visible viewport samples only the dense centre of the flower
        // mask — particles cover the full screen with no visible edge.
        let postTapRadius = max(aspect, 1.0) * 4.0

        let maskRadiusX: Float
        let maskRadiusY: Float
        let edgeGlowStrength: Float
        if hasTapped {
            let t = simd_clamp(tapTime / 1.0, 0, 1)
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

        let dustOpacity = currentDustOpacity(at: now)

        let bloomIntensity: Float = hasTapped
            ? params.bloomIntensity * (1.15 + 0.55 * (1.0 - Self.smoothstep(0.45, 1.2, tapTime)))
            : params.bloomIntensity * 1.05
        // Cloud arrives in sync with the SwiftUI card pop (≤ 0.55 s) and is
        // fully visible by 0.35 s — earlier and faster than the old 0.20–0.72
        // s ramp so the user sees the cloud forming as the card rises. When
        // `cloudEnabled` is false (e.g. negative P&L), opacity stays at 0 so
        // the cloud render + bloom passes are skipped entirely.
        let cloudOpacity: Float = (hasTapped && cloudEnabled)
            ? Self.smoothstep(0.05, 0.35, tapTime)
            : 0
        // Split ramps from 0 (centered cloud) to 1 (small top + small bottom,
        // clear middle). Targets completion at ~1.85 s so the split lands a
        // hair before the share button appears at 2.0 s — the cloud has
        // finished separating by the time the secondary UI arrives.
        let cloudSplitProgress: Float = (hasTapped && cloudEnabled)
            ? Self.smoothstep(0.10, 1.85, tapTime)
            : 0
        let cloudBloomIntensity: Float = 1.08 + 0.24 * sin(Float(now - startTime) * 0.62)

        let uniforms = FrameUniforms(
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
            burstEnvelope:  burstEnvelope
        )
        uniformBuffer.contents().copyMemory(
            from: [uniforms],
            byteCount: MemoryLayout<FrameUniforms>.stride
        )
        let cloudUniforms = CloudUniforms(
            time: Float(now - startTime),
            aspect: aspect,
            opacity: cloudOpacity,
            bloomIntensity: cloudBloomIntensity,
            splitProgress: cloudSplitProgress
        )
        cloudUniformBuffer.contents().copyMemory(
            from: [cloudUniforms],
            byteCount: MemoryLayout<CloudUniforms>.stride
        )

        // ----- Dust pipeline (background layer only) -----
        // Foreground renderer only produces the petal overlay above the card,
        // so we skip dust simulate / particle pass / bloom entirely there.
        if !isForegroundLayer {
            guard let particleColor, let cloudColor, let bloomA, let bloomB, let cloudBloomB else {
                return
            }
            compositeParticleColor = particleColor
            compositeCloudColor = cloudColor
            compositeBloomB = bloomB
            compositeCloudBloomB = cloudBloomB
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
            if cloudOpacity > 0.001 {
                encodeCloudPass(into: cb, target: cloudColor)
            }

            // ----- 3. Bloom: downsample → MPS Gaussian blur -----
            if dustOpacity > 0.01 {
                encodeDownsample(into: cb, source: particleColor, target: bloomA)
                gaussianBlur.encode(commandBuffer: cb, sourceTexture: bloomA, destinationTexture: bloomB)
            }
            if cloudOpacity > 0.001 {
                encodeDownsample(into: cb, source: cloudColor, target: bloomA)
                gaussianBlur.encode(commandBuffer: cb, sourceTexture: bloomA, destinationTexture: cloudBloomB)
            }
        } else {
            compositeParticleColor = nil
            compositeCloudColor = nil
            compositeBloomB = nil
            compositeCloudBloomB = nil
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
                guard let compositeParticleColor,
                      let compositeCloudColor,
                      let compositeBloomB,
                      let compositeCloudBloomB else {
                    enc.endEncoding()
                    return
                }
                enc.setRenderPipelineState(compositePipeline)
                enc.setFragmentTexture(compositeParticleColor, index: 0)
                enc.setFragmentTexture(compositeBloomB, index: 1)
                enc.setFragmentTexture(compositeCloudColor, index: 2)
                enc.setFragmentTexture(compositeCloudBloomB, index: 3)
                enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
                enc.setFragmentBuffer(cloudUniformBuffer, offset: 0, index: 1)
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

        if isForegroundLayer {
            if !petalActive {
                hostView?.isPaused = true
            }
        } else if dustOpacity <= 0.001 && !petalActive && cloudOpacity <= 0.001 {
            hostView?.isPaused = true
        }
    }

    private func currentDustOpacity(at now: CFTimeInterval) -> Float {
        if let rt = revealedAt {
            let since = Float(now - rt)
            let holdEnd: Float = 0.18
            let fadeDur: Float = 1.2
            let progress = max(0, since - holdEnd) / fadeDur
            return max(0, 1 - progress)
        }
        return 1
    }

    // MARK: - Pass helpers

    private func encodeParticlePass(into cb: MTLCommandBuffer,
                                    target: MTLTexture,
                                    pipeline: MTLRenderPipelineState,
                                    label: String,
                                    loadAction: MTLLoadAction,
                                    particleBuffer: MTLBuffer? = nil,
                                    uniformBuffer: MTLBuffer? = nil) {
        let desc = MTLRenderPassDescriptor()
        let att = desc.colorAttachments[0]!
        att.texture = target
        att.loadAction = loadAction
        att.storeAction = .store
        att.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.label = label
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(particleBuffer ?? self.particleBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffer ?? self.uniformBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(maskShapeTexture, index: 0)
        enc.setFragmentBuffer(uniformBuffer ?? self.uniformBuffer, offset: 0, index: 0)
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

    private func encodeCloudPass(into cb: MTLCommandBuffer,
                                 target: MTLTexture,
                                 uniformBuffer: MTLBuffer? = nil) {
        let desc = MTLRenderPassDescriptor()
        let att = desc.colorAttachments[0]!
        att.texture = target
        att.loadAction = .clear
        att.storeAction = .store
        att.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.label = "Cloud"
        enc.setRenderPipelineState(cloudPipeline)
        enc.setFragmentBuffer(uniformBuffer ?? cloudUniformBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - Errors

    enum RendererError: Error {
        case missingFunction(String)
        case artGenerationFailed
    }
}

enum MetalPipelinePrewarmer {
    private static var hasStarted = false

    static func prewarm() {
        guard !hasStarted else { return }
        hasStarted = true

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let particleBuffer = device.makeBuffer(
                length: SimulationParameters.recommended().particleCount * MemoryLayout<Particle>.stride,
                options: .storageModeShared
              ),
              let uniformBuffer = device.makeBuffer(
                length: MemoryLayout<FrameUniforms>.stride,
                options: .storageModeShared
              ),
              let cloudUniformBuffer = device.makeBuffer(
                length: MemoryLayout<CloudUniforms>.stride,
                options: .storageModeShared
              ),
              let petalBuffer = device.makeBuffer(
                length: PetalSystem.count * MemoryLayout<Petal>.stride,
                options: .storageModeShared
              ),
              let petalUniformBuffer = device.makeBuffer(
                length: MemoryLayout<PetalUniforms>.stride,
                options: .storageModeShared
              ),
              let particleTexture = makeRenderTarget(device: device, format: .bgra8Unorm, label: "SplashPrewarmParticle"),
              let cloudTexture = makeRenderTarget(device: device, format: .rgba16Float, label: "SplashPrewarmCloud"),
              let bloomTextureA = makeRenderTarget(device: device, format: .rgba16Float, label: "SplashPrewarmBloomA"),
              let bloomTextureB = makeRenderTarget(device: device, format: .rgba16Float, label: "SplashPrewarmBloomB"),
              let compositeTexture = makeRenderTarget(device: device, format: .bgra8Unorm, label: "SplashPrewarmComposite"),
              let cb = queue.makeCommandBuffer() else {
            return
        }

        let params = SimulationParameters.recommended()
        let particles = ParticleSystem.makeInitialParticles(
            count: params.particleCount,
            seed: 0xC0FFEE_BABE,
            aspect: 1,
            params: params
        )
        particleBuffer.contents().copyMemory(
            from: particles,
            byteCount: particles.count * MemoryLayout<Particle>.stride
        )
        let frameUniforms = FrameUniforms(
            time: 0,
            dt: 1.0 / 60.0,
            aspect: 1,
            noiseScale: params.noiseScale,
            idleStrength: params.idleStrength,
            upwardFlowSpeed: params.upwardFlowSpeed,
            bloomIntensity: params.bloomIntensity,
            dustOpacity: 1,
            maskCenterY: 0.05,
            maskRadiusX: 0.30,
            maskRadiusY: 0.30,
            maskFeather: 0.42,
            edgeGlowStrength: 0,
            tapTime: 0.25,
            burstEnvelope: 0.8
        )
        uniformBuffer.contents().copyMemory(
            from: [frameUniforms],
            byteCount: MemoryLayout<FrameUniforms>.stride
        )
        let cloudUniforms = CloudUniforms(
            time: 0,
            aspect: 1,
            opacity: 1,
            bloomIntensity: 1,
            splitProgress: 0.6
        )
        cloudUniformBuffer.contents().copyMemory(
            from: [cloudUniforms],
            byteCount: MemoryLayout<CloudUniforms>.stride
        )
        let petals = PetalSystem.makePetals(at: .zero, seed: 1)
        petalBuffer.contents().copyMemory(
            from: petals,
            byteCount: petals.count * MemoryLayout<Petal>.stride
        )
        let petalUniforms = PetalUniforms(
            elapsed: 0.3,
            dt: 1.0 / 60.0,
            aspect: 1,
            gravity: 4.4,
            dragPerFrame: 0.992,
            fallDragPerFrame: 0.985,
            flutterBoost: 4.5,
            totalCount: UInt32(PetalSystem.count),
            sizeMul: 1.0,
            flipX: 1.0
        )
        petalUniformBuffer.contents().copyMemory(
            from: [petalUniforms],
            byteCount: MemoryLayout<PetalUniforms>.stride
        )

        guard let simulate = try? computePipeline(device: device, library: library, name: "simulateParticles"),
              let rescale = try? computePipeline(device: device, library: library, name: "rescaleParticlesX"),
              let simulatePetals = try? computePipeline(device: device, library: library, name: "simulatePetals"),
              let cloudPipeline = try? renderPipeline(device: device, library: library, vertex: "fullscreenVertex", fragment: "cloudFragment", pixelFormat: .rgba16Float, label: "SplashPrewarmCloud"),
              let compositePipeline = try? renderPipeline(device: device, library: library, vertex: "fullscreenVertex", fragment: "compositeFragment", pixelFormat: .bgra8Unorm, label: "SplashPrewarmComposite"),
              let downsamplePipeline = try? renderPipeline(device: device, library: library, vertex: "fullscreenVertex", fragment: "downsampleFragment", pixelFormat: .rgba16Float, label: "SplashPrewarmDownsample"),
              let particlePipeline = try? additivePipeline(device: device, library: library, vertex: "particleVertex", fragment: "particleFragment", pixelFormat: .bgra8Unorm, label: "SplashPrewarmParticle"),
              let petalPipeline = try? petalPipeline(device: device, library: library, pixelFormat: .bgra8Unorm),
              let maskTexture = makeSolidMaskTexture(device: device),
              let petalAtlas = makeSolidPetalAtlas(device: device) else {
            return
        }

        let blur = MPSImageGaussianBlur(device: device, sigma: 1.5)
        blur.edgeMode = .clamp
        cb.label = "SplashMetalPrewarm"

        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(simulate)
            enc.setBuffer(particleBuffer, offset: 0, index: 0)
            enc.setBuffer(uniformBuffer, offset: 0, index: 1)
            var count = UInt32(params.particleCount)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
            let tew = simulate.threadExecutionWidth
            enc.dispatchThreads(
                MTLSize(width: params.particleCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
            )
            enc.endEncoding()
        }
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(rescale)
            enc.setBuffer(particleBuffer, offset: 0, index: 0)
            var scale: Float = 1
            var count = UInt32(params.particleCount)
            enc.setBytes(&scale, length: MemoryLayout<Float>.size, index: 1)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
            let tew = rescale.threadExecutionWidth
            enc.dispatchThreads(
                MTLSize(width: params.particleCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
            )
            enc.endEncoding()
        }
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(simulatePetals)
            enc.setBuffer(petalBuffer, offset: 0, index: 0)
            enc.setBuffer(petalUniformBuffer, offset: 0, index: 1)
            let tew = simulatePetals.threadExecutionWidth
            enc.dispatchThreads(
                MTLSize(width: PetalSystem.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tew, height: 1, depth: 1)
            )
            enc.endEncoding()
        }

        encodeParticlePass(
            commandBuffer: cb,
            target: particleTexture,
            pipeline: particlePipeline,
            particleBuffer: particleBuffer,
            uniformBuffer: uniformBuffer,
            maskTexture: maskTexture,
            vertexCount: params.particleCount
        )
        encodeCloudPass(
            commandBuffer: cb,
            target: cloudTexture,
            pipeline: cloudPipeline,
            uniformBuffer: cloudUniformBuffer
        )
        encodeDownsample(commandBuffer: cb, source: particleTexture, target: bloomTextureA, pipeline: downsamplePipeline)
        blur.encode(commandBuffer: cb, sourceTexture: bloomTextureA, destinationTexture: bloomTextureB)
        encodeDownsample(commandBuffer: cb, source: cloudTexture, target: bloomTextureA, pipeline: downsamplePipeline)
        blur.encode(commandBuffer: cb, sourceTexture: bloomTextureA, destinationTexture: bloomTextureB)
        encodeCompositePass(
            commandBuffer: cb,
            target: compositeTexture,
            pipeline: compositePipeline,
            particleTexture: particleTexture,
            bloomTexture: bloomTextureB,
            cloudTexture: cloudTexture,
            cloudBloomTexture: bloomTextureB,
            uniformBuffer: uniformBuffer,
            cloudUniformBuffer: cloudUniformBuffer
        )
        encodePetalPass(
            commandBuffer: cb,
            target: compositeTexture,
            pipeline: petalPipeline,
            petalBuffer: petalBuffer,
            petalUniformBuffer: petalUniformBuffer,
            petalAtlas: petalAtlas
        )

        cb.commit()
    }

    private static func computePipeline(device: MTLDevice, library: MTLLibrary, name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw ParticleRenderer.RendererError.missingFunction(name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    private static func renderPipeline(device: MTLDevice,
                                       library: MTLLibrary,
                                       vertex: String,
                                       fragment: String,
                                       pixelFormat: MTLPixelFormat,
                                       label: String) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private static func additivePipeline(device: MTLDevice,
                                         library: MTLLibrary,
                                         vertex: String,
                                         fragment: String,
                                         pixelFormat: MTLPixelFormat,
                                         label: String) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private static func petalPipeline(device: MTLDevice,
                                      library: MTLLibrary,
                                      pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "SplashPrewarmPetals"
        desc.vertexFunction = library.makeFunction(name: "petalVertex")
        desc.fragmentFunction = library.makeFunction(name: "petalFragment")
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeRenderTarget(device: MTLDevice,
                                         format: MTLPixelFormat,
                                         label: String) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: 4,
            height: 4,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .private
        let texture = device.makeTexture(descriptor: desc)
        texture?.label = label
        return texture
    }

    private static func makeSolidMaskTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 4,
            height: 4,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: desc)
        var bytes = [UInt8](repeating: 255, count: 16)
        texture?.replace(
            region: MTLRegionMake2D(0, 0, 4, 4),
            mipmapLevel: 0,
            withBytes: &bytes,
            bytesPerRow: 4
        )
        return texture
    }

    private static func makeSolidPetalAtlas(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 12,
            height: 4,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: desc)
        var bytes = [UInt8](repeating: 255, count: 12 * 4 * 4)
        texture?.replace(
            region: MTLRegionMake2D(0, 0, 12, 4),
            mipmapLevel: 0,
            withBytes: &bytes,
            bytesPerRow: 12 * 4
        )
        return texture
    }

    private static func encodeParticlePass(commandBuffer cb: MTLCommandBuffer,
                                           target: MTLTexture,
                                           pipeline: MTLRenderPipelineState,
                                           particleBuffer: MTLBuffer,
                                           uniformBuffer: MTLBuffer,
                                           maskTexture: MTLTexture,
                                           vertexCount: Int) {
        let desc = MTLRenderPassDescriptor()
        let attachment = desc.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(maskTexture, index: 0)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertexCount)
        enc.endEncoding()
    }

    private static func encodeCloudPass(commandBuffer cb: MTLCommandBuffer,
                                        target: MTLTexture,
                                        pipeline: MTLRenderPipelineState,
                                        uniformBuffer: MTLBuffer) {
        let desc = MTLRenderPassDescriptor()
        let attachment = desc.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private static func encodeDownsample(commandBuffer cb: MTLCommandBuffer,
                                         source: MTLTexture,
                                         target: MTLTexture,
                                         pipeline: MTLRenderPipelineState) {
        let desc = MTLRenderPassDescriptor()
        let attachment = desc.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .dontCare
        attachment.storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private static func encodeCompositePass(commandBuffer cb: MTLCommandBuffer,
                                            target: MTLTexture,
                                            pipeline: MTLRenderPipelineState,
                                            particleTexture: MTLTexture,
                                            bloomTexture: MTLTexture,
                                            cloudTexture: MTLTexture,
                                            cloudBloomTexture: MTLTexture,
                                            uniformBuffer: MTLBuffer,
                                            cloudUniformBuffer: MTLBuffer) {
        let desc = MTLRenderPassDescriptor()
        let attachment = desc.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(particleTexture, index: 0)
        enc.setFragmentTexture(bloomTexture, index: 1)
        enc.setFragmentTexture(cloudTexture, index: 2)
        enc.setFragmentTexture(cloudBloomTexture, index: 3)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        enc.setFragmentBuffer(cloudUniformBuffer, offset: 0, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private static func encodePetalPass(commandBuffer cb: MTLCommandBuffer,
                                        target: MTLTexture,
                                        pipeline: MTLRenderPipelineState,
                                        petalBuffer: MTLBuffer,
                                        petalUniformBuffer: MTLBuffer,
                                        petalAtlas: MTLTexture) {
        let desc = MTLRenderPassDescriptor()
        let attachment = desc.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .load
        attachment.storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(petalBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(petalUniformBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(petalAtlas, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: PetalSystem.count)
        enc.endEncoding()
    }
}
