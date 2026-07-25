using Microsoft.Win32.SafeHandles;

namespace EzGfx.Native;

public sealed class EzGfxContextHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public EzGfxContextHandle(ulong value) : base(ownsHandle: true) => SetHandle((nint)value);

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxCContextDestroy((ulong)handle);
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
        EzGfxNative.EzGfxCSurfaceDestroy((ulong)handle, _context);
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
        EzGfxNative.EzGfxCShaderDestroy((ulong)handle, _context);
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
        EzGfxNative.EzGfxCIndirectRelease((ulong)handle, _context);
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
        EzGfxNative.EzGfxCStructuredRelease((ulong)handle, _context);
        return true;
    }
}
