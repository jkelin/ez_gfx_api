using System.Numerics;

namespace EzGfx.Examples;

public sealed record ExampleOptions(
    int Frames = 1,
    string? ScreenshotPath = null,
    bool Hidden = true,
    bool EnableValidation = true);

public static class ExampleHost
{
    public static string RepositoryRoot => FindRepositoryRoot(Environment.CurrentDirectory);

    public static string ShaderPath(string example, string file)
        => Path.Combine(RepositoryRoot, "examples", example, file);

    public static string AssetPath(params string[] path)
        => Path.Combine(new[] { RepositoryRoot, "examples", "shared", "assets" }.Concat(path).ToArray());

    public static void RunFrames(
        EasyGraphics graphics,
        GraphicsWindow window,
        int frames,
        Action<int> draw)
    {
        if (frames <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(frames));
        }
        for (int frame = 0; frame < frames; frame++)
        {
            window.PollEvents();
            if (window.ShouldClose || !graphics.BeginFrame(window))
            {
                continue;
            }
            draw(frame);
            graphics.FinishFrame();
        }
    }

    public static void RunNativeFrames(
        GraphicsWindow window,
        int frames,
        Action<int> render)
    {
        if (frames <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(frames));
        }
        ArgumentNullException.ThrowIfNull(render);
        for (int frame = 0; frame < frames; frame++)
        {
            window.PollEvents();
            if (!window.ShouldClose && !window.IsMinimized)
            {
                render(frame);
            }
        }
    }

    public static void SaveIfRequested(EasyGraphics graphics, GraphicsWindow window, string? path)
    {
        if (!string.IsNullOrWhiteSpace(path))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            graphics.WaitIdle();
            graphics.SaveScreenshot(window, path);
        }
    }

    public static Matrix4x4 OrbitView(
        float yawDegrees = 35,
        float pitchDegrees = 22,
        float distance = 5,
        float targetX = 0,
        float targetY = 0,
        float targetZ = 0)
    {
        float yaw = yawDegrees * (float)(Math.PI * 2.0 / 360.0);
        float pitch = pitchDegrees * (float)(Math.PI * 2.0 / 360.0);
        float cosPitch = (float)Math.Cos((double)pitch);
        Vector3 target = new(targetX, targetY, targetZ);
        Vector3 eye = target + new Vector3(
            distance * (float)Math.Sin((double)yaw) * cosPitch,
            distance * (float)Math.Sin((double)pitch),
            distance * (float)Math.Cos((double)yaw) * cosPitch);
        return Matrix4x4.CreateLookAt(eye, target, Vector3.UnitY);
    }

    public static Matrix4x4 VulkanPerspective(float fovDegrees, float aspect, float near, float far)
    {
        float fov = fovDegrees * (float)(Math.PI * 2.0 / 360.0);
        float tanHalfFov = MathF.Tan(0.5f * fov);
        Matrix4x4 native = new(
            1f / (aspect * tanHalfFov), 0, 0, 0,
            0, -1f / tanHalfFov, 0, 0,
            0, 0, -(far + near) / (far - near), -2f * far * near / (far - near),
            0, 0, -1, 0);
        return Matrix4x4.Transpose(native);
    }

    public static byte[] MatrixPush(Matrix4x4 matrix)
    {
        Matrix4x4 columnVectorMatrix = Matrix4x4.Transpose(matrix);
        float[] values =
        {
            columnVectorMatrix.M11, columnVectorMatrix.M12, columnVectorMatrix.M13, columnVectorMatrix.M14,
            columnVectorMatrix.M21, columnVectorMatrix.M22, columnVectorMatrix.M23, columnVectorMatrix.M24,
            columnVectorMatrix.M31, columnVectorMatrix.M32, columnVectorMatrix.M33, columnVectorMatrix.M34,
            columnVectorMatrix.M41, columnVectorMatrix.M42, columnVectorMatrix.M43, columnVectorMatrix.M44,
        };
        byte[] bytes = new byte[sizeof(float) * values.Length];
        Buffer.BlockCopy(values, 0, bytes, 0, bytes.Length);
        return bytes;
    }


    public static byte[] ColumnMatrixPush(Matrix4x4 matrix)
    {
        float[] values =
        {
            matrix.M11, matrix.M12, matrix.M13, matrix.M14,
            matrix.M21, matrix.M22, matrix.M23, matrix.M24,
            matrix.M31, matrix.M32, matrix.M33, matrix.M34,
            matrix.M41, matrix.M42, matrix.M43, matrix.M44,
        };
        byte[] bytes = new byte[sizeof(float) * values.Length];
        Buffer.BlockCopy(values, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    public static byte[] MatrixAndTexturePush(Matrix4x4 matrix, uint textureBindingIndex)
    {
        byte[] bytes = new byte[80];
        byte[] matrixBytes = MatrixPush(matrix);
        Buffer.BlockCopy(matrixBytes, 0, bytes, 0, matrixBytes.Length);
        BitConverter.TryWriteBytes(bytes.AsSpan(64, sizeof(uint)), textureBindingIndex);
        return bytes;
    }

    private static string FindRepositoryRoot(string start)
    {
        DirectoryInfo? directory = new(Path.GetFullPath(start));
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Justfile")) &&
                Directory.Exists(Path.Combine(directory.FullName, "src")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException($"Could not locate the ez_gfx repository from {start}.");
    }
}
