# Particle Reveal — Execution Plan

Companion to [`particle-reveal-plan.md`](./particle-reveal-plan.md). That doc is the design; this one is how to actually land it phase by phase. Generated 2026-04-28 with Codex review.

# Phase 1. MTKView Shell

## Goal / definition of done
A SwiftUI screen replaces the default scaffold with a black-backed Metal view that renders continuously at the display refresh rate on iOS, macOS, and visionOS. No particles yet. The app builds and runs on all three platforms without conditional-compilation breakage.

## Files to create or edit
1. `s-reveal/ContentView.swift`
   - Replace the default globe UI with a thin host view, likely:
     - `struct ContentView: View`
     - `var body: some View`
   - Responsibility:
     - Embed `RevealView()`
     - Apply full-bleed layout with predictable sizing
     - Keep app-level UI minimal so Metal owns the canvas

2. `s-reveal/Reveal/RevealView.swift`
   - Create the SwiftUI bridge layer.
   - Recommended shape:
     - `struct RevealView: View`
     - Internal platform bridge:
       - `struct PlatformMetalViewRepresentable: UIViewRepresentable` on iOS and visionOS
       - `struct PlatformMetalViewRepresentable: NSViewRepresentable` on macOS
   - Key functions:
     - `makeUIView(context:) -> MTKView` / `updateUIView(_:context:)`
     - `makeNSView(context:) -> MTKView` / `updateNSView(_:context:)`
     - `makeCoordinator() -> Coordinator`
   - `Coordinator` responsibilities:
     - Own a `ParticleRenderer`
     - Bind the `MTKView.delegate`
     - Provide a stable lifetime boundary so the renderer is not recreated every SwiftUI update
   - Non-obvious detail:
     - visionOS can use `UIViewRepresentable`; there is no separate "VisionViewRepresentable".

3. `s-reveal/Reveal/ParticleRenderer.swift`
   - Create the renderer shell only.
   - Recommended API:
     - `final class ParticleRenderer: NSObject, MTKViewDelegate`
     - `init?(mtkView: MTKView)`
     - `func draw(in view: MTKView)`
     - `func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)`
   - Responsibilities in this phase:
     - Create `MTLDevice`, `MTLCommandQueue`
     - Configure `MTKView`
     - Issue a simple clear pass to black
     - Track drawable size, backing scale, and frame timing scaffolding

## Cross-platform gotchas
- `UIViewRepresentable` vs `NSViewRepresentable`:
  - iOS and visionOS: `UIViewRepresentable`
  - macOS: `NSViewRepresentable`
  - Keep platform conditionals isolated to `RevealView.swift`, not scattered across renderer code.
- Refresh loop:
  - `MTKView.isPaused = false`
  - `enableSetNeedsDisplay = false`
  - `preferredFramesPerSecond = 60` on iOS/visionOS
  - macOS may ignore `preferredFramesPerSecond`; `MTKView` drives from display timing differently.
- Pixel scaling:
  - Use `mtkView.drawableSize = bounds.size * scaleFactor`.
  - iOS/visionOS: derive from `contentScaleFactor`
  - macOS: derive from `window?.backingScaleFactor` or `view.layer?.contentsScale`
- Pixel format:
  - Set `colorPixelFormat` once up front and keep it stable. Start with `.bgra8Unorm`.
  - Future pipelines must match this exactly.
- visionOS:
  - Treat it like iPad-class 2D SwiftUI in a window for v1.
  - Avoid UIKit-only APIs in shared code except under `#if os(iOS)`.
- Shader compilation:
  - No shaders yet, but choose whether to use `device.makeDefaultLibrary()` from the start; that avoids later refactors.

## What to verify before moving to the next phase
- App launches to a full-bleed black canvas on iOS, macOS, and visionOS.
- No SwiftUI layout jitter or zero-size drawable.
- `draw(in:)` is called continuously.
- Resizing the macOS window updates drawable size cleanly.
- No Metal validation errors in the console.

## Risks specific to this phase
- Risk: SwiftUI repeatedly recreates the renderer.
  - De-risk: keep renderer in the representable coordinator and log init/deinit once.
- Risk: incorrect drawable sizing on macOS Retina.
  - De-risk: print logical size vs drawable size once on resize.
- Risk: visionOS build breaks because of iOS-only imports.
  - De-risk: keep haptics and UIKit gesture code out of this phase entirely.

---

# Phase 2. Static Particle Field

## Goal / definition of done
A fixed cloud of visible particles renders over black, centered and contained within the intended ellipse. No motion. The field density, size distribution, and additive appearance roughly match the reference's initial resting state.

## Files to create or edit
1. `s-reveal/Reveal/ParticleSystem.swift`
   - Create particle data definitions and initialization helpers.
   - Recommended API:
     - `struct Particle`
     - `enum ParticleSystem`
     - `static func makeInitialParticles(count: Int, seed: UInt64, aspect: Float) -> [Particle]`
   - Responsibilities:
     - Seed particles inside a soft ellipse
     - Randomize size, hue offset, life
     - Keep initialization deterministic for tests

2. `s-reveal/Reveal/ParticleRenderer.swift`
   - Expand renderer to:
     - Create particle buffer
     - Create render pipeline for particle sprites
     - Upload initial particles
   - Add likely helpers:
     - `private func buildPipelines() throws`
     - `private func buildBuffers()`
     - `private func drawParticles(...)`
   - Responsibilities:
     - Set particle count default
     - Pass viewport and color uniforms
     - Render point/quad sprites into the drawable

3. `s-reveal/Reveal/Shaders/Common.metal`
   - Shared structs:
     - `struct Particle`
     - `struct FrameUniforms`
     - Vertex outputs and shared constants
   - Keep memory layout explicitly aligned with Swift.

4. `s-reveal/Reveal/Shaders/Particles.metal`
   - Add render-only shader pair for now:
     - `vertex ParticleVertexOut particleVertex(...)`
     - `fragment half4 particleFragment(...)`
   - Responsibilities:
     - Convert particle positions into clip space
     - Generate soft circular sprites
     - Apply initial blue/indigo palette and additive-friendly alpha falloff

## Cross-platform gotchas
- File inclusion / shader library:
  - Ensure `.metal` files are added under `s-reveal/` on disk so the synchronized root group picks them up.
  - If Xcode fails to compile them automatically, that is a project sync issue, not a code issue.
- Sprite strategy:
  - `point_size` can behave differently across GPUs; a quad-per-particle path is more predictable.
  - If starting with point sprites, verify macOS and visionOS produce the same visual size.
- Buffer storage:
  - Initial phase can use `MTLStorageMode.shared` everywhere to reduce moving parts.
  - Defer discrete-GPU optimization to phase 7.
- Color precision:
  - Fragment outputs should use `half` unless debugging reveals precision artifacts.
- Blend state:
  - Additive blending configuration must match intent:
    - color: `.add`, src `.one`, dst `.one`
    - alpha: either additive too or ignored consistently
  - Inconsistent alpha blending will complicate later bloom.

## What to verify before moving to the next phase
- Static particles are visible on all platforms.
- Distribution looks elliptical, not rectangular or clipped.
- Particle sizes look stable across Retina/non-Retina displays.
- No obvious overdraw blowout from accidental full-screen quads.
- Metal shader library builds on all targets.

## Risks specific to this phase
- Risk: Swift/Metal struct packing mismatch.
  - De-risk: keep fields 16-byte aligned and assert `MemoryLayout<Particle>.stride` against expectation.
- Risk: point sprites render inconsistently across platforms.
  - De-risk: decide early whether to switch to instanced quads if visual parity is off.
- Risk: initial field looks too sparse or too uniform.
  - De-risk: expose particle count, size range, and ellipse radii as constants before adding runtime tuning.

---

# Phase 3. Compute Simulation: Idle Drift

## Goal / definition of done
The cloud drifts continuously with stable, low-amplitude curl-noise motion and damping. It resembles the reference clip's idle first second: alive, contained, and not exploding or collapsing.

## Files to create or edit
1. `s-reveal/Reveal/ParticleRenderer.swift`
   - Add compute pipeline creation and frame stepping.
   - New likely members:
     - `private var simulatePipeline: MTLComputePipelineState`
     - `private var frameUniformBuffer: MTLBuffer`
     - `private var lastFrameTimestamp: CFTimeInterval?`
   - New functions:
     - `private func updateFrameTiming(currentTime: CFTimeInterval)`
     - `private func encodeSimulation(into commandBuffer: MTLCommandBuffer)`
   - Responsibilities:
     - Compute `dt` with clamping
     - Encode simulation before render
     - Keep one command buffer per frame at this stage

2. `s-reveal/Reveal/Shaders/Common.metal`
   - Add `FrameUniforms` fields needed for simulation:
     - `time`, `dt`, `noiseScale`, `idleStrength`, `damping`, `viewportAspect`, containment params
   - Add curl-noise helpers if shared.

3. `s-reveal/Reveal/Shaders/Particles.metal`
   - Add compute kernel:
     - `kernel void simulate(...)`
   - Responsibilities:
     - Sample curl noise
     - Apply idle acceleration
     - Integrate velocity and position
     - Apply damping
     - Enforce containment well or soft recentering
   - Non-obvious behavior:
     - Prefer a soft force toward the ellipse center over hard clipping to avoid edge chatter.
     - Clamp `dt` after app backgrounding or window stalls.

4. `s-reveal/Reveal/ParticleSystem.swift`
   - Possibly add constants/types for parameter defaults:
     - `struct SimulationParameters`
   - Responsibility:
     - Keep initial tuning in one place so CPU and tests share it.

## Cross-platform gotchas
- Timing source:
  - iOS/visionOS: `MTKView` render loop timing is sufficient; avoid adding `CADisplayLink` unless you need external pacing.
  - macOS: same renderer can use MTKView delegate timing; `CVDisplayLink` is only for deeper profiling or custom pacing, not required for core rendering.
- Compute threadgroup sizing:
  - Use `pipeline.threadExecutionWidth` and a rounded-up grid size.
  - Avoid hardcoding 256 without checking device capabilities.
- Shared memory coherence:
  - `storageModeShared` buffer updates from GPU are fine on Apple Silicon.
  - Do not assume the same cost profile on discrete macOS GPUs; note it for phase 7.
- Floating-point behavior:
  - `MTL_FAST_MATH = YES` is already on; expect minor differences in noise shape across platforms.
  - Keep tuning visual, not numerically exact.
- Backgrounding / suspension:
  - iOS/visionOS may deliver a large `dt` after app resume.
  - Clamp to something like `1/30` or `1/20`.

## What to verify before moving to the next phase
- Motion is smooth and continuous at rest.
- Particles remain contained; no steady drift off-screen.
- No visible single-frame jumps after pause/resume or window resize.
- Frame time remains well under budget with idle simulation only.
- Metal validation shows no read/write hazards on the particle buffer.

## Risks specific to this phase
- Risk: curl noise is too expensive or too chaotic.
  - De-risk: start with one octave and cheap containment; add the second octave only if budget allows.
- Risk: particles accumulate velocity and escape.
  - De-risk: add a center bias and speed clamp before chasing visual fidelity.
- Risk: dt instability creates visible jitter.
  - De-risk: clamp dt and consider fixed-step simulation later only if needed.

---

# Phase 4. Tap Impulse

## Goal / definition of done
A tap or click injects a burst centered at the interaction point. Nearby particles accelerate radially, the impulse feels immediate, and the tap location maps correctly to the Metal coordinate space on all platforms.

## Files to create or edit
1. `s-reveal/Reveal/RevealView.swift`
   - Add input forwarding.
   - Recommended shape:
     - `final class Coordinator`
       - `func handleTap(at viewPoint: CGPoint, in size: CGSize)`
   - Responsibilities:
     - Receive platform gesture coordinates
     - Forward them to the renderer in drawable-space or normalized-space
   - Gesture wiring:
     - iOS/visionOS: `UITapGestureRecognizer` or `UIPanGestureRecognizer` if drag-to-scrub is desired
     - macOS: `NSClickGestureRecognizer`

2. `s-reveal/Reveal/ParticleRenderer.swift`
   - Add tap state and uniform update path.
   - New likely API:
     - `func registerTap(locationInView: CGPoint, viewSize: CGSize, scaleFactor: CGFloat)`
   - Responsibilities:
     - Convert from SwiftUI/view coordinates to shader coordinates
     - Store recent tap time and position
     - Fade impulse over a short duration
   - Non-obvious detail:
     - Normalize with drawable size, not logical points, if the shader expects pixel-based falloff.
     - Invert Y once, in one place, and test it.

3. `s-reveal/Reveal/Shaders/Common.metal`
   - Extend uniforms with:
     - `tapPos`
     - `tapTime`
     - `burstStrength`
     - `burstSharpness`
     - `tapActive` or derived lifetime

4. `s-reveal/Reveal/Shaders/Particles.metal`
   - Update `simulate` to include radial burst impulse.
   - Responsibilities:
     - Compute distance/falloff from tap
     - Apply outward impulse scaled by recency
     - Keep idle motion active underneath

## Cross-platform gotchas
- Gesture recognizers:
  - iOS/visionOS: `UITapGestureRecognizer` coordinates come in UIKit view space with origin top-left.
  - macOS: `NSClickGestureRecognizer` also reports view-space coordinates, but flipped coordinate systems can differ if the view is layer-backed.
  - Use `MTKView` local coordinates directly and centralize conversion in the renderer.
- Haptics:
  - `UIImpactFeedbackGenerator` is iOS-only.
  - Do not compile it for macOS or visionOS unless explicitly verified supported; safest default is iOS only.
- Drag vs tap:
  - If you use `DragGesture` in SwiftUI instead of native recognizers, confirm it does not fight `MTKView` event delivery on macOS.
  - Native gesture recognizers on the underlying `MTKView` are usually simpler.
- Coordinate units:
  - Decide whether tap position in uniforms is clip-space, UV-space, or pixel-space.
  - Pixel-space is easiest if burst radius should visually scale with drawable resolution.
- visionOS interaction:
  - Windowed tap gestures should work via UIKit pathway, but do not assume spatial gestures.

## What to verify before moving to the next phase
- Tapping each corner affects the correct on-screen region.
- The burst happens on the same frame or next frame after input, without noticeable latency.
- Repeated taps do not crash or leave stale state.
- iOS tap fires haptic once per tap if enabled.
- macOS click behavior matches iOS coordinate mapping.

## Risks specific to this phase
- Risk: coordinate conversion bugs cause mirrored or offset bursts.
  - De-risk: temporarily render a debug flare at the tap point before tuning physics.
- Risk: SwiftUI gestures intercept events before MTKView sees them.
  - De-risk: use platform gesture recognizers attached directly to the MTKView.
- Risk: burst tuning looks correct on one device class but not another.
  - De-risk: express falloff in normalized screen terms or scale by min(drawable width, height).

---

# Phase 5. Reveal Mask + Composite

## Goal / definition of done
The hidden image is now revealed where particles pass. The reveal persists across frames. The app visually matches the core effect: dust on top, image underneath, clearing at the tap-driven sweep.

## Files to create or edit
1. `s-reveal/Reveal/ParticleRenderer.swift`
   - Add render targets and multi-pass frame encoding.
   - New likely members:
     - `private var revealMaskA: MTLTexture`
     - `private var revealMaskB: MTLTexture` if true ping-pong is used
     - `private var particleColorTexture: MTLTexture` if particles are rendered offscreen before composite
     - `private var artTexture: MTLTexture`
     - `private var compositePipeline: MTLRenderPipelineState`
   - New functions:
     - `private func rebuildTextures(for drawableSize: CGSize)`
     - `private func encodeMaskPass(into:)`
     - `private func encodeCompositePass(into:drawable:)`
     - `private func loadArtTexture() throws`
   - Responsibilities:
     - Allocate half-resolution `r8Unorm` reveal mask
     - Persist mask contents across frames
     - Render particles into mask with additive accumulation
     - Composite image + dust + mask into final drawable

2. `s-reveal/Reveal/Shaders/Particles.metal`
   - Add/adjust a pass specialized for mask writing.
   - Responsibilities:
     - Render soft particles into single-channel mask space
     - Use additive accumulation
     - Ensure write rate is tuned so reveal is neither instant nor imperceptible

3. `s-reveal/Reveal/Shaders/Composite.metal`
   - Create fullscreen composite shaders:
     - `vertex FullscreenVertexOut fullscreenVertex(uint vertexID [[vertex_id]])`
     - `fragment half4 composite(...)`
   - Responsibilities:
     - Sample art texture, particle color texture, and reveal mask
     - Apply reveal logic from the doc
     - Handle UV mapping and mask upsampling cleanly

4. `s-reveal/Reveal/Shaders/Common.metal`
   - Add composite uniforms if needed:
     - texel size
     - reveal softness
     - tone controls reserved for phase 6

5. `s-reveal/ContentView.swift`
   - If needed, pass a bundled asset name or configuration into `RevealView`.

6. Asset catalog / bundled image asset
   - Add one bundled reveal image for the demo.
   - Responsibility:
     - Fixed art source for v1 so rendering path is stable.

## Cross-platform gotchas
- Reveal mask persistence:
  - The doc mentions ping-pong because persistent screen-space accumulation often requires reading prior frame contents.
  - Decide whether you truly need A/B textures:
    - If only additive writes happen and no same-pass sampling occurs, a single persistent mask texture can work.
    - If adding regrowth, decay, or read-modify-write behavior, use ping-pong.
- Texture formats:
  - Reveal mask: `r8Unorm` is compact and appropriate.
  - Confirm renderability and sampling support on all target platforms.
- Drawable size / offscreen size:
  - Mask at half-resolution must be derived from drawable size and recreated on resize.
  - Composite shader must sample with the correct UVs; avoid logical-point math here.
- Loading the art texture:
  - Prefer `MTKTextureLoader` from bundled assets.
  - Verify asset orientation on iOS vs macOS if using image files outside asset catalogs.
- Blend and load actions:
  - The reveal mask pass must preserve prior contents.
  - Use `loadAction = .load` after explicit initialization.
  - First-use initialization should clear once, not every frame.
- Shader compilation differences:
  - Keep sampler declarations explicit.
  - Avoid relying on implicit swizzles or unsupported texture access assumptions across GPU families.

## What to verify before moving to the next phase
- Reveal persists after particles move away.
- A tap-driven sweep reveals the image in the expected region.
- No mask reset occurs on subsequent frames.
- Resize/orientation changes recreate textures correctly without crashes.
- Offscreen textures match drawable size changes and do not stretch incorrectly.
- Visually, this is the first phase that reads as "the effect."

## Risks specific to this phase
- Risk: mask semantics invert accidentally.
  - De-risk: use a temporary debug composite that displays the mask as grayscale fullscreen.
- Risk: half-resolution mask causes obvious pixel stair-stepping.
  - De-risk: start at half-res but keep a toggle for full-res during tuning.
- Risk: too many passes create early perf regressions.
  - De-risk: implement the simplest pass graph first, then add separation only if blending/composition requires it.
- Risk: reading and writing the same texture incorrectly.
  - De-risk: use explicit ping-pong if any sampling-from-previous-mask enters the frame graph.

---

# Phase 6. Bloom + Tone Curve

## Goal / definition of done
Particles and burst highlights have the soft haze seen in the reference. Bright regions bloom without washing out the art. The overall contrast and tone feel intentional rather than raw additive output.

## Files to create or edit
1. `s-reveal/Reveal/ParticleRenderer.swift`
   - Add post-processing resources and pass orchestration.
   - New likely members:
     - bloom intermediate textures
     - `MPSImageGaussianBlur` instance, if using MPS
     - composite/tone parameters
   - New functions:
     - `private func encodeBloom(into:)`
     - `private func encodeFinalComposite(into:drawable:)`
   - Responsibilities:
     - Downsample bright particle output if desired
     - Blur bloom texture
     - Blend bloom back into final composite
     - Apply a lightweight tone curve or contrast shoulder

2. `s-reveal/Reveal/Shaders/Composite.metal`
   - Extend composite fragment or add a final pass fragment.
   - Responsibilities:
     - Mix base image, dust, mask, and blurred bloom
     - Apply tone shaping, e.g. soft shoulder or gamma-adjusted blend
   - Keep logic simple enough to tune visually.

3. `s-reveal/Reveal/Shaders/Common.metal`
   - Add uniforms for:
     - bloom intensity
     - threshold if needed
     - tone curve parameters

## Cross-platform gotchas
- MPS availability:
  - `MetalPerformanceShaders` is available on iOS, macOS, and visionOS, but availability annotations must match deployment targets.
  - If MPS complicates visionOS builds, fallback to a simple separable blur shader rather than blocking the whole feature.
- Texture usage flags:
  - Bloom textures need both shader-read and shader-write or render-target usage depending on implementation.
- Color space:
  - If the final output looks different across platforms, verify whether the drawable/view is effectively in sRGB and whether textures are loaded as sRGB.
  - Start conservative: keep the pipeline consistent before chasing color-management perfection.
- Performance:
  - Full-resolution blur is expensive. Downsample first.
- Additive bloom on macOS:
  - Overbright additive blending can feel harsher on larger displays; make bloom intensity configurable.

## What to verify before moving to the next phase
- Bloom adds softness without obscuring the revealed image.
- There is no obvious halo clipping at screen edges.
- Final output is visually closer to the reference than phase 5, not simply brighter.
- Performance remains acceptable after adding blur.
- MPS or fallback blur works on all three platforms.

## Risks specific to this phase
- Risk: bloom becomes the most expensive pass too early.
  - De-risk: blur a quarter- or half-res texture and keep sigma modest.
- Risk: tone curve hides mask/composite bugs.
  - De-risk: keep a debug flag to disable bloom and tone independently.
- Risk: MPS pipeline integration causes build/runtime issues on one platform.
  - De-risk: isolate bloom behind one renderer helper with a shader-based fallback path.

---

# Phase 7. Performance Pass

## Goal / definition of done
The full effect runs within budget on target hardware, especially iPhone 13 base. The renderer has explicit knobs for degradation under pressure, and the frame graph has been profiled rather than guessed.

## Files to create or edit
1. `s-reveal/Reveal/ParticleRenderer.swift`
   - Add instrumentation and quality controls.
   - New likely members:
     - `struct QualitySettings`
     - counters/timestamps for CPU frame pacing
     - optional signpost hooks
   - New responsibilities:
     - Select particle count per device class
     - Toggle mask resolution fraction
     - Choose buffer storage strategy
     - Expose debug/perf overlays or logging hooks

2. `s-reveal/Reveal/ParticleSystem.swift`
   - Add presets:
     - `static let phoneBaseline`
     - `static let highEnd`
   - Responsibility:
     - Keep device-tier defaults centralized.

3. `s-reveal/Reveal/Shaders/*.metal`
   - Trim unnecessary work discovered in profiling.
   - Typical examples:
     - reduce noise octaves
     - cheaper falloff
     - remove unused uniforms or branches

4. Optional small diagnostics file if needed
   - Example:
     - `Reveal/RendererDiagnostics.swift`
   - Responsibility:
     - Signpost names, counters, build-flagged debug utilities
   - Only add if `ParticleRenderer.swift` is becoming overloaded.

## Cross-platform gotchas
- Buffer storage mode:
  - Apple Silicon iOS/macOS/visionOS: `MTLStorageMode.shared` is often fine for CPU-seeded, GPU-updated particle buffers.
  - Discrete macOS GPUs: prefer `.private` for simulation/render buffers and stage uploads through a shared staging buffer plus blit.
  - Do not pay the complexity tax until profiling shows a real need on discrete Macs.
- Display refresh expectations:
  - iPhone Pro/vision devices may run above 60 Hz; do not accidentally lock effect tuning to 60 Hz assumptions.
  - Motion must be time-based, not frame-based.
- Drawable pacing:
  - macOS may not behave like iOS around vsync and window occlusion; profile active visible cases only.
- Shader specialization:
  - Different GPU families may reorder bottlenecks; a kernel that is ALU-bound on iPhone can become bandwidth-bound on Mac.

## What to verify before moving to the next phase
- GPU frame time meets or approaches target on iPhone 13 base.
- Quality knobs have measurable effect:
  - lower particle count
  - lower mask resolution
  - lower bloom resolution
- No platform regresses below an acceptable baseline while optimizing for one device.
- Discrete macOS GPU path, if implemented, is correct and not just faster-looking.

## Risks specific to this phase
- Risk: optimization begins before enough measurement.
  - De-risk: capture one representative frame and identify the top pass first.
- Risk: premature discrete-GPU branching increases maintenance cost.
  - De-risk: keep the unified-memory path as default and add discrete optimization only behind a narrow abstraction.
- Risk: visual tuning gets lost while chasing numbers.
  - De-risk: keep short reference videos/screenshots from phase 6 for before/after comparisons.

---

# Cross-cutting decisions

## Decision ledger
1. Reveal art source
   - Decision: bundled asset in the asset catalog.
   - Recommended default: one fixed portrait asset sized for the reference aspect.
   - Reason: removes networking, caching, and async image decode from the renderer bring-up.

2. One-shot vs replayable reveal
   - Decision: one-shot for v1.
   - Recommended default: persistent reveal mask with no regrowth.
   - Reason: matches the reference more closely and avoids extra mask decay logic during core effect development.

3. Particle primitive shape
   - Decision: start with point sprites only if cross-platform parity is acceptable; otherwise switch immediately to instanced quads.
   - Recommended default: point sprites for phase 2, with an explicit fallback decision checkpoint before phase 5.
   - Reason: fastest path to pixels, but not worth carrying if macOS/visionOS sizing differs.

4. Particle buffer storage mode
   - Decision: shared everywhere first; optimize later for discrete macOS.
   - Recommended default: `MTLStorageMode.shared` through phase 6.
   - Reason: simplest, least error-prone, ideal for Apple Silicon, and adequate until profiling proves otherwise.

5. Reveal mask topology
   - Decision: single persistent mask texture unless a read-modify-write step is introduced; otherwise ping-pong.
   - Recommended default: implement as ping-pong-capable abstraction even if phase 5 uses only one side.
   - Reason: preserves the architecture from the doc and keeps replay/regrowth options cheap later.

6. Coordinate convention
   - Decision: particles in normalized simulation space, taps converted once into the same space, mask/composite in UV/pixel space as needed.
   - Recommended default: store tap in normalized view UV plus precomputed pixel radius terms in uniforms.
   - Reason: easiest to test and scale across devices.

7. Haptics
   - Decision: iOS only.
   - Recommended default: `UIImpactFeedbackGenerator(style: .medium)` on tap; skip the 80% progress tick until reveal coverage math exists.
   - Reason: keeps platform conditionals narrow and avoids premature feature work.

8. visionOS support level
   - Decision: 2D windowed support only for v1.
   - Recommended default: same representable path as iOS, no `RealityView`.
   - Reason: keeps the implementation aligned with the existing multiplatform target and avoids a parallel 3D architecture.

9. Performance tiers
   - Decision: define at least two presets before coding phase 5.
   - Recommended default:
     - baseline mobile: 12k particles, half-res mask, half-res bloom
     - high-end: 24k particles, half-res mask, quarter/half-res bloom depending capture
   - Reason: avoids hardcoding a single quality level that later becomes painful to unwind.

10. Shader library organization
   - Decision: keep shared structs and helpers in `Common.metal`, simulation/render in `Particles.metal`, fullscreen in `Composite.metal`.
   - Recommended default: no extra shader files in v1.
   - Reason: matches the doc and keeps build/debug manageable.

---

# Test strategy

## `s-revealTests` (Swift Testing)
Focus on deterministic CPU-side logic, not GPU pixels.

1. Particle initialization tests
   - `makeInitialParticles(count:seed:aspect:)` returns the expected count.
   - Seeded output is deterministic for a fixed seed.
   - Positions fall within the expected ellipse bounds.
   - Size/hue/life values remain within configured ranges.

2. Coordinate conversion tests
   - Tap in view-space converts correctly to renderer/shader-space.
   - Corners and center map exactly as expected.
   - Y-axis inversion is covered explicitly.
   - Retina scaling path is tested with logical size vs drawable size.

3. Uniform packing / parameter derivation tests
   - Burst radius or viewport-derived constants are computed correctly from drawable size.
   - `dt` clamping logic behaves correctly after long frame gaps.
   - Quality preset selection returns expected values for mocked device classes if that logic is abstracted.

4. Reveal coverage math tests
   - If you compute "percent revealed" via CPU read-back or analytic bookkeeping later, test:
     - all-covered mask returns 0%
     - all-revealed mask returns 100%
     - known byte patterns produce expected percentages
   - Keep this math separate from actual Metal texture access so it is unit-testable.

5. Cheap state-machine tests
   - Tap state expires after the intended interval.
   - One-shot reveal mode does not regrow.
   - Replay/reset hooks, if added later, clear the right CPU-side state.

## `s-revealUITests` (XCTest)
Use UI tests only for app-level behavior that can be observed without validating GPU output numerically.

1. Launch/smoke tests
   - App launches into the reveal screen on all supported destinations available in CI/local automation.
   - Window/canvas exists and is hittable.

2. Basic interaction tests
   - A tap on the canvas does not crash.
   - Multiple taps in sequence do not freeze the app.
   - macOS window resize during rendering does not crash.

3. Optional screenshot sanity tests
   - If stable enough, capture a screenshot after launch and after a tap to detect catastrophic blank-frame regressions.
   - Do not attempt pixel-perfect assertions on particle output.

## Not worth testing directly
- Exact particle positions after GPU simulation.
- Exact rendered bloom or composite output.
- Cross-GPU visual parity at the pixel level.

---

# Performance budget & instrumentation plan

## Budgets
1. Primary target
   - `<= 4.0 ms` GPU frame time on iPhone 13 base for the full effect.
   - This leaves room for display pacing and OS overhead at 60 fps.

2. Frame-rate targets
   - 60 fps sustained on iPhone 13 base.
   - 120 fps opportunistic on ProMotion hardware if the effect naturally fits; do not promise it until measured.
   - macOS and visionOS should feel smooth, but iPhone 13 base is the hard gate.

3. Pass-level starting budget
   - Simulation compute: `<= 1.0 ms`
   - Mask pass: `<= 1.0 ms`
   - Composite + bloom: `<= 1.5 ms`
   - Margin: `~0.5 ms`

## How to measure
1. Xcode GPU capture
   - Use Metal frame capture once phase 5 lands, then again after phase 6.
   - Inspect:
     - per-pass GPU duration
     - render target sizes
     - overdraw in particle and mask passes
     - threadgroup occupancy / kernel cost

2. Instruments signposts
   - Add `os_signpost` around:
     - simulation encode
     - mask pass
     - bloom
     - final composite
     - full frame
   - This gives stable comparisons as tuning changes.

3. Runtime frame pacing
   - iOS/visionOS:
     - `MTKView` delegate timing is enough for runtime stats
     - `CADisplayLink` only if you need an external frame-time overlay
   - macOS:
     - use MTKView timing for normal stats
     - use `CVDisplayLink` only if deeper platform-specific pacing diagnostics are needed

4. MetricKit
   - Useful later for on-device aggregate hitching and performance in longer runs.
   - Not necessary for early bring-up, but worth wiring once the effect is stable enough to dogfood.

## What to do when a phase blows budget
1. If phase 3 exceeds budget
   - Reduce particle count first.
   - Drop curl-noise complexity to one octave.
   - Simplify containment math before touching rendering architecture.

2. If phase 5 exceeds budget
   - Lower mask resolution from half-res to quarter-res as an A/B test.
   - Reduce mask sprite radius or particle write density.
   - Confirm you are not accidentally clearing/rebuilding textures every frame.

3. If phase 6 exceeds budget
   - Downsample bloom harder before blur.
   - Reduce Gaussian sigma.
   - Blur only particle highlights, not the full composite.

4. If only macOS discrete GPUs struggle or behave differently
   - Move long-lived simulation/render buffers to `.private`.
   - Use shared staging buffers for CPU uploads and a blit during initialization or rare updates.
   - Avoid branching the whole renderer; isolate storage-mode differences behind allocation helpers.

5. If CPU becomes the issue instead of GPU
   - Check SwiftUI/view churn first.
   - Ensure renderer/pipelines/textures are not recreated unnecessarily.
   - Remove per-frame CPU-side particle work; all simulation should stay on GPU.

## Instrumentation checkpoints by phase
1. End of phase 2
   - Confirm render pass cost for static sprites.
2. End of phase 3
   - Capture compute kernel cost in isolation.
3. End of phase 5
   - First full-frame capture with mask/composite.
4. End of phase 6
   - Final tuning capture with bloom/tone enabled.
5. End of phase 7
   - Compare baseline vs optimized captures and document the chosen quality preset thresholds.
