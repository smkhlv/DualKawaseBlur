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

// MARK: - Copy Fragment Shader

/// Simple copy shader for rendering to drawable
fragment float4 copyFragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]]
) {
    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    return sourceTexture.sample(linearSampler, in.texCoord);
}

// MARK: - Benchmark Compute Kernels

/// These kernels intentionally mirror the render-pipeline filters above. They are
/// benchmark-only experiments used to measure the cost of render-pass boundaries.
kernel void downsampleCompute(
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    texture2d<half, access::write> destinationTexture [[texture(1)]],
    constant float2 &sampleStep [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destinationTexture.get_width() ||
        position.y >= destinationTexture.get_height()) {
        return;
    }

    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    const float2 size = float2(destinationTexture.get_width(), destinationTexture.get_height());
    const float2 uv = (float2(position) + 0.5) / size;

    half4 sum = sourceTexture.sample(linearSampler, uv) * half(4.0);
    sum += sourceTexture.sample(linearSampler, uv - sampleStep);
    sum += sourceTexture.sample(linearSampler, uv + sampleStep);
    sum += sourceTexture.sample(linearSampler, uv + float2(sampleStep.x, -sampleStep.y));
    sum += sourceTexture.sample(linearSampler, uv - float2(sampleStep.x, -sampleStep.y));
    destinationTexture.write(sum / half(8.0), position);
}

/// Four equal diagonal samples preserve the five-tap kernel's zero centroid and
/// per-axis second moment. The radius 1/sqrt(2) matches four diagonal samples
/// plus the original center weight of four after normalization by eight.
kernel void downsampleCompute4Tap(
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    texture2d<half, access::write> destinationTexture [[texture(1)]],
    constant float2 &sampleStep [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destinationTexture.get_width() ||
        position.y >= destinationTexture.get_height()) {
        return;
    }

    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    const float2 size = float2(destinationTexture.get_width(), destinationTexture.get_height());
    const float2 uv = (float2(position) + 0.5) / size;
    constexpr float momentMatchedScale = 0.70710678118;
    const float2 step = sampleStep * momentMatchedScale;

    half4 sum = sourceTexture.sample(linearSampler, uv + float2(-step.x, step.y));
    sum += sourceTexture.sample(linearSampler, uv + float2(step.x, step.y));
    sum += sourceTexture.sample(linearSampler, uv + float2(step.x, -step.y));
    sum += sourceTexture.sample(linearSampler, uv + float2(-step.x, -step.y));
    destinationTexture.write(sum / half(4.0), position);
}

kernel void upsampleCompute8Tap(
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    texture2d<half, access::write> destinationTexture [[texture(1)]],
    constant float2 &sampleStep [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destinationTexture.get_width() ||
        position.y >= destinationTexture.get_height()) {
        return;
    }

    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    const float2 size = float2(destinationTexture.get_width(), destinationTexture.get_height());
    const float2 uv = (float2(position) + 0.5) / size;

    half4 sum = sourceTexture.sample(linearSampler, uv + float2(-sampleStep.x * 2.0, 0.0));
    sum += sourceTexture.sample(linearSampler, uv + float2(sampleStep.x * 2.0, 0.0));
    sum += sourceTexture.sample(linearSampler, uv + float2(0.0, sampleStep.y * 2.0));
    sum += sourceTexture.sample(linearSampler, uv + float2(0.0, -sampleStep.y * 2.0));
    sum += sourceTexture.sample(linearSampler, uv + float2(-sampleStep.x, sampleStep.y)) * half(2.0);
    sum += sourceTexture.sample(linearSampler, uv + float2(sampleStep.x, sampleStep.y)) * half(2.0);
    sum += sourceTexture.sample(linearSampler, uv + float2(sampleStep.x, -sampleStep.y)) * half(2.0);
    sum += sourceTexture.sample(linearSampler, uv + float2(-sampleStep.x, -sampleStep.y)) * half(2.0);
    destinationTexture.write(sum / half(12.0), position);
}

/// Lower-cost final reconstruction. Intermediate upsample levels still use the
/// faithful 8-tap filter. The diagonal radius sqrt(4/3) matches the radial second
/// moment of the normalized 8-tap kernel: (4*4 + 8*2) / 12 = 8/3.
kernel void upsampleCompute4Tap(
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    texture2d<half, access::write> destinationTexture [[texture(1)]],
    constant float2 &sampleStep [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destinationTexture.get_width() ||
        position.y >= destinationTexture.get_height()) {
        return;
    }

    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    const float2 size = float2(destinationTexture.get_width(), destinationTexture.get_height());
    const float2 uv = (float2(position) + 0.5) / size;
    constexpr float momentMatchedDiagonalScale = 1.15470053838;
    const float2 step = sampleStep * momentMatchedDiagonalScale;

    half4 sum = sourceTexture.sample(linearSampler, uv + float2(-step.x, step.y));
    sum += sourceTexture.sample(linearSampler, uv + float2(step.x, step.y));
    sum += sourceTexture.sample(linearSampler, uv + float2(step.x, -step.y));
    sum += sourceTexture.sample(linearSampler, uv + float2(-step.x, -step.y));
    destinationTexture.write(sum / half(4.0), position);
}

/// Three-sample final reconstruction. Equal samples at the vertices of an
/// equilateral triangle have zero centroid and isotropic covariance. A radius
/// sqrt(8/3) matches the faithful kernel's normalized radial second moment.
kernel void upsampleCompute3Tap(
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    texture2d<half, access::write> destinationTexture [[texture(1)]],
    constant float2 &sampleStep [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destinationTexture.get_width() ||
        position.y >= destinationTexture.get_height()) {
        return;
    }

    constexpr sampler linearSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    const float2 size = float2(destinationTexture.get_width(), destinationTexture.get_height());
    const float2 uv = (float2(position) + 0.5) / size;
    constexpr float triangleRadius = 1.63299316186;
    constexpr float triangleHalfRadius = 0.81649658093;
    constexpr float triangleHeight = 1.41421356237;

    half4 sum = sourceTexture.sample(
        linearSampler,
        uv + float2(sampleStep.x * triangleRadius, 0.0)
    );
    sum += sourceTexture.sample(
        linearSampler,
        uv + float2(-sampleStep.x * triangleHalfRadius, sampleStep.y * triangleHeight)
    );
    sum += sourceTexture.sample(
        linearSampler,
        uv + float2(-sampleStep.x * triangleHalfRadius, -sampleStep.y * triangleHeight)
    );
    destinationTexture.write(sum / half(3.0), position);
}
