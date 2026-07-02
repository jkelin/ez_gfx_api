import ez_gfx;

[StructuredBuffer("instances")]
[[vk::binding(0, 1)]]
StructuredBuffer<float4> instances;

struct V2P
{
    float4 pos : SV_Position;
};

[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    V2P output;
    output.pos = instances[vertex_index];
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
    output.frag_color = float4(1.0, 1.0, 1.0, 1.0);
    return output;
}
