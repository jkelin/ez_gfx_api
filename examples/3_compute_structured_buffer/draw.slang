import ez_gfx;

struct PushConstants
{
    row_major float4x4 mvp;
};

struct MeshInstance
{
    uint mesh_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float4 color;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float4> positions;

[VertexHeap("normal")]
[[vk::binding(1, 0)]]
StructuredBuffer<float4> normals;

[StructuredBuffer("mesh_instances")]
[[vk::binding(2, 0)]]
StructuredBuffer<MeshInstance> mesh_instances;

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
    output.pos = mul(push_constants.mvp, float4(positions[vertex_index].xyz, 1.0));
    float3 normal = normalize(normals[vertex_index].xyz);
    float3 lit = normal * 0.5 + 0.5;
    float4 instance_color = mesh_instances[instance_index].color;
    output.color = float4(instance_color.rgb * lit, instance_color.a);
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
