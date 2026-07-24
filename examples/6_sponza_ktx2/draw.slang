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
    uint uv_offset;
    uint texture_id;
    uint _pad0;
    uint _pad1;
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

[VertexHeap("uv")]
[[vk::binding(2, 0)]]
StructuredBuffer<float4> uvs;

[StructuredBuffer("primitives")]
[[vk::binding(3, 0)]]
StructuredBuffer<PrimitiveRecord> primitives;

static const uint EZ_GFX_MAX_TEXTURES = 1024;

[[vk::binding(0, 1)]]
Sampler2D ez_gfx_textures[EZ_GFX_MAX_TEXTURES];

[RelativeScale(1.0)]
[TargetLayout("depth", "d32_float")]
[[vk::binding(4, 0)]]
Texture2D<float> depth;

struct V2P
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float2 uv : TEXCOORD0;
    [vk_location(1)]
    nointerpolation uint texture_id : TEXCOORD1;
    [vk_location(2)]
    float4 color : COLOR0;
};

[DepthTarget("depth", "read_write")]
[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID, uint instance_index: SV_VulkanInstanceID)
{
    V2P output;
    PrimitiveRecord prim = primitives[instance_index];
    float4x4 world = prim.transform;
    output.pos = mul(push_constants.mvp, mul(world, float4(positions[vertex_index].xyz, 1.0)));
    uint local_vertex = vertex_index - prim.vertex_offset;
    output.uv = uvs[local_vertex + prim.uv_offset].xy;
    output.texture_id = prim.texture_id;
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
    float4 albedo = ez_gfx_textures[NonUniformResourceIndex(input.texture_id)].Sample(input.uv);
    if (albedo.a < 0.7)
    {
        discard;
    }
    float3 normal = normalize(input.color.rgb * 2.0 - 1.0);
    float3 light_direction = normalize(float3(-0.4, 0.8, 0.5));
    float diffuse = max(dot(normal, light_direction), 0.0);
    float structural_light = 0.25 + 0.75 * diffuse;
    float3 textured_albedo = albedo.rgb * (0.35 + 0.65 * diffuse);
    float3 lit_albedo = lerp(
        float3(structural_light, structural_light, structural_light),
        textured_albedo,
        0.85);
    output.frag_color = float4(lit_albedo, 1.0);
    return output;
}
