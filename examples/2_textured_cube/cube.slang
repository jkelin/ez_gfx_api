import ez_gfx;

struct PushConstants
{
    row_major float4x4 mvp;
    uint texture_id;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

static const uint EZ_GFX_MAX_TEXTURES = 1024;

[[vk::binding(0, 1)]]
Sampler2D ez_gfx_textures[EZ_GFX_MAX_TEXTURES];

struct V2P
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float2 uv : TEXCOORD0;
};

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float4> positions;

[RelativeScale(1.0)]
[TargetLayout("depth", "d32_float")]
[[vk::binding(1, 0)]]
Texture2D<float> depth;

[DepthTarget("depth", "read_write")]
[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    V2P output;
    float3 position = positions[vertex_index].xyz;
    output.pos = mul(push_constants.mvp, float4(position, 1.0));
    uint face_vertex = vertex_index & 3;
    output.uv = float2(
        (face_vertex == 1 || face_vertex == 2) ? 1.0 : 0.0,
        (face_vertex == 0 || face_vertex == 1) ? 1.0 : 0.0
    );
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
    output.frag_color = ez_gfx_textures[push_constants.texture_id].Sample(input.uv);
    return output;
}
