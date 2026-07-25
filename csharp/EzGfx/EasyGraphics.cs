using EzGfx.Native;

namespace EzGfx;

public sealed record EasyGraphicsOptions(bool EnableDebug = true, bool EnableValidation = true);

public sealed class EasyGraphics : IDisposable
{
    private readonly List<GraphicsResource> _resources = new();
    private readonly EzGfxContextHandle _context;
    private GraphicsWindow? _window;
    private bool _disposed;

    private EasyGraphics(EzGfxContextHandle context)
    {
        _context = context;
    }

    public static EasyGraphics Create(EasyGraphicsOptions? options = null)
    {
        options ??= new EasyGraphicsOptions();
        EzGfxNativeLoader.VerifyAbi();
        NativeErrors.ThrowIfFailed(
            "Context creation",
            EzGfxNative.EzGfxContextCreate(
                options.EnableDebug,
                options.EnableValidation,
                EzGfxSurfacePlatform.Win32,
                out ulong rawContext));
        return new EasyGraphics(new EzGfxContextHandle(rawContext));
    }

    public string NativeLibraryPath => EzGfxNativeLoader.ResolvedPath;

    public GraphicsWindow CreateWindow(
        string title,
        uint width = 1280,
        uint height = 720,
        bool hidden = false,
        bool cachePresentedSnapshots = false)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(title);
        if (width == 0 || height == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "Window dimensions must be non-zero.");
        }
        if (_window is not null)
        {
            throw new InvalidOperationException("An EasyGraphics instance supports one parent-owned surface.");
        }

        Win32Window nativeWindow = Win32Window.Create(title, width, height, hidden);
        GraphicsWindow? window = null;
        try
        {
            NativeErrors.ThrowIfFailed(
                "Surface creation",
                EzGfxNative.EzGfxSurfaceCreate(
                    nativeWindow.Handle,
                    nativeWindow.Instance,
                    EzGfxSurfacePlatform.Win32,
                    width,
                    height,
                    out ulong rawSurface,
                    ContextValue));
            window = new GraphicsWindow(this, nativeWindow, new EzGfxSurfaceHandle(rawSurface, ContextValue), width, height);
            NativeErrors.ThrowIfFailed(
                "Surface snapshot cache configuration",
                EzGfxNative.EzGfxSurfaceSetSnapshotCache(
                    window.NativeValue,
                    cachePresentedSnapshots ? 1 : 0,
                    ContextValue));
            NativeErrors.ThrowIfFailed(
                "Device initialization",
                EzGfxNative.EzGfxContextInitDevice(window.NativeValue, ContextValue));
            NativeErrors.ThrowIfFailed(
                "Swapchain creation",
                EzGfxNative.EzGfxSurfaceResize(window.NativeValue, width, height, ContextValue));
            _window = window;
            _resources.Add(window);
            return window;
        }
        catch
        {
            window?.Dispose();
            if (window is null)
            {
                nativeWindow.Dispose();
            }
            throw;
        }
    }

    public void EnableAllDecoders()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        NativeErrors.ThrowIfFailed("Enable image decoders", EzGfxNative.EzGfxEnableAllDecoders(ContextValue));
    }

    public ShaderProgram CompileShader(ShaderDescription description)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(description);
        ArgumentException.ThrowIfNullOrWhiteSpace(description.Path);
        NativeErrors.ThrowIfFailed(
            "Shader compilation",
            EzGfxNative.EzGfxShaderCompile(
                description.Path,
                description.Kind,
                description.VertexEntry,
                description.FragmentEntry,
                description.ComputeEntry,
                out ulong rawShader,
                ContextValue));
        ShaderProgram shader = new(this, new EzGfxShaderHandle(rawShader, ContextValue));
        _resources.Add(shader);
        return shader;
    }

    public VertexManager BeginVertexManager(ulong defaultVertexStride = 16)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (defaultVertexStride == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(defaultVertexStride));
        }
        VertexManager manager = new(this, defaultVertexStride);
        _resources.Add(manager);
        return manager;
    }

    public VertexManager CreateVertexManager(ulong defaultVertexStride, params string[] heapNames)
    {
        ArgumentNullException.ThrowIfNull(heapNames);
        VertexManager manager = BeginVertexManager(defaultVertexStride);
        foreach (string heapName in heapNames)
        {
            manager.AddHeap(heapName, 1024 * 1024, defaultVertexStride);
        }
        return manager;
    }

    public void CreateIndexHeap(VertexManager manager, ulong capacity, string debugName = "index heap")
    {
        ValidateOwner(manager);
        if (capacity == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(capacity));
        }
        NativeErrors.ThrowIfFailed(
            "Index heap creation",
            EzGfxNative.EzGfxIndexHeapCreate(capacity, debugName, ContextValue));
    }

    public uint UploadIndices(VertexManager manager, ReadOnlySpan<uint> indices)
    {
        ValidateOwner(manager);
        if (indices.IsEmpty)
        {
            throw new ArgumentException("At least one index is required.", nameof(indices));
        }
        NativeErrors.ThrowIfFailed(
            "Index upload",
            EzGfxNative.EzGfxVertexUploadIndices(indices, out uint startIndex, ContextValue));
        return startIndex;
    }

    public uint UploadVertices(VertexManager manager, string heapName, ReadOnlySpan<byte> data, int elementCount, int elementSize)
    {
        ValidateOwner(manager);
        ArgumentException.ThrowIfNullOrWhiteSpace(heapName);
        if (elementCount <= 0 || elementSize <= 0 || data.Length != checked(elementCount * elementSize))
        {
            throw new ArgumentException("Vertex data size must equal elementCount multiplied by elementSize.", nameof(data));
        }
        NativeErrors.ThrowIfFailed(
            "Vertex upload",
            EzGfxNative.EzGfxVertexUpload(
                heapName,
                data,
                checked((uint)elementCount),
                checked((ulong)elementSize),
                out uint startIndex,
                ContextValue));
        return startIndex;
    }

    public TextureResource LoadTexture(ReadOnlySpan<byte> data, TextureDescription description)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(description);
        EzGfxTextureError result = EzGfxNative.EzGfxTextureLoad(
            data,
            description.SourceFormat,
            description.DestinationFormat,
            description.Width,
            description.Height,
            description.MipCount,
            description.GenerateMips,
            description.MinFilter,
            description.MagFilter,
            description.MaxAnisotropy,
            description.AddressModeU,
            description.AddressModeV,
            description.AddressModeW,
            description.DebugLabel,
            out ulong textureId,
            ContextValue);
        NativeErrors.ThrowIfTextureFailed("Texture load", result);
        TextureResource texture = new(this, textureId);
        _resources.Add(texture);
        return texture;
    }

    public uint GetTextureBindingIndex(TextureResource texture)
    {
        ValidateOwner(texture);
        NativeErrors.ThrowIfTextureFailed(
            "Texture binding index",
            EzGfxNative.EzGfxTextureBindingIndex(texture.NativeValue, out uint bindingIndex, ContextValue));
        return bindingIndex;
    }

    public bool BeginFrame(GraphicsWindow window)
    {
        ValidateOwner(window);
        if (window.IsMinimized)
        {
            return false;
        }
        EzGfxResult result = EzGfxNative.EzGfxBeginRender(window.NativeValue, ContextValue);
        if (result == EzGfxResult.NotReady)
        {
            return false;
        }
        NativeErrors.ThrowIfFailed("Begin render", result);
        return true;
    }

    public void RenderImGuiDemo(GraphicsWindow window)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ValidateOwner(window);
        NativeErrors.ThrowIfFailed(
            "Dear ImGui demo render",
            EzGfxNative.EzGfxImguiRenderDemo(window.NativeValue, ContextValue));
    }

    public IndirectBuffer AcquireIndirect(uint capacity, string debugName = "indirect buffer")
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (capacity == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(capacity));
        }
        NativeErrors.ThrowIfFailed(
            "Indirect buffer acquisition",
            EzGfxNative.EzGfxAcquireIndirect(capacity, debugName, out ulong rawHandle, ContextValue));
        IndirectBuffer buffer = new(this, new EzGfxIndirectHandle(rawHandle, ContextValue));
        _resources.Add(buffer);
        return buffer;
    }

    public StructuredBuffer AcquireStructured(uint elementSize, uint elementCount, string debugName = "structured buffer")
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (elementSize == 0 || elementCount == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(elementSize));
        }
        NativeErrors.ThrowIfFailed(
            "Structured buffer acquisition",
            EzGfxNative.EzGfxStructuredAcquire(elementSize, elementCount, debugName, out ulong rawHandle, ContextValue));
        StructuredBuffer buffer = new(this, new EzGfxStructuredHandle(rawHandle, ContextValue));
        _resources.Add(buffer);
        return buffer;
    }

    public void AddVertexPipeline(
        ShaderProgram shader,
        IndirectBuffer indirect,
        ReadOnlySpan<Binding> bindings = default,
        DynamicState? dynamicState = null,
        ReadOnlySpan<byte> pushConstants = default)
    {
        ValidateOwner(shader);
        ValidateOwner(indirect);
        DynamicState state = dynamicState ?? new DynamicState();
        NativeErrors.ThrowIfFailed(
            "Vertex pipeline creation",
            EzGfxNative.EzGfxRenderAddVertexPipeline(
                shader.NativeValue,
                indirect.NativeValue,
                bindings,
                state.CullMode,
                state.FrontFace,
                state.PrimitiveType,
                state.BlendMode,
                pushConstants,
                ContextValue));
    }

    public void AddComputePipeline(
        ShaderProgram shader,
        uint dispatchX,
        uint dispatchY,
        uint dispatchZ,
        ReadOnlySpan<Binding> bindings = default,
        ReadOnlySpan<byte> pushConstants = default)
    {
        ValidateOwner(shader);
        if (dispatchX == 0 || dispatchY == 0 || dispatchZ == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(dispatchX));
        }
        NativeErrors.ThrowIfFailed(
            "Compute pipeline creation",
            EzGfxNative.EzGfxRenderAddComputePipeline(
                shader.NativeValue,
                dispatchX,
                dispatchY,
                dispatchZ,
                bindings,
                pushConstants,
                ContextValue));
    }

    public void FinishFrame()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        NativeErrors.ThrowIfFailed("Finish render", EzGfxNative.EzGfxFinishRender(ContextValue));
    }

    public void SaveScreenshot(GraphicsWindow window, string path)
    {
        ValidateOwner(window);
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        NativeErrors.ThrowIfFailed("Screenshot save", EzGfxNative.EzGfxScreenshotSave(window.NativeValue, path, ContextValue));
    }

    public void WaitIdle()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        NativeErrors.ThrowIfFailed("Context wait idle", EzGfxNative.EzGfxContextWaitIdle(ContextValue));
    }

    internal ulong ContextValue => _context.IsInvalid ? 0 : (ulong)_context.DangerousGetHandle();

    internal void ResizeSurface(GraphicsWindow window, uint width, uint height)
    {
        ValidateOwner(window);
        NativeErrors.ThrowIfFailed("Surface resize", EzGfxNative.EzGfxSurfaceResize(window.NativeValue, width, height, ContextValue));
    }

    internal bool SurfaceResizePending(GraphicsWindow window)
    {
        ValidateOwner(window);
        NativeErrors.ThrowIfFailed(
            "Surface resize status query",
            EzGfxNative.EzGfxSurfaceResizePending(window.NativeValue, out int pending, ContextValue));
        return pending != 0;
    }

    internal void UnloadTexture(ulong textureId)
    {
        if (_disposed)
        {
            return;
        }
        NativeErrors.ThrowIfTextureFailed("Texture unload", EzGfxNative.EzGfxTextureUnload(textureId, ContextValue));
    }

    private void ValidateOwner(GraphicsResource resource)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(resource);
        if (!ReferenceEquals(resource.Owner, this))
        {
            throw new ArgumentException("The resource belongs to a different graphics context.", nameof(resource));
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        for (int index = _resources.Count - 1; index >= 0; index--)
        {
            _resources[index].Dispose();
        }
        _resources.Clear();
        _window = null;
        _disposed = true;
        _context.Dispose();
        GC.SuppressFinalize(this);
    }
}
