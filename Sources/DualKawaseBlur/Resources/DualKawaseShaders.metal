#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

struct VertexIn {
    float3 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct BlurUniforms {
    float2 halfpixel;
    float2 offset;
};

// MARK: - Vertex Shader

vertex VertexOut vertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 1.0);

    // Convert NDC coordinates to texture coordinates
    // Metal uses top-left origin for textures, need to flip Y
    out.texCoord = float2((in.position.x + 1.0) * 0.5,
                          (1.0 - in.position.y) * 0.5);

    return out;
}

// MARK: - Downsample Fragment Shader

/// Downsample shader using 5-tap filter
/// Weights: center=4.0, diagonals=1.0 each, total=8.0
fragment float4 downsampleFragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    constant BlurUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float2 uv = in.texCoord;
    float2 hp = uniforms.halfpixel * uniforms.offset;

    // 5-tap filter: center + 4 diagonal corners
    float4 sum = sourceTexture.sample(linearSampler, uv) * 4.0;                    // Center (weight 4.0)
    sum += sourceTexture.sample(linearSampler, uv - hp);                           // Top-left
    sum += sourceTexture.sample(linearSampler, uv + hp);                           // Bottom-right
    sum += sourceTexture.sample(linearSampler, uv + float2(hp.x, -hp.y));         // Bottom-left
    sum += sourceTexture.sample(linearSampler, uv - float2(hp.x, -hp.y));         // Top-right

    return sum / 8.0;
}

// MARK: - Upsample Fragment Shader

/// Upsample shader using 8-tap filter
/// Weights: cardinals=1.0 each, diagonals=2.0 each, total=12.0
fragment float4 upsampleFragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    constant BlurUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float2 uv = in.texCoord;
    float2 hp = uniforms.halfpixel * uniforms.offset;

    // 4 cardinal directions (weight 1.0 each)
    float4 sum = sourceTexture.sample(linearSampler, uv + float2(-hp.x * 2.0, 0.0));     // Left
    sum += sourceTexture.sample(linearSampler, uv + float2(hp.x * 2.0, 0.0));            // Right
    sum += sourceTexture.sample(linearSampler, uv + float2(0.0, hp.y * 2.0));            // Bottom
    sum += sourceTexture.sample(linearSampler, uv + float2(0.0, -hp.y * 2.0));           // Top

    // 4 diagonal directions (weight 2.0 each)
    sum += sourceTexture.sample(linearSampler, uv + float2(-hp.x, hp.y)) * 2.0;          // Bottom-left
    sum += sourceTexture.sample(linearSampler, uv + float2(hp.x, hp.y)) * 2.0;           // Bottom-right
    sum += sourceTexture.sample(linearSampler, uv + float2(hp.x, -hp.y)) * 2.0;          // Top-right
    sum += sourceTexture.sample(linearSampler, uv + float2(-hp.x, -hp.y)) * 2.0;         // Top-left

    return sum / 12.0;
}
