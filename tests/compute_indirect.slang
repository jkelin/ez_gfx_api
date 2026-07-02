import ez_gfx;

struct DrawCommand
{
    uint index_count;
    uint instance_count;
    uint first_index;
    int vertex_offset;
    uint first_instance;
};

[StructuredBuffer("draws")]
[[vk::binding(0, 0)]]
RWIndirectBuffer<DrawCommand> draws;

[shader("compute")]
[numthreads(1, 1, 1)]
void computemain(uint3 dispatch_id: SV_DispatchThreadID)
{
    DrawCommand command;
    command.index_count = dispatch_id.x;
    command.instance_count = 1;
    command.first_index = 0;
    command.vertex_offset = 0;
    command.first_instance = dispatch_id.x;
    draws.Append(command);
}
