import ez_gfx;

struct PushConstants
{
    row_major float4x4 mvp;
};

struct MeshDescriptor
{
    uint index_count;
    uint first_index;
    uint vertex_offset;
    uint normal_vertex_offset;
    row_major float4x4 transform;
};

struct MeshInstance
{
    uint mesh_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float4 color;
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

[StructuredBuffer("mesh_instances")]
[[vk::binding(2, 0)]]
StructuredBuffer<MeshInstance> mesh_instances;

[StructuredBuffer("mesh_descriptors")]
[[vk::binding(3, 0)]]
StructuredBuffer<MeshDescriptor> mesh_descriptors;

[RelativeScale(1.0)]
[TargetLayout("depth", "d32_float")]
[[vk::binding(4, 0)]]
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
    // Vertex data is uploaded untouched from the glTF buffers; node transforms
    // (with scene normalization) live in the mesh descriptor and per-instance
    // transforms in the mesh instance.
    MeshInstance instance = mesh_instances[instance_index];
    MeshDescriptor mesh = mesh_descriptors[instance.mesh_index];
    float4x4 world = mul(instance.transform, mesh.transform);
    output.pos = mul(push_constants.mvp, mul(world, float4(positions[vertex_index].xyz, 1.0)));
    // Position and normal heaps allocate independently; indirect vertex_offset
    // indexes the position heap, normal_vertex_offset indexes the normal heap.
    uint local_vertex = vertex_index - mesh.vertex_offset;
    float3 normal = normalize(mul((float3x3)world, normals[local_vertex + mesh.normal_vertex_offset].xyz));
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
