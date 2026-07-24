import ez_gfx;

struct PrimitiveRecord
{
    uint first_index;
    uint index_count;
    uint vertex_offset;
    uint normal_offset;
    row_major float4x4 transform;
};

struct ComputePushConstants
{
    uint primitive_count;
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

[StructuredBuffer("primitives")]
[[vk::binding(0, 0)]]
StructuredBuffer<PrimitiveRecord> primitives;

[StructuredBuffer("draw_commands")]
[[vk::binding(1, 0)]]
RWIndirectBuffer<DrawIndexedIndirectCommand> draw_commands;

[shader("compute")]
[numthreads(1, 1, 1)]
void computemain(uint3 dispatch_id: SV_DispatchThreadID)
{
    uint primitive_index = dispatch_id.x;
    if (primitive_index >= push_constants.primitive_count)
    {
        return;
    }

    PrimitiveRecord prim = primitives[primitive_index];

    DrawIndexedIndirectCommand command;
    command.index_count = prim.index_count;
    command.instance_count = 1;
    command.first_index = prim.first_index;
    command.vertex_offset = int(prim.vertex_offset);
    command.first_instance = primitive_index;
    draw_commands.Set(primitive_index, command);
}
