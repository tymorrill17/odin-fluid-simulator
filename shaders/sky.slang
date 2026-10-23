import "modules/common_types.slang";
import "fullscreen_triangle.slang";

[[vk::binding(0, 0)]]
ConstantBuffer<GlobalSceneData> scene_data;

static const float3 ZENITH_COLOR  = float3(0.10, 0.30, 0.75);
static const float3 HORIZON_COLOR = float3(0.65, 0.80, 0.95);

float3 sky_color(float3 dir) {
    float height = abs(dir.y);
    return lerp(HORIZON_COLOR, ZENITH_COLOR, pow(height, 0.5));
}

typedef VSOutput PSInput;

float3 view_ray(float2 ndc) {
    // Undo the projection
    float3 view_dir = float3(ndc.x / scene_data.proj[0][0], ndc.y / scene_data.proj[1][1], -1.0);

    // Apply the inverse of the view rotation
    float4x4 view = scene_data.view;
    return normalize(view[0].xyz * view_dir.x + view[1].xyz * view_dir.y + view[2].xyz * view_dir.z);
}

[shader("fragment")]
float4 sky_gradient(PSInput input) {
    float2 ndc = input.uv * 2.0 - 1.0;
    float3 dir = view_ray(ndc);
    return float4(sky_color(dir), 1.0);
}
