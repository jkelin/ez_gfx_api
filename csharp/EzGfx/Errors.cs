using EzGfx.Native;

namespace EzGfx;

public sealed class EzGfxNativeException : Exception
{
    public EzGfxNativeException(string operation, EzGfxResult result)
        : base($"{operation} failed with native result {result} ({(int)result}).")
    {
        Operation = operation;
        Result = result;
    }

    public string Operation { get; }
    public EzGfxResult Result { get; }
}

public sealed class EzGfxTextureException : Exception
{
    public EzGfxTextureException(string operation, EzGfxTextureError result)
        : base($"{operation} failed with native texture error {result} ({(int)result}).")
    {
        Operation = operation;
        Result = result;
    }

    public string Operation { get; }
    public EzGfxTextureError Result { get; }
}

internal static class NativeErrors
{
    public static void ThrowIfFailed(string operation, EzGfxResult result)
    {
        if (result != EzGfxResult.Ok)
        {
            throw new EzGfxNativeException(operation, result);
        }
    }

    public static void ThrowIfTextureFailed(string operation, EzGfxTextureError result)
    {
        if (result != EzGfxTextureError.None)
        {
            throw new EzGfxTextureException(operation, result);
        }
    }
}
