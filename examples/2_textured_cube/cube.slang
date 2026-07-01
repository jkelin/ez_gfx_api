import ez_gfx;

struct PushConstants
{
    row_major float4x4 mvp;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

struct V2P
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float4 color : COLOR0;
};

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float4> positions;

[VertexHeap("color")]
[[vk::binding(1, 0)]]
StructuredBuffer<float4> colors;

[RelativeScale(1.0)]
[TargetLayout("depth", "d32_float")]
[[vk::binding(2, 0)]]
Texture2D<float> depth;

[DepthTarget("depth", "read_write")]
[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    V2P output;
    output.pos = mul(push_constants.mvp, float4(positions[vertex_index].xyz, 1.0));
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
