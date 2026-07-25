using System.Numerics;
using EzGfx.Native;

namespace EzGfx.Examples;

public static class Example02
{
    private static readonly uint[] Indices =
    {
        0, 1, 2, 2, 3, 0,
        4, 5, 6, 6, 7, 4,
        8, 9, 10, 10, 11, 8,
        12, 13, 14, 14, 15, 12,
        16, 17, 18, 18, 19, 16,
        20, 21, 22, 22, 23, 20,
    };

    private static readonly float[] Positions =
    {
        -1, -1, 1, 1, 1, -1, 1, 1, 1, 1, 1, 1, -1, 1, 1, 1,
        1, -1, -1, 1, -1, -1, -1, 1, -1, 1, -1, 1, 1, 1, -1, 1,
        -1, -1, -1, 1, -1, -1, 1, 1, -1, 1, 1, 1, -1, 1, -1, 1,
        1, -1, 1, 1, 1, -1, -1, 1, 1, 1, -1, 1, 1, 1, 1, 1,
        -1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, 1, -1, 1, -1, 1,
        -1, -1, -1, 1, 1, -1, -1, 1, 1, -1, 1, 1, -1, -1, 1, 1,
    };

    public static void Run(ExampleOptions options)
    {
        using EasyGraphics graphics = EasyGraphics.Create(new EasyGraphicsOptions(EnableValidation: options.EnableValidation));
        graphics.EnableAllDecoders();
        using GraphicsWindow window = graphics.CreateWindow(
            "ez_gfx_api cube",
            1280,
            720,
            options.Hidden,
            cachePresentedSnapshots: options.ScreenshotPath is not null);
        using ShaderProgram shader = graphics.CompileShader(new ShaderDescription(ExampleHost.ShaderPath("2_textured_cube", "cube.slang")));
        using VertexManager vertices = graphics.BeginVertexManager();
        vertices.AddHeap("position", 1024 * 1024, 16);
        graphics.CreateIndexHeap(vertices, (ulong)(Indices.Length * sizeof(uint)), "cube indices");
        uint indexStart = vertices.UploadIndices(Indices);
        uint vertexStart = vertices.UploadVertices("position", ToBytes(Positions), 24, 16);
        graphics.WaitIdle();

        using TextureResource texture = graphics.LoadTexture(
            File.ReadAllBytes(Path.Combine(ExampleHost.RepositoryRoot, "examples", "2_textured_cube", "ez_graphics_api_texture.png")),
            new TextureDescription(
                EzGfxSourceTextureFormat.Png,
                0,
                0,
                MipCount: 0,
                GenerateMips: true,
                DebugLabel: "example cube texture"));

        Matrix4x4 view = ExampleHost.OrbitView();
        Matrix4x4 projection = ExampleHost.VulkanPerspective(60, 1280f / 720f, 0.1f, 100f);
        byte[] pushConstants = ExampleHost.MatrixAndTexturePush(view * projection, texture.Id);
        ExampleHost.RunFrames(graphics, window, options.Frames, _ =>
        {
            using IndirectBuffer indirect = graphics.AcquireIndirect(1, "cube draw commands");
            graphics.AddVertexPipeline(shader, indirect, pushConstants: pushConstants);
            indirect.WriteDraw(0, new DrawIndexedCommand((uint)Indices.Length, 1, indexStart, checked((int)vertexStart), 0));
            indirect.SetDrawCount(1);
        });
        ExampleHost.SaveIfRequested(graphics, window, options.ScreenshotPath);
    }

    private static byte[] ToBytes(float[] values)
    {
        byte[] bytes = new byte[checked(values.Length * sizeof(float))];
        Buffer.BlockCopy(values, 0, bytes, 0, bytes.Length);
        return bytes;
    }
}
