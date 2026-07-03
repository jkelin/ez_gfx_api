import ez_gfx;

struct PushConstants
{
    row_major float4x4 mvp;
};

struct PrimitiveRecord
{
    uint first_index;
    uint index_count;
    uint vertex_offset;
    uint normal_offset;
    row_major float4x4 transform;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float4> positions;

[VertexHeap("normal")]
[[vk::binding(1, 0)]]
StructuredBuffer<float4> normals;

[StructuredBuffer("primitives")]
[[vk::binding(2, 0)]]
StructuredBuffer<PrimitiveRecord> primitives;

[RelativeScale(1.0)]
[TargetLayout("depth", "d32_float")]
[[vk::binding(3, 0)]]
Texture2D<float> depth;

struct V2P
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float4 color : COLOR0;
};

[DepthTarget("depth", "read_write")]
[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID, uint instance_index: SV_InstanceID)
{
    V2P output;
    PrimitiveRecord prim = primitives[instance_index];
    float4x4 world = prim.transform;
    output.pos = mul(push_constants.mvp, mul(world, float4(positions[vertex_index].xyz, 1.0)));
    uint local_vertex = vertex_index - prim.vertex_offset;
    float3 normal = normalize(mul((float3x3)world, normals[local_vertex + prim.normal_offset].xyz));
    output.color = float4(normal * 0.5 + 0.5, 1.0);
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
