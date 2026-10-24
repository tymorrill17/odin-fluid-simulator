import "modules/common_types";

struct ParticleInstance {
    float3 position;
    float  size;
    float4 color;
};

struct DrawPushConstants {
    float4x4          world_matrix;
    MeshVertex*       vertex_buffer;
    ParticleInstance* instance_buffer;
};

[[vk::binding(0, 0)]]
ConstantBuffer<GlobalSceneData> g_scene;

[[vk::push_constant]]
DrawPushConstants push_constants;

struct VSOutput {
    float4 position : SV_Position;
    float4 pixel_color;
    float2 local_position;
};

[shader("vertex")]
VSOutput billboard(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    VSOutput output;

    MeshVertex vertex = push_constants.vertex_buffer[vertex_id];
    ParticleInstance particle = push_constants.instance_buffer[instance_id];

    // Billboard the mesh quad toward the camera using the view matrix's rows,
    // which are the camera's world-space right/up axes.
    float3 right = g_scene.view[0].xyz;
    float3 up    = g_scene.view[1].xyz;

    float3 particle_world_pos = mul(push_constants.world_matrix, float4(particle.position, 1.0)).xyz;
    float3 world_pos = particle_world_pos + (vertex.position.x * right + vertex.position.y * up) * particle.size;

    output.position = mul(g_scene.viewproj, float4(world_pos, 1.0));
    output.pixel_color = vertex.color * particle.color;
    output.local_position = float2(vertex.uv_x, vertex.uv_y) * 2.0 - 1.0;

    return output;
}


typedef VSOutput PSInput;
//struct PSInput {
//    float4 position : SV_Position;
//    float4 pixel_color;
//    int instance_id;
//};

[shader("fragment")]
float4 render_quad_as_circle(PSInput input) {
    float dist = dot(input.local_position, input.local_position);
    clip(1.0 - dist);
    return input.pixel_color;
}

[shader("fragment")]
float4 render_quad(PSInput input) {
    return input.pixel_color;
}
