// Cloud.metal
//
// Fullscreen procedural cloud rendered behind the card after the dust burst.

#include <metal_stdlib>
#include "Common.h"

using namespace metal;

static float sr_cloudFbm(float2 p) {
    float sum = 0.0;
    float amp = 0.5;
    for (uint i = 0; i < 4; ++i) {
        sum += amp * sr_gradNoise(p);
        p = p * 2.03 + float2(11.7, -8.3);
        amp *= 0.5;
    }
    return sum;
}

fragment half4 cloudFragment(FullscreenVertexOut in         [[stage_in]],
                             constant CloudUniforms &u      [[buffer(0)]])
{
    if (u.opacity <= 0.0001) {
        return half4(0.0h);
    }

    float2 uv = in.uv * 2.0 - 1.0;
    uv.x *= max(u.aspect, 1e-3);

    float t = u.time;
    float split = u.splitProgress;

    // Pre-split, the cloud body wanders on a slow Lissajous so the single
    // centred cloud feels organic. Once split, lock the global centre to
    // (0, 0) so the top + bottom lobes both sit on the screen's vertical
    // axis instead of drifting off-centre as a unit.
    float2 baseCenter = float2(0.15 * sin(t * 0.30), 0.05 + 0.10 * cos(t * 0.41));
    float2 center = mix(baseCenter, float2(0.0, 0.0), split);
    float2 p = uv - center;

    // Hover drift. Lateral component goes to zero with the split — when
    // each lobe is anchored at a screen edge, X drift would offset the
    // top and bottom hazes from each other, breaking horizontal
    // alignment. Vertical drift damps to a slow breath instead of
    // disappearing entirely so the lobes stay visibly alive.
    float xMask = 1.0 - split;
    float yScale = mix(1.0, 0.40, split);
    float2 driftA = float2(0.10 * sin(t * 0.18) * xMask,
                           0.05 * cos(t * 0.14) * yScale);
    float2 driftB = float2(0.08 * cos(t * 0.20 + 1.2) * xMask,
                           0.04 * sin(t * 0.16 + 0.8) * yScale);
    float2 driftC = float2(0.06 * sin(t * 0.27 + 2.1),
                           0.08 * cos(t * 0.13 + 1.7));

    // Vertical separation: lobeA's centre migrates *past* the top edge
    // (NDC y = 1.0) and lobeB past the bottom (-1.0). That clips each
    // cloud roughly in half, so the user sees an atmospheric haze hugging
    // each screen edge rather than two full clouds floating in mid-air.
    // lobeC (the centre body) fades out, leaving the middle empty.
    float topY    = mix(0.0, 1.02, split);
    float bottomY = mix(0.0, -1.02, split);

    // Lobe footprints shrink slightly with the split so the residual
    // top/bottom hazes read as compact wisps rather than full clouds.
    float2 sizeA = mix(float2(0.62, 0.38), float2(0.50, 0.30), split);
    float2 sizeB = mix(float2(0.48, 0.30), float2(0.46, 0.28), split);
    float2 sizeC = float2(0.40, 0.26);

    float2 pA = (p - driftA) - float2(0.0, topY);
    float2 pB = (p + driftB) - float2(0.0, bottomY);
    float2 pC = p - driftC;

    float lobeA = exp(-dot(pA / sizeA, pA / sizeA) * 1.9);
    float lobeB = exp(-dot(pB / sizeB, pB / sizeB) * 2.1);
    // Centre lobe fades to nothing as the split completes.
    float lobeC = exp(-dot(pC / sizeC, pC / sizeC) * 2.4) * (1.0 - split);

    float noise = sr_cloudFbm(p * 2.2 + float2(t * 0.09, -t * 0.06));
    float edgeNoise = sr_cloudFbm(p * 4.1 + float2(-t * 0.05, t * 0.08));

    float body = lobeA * 0.95 + lobeB * 0.75 + lobeC * 0.55;
    body *= smoothstep(-0.28, 0.62, noise + body * 0.55);

    // Global halo dims aggressively as we split — its job in the centred
    // state was to soften the edges of one cloud; once we have two
    // separated clouds it would otherwise smear pink across the whole
    // middle, defeating the purpose.
    float halo = exp(-dot(p / float2(0.92, 0.58), p / float2(0.92, 0.58)) * 1.3);
    halo *= smoothstep(-0.35, 0.55, edgeNoise + 0.15);
    halo *= mix(1.0, 0.18, split);

    float pulse = 0.92 + 0.08 * sin(t * 0.72 + noise * 2.0);
    float alpha = saturate((body + halo * 0.55) * u.opacity * pulse);
    float core = saturate(body * 1.15 + halo * 0.2);

    // Slightly hotter pink — leans toward the label's hot-pink without
    // losing the cloud's luminous read once white core mix kicks in.
    half3 pink = half3(1.0h, 0.58h, 0.80h);
    half3 white = half3(1.0h, 0.94h, 0.98h);
    half3 fringe = half3(0.96h, 0.50h, 0.74h);
    half3 color = mix(pink, white, half(core));
    color += fringe * half(halo * 0.18);

    return half4(color * half(alpha), half(alpha));
}
