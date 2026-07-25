using System.Numerics;
using EzGfx.Native;

namespace EzGfx.Examples;

public static class Example05
{
    public static void Run(ExampleOptions options)
    {
        GltfScene scene = GltfScene.Load(ExampleHost.AssetPath("helmet.glb"));
        using EasyGraphics graphics = EasyGraphics.Create(new EasyGraphicsOptions(EnableValidation: options.EnableValidation));
        graphics.EnableAllDecoders();
        using GraphicsWindow window = graphics.CreateWindow(
            "ez_gfx_api helmet cgltf",
            1280,
            720,
            options.Hidden,
            cachePresentedSnapshots: options.ScreenshotPath is not null);
        using ShaderProgram computeShader = graphics.CompileShader(new ShaderDescription(
            ExampleHost.ShaderPath("5_helmet_cgltf", "compute.slang"),
            EzGfxShaderKind.Compute));
        using ShaderProgram drawShader = graphics.CompileShader(new ShaderDescription(
            ExampleHost.ShaderPath("5_helmet_cgltf", "draw.slang")));
        using VertexManager vertices = graphics.BeginVertexManager();

        ulong vertexBytes = checked((ulong)scene.Primitives.Sum(static primitive => primitive.Positions.Length / 3 * 16));
        ulong indexBytes = checked((ulong)scene.Primitives.Sum(static primitive => primitive.Indices.Length * sizeof(uint)));
        graphics.CreateIndexHeap(vertices, indexBytes + 4096, "example 5 index heap");
        vertices.AddHeap("position", vertexBytes + 4096, 16);
        vertices.AddHeap("normal", vertexBytes + 4096, 16);

        List<PrimitiveRecord> records = new(scene.Primitives.Count);
        foreach (GltfPrimitive primitive in scene.Primitives)
        {
            uint vertexStart = vertices.UploadVertices("position", ToVec4Bytes(primitive.Positions, 1), primitive.Positions.Length / 3, 16);
            uint normalStart = vertices.UploadVertices("normal", ToVec4Bytes(primitive.Normals, 0), primitive.Normals.Length / 3, 16);
            uint[] globalIndices = primitive.Indices.Select(index => checked(index + vertexStart)).ToArray();
            uint firstIndex = vertices.UploadIndices(globalIndices);
            records.Add(new PrimitiveRecord(firstIndex, checked((uint)globalIndices.Length), vertexStart, normalStart, primitive.Transform));
        }
        graphics.WaitIdle();

        Matrix4x4 view = ExampleHost.OrbitView(35, 22, 5);
        Matrix4x4 projection = ExampleHost.VulkanPerspective(60, 1280f / 720f, 0.1f, 100f);
        byte[] drawPush = ExampleHost.MatrixPush(view * projection);
        byte[] primitiveBytes = PackRecords(records);
        ExampleHost.RunFrames(graphics, window, options.Frames, _ =>
        {
            using IndirectBuffer indirect = graphics.AcquireIndirect((uint)records.Count, "example 5 draw commands");
            using StructuredBuffer primitives = graphics.AcquireStructured(80, (uint)records.Count, "primitives");
            primitives.Write(primitiveBytes);
            graphics.AddComputePipeline(
                computeShader,
                (uint)records.Count,
                1,
                1,
                new[]
                {
                    new Binding("primitives", Structured: primitives),
                    new Binding("draw_commands", Indirect: indirect),
                },
                BitConverter.GetBytes((uint)records.Count));
            indirect.SetDrawCount((uint)records.Count);
            graphics.AddVertexPipeline(
                drawShader,
                indirect,
                new[] { new Binding("primitives", Structured: primitives) },
                pushConstants: drawPush);
        });
        ExampleHost.SaveIfRequested(graphics, window, options.ScreenshotPath);
    }

    private static byte[] ToVec4Bytes(float[] values, float w)
    {
        int count = values.Length / 3;
        float[] expanded = new float[checked(count * 4)];
        for (int index = 0; index < count; index++)
        {
            expanded[index * 4] = values[index * 3];
            expanded[index * 4 + 1] = values[index * 3 + 1];
            expanded[index * 4 + 2] = values[index * 3 + 2];
            expanded[index * 4 + 3] = w;
        }
        byte[] bytes = new byte[expanded.Length * sizeof(float)];
        Buffer.BlockCopy(expanded, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    private static byte[] PackRecords(IReadOnlyList<PrimitiveRecord> records)
    {
        byte[] bytes = new byte[checked(records.Count * 80)];
        for (int index = 0; index < records.Count; index++)
        {
            PrimitiveRecord record = records[index];
            int offset = index * 80;
            BitConverter.TryWriteBytes(bytes.AsSpan(offset, 4), record.FirstIndex);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 4, 4), record.IndexCount);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 8, 4), record.VertexOffset);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 12, 4), record.NormalOffset);
            Buffer.BlockCopy(ExampleHost.ColumnMatrixPush(record.Transform), 0, bytes, offset + 16, 64);
        }
        return bytes;
    }

    private readonly record struct PrimitiveRecord(
        uint FirstIndex,
        uint IndexCount,
        uint VertexOffset,
        uint NormalOffset,
        Matrix4x4 Transform);
}
