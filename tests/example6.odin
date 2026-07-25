#+private
package tests

import shared "../examples/shared"
import gfx "../src"
import cgltf "vendor:cgltf"
import "core:math"
import "core:testing"
import vk "vendor:vulkan"

EXAMPLE6_WIDTH :: 640
EXAMPLE6_HEIGHT :: 480
EXAMPLE6_TEST_FRAMES :: 2
EXAMPLE6_COMPUTE_SHADER_PATH :: cstring("examples/6_sponza_ktx2/compute.slang")
EXAMPLE6_DRAW_SHADER_PATH :: cstring("examples/6_sponza_ktx2/draw.slang")
EXAMPLE6_GLTF_PATH :: "examples/shared/assets/sponza.glb"
EXAMPLE6_POSITION_HEAP :: "position"
EXAMPLE6_NORMAL_HEAP :: "normal"
EXAMPLE6_UV_HEAP :: "uv"
EXAMPLE6_ORBIT_CENTER :: shared.Vec3{0.0, -0.32, 0.0}
EXAMPLE6_NEAR_PLANE :: f32(0.02)
EXAMPLE6_WHITE_PIXEL: [4]u8 = {255, 255, 255, 255}

Example6_Primitive_Record :: struct {
	first_index:   u32,
	index_count:   u32,
	vertex_offset: u32,
	normal_offset: u32,
	uv_offset:     u32,
	texture_id:    u32,
	_pad0:         u32,
	_pad1:         u32,
	transform:     shared.Mat4,
}
Example6_Compute_Push_Constants :: struct { primitive_count: u32 }
Example6_Draw_Push_Constants :: struct { mvp: shared.Mat4 }

Example6_Test_App :: struct {
	ctx:                   gfx.Ez_Gfx_Context_Handle,
	window:                shared.Example_Window,
	compute_shader:        gfx.Ez_Gfx_Shader_Handle,
	draw_shader:           gfx.Ez_Gfx_Shader_Handle,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	mesh:                  shared.Loaded_Mesh,
	mesh_loaded:           bool,
	primitive_records:     []Example6_Primitive_Record,
	texture_ids:           [dynamic]gfx.Ez_Gfx_Texture_Handle,
	texture_ids_by_image:  map[^cgltf.image]gfx.Ez_Gfx_Texture_Handle,
	fallback_texture_id:   gfx.Ez_Gfx_Texture_Handle,
	fallback_pixel:        [4]u8,
	camera:                shared.Orbit_Camera,
	camera_start:          shared.Orbit_Camera_Start,
	validation_log:        Validation_Log,
}

@(test)
example6_sponza_ktx2_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Example6_Test_App
	if !testing.expect(t, example6_test_init_app(&app), "example 6 render test failed during init") {
		example6_test_cleanup(&app)
		return
	}
	defer example6_test_cleanup(&app)
	frames_drawn := 0
	attempts := 0
	for frames_drawn < EXAMPLE6_TEST_FRAMES && attempts < 60 {
		attempts += 1
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return
		if example6_test_draw_frame(&app) do frames_drawn += 1
	}
	if !testing.expect_value(t, frames_drawn, EXAMPLE6_TEST_FRAMES) do return
	gfx.ez_gfx_context_wait_idle(app.ctx)
	expect_window_snapshot(t, &app.window, "example6")
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

example6_test_init_app :: proc(app: ^Example6_Test_App) -> bool {
	if !shared.example_glfw_init() do return false
	app.camera = shared.orbit_camera_default()
	app.camera_start = shared.Orbit_Camera_Start{yaw = math.to_radians_f32(90), pitch = math.to_radians_f32(8), distance = 0.45}
	shared.orbit_camera_apply_start(&app.camera, EXAMPLE6_ORBIT_CENTER, app.camera_start)
	ctx, ctx_status := gfx.ez_gfx_context_create({
		enable_validation = true,
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	if ctx_status != .Ok do return false
	app.ctx = ctx
	if gfx.ez_gfx_enable_all_decoders_for_context(app.ctx) != .Ok do return false
	if !shared.example_window_create(&app.window, app.ctx, "ez_gfx_api example 6 test", EXAMPLE6_WIDTH, EXAMPLE6_HEIGHT) do return false
	if gfx.ez_gfx_surface_init_device(app.ctx, app.window.surface) != .Ok do return false
	if gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, u32(app.window.framebuffer_width), u32(app.window.framebuffer_height)) != .Ok do return false
	return example6_test_init_resources(app)
}

example6_test_init_resources :: proc(app: ^Example6_Test_App) -> bool {
	compute_shader, compute_status := gfx.ez_gfx_shader_create(app.ctx, {path = EXAMPLE6_COMPUTE_SHADER_PATH, compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY, kind = .Compute})
	app.compute_shader = compute_shader
	if compute_status != .Ok do return false
	app.compute_shader_loaded = true
	draw_shader, draw_status := gfx.ez_gfx_shader_create(app.ctx, {path = EXAMPLE6_DRAW_SHADER_PATH, vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY, fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY})
	app.draw_shader = draw_shader
	if draw_status != .Ok do return false
	app.draw_shader_loaded = true
	mesh, mesh_ok := shared.gltf_load_meshes(EXAMPLE6_GLTF_PATH)
	app.mesh = mesh
	if !mesh_ok do return false
	app.mesh_loaded = true
	example6_load_textures(app)
	position_stride := vk.DeviceSize(size_of([4]f32))
	normal_stride := vk.DeviceSize(size_of([4]f32))
	uv_stride := vk.DeviceSize(size_of([4]f32))
	if gfx.ez_gfx_index_heap_create(app.ctx, shared.gltf_mesh_index_heap_bytes(&app.mesh) + 4096, "example 6 test index heap") != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, EXAMPLE6_POSITION_HEAP, shared.gltf_mesh_vertex_heap_bytes(&app.mesh, position_stride) + 4096, position_stride) != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, EXAMPLE6_NORMAL_HEAP, shared.gltf_mesh_vertex_heap_bytes(&app.mesh, normal_stride) + 4096, normal_stride) != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, EXAMPLE6_UV_HEAP, shared.gltf_mesh_vertex_heap_bytes(&app.mesh, uv_stride) + 4096, uv_stride) != .Ok do return false
	if !example6_upload_primitives(app.ctx, &app.mesh) do return false
	app.primitive_records = make([]Example6_Primitive_Record, len(app.mesh.descriptors))
	for descriptor, i in app.mesh.descriptors {
		texture := app.fallback_texture_id
		if image := shared.gltf_base_color_image(&app.mesh.cpu_primitives[i]); image != nil {
			if mapped, ok := app.texture_ids_by_image[image]; ok do texture = mapped
		}
		app.primitive_records[i] = example6_descriptor_to_record(app.ctx, descriptor, texture)
	}
	return true
}

example6_load_textures :: proc(app: ^Example6_Test_App) {
	app.texture_ids_by_image = make(map[^cgltf.image]gfx.Ez_Gfx_Texture_Handle)
	app.fallback_pixel = EXAMPLE6_WHITE_PIXEL
	fallback, fallback_err := gfx.ez_gfx_texture_load(app.ctx, {{data = app.fallback_pixel[:]}}, {source_format = .RGBA, destination_format = .R8G8B8A8_UNORM, width = 1, height = 1, mip_count = 1, min_filter = .Linear, mag_filter = .Linear, address_mode_u = .Repeat, address_mode_v = .Repeat, debug_label = "example 6 fallback"})
	if fallback_err != .None do return
	app.fallback_texture_id = fallback
	append(&app.texture_ids, fallback)
	for &prim in app.mesh.cpu_primitives {
		image := shared.gltf_base_color_image(&prim)
		if image == nil do continue
		if _, exists := app.texture_ids_by_image[image]; exists do continue
		data := shared.gltf_image_bytes(image)
		if len(data) == 0 do continue
		texture, texture_err := gfx.ez_gfx_texture_load(app.ctx, {{data = data}}, {source_format = .KTX2, destination_format = .R8G8B8A8_UNORM, generate_mips = true, min_filter = .Linear, mag_filter = .Linear, max_anisotropy = 16.0, address_mode_u = .Repeat, address_mode_v = .Repeat, debug_label = "example 6 base color"})
		if texture_err != .None do continue
		app.texture_ids_by_image[image] = texture
		append(&app.texture_ids, texture)
	}
}

example6_descriptor_to_record :: proc(ctx: gfx.Ez_Gfx_Context_Handle, descriptor: shared.Mesh_Descriptor, texture: gfx.Ez_Gfx_Texture_Handle) -> Example6_Primitive_Record {
	binding, binding_err := gfx.ez_gfx_texture_binding_index(ctx, texture)
	if binding_err != .None do binding = 0
	return Example6_Primitive_Record{first_index = descriptor.first_index, index_count = descriptor.index_count, vertex_offset = descriptor.vertex_offset, normal_offset = descriptor.normal_vertex_offset, uv_offset = descriptor.uv_offset, texture_id = binding, transform = descriptor.transform}
}

example6_upload_primitives :: proc(ctx: gfx.Ez_Gfx_Context_Handle, mesh: ^shared.Loaded_Mesh) -> bool {
	for &cpu, prim_index in mesh.cpu_primitives {
		position_start, position_status := gfx.ez_gfx_vertex_upload(ctx, EXAMPLE6_POSITION_HEAP, cpu.positions[:])
		if position_status != .Ok do return false
		global_indices := make([]u32, len(cpu.indices))
		for index, i in cpu.indices do global_indices[i] = index + position_start
		first_index, index_status := gfx.ez_gfx_vertex_upload_indices(ctx, global_indices)
		delete(global_indices)
		if index_status != .Ok do return false
		normal_start, normal_status := gfx.ez_gfx_vertex_upload(ctx, EXAMPLE6_NORMAL_HEAP, cpu.normals[:])
		if normal_status != .Ok do return false
		uv_start, uv_status := gfx.ez_gfx_vertex_upload(ctx, EXAMPLE6_UV_HEAP, cpu.uvs[:])
		if uv_status != .Ok do return false
		descriptor := &mesh.descriptors[prim_index]
		descriptor.first_index = first_index
		descriptor.vertex_offset = position_start
		descriptor.normal_vertex_offset = normal_start
		descriptor.uv_offset = uv_start
	}
	return true
}

example6_test_draw_frame :: proc(app: ^Example6_Test_App) -> bool {
	if gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) != .Ok do return false
	primitive_count := u32(len(app.primitive_records))
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(app.ctx, primitive_count, "example 6 test draw commands")
	if indirect_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	primitives, primitive_status := gfx.ez_gfx_acquire_structured(app.ctx, Example6_Primitive_Record, primitive_count, "example 6 primitives")
	if primitive_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	if gfx.ez_gfx_structured_write(app.ctx, primitives, raw_data(app.primitive_records), u64(len(app.primitive_records) * size_of(Example6_Primitive_Record))) != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	compute_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "primitives", structured = primitives}, {name = "draw_commands", indirect = indirect}}
	compute_push := Example6_Compute_Push_Constants{primitive_count = primitive_count}
	_, compute_status := gfx.ez_gfx_render_add_compute_pipeline_handles(app.ctx, app.compute_shader, primitive_count, 1, 1, compute_bindings[:], rawptr(&compute_push), u32(size_of(compute_push)))
	if compute_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	if gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, primitive_count) != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(math.to_radians_f32(60), shared.window_aspect(&app.window), EXAMPLE6_NEAR_PLANE, 100.0)
	dynamic_state := gfx.Ez_Gfx_Render_Dynamic_State{front_face = .COUNTER_CLOCKWISE, cull_mode = .BACK}
	draw_push := Example6_Draw_Push_Constants{mvp = shared.mat4_mul(projection, view)}
	draw_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "primitives", structured = primitives}}
	_, draw_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, app.draw_shader, indirect, draw_bindings[:], dynamic_state, rawptr(&draw_push), u32(size_of(draw_push)))
	if draw_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	return gfx.ez_gfx_finish_render_context(app.ctx) == .Ok
}

example6_test_cleanup :: proc(app: ^Example6_Test_App) {
	gfx.ez_gfx_context_wait_idle(app.ctx)
	for texture in app.texture_ids { _ = gfx.ez_gfx_texture_unload(app.ctx, texture) }
	if len(app.texture_ids) > 0 { delete(app.texture_ids) }
	if app.texture_ids_by_image != nil { delete(app.texture_ids_by_image) }
	if app.primitive_records != nil { delete(app.primitive_records) }
	if app.mesh_loaded { shared.gltf_loaded_mesh_destroy(&app.mesh); app.mesh_loaded = false }
	if app.compute_shader_loaded { _ = gfx.ez_gfx_shader_release(app.ctx, app.compute_shader); app.compute_shader_loaded = false }
	if app.draw_shader_loaded { _ = gfx.ez_gfx_shader_release(app.ctx, app.draw_shader); app.draw_shader_loaded = false }
	shared.example_window_destroy(&app.window)
	if app.ctx != 0 do _ = gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}
