using EzGfx.Native;

namespace EzGfx.Examples;

public static class Example01
{
    public static void Run(ExampleOptions options)
    {
        using EasyGraphics graphics = EasyGraphics.Create(new EasyGraphicsOptions(EnableValidation: options.EnableValidation));
        graphics.EnableAllDecoders();
        using GraphicsWindow window = graphics.CreateWindow(
            "ez_gfx_api triangle",
            1280,
            720,
            options.Hidden,
            cachePresentedSnapshots: options.ScreenshotPath is not null);
        using ShaderProgram shader = graphics.CompileShader(new ShaderDescription(ExampleHost.ShaderPath("1_triangle", "triangle.slang")));
        using VertexManager vertices = graphics.BeginVertexManager();
        graphics.CreateIndexHeap(vertices, 3 * sizeof(uint), "triangle indices");
        vertices.AddHeap("position", 1024 * 1024, 16);

        uint indexStart = vertices.UploadIndices(new uint[] { 0, 1, 2 });
        float[] positionValues =
        {
            -0.5f, -0.5f, 0, 1,
             0.5f, -0.5f, 0, 1,
             0, 0.5f, 0, 1,
        };
        uint vertexStart = vertices.UploadVertices("position", ToBytes(positionValues), 3, 16);
        graphics.WaitIdle();

        ExampleHost.RunFrames(graphics, window, options.Frames, _ =>
        {
            using IndirectBuffer indirect = graphics.AcquireIndirect(1, "triangle draw commands");
            graphics.AddVertexPipeline(shader, indirect);
            indirect.WriteDraw(0, new DrawIndexedCommand(3, 1, indexStart, checked((int)vertexStart), 0));
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
