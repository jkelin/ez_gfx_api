using System.Numerics;
using EzGfx.Native;

namespace EzGfx.Examples;

public static class Example06
{
    public static void Run(ExampleOptions options)
    {
        GltfScene scene = GltfScene.Load(ExampleHost.AssetPath("sponza.glb"));
        using EasyGraphics graphics = EasyGraphics.Create(new EasyGraphicsOptions(EnableValidation: options.EnableValidation));
        graphics.EnableAllDecoders();
        using GraphicsWindow window = graphics.CreateWindow(
            "ez_gfx_api Sponza KTX2",
            1280,
            720,
            options.Hidden,
            cachePresentedSnapshots: options.ScreenshotPath is not null);
        using ShaderProgram computeShader = graphics.CompileShader(new ShaderDescription(
            ExampleHost.ShaderPath("6_sponza_ktx2", "compute.slang"),
            EzGfxShaderKind.Compute));
        using ShaderProgram drawShader = graphics.CompileShader(new ShaderDescription(
            ExampleHost.ShaderPath("6_sponza_ktx2", "draw.slang")));
        using VertexManager vertices = graphics.BeginVertexManager();

        TextureResource fallback = graphics.LoadTexture(
            new byte[] { 255, 255, 255, 255 },
            new TextureDescription(
                EzGfxSourceTextureFormat.Rgba,
                1,
                1,
                MipCount: 1,
                DebugLabel: "sponza fallback texture"));
        List<TextureResource> textures = new() { fallback };
        Dictionary<int, TextureResource> imageTextures = new();
        foreach (GltfPrimitive primitive in scene.Primitives)
        {
            if (primitive.TextureIndex < 0 || imageTextures.ContainsKey(primitive.TextureIndex))
            {
                continue;
            }
            GltfImage image = scene.Images[primitive.TextureIndex];
            if (image.Bytes.Length == 0)
            {
                continue;
            }
            TextureResource texture = graphics.LoadTexture(
                image.Bytes,
                new TextureDescription(
                    image.SourceFormat,
                    0,
                    0,
                    MipCount: 0,
                    GenerateMips: true,
                    MaxAnisotropy: 16,
                    DebugLabel: "sponza base color KTX2"));
            imageTextures.Add(primitive.TextureIndex, texture);
            textures.Add(texture);
        }
        uint fallbackBindingIndex = graphics.GetTextureBindingIndex(fallback);

        ulong positionBytes = checked((ulong)scene.Primitives.Sum(static primitive => primitive.Positions.Length / 3 * 16));
        ulong normalBytes = checked((ulong)scene.Primitives.Sum(static primitive => primitive.Normals.Length / 3 * 16));
        ulong uvBytes = checked((ulong)scene.Primitives.Sum(static primitive => primitive.Uvs.Length / 2 * 16));
        ulong indexBytes = checked((ulong)scene.Primitives.Sum(static primitive => primitive.Indices.Length * sizeof(uint)));
        graphics.CreateIndexHeap(vertices, indexBytes + 4096, "example 6 index heap");
        vertices.AddHeap("position", positionBytes + 4096, 16);
        vertices.AddHeap("normal", normalBytes + 4096, 16);
        vertices.AddHeap("uv", uvBytes + 4096, 16);

        List<PrimitiveRecord> records = new(scene.Primitives.Count);
        foreach (GltfPrimitive primitive in scene.Primitives)
        {
            uint vertexStart = vertices.UploadVertices("position", ToVec4Bytes(primitive.Positions, 1), primitive.Positions.Length / 3, 16);
            uint normalStart = vertices.UploadVertices("normal", ToVec4Bytes(primitive.Normals, 0), primitive.Normals.Length / 3, 16);
            uint uvStart = vertices.UploadVertices("uv", ToUvVec4Bytes(primitive.Uvs), primitive.Uvs.Length / 2, 16);
            uint[] globalIndices = primitive.Indices.Select(index => checked(index + vertexStart)).ToArray();
            uint firstIndex = vertices.UploadIndices(globalIndices);
            uint textureBindingIndex = fallbackBindingIndex;
            if (primitive.TextureIndex >= 0 && imageTextures.TryGetValue(primitive.TextureIndex, out TextureResource? texture))
            {
                textureBindingIndex = graphics.GetTextureBindingIndex(texture);
            }
            records.Add(new PrimitiveRecord(
                firstIndex,
                checked((uint)globalIndices.Length),
                vertexStart,
                normalStart,
                uvStart,
                textureBindingIndex,
                primitive.Transform));
        }
        graphics.WaitIdle();

        Matrix4x4 view = ExampleHost.OrbitView(90, 8, 0.45f, 0, -0.32f, 0);
        Matrix4x4 projection = ExampleHost.VulkanPerspective(60, 1280f / 720f, 0.02f, 100f);
        byte[] drawPush = ExampleHost.MatrixPush(view * projection);
        byte[] primitiveBytes = PackRecords(records);
        ExampleHost.RunFrames(graphics, window, options.Frames, _ =>
        {
            using IndirectBuffer indirect = graphics.AcquireIndirect((uint)records.Count, "example 6 draw commands");
            using StructuredBuffer primitives = graphics.AcquireStructured(96, (uint)records.Count, "primitives");
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
                new DynamicState(CullMode: EzGfxCullMode.Back, FrontFace: EzGfxFrontFace.CounterClockwise),
                drawPush);
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

    private static byte[] ToUvVec4Bytes(float[] values)
    {
        int count = values.Length / 2;
        float[] expanded = new float[checked(count * 4)];
        for (int index = 0; index < count; index++)
        {
            expanded[index * 4] = values[index * 2];
            expanded[index * 4 + 1] = values[index * 2 + 1];
        }
        byte[] bytes = new byte[expanded.Length * sizeof(float)];
        Buffer.BlockCopy(expanded, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    private static byte[] PackRecords(IReadOnlyList<PrimitiveRecord> records)
    {
        byte[] bytes = new byte[checked(records.Count * 96)];
        for (int index = 0; index < records.Count; index++)
        {
            PrimitiveRecord record = records[index];
            int offset = index * 96;
            BitConverter.TryWriteBytes(bytes.AsSpan(offset, 4), record.FirstIndex);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 4, 4), record.IndexCount);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 8, 4), record.VertexOffset);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 12, 4), record.NormalOffset);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 16, 4), record.UvOffset);
            BitConverter.TryWriteBytes(bytes.AsSpan(offset + 20, 4), record.TextureBindingIndex);
            Buffer.BlockCopy(ExampleHost.ColumnMatrixPush(record.Transform), 0, bytes, offset + 32, 64);
        }
        return bytes;
    }

    private readonly record struct PrimitiveRecord(
        uint FirstIndex,
        uint IndexCount,
        uint VertexOffset,
        uint NormalOffset,
        uint UvOffset,
        uint TextureBindingIndex,
        Matrix4x4 Transform);
}
