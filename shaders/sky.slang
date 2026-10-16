import "modules/common_types.slang";

struct GradientPushConstants {
    uint2 image_extent;
}

[[vk::push_constant]]
GradientPushConstants push_constants;

[[vk::binding(0, 0)]]
ConstantBuffer<GlobalSceneData> camera_data;

[[vk::binding(0, 1)]]
[[vk::image_format("rgba16f")]]
RWTexture2D<float4> image;

static const float3 ZENITH_COLOR  = float3(0.10, 0.30, 0.75);
static const float3 HORIZON_COLOR = float3(0.65, 0.80, 0.95);

// Get the world-space direction from the camera through the center of pixel
float3 view_ray(uint2 pixel, uint2 extent) {
    float2 ndc = (float2(pixel) + 0.5) / float2(extent) * 2.0 - 1.0;

    // Undo the projection
    float3 view_dir = float3(ndc.x / camera_data.proj[0][0], ndc.y / camera_data.proj[1][1], -1.0);

    // Apply the inverse of the view rotation
    float4x4 view = camera_data.view;
    return normalize(view[0].xyz * view_dir.x + view[1].xyz * view_dir.y + view[2].xyz * view_dir.z);
}

float3 sky_color(float3 dir) {
    float height = abs(dir.y);
    return lerp(HORIZON_COLOR, ZENITH_COLOR, pow(height, 0.5));
}

[shader("compute")]
[numthreads(16, 16, 1)]
void sky_gradient(uint3 global_id : SV_DispatchThreadID, uint3 local_id : SV_GroupThreadID) {
    uint2 pixel  = global_id.xy;
    uint2 extent = push_constants.image_extent;
    if (pixel.x >= extent.x || pixel.y >= extent.y) return;

    float3 dir = view_ray(pixel, extent);
    image[pixel] = float4(sky_color(dir), 1.0);
}
