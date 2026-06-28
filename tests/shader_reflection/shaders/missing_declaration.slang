import ez_gfx;

struct V2P
{
    float4 pos : SV_Position;
};

[DepthTarget("depth", "read_write")]
[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    return V2P(float4(0.0, 0.0, 0.0, 1.0));
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
    return PSOutput(float4(1.0, 0.0, 0.0, 1.0));
}
