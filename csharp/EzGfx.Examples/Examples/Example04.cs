
namespace EzGfx.Examples;

public static class Example04
{
    public static void Run(ExampleOptions options)
    {
        using EasyGraphics graphics = EasyGraphics.Create(new EasyGraphicsOptions(EnableValidation: options.EnableValidation));
        graphics.EnableAllDecoders();
        using GraphicsWindow window = graphics.CreateWindow(
            "ez_gfx_api Dear ImGui",
            1280,
            720,
            options.Hidden,
            cachePresentedSnapshots: options.ScreenshotPath is not null);

        ExampleHost.RunNativeFrames(window, options.Frames, _ => graphics.RenderImGuiDemo(window));
        ExampleHost.SaveIfRequested(graphics, window, options.ScreenshotPath);
    }
}
