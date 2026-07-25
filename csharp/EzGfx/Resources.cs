using System.Runtime.InteropServices;
using EzGfx.Native;

namespace EzGfx;

public abstract class GraphicsResource : IDisposable
{
    protected GraphicsResource(EasyGraphics owner)
    {
        Owner = owner;
    }

    internal EasyGraphics Owner { get; }

    public abstract void Dispose();
}

public sealed class GraphicsWindow : GraphicsResource
{
    private readonly Win32Window _window;
    private readonly EzGfxSurfaceHandle _surface;
    private uint _width;
    private uint _height;
    private bool _disposed;
    private bool _shouldClose;

    internal GraphicsWindow(EasyGraphics owner, Win32Window window, EzGfxSurfaceHandle surface, uint width, uint height)
        : base(owner)
    {
        _window = window;
        _surface = surface;
        _width = width;
        _height = height;
    }

    public uint Width => _width;
    public uint Height => _height;
    public bool IsMinimized => _width == 0 || _height == 0;
    internal ulong NativeValue => _surface.IsInvalid ? 0 : (ulong)_surface.DangerousGetHandle();

    public bool ShouldClose
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _shouldClose;
        }
        set
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _shouldClose = value;
        }
    }

    public void PollEvents()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _window.PollEvents(out uint width, out uint height, out bool closeRequested);
        _shouldClose |= closeRequested;
        if (width == 0 || height == 0)
        {
            Owner.ResizeSurface(this, 0, 0);
            _width = 0;
            _height = 0;
            return;
        }

        bool pendingResize = Owner.SurfaceResizePending(this);
        if (width != _width || height != _height || pendingResize)
        {
            Owner.ResizeSurface(this, width, height);
            _width = width;
            _height = height;
        }
    }

    public (uint Width, uint Height) GetFramebufferSize()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (IsMinimized)
        {
            return (0, 0);
        }
        NativeErrors.ThrowIfFailed(
            "Framebuffer size query",
            EzGfxNative.EzGfxCSurfaceGetExtent(NativeValue, out uint width, out uint height));
        return (width, height);
    }

    public override void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _surface.Dispose();
        _window.Dispose();
        GC.SuppressFinalize(this);
    }
}

public sealed record ShaderDescription(
    string Path,
    EzGfxShaderKind Kind = EzGfxShaderKind.Graphics,
    string? VertexEntry = "vertexmain",
    string? FragmentEntry = "fragmentmain",
    string? ComputeEntry = "computemain");

public sealed class ShaderProgram : GraphicsResource
{
    private readonly EzGfxShaderHandle _native;
    private bool _disposed;

    internal ShaderProgram(EasyGraphics owner, EzGfxShaderHandle native)
        : base(owner)
    {
        _native = native;
    }

    internal ulong NativeValue => _native.IsInvalid ? 0 : (ulong)_native.DangerousGetHandle();

    public override void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _native.Dispose();
        GC.SuppressFinalize(this);
    }
}

public sealed class VertexManager : GraphicsResource
{
    private readonly ulong _defaultStride;
    private bool _disposed;

    internal VertexManager(EasyGraphics owner, ulong defaultStride)
        : base(owner)
    {
        _defaultStride = defaultStride;
    }

    public ulong DefaultStride => _defaultStride;

    public void AddHeap(string name, ulong capacity, ulong stride)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        if (capacity == 0 || stride == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(capacity));
        }
        NativeErrors.ThrowIfFailed(
            "Vertex heap creation",
            EzGfxNative.EzGfxCVertexHeapCreate(Owner.ContextValue, name, capacity, stride));
    }

    public uint UploadIndices(ReadOnlySpan<uint> indices) => Owner.UploadIndices(this, indices);

    public uint UploadVertices(string heapName, ReadOnlySpan<byte> data, int elementCount, int elementSize)
        => Owner.UploadVertices(this, heapName, data, elementCount, elementSize);

    public override void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        GC.SuppressFinalize(this);
    }
}

public sealed class IndirectBuffer : GraphicsResource
{
    private readonly EzGfxIndirectHandle _native;
    private bool _disposed;

    internal IndirectBuffer(EasyGraphics owner, EzGfxIndirectHandle native)
        : base(owner)
    {
        _native = native;
    }

    internal ulong NativeValue => _native.IsInvalid ? 0 : (ulong)_native.DangerousGetHandle();

    public void WriteDraw(uint index, DrawIndexedCommand command)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        NativeErrors.ThrowIfFailed(
            "Indirect draw write",
            EzGfxNative.EzGfxCIndirectWriteDraw(
                NativeValue,
                index,
                command.IndexCount,
                command.InstanceCount,
                command.FirstIndex,
                command.VertexOffset,
                command.FirstInstance));
    }

    public void SetDrawCount(uint count)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        NativeErrors.ThrowIfFailed("Indirect draw count", EzGfxNative.EzGfxCIndirectSetDrawCount(NativeValue, count));
    }

    public override void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _native.Dispose();
        GC.SuppressFinalize(this);
    }
}

public sealed class StructuredBuffer : GraphicsResource
{
    private readonly EzGfxStructuredHandle _native;
    private bool _disposed;

    internal StructuredBuffer(EasyGraphics owner, EzGfxStructuredHandle native)
        : base(owner)
    {
        _native = native;
    }

    internal ulong NativeValue => _native.IsInvalid ? 0 : (ulong)_native.DangerousGetHandle();

    public void Write(ReadOnlySpan<byte> data)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (data.IsEmpty)
        {
            throw new ArgumentException("Structured data must not be empty.", nameof(data));
        }
        NativeErrors.ThrowIfFailed("Structured buffer write", EzGfxNative.EzGfxCStructuredWrite(NativeValue, data));
    }

    public override void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _native.Dispose();
        GC.SuppressFinalize(this);
    }
}

public sealed class TextureResource : GraphicsResource
{
    private readonly uint _textureId;
    private bool _disposed;

    internal TextureResource(EasyGraphics owner, uint textureId)
        : base(owner)
    {
        _textureId = textureId;
    }

    public uint Id => _textureId;

    public override void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Owner.UnloadTexture(_textureId);
        GC.SuppressFinalize(this);
    }
}

public readonly record struct DrawIndexedCommand(
    uint IndexCount,
    uint InstanceCount,
    uint FirstIndex,
    int VertexOffset,
    uint FirstInstance);

public readonly record struct Binding(string Name, StructuredBuffer? Structured = null, IndirectBuffer? Indirect = null) : IEzGfxBindingInput
{
    ulong IEzGfxBindingInput.Structured => Structured?.NativeValue ?? 0;
    ulong IEzGfxBindingInput.Indirect => Indirect?.NativeValue ?? 0;
}
public readonly record struct DynamicState(
    uint CullMode = 2,
    uint FrontFace = 0,
    uint PrimitiveType = 0,
    uint BlendMode = 0);

public sealed record TextureDescription(
    EzGfxSourceTextureFormat SourceFormat,
    uint Width,
    uint Height,
    uint MipCount = 1,
    bool GenerateMips = false,
    EzGfxTextureFilter MinFilter = EzGfxTextureFilter.Linear,
    EzGfxTextureFilter MagFilter = EzGfxTextureFilter.Linear,
    float MaxAnisotropy = 1,
    EzGfxTextureAddressMode AddressModeU = EzGfxTextureAddressMode.Repeat,
    EzGfxTextureAddressMode AddressModeV = EzGfxTextureAddressMode.Repeat,
    EzGfxTextureAddressMode AddressModeW = EzGfxTextureAddressMode.Repeat,
    EzGfxTextureDestinationFormat DestinationFormat = EzGfxTextureDestinationFormat.Rgba8Unorm,
    string? DebugLabel = "texture");

internal sealed class Win32Window : IDisposable
{
    private const uint WsOverlappedWindow = 0x00CF0000;
    private const uint CwUseDefault = 0x80000000;
    private const int SwShow = 5;
    private const int SwHide = 0;
    private const uint WmDestroy = 0x0002;
    private const uint WmClose = 0x0010;
    private const uint WmQuit = 0x0012;
    private const uint PmRemove = 0x0001;
    private const int ErrorClassAlreadyExists = 1410;
    private const string ClassName = "EzGfx.Managed.Win32Window";
    private static readonly object ClassSync = new();
    private static readonly WndProcDelegate WindowProcedure = WindowProcedureImpl;
    private static bool _classRegistered;
    private static IntPtr _classInstance;
    private readonly IntPtr _handle;
    private bool _disposed;

    private Win32Window(IntPtr handle, IntPtr instance)
    {
        _handle = handle;
        Instance = instance;
    }

    public IntPtr Handle => _handle;
    public IntPtr Instance { get; }

    public static Win32Window Create(string title, uint clientWidth, uint clientHeight, bool hidden)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The native Vulkan surface currently supports Win32 only.");
        }
        EnsureClassRegistered();
        RECT rectangle = new() { Right = checked((int)clientWidth), Bottom = checked((int)clientHeight) };
        if (!AdjustWindowRectEx(ref rectangle, WsOverlappedWindow, false, 0))
        {
            throw new InvalidOperationException($"AdjustWindowRectEx failed: {Marshal.GetLastWin32Error()}.");
        }
        IntPtr handle = CreateWindowEx(
            0,
            ClassName,
            title,
            WsOverlappedWindow,
            unchecked((int)CwUseDefault),
            unchecked((int)CwUseDefault),
            rectangle.Right - rectangle.Left,
            rectangle.Bottom - rectangle.Top,
            IntPtr.Zero,
            IntPtr.Zero,
            _classInstance,
            IntPtr.Zero);
        if (handle == IntPtr.Zero)
        {
            throw new InvalidOperationException($"CreateWindowEx failed: {Marshal.GetLastWin32Error()}.");
        }
        ShowWindow(handle, hidden ? SwHide : SwShow);
        UpdateWindow(handle);
        return new Win32Window(handle, _classInstance);
    }

    public void PollEvents(out uint width, out uint height, out bool closeRequested)
    {
        width = 0;
        height = 0;
        closeRequested = false;
        MSG message;
        while (PeekMessage(out message, IntPtr.Zero, 0, 0, PmRemove))
        {
            if (message.Message == WmQuit)
            {
                closeRequested = true;
                continue;
            }
            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
        RECT rectangle;
        if (GetClientRect(_handle, out rectangle))
        {
            width = rectangle.Right - rectangle.Left > 0 ? checked((uint)(rectangle.Right - rectangle.Left)) : 0;
            height = rectangle.Bottom - rectangle.Top > 0 ? checked((uint)(rectangle.Bottom - rectangle.Top)) : 0;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        DestroyWindow(_handle);
    }

    private static void EnsureClassRegistered()
    {
        lock (ClassSync)
        {
            if (_classRegistered)
            {
                return;
            }
            _classInstance = GetModuleHandle(null);
            WNDCLASSEX windowClass = new()
            {
                Size = (uint)Marshal.SizeOf<WNDCLASSEX>(),
                Style = 0,
                WindowProcedure = Marshal.GetFunctionPointerForDelegate(WindowProcedure),
                Instance = _classInstance,
                Cursor = LoadCursor(IntPtr.Zero, (IntPtr)32512),
                ClassName = ClassName,
            };
            if (RegisterClassEx(ref windowClass) == 0 && Marshal.GetLastWin32Error() != ErrorClassAlreadyExists)
            {
                throw new InvalidOperationException($"RegisterClassEx failed: {Marshal.GetLastWin32Error()}.");
            }
            _classRegistered = true;
        }
    }

    private static IntPtr WindowProcedureImpl(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam)
    {
        if (message == WmClose)
        {
            DestroyWindow(window);
            return IntPtr.Zero;
        }
        if (message == WmDestroy)
        {
            PostQuitMessage(0);
            return IntPtr.Zero;
        }
        return DefWindowProc(window, message, wParam, lParam);
    }

    private delegate IntPtr WndProcDelegate(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public uint Size;
        public uint Style;
        public IntPtr WindowProcedure;
        public int ClassExtra;
        public int WindowExtra;
        public IntPtr Instance;
        public IntPtr Icon;
        public IntPtr Cursor;
        public IntPtr Background;
        public IntPtr MenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string ClassName;
        public IntPtr SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr Window;
        public uint Message;
        public UIntPtr WParam;

        public IntPtr LParam;
        public uint Time;
        public POINT Point;
        public uint Private;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassEx(ref WNDCLASSEX windowClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint extendedStyle, string className, string windowName, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int exitCode);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProc(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool AdjustWindowRectEx(ref RECT rectangle, uint style, bool menu, uint extendedStyle);

    [DllImport("user32.dll")]
    private static extern IntPtr LoadCursor(IntPtr instance, IntPtr cursorName);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    private static extern bool UpdateWindow(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PeekMessage(out MSG message, IntPtr window, uint minimum, uint maximum, uint removeMessage);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG message);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG message);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr window, out RECT rectangle);
}
