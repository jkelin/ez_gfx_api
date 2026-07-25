#ifndef EZ_GFX_API_H
#define EZ_GFX_API_H

#include <stdint.h>
#include <stddef.h>

#define EZ_GFX_ABI_VERSION 7u

#if defined(__clang__)
#  if __has_attribute(access)
#    define EZ_GFX_ACCESS(...) __attribute__((access(__VA_ARGS__)))
#  else
#    define EZ_GFX_ACCESS(...)
#  endif
#  if __has_attribute(counted_by)
#    define EZ_GFX_COUNTED_BY(field) __attribute__((counted_by(field)))
#  else
#    define EZ_GFX_COUNTED_BY(field)
#  endif
#elif defined(__GNUC__) && (__GNUC__ >= 10)
#  define EZ_GFX_ACCESS(...) __attribute__((access(__VA_ARGS__)))
#  define EZ_GFX_COUNTED_BY(field)
#else
#  define EZ_GFX_ACCESS(...)
#  define EZ_GFX_COUNTED_BY(field)
#endif

/* ABI string contract: every const char* is UTF-8 and NUL-terminated for the duration of the call. */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * EzGfxContext: Opaque packed u64 context handle (slot+1/generation in bits 0-39).
 */
typedef uint64_t EzGfxContext;
/**
 * EzGfxSurface: Opaque packed u64 surface handle; child bits index the context identity arena and resolve only as Surface.
 */
typedef uint64_t EzGfxSurface;
/**
 * EzGfxShader: Opaque packed u64 shader handle; child bits index the context identity arena and resolve only as Shader.
 */
typedef uint64_t EzGfxShader;
/**
 * EzGfxIndirectBuffer: Opaque packed u64 indirect-buffer handle; child bits index the context identity arena and resolve only as Indirect.
 */
typedef uint64_t EzGfxIndirectBuffer;
/**
 * EzGfxStructuredBuffer: Opaque packed u64 structured-buffer handle; child bits index the context identity arena and resolve only as Structured.
 */
typedef uint64_t EzGfxStructuredBuffer;
/**
 * EzGfxTexture: Opaque packed u64 texture handle; child bits index the context identity arena and resolve only as Texture.
 */
typedef uint64_t EzGfxTexture;

/**
 * EzGfxResult:
 * @EzGfxResult_Ok: The operation completed successfully.
 * @EzGfxResult_InvalidArgument: A public argument failed validation.
 * @EzGfxResult_InvalidContext: The context is null, stale, or does not own the resource.
 * @EzGfxResult_NativeFailure: The native graphics operation failed.
 * @EzGfxResult_NotReady: The operation is temporarily unavailable, such as a minimized surface.
 *
 * Result returned by context, surface, shader, buffer, and render operations.
 */
typedef enum EzGfxResult {
    EzGfxResult_Ok = 0,
    EzGfxResult_InvalidArgument = 1,
    EzGfxResult_InvalidContext = 2,
    EzGfxResult_NativeFailure = 3,
    EzGfxResult_NotReady = 4,
} EzGfxResult;

/**
 * EzGfxTextureError:
 * @EzGfxTextureError_None: The operation completed successfully.
 * @EzGfxTextureError_InvalidContext: The context is null, stale, or does not own the resource.
 * @EzGfxTextureError_InvalidArguments: Texture data or description failed validation.
 * @EzGfxTextureError_UnsupportedFormat: No registered decoder supports the source format.
 * @EzGfxTextureError_OutOfTextureHandles: The texture handle table is full.
 * @EzGfxTextureError_OutOfMemory: Texture allocation failed.
 * @EzGfxTextureError_DecodeFailed: The image decoder rejected the data.
 * @EzGfxTextureError_VulkanFailed: A Vulkan texture operation failed.
 * @EzGfxTextureError_WorkerUnavailable: No texture upload worker is available.
 * @EzGfxTextureError_NotFound: The texture handle is not loaded.
 *
 * Result returned by texture loading and unloading.
 */
typedef enum EzGfxTextureError {
    EzGfxTextureError_None = 0,
    EzGfxTextureError_InvalidContext = 1,
    EzGfxTextureError_InvalidArguments = 2,
    EzGfxTextureError_UnsupportedFormat = 3,
    EzGfxTextureError_OutOfTextureHandles = 4,
    EzGfxTextureError_OutOfMemory = 5,
    EzGfxTextureError_DecodeFailed = 6,
    EzGfxTextureError_VulkanFailed = 7,
    EzGfxTextureError_WorkerUnavailable = 8,
    EzGfxTextureError_NotFound = 9,
} EzGfxTextureError;

/**
 * EzGfxShaderKind:
 * @EzGfxShaderKind_Graphics: Vertex and fragment shader pair.
 * @EzGfxShaderKind_Compute: Compute shader.
 *
 * Shader stage family.
 */
typedef enum EzGfxShaderKind {
    EzGfxShaderKind_Graphics = 0,
    EzGfxShaderKind_Compute = 1,
} EzGfxShaderKind;

/**
 * EzGfxSurfacePlatform:
 * @EzGfxSurfacePlatform_Win32: Win32 HWND and HINSTANCE handles.
 *
 * Native surface platform.
 */
typedef enum EzGfxSurfacePlatform {
    EzGfxSurfacePlatform_Win32 = 0,
} EzGfxSurfacePlatform;

/**
 * EzGfxSourceTextureFormat:
 * @EzGfxSourceTextureFormat_Rgb: Raw RGB pixels.
 * @EzGfxSourceTextureFormat_Rgba: Raw RGBA pixels.
 * @EzGfxSourceTextureFormat_Bmp: BMP image bytes.
 * @EzGfxSourceTextureFormat_Jpeg: JPEG image bytes.
 * @EzGfxSourceTextureFormat_Png: PNG image bytes.
 * @EzGfxSourceTextureFormat_Tga: TGA image bytes.
 * @EzGfxSourceTextureFormat_Ktx2: KTX2 image bytes.
 *
 * Source image encoding.
 */
typedef enum EzGfxSourceTextureFormat {
    EzGfxSourceTextureFormat_Rgb = 0,
    EzGfxSourceTextureFormat_Rgba = 1,
    EzGfxSourceTextureFormat_Bmp = 2,
    EzGfxSourceTextureFormat_Jpeg = 3,
    EzGfxSourceTextureFormat_Png = 4,
    EzGfxSourceTextureFormat_Tga = 5,
    EzGfxSourceTextureFormat_Ktx2 = 6,
} EzGfxSourceTextureFormat;

/**
 * EzGfxTextureFilter:
 * @EzGfxTextureFilter_Nearest: Nearest-neighbor filtering.
 * @EzGfxTextureFilter_Linear: Linear filtering.
 *
 * Texture sampling filter.
 */
typedef enum EzGfxTextureFilter {
    EzGfxTextureFilter_Nearest = 0,
    EzGfxTextureFilter_Linear = 1,
} EzGfxTextureFilter;

/**
 * EzGfxTextureAddressMode:
 * @EzGfxTextureAddressMode_Repeat: Repeat coordinates.
 * @EzGfxTextureAddressMode_ClampToEdge: Clamp coordinates to the edge.
 *
 * Texture addressing mode.
 */
typedef enum EzGfxTextureAddressMode {
    EzGfxTextureAddressMode_Repeat = 0,
    EzGfxTextureAddressMode_ClampToEdge = 1,
} EzGfxTextureAddressMode;

/**
 * EzGfxTextureDestinationFormat:
 * @EzGfxTextureDestinationFormat_Rgba8Unorm: 8-bit normalized RGBA.
 *
 * Destination texture format.
 */
typedef enum EzGfxTextureDestinationFormat {
    EzGfxTextureDestinationFormat_Rgba8Unorm = 0,
} EzGfxTextureDestinationFormat;

/**
 * EzGfxContextDesc:
 * @enable_debug: Non-zero enables debug utilities.
 * @enable_validation: Non-zero enables validation layers.
 * @surface_platform: Value from EzGfxSurfacePlatform.
 *
 * Context creation options.
 */
typedef struct EzGfxContextDesc {
    int32_t enable_debug;
    int32_t enable_validation;
    uint32_t surface_platform;
} EzGfxContextDesc;

/**
 * EzGfxSurfaceDesc:
 * @window (not nullable): Native HWND.
 * @display (not nullable): Native HINSTANCE.
 * @platform: Value from EzGfxSurfacePlatform.
 * @width: Initial framebuffer width.
 * @height: Initial framebuffer height.
 *
 * Caller-owned native window used to create a Vulkan surface.
 */
typedef struct EzGfxSurfaceDesc {
    void * window;
    void * display;
    uint32_t platform;
    uint32_t width;
    uint32_t height;
} EzGfxSurfaceDesc;

/**
 * EzGfxShaderDesc:
 * @path (not nullable): UTF-8, NUL-terminated shader path.
 * @vertex_entry (nullable): Optional UTF-8 vertex entry point.
 * @fragment_entry (nullable): Optional UTF-8 fragment entry point.
 * @compute_entry (nullable): Optional UTF-8 compute entry point.
 * @kind: Value from EzGfxShaderKind.
 *
 * Shader source and entry-point metadata.
 */
typedef struct EzGfxShaderDesc {
    const char * path;
    const char * vertex_entry;
    const char * fragment_entry;
    const char * compute_entry;
    uint32_t kind;
} EzGfxShaderDesc;

/**
 * EzGfxTextureDesc:
 * @source_format: Value from EzGfxSourceTextureFormat.
 * @destination_format: Value from EzGfxTextureDestinationFormat.
 * @width: Decoded width for raw pixels.
 * @height: Decoded height for raw pixels.
 * @mip_count: Number of mip levels, or zero for decoder defaults.
 * @generate_mips: Non-zero requests mip generation.
 * @min_filter: Value from EzGfxTextureFilter.
 * @mag_filter: Value from EzGfxTextureFilter.
 * @max_anisotropy: Requested anisotropy; zero uses the default.
 * @address_mode_u: Value from EzGfxTextureAddressMode.
 * @address_mode_v: Value from EzGfxTextureAddressMode.
 * @address_mode_w: Value from EzGfxTextureAddressMode.
 * @debug_label (nullable): Optional UTF-8 debug label.
 *
 * Texture decoding and sampling metadata.
 */
typedef struct EzGfxTextureDesc {
    uint32_t source_format;
    uint32_t destination_format;
    uint32_t width;
    uint32_t height;
    uint32_t mip_count;
    int32_t generate_mips;
    uint32_t min_filter;
    uint32_t mag_filter;
    float max_anisotropy;
    uint32_t address_mode_u;
    uint32_t address_mode_v;
    uint32_t address_mode_w;
    const char * debug_label;
} EzGfxTextureDesc;

/**
 * EzGfxBinding:
 * @name (not nullable): UTF-8 shader binding name.
 * @structured: Optional structured buffer handle.
 * @indirect: Optional indirect buffer handle.
 *
 * Shader resource binding.
 */
typedef struct EzGfxBinding {
    const char * name;
    EzGfxStructuredBuffer structured;
    EzGfxIndirectBuffer indirect;
} EzGfxBinding;

/**
 * EzGfxDynamicState:
 * @cull_mode: 0 none, 1 front, 2 back, 3 both.
 * @front_face: 0 counter-clockwise, 1 clockwise.
 * @primitive_type: Primitive topology enum value.
 * @blend_mode: Blend mode enum value.
 *
 * Optional dynamic state overrides.
 */
typedef struct EzGfxDynamicState {
    uint32_t cull_mode;
    uint32_t front_face;
    uint32_t primitive_type;
    uint32_t blend_mode;
} EzGfxDynamicState;

/**
 * EzGfxDrawIndexedCommand:
 * @index_count: Number of indices.
 * @instance_count: Number of instances.
 * @first_index: First index.
 * @vertex_offset: Signed vertex offset.
 * @first_instance: First instance.
 *
 * One indexed indirect draw command.
 */
typedef struct EzGfxDrawIndexedCommand {
    uint32_t index_count;
    uint32_t instance_count;
    uint32_t first_index;
    int32_t vertex_offset;
    uint32_t first_instance;
} EzGfxDrawIndexedCommand;

/**
 * EzGfxByteBuffer:
 * @length: Number of bytes in data.
 * @data (nullable) (array length=length): Byte range; nullable only when length is zero.
 *
 * Pointer-plus-length byte range for ABI consumers.
 */
typedef struct EzGfxByteBuffer {
    size_t length;
    const uint8_t * data EZ_GFX_COUNTED_BY(length);
} EzGfxByteBuffer;

/**
 * ez_gfx_c_abi_version:
 *
 * Returns: (transfer none): ABI version; no context is required.
 */
uint32_t ez_gfx_c_abi_version(void);

/**
 * ez_gfx_c_context_create:
 * @desc (in) (not nullable): Context creation options.
 * @out_context (out caller-allocates): Receives the opaque context handle.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a creation error.
 */
EzGfxResult ez_gfx_c_context_create(const EzGfxContextDesc * desc, EzGfxContext * out_context) EZ_GFX_ACCESS(write_only, 2);

/**
 * ez_gfx_c_context_wait_idle:
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or EzGfxResult_InvalidContext.
 */
EzGfxResult ez_gfx_c_context_wait_idle(EzGfxContext context);

/**
 * ez_gfx_c_context_destroy:
 * @context: Context to destroy; null is ignored.
 *
 * Returns: (transfer none): No return value; null handles are ignored.
 */
void ez_gfx_c_context_destroy(EzGfxContext context);

/**
 * ez_gfx_c_surface_create:
 * @desc (in) (not nullable): Window and initial extent.
 * @out_surface (out caller-allocates): Receives the opaque surface handle.
 * @context (not nullable): Context that owns the surface.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a validation/native error.
 */
EzGfxResult ez_gfx_c_surface_create(const EzGfxSurfaceDesc * desc, EzGfxSurface * out_surface, EzGfxContext context) EZ_GFX_ACCESS(write_only, 2);

/**
 * ez_gfx_c_context_init_device:
 * @surface: Surface owned by context.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a native failure.
 */
EzGfxResult ez_gfx_c_context_init_device(EzGfxSurface surface, EzGfxContext context);

/**
 * ez_gfx_c_surface_resize:
 * @surface: Surface to resize.
 * @width: New width; zero is valid only with zero height for minimized state.
 * @height: New height; zero is valid only with zero width for minimized state.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok, EzGfxResult_NotReady, or an error.
 */
EzGfxResult ez_gfx_c_surface_resize(EzGfxSurface surface, uint32_t width, uint32_t height, EzGfxContext context);

/**
 * ez_gfx_c_surface_get_extent:
 * @surface: Surface to query.
 * @out_width (out caller-allocates): Receives width.
 * @out_height (out caller-allocates): Receives height.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_NotReady while minimized.
 */
EzGfxResult ez_gfx_c_surface_get_extent(EzGfxSurface surface, uint32_t * out_width, uint32_t * out_height, EzGfxContext context) EZ_GFX_ACCESS(write_only, 2) EZ_GFX_ACCESS(write_only, 3);

/**
 * ez_gfx_c_surface_resize_pending:
 * @surface: Surface to query.
 * @out_pending (out caller-allocates): Receives 0 or 1.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or an error.
 */
EzGfxResult ez_gfx_c_surface_resize_pending(EzGfxSurface surface, int32_t * out_pending, EzGfxContext context) EZ_GFX_ACCESS(write_only, 2);

/**
 * ez_gfx_c_surface_set_snapshot_cache:
 * @surface: Surface to configure.
 * @enabled: Must be zero or one.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or EzGfxResult_InvalidArgument.
 */
EzGfxResult ez_gfx_c_surface_set_snapshot_cache(EzGfxSurface surface, int32_t enabled, EzGfxContext context);

/**
 * ez_gfx_c_surface_destroy:
 * @surface: Surface to destroy.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): No return value; null handles are ignored.
 */
void ez_gfx_c_surface_destroy(EzGfxSurface surface, EzGfxContext context);

/**
 * ez_gfx_c_shader_compile:
 * @desc (in) (not nullable): Shader description.
 * @out_shader (out caller-allocates): Receives the shader handle.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a compile error.
 */
EzGfxResult ez_gfx_c_shader_compile(const EzGfxShaderDesc * desc, EzGfxShader * out_shader, EzGfxContext context) EZ_GFX_ACCESS(write_only, 2);

/**
 * ez_gfx_c_shader_destroy:
 * @shader: Shader to destroy.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): No return value; null handles are ignored.
 */
void ez_gfx_c_shader_destroy(EzGfxShader shader, EzGfxContext context);

/**
 * ez_gfx_c_vertex_heap_create:
 * @name (not nullable): UTF-8 heap name.
 * @capacity: Heap capacity in bytes.
 * @stride: Element stride in bytes.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or an error.
 */
EzGfxResult ez_gfx_c_vertex_heap_create(const char * name, uint64_t capacity, uint64_t stride, EzGfxContext context);

/**
 * ez_gfx_c_index_heap_create:
 * @capacity: Heap capacity in bytes.
 * @debug_name (not nullable): UTF-8 debug name.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or an error.
 */
EzGfxResult ez_gfx_c_index_heap_create(uint64_t capacity, const char * debug_name, EzGfxContext context);

/**
 * ez_gfx_c_vertex_upload_indices:
 * @data (in) (not nullable) (array length=count): Index data.
 * @count: Number of indices.
 * @out_start_index (out caller-allocates): Receives the allocated first index.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a queueing error.
 */
EzGfxResult ez_gfx_c_vertex_upload_indices(const void * data, uint32_t count, uint32_t * out_start_index, EzGfxContext context) EZ_GFX_ACCESS(read_only, 1, 2) EZ_GFX_ACCESS(write_only, 3);

/**
 * ez_gfx_c_vertex_upload:
 * @heap_name (not nullable): UTF-8 heap name.
 * @data (in) (not nullable) (bytes=element_size) (array length=element_count): Vertex data; its byte length must equal element_count multiplied by element_size.
 * @element_count: Number of vertices.
 * @element_size: Vertex element size in bytes.
 * @out_start_index (out caller-allocates): Receives the allocated first vertex.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a queueing error.
 */
EzGfxResult ez_gfx_c_vertex_upload(const char * heap_name, const void * data, uint32_t element_count, uint64_t element_size, uint32_t * out_start_index, EzGfxContext context) EZ_GFX_ACCESS(write_only, 5);

/**
 * ez_gfx_c_enable_all_decoders:
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a registration error.
 */
EzGfxResult ez_gfx_c_enable_all_decoders(EzGfxContext context);

/**
 * ez_gfx_c_texture_load:
 * @data (in) (not nullable) (array length=data_size): Encoded image bytes.
 * @data_size: Number of bytes in data.
 * @desc (in) (not nullable): Texture description.
 * @out_texture (out caller-allocates): Receives the texture handle.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxTextureError_None or a typed texture error.
 */
EzGfxTextureError ez_gfx_c_texture_load(const void * data, uint64_t data_size, const EzGfxTextureDesc * desc, EzGfxTexture * out_texture, EzGfxContext context) EZ_GFX_ACCESS(read_only, 1, 2) EZ_GFX_ACCESS(write_only, 4);

/**
 * ez_gfx_c_texture_binding_index:
 * @texture: Texture handle.
 * @out_binding_index (out caller-allocates): Receives the bindless descriptor index.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxTextureError_None or a typed texture error.
 */
EzGfxTextureError ez_gfx_c_texture_binding_index(EzGfxTexture texture, uint32_t * out_binding_index, EzGfxContext context) EZ_GFX_ACCESS(write_only, 2);

/**
 * ez_gfx_c_texture_unload:
 * @texture: Texture handle.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxTextureError_None or a typed texture error.
 */
EzGfxTextureError ez_gfx_c_texture_unload(EzGfxTexture texture, EzGfxContext context);

/**
 * ez_gfx_c_begin_render:
 * @surface: Surface to acquire.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_NotReady for a minimized or unavailable frame.
 */
EzGfxResult ez_gfx_c_begin_render(EzGfxSurface surface, EzGfxContext context);

/**
 * ez_gfx_c_acquire_indirect:
 * @capacity: Number of draw commands.
 * @debug_name (not nullable): UTF-8 debug name.
 * @out_indirect (out caller-allocates): Receives the buffer handle.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or EzGfxResult_NotReady.
 */
EzGfxResult ez_gfx_c_acquire_indirect(uint32_t capacity, const char * debug_name, EzGfxIndirectBuffer * out_indirect, EzGfxContext context) EZ_GFX_ACCESS(write_only, 3);

/**
 * ez_gfx_c_indirect_write_draw:
 * @indirect: Indirect buffer handle.
 * @index: Command index.
 * @command (in) (not nullable): Command data.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or EzGfxResult_InvalidArgument.
 */
EzGfxResult ez_gfx_c_indirect_write_draw(EzGfxIndirectBuffer indirect, uint32_t index, const EzGfxDrawIndexedCommand * command, EzGfxContext context);

/**
 * ez_gfx_c_indirect_set_draw_count:
 * @indirect: Indirect buffer handle.
 * @count: Number of commands.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or EzGfxResult_InvalidArgument.
 */
EzGfxResult ez_gfx_c_indirect_set_draw_count(EzGfxIndirectBuffer indirect, uint32_t count, EzGfxContext context);

/**
 * ez_gfx_c_indirect_release:
 * @indirect: Indirect buffer handle.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): No return value; null handles are ignored.
 */
void ez_gfx_c_indirect_release(EzGfxIndirectBuffer indirect, EzGfxContext context);

/**
 * ez_gfx_c_structured_acquire:
 * @element_size: Element size in bytes.
 * @element_count: Number of elements.
 * @debug_name (not nullable): UTF-8 debug name.
 * @out_structured (out caller-allocates): Receives the buffer handle.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or EzGfxResult_NotReady.
 */
EzGfxResult ez_gfx_c_structured_acquire(uint32_t element_size, uint32_t element_count, const char * debug_name, EzGfxStructuredBuffer * out_structured, EzGfxContext context) EZ_GFX_ACCESS(write_only, 4);

/**
 * ez_gfx_c_structured_write:
 * @structured: Structured buffer handle.
 * @data (in) (not nullable) (array length=data_size): Bytes to copy.
 * @data_size: Number of bytes; zero is allowed.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or EzGfxResult_InvalidArgument.
 */
EzGfxResult ez_gfx_c_structured_write(EzGfxStructuredBuffer structured, const void * data, uint64_t data_size, EzGfxContext context) EZ_GFX_ACCESS(read_only, 2, 3);

/**
 * ez_gfx_c_structured_release:
 * @structured: Structured buffer handle.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): No return value; null handles are ignored.
 */
void ez_gfx_c_structured_release(EzGfxStructuredBuffer structured, EzGfxContext context);

/**
 * ez_gfx_c_render_add_vertex_pipeline:
 * @shader: Graphics shader handle.
 * @indirect: Indirect buffer handle.
 * @bindings (in) (nullable) (array length=binding_count): Shader resource bindings.
 * @binding_count: Number of bindings; no more than 16.
 * @dynamic_state (in) (nullable): Optional pipeline state override.
 * @push_constants (in) (nullable) (array length=push_constant_size): Push-constant bytes.
 * @push_constant_size: Number of push-constant bytes; no more than 128.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a validation/native error.
 */
EzGfxResult ez_gfx_c_render_add_vertex_pipeline(EzGfxShader shader, EzGfxIndirectBuffer indirect, const EzGfxBinding * bindings, uint32_t binding_count, const EzGfxDynamicState * dynamic_state, const void * push_constants, uint32_t push_constant_size, EzGfxContext context) EZ_GFX_ACCESS(read_only, 3, 4) EZ_GFX_ACCESS(read_only, 6, 7);

/**
 * ez_gfx_c_render_add_compute_pipeline:
 * @shader: Compute shader handle.
 * @dispatch_x: X workgroup count.
 * @dispatch_y: Y workgroup count.
 * @dispatch_z: Z workgroup count.
 * @bindings (in) (nullable) (array length=binding_count): Shader resource bindings.
 * @binding_count: Number of bindings; no more than 16.
 * @push_constants (in) (nullable) (array length=push_constant_size): Push-constant bytes.
 * @push_constant_size: Number of push-constant bytes; no more than 128.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a validation/native error.
 */
EzGfxResult ez_gfx_c_render_add_compute_pipeline(EzGfxShader shader, uint32_t dispatch_x, uint32_t dispatch_y, uint32_t dispatch_z, const EzGfxBinding * bindings, uint32_t binding_count, const void * push_constants, uint32_t push_constant_size, EzGfxContext context) EZ_GFX_ACCESS(read_only, 5, 6) EZ_GFX_ACCESS(read_only, 7, 8);

/**
 * ez_gfx_c_finish_render:
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a render failure.
 */
EzGfxResult ez_gfx_c_finish_render(EzGfxContext context);

/**
 * ez_gfx_c_screenshot_save:
 * @surface: Surface to capture.
 * @path (not nullable): UTF-8, NUL-terminated output path.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok or a native failure.
 */
EzGfxResult ez_gfx_c_screenshot_save(EzGfxSurface surface, const char * path, EzGfxContext context);

/**
 * ez_gfx_c_imgui_render_demo:
 * @surface: Surface to render.
 * @context (not nullable): Owning context.
 *
 * Returns: (transfer none): Returns EzGfxResult_Ok, EzGfxResult_NotReady, or a native failure.
 */
EzGfxResult ez_gfx_c_imgui_render_demo(EzGfxSurface surface, EzGfxContext context);

#ifdef __cplusplus
}
#endif

#endif
