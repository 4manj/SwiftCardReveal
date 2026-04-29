// Composite.metal
//
// Fullscreen vertex + composite fragment. Mixes:
//   - particle color texture (this frame's dust)
//   - bloom texture (blurred copy of particle color)

#include <metal_stdlib>
#include "Common.h"

using namespace metal;

vertex FullscreenVertexOut fullscreenVertex(uint vid [[vertex_id]])
{
    float2 pos[3] = { float2(-1.0, -1.0), float2( 3.0, -1.0), float2(-1.0,  3.0) };
    float2 uv[3]  = { float2( 0.0,  1.0), float2( 2.0,  1.0), float2( 0.0, -1.0) };

    FullscreenVertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv       = uv[vid];
    return out;
}

fragment half4 compositeFragment(FullscreenVertexOut in           [[stage_in]],
                                 texture2d<half> particles        [[texture(0)]],
                                 texture2d<half> bloom            [[texture(1)]],
                                 texture2d<half> cloud            [[texture(2)]],
                                 texture2d<half> cloudBloom       [[texture(3)]],
                                 constant FrameUniforms &u        [[buffer(0)]],
                                 constant CloudUniforms &cloudU   [[buffer(1)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    half3 dust = particles.sample(s, in.uv).rgb;
    half3 dustBloom = bloom.sample(s, in.uv).rgb;

    half opacity = half(u.dustOpacity);
    half3 lit = (dust + dustBloom * half(u.bloomIntensity)) * opacity;
    if (cloudU.opacity > 0.001) {
        half3 cloudDirect = cloud.sample(s, in.uv).rgb;
        half3 cloudBlur = cloudBloom.sample(s, in.uv).rgb;
        lit += cloudDirect + cloudBlur * half(cloudU.bloomIntensity);
    }
    half3 toned = lit / (lit + half3(0.6h)) * 1.6h;

    // Screen-space dither (~±0.5/255) to break up the final 8-bit drawable
    // quantisation. Without this, large soft gradients band into visible
    // contour rings even with fp16 intermediate buffers.
    float ditherHash = fract(sin(dot(in.uv * 1024.0,
                                     float2(12.9898, 78.233))) * 43758.5453);
    half dither = half((ditherHash - 0.5) * (1.0 / 255.0));

    return half4(saturate(toned + half3(dither)), 1.0h);
}

fragment half4 downsampleFragment(FullscreenVertexOut in   [[stage_in]],
                                  texture2d<half> src      [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv);
}
