
struct MeshVertex
{
    float3 position;
    float  uv_x;
    float3 normal;
    float  uv_y;
    float4 color;
};

struct GlobalSceneData {
    float4x4 viewproj;
    float4x4 view;
    float4x4 proj;
};

struct DrawPushConstants {
    float4x4          world_matrix;
    MeshVertex*       vertex_buffer;
};

[[vk::binding(0, 0)]]
ConstantBuffer<GlobalSceneData> g_scene;

[[vk::push_constant]]
DrawPushConstants push_constants;

struct VSOutput {
    float4 position : SV_Position;
    float4 pixel_color;
};

typedef VSOutput PSInput;

[shader("vertex")]
VSOutput basic_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    VSOutput output;

    MeshVertex vertex = push_constants.vertex_buffer[vertex_id];

    float4 world_pos = mul(push_constants.world_matrix, float4(vertex.position, 1.0));
    output.position = mul(g_scene.viewproj, world_pos);
    output.pixel_color = vertex.color;
    return output;
}

[shader("fragment")]
float4 basic_frag(PSInput input) {
    return input.pixel_color;
}
