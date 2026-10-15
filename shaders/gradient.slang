[[vk::binding(0, 0)]]
[[vk::image_format("rgba16f")]]
RWTexture2D<float4> image;

[shader("compute")]
[numthreads(16, 16, 1)]
void gradient(uint3 global_id : SV_DispatchThreadID, uint3 local_id : SV_GroupThreadID) {
    int2 texel_coord = int2(global_id.xy);

    uint width, height;
    image.GetDimensions(width, height);
    int2 size = int2(width, height);

    if (texel_coord.x < size.x && texel_coord.y < size.y) {
        float4 color = float4(0.0, 0.0, 0.0, 1.0);

        if (local_id.x != 0 && local_id.y != 0) {
            color.x = float(texel_coord.x) / float(size.x);
            color.y = float(texel_coord.y) / float(size.y);
        }

        image[texel_coord] = color;
    }
}
