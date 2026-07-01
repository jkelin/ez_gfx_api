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
Texture2D<float4> branch_a;

[RelativeScale(1.0)]
[TargetLayout("color", "rgba8")]
[[vk::binding(2, 0)]]
Texture2D<float4> branch_b;

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
    output.color = branch_a.Load(int3(0, 0, 0)) + branch_b.Load(int3(0, 0, 0));
    return output;
}
