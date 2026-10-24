import "modules/common_types.slang";

struct SceneDataGLTF {
    float4x4 viewproj;
    float4x4 view;
    float4x4 proj;
    float4 ambient_color;
    float4 sunlight_dir;
    float4 sunlight_color;
};

struct MaterialDataGLTF {
    float4 color_factors;
    float4 metal_rough_factors;
};

struct DrawPushConstants {
    float4x4          world_matrix;
    MeshVertex*       vertex_buffer;
};

[[vk::push_constant]]
DrawPushConstants push_constants;

[[vk::binding(0, 0)]]
ConstantBuffer<SceneDataGLTF> scene_data;

[[vk::binding(0, 1)]]
ConstantBuffer<MaterialDataGLTF> material_data;

[[vk::binding(1, 1)]]
Sampler2D color_texture;

[[vk::binding(2, 1)]]
Sampler2D metal_rough_texture;

struct VSOutput {
    float4 position : SV_Position;
    float3 normal;
    float3 color;
    float2 uv;
};
typedef VSOutput PSInput;

[shader("vertex")]
VSOutput vertex_main(uint vertex_id : SV_VertexID) {
    VSOutput output;

    MeshVertex vertex = push_constants.vertex_buffer[vertex_id];
    output.position = mul(scene_data.viewproj, mul(push_constants.world_matrix, float4(vertex.position, 1)));
    output.normal = mul(push_constants.world_matrix, float4(vertex.normal, 0)).xyz;
    output.color = vertex.color.xyz * material_data.color_factors.xyz;
    output.uv.x = vertex.uv_x;
    output.uv.y = vertex.uv_y;
    return output;
}

[shader("fragment")]
float4 fragment_main(PSInput input) {
    float light_value = max(dot(input.normal, scene_data.sunlight_dir.xyz), 0.1);
    float3 color = input.color * color_texture.Sample(input.uv).xyz;
    float3 ambient = color * scene_data.ambient_color.xyz;
    return float4(light_value * scene_data.sunlight_color.w * color + ambient, 1.0);

}

