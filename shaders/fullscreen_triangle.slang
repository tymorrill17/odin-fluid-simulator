
struct VSOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

static const float2 BIG_TRIANGLE[3] = {
    float2(-1.0, -1.0),
    float2( 3.0, -1.0),
    float2(-1.0,  3.0),
};

[shader("vertex")]
VSOutput fullscreen_triangle(uint vertex_id : SV_VertexID) {
    VSOutput output;

    output.position = float4(BIG_TRIANGLE[vertex_id], 0, 1);
    output.uv = 0.5 * BIG_TRIANGLE[vertex_id] + float2(0.5);
    return output;
}
