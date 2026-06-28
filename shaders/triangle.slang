struct V2P
{
    float4 pos : SV_Position;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct VertexHeapAttribute
{
    string name;
};

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float4> positions;

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
    float4 frag_color : COLOR0;
};

[shader("fragment")]
PSOutput fragmentmain(V2P input)
{
    PSOutput output;
    output.frag_color = float4(1.0, 0.0, 0.0, 1.0);
    return output;
}
