# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`s-reveal` is a multiplatform SwiftUI app (iOS 18.5, macOS 15.3, visionOS 2.5) implementing a Metal-based "tap-to-reveal" particle effect: a black screen with a shimmering "Closing your position…" label transitions, on tap, into a dust burst + petal confetti that uncovers a 3D-tilting Polymarket P&L card with Share + Skip buttons. The original design is in `docs/particle-reveal-plan.md`; the build log of how it was actually phased in is in `docs/particle-reveal-execution-plan.md`. Both predate the current renderer in places — when they conflict with the code, trust the code.

Bundle id `aman.s-reveal`. Single workspace, single app target, plus unit + UI test targets.

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

# UI tests live in their own target
xcodebuild test -project s-reveal.xcodeproj -scheme s-reveal \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:s-revealUITests
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

**Sandboxing (macOS).** `s-reveal/s_reveal.entitlements` enables App Sandbox + user-selected read-only file access. If something needs to load images outside the bundle, expect to extend entitlements rather than reach for `FileManager` shortcuts. Today the only bundled asset the renderer needs is `Reveal/pnl-card.jpg`, loaded by `RevealArt.loadBundledCardCGImage()`.

### The reveal scene

`SplashView` (2 s wordmark) → `RevealView` is the entire user-visible flow. `RevealView` composes:

- A `MetalRevealView` (`UIViewRepresentable` on iOS / visionOS, `NSViewRepresentable` on macOS) hosting an `MTKView` whose delegate is `ParticleRenderer`.
- A SwiftUI overlay layered in this order: pre-tap `ClosingPositionLabel` (shimmer + bouncing dots), post-tap `PnlCard3DView` + `ShareButtonsRow`, then a `Skip` button pinned to the bottom.

`RevealOrchestrator` (`ObservableObject`) is the **single source of truth** for `revealed` / `showButtons` / `showSkip`. Both the SwiftUI overlay and the Metal `RevealCoordinator` read/write through it — gestures land on the coordinator, get forwarded to the orchestrator, which calls `ParticleRenderer.registerTap(...)` and flips the published flags. Don't add a parallel state path; route everything through the orchestrator. The Skip button calls `orchestrator.reset()`, which calls `ParticleRenderer.resetToInitial()` (re-seeds particles, clears tap/reveal/petal state, un-pauses the MTKView) and animates the SwiftUI flags back to false — the user lands at the pre-tap label, ready to tap again.

The renderer keeps two independent particle simulations:

- **Dust** (`ParticleSystem` + `Shaders/Particles.metal` + `Shaders/Composite.metal`). A curl-noise compute kernel + tap impulse renders into a per-frame `particleColorTexture`. The composite fragment mixes `particles + bloom * intensity`, scaled by `dustOpacity` (which fades after tap), and reshapes the cloud's silhouette by sampling a single static `maskShapeTexture` (loaded once from a CGImage via `loadMaskShapeTexture()`). **There is no longer an accumulating ping-pong reveal mask** — earlier docs/plans describe one but it has been removed; the only persistent state across frames is the particle buffer itself. The MPS Gaussian bloom downsample/blur passes are gated by `if dustOpacity > 0.01` so they stop running once dust has faded.
- **Petals** (`PetalSystem` + `Shaders/Petals.metal`). A separate confetti simulation that fires from the tap point and outlives the dust fade. CPU-side `Petal` and `PetalUniforms` structs in `PetalSystem.swift` must stay layout-compatible with the matching structs in `Shaders/Common.h`; renderer init asserts the strides. The shader receives `dt * PetalSystem.timeScale` so the whole arc compresses into `animationDuration` wall-clock without truncation — keep `animationDuration ≈ originalArcSeconds / timeScale` when tuning. `ParticleRenderer.isAnimatingPetals` reads `animationDuration` directly to gate re-taps mid-burst.

`ParticleRenderer` also owns `RevealHaptics.shared` (Core Haptics, iOS only) — a single shared engine drives the tap burst (`playRevealArc`), the share button (`playCardPress`), and `PnlCard3DView`'s tilt feedback (`playTiltDetent(progress:)`). Don't scatter `UIImpactFeedbackGenerator` calls; route haptics through `RevealHaptics`. The Skip button intentionally uses the lighter `playTiltDetent(progress: 0)` — share is a primary action, skip is a secondary cancel.

`MTKView.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond` on iOS — hard-coding 60 fights ProMotion's 120 Hz card-smoothing timer and produces a visible cadence mismatch. Leave it at the device max. The background renderer pauses itself (`hostView?.isPaused = true`) once dust and cloud are gone and no petals are in flight; the foreground petal-only renderer pauses when its burst finishes. `registerTap` and `resetToInitial` un-pause both layers.

### Share button (iOS)

`ShareButtonsRow` on iOS does **not** use `ShareLink`. It eagerly prepares a `UIActivityViewController` in `.task(priority: .userInitiated)` — building an `NSItemProvider` registered for `UTType.jpeg`, warming that provider once, and forcing the controller's `.view` to load — so the fast path on tap is just haptic + `present(animated:)`. If the prewarm somehow has not finished yet, the tap path silently falls back to building the controller on demand instead of asking the user to tap again. This was specifically to remove the perceptible delay between tap and drawer-up animation that `ShareLink` had. Tapping `ShareLink` lazily builds the activity controller + asks the `Transferable` for representations + generates `LPLinkMetadata` *on the main thread, on tap*; pre-warming kills all of that.

Timing instrumentation logs to the `ShareSheet` os_log category: `tap -> presenter update`, `tap -> present(animated:) call`, `tap -> share sheet visible`. Watch in `Console.app` if the lag returns.

The `Transferable` payload is still `FileRepresentation(exportedContentType: .jpeg)` against the bundled JPG — that's what makes iOS render the **tall photo-style preview header** at the top of the share sheet (same one Photos.app shows). A bare `URL` falls back to the file-row look. macOS still uses `ShareLink` with a pre-decoded thumbnail.

## Conventions

- Swift 5, `SWIFT_VERSION = 5.0`. `MTL_FAST_MATH = YES` in both Debug and Release — be careful with NaN-sensitive shader math.
- App entry point is `s_revealApp.swift` (`@main struct s_revealApp: App`). Underscore-prefixed name is from the Xcode template; keep it.
- The reference video for the reveal effect lives outside the repo at `~/Downloads/x-video-analysis/radiofun8-2040605469019197440.mp4` per the plan — don't try to commit it.
- `Reveal/pnl-card.jpg` (~580 KB) ships inside the app bundle as a top-level resource, not via `Assets.xcassets`. `RevealArt` looks it up with `Bundle.main.url(forResource: "pnl-card", withExtension: "jpg")`. `ShareButtonsRow` shares the same file URL.
