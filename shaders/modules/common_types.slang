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

