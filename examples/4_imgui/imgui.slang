import ez_gfx;

struct PushConstants
{
    float2 display_size;
};

struct ImGuiVertex
{
    float2 pos;
    float2 uv;
    uint col;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct ImGuiDrawCommand
{
    float4 clip_rect;
    uint texture_id;
    uint idx_offset;
    uint vtx_offset;
    uint _pad;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

static const uint EZ_GFX_MAX_TEXTURES = 1024;

[[vk::binding(0, 1)]]
Sampler2D ez_gfx_textures[EZ_GFX_MAX_TEXTURES];

[StructuredBuffer("imgui_vertices")]
[[vk::binding(0, 0)]]
StructuredBuffer<ImGuiVertex> imgui_vertices;

[StructuredBuffer("imgui_indices")]
[[vk::binding(1, 0)]]
StructuredBuffer<uint> imgui_indices;

[StructuredBuffer("imgui_commands")]
[[vk::binding(2, 0)]]
StructuredBuffer<ImGuiDrawCommand> imgui_commands;

struct V2P
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float2 screen_pos : TEXCOORD0;
    [vk_location(1)]
    float2 uv : TEXCOORD1;
    [vk_location(2)]
    float4 color : COLOR0;
    [vk_location(3)]
    float4 clip_rect : TEXCOORD2;
    [vk_location(4)]
    uint texture_id : TEXCOORD3;
};

[shader("vertex")]
V2P vertexmain(uint vertex_index : SV_VertexID, uint instance_index : SV_InstanceID)
{
    V2P output;
    ImGuiDrawCommand cmd = imgui_commands[instance_index];
    uint idx = imgui_indices[cmd.idx_offset + vertex_index];
    ImGuiVertex v = imgui_vertices[cmd.vtx_offset + idx];

    float2 pos = v.pos;
    output.screen_pos = pos;
    float2 ndc;
    ndc.x = (pos.x / push_constants.display_size.x) * 2.0 - 1.0;
    ndc.y = (pos.y / push_constants.display_size.y) * 2.0 - 1.0;
    output.pos = float4(ndc, 0.0, 1.0);

    output.uv = v.uv;
    output.color = float4(
        ((v.col >> 0) & 0xFF) / 255.0,
        ((v.col >> 8) & 0xFF) / 255.0,
        ((v.col >> 16) & 0xFF) / 255.0,
        ((v.col >> 24) & 0xFF) / 255.0
    );
    output.clip_rect = cmd.clip_rect;
    output.texture_id = cmd.texture_id;
    return output;
}

struct PSOutput
{
    [vk_location(0)]
    [ColorTarget("swapchain", "write")]
    float4 frag_color : COLOR0;
};

[BlendMode("alpha")]
[shader("fragment")]
PSOutput fragmentmain(V2P input)
{
    PSOutput output;
    if (input.screen_pos.x < input.clip_rect.x || input.screen_pos.x >= input.clip_rect.z ||
        input.screen_pos.y < input.clip_rect.y || input.screen_pos.y >= input.clip_rect.w)
    {
        discard;
    }
    float4 sampled = ez_gfx_textures[input.texture_id].Sample(input.uv);
    output.frag_color = sampled * input.color;
    return output;
}
