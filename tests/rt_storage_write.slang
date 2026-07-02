import ez_gfx;

struct V2P
{
    float4 pos : SV_Position;
};

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float4> positions;

[RelativeScale(1.0)]
[TargetLayout("color", "rgba8")]
[[vk::binding(1, 0)]]
[[vk::image_format("rgba8")]]
RWTexture2D<float4> storage_history;

[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    V2P output;
    output.pos = float4(positions[vertex_index].xyz, 1.0);
    return output;
}

struct PSOutput
{
    [vk_location(0)]
    [ColorTarget("swapchain", "write")]
    float4 color : COLOR0;
};

[shader("fragment")]
PSOutput fragmentmain(V2P input)
{
    PSOutput output;
    uint width;
    uint height;
    storage_history.GetDimensions(width, height);
    int2 pixel = clamp(int2(input.pos.xy), int2(0, 0), int2(int(width) - 1, int(height) - 1));
    storage_history[pixel] = float4(0.2, 0.8, 0.3, 1.0);
    output.color = float4(0.0, 0.0, 0.0, 1.0);
    return output;
}
