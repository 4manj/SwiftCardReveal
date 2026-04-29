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
                                 constant FrameUniforms &u        [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    half4 dust        = particles.sample(s, in.uv);
    half4 bloomSample = bloom.sample(s, in.uv);
    half opacity = half(u.dustOpacity);
    half3 lit = (dust.rgb + bloomSample.rgb * half(u.bloomIntensity)) * opacity;
    half3 toned = lit / (lit + half3(0.6h)) * 1.6h;

    return half4(saturate(toned), 1.0h);
}

fragment half4 downsampleFragment(FullscreenVertexOut in   [[stage_in]],
                                  texture2d<half> src      [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv);
}
