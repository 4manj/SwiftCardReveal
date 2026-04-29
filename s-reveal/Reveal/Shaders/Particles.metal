// Particles.metal
//
// Compute kernel for the per-frame simulation plus the particle color pass.

#include <metal_stdlib>
#include "Common.h"

using namespace metal;

kernel void simulateParticles(device Particle *particles  [[buffer(0)]],
                              constant FrameUniforms &u   [[buffer(1)]],
                              constant uint &count        [[buffer(2)]],
                              uint id                     [[thread_position_in_grid]])
{
    if (id >= count) return;

    Particle p = particles[id];

    float2 noise = sr_curlNoise(p.position * u.noiseScale + u.time * 0.18);
    p.velocity = float2(noise.x * u.idleStrength * 0.6,
                        u.upwardFlowSpeed + noise.y * u.idleStrength * 0.4);

    float splitDirY = tanh((p.position.y - u.maskCenterY) * 4.0);
    float splitKick = splitDirY * 3.2 * u.burstEnvelope;
    p.velocity.y += splitKick * u.dt;

    float xFan = tanh(p.position.x * 1.4) * 0.9 * u.burstEnvelope;
    p.velocity.x += xFan * u.dt;

    p.position += p.velocity * u.dt;

    if (u.burstEnvelope < 0.05 && p.position.y > 1.05) {
        float h = fract(sin(dot(float2(float(id), u.time),
                                 float2(127.1, 311.7))) * 43758.5453);
        p.position = float2((h * 2.0 - 1.0) * u.aspect, -1.05);
        p.life = 1.0;
    }

    if (p.position.x > u.aspect) p.position.x -= 2.0 * u.aspect;
    if (p.position.x < -u.aspect) p.position.x += 2.0 * u.aspect;

    if (u.burstEnvelope >= 0.05 && (p.position.y > 1.05 || p.position.y < -1.05)) {
        p.life = max(0.0, p.life - 2.4 * u.dt);
    } else {
        p.life = 1.0;
    }

    particles[id] = p;
}

vertex ParticleVertexOut particleVertex(uint vid                                [[vertex_id]],
                                        const device Particle *particles        [[buffer(0)]],
                                        constant FrameUniforms &u               [[buffer(1)]])
{
    Particle p = particles[vid];

    float2 clip = float2(p.position.x / max(u.aspect, 1e-3), p.position.y);

    ParticleVertexOut out;
    out.position  = float4(clip, 0.0, 1.0);
    float pointSize = max(p.size, 1.0) * mix(1.0, 1.35, p.seedBias);
    pointSize *= 1.0 + 0.06 * sin(u.time * 1.4 + p.seedBias * 6.28);
    float sizeBoost = 1.0 + 1.4 * u.burstEnvelope;
    out.pointSize = pointSize * sizeBoost;
    out.particleX = p.position.x;
    out.particleY = p.position.y;
    out.life = p.life;

    float velMag = length(p.velocity);
    half3 rgb;
    if (p.hueOffset > 0.75f) {
        half hue = 340.0h / 360.0h;
        half sat = 0.06h;
        half val = mix(0.92h, 1.0h, half(saturate(velMag * 0.45)));
        rgb = sr_hsv2rgb(half3(hue, sat, val));
    } else {
        half t = half(p.hueOffset / 0.75);
        half hue = mix(0.91h, 0.96h, t);
        half sat = mix(0.30h, 0.50h, t);
        half val = mix(0.92h, 1.0h, half(saturate(velMag * 0.45)));
        rgb = sr_hsv2rgb(half3(hue, sat, val));
    }
    half whiteCore = half(saturate(p.seedBias * 0.25));
    rgb = mix(rgb, half3(1.0h, 0.93h, 0.98h), whiteCore);
    out.color = half4(rgb, half(p.life));

    return out;
}

fragment half4 particleFragment(ParticleVertexOut in          [[stage_in]],
                                float2 pointCoord            [[point_coord]],
                                texture2d<float> maskShape   [[texture(0)]],
                                constant FrameUniforms &u    [[buffer(0)]])
{
    constexpr sampler maskSampler(filter::linear, address::clamp_to_edge);

    float2 d  = pointCoord - 0.5;
    float  r2 = dot(d, d) * 4.0;
    float  alpha = exp(-r2 * 2.6);
    float  core = exp(-r2 * 10.0);

    float2 m = float2(in.particleX / max(u.maskRadiusX, 1e-3),
                      (in.particleY - u.maskCenterY) / max(u.maskRadiusY, 1e-3));
    float2 shapeUV = sr_maskShapeUV(m, u.time);
    float rawMask = maskShape.sample(maskSampler, shapeUV).r;
    float maskAlpha = smoothstep(0.5 - u.maskFeather, 0.5 + u.maskFeather, rawMask);
    float ring = exp(-pow(rawMask - 0.5, 2.0) * 30.0) * u.edgeGlowStrength;

    half3 corePink = half3(1.0h, 0.86h, 0.92h);
    half3 rgb = in.color.rgb * half(alpha) + corePink * half(core * 0.25);
    rgb += half3(1.0h, 0.7h, 0.85h) * half(ring * 0.6);

    half life = half(in.life);
    half a = half((alpha * 0.9 + core * 0.35) * maskAlpha) * life;
    return half4(rgb * half(maskAlpha) * life, a);
}

kernel void rescaleParticlesX(device Particle *particles  [[buffer(0)]],
                              constant float &scale       [[buffer(1)]],
                              constant uint &count        [[buffer(2)]],
                              uint id                     [[thread_position_in_grid]])
{
    if (id >= count) return;
    Particle p = particles[id];
    p.position.x *= scale;
    p.velocity.x *= scale;
    particles[id] = p;
}
