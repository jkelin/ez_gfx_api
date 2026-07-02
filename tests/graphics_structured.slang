import ez_gfx;

struct V2P
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float4 color : COLOR0;
};

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float4> positions;

[StructuredBuffer("colors")]
[[vk::binding(1, 0)]]
StructuredBuffer<float4> colors;

[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    V2P output;
    output.pos = float4(positions[vertex_index].xyz, 1.0);
    output.color = colors[vertex_index];
    return output;
}

struct PSOutput
{
    [vk_location(0)]
    [ColorTarget("swapchain", "write")]
    float4 frag_color : COLOR0;
};

[shader("fragment")]
PSOutput fragmentmain(V2P input)
{
    PSOutput output;
    output.frag_color = input.color;
    return output;
}
