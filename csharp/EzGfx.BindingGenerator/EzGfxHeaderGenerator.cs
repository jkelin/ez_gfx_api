#nullable enable

using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Text;

namespace EzGfx.BindingGenerator;

[Generator(LanguageNames.CSharp)]
public sealed class EzGfxHeaderGenerator : IIncrementalGenerator
{
    private static readonly DiagnosticDescriptor MissingHeader = new(
        "EZGFX001",
        "C ABI header is missing",
        "The ez_gfx C header was not supplied as an AdditionalFiles input",
        "EzGfx",
        DiagnosticSeverity.Error,
        isEnabledByDefault: true);

    private static readonly DiagnosticDescriptor InvalidHeader = new(
        "EZGFX002",
        "C ABI header cannot be parsed",
        "The ez_gfx C header could not be parsed: {0}",
        "EzGfx",
        DiagnosticSeverity.Error,
        isEnabledByDefault: true);

    public void Initialize(IncrementalGeneratorInitializationContext context)
    {
        IncrementalValueProvider<ImmutableArray<string?>> headers = context.AdditionalTextsProvider
            .Where(static file => string.Equals(Path.GetFileName(file.Path), "ez_gfx_api.h", StringComparison.OrdinalIgnoreCase))
            .Select(static (file, cancellationToken) => file.GetText(cancellationToken)?.ToString())
            .Collect();

        context.RegisterSourceOutput(headers, static (productionContext, values) =>
        {
            string? header = values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
            if (header is null)
            {
                productionContext.ReportDiagnostic(Diagnostic.Create(MissingHeader, Location.None));
                return;
            }

            try
            {
                HeaderModel model = HeaderParser.Parse(header);
                productionContext.AddSource("EzGfxNative.g.cs", SourceText.From(CSharpEmitter.Emit(model), Encoding.UTF8));
            }
            catch (Exception error)
            {
                productionContext.ReportDiagnostic(Diagnostic.Create(InvalidHeader, Location.None, error.Message));
            }
        });
    }

    private sealed class HeaderModel
    {
        public int AbiVersion { get; set; }
        public HashSet<string> Handles { get; } = new(StringComparer.Ordinal);
        public List<EnumModel> Enums { get; } = new();
        public List<StructModel> Structs { get; } = new();
        public List<FunctionModel> Functions { get; } = new();
    }

    private sealed class EnumModel
    {
        public string Name { get; set; } = string.Empty;
        public List<EnumValueModel> Values { get; } = new();
    }

    private sealed class EnumValueModel
    {
        public string Name { get; set; } = string.Empty;
        public int Value { get; set; }
    }

    private sealed class StructModel
    {
        public string Name { get; set; } = string.Empty;
        public List<FieldModel> Fields { get; } = new();
    }

    private sealed class FieldModel
    {
        public string Type { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
    }

    private sealed class FunctionModel
    {
        public string ReturnType { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public List<ParameterModel> Parameters { get; } = new();
    }

    private sealed class ParameterModel
    {
        public string Type { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
    }

    private static class HeaderParser
    {
        private static readonly Regex AbiRegex = new(
            @"#define\s+EZ_GFX_ABI_VERSION\s+(?<value>\d+)",
            RegexOptions.Compiled);

        private static readonly Regex HandleRegex = new(
            @"typedef\s+uint64_t\s+(?<name>EzGfx[A-Za-z0-9_]+)\s*;",
            RegexOptions.Compiled);

        private static readonly Regex EnumRegex = new(
            @"typedef\s+enum\s+(?<name>EzGfx[A-Za-z0-9_]+)\s*\{(?<body>.*?)\}\s*(?<alias>EzGfx[A-Za-z0-9_]+)\s*;",
            RegexOptions.Compiled | RegexOptions.Singleline);

        private static readonly Regex StructRegex = new(
            @"typedef\s+struct\s+(?<name>EzGfx[A-Za-z0-9_]+)\s*\{(?<body>.*?)\}\s*(?<alias>EzGfx[A-Za-z0-9_]+)\s*;",
            RegexOptions.Compiled | RegexOptions.Singleline);

        private static readonly Regex FunctionRegex = new(
            @"(?m)^\s*(?<return>[A-Za-z_][A-Za-z0-9_\s]*?)\s+(?<name>ez_gfx_[A-Za-z0-9_]+)\s*\((?<parameters>[^;]*)\)\s*;",
            RegexOptions.Compiled);

        public static HeaderModel Parse(string source)
        {
            string withoutBlockComments = Regex.Replace(source, @"/\*.*?\*/", string.Empty, RegexOptions.Singleline);
            string withoutComments = Regex.Replace(withoutBlockComments, @"//[^\r\n]*", string.Empty);
            Match abi = AbiRegex.Match(withoutComments);
            if (!abi.Success || !int.TryParse(abi.Groups["value"].Value, out int abiVersion))
            {
                throw new InvalidDataException("EZ_GFX_ABI_VERSION is missing");
            }

            HeaderModel model = new() { AbiVersion = abiVersion };
            foreach (Match handle in HandleRegex.Matches(withoutComments))
            {
                model.Handles.Add(handle.Groups["name"].Value);
            }

            foreach (Match match in EnumRegex.Matches(withoutComments))
            {
                string name = match.Groups["name"].Value;
                string alias = match.Groups["alias"].Value;
                if (!string.Equals(name, alias, StringComparison.Ordinal))
                {
                    throw new InvalidDataException($"enum alias {alias} does not match {name}");
                }

                EnumModel enumModel = new() { Name = name };
                foreach (Match value in Regex.Matches(match.Groups["body"].Value, @"(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>-?\d+)"))
                {
                    enumModel.Values.Add(new EnumValueModel
                    {
                        Name = value.Groups["name"].Value,
                        Value = int.Parse(value.Groups["value"].Value),
                    });
                }
                if (enumModel.Values.Count == 0)
                {
                    throw new InvalidDataException($"enum {name} has no explicit values");
                }
                model.Enums.Add(enumModel);
            }

            foreach (Match match in StructRegex.Matches(withoutComments))
            {
                string name = match.Groups["name"].Value;
                string alias = match.Groups["alias"].Value;
                if (!string.Equals(name, alias, StringComparison.Ordinal))
                {
                    throw new InvalidDataException($"struct alias {alias} does not match {name}");
                }

                StructModel structModel = new() { Name = name };
                foreach (string rawLine in match.Groups["body"].Value.Split('\n'))
                {
                    string line = rawLine.Trim().TrimEnd('\r');
                    if (line.Length == 0)
                    {
                        continue;
                    }
                    string declaration = line.EndsWith(";", StringComparison.Ordinal)
                        ? line.Substring(0, line.Length - 1).Trim()
                        : string.Empty;
                    int separator = declaration.LastIndexOf(' ');
                    if (separator <= 0 || separator == declaration.Length - 1)
                    {
                        throw new InvalidDataException($"struct {name} has an unsupported field declaration: {line}");
                    }
                    string type = declaration.Substring(0, separator).Trim();
                    string fieldName = declaration.Substring(separator + 1).Trim();
                    while (fieldName.StartsWith("*", StringComparison.Ordinal))
                    {
                        type += " *";
                        fieldName = fieldName.Substring(1).Trim();
                    }
                    if (!Regex.IsMatch(fieldName, @"^[A-Za-z_][A-Za-z0-9_]*$"))
                    {
                        throw new InvalidDataException($"struct {name} has an unsupported field declaration: {line}");
                    }
                    structModel.Fields.Add(new FieldModel
                    {
                        Type = Normalize(type),
                        Name = fieldName,
                    });
                }
                model.Structs.Add(structModel);
            }

            foreach (Match match in FunctionRegex.Matches(withoutComments))
            {
                FunctionModel function = new()
                {
                    ReturnType = Normalize(match.Groups["return"].Value),
                    Name = match.Groups["name"].Value,
                };
                string parameters = match.Groups["parameters"].Value.Trim();
                if (!string.Equals(parameters, "void", StringComparison.Ordinal))
                {
                    foreach (string parameterText in SplitParameters(parameters))
                    {
                        string declaration = parameterText.Trim();
                        int separator = declaration.LastIndexOf(' ');
                        if (separator <= 0 || separator == declaration.Length - 1)
                        {
                            throw new InvalidDataException($"function {function.Name} has an unsupported parameter: {parameterText}");
                        }
                        string type = declaration.Substring(0, separator).Trim();
                        string parameterName = declaration.Substring(separator + 1).Trim();
                        while (parameterName.StartsWith("*", StringComparison.Ordinal))
                        {
                            type += " *";
                            parameterName = parameterName.Substring(1).Trim();
                        }
                        if (!Regex.IsMatch(parameterName, @"^[A-Za-z_][A-Za-z0-9_]*$"))
                        {
                            throw new InvalidDataException($"function {function.Name} has an unsupported parameter: {parameterText}");
                        }
                        function.Parameters.Add(new ParameterModel
                        {
                            Type = Normalize(type),
                            Name = parameterName,
                        });
                    }
                }
                model.Functions.Add(function);
            }

            if (model.Functions.Count == 0)
            {
                throw new InvalidDataException("no ez_gfx_ function declarations were found");
            }
            return model;
        }

        private static string Normalize(string value) => Regex.Replace(value.Trim(), @"\s+", " ");

        private static IEnumerable<string> SplitParameters(string value)
        {
            int start = 0;
            int depth = 0;
            for (int index = 0; index < value.Length; index++)
            {
                switch (value[index])
                {
                    case '(':
                        depth++;
                        break;
                    case ')':
                        depth--;
                        break;
                    case ',' when depth == 0:
                        yield return value.Substring(start, index - start);
                        start = index + 1;
                        break;
                }
            }
            yield return value.Substring(start);
        }
    }

    private static class CSharpEmitter
    {
        private const int StackAllocationLimit = 16 * 1024;

        private static readonly Dictionary<string, string> PrimitiveTypes = new(StringComparer.Ordinal)
        {
            ["void"] = "void",
            ["uint32_t"] = "uint",
            ["int32_t"] = "int",
            ["uint64_t"] = "ulong",
            ["int64_t"] = "long",
            ["float"] = "float",
        };


        private static readonly HashSet<string> GeneratedConvenienceMethods = new(StringComparer.Ordinal)
        {
            "ez_gfx_c_context_create",
            "ez_gfx_c_surface_create",
            "ez_gfx_c_shader_compile",
            "ez_gfx_c_vertex_heap_create",
            "ez_gfx_c_index_heap_create",
            "ez_gfx_c_vertex_upload_indices",
            "ez_gfx_c_vertex_upload",
            "ez_gfx_c_texture_load",
            "ez_gfx_c_acquire_indirect",
            "ez_gfx_c_indirect_write_draw",
            "ez_gfx_c_structured_acquire",
            "ez_gfx_c_structured_write",
            "ez_gfx_c_render_add_vertex_pipeline",
            "ez_gfx_c_render_add_compute_pipeline",
            "ez_gfx_c_screenshot_save",
        };

        public static string Emit(HeaderModel model)
        {
            StringBuilder output = new();
            output.AppendLine("// <auto-generated />");
            output.AppendLine("// Generated by EzGfxHeaderGenerator from include/ez_gfx_api.h.");
            output.AppendLine("#nullable enable");
            output.AppendLine("using System;");
            output.AppendLine("using System.Buffers;");
            output.AppendLine("using System.Runtime.CompilerServices;");
            output.AppendLine("using System.Runtime.InteropServices;");
            output.AppendLine("using System.Text;");
            output.AppendLine();
            output.AppendLine("namespace EzGfx.Native;");
            output.AppendLine();

            foreach (EnumModel enumModel in model.Enums)
            {
                output.AppendLine($"public enum {enumModel.Name} : int");
                output.AppendLine("{");
                foreach (EnumValueModel value in enumModel.Values)
                {
                    string member = value.Name.StartsWith(enumModel.Name + "_", StringComparison.Ordinal)
                        ? value.Name.Substring(enumModel.Name.Length + 1)
                        : value.Name;
                    output.AppendLine($"    {member} = {value.Value},");
                }
                output.AppendLine("}");
                output.AppendLine();
            }

            foreach (StructModel structModel in model.Structs)
            {
                output.AppendLine("[StructLayout(LayoutKind.Sequential)]");
                output.AppendLine($"public struct {structModel.Name}");
                output.AppendLine("{");
                foreach (FieldModel field in structModel.Fields)
                {
                    output.AppendLine($"    public {StructFieldType(field.Type, model.Handles)} {ToPascal(field.Name)};");
                }
                output.AppendLine("}");
                output.AppendLine();
            }

            output.AppendLine("public interface IEzGfxBindingInput");
            output.AppendLine("{");
            output.AppendLine("    string Name { get; }");
            output.AppendLine("    ulong Structured { get; }");
            output.AppendLine("    ulong Indirect { get; }");
            output.AppendLine("}");
            output.AppendLine();
            output.AppendLine("public static unsafe partial class EzGfxNative");
            output.AppendLine("{");
            output.AppendLine($"    public const uint AbiVersion = {model.AbiVersion}u;");
            output.AppendLine("    public const string LibraryName = \"ez_gfx_native\";");
            output.AppendLine($"    private const int StackAllocationLimit = {StackAllocationLimit};");
            output.AppendLine();
            output.AppendLine("    private static int Utf8ByteCount(string? value)");
            output.AppendLine("    {");
            output.AppendLine("        return value is null ? 0 : checked(Encoding.UTF8.GetByteCount(value) + 1);");
            output.AppendLine("    }");
            output.AppendLine();
            output.AppendLine("    private static IntPtr PutUtf8(byte* storage, ref int offset, string? value)");
            output.AppendLine("    {");
            output.AppendLine("        if (value is null)");
            output.AppendLine("        {");
            output.AppendLine("            return IntPtr.Zero;");
            output.AppendLine("        }");
            output.AppendLine("        int byteCount = Encoding.UTF8.GetByteCount(value);");
            output.AppendLine("        IntPtr result = (IntPtr)(storage + offset);");
            output.AppendLine("        int written = Encoding.UTF8.GetBytes(value.AsSpan(), new Span<byte>(storage + offset, byteCount));");
            output.AppendLine("        storage[offset + written] = 0;");
            output.AppendLine("        offset += written + 1;");
            output.AppendLine("        return result;");
            output.AppendLine("    }");
            output.AppendLine();

            foreach (FunctionModel function in model.Functions)
            {
                string methodName = ToPascal(function.Name);
                output.AppendLine($"    [DllImport(LibraryName, EntryPoint = \"{function.Name}\", ExactSpelling = true)]");
                output.AppendLine("    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]");
                output.AppendLine($"    private static extern {ReturnType(function.ReturnType, model.Handles)} Raw{methodName}({string.Join(", ", function.Parameters.Select(parameter => RawParameterDeclaration(parameter, model.Handles)))});");
                output.AppendLine();
            }

            foreach (FunctionModel function in model.Functions)
            {
                if (GeneratedConvenienceMethods.Contains(function.Name))
                {
                    EmitConvenienceMethod(output, function);
                }
                else
                {
                    EmitForwardingMethod(output, function, model.Handles);
                }
            }

            output.AppendLine("}");
            return output.ToString();
        }

        private static void EmitForwardingMethod(StringBuilder output, FunctionModel function, HashSet<string> handleTypes)
        {
            string methodName = ToPascal(function.Name);
            output.AppendLine($"    public static {ReturnType(function.ReturnType, handleTypes)} {methodName}({string.Join(", ", function.Parameters.Select(parameter => RawParameterDeclaration(parameter, handleTypes)))})");
            output.AppendLine("        => Raw" + methodName + "(" + string.Join(", ", function.Parameters.Select(RawCallArgument)) + ");");
            output.AppendLine();
        }

        private static void EmitConvenienceMethod(StringBuilder output, FunctionModel function)
        {
            switch (function.Name)
            {
                case "ez_gfx_c_context_create":
                    EmitContextCreate(output);
                    break;
                case "ez_gfx_c_surface_create":
                    EmitSurfaceCreate(output);
                    break;
                case "ez_gfx_c_shader_compile":
                    EmitShaderCompile(output);
                    break;
                case "ez_gfx_c_vertex_heap_create":
                    EmitSingleStringCall(output, "EzGfxCVertexHeapCreate", "EzGfxResult", "ulong context, string name, ulong capacity, ulong stride", "context, {string}, capacity, stride", "name");
                    break;
                case "ez_gfx_c_index_heap_create":
                    EmitSingleStringCall(output, "EzGfxCIndexHeapCreate", "EzGfxResult", "ulong context, ulong capacity, string debugName", "context, capacity, {string}", "debugName");
                    break;
                case "ez_gfx_c_vertex_upload_indices":
                    EmitVertexUploadIndices(output);
                    break;
                case "ez_gfx_c_vertex_upload":
                    EmitVertexUpload(output);
                    break;
                case "ez_gfx_c_texture_load":
                    EmitTextureLoad(output);
                    break;
                case "ez_gfx_c_acquire_indirect":
                    EmitSingleStringCall(output, "EzGfxCAcquireIndirect", "EzGfxResult", "ulong context, uint capacity, string debugName, out ulong indirect", "context, capacity, {string}, out indirect", "debugName");
                    break;
                case "ez_gfx_c_indirect_write_draw":
                    EmitIndirectWriteDraw(output);
                    break;
                case "ez_gfx_c_structured_acquire":
                    EmitSingleStringCall(output, "EzGfxCStructuredAcquire", "EzGfxResult", "ulong context, uint elementSize, uint elementCount, string debugName, out ulong structured", "context, elementSize, elementCount, {string}, out structured", "debugName");
                    break;
                case "ez_gfx_c_structured_write":
                    EmitStructuredWrite(output);
                    break;
                case "ez_gfx_c_render_add_vertex_pipeline":
                    EmitRenderPipeline(output, vertex: true);
                    break;
                case "ez_gfx_c_render_add_compute_pipeline":
                    EmitRenderPipeline(output, vertex: false);
                    break;
                case "ez_gfx_c_screenshot_save":
                    EmitSingleStringCall(output, "EzGfxCScreenshotSave", "EzGfxResult", "ulong surface, string path", "surface, {string}", "path");
                    break;
                default:
                    throw new InvalidOperationException($"No convenience emitter for {function.Name}");
            }
        }

        private static void EmitContextCreate(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxCContextCreate(bool enableDebug, bool enableValidation, EzGfxSurfacePlatform surfacePlatform, out ulong context)");
            output.AppendLine("    {");
            output.AppendLine("        EzGfxContextDesc description = new()");
            output.AppendLine("        {");
            output.AppendLine("            EnableDebug = enableDebug ? 1 : 0,");
            output.AppendLine("            EnableValidation = enableValidation ? 1 : 0,");
            output.AppendLine("            SurfacePlatform = (uint)surfacePlatform,");
            output.AppendLine("        };");
            output.AppendLine("        return RawEzGfxCContextCreate((IntPtr)(&description), out context);");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitSurfaceCreate(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxCSurfaceCreate(ulong context, IntPtr window, IntPtr display, EzGfxSurfacePlatform platform, uint width, uint height, out ulong surface)");
            output.AppendLine("    {");
            output.AppendLine("        if (window == IntPtr.Zero || display == IntPtr.Zero || width == 0 || height == 0)");
            output.AppendLine("        {");
            output.AppendLine("            throw new ArgumentException(\"A non-zero parent window, display, width, and height are required.\");");
            output.AppendLine("        }");
            output.AppendLine("        EzGfxSurfaceDesc description = new()");
            output.AppendLine("        {");
            output.AppendLine("            Window = window,");
            output.AppendLine("            Display = display,");
            output.AppendLine("            Platform = (uint)platform,");
            output.AppendLine("            Width = width,");
            output.AppendLine("            Height = height,");
            output.AppendLine("        };");
            output.AppendLine("        return RawEzGfxCSurfaceCreate(context, (IntPtr)(&description), out surface);");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitShaderCompile(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxCShaderCompile(ulong context, string path, EzGfxShaderKind kind, string? vertexEntry, string? fragmentEntry, string? computeEntry, out ulong shader)");
            output.AppendLine("    {");
            output.AppendLine("        ArgumentException.ThrowIfNullOrWhiteSpace(path);");
            output.AppendLine("        int totalBytes = checked(Utf8ByteCount(path) + Utf8ByteCount(vertexEntry) + Utf8ByteCount(fragmentEntry) + Utf8ByteCount(computeEntry));");
            EmitStorageSetup(output, "totalBytes", "storage", "rented");
            output.AppendLine("        try");
            output.AppendLine("        {");
            output.AppendLine("            fixed (byte* utf8 = storage)");
            output.AppendLine("            {");
            output.AppendLine("                int offset = 0;");
            output.AppendLine("                EzGfxShaderDesc description = new()");
            output.AppendLine("                {");
            output.AppendLine("                    Path = PutUtf8(utf8, ref offset, path),");
            output.AppendLine("                    VertexEntry = PutUtf8(utf8, ref offset, vertexEntry),");
            output.AppendLine("                    FragmentEntry = PutUtf8(utf8, ref offset, fragmentEntry),");
            output.AppendLine("                    ComputeEntry = PutUtf8(utf8, ref offset, computeEntry),");
            output.AppendLine("                    Kind = (uint)kind,");
            output.AppendLine("                };");
            output.AppendLine("                return RawEzGfxCShaderCompile(context, (IntPtr)(&description), out shader);");
            output.AppendLine("            }");
            output.AppendLine("        }");
            output.AppendLine("        finally");
            output.AppendLine("        {");
            output.AppendLine("            if (rented is not null) ArrayPool<byte>.Shared.Return(rented);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitVertexUploadIndices(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxCVertexUploadIndices(ulong context, ReadOnlySpan<uint> data, out uint startIndex)");
            output.AppendLine("    {");
            output.AppendLine("        if (data.IsEmpty) throw new ArgumentException(\"Index data must not be empty.\", nameof(data));");
            output.AppendLine("        fixed (uint* pointer = data)");
            output.AppendLine("        {");
            output.AppendLine("            return RawEzGfxCVertexUploadIndices(context, (IntPtr)pointer, checked((uint)data.Length), out startIndex);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitVertexUpload(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxCVertexUpload(ulong context, string heapName, ReadOnlySpan<byte> data, uint elementCount, ulong elementSize, out uint startIndex)");
            output.AppendLine("    {");
            output.AppendLine("        ArgumentException.ThrowIfNullOrWhiteSpace(heapName);");
            output.AppendLine("        if (data.IsEmpty) throw new ArgumentException(\"Vertex data must not be empty.\", nameof(data));");
            output.AppendLine("        int totalBytes = Utf8ByteCount(heapName);");
            EmitStorageSetup(output, "totalBytes", "storage", "rented");
            output.AppendLine("        try");
            output.AppendLine("        {");
            output.AppendLine("            fixed (byte* utf8 = storage)");
            output.AppendLine("            fixed (byte* dataPointer = data)");
            output.AppendLine("            {");
            output.AppendLine("                int offset = 0;");
            output.AppendLine("                return RawEzGfxCVertexUpload(context, PutUtf8(utf8, ref offset, heapName), (IntPtr)dataPointer, elementCount, elementSize, out startIndex);");
            output.AppendLine("            }");
            output.AppendLine("        }");
            output.AppendLine("        finally");
            output.AppendLine("        {");
            output.AppendLine("            if (rented is not null) ArrayPool<byte>.Shared.Return(rented);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitTextureLoad(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxTextureError EzGfxCTextureLoad(ulong context, ReadOnlySpan<byte> data, uint sourceFormat, uint destinationFormat, uint width, uint height, uint mipCount, bool generateMips, EzGfxTextureFilter minFilter, EzGfxTextureFilter magFilter, float maxAnisotropy, EzGfxTextureAddressMode addressModeU, EzGfxTextureAddressMode addressModeV, EzGfxTextureAddressMode addressModeW, string? debugLabel, out uint textureId)");
            output.AppendLine("    {");
            output.AppendLine("        if (data.IsEmpty) throw new ArgumentException(\"Texture data must not be empty.\", nameof(data));");
            output.AppendLine("        int totalBytes = Utf8ByteCount(debugLabel);");
            EmitStorageSetup(output, "totalBytes", "storage", "rented");
            output.AppendLine("        try");
            output.AppendLine("        {");
            output.AppendLine("            fixed (byte* utf8 = storage)");
            output.AppendLine("            fixed (byte* dataPointer = data)");
            output.AppendLine("            {");
            output.AppendLine("                int offset = 0;");
            output.AppendLine("                EzGfxTextureDesc description = new()");
            output.AppendLine("                {");
            output.AppendLine("                    SourceFormat = sourceFormat,");
            output.AppendLine("                    DestinationFormat = destinationFormat,");
            output.AppendLine("                    Width = width,");
            output.AppendLine("                    Height = height,");
            output.AppendLine("                    MipCount = mipCount,");
            output.AppendLine("                    GenerateMips = generateMips ? 1 : 0,");
            output.AppendLine("                    MinFilter = (uint)minFilter,");
            output.AppendLine("                    MagFilter = (uint)magFilter,");
            output.AppendLine("                    MaxAnisotropy = maxAnisotropy,");
            output.AppendLine("                    AddressModeU = (uint)addressModeU,");
            output.AppendLine("                    AddressModeV = (uint)addressModeV,");
            output.AppendLine("                    AddressModeW = (uint)addressModeW,");
            output.AppendLine("                    DebugLabel = PutUtf8(utf8, ref offset, debugLabel),");
            output.AppendLine("                };");
            output.AppendLine("                return (EzGfxTextureError)RawEzGfxCTextureLoad(context, (IntPtr)dataPointer, checked((ulong)data.Length), (IntPtr)(&description), out textureId);");
            output.AppendLine("            }");
            output.AppendLine("        }");
            output.AppendLine("        finally");
            output.AppendLine("        {");
            output.AppendLine("            if (rented is not null) ArrayPool<byte>.Shared.Return(rented);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitIndirectWriteDraw(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxCIndirectWriteDraw(ulong indirect, uint index, uint indexCount, uint instanceCount, uint firstIndex, int vertexOffset, uint firstInstance)");
            output.AppendLine("    {");
            output.AppendLine("        EzGfxDrawIndexedCommand command = new()");
            output.AppendLine("        {");
            output.AppendLine("            IndexCount = indexCount,");
            output.AppendLine("            InstanceCount = instanceCount,");
            output.AppendLine("            FirstIndex = firstIndex,");
            output.AppendLine("            VertexOffset = vertexOffset,");
            output.AppendLine("            FirstInstance = firstInstance,");
            output.AppendLine("        };");
            output.AppendLine("        return RawEzGfxCIndirectWriteDraw(indirect, index, (IntPtr)(&command));");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitStructuredWrite(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxCStructuredWrite(ulong structured, ReadOnlySpan<byte> data)");
            output.AppendLine("    {");
            output.AppendLine("        if (data.IsEmpty) throw new ArgumentException(\"Structured data must not be empty.\", nameof(data));");
            output.AppendLine("        fixed (byte* pointer = data)");
            output.AppendLine("        {");
            output.AppendLine("            return RawEzGfxCStructuredWrite(structured, (IntPtr)pointer, checked((ulong)data.Length));");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitRenderPipeline(StringBuilder output, bool vertex)
        {
            string methodName = vertex ? "EzGfxCRenderAddVertexPipeline" : "EzGfxCRenderAddComputePipeline";
            string parameters = vertex
                ? "ulong shader, ulong indirect, ReadOnlySpan<TBinding> bindings, uint cullMode, uint frontFace, uint primitiveType, uint blendMode, ReadOnlySpan<byte> pushConstants"
                : "ulong shader, uint dispatchX, uint dispatchY, uint dispatchZ, ReadOnlySpan<TBinding> bindings, ReadOnlySpan<byte> pushConstants";
            output.AppendLine($"    public static EzGfxResult {methodName}<TBinding>({parameters}) where TBinding : IEzGfxBindingInput");
            output.AppendLine("    {");
            output.AppendLine("        if (bindings.Length > 16) throw new ArgumentException(\"Too many render bindings.\", nameof(bindings));");
            output.AppendLine("        if (pushConstants.Length > 128) throw new ArgumentException(\"Push constants exceed the native limit.\", nameof(pushConstants));");
            output.AppendLine("        int totalBytes = 0;");
            output.AppendLine("        foreach (TBinding binding in bindings)");
            output.AppendLine("        {");
            output.AppendLine("            ArgumentException.ThrowIfNullOrWhiteSpace(binding.Name);");
            output.AppendLine("            totalBytes = checked(totalBytes + Utf8ByteCount(binding.Name));");
            output.AppendLine("        }");
            EmitStorageSetup(output, "totalBytes", "storage", "rented");
            output.AppendLine("        Span<EzGfxBinding> nativeBindings = bindings.Length == 0 ? Span<EzGfxBinding>.Empty : stackalloc EzGfxBinding[bindings.Length];");
            output.AppendLine("        EzGfxDynamicState dynamicState = new()");
            output.AppendLine("        {");
            if (vertex)
            {
                output.AppendLine("            CullMode = cullMode,");
                output.AppendLine("            FrontFace = frontFace,");
                output.AppendLine("            PrimitiveType = primitiveType,");
                output.AppendLine("            BlendMode = blendMode,");
            }
            output.AppendLine("        };");
            output.AppendLine("        try");
            output.AppendLine("        {");
            output.AppendLine("            fixed (byte* utf8 = storage)");
            output.AppendLine("            fixed (EzGfxBinding* bindingPointer = nativeBindings)");
            output.AppendLine("            fixed (byte* pushPointer = pushConstants)");
            output.AppendLine("            {");
            output.AppendLine("                int offset = 0;");
            output.AppendLine("                for (int index = 0; index < bindings.Length; index++)");
            output.AppendLine("                {");
            output.AppendLine("                    TBinding binding = bindings[index];");
            output.AppendLine("                    nativeBindings[index] = new EzGfxBinding");
            output.AppendLine("                    {");
            output.AppendLine("                        Name = PutUtf8(utf8, ref offset, binding.Name),");
            output.AppendLine("                        Structured = binding.Structured,");
            output.AppendLine("                        Indirect = binding.Indirect,");
            output.AppendLine("                    };");
            output.AppendLine("                }");
            output.AppendLine("                IntPtr bindingAddress = bindings.Length == 0 ? IntPtr.Zero : (IntPtr)bindingPointer;");
            output.AppendLine("                IntPtr pushAddress = pushConstants.Length == 0 ? IntPtr.Zero : (IntPtr)pushPointer;");
            if (vertex)
            {
                output.AppendLine($"                return Raw{methodName}(shader, indirect, bindingAddress, checked((uint)bindings.Length), (IntPtr)(&dynamicState), pushAddress, checked((uint)pushConstants.Length));");
            }
            else
            {
                output.AppendLine($"                return Raw{methodName}(shader, dispatchX, dispatchY, dispatchZ, bindingAddress, checked((uint)bindings.Length), pushAddress, checked((uint)pushConstants.Length));");
            }
            output.AppendLine("            }");
            output.AppendLine("        }");
            output.AppendLine("        finally");
            output.AppendLine("        {");
            output.AppendLine("            if (rented is not null) ArrayPool<byte>.Shared.Return(rented);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitSingleStringCall(StringBuilder output, string methodName, string returnType, string parameters, string rawArguments, string stringParameter)
        {
            output.AppendLine($"    public static {returnType} {methodName}({parameters})");
            output.AppendLine("    {");
            output.AppendLine($"        ArgumentException.ThrowIfNullOrWhiteSpace({stringParameter});");
            output.AppendLine($"        int totalBytes = Utf8ByteCount({stringParameter});");
            EmitStorageSetup(output, "totalBytes", "storage", "rented");
            output.AppendLine("        try");
            output.AppendLine("        {");
            output.AppendLine("            fixed (byte* utf8 = storage)");
            output.AppendLine("            {");
            output.AppendLine("                int offset = 0;");
            string methodRawName = "Raw" + methodName;
            string encodedString = "PutUtf8(utf8, ref offset, " + stringParameter + ")";
            string callArguments = rawArguments.Replace("{string}", encodedString);
            output.AppendLine($"                return {methodRawName}({callArguments});");
            output.AppendLine("            }");
            output.AppendLine("        }");
            output.AppendLine("        finally");
            output.AppendLine("        {");
            output.AppendLine("            if (rented is not null) ArrayPool<byte>.Shared.Return(rented);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitStorageSetup(StringBuilder output, string totalExpression, string storageName, string rentedName)
        {
            output.AppendLine($"        byte[]? {rentedName} = null;");
            output.AppendLine($"        scoped Span<byte> {storageName};");
            output.AppendLine($"        if ({totalExpression} <= StackAllocationLimit)");
            output.AppendLine("        {");
            output.AppendLine($"            {storageName} = stackalloc byte[{totalExpression}];");
            output.AppendLine("        }");
            output.AppendLine("        else");
            output.AppendLine("        {");
            output.AppendLine($"            {rentedName} = ArrayPool<byte>.Shared.Rent({totalExpression});");
            output.AppendLine($"            {storageName} = {rentedName}.AsSpan(0, {totalExpression});");
            output.AppendLine("        }");
        }

        private static string StructFieldType(string type, HashSet<string> handleTypes)
        {
            if (type.IndexOf('*') >= 0)
            {
                return "IntPtr";
            }
            return CSharpType(type, handleTypes);
        }

        private static string ReturnType(string type, HashSet<string> handleTypes) => CSharpType(type, handleTypes);

        private static string CSharpType(string type, HashSet<string> handleTypes)
        {
            if (handleTypes.Contains(type))
            {
                return "ulong";
            }
            return PrimitiveTypes.TryGetValue(type, out string? primitive) ? primitive : type;
        }

        private static string RawParameterDeclaration(ParameterModel parameter, HashSet<string> handleTypes)
        {
            string name = ToPascal(parameter.Name);
            if (parameter.Type.IndexOf('*') < 0)
            {
                return $"{CSharpType(parameter.Type, handleTypes)} {name}";
            }
            string baseType = parameter.Type.Replace("const", string.Empty).Replace("*", string.Empty).Trim();
            if (parameter.Name.StartsWith("out_", StringComparison.Ordinal))
            {
                return $"out {CSharpType(baseType, handleTypes)} {name}";
            }
            return $"IntPtr {name}";
        }

        private static string RawCallArgument(ParameterModel parameter)
        {
            string name = ToPascal(parameter.Name);
            return parameter.Name.StartsWith("out_", StringComparison.Ordinal) ? "out " + name : name;
        }

        private static string ToPascal(string value) =>
            string.Concat(value.Split('_').Select(part => part.Length == 0 ? string.Empty : char.ToUpperInvariant(part[0]) + (part.Length > 1 ? part.Substring(1) : string.Empty)));
    }
}
