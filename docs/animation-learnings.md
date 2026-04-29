# Animation & transition learnings

This document is **required reading before adding or modifying any animation, transition, gesture, or per-frame visual effect in this repo.** Every rule here is paid for in real debugging hours — re-violating any of them will cost the same hours again.

The hard lessons came from a chain of bugs: 360° rotation spins under continuous drag, pinch-cancellation freezes, jagged "is typing" dots, choppy idle motion, ProMotion cadence mismatch, and "ease vs. spring" decisions that didn't actually fix anything because the underlying architecture was wrong. The fixes that finally made the card feel right were structural — not parameter tuning.

## TL;DR — apply these as you write code

- **Per-frame state mutations live in `@Observable` models, not `@State`.** Driving `@State` from a `Timer.publish` (or anything ticking ≥ 30 Hz) re-invalidates the entire enclosing `body` on every tick, forcing SwiftUI to diff the whole view tree. At 120 Hz this exhausts the 8.3 ms frame budget instantly and produces jitter that no amount of timing-curve tweaks will fix.
- **Per-frame visual work goes in a single `Canvas` inside `TimelineView(.animation)`,** not stacked SwiftUI overlays. Hundreds of `Shape` / gradient / blur views each become a SwiftUI node the diff engine has to walk; one `Canvas` collapses them into one render node.
- **`DragGesture` defaults to `.local` coordinate space.** If the gesture host is itself transformed (`rotation3DEffect`, scale, etc.), `v.translation` is reported in the *transformed* frame and becomes discontinuous as the transform changes. **Always pass `coordinateSpace: .global`** and compute translation from `v.location - v.startLocation`.
- **`DragGesture.onEnded` does not fire when a system gesture cancels the drag** (pinch, edge swipe, control-center pull). Always have a watchdog: track `lastGestureSampleAt`, and after ~120 ms of silence in your physics tick, treat the gesture as ended.
- **Stacked `rotation3DEffect`s compose via matrix multiplication, not Euler addition.** Under any animation transaction, interpolating the composed transform under perspective can produce visual full-rotations even with clamped input angles. **Wrap the rotated subtree in `.transaction { $0.animation = nil }`** to disable inherited animations on it. Press scale, halos, and other modifiers go *outside* that zone so they still spring.
- **Springs are for one-shot transitions, not loops.** `.smooth` / `.snappy` / `.bouncy` (iOS 17+ named springs) are the right tool for state A → state B. Keep `.linear` / `.easeInOut` `.repeatForever` for continuous motion (shimmer sweeps, pulses, ambient cycles) — springs are physics simulations meant to settle, they don't apply to indefinite oscillation.
- **The card's interactive feel comes from physics, not animations.** Don't `withAnimation { dragOffset = .zero }` on release — that fed exactly the kind of animation transaction that wrapped the composed transform. Snap the model state and let the simulation tick handle the visual settle.

## Required architecture for any animated/interactive view

When you add a new view that needs per-frame motion or interaction:

```
┌─────────────────────────────────────────────────┐
│  @Observable Model                              │
│   - all per-frame physics state                 │
│   - imperative API: begin/update/end/step       │
│   - watchdog state for gesture cancellation     │
└──────────────────┬──────────────────────────────┘
                   │ exposes properties
                   ▼
┌─────────────────────────────────────────────────┐
│  Slim parent View                               │
│   - reads only what it needs from the model     │
│   - hosts gesture (forwards to model API)       │
│   - rotates/scales the static visual            │
└──────────────────┬──────────────────────────────┘
                   │ overlay
                   ▼
┌─────────────────────────────────────────────────┐
│  TimelineView(.animation) → Canvas              │
│   - calls model.step(at: timeline.date)         │
│   - draws all per-frame effects imperatively    │
│   - lives outside the parent view's body diff   │
└─────────────────────────────────────────────────┘
```

Concrete reference: `s-reveal/Reveal/CardMotionModel.swift` + `s-reveal/Reveal/PnlCard3DView.swift`'s `CardEffectsLayer`.

## Lessons by area

### State management

| Don't | Do |
|---|---|
| `Timer.publish(every: 1/120) → onReceive { dragOffset = … }` (with `dragOffset` as `@State`) | `@Observable` model + `TimelineView(.animation) { Canvas { model.step(at: timeline.date); … } }` |
| Read 6 derived `let`s off `@State` at the top of `body` | Read those values *inside* the `Canvas` closure so they don't trigger body diffs |
| `withAnimation { state = newValue }` for gesture release | Snap state; let the physics tick handle the settle (especially on rotated subtrees) |
| `@StateObject` for plain physics state | `@Observable` (iOS 17+) + `@State private var model = …` — fine-grained dependency tracking only updates the consumers that read each property |

### Animation API

| Use case | Animation |
|---|---|
| Showy entrance (card pop-in, share button arrival) | `.bouncy(duration: 0.55, extraBounce: 0.08–0.12)` |
| Quick press / release reaction | `.snappy(duration: 0.25–0.32, extraBounce: 0.06–0.08)` |
| Gentle hold-state property changes (glow, halo) | `.smooth(duration: 0.22–0.35)` |
| Continuous loops (shimmer band sweep, dot bounce, glow pulse) | `.linear(duration:).repeatForever(autoreverses: false)` or `.easeInOut(duration:).repeatForever(autoreverses: true)` |
| Mid-gesture interpolation between drag samples | **Don't.** Use a physics-tick model that smooths internally. SwiftUI animation on a frame-rate-driven `@State` is the road to hell. |

**Springs to avoid:** `.spring(response:dampingFraction:)` is the legacy API. Prefer the named presets unless you need very specific physics. `.interactiveSpring` is fine for finger-following gestures but only on isolated interactive properties.

### Transitions

```swift
.transition(
    .asymmetric(
        insertion: .scale(scale: 0.84)
            .combined(with: .opacity)
            .combined(with: .offset(y: 24)),
        removal: .opacity
    )
)
```

paired with

```swift
withAnimation(.bouncy(duration: 0.55, extraBounce: 0.12)) { revealed = true }
```

The `.transition` modifier defines *what* changes (scale + opacity + offset). The animation passed to `withAnimation` defines *how* it changes (bouncy spring). Don't put the timing curve in the transition itself — pair them.

### Gesture handling

- `DragGesture(minimumDistance: 0, coordinateSpace: .global)` — always.
- Compute `let translation = CGSize(width: v.location.x - v.startLocation.x, height: v.location.y - v.startLocation.y)`. Don't trust `v.translation` on transformed hosts.
- Track `lastGestureSampleAt = Date()` in `.onChanged`. In your physics tick:
  ```swift
  if isHolding,
     let lastSample = lastGestureSampleAt,
     now.timeIntervalSince(lastSample) > 0.12 {
      // gesture was cancelled — recover state
  }
  ```
- For momentum carryover on release: in `.onChanged`, compute per-sample velocity from `(clamped - lastSampleOffset) / dt` and low-pass filter it (`v = v * 0.65 + sampleV * 0.35`). On release, the simulation reads this velocity and decays it via damping.

### 3D rotation

- Two stacked `rotation3DEffect`s with `perspective` ≠ 0 will produce wraparound spins under any animation context, **even with clamped input angles**. The fix is `.transaction { $0.animation = nil }` on the rotated subtree, not adjusting the angle math.
- Inside the no-animation zone: rotation, gesture, and inner glow / shine effects.
- Outside the zone (above in the modifier chain): scale effects, halos, and any modifier that should spring smoothly when state changes.
- Clamp gesture input at the source (`dragOffset` clamped to ±240 px) AND inside the angle expression (`clamp(.../12, -20, 20)`). Defensive belt-and-braces.

### Performance budgets

- 60 Hz → 16.7 ms per frame
- 120 Hz → 8.3 ms per frame, ~5 ms after system overhead
- 100+ SwiftUI `Shape` views in a `ForEach` rebuilt every state change will blow either budget. Rewrite as `Canvas` strokes if the count is high or the parent state changes often.
- `GeometryReader` is fine in moderation but *each one* triggers a layout pass when its parent invalidates — don't nest several inside an overlay that re-renders at frame rate.
- `.blur(radius:)` is per-frame GPU work scaling with affected area. Big blurred regions in an always-visible layer are expensive; gate behind `if hovering` / `if pressing` when possible.

### Metal renderer

- **Pause `MTKView.isPaused = true`** when there's nothing to draw (faded out / animation finished). Resume on user input. The current renderer pauses when `dustOpacity ≤ 0.001 && !petalActive`.
- **Match the display refresh rate**, never hardcode: `view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond` on iOS. Hardcoding 60 fights ProMotion.
- **Skip passes whose output is invisible**: bloom downsample + MPS Gaussian blur are gated behind `dustOpacity > 0.01` because the composite multiplies bloom by `dustOpacity` anyway.
- **Don't rely on `os_signpost` for performance debugging while shipping** — it triggers unified-logging rate limits at frame rate, and the dropped-message warnings themselves can cause main-thread jitter when debugger is attached.
- **Disable Metal API Validation** in the scheme's Diagnostics tab when measuring perf in Debug. It's known to add 10–30% CPU overhead in Metal-heavy apps.

### Haptics

- One shared `RevealHaptics` singleton wrapping a `CHHapticEngine` for rich Core Haptics patterns. Don't scatter `UIImpactFeedbackGenerator` instantiations.
- Stock `UIImpactFeedbackGenerator` is fine for simple discrete ticks (tilt detents). Cache the generator (`static let`), don't create per-tap.
- Throttle gesture-driven haptics by distance traveled, not by time. ~32–44 px of finger movement between fires feels like detents.
- `prepare()` keeps the haptic engine warm — call it once before the trigger to avoid first-fire latency.

### Variable-width strokes (rim shine, edge highlights)

- Round line caps on tiny path segments produce visible "dot" artifacts because the cap is a semicircle of radius `lineWidth/2` — when the segment is shorter than the line is wide, the visible result is essentially the cap.
- **Use `.butt` line cap** for sub-segments that meet flush.
- For variable-width along a stroke, sample the trim into N segments (≥ 32) and stroke each at a width determined by a smoothstep-ramp + plateau weight curve. Adjacent segments overlap by ~18% so the perpendicular step at width transitions is invisible.
- Render the whole thing inside a `Canvas` `context.stroke(_:with:style:)` call, not as N `.stroke(...)` SwiftUI Shape views.

### Anti-patterns observed in this repo's history

These are direct quotes of mistakes that wasted hours. Don't repeat them.

| Anti-pattern | Why it failed | Correct approach |
|---|---|---|
| Tweaking spring `response`/`dampingFraction` to fix jitter | The bug was in body invalidation rate, not in the curve | Profile invalidation surface; consider `@Observable` + Canvas |
| Reducing rim-stroke segment count from 48 → 24 | Reduced load slightly but didn't fix root cause | Move to a single `Canvas` draw call |
| Using `lineCap: .round` for short sub-segment strokes | Each segment looked like a dot | Use `.butt` caps with overlap |
| Adding more `os_signpost` calls "for debugging" | Triggered 32 Hz rate-limit log spam, debugger jitter | Use Instruments + `os_signpost` only at coarse boundaries, off in Release |
| Hardcoding `preferredFramesPerSecond = 60` | Fought ProMotion's 120 Hz; visible cadence mismatch | `UIScreen.main.maximumFramesPerSecond` |
| Driving `dragOffset` via `withAnimation { dragOffset = .zero }` | Re-introduced the composed-3D-matrix wrap because the animation interpolated the rotation through unexpected paths | Snap the value and let physics handle the settle |
| Reading `v.translation` from a `DragGesture` on a rotated host | Discontinuous as the rotation changed | `coordinateSpace: .global` + manual `location - startLocation` |
| Treating the pinch-bug as "user error" | The gesture was actually being cancelled and our state wasn't recovering | Watchdog on `lastGestureSampleAt` |

## Skills / keywords to apply when adding animations

When you write or review code involving any of these keywords, this document applies:

`animation`, `transition`, `withAnimation`, `interactiveSpring`, `bouncy`, `snappy`, `smooth`, `easeIn`, `easeOut`, `easeInOut`, `linear`, `repeatForever`, `delay`, `Timer.publish`, `TimelineView`, `Canvas`, `GraphicsContext`, `DragGesture`, `MagnificationGesture`, `coordinateSpace`, `rotation3DEffect`, `transformEffect`, `scaleEffect`, `offset`, `transition`, `matchedGeometryEffect`, `PhaseAnimator`, `phaseAnimator`, `keyframeAnimator`, `MTKView`, `os_signpost`, `CHHapticEngine`, `UIImpactFeedbackGenerator`, `MPSImageGaussianBlur`, `UIScreen.main.maximumFramesPerSecond`.

If you find yourself adding any of those without consulting this doc, you're probably about to repeat one of the mistakes catalogued above.
