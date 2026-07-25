using System.Buffers.Binary;
using System.Reflection;
using System.Runtime.InteropServices;

namespace EzGfx.Native;

public static class EzGfxNativeLoader
{
    private static readonly object Sync = new();
    private static IntPtr _library;
    private static string? _resolvedPath;

    static EzGfxNativeLoader()
    {
        NativeLibrary.SetDllImportResolver(typeof(EzGfxNative).Assembly, Resolve);
    }

    public static string ResolvedPath => _resolvedPath ?? throw new InvalidOperationException("The ez_gfx native library has not been loaded.");

    public static void EnsureLoaded()
    {
        lock (Sync)
        {
            if (_library != IntPtr.Zero)
            {
                return;
            }

            string[] candidates = CandidatePaths();
            List<string> failures = new();
            foreach (string candidate in candidates)
            {
                try
                {
                    if (!Path.IsPathRooted(candidate) && !File.Exists(candidate))
                    {
                        continue;
                    }

                    ValidateCandidate(candidate);
                    _library = NativeLibrary.Load(candidate);
                    _resolvedPath = Path.GetFullPath(candidate);
                    return;
                }
                catch (Exception error) when (error is DllNotFoundException or BadImageFormatException or FileLoadException or IOException or UnauthorizedAccessException)
                {
                    failures.Add($"{candidate}: {error.Message}");
                }
            }

            string attempted = candidates.Length == 0 ? "(none)" : string.Join(Environment.NewLine, candidates);
            string detail = failures.Count == 0 ? string.Empty : Environment.NewLine + string.Join(Environment.NewLine, failures);
            throw new DllNotFoundException(
                $"Unable to load the ez_gfx native DLL. Set EZ_GFX_NATIVE_DLL to an x64 DLL path or build out/ez_gfx_native.dll. Attempted:{Environment.NewLine}{attempted}{detail}");
        }
    }

    public static void VerifyAbi()
    {
        EnsureLoaded();
        uint nativeVersion = EzGfxNative.EzGfxCAbiVersion();
        if (nativeVersion != EzGfxNative.AbiVersion)
        {
            throw new InvalidOperationException($"ez_gfx ABI mismatch: native={nativeVersion}, managed={EzGfxNative.AbiVersion}, path={ResolvedPath}");
        }
    }

    private static void ValidateCandidate(string candidate)
    {
        if (!Environment.Is64BitProcess || RuntimeInformation.ProcessArchitecture != Architecture.X64)
        {
            throw new PlatformNotSupportedException("ez_gfx requires an x64 .NET process.");
        }

        ValidatePeImage(candidate, "ez_gfx native DLL");
        string? nativeDirectory = Path.GetDirectoryName(candidate);
        string? slangPath = FindDependency("slang.dll", nativeDirectory);
        if (slangPath is null)
        {
            throw new DllNotFoundException(
                $"The Odin shader runtime slang.dll was not found beside {candidate} or on PATH.");
        }
        ValidatePeImage(slangPath, "Odin shader runtime slang.dll");
    }

    private static void ValidatePeImage(string path, string description)
    {
        using FileStream stream = File.OpenRead(path);
        Span<byte> dosHeader = stackalloc byte[64];
        if (stream.Read(dosHeader) != dosHeader.Length ||
            dosHeader[0] != (byte)'M' ||
            dosHeader[1] != (byte)'Z')
        {
            throw new BadImageFormatException($"{description} is not a valid PE image: {path}");
        }

        int peOffset = BinaryPrimitives.ReadInt32LittleEndian(dosHeader[0x3c..]);
        if (peOffset < 0 || peOffset > stream.Length - 6)
        {
            throw new BadImageFormatException($"{description} has an invalid PE header offset: {path}");
        }

        stream.Position = peOffset;
        Span<byte> peHeader = stackalloc byte[6];
        if (stream.Read(peHeader) != peHeader.Length ||
            peHeader[0] != (byte)'P' ||
            peHeader[1] != (byte)'E' ||
            peHeader[2] != 0 ||
            peHeader[3] != 0)
        {
            throw new BadImageFormatException($"{description} is not a valid PE image: {path}");
        }

        const ushort ImageFileMachineAmd64 = 0x8664;
        ushort machine = BinaryPrimitives.ReadUInt16LittleEndian(peHeader[4..]);
        if (machine != ImageFileMachineAmd64)
        {
            throw new BadImageFormatException($"{description} is not x64 (machine 0x{machine:X4}): {path}");
        }
    }

    private static string? FindDependency(string fileName, string? nativeDirectory)
    {
        if (!string.IsNullOrWhiteSpace(nativeDirectory))
        {
            string sibling = Path.Combine(nativeDirectory, fileName);
            if (File.Exists(sibling))
            {
                return sibling;
            }
        }

        string? path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        foreach (string directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(directory, fileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return null;
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, EzGfxNative.LibraryName, StringComparison.Ordinal))
        {
            return IntPtr.Zero;
        }

        EnsureLoaded();
        return _library;
    }

    private static string[] CandidatePaths()
    {
        string? configured = Environment.GetEnvironmentVariable("EZ_GFX_NATIVE_DLL");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return new[] { Path.GetFullPath(configured) };
        }

        string root = FindRepositoryRoot(AppContext.BaseDirectory);
        return new[]
        {
            Path.Combine(root, "out", "ez_gfx_native.dll"),
            Path.Combine(root, "build", "native", "ez_gfx.dll"),
            Path.Combine(AppContext.BaseDirectory, "ez_gfx_native.dll"),
        };
    }

    private static string FindRepositoryRoot(string start)
    {
        DirectoryInfo? directory = new(start);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Justfile")) &&
                Directory.Exists(Path.Combine(directory.FullName, "src")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        return start;
    }
}
