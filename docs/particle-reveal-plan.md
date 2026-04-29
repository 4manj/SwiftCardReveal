# Particle "Tap-to-Reveal" — Metal Implementation Plan

Reference clip: `~/Downloads/x-video-analysis/radiofun8-2040605469019197440.mp4`
(7.4 s, 1080 × 1920, 30 fps — kept outside the repo, also covered by `.gitignore`.)

## What we're recreating

A persistent dust cloud sits over a hidden image. The idle cloud drifts gently with a "Tap to reveal" label. On tap, a radial burst sweeps the dust off the canvas; as particles pass over a region, a screen-space **reveal mask** clears, exposing the image underneath. The clip's palette is white → blue → indigo with additive blending, slight bloom, and gentle curl-noise turbulence.

## Anatomy of the effect

1. **Idle field.** ~8 k–20 k particles, low-amplitude curl-noise advection inside a soft elliptical containment well. Hue drifts on a slow sine.
2. **Trigger.** Tap location becomes an impulse source; every particle gets `v += normalize(p − tap) * burstStrength * falloff(distance)`. A short-lived bright flare sprite is added at the tap.
3. **Reveal mask.** A single-channel R8 texture (screen-space, half-resolution is fine). Particles render *additively* into this mask at a low rate; the compositor then samples it as an erase factor on a black overlay covering the image: `final = mix(image, dust, dust_density) * mask + image * (1 − mask)`. Effectively, the more particle "ink" passes through a pixel, the more the image shows through.
4. **Final composition.** Image layer → black/dark overlay modulated by `(1 − reveal_mask)` → particles (additive) → bloom → tone curve.

## Why Metal + compute, not SwiftUI / SpriteKit

- 10 k+ particles with curl-noise per-frame is GPU-bound; a CPU loop won't hit 60/120 fps on iOS without falling back to coarse motion.
- We need a **persistent ping-pong texture** for the reveal mask (frame N reads frame N−1). SwiftUI / Core Animation don't offer that primitive cleanly.
- Metal Performance Shaders gives us free Gaussian blur for bloom.

## Architecture

```
                  ┌────────────────────────┐
SwiftUI tap ──►   │ ParticleRenderer        │  (final image)
  (CGPoint)       │  ┌──────────────────┐   │      ▲
                  │  │ Compute pass:    │   │      │
                  │  │  curl-noise +    │   │      │
                  │  │  burst impulse   │   │      │
                  │  └────────┬─────────┘   │      │
                  │           ▼             │      │
                  │  Particle buffer (SoA)  │      │
                  │           │             │      │
                  │  ┌────────▼─────────┐   │      │
                  │  │ Render pass A:   │──►│ revealMask (R8, ping-pong)
                  │  │  particles → mask│   │      │
                  │  └────────┬─────────┘   │      │
                  │           ▼             │      │
                  │  ┌──────────────────┐   │      │
                  │  │ Render pass B:   │   │      │
                  │  │  composite img + │───┼──────┘
                  │  │  mask + sprites  │   │
                  │  └──────────────────┘   │
                  └────────────────────────┘
```

### Files we'll add

```
swift Try/
  Reveal/
    RevealView.swift              SwiftUI wrapper (UIViewRepresentable / NSViewRepresentable)
    ParticleRenderer.swift        MTKViewDelegate; owns pipelines, buffers, textures
    ParticleSystem.swift          Particle struct, init grid, CPU-side state
    Shaders/
      Particles.metal             compute kernel (simulate) + vertex/fragment (draw)
      Composite.metal             fullscreen reveal compositor + bloom blend
      Common.metal                shared structs (Particle, Uniforms), curl-noise helpers
```

The folder lives inside the existing **synchronized root group** — Xcode will pick up new files automatically; no `project.pbxproj` editing required.

### Particle data layout

```c
struct Particle {
    float2 position;     // NDC-ish, seeded inside ellipse
    float2 velocity;
    float  life;         // 0..1
    float  size;         // px
    float  hueOffset;
    uint   _pad;
};
```
Stored in a single `MTLBuffer` (`storageModeShared` for unified memory; on discrete macOS GPUs use `storageModePrivate` + blit). 16 byte packing.

### Compute kernel (per frame)

```metal
kernel void simulate(device Particle *p          [[buffer(0)]],
                     constant Uniforms &u        [[buffer(1)]],
                     uint id                     [[thread_position_in_grid]]) {
    Particle s = p[id];
    float2 noise = curlNoise(s.position * u.noiseScale + u.time * 0.15);
    s.velocity  += noise * u.idleStrength * u.dt;

    // Burst impulse (single recent tap; ring-buffer for combos).
    float2 d = s.position - u.tapPos;
    float  r = max(length(d), 1e-3);
    float  k = exp(-r * r * u.burstSharpness) * u.burstStrength;
    s.velocity += normalize(d) * k * u.dt;

    s.position += s.velocity * u.dt;
    s.velocity *= u.damping;          // 0.92ish
    s.life      = saturate(s.life - u.dt * u.fadeRate);
    p[id] = s;
}
```

### Mask write pass

Render the particles as 4-vertex point sprites with a soft circular falloff (`exp(-r^2 * k)`). Output is **alpha contribution to the reveal mask**, additive blended into a half-resolution R8 texture. The texture is *not cleared each frame* — it accumulates so the cleared regions stay revealed. A very gentle "regrowth" can be added by drawing the mask back toward 1 each frame at e.g. 0.001/frame if we want the effect to be replayable; for a one-shot reveal we skip that.

### Composite fragment

```metal
fragment half4 composite(VertexOut in [[stage_in]],
                         texture2d<half> art         [[texture(0)]],
                         texture2d<half> particles   [[texture(1)]],
                         texture2d<half> mask        [[texture(2)]],
                         sampler s [[sampler(0)]]) {
    half4 image = art.sample(s, in.uv);
    half  m     = mask.sample(s, in.uv).r;          // 0 = covered, 1 = revealed
    half4 dust  = particles.sample(s, in.uv);
    half3 base  = mix(half3(0.0), image.rgb, m);    // overlay→reveal
    half3 final = base + dust.rgb;                  // additive sparkles on top
    return half4(final, 1.0);
}
```

Bloom = downsample → MPSImageGaussianBlur (σ ≈ 6) → add at 0.4 weight.

## Tuning targets (from the reference)

| Parameter         | Starting value        | Notes |
|-------------------|----------------------|-------|
| Particle count    | 12 000               | Bump to 24 k on iPhone 15+; halve on iPad mini. |
| Idle noise scale  | 1.6                  | Octaves 2. |
| Idle strength     | 0.04                 | Per-second velocity nudge. |
| Damping           | 0.92                 | Per frame. |
| Burst strength    | 7.0                  | One-shot, scaled by `1/dt`. |
| Burst sharpness   | 18.0                 | Higher = tighter ring. |
| Mask write radius | 12 px                | Sprite size in mask pass. |
| Bloom σ           | 6 px                 | Gaussian. |
| Hue range         | 200° – 280° HSV      | Blue → violet, slight white pop on burst. |

## Phased build

1. **MTKView shell** wired via `UIViewRepresentable`, clearing to black, 60 fps loop. Confirm the existing iOS / macOS / visionOS scheme still builds.
2. **Static particle field** — fill buffer, draw point sprites with hard-coded colour. No motion.
3. **Compute simulate** with curl-noise idle + damping. Verify drift looks like the first second of the reference.
4. **Tap impulse** — forward SwiftUI `DragGesture` location into uniforms; tune `burstStrength` against frames 4–6 of the clip.
5. **Reveal mask** — add the R8 ping-pong texture and the mask-write pass. Composite the album art behind. This is the moment it becomes "the effect."
6. **Bloom + tone curve** — soften the highs; match the slight haze on the original.
7. **Performance pass** — Instruments GPU frame capture, target ≤ 4 ms GPU on iPhone 13 base. Drop particle count or move mask to ¼-res if needed.

## Open decisions before coding

- **Reveal art source** — bundled `Image("…")` asset, or pulled from a URL? For a demo, ship a single asset.
- **One-shot vs replayable** — one-shot is closer to the reference (and simpler). Replayable needs the mask regrowth term plus a re-arm gesture.
- **Haptics** — `UIImpactFeedbackGenerator(style: .medium)` on tap, plus a `.soft` tick when the reveal crosses ~80% cleared. Not on macOS.
- **visionOS** — works as a windowed 2D effect, but would feel native as a `RealityView` with the dust as a particle emitter; defer until iOS version is locked.

## Out of scope for v1

- Audio-reactive modulation.
- Multi-touch combos (the structure already supports a tap ring buffer; just unused).
- Lottie / video export — purely a live interactive effect.
