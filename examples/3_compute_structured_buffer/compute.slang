import ez_gfx;

struct MeshDescriptor
{
    uint index_count;
    uint first_index;
    uint vertex_offset;
    uint _pad0;
};

struct MeshInstance
{
    uint mesh_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float4 color;
};

struct ComputePushConstants
{
    uint draw_stride_words;
    uint instance_count;
};

[[vk::push_constant]]
ConstantBuffer<ComputePushConstants> push_constants;

[StructuredBuffer("mesh_descriptors")]
[[vk::binding(0, 0)]]
StructuredBuffer<MeshDescriptor> mesh_descriptors;

[StructuredBuffer("mesh_instances")]
[[vk::binding(1, 0)]]
StructuredBuffer<MeshInstance> mesh_instances;

[StructuredBuffer("draw_commands")]
[[vk::binding(2, 0)]]
RWStructuredBuffer<uint> draw_commands;

[shader("compute")]
[numthreads(1, 1, 1)]
void computemain(uint3 dispatch_id: SV_DispatchThreadID)
{
    uint instance_index = dispatch_id.x;
    if (instance_index >= push_constants.instance_count)
    {
        return;
    }

    MeshInstance instance = mesh_instances[instance_index];
    MeshDescriptor mesh = mesh_descriptors[instance.mesh_index];

    if (instance_index == 0)
    {
        draw_commands[0] = push_constants.instance_count;
    }
    uint base = push_constants.draw_stride_words * (instance_index + 1);
    draw_commands[base + 0] = mesh.index_count;
    draw_commands[base + 1] = 1;
    draw_commands[base + 2] = mesh.first_index;
    draw_commands[base + 3] = mesh.vertex_offset;
    draw_commands[base + 4] = instance_index;
}
