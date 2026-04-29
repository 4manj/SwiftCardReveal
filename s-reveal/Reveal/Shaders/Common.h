// Common.h
//
// Shared types and helpers for the particle reveal effect.
// Kept binary-compatible with `Particle` and `FrameUniforms` in
// `ParticleSystem.swift`. If you change any field here, update Swift to match.

#pragma once

#include <metal_stdlib>
using namespace metal;

struct Particle {
    float2 position;     // particle space: x in [-aspect, aspect], y in [-1, 1]
    float2 velocity;
    float  life;
    float  size;         // base point size in pixels
    float  hueOffset;    // 0..1, drives pink hue mapping
    float  seedBias;     // core particles bias toward 1, halo toward 0
};

struct FrameUniforms {
    float  time;            // seconds since renderer start
    float  dt;              // clamped frame delta in seconds
    float  aspect;          // drawableWidth / drawableHeight
    float  noiseScale;
    float  idleStrength;
    float  upwardFlowSpeed; // particle-space units / sec
    float  bloomIntensity;
    float  dustOpacity;     // dust visibility — held high through reveal so cloud persists
    float  maskCenterY;     // Y center of the analytic ellipse
    float  maskRadiusX;     // ellipse half-width in particle space
    float  maskRadiusY;     // ellipse half-height in particle space
    float  maskFeather;     // soft edge thickness in normalized ellipse space
    float  edgeGlowStrength;
    float  tapTime;
    float  burstEnvelope;
};

struct CloudUniforms {
    float time;
    float aspect;
    float opacity;
    float bloomIntensity;
    float splitProgress;     // 0 = centered, 1 = split top/bottom with clear middle
};

struct ParticleVertexOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    half4  color;
    float  particleX;
    float  particleY;
    float  life;
};

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

// ---- Petal (flower confetti) types -----------------------------------------
// Mirrors `Petal` and `PetalUniforms` in `PetalSystem.swift`.

struct Petal {
    float2 position;     // particle space, same as dust
    float2 velocity;     // particle units / sec
    float  angle;        // current rotation, radians
    float  angularVel;   // radians / sec
    float  life;         // 1 → 0
    float  scale;        // size multiplier (0.35..0.9 from JSX)
    float  swirl;        // amplitude (particle units)
    float  swirlFreq;    // Hz
    float  swirlPhase;   // radians
    float  spawnDelay;   // seconds from burst start before this petal appears
    uint   petalIdx;     // 0/1/2 — which atlas cell
    uint   colorIdx;     // 0..8 — which pink shade
};

struct PetalUniforms {
    float  elapsed;            // seconds since burst start
    float  dt;
    float  aspect;
    float  gravity;            // particle units / sec²  (downward acts on -y)
    float  dragPerFrame;       // horizontal drag, already rescaled for actual dt
    float  fallDragPerFrame;   // heavier drag applied to vy when falling — gives
                               // petals a low terminal velocity (broad-face air drag)
    float  flutterBoost;       // multiplier on swirl amplitude during descent
    uint   totalCount;
    float  sizeMul;            // per-cohort size multiplier (foreground > 1)
    float  flipX;              // ±1 — foreground mirrors trajectories
};

struct PetalVertexOut {
    float4 position [[position]];
    float2 uv;
    half3  tint;
    float  alpha;
};

// ---- Hash + value-noise + curl-noise helpers ------------------------------
// Cheap 2D noise; not the highest quality but good enough at this scale.

inline float2 sr_hash2(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

inline float sr_gradNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = dot(sr_hash2(i + float2(0.0, 0.0)), f - float2(0.0, 0.0));
    float b = dot(sr_hash2(i + float2(1.0, 0.0)), f - float2(1.0, 0.0));
    float c = dot(sr_hash2(i + float2(0.0, 1.0)), f - float2(0.0, 1.0));
    float d = dot(sr_hash2(i + float2(1.0, 1.0)), f - float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float2 sr_curlNoise(float2 p) {
    const float eps = 0.01;
    float n1 = sr_gradNoise(p + float2(0.0,  eps));
    float n2 = sr_gradNoise(p - float2(0.0,  eps));
    float n3 = sr_gradNoise(p + float2(eps,  0.0));
    float n4 = sr_gradNoise(p - float2(eps,  0.0));
    float dnx = (n1 - n2) / (2.0 * eps);
    float dny = (n3 - n4) / (2.0 * eps);
    // 90° rotation of gradient => divergence-free flow.
    return float2(dny, -dnx);
}

inline float2 sr_maskShapeUV(float2 m, float time) {
    float2 uv = float2(m.x * 0.5 + 0.5, m.y * 0.5 + 0.5);
    float2 warpA = float2(
        sr_gradNoise(float2(uv.x * 3.0, uv.y * 3.0 + time * 0.45)),
        sr_gradNoise(float2(uv.x * 3.0 + 17.3, uv.y * 3.0 - time * 0.55))
    );
    float2 warpB = float2(
        sr_gradNoise(float2(uv.x * 7.5, uv.y * 7.5 + time * 0.85)),
        sr_gradNoise(float2(uv.x * 7.5 + 41.7, uv.y * 7.5 - time * 0.95))
    ) * 0.45;
    return clamp(uv + (warpA + warpB) * 0.05, 0.0, 1.0);
}

inline float sr_sampleShapeMask(texture2d<float> shape,
                                sampler s,
                                float2 m,
                                float time,
                                float feather) {
    float a = shape.sample(s, sr_maskShapeUV(m, time)).r;
    return smoothstep(0.5 - feather, 0.5 + feather, a);
}

inline half3 sr_hsv2rgb(half3 c) {
    half4 K = half4(1.0h, 2.0h / 3.0h, 1.0h / 3.0h, 3.0h);
    half3 p = abs(fract(half3(c.x) + K.xyz) * 6.0h - K.www);
    return c.z * mix(half3(K.x), saturate(p - K.xxx), c.y);
}
