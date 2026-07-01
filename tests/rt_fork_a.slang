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
Texture2D<float4> source;

[RelativeScale(1.0)]
[TargetLayout("color", "rgba8")]
[[vk::binding(2, 0)]]
Texture2D<float4> branch_a;

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
    [ColorTarget("branch_a", "write")]
    float4 color : COLOR0;
};

[shader("fragment")]
PSOutput fragmentmain(V2P input)
{
    PSOutput output;
    output.color = source.Load(int3(0, 0, 0)) * float4(1.0, 0.5, 0.5, 1.0);
    return output;
}
