module ez_gfx;

[__AttributeUsage(_AttributeTargets.Var)]
struct VertexHeapAttribute
{
    string name;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct StructuredBufferAttribute
{
    string name;
};

public struct IndirectBuffer<TElement>
{
    public StructuredBuffer<uint> count;
    public StructuredBuffer<TElement> elements;

    [ForceInline]
    public uint Count()
    {
        return indirect_buffer_count(count);
    }

    [ForceInline]
    public TElement Get(uint index)
    {
        return indirect_buffer_get(elements, index);
    }
};

public struct RWIndirectBuffer<TElement>
{
    public RWStructuredBuffer<uint> count;
    public RWStructuredBuffer<TElement> elements;

    [ForceInline]
    public uint Count()
    {
        return rw_indirect_buffer_count(count);
    }

    [ForceInline]
    public uint Append(TElement element)
    {
        return rw_indirect_buffer_append(count, elements, element);
    }

    [ForceInline]
    public void Set(uint index, TElement element)
    {
        rw_indirect_buffer_set(elements, index, element);
    }

    [ForceInline]
    public TElement Get(uint index)
    {
        return rw_indirect_buffer_get(elements, index);
    }
};

[ForceInline]
public uint rw_indirect_buffer_count(RWStructuredBuffer<uint> count)
{
    return count[0];
}

[ForceInline]
public uint indirect_buffer_count(StructuredBuffer<uint> count)
{
    return count[0];
}

[ForceInline]
public uint rw_indirect_buffer_append<TElement>(
    RWStructuredBuffer<uint> count,
    RWStructuredBuffer<TElement> elements,
    TElement element)
{
    uint index;
    InterlockedAdd(count[0], 1, index);
    elements[index] = element;
    return index;
}

[ForceInline]
public void rw_indirect_buffer_set<TElement>(
    RWStructuredBuffer<TElement> elements,
    uint index,
    TElement element)
{
    elements[index] = element;
}

[ForceInline]
public TElement rw_indirect_buffer_get<TElement>(
    RWStructuredBuffer<TElement> elements,
    uint index)
{
    return elements[index];
}

[ForceInline]
public TElement indirect_buffer_get<TElement>(
    StructuredBuffer<TElement> elements,
    uint index)
{
    return elements[index];
}

[__AttributeUsage(_AttributeTargets.Var)]
struct ColorTargetAttribute
{
    string name;
    string access;
};

[__AttributeUsage(_AttributeTargets.Function)]
struct DepthTargetAttribute
{
    string name;
    string access;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct RelativeScaleAttribute
{
    float value;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct TargetLayoutAttribute
{
    string kind;
    string format;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct LoadTargetAttribute
{
};

[__AttributeUsage(_AttributeTargets.Function)]
struct BlendModeAttribute
{
    string mode;
};
