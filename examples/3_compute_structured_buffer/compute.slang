import ez_gfx;

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

struct ComputePushConstants
{
    uint instance_count;
};

struct DrawIndexedIndirectCommand
{
    uint index_count;
    uint instance_count;
    uint first_index;
    int vertex_offset;
    uint first_instance;
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
RWIndirectBuffer<DrawIndexedIndirectCommand> draw_commands;

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

    DrawIndexedIndirectCommand command;
    command.index_count = mesh.index_count;
    command.instance_count = 1;
    command.first_index = mesh.first_index;
    command.vertex_offset = int(mesh.vertex_offset);
    command.first_instance = instance_index;
    draw_commands.Append(command);
}
