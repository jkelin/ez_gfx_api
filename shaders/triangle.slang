struct V2P
{
    float4 pos : SV_Position;
};

// Three hardcoded triangle vertices; the index buffer selects which one to use.
static const float3 VERTICES[3] = {
    { -0.5f, -0.5f, 0.0f },
    { 0.5f, -0.5f, 0.0f },
    { 0.0f, 0.5f, 0.0f },
};

[shader("vertex")]
V2P vertexmain(uint vertex_index: SV_VertexID)
{
    V2P output;
    output.pos = float4(VERTICES[vertex_index], 1.0);
    return output;
}

struct PSOutput
{
    [vk_location(0)]
    float4 frag_color : COLOR0;
};

[shader("fragment")]
PSOutput fragmentmain(V2P input)
{
    PSOutput output;
    output.frag_color = float4(1.0, 0.0, 0.0, 1.0);
    return output;
}
