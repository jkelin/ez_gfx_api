import ez_gfx;

struct V2P
{
    float4 pos : SV_Position;
};

[RelativeScale(1.0)]
[TargetLayout("color", "rgba8")]
[LoadTarget]
[[vk::binding(1, 0)]]
Texture2D<float4> history;

[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    V2P output;
    output.pos = float4(0.0, 0.0, 0.0, 1.0);
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
    output.frag_color = history.Load(int3(0, 0, 0));
    return output;
}
