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
    public EzGfxSurfaceHandle(ulong value) : base(ownsHandle: true) => SetHandle((nint)value);

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxCSurfaceDestroy((ulong)handle);
        return true;
    }
}


public sealed class EzGfxShaderHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public EzGfxShaderHandle(ulong value) : base(ownsHandle: true) => SetHandle((nint)value);

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxCShaderDestroy((ulong)handle);
        return true;
    }
}

public sealed class EzGfxIndirectHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public EzGfxIndirectHandle(ulong value) : base(ownsHandle: true) => SetHandle((nint)value);

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxCIndirectRelease((ulong)handle);
        return true;
    }
}

public sealed class EzGfxStructuredHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public EzGfxStructuredHandle(ulong value) : base(ownsHandle: true) => SetHandle((nint)value);

    protected override bool ReleaseHandle()
    {
        EzGfxNative.EzGfxCStructuredRelease((ulong)handle);
        return true;
    }
}
