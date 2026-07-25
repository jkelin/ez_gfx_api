#+private
package tests

import shared "../examples/shared"
import gfx "../src"
import "core:math"
import "core:testing"
import vk "vendor:vulkan"

EXAMPLE5_WIDTH :: 640
EXAMPLE5_HEIGHT :: 480
EXAMPLE5_TEST_FRAMES :: 2
EXAMPLE5_COMPUTE_SHADER_PATH :: cstring("examples/5_helmet_cgltf/compute.slang")
EXAMPLE5_DRAW_SHADER_PATH :: cstring("examples/5_helmet_cgltf/draw.slang")
EXAMPLE5_GLTF_PATH :: "examples/shared/assets/helmet.glb"
EXAMPLE5_POSITION_HEAP :: "position"
EXAMPLE5_NORMAL_HEAP :: "normal"
EXAMPLE5_ORBIT_CENTER :: shared.Vec3{0.0, 0.0, 0.0}

Example5_Primitive_Record :: struct {
	first_index:   u32,
	index_count:   u32,
	vertex_offset: u32,
	normal_offset: u32,
	transform:     shared.Mat4,
}

Example5_Compute_Push_Constants :: struct { primitive_count: u32 }
Example5_Draw_Push_Constants :: struct { mvp: shared.Mat4 }

Example5_Test_App :: struct {
	ctx:                   gfx.Ez_Gfx_Context_Handle,
	window:                shared.Example_Window,
	compute_shader:        gfx.Ez_Gfx_Shader_Handle,
	draw_shader:           gfx.Ez_Gfx_Shader_Handle,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	mesh:                  shared.Loaded_Mesh,
	mesh_loaded:           bool,
	primitive_records:     []Example5_Primitive_Record,
	camera:                shared.Orbit_Camera,
	camera_start:          shared.Orbit_Camera_Start,
	validation_log:        Validation_Log,
}

@(test)
example5_helmet_cgltf_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Example5_Test_App
	if !testing.expect(t, example5_test_init_app(&app), "example 5 render test failed during init") {
		example5_test_cleanup(&app)
		return
	}
	defer example5_test_cleanup(&app)
	frames_drawn := 0
	attempts := 0
	for frames_drawn < EXAMPLE5_TEST_FRAMES && attempts < 60 {
		attempts += 1
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return
		if example5_test_draw_frame(&app) do frames_drawn += 1
	}
	if !testing.expect_value(t, frames_drawn, EXAMPLE5_TEST_FRAMES) do return
	gfx.ez_gfx_context_wait_idle(app.ctx)
	expect_window_snapshot(t, &app.window, "example5")
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

example5_test_init_app :: proc(app: ^Example5_Test_App) -> bool {
	if !shared.example_glfw_init() do return false
	app.camera = shared.orbit_camera_default()
	app.camera_start = shared.Orbit_Camera_Start{yaw = math.to_radians_f32(35), pitch = math.to_radians_f32(22), distance = 5.0}
	shared.orbit_camera_apply_start(&app.camera, EXAMPLE5_ORBIT_CENTER, app.camera_start)
	ctx, ctx_status := gfx.ez_gfx_context_create({
		enable_validation = true,
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	if ctx_status != .Ok do return false
	app.ctx = ctx
	if gfx.ez_gfx_enable_all_decoders_for_context(app.ctx) != .Ok do return false
	if !shared.example_window_create(&app.window, app.ctx, "ez_gfx_api example 5 test", EXAMPLE5_WIDTH, EXAMPLE5_HEIGHT) do return false
	if gfx.ez_gfx_surface_init_device(app.ctx, app.window.surface) != .Ok do return false
	if gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, u32(app.window.framebuffer_width), u32(app.window.framebuffer_height)) != .Ok do return false
	return example5_test_init_resources(app)
}

example5_test_init_resources :: proc(app: ^Example5_Test_App) -> bool {
	compute_shader, compute_status := gfx.ez_gfx_shader_create(app.ctx, {path = EXAMPLE5_COMPUTE_SHADER_PATH, compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY, kind = .Compute})
	app.compute_shader = compute_shader
	if compute_status != .Ok do return false
	app.compute_shader_loaded = true
	draw_shader, draw_status := gfx.ez_gfx_shader_create(app.ctx, {path = EXAMPLE5_DRAW_SHADER_PATH, vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY, fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY})
	app.draw_shader = draw_shader
	if draw_status != .Ok do return false
	app.draw_shader_loaded = true
	mesh, mesh_ok := shared.gltf_load_meshes(EXAMPLE5_GLTF_PATH)
	app.mesh = mesh
	if !mesh_ok do return false
	app.mesh_loaded = true
	app.camera_start = shared.Orbit_Camera_Start{yaw = math.to_radians_f32(35), pitch = math.to_radians_f32(22), distance = 5.0}
	vertex_stride := vk.DeviceSize(size_of([4]f32))
	index_bytes := shared.gltf_mesh_index_heap_bytes(&app.mesh) + 4096
	vertex_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, vertex_stride) + 4096
	if gfx.ez_gfx_index_heap_create(app.ctx, index_bytes, "example 5 test index heap") != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, EXAMPLE5_POSITION_HEAP, vertex_bytes, vertex_stride) != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, EXAMPLE5_NORMAL_HEAP, vertex_bytes, vertex_stride) != .Ok do return false
	if !example5_upload_gltf_primitives(app.ctx, &app.mesh) do return false
	app.primitive_records = make([]Example5_Primitive_Record, len(app.mesh.descriptors))
	for descriptor, i in app.mesh.descriptors {
		app.primitive_records[i] = Example5_Primitive_Record{first_index = descriptor.first_index, index_count = descriptor.index_count, vertex_offset = descriptor.vertex_offset, normal_offset = descriptor.normal_vertex_offset, transform = descriptor.transform}
	}
	return true
}

example5_upload_gltf_primitives :: proc(ctx: gfx.Ez_Gfx_Context_Handle, mesh: ^shared.Loaded_Mesh) -> bool {
	for &cpu, prim_index in mesh.cpu_primitives {
		first_index, index_status := gfx.ez_gfx_vertex_upload_indices(ctx, cpu.indices[:])
		if index_status != .Ok do return false
		vertex_start, vertex_status := gfx.ez_gfx_vertex_upload(ctx, EXAMPLE5_POSITION_HEAP, cpu.positions[:])
		if vertex_status != .Ok do return false
		normal_start, normal_status := gfx.ez_gfx_vertex_upload(ctx, EXAMPLE5_NORMAL_HEAP, cpu.normals[:])
		if normal_status != .Ok do return false
		descriptor := &mesh.descriptors[prim_index]
		descriptor.first_index = first_index
		descriptor.vertex_offset = vertex_start
		descriptor.normal_vertex_offset = normal_start
	}
	return true
}

example5_test_draw_frame :: proc(app: ^Example5_Test_App) -> bool {
	if gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) != .Ok do return false
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(app.ctx, app.mesh.mesh_count, "example 5 test draw commands")
	if indirect_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	primitives, primitive_status := gfx.ez_gfx_acquire_structured(app.ctx, Example5_Primitive_Record, u32(len(app.primitive_records)), "primitives")
	if primitive_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	if gfx.ez_gfx_structured_write(app.ctx, primitives, raw_data(app.primitive_records), u64(len(app.primitive_records) * size_of(Example5_Primitive_Record))) != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	compute_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "primitives", structured = primitives}, {name = "draw_commands", indirect = indirect}}
	compute_push := Example5_Compute_Push_Constants{primitive_count = app.mesh.mesh_count}
	_, compute_status := gfx.ez_gfx_render_add_compute_pipeline_handles(app.ctx, app.compute_shader, app.mesh.mesh_count, 1, 1, compute_bindings[:], rawptr(&compute_push), u32(size_of(compute_push)))
	if compute_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	if gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, app.mesh.mesh_count) != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(math.to_radians_f32(60), shared.window_aspect(&app.window), 0.1, 100.0)
	draw_push := Example5_Draw_Push_Constants{mvp = shared.mat4_mul(projection, view)}
	draw_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "primitives", structured = primitives}}
	_, draw_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, app.draw_shader, indirect, draw_bindings[:], {}, rawptr(&draw_push), u32(size_of(draw_push)))
	if draw_status != .Ok { _ = gfx.ez_gfx_finish_render_context(app.ctx); return false }
	return gfx.ez_gfx_finish_render_context(app.ctx) == .Ok
}

example5_test_cleanup :: proc(app: ^Example5_Test_App) {
	if app.primitive_records != nil { delete(app.primitive_records); app.primitive_records = nil }
	if app.mesh_loaded { shared.gltf_loaded_mesh_destroy(&app.mesh); app.mesh_loaded = false }
	if app.compute_shader_loaded { _ = gfx.ez_gfx_shader_release(app.ctx, app.compute_shader); app.compute_shader_loaded = false }
	if app.draw_shader_loaded { _ = gfx.ez_gfx_shader_release(app.ctx, app.draw_shader); app.draw_shader_loaded = false }
	shared.example_window_destroy(&app.window)
	if app.ctx != 0 do _ = gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}
