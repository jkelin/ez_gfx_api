#nullable enable

using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Text;

namespace EzGfx.BindingGenerator;

[Generator(LanguageNames.CSharp)]
public sealed class EzGfxHeaderGenerator : IIncrementalGenerator
{
    private static readonly DiagnosticDescriptor MissingBindings = new(
        "EZGFX001",
        "XML bindings are missing",
        "bindings.xml was not supplied as an AdditionalFiles input",
        "EzGfx",
        DiagnosticSeverity.Error,
        isEnabledByDefault: true);

    private static readonly DiagnosticDescriptor InvalidBindings = new(
        "EZGFX002",
        "XML bindings cannot be parsed",
        "The ez_gfx XML bindings could not be parsed: {0}",
        "EzGfx",
        DiagnosticSeverity.Error,
        isEnabledByDefault: true);

    public void Initialize(IncrementalGeneratorInitializationContext context)
    {
        IncrementalValueProvider<ImmutableArray<string?>> bindings = context.AdditionalTextsProvider
            .Where(static file => string.Equals(Path.GetFileName(file.Path), "bindings.xml", StringComparison.OrdinalIgnoreCase))
            .Select(static (file, cancellationToken) => file.GetText(cancellationToken)?.ToString())
            .Collect();

        context.RegisterSourceOutput(bindings, static (productionContext, values) =>
        {
            string? source = values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
            if (source is null)
            {
                productionContext.ReportDiagnostic(Diagnostic.Create(MissingBindings, Location.None));
                return;
            }

            try
            {
                HeaderModel model = BindingXmlParser.Parse(source);
                productionContext.AddSource("EzGfxNative.g.cs", SourceText.From(CSharpEmitter.Emit(model), Encoding.UTF8));
            }
            catch (Exception error)
            {
                productionContext.ReportDiagnostic(Diagnostic.Create(InvalidBindings, Location.None, error.Message));
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
        public string Doc { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string Underlying { get; set; } = string.Empty;
        public List<EnumValueModel> Values { get; } = new();
    }

    private sealed class EnumValueModel
    {
        public string Name { get; set; } = string.Empty;
        public int Value { get; set; }
        public string Doc { get; set; } = string.Empty;
    }

    private sealed class StructModel
    {
        public string Name { get; set; } = string.Empty;
        public List<FieldModel> Fields { get; } = new();
        public string Doc { get; set; } = string.Empty;
    }
    private sealed class FieldModel
    {
        public string Type { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string Doc { get; set; } = string.Empty;
        public string Validation { get; set; } = string.Empty;
        public string CountedBy { get; set; } = string.Empty;
        public string Nullable { get; set; } = string.Empty;
    }
    private sealed class FunctionModel
    {
        public string ReturnType { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string Doc { get; set; } = string.Empty;
        public string Context { get; set; } = string.Empty;
        public string Managed { get; set; } = string.Empty;
        public List<ParameterModel> Parameters { get; } = new();
    }
    private sealed class ParameterModel
    {
        public string Type { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string Doc { get; set; } = string.Empty;
        public string Direction { get; set; } = string.Empty;
        public string Validation { get; set; } = string.Empty;
        public string ArrayLength { get; set; } = string.Empty;
        public string ArrayByteSize { get; set; } = string.Empty;
        public string Nullable { get; set; } = string.Empty;
    }

    private static class BindingXmlParser
    {
        public static HeaderModel Parse(string source)
        {
            XDocument document = XDocument.Parse(source, LoadOptions.PreserveWhitespace);
            XElement root = document.Root ?? throw new InvalidDataException("XML bindings have no root element");
            if (!string.Equals(root.Name.LocalName, "ez-gfx-bindings", StringComparison.Ordinal))
            {
                throw new InvalidDataException("XML bindings root must be ez-gfx-bindings");
            }

            HeaderModel model = new()
            {
                AbiVersion = ParseInt(root, "abi-version"),
            };

            XElement handles = RequiredChild(root, "handles");
            foreach (XElement handle in handles.Elements("handle"))
            {
                string handleName = RequiredAttribute(handle, "name");
                if (!model.Handles.Add(handleName))
                {
                    throw new InvalidDataException($"duplicate handle {handleName}");
                }
            }

            XElement enums = RequiredChild(root, "enums");
            foreach (XElement enumElement in enums.Elements("enum"))
            {
                EnumModel enumModel = new()
                {
                    Name = RequiredAttribute(enumElement, "name"),
                    Underlying = RequiredAttribute(enumElement, "underlying"),
                    Doc = OptionalAttribute(enumElement, "doc"),
                };
                foreach (XElement value in enumElement.Elements("value"))
                {
                    enumModel.Values.Add(new EnumValueModel
                    {
                        Name = RequiredAttribute(value, "name"),
                        Value = ParseInt(value, "value"),
                        Doc = OptionalAttribute(value, "doc"),
                    });
                }
                if (enumModel.Values.Count == 0)
                {
                    throw new InvalidDataException($"enum {enumModel.Name} has no values");
                }
                model.Enums.Add(enumModel);
            }

            XElement structs = RequiredChild(root, "structs");
            foreach (XElement structElement in structs.Elements("struct"))
            {
                StructModel structModel = new()
                {
                    Name = RequiredAttribute(structElement, "name"),
                    Doc = OptionalAttribute(structElement, "doc"),
                };
                foreach (XElement field in structElement.Elements("field"))
                {
                    structModel.Fields.Add(new FieldModel
                    {
                        Type = Normalize(RequiredAttribute(field, "type")),
                        Name = RequiredAttribute(field, "name"),
                        Doc = OptionalAttribute(field, "doc"),
                        Validation = OptionalAttribute(field, "validation"),
                        CountedBy = OptionalAttribute(field, "counted-by"),
                        Nullable = OptionalAttribute(field, "nullable"),
                    });
                }
                model.Structs.Add(structModel);
            }

            XElement functions = RequiredChild(root, "functions");
            foreach (XElement functionElement in functions.Elements("function"))
            {
                FunctionModel function = new()
                {
                    ReturnType = Normalize(RequiredAttribute(functionElement, "return")),
                    Name = RequiredAttribute(functionElement, "name"),
                    Doc = OptionalAttribute(functionElement, "doc"),
                    Context = OptionalAttribute(functionElement, "context"),
                    Managed = OptionalAttribute(functionElement, "managed"),
                };
                foreach (XElement parameter in functionElement.Elements("param"))
                {
                    function.Parameters.Add(new ParameterModel
                    {
                        Type = Normalize(RequiredAttribute(parameter, "type")),
                        Name = RequiredAttribute(parameter, "name"),
                        Doc = OptionalAttribute(parameter, "doc"),
                        Direction = OptionalAttribute(parameter, "direction"),
                        Validation = OptionalAttribute(parameter, "validation"),
                        ArrayLength = OptionalAttribute(parameter, "array-length"),
                        ArrayByteSize = OptionalAttribute(parameter, "array-byte-size"),
                        Nullable = OptionalAttribute(parameter, "nullable"),
                    });
                }
                model.Functions.Add(function);
            }

            if (model.Functions.Count == 0)
            {
                throw new InvalidDataException("XML bindings contain no functions");
            }
            Validate(model);
            return model;
        }

        private static void Validate(HeaderModel model)
        {
            ValidateUnique(model.Enums.Select(enumModel => enumModel.Name), "enum");
            ValidateUnique(model.Structs.Select(structModel => structModel.Name), "struct");
            ValidateUnique(model.Functions.Select(function => function.Name), "function");
            foreach (EnumModel enumModel in model.Enums)
            {
                ValidateUnique(enumModel.Values.Select(value => value.Name), $"enum {enumModel.Name} value");
            }
            foreach (StructModel structModel in model.Structs)
            {
                ValidateUnique(structModel.Fields.Select(field => field.Name), $"struct {structModel.Name} field");
                foreach (FieldModel field in structModel.Fields)
                {
                    ValidateMetadata(field.Validation, $"struct {structModel.Name}.{field.Name}");
                    if (!string.IsNullOrEmpty(field.CountedBy) &&
                        !structModel.Fields.Any(candidate => candidate.Name == field.CountedBy))
                    {
                        throw new InvalidDataException($"struct {structModel.Name}.{field.Name} counted-by references missing field {field.CountedBy}");
                    }
                }
            }
            foreach (FunctionModel function in model.Functions)
            {
                ValidateManagedShape(function);
                if (!string.IsNullOrEmpty(function.Context) &&
                    !string.Equals(function.Context, "last", StringComparison.Ordinal))
                {
                    throw new InvalidDataException($"function {function.Name} has unsupported context placement {function.Context}");
                }
                if (string.Equals(function.Context, "last", StringComparison.Ordinal) &&
                    (function.Parameters.Count == 0 ||
                     function.Parameters[function.Parameters.Count - 1].Name != "context"))
                {
                    throw new InvalidDataException($"function {function.Name} must place context as its final parameter");
                }
                ValidateUnique(function.Parameters.Select(parameter => parameter.Name), $"function {function.Name} parameter");
                HashSet<string> parameters = new HashSet<string>(
                    function.Parameters.Select(parameter => parameter.Name),
                    StringComparer.Ordinal);
                foreach (ParameterModel parameter in function.Parameters)
                {
                    ValidateMetadata(parameter.Validation, $"function {function.Name}.{parameter.Name}");
                    if (!string.IsNullOrEmpty(parameter.ArrayByteSize) &&
                        string.IsNullOrEmpty(parameter.ArrayLength))
                    {
                        throw new InvalidDataException($"function {function.Name}.{parameter.Name} array-byte-size requires array-length");
                    }
                    if (!string.IsNullOrEmpty(parameter.ArrayLength) &&
                        !parameters.Contains(parameter.ArrayLength))
                    {
                        throw new InvalidDataException($"function {function.Name}.{parameter.Name} array-length references missing parameter {parameter.ArrayLength}");
                    }
                    if (!string.IsNullOrEmpty(parameter.ArrayByteSize) &&
                        !parameters.Contains(parameter.ArrayByteSize))
                    {
                        throw new InvalidDataException($"function {function.Name}.{parameter.Name} array-byte-size references missing parameter {parameter.ArrayByteSize}");
                    }
                }
            }
        }

        private static void ValidateManagedShape(FunctionModel function)
        {
            if (string.IsNullOrEmpty(function.Managed))
            {
                return;
            }
            switch (function.Managed)
            {
                case "context-create":
                case "surface-create":
                case "shader-compile":
                case "utf8-string":
                case "vertex-upload-indices":
                case "vertex-upload":
                case "texture-load":
                case "draw-command":
                case "structured-write":
                case "vertex-pipeline":
                case "compute-pipeline":
                    return;
                default:
                    throw new InvalidDataException($"function {function.Name} has unsupported managed shape {function.Managed}");
            }
        }

        private static void ValidateMetadata(string validation, string owner)
        {
            if (string.IsNullOrEmpty(validation) || validation == "non-negative" ||
                validation == "greater-than-zero" || validation == "zero-or-one" ||
                validation == "not-empty")
            {
                return;
            }
            if (validation.StartsWith("at-most-", StringComparison.Ordinal) &&
                int.TryParse(validation.Substring("at-most-".Length), out int limit) &&
                limit >= 0)
            {
                return;
            }
            throw new InvalidDataException($"{owner} has unsupported validation metadata {validation}");
        }

        private static void ValidateUnique(IEnumerable<string> values, string kind)
        {
            HashSet<string> seen = new(StringComparer.Ordinal);
            foreach (string value in values)
            {
                if (!seen.Add(value))
                {
                    throw new InvalidDataException($"duplicate {kind} {value}");
                }
            }
        }


        private static XElement RequiredChild(XElement parent, string name) =>
            parent.Element(name) ?? throw new InvalidDataException($"missing {name} section");

        private static string RequiredAttribute(XElement element, string name) =>
            element.Attribute(name)?.Value
            ?? throw new InvalidDataException($"{element.Name.LocalName} is missing {name}");

        private static string OptionalAttribute(XElement element, string name) =>
            element.Attribute(name)?.Value ?? string.Empty;

        private static int ParseInt(XElement element, string name) =>
            int.TryParse(RequiredAttribute(element, name), out int value)
                ? value
                : throw new InvalidDataException($"{element.Name.LocalName}.{name} is not an integer");

        private static string Normalize(string value) => Regex.Replace(value.Trim(), @"\s+", " ");
    }

    private static class CSharpEmitter
    {
        private const int StackAllocationLimit = 16 * 1024;

        private static readonly Dictionary<string, string> PrimitiveTypes = new(StringComparer.Ordinal)
        {
            ["void"] = "void",
            ["uint8_t"] = "byte",
            ["uint32_t"] = "uint",
            ["int32_t"] = "int",
            ["uint64_t"] = "ulong",
            ["int64_t"] = "long",
            ["size_t"] = "nuint",
            ["float"] = "float",
        };



        public static string Emit(HeaderModel model)
        {
            StringBuilder output = new();
            output.AppendLine("// <auto-generated />");
            output.AppendLine("// Generated by EzGfxHeaderGenerator from bindings/bindings.xml.");
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
                EmitSummary(output, enumModel.Doc, string.Empty);
                output.AppendLine($"public enum {enumModel.Name} : {EnumUnderlyingType(enumModel.Underlying)}");
                output.AppendLine("{");
                foreach (EnumValueModel value in enumModel.Values)
                {
                    string member = value.Name.StartsWith(enumModel.Name + "_", StringComparison.Ordinal)
                        ? value.Name.Substring(enumModel.Name.Length + 1)
                        : value.Name;
                    EmitSummary(output, value.Doc, "    ");
                    output.AppendLine($"    {member} = {value.Value},");
                }
                output.AppendLine("}");
                output.AppendLine();
            }

            foreach (StructModel structModel in model.Structs)
            {
                EmitSummary(output, structModel.Doc, string.Empty);
                output.AppendLine("[StructLayout(LayoutKind.Sequential)]");
                output.AppendLine($"public struct {structModel.Name}");
                output.AppendLine("{");
                foreach (FieldModel field in structModel.Fields)
                {
                    EmitSummary(output, field.Doc, "    ");
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
            output.AppendLine("    ulong RenderTarget { get; }");
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
                if (!string.IsNullOrEmpty(function.Managed))
                {
                    EmitConvenienceMethod(output, function, model.Handles);
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
            EmitSummary(output, function.Doc, "    ");
            output.AppendLine($"    public static {ReturnType(function.ReturnType, handleTypes)} {methodName}({string.Join(", ", function.Parameters.Select(parameter => RawParameterDeclaration(parameter, handleTypes)))})");
            output.AppendLine("    {");
            EmitRawParameterValidation(output, function, handleTypes);
            string call = "Raw" + methodName + "(" + string.Join(", ", function.Parameters.Select(RawCallArgument)) + ");";
            if (function.ReturnType == "void")
            {
                output.AppendLine("        " + call);
            }
            else
            {
                output.AppendLine("        return " + call);
            }
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitConvenienceMethod(StringBuilder output, FunctionModel function, HashSet<string> handleTypes)
        {
            EmitSummary(output, function.Doc, "    ");
            switch (function.Managed)
            {
                case "context-create":
                    EmitContextCreate(output);
                    break;
                case "surface-create":
                    EmitSurfaceCreate(output);
                    break;
                case "shader-compile":
                    EmitShaderCompile(output);
                    break;
                case "utf8-string":
                    EmitUtf8StringCall(output, function, handleTypes);
                    break;
                case "vertex-upload-indices":
                    EmitVertexUploadIndices(output);
                    break;
                case "vertex-upload":
                    EmitVertexUpload(output);
                    break;
                case "texture-load":
                    EmitTextureLoad(output);
                    break;
                case "draw-command":
                    EmitIndirectWriteDraw(output);
                    break;
                case "structured-write":
                    EmitStructuredWrite(output);
                    break;
                case "vertex-pipeline":
                    EmitRenderPipeline(output, vertex: true);
                    break;
                case "compute-pipeline":
                    EmitRenderPipeline(output, vertex: false);
                    break;
                default:
                    throw new InvalidOperationException($"No convenience emitter for managed shape {function.Managed}");
            }
        }

        private static void EmitContextCreate(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxContextCreate(bool enableDebug, bool enableValidation, EzGfxSurfacePlatform surfacePlatform, out ulong context)");
            output.AppendLine("    {");
            output.AppendLine("        EzGfxContextDesc description = new()");
            output.AppendLine("        {");
            output.AppendLine("            EnableDebug = enableDebug ? (byte)1 : (byte)0,");
            output.AppendLine("            EnableValidation = enableValidation ? (byte)1 : (byte)0,");
            output.AppendLine("            SurfacePlatform = surfacePlatform,");
            output.AppendLine("        };");
            output.AppendLine("        return RawEzGfxContextCreate((IntPtr)(&description), out context);");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitSurfaceCreate(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxSurfaceCreate(IntPtr window, IntPtr display, EzGfxSurfacePlatform platform, uint width, uint height, out ulong surface, ulong context)");
            output.AppendLine("    {");
            output.AppendLine("        if (window == IntPtr.Zero || width == 0 || height == 0 || (platform == EzGfxSurfacePlatform.Win32 && display == IntPtr.Zero))");
            output.AppendLine("        {");
            output.AppendLine("            throw new ArgumentException(\"A non-zero parent window, width, and height are required; Win32 also requires a display handle.\");");
            output.AppendLine("        }");
            output.AppendLine("        EzGfxSurfaceDesc description = new()");
            output.AppendLine("        {");
            output.AppendLine("            Window = window,");
            output.AppendLine("            Display = display,");
            output.AppendLine("            Platform = platform,");
            output.AppendLine("            Width = width,");
            output.AppendLine("            Height = height,");
            output.AppendLine("        };");
            output.AppendLine("        return RawEzGfxSurfaceCreate((IntPtr)(&description), out surface, context);");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitShaderCompile(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxShaderCompile(string path, EzGfxShaderKind kind, string? vertexEntry, string? fragmentEntry, string? computeEntry, out ulong shader, ulong context)");
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
            output.AppendLine("                    Kind = kind,");
            output.AppendLine("                };");
            output.AppendLine("                return RawEzGfxShaderCompile((IntPtr)(&description), out shader, context);");
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
            output.AppendLine("    public static EzGfxResult EzGfxVertexUploadIndices(ReadOnlySpan<uint> data, out uint startIndex, ulong context)");
            output.AppendLine("    {");
            output.AppendLine("        if (data.IsEmpty) throw new ArgumentException(\"Index data must not be empty.\", nameof(data));");
            output.AppendLine("        fixed (uint* pointer = data)");
            output.AppendLine("        {");
            output.AppendLine("            return RawEzGfxVertexUploadIndices((IntPtr)pointer, checked((uint)data.Length), out startIndex, context);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitVertexUpload(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxVertexUpload(string heapName, ReadOnlySpan<byte> data, uint elementCount, ulong elementSize, out uint startIndex, ulong context)");
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
            output.AppendLine("                return RawEzGfxVertexUpload(PutUtf8(utf8, ref offset, heapName), (IntPtr)dataPointer, elementCount, elementSize, out startIndex, context);");
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
            output.AppendLine("    public static EzGfxTextureError EzGfxTextureLoad(ReadOnlySpan<byte> data, EzGfxSourceTextureFormat sourceFormat, EzGfxTextureDestinationFormat destinationFormat, uint width, uint height, uint mipCount, bool generateMips, EzGfxTextureFilter minFilter, EzGfxTextureFilter magFilter, float maxAnisotropy, EzGfxTextureAddressMode addressModeU, EzGfxTextureAddressMode addressModeV, EzGfxTextureAddressMode addressModeW, string? debugLabel, out ulong texture, ulong context)");
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
            output.AppendLine("                    GenerateMips = generateMips ? (byte)1 : (byte)0,");
            output.AppendLine("                    MinFilter = minFilter,");
            output.AppendLine("                    MagFilter = magFilter,");
            output.AppendLine("                    MaxAnisotropy = maxAnisotropy,");
            output.AppendLine("                    AddressModeU = addressModeU,");
            output.AppendLine("                    AddressModeV = addressModeV,");
            output.AppendLine("                    AddressModeW = addressModeW,");
            output.AppendLine("                    DebugLabel = PutUtf8(utf8, ref offset, debugLabel),");
            output.AppendLine("                };");
            output.AppendLine("                return RawEzGfxTextureLoad((IntPtr)dataPointer, checked((ulong)data.Length), (IntPtr)(&description), out texture, context);");
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
            output.AppendLine("    public static EzGfxResult EzGfxIndirectWriteDraw(ulong indirect, uint index, uint indexCount, uint instanceCount, uint firstIndex, int vertexOffset, uint firstInstance, ulong context)");
            output.AppendLine("    {");
            output.AppendLine("        EzGfxDrawIndexedCommand command = new()");
            output.AppendLine("        {");
            output.AppendLine("            IndexCount = indexCount,");
            output.AppendLine("            InstanceCount = instanceCount,");
            output.AppendLine("            FirstIndex = firstIndex,");
            output.AppendLine("            VertexOffset = vertexOffset,");
            output.AppendLine("            FirstInstance = firstInstance,");
            output.AppendLine("        };");
            output.AppendLine("        return RawEzGfxIndirectWriteDraw(indirect, index, (IntPtr)(&command), context);");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitStructuredWrite(StringBuilder output)
        {
            output.AppendLine("    public static EzGfxResult EzGfxStructuredWrite(ulong structured, ReadOnlySpan<byte> data, ulong context)");
            output.AppendLine("    {");
            output.AppendLine("        if (data.IsEmpty) throw new ArgumentException(\"Structured data must not be empty.\", nameof(data));");
            output.AppendLine("        fixed (byte* pointer = data)");
            output.AppendLine("        {");
            output.AppendLine("            return RawEzGfxStructuredWrite(structured, (IntPtr)pointer, checked((ulong)data.Length), context);");
            output.AppendLine("        }");
            output.AppendLine("    }");
            output.AppendLine();
        }

        private static void EmitRenderPipeline(StringBuilder output, bool vertex)
        {
            string methodName = vertex ? "EzGfxRenderAddVertexPipeline" : "EzGfxRenderAddComputePipeline";
            string parameters = vertex
                ? "ulong shader, ulong indirect, ReadOnlySpan<TBinding> bindings, EzGfxCullMode cullMode, EzGfxFrontFace frontFace, EzGfxPrimitiveType primitiveType, EzGfxBlendMode blendMode, ReadOnlySpan<byte> pushConstants, ulong context"
                : "ulong shader, uint dispatchX, uint dispatchY, uint dispatchZ, ReadOnlySpan<TBinding> bindings, ReadOnlySpan<byte> pushConstants, ulong context";
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
            output.AppendLine("                        RenderTarget = binding.RenderTarget,");
            output.AppendLine("                        Structured = binding.Structured,");
            output.AppendLine("                        Indirect = binding.Indirect,");
            output.AppendLine("                    };");
            output.AppendLine("                }");
            output.AppendLine("                IntPtr bindingAddress = bindings.Length == 0 ? IntPtr.Zero : (IntPtr)bindingPointer;");
            output.AppendLine("                IntPtr pushAddress = pushConstants.Length == 0 ? IntPtr.Zero : (IntPtr)pushPointer;");
            if (vertex)
            {
                output.AppendLine($"                return Raw{methodName}(shader, indirect, bindingAddress, checked((uint)bindings.Length), (IntPtr)(&dynamicState), pushAddress, checked((uint)pushConstants.Length), context);");
            }
            else
            {
                output.AppendLine($"                return Raw{methodName}(shader, dispatchX, dispatchY, dispatchZ, bindingAddress, checked((uint)bindings.Length), pushAddress, checked((uint)pushConstants.Length), context);");
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

        private static void EmitUtf8StringCall(StringBuilder output, FunctionModel function, HashSet<string> handleTypes)
        {
            ParameterModel stringParameter = function.Parameters.Single(parameter =>
                parameter.Type.IndexOf("char", StringComparison.Ordinal) >= 0 &&
                parameter.Type.IndexOf('*') >= 0);
            string methodName = ToPascal(function.Name);
            string stringName = FriendlyParameterName(stringParameter);
            string parameters = string.Join(", ", function.Parameters.Select(parameter =>
                FriendlyParameterDeclaration(parameter, stringParameter, handleTypes)));

            output.AppendLine($"    public static {ReturnType(function.ReturnType, handleTypes)} {methodName}({parameters})");
            output.AppendLine("    {");
            EmitFriendlyParameterValidation(output, function);
            output.AppendLine($"        ArgumentException.ThrowIfNullOrWhiteSpace({stringName});");
            output.AppendLine($"        int totalBytes = Utf8ByteCount({stringName});");
            EmitStorageSetup(output, "totalBytes", "storage", "rented");
            output.AppendLine("        try");
            output.AppendLine("        {");
            output.AppendLine("            fixed (byte* utf8 = storage)");
            output.AppendLine("            {");
            output.AppendLine("                int offset = 0;");
            string rawArguments = string.Join(", ", function.Parameters.Select(parameter =>
                parameter.Name == stringParameter.Name
                    ? $"PutUtf8(utf8, ref offset, {stringName})"
                    : parameter.Direction == "out" || parameter.Name.StartsWith("out_", StringComparison.Ordinal)
                        ? "out " + FriendlyParameterName(parameter)
                        : FriendlyParameterName(parameter)));
            output.AppendLine($"                return Raw{methodName}({rawArguments});");
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

        private static void EmitRawParameterValidation(StringBuilder output, FunctionModel function, HashSet<string> handleTypes)
        {
            foreach (ParameterModel parameter in function.Parameters)
            {
                string name = ToPascal(parameter.Name);
                if (parameter.Type.IndexOf('*') < 0 &&
                    parameter.Nullable == "false" &&
                    handleTypes.Contains(parameter.Type))
                {
                    output.AppendLine($"        if ({name} == 0) throw new ArgumentException(\"A non-zero handle is required.\", nameof({name}));");
                }
                EmitValidation(output, parameter.Validation, name);
            }
        }

        private static void EmitFriendlyParameterValidation(StringBuilder output, FunctionModel function)
        {
            foreach (ParameterModel parameter in function.Parameters)
            {
                string name = FriendlyParameterName(parameter);
                if (parameter.Name == "context" && parameter.Nullable == "false")
                {
                    output.AppendLine($"        if ({name} == 0) throw new ArgumentException(\"A non-zero context is required.\", nameof({name}));");
                }
                EmitValidation(output, parameter.Validation, name);
            }
        }

        private static void EmitValidation(StringBuilder output, string validation, string name)
        {
            if (string.IsNullOrEmpty(validation) || validation == "non-negative")
            {
                return;
            }
            if (validation == "greater-than-zero")
            {
                output.AppendLine($"        if ({name} == 0) throw new ArgumentOutOfRangeException(nameof({name}));");
                return;
            }
            if (validation == "zero-or-one")
            {
                output.AppendLine($"        if ({name} != 0 && {name} != 1) throw new ArgumentOutOfRangeException(nameof({name}));");
                return;
            }
            if (validation == "not-empty")
            {
                output.AppendLine($"        if ({name}.Length == 0) throw new ArgumentException(\"{name} must not be empty.\", nameof({name}));");
                return;
            }
            const string AtMostPrefix = "at-most-";
            if (validation.StartsWith(AtMostPrefix, StringComparison.Ordinal) &&
                int.TryParse(validation.Substring(AtMostPrefix.Length), out int limit))
            {
                output.AppendLine($"        if ({name} > {limit}) throw new ArgumentOutOfRangeException(nameof({name}));");
                return;
            }
            throw new InvalidDataException($"unsupported validation metadata {validation}");
        }

        private static string FriendlyParameterDeclaration(
            ParameterModel parameter,
            ParameterModel stringParameter,
            HashSet<string> handleTypes)
        {
            string name = FriendlyParameterName(parameter);
            if (parameter.Name == stringParameter.Name)
            {
                return $"string {name}";
            }
            if (parameter.Type.IndexOf('*') >= 0)
            {
                string baseType = parameter.Type.Replace("const", string.Empty).Replace("*", string.Empty).Trim();
                if (parameter.Direction == "out" || parameter.Name.StartsWith("out_", StringComparison.Ordinal))
                {
                    return $"out {CSharpType(baseType, handleTypes)} {name}";
                }
                return $"IntPtr {name}";
            }
            return $"{CSharpType(parameter.Type, handleTypes)} {name}";
        }

        private static string FriendlyParameterName(ParameterModel parameter)
        {
            string value = parameter.Name.StartsWith("out_", StringComparison.Ordinal)
                ? parameter.Name.Substring("out_".Length)
                : parameter.Name;
            string pascal = ToPascal(value);
            return pascal.Length == 0
                ? pascal
                : char.ToLowerInvariant(pascal[0]) + pascal.Substring(1);
        }

        private static void EmitSummary(StringBuilder output, string documentation, string indent)
        {
            if (string.IsNullOrWhiteSpace(documentation))
            {
                return;
            }
            string summary = documentation
                .Replace("&", "&amp;")
                .Replace("<", "&lt;")
                .Replace(">", "&gt;")
                .Replace("\r", " ")
                .Replace("\n", " ");
            output.AppendLine($"{indent}/// <summary>{summary}</summary>");
        }

        private static string EnumUnderlyingType(string type)
        {
            if (!PrimitiveTypes.TryGetValue(type, out string? primitive) || primitive == "void")
            {
                throw new InvalidDataException($"unsupported enum underlying type {type}");
            }
            return primitive;
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
            if (parameter.Direction == "out" || parameter.Name.StartsWith("out_", StringComparison.Ordinal))
            {
                return $"out {CSharpType(baseType, handleTypes)} {name}";
            }
            return $"IntPtr {name}";
        }

        private static string RawCallArgument(ParameterModel parameter)
        {
            string name = ToPascal(parameter.Name);
            return parameter.Direction == "out" || parameter.Name.StartsWith("out_", StringComparison.Ordinal)
                ? "out " + name
                : name;
        }

        private static string ToPascal(string value) =>
            string.Concat(value.Split('_').Select(part => part.Length == 0 ? string.Empty : char.ToUpperInvariant(part[0]) + (part.Length > 1 ? part.Substring(1) : string.Empty)));
    }
}
