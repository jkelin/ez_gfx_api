using EzGfx;
using EzGfx.Native;

RunNativeAbiSmoke();
RunManagedResourceSmoke();

static void RunNativeAbiSmoke()
{
    EzGfxNativeLoader.VerifyAbi();
    Console.WriteLine($"native={EzGfxNativeLoader.ResolvedPath}");
    EzGfxResult result = EzGfxNative.EzGfxContextCreate(
        enableDebug: false,
        enableValidation: false,
        EzGfxSurfacePlatform.Win32,
        out ulong context);
    if (result != EzGfxResult.Ok)
    {
        throw new InvalidOperationException($"Context creation failed: {result}");
    }

    try
    {
        NativeErrorsForSmoke.ThrowIfFailed("Context wait idle", EzGfxNative.EzGfxContextWaitIdle(context));
    }
    finally
    {
        EzGfxNative.EzGfxContextDestroy(context);
    }

    Console.WriteLine($"abi={EzGfxNative.AbiVersion}");
}

static void RunManagedResourceSmoke()
{
    using EasyGraphics graphics = EasyGraphics.Create(new EasyGraphicsOptions(EnableDebug: false, EnableValidation: false));
    using GraphicsWindow window = graphics.CreateWindow("ez_gfx_api managed smoke", 64, 64, hidden: true);
    using VertexManager vertices = graphics.BeginVertexManager(defaultVertexStride: 16);
    graphics.CreateIndexHeap(vertices, 3 * (ulong)sizeof(uint), "managed smoke indices");
    vertices.AddHeap("position", 1024, 16);
    _ = vertices.UploadIndices(new uint[] { 0, 1, 2 });
    _ = vertices.UploadVertices(
        "position",
        new byte[3 * 16],
        elementCount: 3,
        elementSize: 16);

    using TextureResource texture = graphics.LoadTexture(
        new byte[] { 255, 255, 255, 255 },
        new TextureDescription(EzGfxSourceTextureFormat.Rgba, 1, 1, DebugLabel: "managed smoke texture"));
    graphics.WaitIdle();
    if (!graphics.BeginFrame(window))
    {
        throw new InvalidOperationException("Managed smoke frame was not ready.");
    }
    using StructuredBuffer structured = graphics.AcquireStructured(16, 1, "managed smoke structured");
    structured.Write(new byte[16]);
    using IndirectBuffer indirect = graphics.AcquireIndirect(1, "managed smoke indirect");
    indirect.WriteDraw(0, new DrawIndexedCommand(3, 1, 0, 0, 0));
    indirect.SetDrawCount(1);
    graphics.FinishFrame();
    Console.WriteLine($"managed=ok texture={texture.Id}");
}

static class NativeErrorsForSmoke
{
    public static void ThrowIfFailed(string operation, EzGfxResult result)
    {
        if (result != EzGfxResult.Ok)
        {
            throw new InvalidOperationException($"{operation} failed: {result}");
        }
    }
}
