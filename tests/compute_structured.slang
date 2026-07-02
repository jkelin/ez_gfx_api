import ez_gfx;

struct Mesh_Instance
{
    uint mesh_index;
    float4 color;
};

[StructuredBuffer("instances")]
[[vk::binding(0, 0)]]
RWStructuredBuffer<Mesh_Instance> instances;

[shader("compute")]
[numthreads(1, 1, 1)]
void computemain(uint3 dispatch_id: SV_DispatchThreadID)
{
    instances[dispatch_id.x].mesh_index = dispatch_id.x;
}
