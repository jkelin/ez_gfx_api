using System.Buffers.Binary;
using System.Numerics;
using System.Text;
using System.Text.Json;

namespace EzGfx.Examples;

internal sealed class GltfScene
{
    private GltfScene(List<GltfPrimitive> primitives, List<GltfImage> images)
    {
        Primitives = primitives;
        Images = images;
    }

    public List<GltfPrimitive> Primitives { get; }
    public List<GltfImage> Images { get; }

    public static GltfScene Load(string path)
    {
        byte[] file = File.ReadAllBytes(path);
        if (file.Length < 20 || BinaryPrimitives.ReadUInt32LittleEndian(file) != 0x46546C67)
        {
            throw new InvalidDataException($"{path} is not a GLB file.");
        }
        int jsonLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(file.AsSpan(12)));
        uint jsonType = BinaryPrimitives.ReadUInt32LittleEndian(file.AsSpan(16));
        if (jsonType != 0x4E4F534A || 20 + jsonLength > file.Length)
        {
            throw new InvalidDataException($"{path} does not contain a valid GLB JSON chunk.");
        }
        using JsonDocument document = JsonDocument.Parse(file.AsMemory(20, jsonLength));
        JsonElement root = document.RootElement;
        int binOffset = 20 + jsonLength;
        byte[] binary = Array.Empty<byte>();
        if (binOffset + 8 <= file.Length)
        {
            int binLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(file.AsSpan(binOffset)));
            uint binType = BinaryPrimitives.ReadUInt32LittleEndian(file.AsSpan(binOffset + 4));
            if (binType == 0x004E4942 && binOffset + 8 + binLength <= file.Length)
            {
                binary = file.AsSpan(binOffset + 8, binLength).ToArray();
            }
        }

        List<GltfBufferView> views = ReadBufferViews(root);
        List<GltfAccessor> accessors = ReadAccessors(root);
        List<GltfImage> images = ReadImages(root, views, binary);
        List<GltfPrimitive> primitives = new();
        if (root.TryGetProperty("nodes", out JsonElement nodes))
        {
            HashSet<int> childNodes = new();
            foreach (JsonElement node in nodes.EnumerateArray())
            {
                if (node.TryGetProperty("children", out JsonElement children))
                {
                    foreach (JsonElement child in children.EnumerateArray())
                    {
                        childNodes.Add(child.GetInt32());
                    }
                }
            }
            if (root.TryGetProperty("scenes", out JsonElement scenes) && scenes.GetArrayLength() > 0)
            {
                int sceneIndex = root.TryGetProperty("scene", out JsonElement sceneValue) ? sceneValue.GetInt32() : 0;
                JsonElement scene = scenes[sceneIndex];
                foreach (JsonElement nodeIndex in scene.GetProperty("nodes").EnumerateArray())
                {
                    VisitNode(nodeIndex.GetInt32(), Matrix4x4.Identity, nodes, root, accessors, views, binary, primitives);
                }
            }
            else
            {
                for (int index = 0; index < nodes.GetArrayLength(); index++)
                {
                    if (!childNodes.Contains(index))
                    {
                        VisitNode(index, Matrix4x4.Identity, nodes, root, accessors, views, binary, primitives);
                    }
                }
            }
        }
        Normalize(primitives);
        return new GltfScene(primitives, images);
    }

    private static void VisitNode(
        int nodeIndex,
        Matrix4x4 parent,
        JsonElement nodes,
        JsonElement root,
        IReadOnlyList<GltfAccessor> accessors,
        IReadOnlyList<GltfBufferView> views,
        byte[] binary,
        List<GltfPrimitive> output)
    {
        JsonElement node = nodes[nodeIndex];
        Matrix4x4 world = parent * ReadNodeTransform(node);
        if (node.TryGetProperty("mesh", out JsonElement meshIndexElement))
        {
            JsonElement mesh = root.GetProperty("meshes")[meshIndexElement.GetInt32()];
            foreach (JsonElement primitive in mesh.GetProperty("primitives").EnumerateArray())
            {
                if (primitive.TryGetProperty("mode", out JsonElement mode) && mode.GetInt32() != 4)
                {
                    continue;
                }
                if (!primitive.GetProperty("attributes").TryGetProperty("POSITION", out JsonElement positionAccessor))
                {
                    continue;
                }
                int positionIndex = positionAccessor.GetInt32();
                float[] positions = ReadFloatAccessor(accessors[positionIndex], accessors, views, binary, 3);
                float[] normals = TryReadAttribute(primitive, "NORMAL", accessors, views, binary, positions.Length / 3, 3)
                    ?? BuildDefaultNormals(positions.Length / 3);
                float[] uvs = TryReadAttribute(primitive, "TEXCOORD_0", accessors, views, binary, positions.Length / 3, 2)
                    ?? new float[(positions.Length / 3) * 2];
                uint[] indices;
                if (primitive.TryGetProperty("indices", out JsonElement indexAccessor))
                {
                    indices = ReadIndexAccessor(accessors[indexAccessor.GetInt32()], views, binary);
                }
                else
                {
                    indices = Enumerable.Range(0, positions.Length / 3).Select(static value => (uint)value).ToArray();
                }
                int textureIndex = ReadMaterialTextureIndex(primitive, root);
                output.Add(new GltfPrimitive(positions, normals, uvs, indices, world, textureIndex));
            }
        }
        if (node.TryGetProperty("children", out JsonElement children))
        {
            foreach (JsonElement child in children.EnumerateArray())
            {
                VisitNode(child.GetInt32(), world, nodes, root, accessors, views, binary, output);
            }
        }
    }

    private static List<GltfBufferView> ReadBufferViews(JsonElement root)
    {
        List<GltfBufferView> result = new();
        foreach (JsonElement value in root.GetProperty("bufferViews").EnumerateArray())
        {
            result.Add(new GltfBufferView(
                value.TryGetProperty("byteOffset", out JsonElement offset) ? offset.GetInt32() : 0,
                value.GetProperty("byteLength").GetInt32(),
                value.TryGetProperty("byteStride", out JsonElement stride) ? stride.GetInt32() : 0));
        }
        return result;
    }

    private static List<GltfAccessor> ReadAccessors(JsonElement root)
    {
        List<GltfAccessor> result = new();
        foreach (JsonElement value in root.GetProperty("accessors").EnumerateArray())
        {
            result.Add(new GltfAccessor(
                value.GetProperty("bufferView").GetInt32(),
                value.TryGetProperty("byteOffset", out JsonElement offset) ? offset.GetInt32() : 0,
                value.GetProperty("componentType").GetInt32(),
                value.GetProperty("count").GetInt32(),
                value.GetProperty("type").GetString() ?? string.Empty));
        }
        return result;
    }

    private static List<GltfImage> ReadImages(JsonElement root, IReadOnlyList<GltfBufferView> views, byte[] binary)
    {
        List<GltfImage> result = new();
        if (!root.TryGetProperty("images", out JsonElement images))
        {
            return result;
        }
        foreach (JsonElement image in images.EnumerateArray())
        {
            string mime = image.TryGetProperty("mimeType", out JsonElement mimeElement)
                ? mimeElement.GetString() ?? string.Empty
                : string.Empty;
            byte[] bytes = image.TryGetProperty("bufferView", out JsonElement view)
                ? ReadView(views[view.GetInt32()], binary)
                : Array.Empty<byte>();
            result.Add(new GltfImage(bytes, mime));
        }
        return result;
    }

    private static int ReadMaterialTextureIndex(JsonElement primitive, JsonElement root)
    {
        if (!primitive.TryGetProperty("material", out JsonElement materialIndex) ||
            !root.TryGetProperty("materials", out JsonElement materials))
        {
            return -1;
        }
        JsonElement material = materials[materialIndex.GetInt32()];
        if (!material.TryGetProperty("pbrMetallicRoughness", out JsonElement pbr) ||
            !pbr.TryGetProperty("baseColorTexture", out JsonElement texture) ||
            !texture.TryGetProperty("index", out JsonElement textureIndex) ||
            !root.TryGetProperty("textures", out JsonElement textures))
        {
            return -1;
        }
        JsonElement textureValue = textures[textureIndex.GetInt32()];
        if (textureValue.TryGetProperty("extensions", out JsonElement extensions) &&
            extensions.TryGetProperty("KHR_texture_basisu", out JsonElement basisu) &&
            basisu.TryGetProperty("source", out JsonElement source))
        {
            return source.GetInt32();
        }
        return textureValue.TryGetProperty("source", out JsonElement image) ? image.GetInt32() : -1;
    }

    private static float[]? TryReadAttribute(
        JsonElement primitive,
        string name,
        IReadOnlyList<GltfAccessor> accessors,
        IReadOnlyList<GltfBufferView> views,
        byte[] binary,
        int vertexCount,
        int components)
    {
        if (!primitive.GetProperty("attributes").TryGetProperty(name, out JsonElement accessor))
        {
            return null;
        }
        GltfAccessor description = accessors[accessor.GetInt32()];
        if (description.Count != vertexCount || !string.Equals(description.Type, components == 2 ? "VEC2" : "VEC3", StringComparison.Ordinal))
        {
            return null;
        }
        return ReadFloatAccessor(description, accessors, views, binary, components);
    }

    private static float[] ReadFloatAccessor(
        GltfAccessor accessor,
        IReadOnlyList<GltfAccessor> allAccessors,
        IReadOnlyList<GltfBufferView> views,
        byte[] binary,
        int components)
    {
        if (accessor.ComponentType != 5126 || accessor.Type != (components == 2 ? "VEC2" : "VEC3"))
        {
            throw new InvalidDataException("Only float VEC2/VEC3 accessors are supported for vertex attributes.");
        }
        GltfBufferView view = views[accessor.BufferView];
        int elementSize = components * sizeof(float);
        int stride = view.ByteStride == 0 ? elementSize : view.ByteStride;
        float[] values = new float[checked(accessor.Count * components)];
        int start = checked(view.ByteOffset + accessor.ByteOffset);
        for (int element = 0; element < accessor.Count; element++)
        {
            int elementOffset = checked(start + element * stride);
            for (int component = 0; component < components; component++)
            {
                values[element * components + component] = BitConverter.Int32BitsToSingle(
                    BinaryPrimitives.ReadInt32LittleEndian(binary.AsSpan(elementOffset + component * sizeof(float))));
            }
        }
        return values;
    }

    private static uint[] ReadIndexAccessor(GltfAccessor accessor, IReadOnlyList<GltfBufferView> views, byte[] binary)
    {
        if (accessor.Type != "SCALAR")
        {
            throw new InvalidDataException("Index accessor must be scalar.");
        }
        int componentSize = accessor.ComponentType switch
        {
            5121 => 1,
            5123 => 2,
            5125 => 4,
            _ => throw new InvalidDataException("Unsupported index component type."),
        };
        GltfBufferView view = views[accessor.BufferView];
        int stride = view.ByteStride == 0 ? componentSize : view.ByteStride;
        int start = checked(view.ByteOffset + accessor.ByteOffset);
        uint[] values = new uint[accessor.Count];
        for (int index = 0; index < values.Length; index++)
        {
            int offset = checked(start + index * stride);
            values[index] = accessor.ComponentType switch
            {
                5121 => binary[offset],
                5123 => BinaryPrimitives.ReadUInt16LittleEndian(binary.AsSpan(offset)),
                _ => BinaryPrimitives.ReadUInt32LittleEndian(binary.AsSpan(offset)),
            };
        }
        return values;
    }

    private static byte[] ReadView(GltfBufferView view, byte[] binary)
    {
        return binary.AsSpan(view.ByteOffset, view.ByteLength).ToArray();
    }

    private static Matrix4x4 ReadNodeTransform(JsonElement node)
    {
        if (node.TryGetProperty("matrix", out JsonElement matrix))
        {
            float[] values = matrix.EnumerateArray().Select(static value => value.GetSingle()).ToArray();
            if (values.Length != 16)
            {
                throw new InvalidDataException("glTF node matrix must contain 16 values.");
            }
            return new Matrix4x4(
                values[0], values[4], values[8], values[12],
                values[1], values[5], values[9], values[13],
                values[2], values[6], values[10], values[14],
                values[3], values[7], values[11], values[15]);
        }
        Vector3 translation = ReadVector3(node, "translation", Vector3.Zero);
        Vector3 scale = ReadVector3(node, "scale", Vector3.One);
        Quaternion rotation = node.TryGetProperty("rotation", out JsonElement rotationValue)
            ? new Quaternion(
                rotationValue[0].GetSingle(),
                rotationValue[1].GetSingle(),
                rotationValue[2].GetSingle(),
                rotationValue[3].GetSingle())
            : Quaternion.Identity;
        Matrix4x4 result = Matrix4x4.Transpose(Matrix4x4.CreateFromQuaternion(rotation));
        result.M11 *= scale.X;
        result.M21 *= scale.X;
        result.M31 *= scale.X;
        result.M12 *= scale.Y;
        result.M22 *= scale.Y;
        result.M32 *= scale.Y;
        result.M13 *= scale.Z;
        result.M23 *= scale.Z;
        result.M33 *= scale.Z;
        result.M14 = translation.X;
        result.M24 = translation.Y;
        result.M34 = translation.Z;
        result.M44 = 1;
        return result;
    }

    private static Vector3 ReadVector3(JsonElement node, string name, Vector3 fallback)
    {
        if (!node.TryGetProperty(name, out JsonElement value))
        {
            return fallback;
        }
        return new Vector3(value[0].GetSingle(), value[1].GetSingle(), value[2].GetSingle());
    }

    private static float[] BuildDefaultNormals(int vertexCount)
    {
        float[] values = new float[checked(vertexCount * 3)];
        for (int index = 0; index < vertexCount; index++)
        {
            values[index * 3 + 1] = 1;
        }
        return values;
    }

    private static void Normalize(List<GltfPrimitive> primitives)
    {
        bool found = false;
        Vector3 min = default;
        Vector3 max = default;
        foreach (GltfPrimitive primitive in primitives)
        {
            for (int index = 0; index < primitive.Positions.Length; index += 3)
            {
                Vector3 point = TransformColumn(primitive.Transform, new Vector3(
                    primitive.Positions[index],
                    primitive.Positions[index + 1],
                    primitive.Positions[index + 2]));
                if (!found)
                {
                    min = max = point;
                    found = true;
                }
                else
                {
                    min = Vector3.Min(min, point);
                    max = Vector3.Max(max, point);
                }
            }
        }
        if (!found)
        {
            return;
        }
        Vector3 center = (min + max) * 0.5f;
        Vector3 extent = max - min;
        float largest = MathF.Max(extent.X, MathF.Max(extent.Y, extent.Z));
        if (largest <= 0)
        {
            return;
        }
        float scale = 3f / largest;
        Matrix4x4 normalization = Matrix4x4.Identity;
        normalization.M11 = normalization.M22 = normalization.M33 = scale;
        normalization.M14 = -center.X * scale;
        normalization.M24 = -center.Y * scale;
        normalization.M34 = -center.Z * scale;
        foreach (GltfPrimitive primitive in primitives)
        {
            primitive.Transform = normalization * primitive.Transform;
        }
    }

    private static Vector3 TransformColumn(Matrix4x4 matrix, Vector3 point)
    {
        return new Vector3(
            matrix.M11 * point.X + matrix.M12 * point.Y + matrix.M13 * point.Z + matrix.M14,
            matrix.M21 * point.X + matrix.M22 * point.Y + matrix.M23 * point.Z + matrix.M24,
            matrix.M31 * point.X + matrix.M32 * point.Y + matrix.M33 * point.Z + matrix.M34);
    }

    private readonly record struct GltfBufferView(int ByteOffset, int ByteLength, int ByteStride);
    private readonly record struct GltfAccessor(int BufferView, int ByteOffset, int ComponentType, int Count, string Type);
}

internal sealed class GltfPrimitive
{
    public GltfPrimitive(float[] positions, float[] normals, float[] uvs, uint[] indices, Matrix4x4 transform, int textureIndex)
    {
        Positions = positions;
        Normals = normals;
        Uvs = uvs;
        Indices = indices;
        Transform = transform;
        TextureIndex = textureIndex;
    }

    public float[] Positions { get; }
    public float[] Normals { get; }
    public float[] Uvs { get; }
    public uint[] Indices { get; }
    public Matrix4x4 Transform { get; set; }
    public int TextureIndex { get; }
}

internal sealed record GltfImage(byte[] Bytes, string MimeType)
{
    public EzGfx.Native.EzGfxSourceTextureFormat SourceFormat => MimeType switch
    {
        "image/jpeg" => EzGfx.Native.EzGfxSourceTextureFormat.Jpeg,
        "image/png" => EzGfx.Native.EzGfxSourceTextureFormat.Png,
        "image/ktx2" => EzGfx.Native.EzGfxSourceTextureFormat.Ktx2,
        _ => throw new InvalidDataException($"Unsupported glTF image MIME type {MimeType}."),
    };
}
