
import "modules/common_types";

struct DrawPushConstants {
    float4x4          world_matrix;
    MeshVertex*       vertex_buffer;
};

[[vk::binding(0, 0)]]
ConstantBuffer<GlobalSceneData> g_scene;

[[vk::push_constant]]
DrawPushConstants push_constants;

[[vk::binding(1, 1)]]
Sampler2D texture;

struct VSOutput {
    float4 position : SV_Position;
    float4 pixel_color;
    float2 uv : TEXCOORD0;
};

typedef VSOutput PSInput;

[shader("vertex")]
VSOutput basic_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID, float2 uv : TEXCOORD0) {
    VSOutput output;

    MeshVertex vertex = push_constants.vertex_buffer[vertex_id];

    float4 world_pos = mul(push_constants.world_matrix, float4(vertex.position, 1.0));
    output.position = mul(g_scene.viewproj, world_pos);
    output.pixel_color = vertex.color;
    output.uv = float2(vertex.uv_x, vertex.uv_y);
    return output;
}

[shader("fragment")]
float4 basic_frag(PSInput input) {
    return texture.Sample(input.uv);
}
