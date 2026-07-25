using Microsoft.Win32.SafeHandles;

namespace EzGfx.Native;

public sealed class EzGfxContextHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public EzGfxContextHandle(ulong value) : base(ownsHandle: true) => SetHandle((nint)value);

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxContextDestroy((ulong)handle);
        return true;
    }
}

public sealed class EzGfxSurfaceHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    private readonly ulong _context;

    public EzGfxSurfaceHandle(ulong value, ulong context) : base(ownsHandle: true)
    {
        _context = context;
        SetHandle((nint)value);
    }

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxSurfaceDestroy((ulong)handle, _context);
        return true;
    }
}

public sealed class EzGfxShaderHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    private readonly ulong _context;

    public EzGfxShaderHandle(ulong value, ulong context) : base(ownsHandle: true)
    {
        _context = context;
        SetHandle((nint)value);
    }

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxShaderDestroy((ulong)handle, _context);
        return true;
    }
}

public sealed class EzGfxIndirectHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    private readonly ulong _context;

    public EzGfxIndirectHandle(ulong value, ulong context) : base(ownsHandle: true)
    {
        _context = context;
        SetHandle((nint)value);
    }

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxIndirectRelease((ulong)handle, _context);
        return true;
    }
}

public sealed class EzGfxStructuredHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    private readonly ulong _context;

    public EzGfxStructuredHandle(ulong value, ulong context) : base(ownsHandle: true)
    {
        _context = context;
        SetHandle((nint)value);
    }

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxStructuredRelease((ulong)handle, _context);
        return true;
    }
}
