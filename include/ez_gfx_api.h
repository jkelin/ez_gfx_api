#ifndef EZ_GFX_API_H
#define EZ_GFX_API_H

#include <stdint.h>

#define EZ_GFX_ABI_VERSION 4u

/*
 * ABI string contract: every const char* is UTF-8 and NUL-terminated for the
 * duration of the call. Optional fields may be NULL: vertex_entry,
 * fragment_entry, compute_entry, and debug_label. All other string pointers
 * are required to be non-NULL.
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t EzGfxContext;
typedef uint64_t EzGfxSurface;
typedef uint64_t EzGfxShader;
typedef uint64_t EzGfxIndirectBuffer;
typedef uint64_t EzGfxStructuredBuffer;

typedef enum EzGfxResult {
    EzGfxResult_Ok = 0,
    EzGfxResult_InvalidArgument = 1,
    EzGfxResult_InvalidContext = 2,
    EzGfxResult_NativeFailure = 3,
    EzGfxResult_NotReady = 4
} EzGfxResult;

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
    EzGfxTextureError_NotFound = 9
} EzGfxTextureError;

typedef enum EzGfxShaderKind {
    EzGfxShaderKind_Graphics = 0,
    EzGfxShaderKind_Compute = 1
} EzGfxShaderKind;

typedef enum EzGfxSurfacePlatform {
    EzGfxSurfacePlatform_Win32 = 0
} EzGfxSurfacePlatform;

typedef enum EzGfxSourceTextureFormat {
    EzGfxSourceTextureFormat_Rgb = 0,
    EzGfxSourceTextureFormat_Rgba = 1,
    EzGfxSourceTextureFormat_Bmp = 2,
    EzGfxSourceTextureFormat_Jpeg = 3,
    EzGfxSourceTextureFormat_Png = 4,
    EzGfxSourceTextureFormat_Tga = 5,
    EzGfxSourceTextureFormat_Ktx2 = 6
} EzGfxSourceTextureFormat;

typedef enum EzGfxTextureFilter {
    EzGfxTextureFilter_Nearest = 0,
    EzGfxTextureFilter_Linear = 1
} EzGfxTextureFilter;

typedef enum EzGfxTextureAddressMode {
    EzGfxTextureAddressMode_Repeat = 0,
    EzGfxTextureAddressMode_ClampToEdge = 1
} EzGfxTextureAddressMode;

typedef enum EzGfxTextureDestinationFormat {
    EzGfxTextureDestinationFormat_Rgba8Unorm = 0
} EzGfxTextureDestinationFormat;

typedef struct EzGfxContextDesc {
    int32_t enable_debug;
    int32_t enable_validation;
    uint32_t surface_platform;
} EzGfxContextDesc;

typedef struct EzGfxSurfaceDesc {
    void *window;
    void *display;
    uint32_t platform;
    uint32_t width;
    uint32_t height;
} EzGfxSurfaceDesc;

typedef struct EzGfxShaderDesc {
    const char *path;
    const char *vertex_entry;
    const char *fragment_entry;
    const char *compute_entry;
    uint32_t kind;
} EzGfxShaderDesc;

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
    const char *debug_label;
} EzGfxTextureDesc;

typedef struct EzGfxBinding {
    const char *name;
    EzGfxStructuredBuffer structured;
    EzGfxIndirectBuffer indirect;
} EzGfxBinding;

typedef struct EzGfxDynamicState {
    uint32_t cull_mode;
    uint32_t front_face;
    uint32_t primitive_type;
    uint32_t blend_mode;
} EzGfxDynamicState;

typedef struct EzGfxDrawIndexedCommand {
    uint32_t index_count;
    uint32_t instance_count;
    uint32_t first_index;
    int32_t vertex_offset;
    uint32_t first_instance;
} EzGfxDrawIndexedCommand;

uint32_t ez_gfx_c_abi_version(void);
EzGfxResult ez_gfx_c_context_create(const EzGfxContextDesc *desc, EzGfxContext *out_context);
EzGfxResult ez_gfx_c_context_set_current(EzGfxContext context);
EzGfxResult ez_gfx_c_context_wait_idle(EzGfxContext context);
void ez_gfx_c_context_destroy(EzGfxContext context);
EzGfxResult ez_gfx_c_surface_create(EzGfxContext context, const EzGfxSurfaceDesc *desc, EzGfxSurface *out_surface);
EzGfxResult ez_gfx_c_context_init_device(EzGfxContext context, EzGfxSurface surface);
/* A zero-by-zero extent marks a minimized surface; restore with non-zero dimensions. */
EzGfxResult ez_gfx_c_surface_resize(EzGfxSurface surface, uint32_t width, uint32_t height);
EzGfxResult ez_gfx_c_surface_get_extent(EzGfxSurface surface, uint32_t *out_width, uint32_t *out_height);
EzGfxResult ez_gfx_c_surface_resize_pending(EzGfxSurface surface, int32_t *out_pending);
EzGfxResult ez_gfx_c_surface_set_snapshot_cache(EzGfxSurface surface, int32_t enabled);
void ez_gfx_c_surface_destroy(EzGfxSurface surface);
EzGfxResult ez_gfx_c_shader_compile(EzGfxContext context, const EzGfxShaderDesc *desc, EzGfxShader *out_shader);
void ez_gfx_c_shader_destroy(EzGfxShader shader);
EzGfxResult ez_gfx_c_vertex_heap_create(EzGfxContext context, const char *name, uint64_t capacity, uint64_t stride);
EzGfxResult ez_gfx_c_index_heap_create(EzGfxContext context, uint64_t capacity, const char *debug_name);
EzGfxResult ez_gfx_c_vertex_upload_indices(EzGfxContext context, const void *data, uint32_t count, uint32_t *out_start_index);
EzGfxResult ez_gfx_c_vertex_upload(EzGfxContext context, const char *heap_name, const void *data, uint32_t element_count, uint64_t element_size, uint32_t *out_start_index);
EzGfxResult ez_gfx_c_enable_all_decoders(EzGfxContext context);
EzGfxTextureError ez_gfx_c_texture_load(EzGfxContext context, const void *data, uint64_t data_size, const EzGfxTextureDesc *desc, uint32_t *out_texture_id);
EzGfxTextureError ez_gfx_c_texture_unload(EzGfxContext context, uint32_t texture_id);
EzGfxResult ez_gfx_c_begin_render(EzGfxSurface surface);
EzGfxResult ez_gfx_c_acquire_indirect(EzGfxContext context, uint32_t capacity, const char *debug_name, EzGfxIndirectBuffer *out_indirect);
EzGfxResult ez_gfx_c_indirect_write_draw(EzGfxIndirectBuffer indirect, uint32_t index, const EzGfxDrawIndexedCommand *command);
EzGfxResult ez_gfx_c_indirect_set_draw_count(EzGfxIndirectBuffer indirect, uint32_t count);
void ez_gfx_c_indirect_release(EzGfxIndirectBuffer indirect);
EzGfxResult ez_gfx_c_structured_acquire(EzGfxContext context, uint32_t element_size, uint32_t element_count, const char *debug_name, EzGfxStructuredBuffer *out_structured);
EzGfxResult ez_gfx_c_structured_write(EzGfxStructuredBuffer structured, const void *data, uint64_t data_size);
void ez_gfx_c_structured_release(EzGfxStructuredBuffer structured);
EzGfxResult ez_gfx_c_render_add_vertex_pipeline(EzGfxShader shader, EzGfxIndirectBuffer indirect, const EzGfxBinding *bindings, uint32_t binding_count, const EzGfxDynamicState *dynamic_state, const void *push_constants, uint32_t push_constant_size);
EzGfxResult ez_gfx_c_render_add_compute_pipeline(EzGfxShader shader, uint32_t dispatch_x, uint32_t dispatch_y, uint32_t dispatch_z, const EzGfxBinding *bindings, uint32_t binding_count, const void *push_constants, uint32_t push_constant_size);
EzGfxResult ez_gfx_c_finish_render(EzGfxContext context);
EzGfxResult ez_gfx_c_screenshot_save(EzGfxSurface surface, const char *path);
EzGfxResult ez_gfx_c_imgui_render_demo(EzGfxSurface surface);

#ifdef __cplusplus
}
#endif

#endif
