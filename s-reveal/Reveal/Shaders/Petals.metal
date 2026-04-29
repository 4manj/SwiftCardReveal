// Petals.metal
//
// Flower confetti, ported from `PnlCardLive.jsx`. Each petal is an instanced
// quad sampling one of three pre-rasterized petal shapes from a horizontal
// atlas. Compute kernel evolves position / velocity / spin / life. Render
// pass alpha-blends petals on top of the composited dust scene.

#include <metal_stdlib>
#include "Common.h"

using namespace metal;

// Pink palette from the JSX.
constant half3 kPetalPalette[9] = {
    half3(1.000h, 0.839h, 0.910h),  // FFD6E8
    half3(1.000h, 0.682h, 0.808h),  // FFAECE
    half3(1.000h, 0.761h, 0.855h),  // FFC2DA
    half3(1.000h, 0.894h, 0.941h),  // FFE4F0
    half3(1.000h, 0.722h, 0.831h),  // FFB8D4
    half3(1.000h, 0.941h, 0.965h),  // FFF0F6
    half3(0.976h, 0.659h, 0.788h),  // F9A8C9
    half3(1.000h, 0.800h, 0.894h),  // FFCCE4
    half3(1.000h, 0.851h, 0.925h),  // FFD9EC
};

// ----- Compute: per-frame petal simulation -------------------------------

kernel void simulatePetals(device Petal *petals          [[buffer(0)]],
                           constant PetalUniforms &u     [[buffer(1)]],
                           uint id                       [[thread_position_in_grid]])
{
    if (id >= u.totalCount) return;
    Petal p = petals[id];

    // Skip if not spawned yet, or already dead.
    if (u.elapsed < p.spawnDelay || p.life <= 0.0) {
        petals[id] = p;
        return;
    }

    float dt = u.dt;
    float local = u.elapsed - p.spawnDelay;

    // Fall activity: 0 while rising, 1 while clearly descending. Computed
    // BEFORE gravity is applied so we can use it to scale gravity (and the
    // flutter / swirl below) without a circular dependency.
    float fall = smoothstep(0.0, -0.6, p.velocity.y);

    // Gravity (down = -y in particle space) — half strength while clearly
    // descending. Petals get more hangtime; the broad-face air drag gives
    // them low terminal velocity instead of accelerating like rocks.
    float gravityScale = mix(1.0, 0.5, fall);
    p.velocity.y -= u.gravity * gravityScale * dt;

    // Asymmetric drag.
    p.velocity.x *= u.dragPerFrame;
    p.velocity.y *= (p.velocity.y < 0.0) ? u.fallDragPerFrame : u.dragPerFrame;

    // Lateral flutter — sinusoidal sway, boosted while falling.
    float phase = local * 6.2831853 * p.swirlFreq + p.swirlPhase;
    float flutterAmp = p.swirl * mix(1.0, u.flutterBoost, fall);
    float2 flutter = float2(sin(phase) * flutterAmp,
                            cos(phase * 1.3) * flutterAmp * 0.25);

    // Circular swirl — only active during descent. The X/Y components are
    // 90° out of phase, so the petal traces a small circle on top of its
    // fall trajectory. Mimics a leaf/petal caught in still air spiralling
    // gently as it lands.
    float swirlPhase = local * 6.2831853 * 0.45 + p.swirlPhase * 0.30;
    float swirlAmp   = p.swirl * fall * 0.55;
    float2 swirl = float2(cos(swirlPhase), sin(swirlPhase)) * swirlAmp;

    // Integrate position with flutter + swirl.
    p.position += (p.velocity + flutter + swirl) * dt;

    // Rotation = base spin + sinusoidal pitch wobble + extra swirl spin
    // while falling (visible whirl on the petal itself).
    float pitchWobble = (sin(phase * 0.85) * 2.8 + sin(phase * 1.7) * 0.8) * fall;
    float swirlSpin   = sin(swirlPhase) * 1.4 * fall;
    p.angle += (p.angularVel + pitchWobble + swirlSpin) * dt;

    // Everything that goes up must come down — no horizontal fade. Petals
    // only start to fade once they've fallen well past the visible area, so
    // gravity has time to bring back even the ones that drifted off-screen.
    if (p.position.y < -1.2) {
        p.life -= 0.6 * dt;
    }

    // Hard kill far below the screen.
    if (p.position.y < -2.2 || p.life <= 0.0) {
        p.life = 0.0;
    }

    petals[id] = p;
}

// ----- Render: instanced quad vertex shader ------------------------------

vertex PetalVertexOut petalVertex(uint vid                          [[vertex_id]],
                                  uint iid                          [[instance_id]],
                                  const device Petal *petals        [[buffer(0)]],
                                  constant PetalUniforms &u         [[buffer(1)]])
{
    Petal p = petals[iid];

    // Two triangles forming a unit quad.
    const float2 corners[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2( 1.0,  1.0),
        float2(-1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
    };
    const float2 uvs[6] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(1.0, 0.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(0.0, 0.0)
    };

    float2 corner = corners[vid];
    bool alive = (p.life > 0.001) && (u.elapsed >= p.spawnDelay);

    // Base half-size in particle units, modulated by per-petal scale and the
    // per-cohort `sizeMul` so the foreground reads larger.
    float halfSize = alive ? (p.scale * 0.064 * u.sizeMul) : 0.0;

    float c = cos(p.angle);
    float s = sin(p.angle);
    float2 rotated = float2(corner.x * c - corner.y * s,
                            corner.x * s + corner.y * c) * halfSize;
    // Mirror trajectories around the y-axis for the foreground cohort.
    float2 worldPos = float2(p.position.x * u.flipX, p.position.y) + rotated;

    // Particle space → clip space (divide x by aspect).
    float2 clip = float2(worldPos.x / max(u.aspect, 1e-3), worldPos.y);

    PetalVertexOut out;
    out.position = float4(clip, 0.0, 1.0);

    // UV: pick the cell of the atlas matching petalIdx (3 cells horizontally).
    float cell = 1.0 / 3.0;
    out.uv = float2(uvs[vid].x * cell + float(p.petalIdx % 3) * cell,
                    uvs[vid].y);

    out.tint  = kPetalPalette[p.colorIdx % 9];
    // Soft fade-in for the first 80 ms after spawn so they don't pop.
    float spawnFade = saturate((u.elapsed - p.spawnDelay) * 12.0);
    // Descent fade: 100% opacity above 60% of screen height (y = -0.20),
    // ramping to 0% at 90% (y = -0.80). Each petal gets a personal random
    // offset (±10% screen height) on its fade band — without it, all petals
    // at the same Y fade simultaneously and the band reads as an occluder
    // line. swirlPhase is already a per-petal random radian; reusing it
    // avoids extra state.
    float fadeRand = fract(sin(p.swirlPhase * 12.9898 + float(iid) * 0.137) * 43758.5453);
    float fadeOffset = (fadeRand - 0.5) * 0.20;
    float descentFade = smoothstep(-0.80 + fadeOffset, -0.20 + fadeOffset, p.position.y);
    out.alpha = saturate(p.life) * spawnFade * descentFade;
    return out;
}

// ----- Render: alpha-blended petal sprite --------------------------------

fragment half4 petalFragment(PetalVertexOut in      [[stage_in]],
                             texture2d<half> atlas  [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 sample = atlas.sample(s, in.uv);

    // Atlas stamps are filled white; alpha encodes the petal silhouette.
    half a = sample.a * half(in.alpha);

    // Pow-curve soften: lifts the low-alpha rim so the silhouette's
    // antialiased edge reads as a soft halo instead of a hard outline.
    // 0.7 is a mild blur; lower (e.g. 0.5) for more bloom, 0.85 for crisper.
    a = pow(a, 0.7h);

    if (a < 0.01h) discard_fragment();

    half3 rgb = in.tint * a;
    return half4(rgb, a);
}
