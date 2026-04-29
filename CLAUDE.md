# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`s-reveal` is a multiplatform SwiftUI app (iOS 18.5, macOS 15.3, visionOS 2.5) implementing a Metal-based "tap-to-reveal" particle effect: a black screen with a shimmering "Closing your position…" label transitions, on tap (or after a 5 s auto-reveal), into a dust burst + a procedural luminous cloud that splits to the top/bottom screen edges + petal confetti, uncovering a 3D-tilting Polymarket P&L card with Share + Skip buttons. The original design is in `docs/particle-reveal-plan.md`; the build log of how it was actually phased in is in `docs/particle-reveal-execution-plan.md`. Both predate the current renderer in places — when they conflict with the code, trust the code.

Bundle id `aman.s-reveal`. Single workspace, single app target, plus unit + UI test targets. Active development happens on the `cloud` branch; `main` is the original release.

## Build / Run / Test

There is no Swift Package or other CLI build — everything goes through Xcode / `xcodebuild`. Open `s-reveal.xcodeproj` in Xcode for normal development, or use these from the repo root:

```bash
# Build for iOS Simulator (pick any iOS 18.5+ device available locally)
xcodebuild -project s-reveal.xcodeproj -scheme s-reveal \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build for macOS
xcodebuild -project s-reveal.xcodeproj -scheme s-reveal \
  -destination 'platform=macOS' build

# Run the unit-test target (Swift Testing framework — see note below)
xcodebuild -project s-reveal.xcodeproj -scheme s-reveal \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test by struct/method name
xcodebuild test -project s-reveal.xcodeproj -scheme s-reveal \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:s-revealTests/ParticleSystemTests/returnsRequestedCount

# Just the unit-test target (skip UI tests — saves ~30 s)
xcodebuild test -project s-reveal.xcodeproj -scheme s-reveal \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:s-revealTests
```

`SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx xros xrsimulator` — the same scheme builds for all three. visionOS deployment target is 2.5. The `s-reveal` scheme is shared (`s-reveal.xcodeproj/xcshareddata/xcschemes/`), so CI / fresh checkouts get it without per-user state.

SourceKit (the in-editor indexer) frequently reports phantom "Cannot find type X in scope" errors across files in this target during cross-file edits. **`xcodebuild` is the source of truth.** If `xcodebuild` reports `BUILD SUCCEEDED`, ignore the diagnostics.

## Required reading: `docs/animation-learnings.md`

**Before touching any animation, transition, gesture, `Canvas`, `TimelineView`, or per-frame visual effect in this repo — read [`docs/animation-learnings.md`](docs/animation-learnings.md) first.** That document is the catalog of architectural rules and anti-patterns paid for in concrete debugging hours: state-management for animated views, the named spring matrix (`smooth` / `snappy` / `bouncy` and when each applies), `DragGesture` coordinate-space pitfalls, gesture cancellation watchdogs, `rotation3DEffect` matrix-wrap protection, frame-budget math at 120 Hz, and which past mistakes look reasonable on the surface but aren't.

The single most load-bearing rule it documents: **don't drive `@State` at frame rate.** Use `@Observable` models + `TimelineView(.animation)` + `Canvas` for any per-frame physics or visual effect. The `CardMotionModel` + `CardEffectsLayer` pattern in `s-reveal/Reveal/PnlCard3DView.swift` is the reference implementation; mirror it for new animated/interactive components.

If you find yourself reaching for `Timer.publish`, `withAnimation` on a frame-rate-driven property, hardcoded `preferredFramesPerSecond`, `.spring(response:dampingFraction:)`, round-cap strokes on tiny segments, or `v.translation` on a transformed gesture host — stop and re-read the learnings doc.

## Architecture notes that matter

**Xcode 16 file-system-synchronized groups.** The `s-reveal`, `s-revealTests`, and `s-revealUITests` folders are `PBXFileSystemSynchronizedRootGroup`s in `project.pbxproj`. **Adding a `.swift` / `.metal` / `.h` / asset file inside one of those folders on disk is enough — Xcode picks it up automatically; you do not edit `project.pbxproj` to register sources.** This is how every file in `s-reveal/Reveal/` got added.

**Test framework split.** `s-revealTests/` uses Apple's new Swift Testing (`import Testing`, `@Test`, `#expect(...)`) — not XCTest. `s-revealUITests/` uses XCTest as required for UI testing. Don't mix them up when adding tests.

**Sandboxing (macOS).** `s-reveal/s_reveal.entitlements` enables App Sandbox + user-selected read-only file access. Today the only bundled asset the app needs at runtime is `Reveal/pnl-card.jpg` (the card art); the flower mask SVG is hardcoded as a string literal in `MaskShape.swift::pathData`, so there is no runtime SVG load.

### The reveal scene

`SplashView` (2 s wordmark + warm-up window) → `RevealView` is the entire user-visible flow. `RevealView` composes:

- A background `MetalRevealView` (`UIViewRepresentable` on iOS / visionOS, `NSViewRepresentable` on macOS) hosting an `MTKView` whose delegate is `ParticleRenderer`. Renders dust + cloud + petals.
- A SwiftUI overlay layered in this order: pre-tap `ClosingPositionLabel` (shimmer + bouncing dots), post-tap `PnlCard3DView` + `ShareButtonsRow`, then a `Skip` button pinned to the bottom (`.blendMode(.plusLighter)` so it stays readable against the cloud).
- A second foreground `MetalRevealView` (`isForegroundLayer: true`) on top of the card, drawing only a transparent petal cohort so some confetti visibly falls in front of the P&L. Its `ParticleRenderer` skips dust/cloud/bloom texture allocation entirely.

`RevealOrchestrator` (`@MainActor ObservableObject`) is the **single source of truth** for `revealed` / `showButtons` / `showSkip` and the per-reveal effect toggles. Both the SwiftUI overlay and the Metal `RevealCoordinator` (also `@MainActor`) read/write through it — gestures land on the coordinator, get forwarded to the orchestrator, which calls `ParticleRenderer.registerTap(...)` and flips the published flags. Don't add a parallel state path; route everything through the orchestrator.

The reveal lifecycle:

1. `triggerReveal(...)` → `renderer.registerTap(...)` (background) and `foregroundRenderer?.registerTap(...)` (foreground, haptics suppressed).
2. `withAnimation(.bouncy, 0.55s) { revealed = true }` — card pops in.
3. **Cancellable** `Task` schedules `showButtons = true` at +2.0 s and `showSkip = true` at +2.5 s. `reset()` cancels both pending tasks before clearing the published flags, so a Skip during the 2.0–2.5 s window cannot resurrect UI later.
4. `Skip` → `orchestrator.reset()` → `ParticleRenderer.resetToInitial()` (snaps state back instantly: clears `revealedAt`, stops petals, re-seeds particles, un-pauses the MTKView). The user lands at the pre-tap label, ready to tap again. The 5 s auto-reveal `.task(id: orchestrator.revealed)` restarts cleanly.

### Three Metal subsystems, one renderer

`ParticleRenderer.draw(in:)` orchestrates three independent passes per frame, with each gated to skip its GPU work when not visible:

- **Dust** (`ParticleSystem` + `Shaders/Particles.metal`). A curl-noise compute kernel evolves the particle buffer; a points-render pass writes into `particleColorTexture` (bgra8). Post-tap, `dustOpacity` holds at 1 for 0.18 s then linear-fades to 0 over 1.2 s. Dust silhouette is shaped by sampling a single static `maskShapeTexture` (loaded from a CGImage rasterised once via `MaskShape.rasterize(size:)`); the post-tap mask radius eases from 0.30 to `max(aspect, 1.0) * 4.0` over 1.0 s so the dust burst fills the screen.
- **Cloud** (`Shaders/Cloud.metal` + `CloudUniforms`). Fullscreen procedural fragment: 3 gaussian lobes + FBM modulation + halo + drift + pulse, rendered into `cloudColorTexture` (rgba16Float). Lifecycle is driven by `CloudUniforms.opacity` (`smoothstep(0.05, 0.35, tapTime)`, in sync with the card pop) and `CloudUniforms.splitProgress` (`smoothstep(0.10, 1.85, tapTime)` — the cloud appears centred, then migrates one lobe to `+1.02` y and another to `−1.02` y, anchoring the visible halves to the top + bottom screen edges with a clear middle for the card by ~1.85 s, just before the share button arrives at 2.0 s). Cloud color + bloom passes are skipped entirely when `cloudOpacity <= 0.001`.
- **Petals** (`PetalSystem` + `Shaders/Petals.metal`). A separate confetti simulation that always spawns from `(0, 0)` (screen centre, regardless of where the user tapped) and outlives the dust fade. CPU-side `Petal` and `PetalUniforms` structs in `PetalSystem.swift` must stay layout-compatible with the matching structs in `Shaders/Common.h`; renderer init asserts the strides. The shader receives `dt * PetalSystem.timeScale` so the whole arc compresses into `animationDuration` wall-clock without truncation — keep `animationDuration ≈ originalArcSeconds / timeScale` when tuning. `ParticleRenderer.isAnimatingPetals` reads `animationDuration` directly to gate re-taps mid-burst. Foreground cohort uses a different seed and `flipX = -1` so its trajectories visibly differ.

**Bloom + composite.** Both dust and cloud feed an MPS Gaussian blur pipeline (sigma=1.5) at quarter-res. Intermediates `bloomDownsampled`, `bloomBlurred`, `cloudBloomBlurred`, and the cloud color target are all `rgba16Float` — half-precision is needed because wide low-frequency cloud gradients show 8-bit banding in `bgra8Unorm`. `Composite.metal::compositeFragment` mixes `(dust + dustBloom * bloomIntensity) * dustOpacity` plus `(cloudDirect + cloudBlur * cloudU.bloomIntensity)` (the cloud sample is **inside** an `if (cloudU.opacity > 0.001)` branch — sampling the uninitialised fp16 cloud texture pre-tap caused a green NaN-flash on first load) and finishes with a Reinhard-ish tone curve and `±0.5/255` screen-space dither to break the final 8-bit drawable quantisation.

**Per-reveal effect toggles.** `RevealOrchestrator` exposes `@Published var cloudEnabled: Bool` and `@Published var petalsEnabled: Bool` (both default `true`) plus a convenience `setEffectsForPnL(isPositive:)`. `triggerReveal` passes them through to `registerTap`, which stores them. `petalsEnabled = false` skips the petal seed so `petalActive` stays false and the petal sim/render pass don't run. `cloudEnabled = false` forces `cloudOpacity = 0` so the cloud render + bloom passes are skipped. Animation code is unchanged when toggled — these are purely render gates.

### Pause + cold-start

`MTKView.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond` on iOS — hard-coding 60 fights ProMotion's 120 Hz card-smoothing timer. Leave it at the device max. The background renderer pauses itself at end-of-frame when `dustOpacity ≤ 0.001 && !petalActive && cloudOpacity ≤ 0.001`; the foreground renderer pauses when no petals are in flight. `registerTap` and `resetToInitial` un-pause both layers.

`ParticleRenderer.prewarmPipelines()` runs once at the end of `init`, encoding every render and compute pipeline (plus the fp16 MPS Gaussian Blur path) against tiny 4×4 dummy textures so each pipeline's GPU code is fully specialised before first reveal. The command buffer is `commit()`-ed without `waitUntilCompleted()` so init doesn't block. `MetalPipelinePrewarmer` in the same file does an additional process-level prewarm (matching `MTLCreateSystemDefaultDevice()`) kicked off from `SplashView.task` — both prewarm paths together hide the first-reveal JIT cost behind the 2 s splash. `SplashView.task` also preloads `PnlCard3DView.bundledCardImage` so the card pop-in pays no JPEG decode on the reveal path.

### Haptics

`RevealHaptics.shared` (Core Haptics, iOS only) is a single shared engine driving every haptic: tap burst (`playReveal` — burst pattern + 4 s cancellable tail), share press (`playCardPress`), Skip cancel (`playSkip`), and the card tilt drag (`playTiltDetent(progress:)`). Don't scatter `UIImpactFeedbackGenerator` calls; route haptics through `RevealHaptics`. The reveal tail is held in `activeRevealTailPlayer` so `stopReveal()` can hard-cut it on Skip without tearing down the engine.

### Share button (iOS)

`ShareButtonsRow` on iOS does **not** use `ShareLink`. It eagerly prepares a `UIActivityViewController` in `.task(priority: .userInitiated)` — building an `NSItemProvider` registered for `UTType.jpeg`, warming that provider once, and forcing the controller's `.view` to load — so the fast path on tap is just haptic + `present(animated:)`. If the prewarm somehow has not finished, the tap path silently falls back to building the controller on demand instead of asking the user to tap again. This was specifically to remove the perceptible delay between tap and drawer-up animation that `ShareLink` had.

Timing instrumentation logs to the `ShareSheet` os_log category: `tap -> presenter update`, `tap -> present(animated:) call`, `tap -> share sheet visible`. Watch in `Console.app` if the lag returns.

The `Transferable` payload is `FileRepresentation(exportedContentType: .jpeg)` against the bundled JPG — that's what makes iOS render the **tall photo-style preview header** at the top of the share sheet (same one Photos.app shows). A bare `URL` falls back to the file-row look. macOS still uses `ShareLink` with a pre-decoded thumbnail.

## Conventions

- Swift 5, `SWIFT_VERSION = 5.0`. `MTL_FAST_MATH = YES` in both Debug and Release — be careful with NaN-sensitive shader math (`saturate(NaN)` is implementation-defined, and uninitialised `rgba16Float` textures can read as NaN/Inf — gate sampling on a known-written-this-frame condition).
- App entry point is `s_revealApp.swift` (`@main struct s_revealApp: App`). Underscore-prefixed name is from the Xcode template; keep it.
- The reference video for the reveal effect lives outside the repo at `~/Downloads/x-video-analysis/radiofun8-2040605469019197440.mp4` per the plan — don't try to commit it.
- `Reveal/pnl-card.jpg` (~580 KB) ships inside the app bundle as a top-level resource (not via `Assets.xcassets`). It's loaded once by `PnlCard3DView.bundledCardImage` and re-used by `ShareButtonsRow` for the share preview.
- GPU-shared structs (`Particle`, `FrameUniforms`, `CloudUniforms`, `Petal`, `PetalUniforms`) live in both `Shaders/Common.h` (C) and the Swift counterparts (`ParticleSystem.swift`, `PetalSystem.swift`). Field order and stride must agree byte-for-byte; `ParticleRenderer.init` asserts each stride at runtime, and `ParticleSystemTests` asserts the same constants — update both sides plus the tests when changing layouts.
