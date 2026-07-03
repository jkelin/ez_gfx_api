package tests

import shared "../examples/shared"
import gfx "../src"
import "core:math"
import "core:testing"
import vk "vendor:vulkan"

EXAMPLE3_TEST_FRAMES :: 2
EXAMPLE3_COMPUTE_SHADER_PATH :: cstring("examples/3_compute_structured_buffer/compute.slang")
EXAMPLE3_DRAW_SHADER_PATH :: cstring("examples/3_compute_structured_buffer/draw.slang")
EXAMPLE3_POSITION_HEAP :: "position"
EXAMPLE3_NORMAL_HEAP :: "normal"

Compute_Push_Constants :: struct {
	instance_count: u32,
}

Draw_Push_Constants :: struct {
	mvp: shared.Mat4,
}

Example3_Test_App :: struct {
	ctx:                   gfx.Ez_Gfx_Ctx,
	window:                gfx.Ez_Gfx_Window,
	compute_shader:        gfx.Ez_Gfx_Shader_Program,
	draw_shader:           gfx.Ez_Gfx_Shader_Program,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	mesh_descriptor:       shared.Mesh_Descriptor,
	mesh_instance:         shared.Mesh_Instance,
	cube_index:            u32,
	cube_index_len:        u32,
	cube_vertex:           u32,
	cube_normal_vertex:    u32,
	camera:                shared.Orbit_Camera,
	validation_log:        Validation_Log,
}

@(test)
example3_compute_structured_buffer_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Example3_Test_App
	if !testing.expect(
		t,
		example3_test_init_app(&app),
		"example 3 render test failed during init",
	) {
		example3_test_cleanup(&app)
		return
	}
	defer example3_test_cleanup(&app)
	example3_test_reset_validation_counts(&app)

	frames_drawn := 0
	attempts := 0
	target_frames := max(EXAMPLE3_TEST_FRAMES, int(app.window.swapchain.image_count) + 1)
	for frames_drawn < target_frames && attempts < 60 {
		attempts += 1
		gfx.ez_gfx_window_poll_events()
		if gfx.ez_gfx_window_should_close(&app.window) do return
		if example3_test_draw_frame(&app) {
			frames_drawn += 1
		}
	}
	if !testing.expect_value(t, frames_drawn, target_frames) {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	expect_window_snapshot(t, &app.window, "example3")
	testing.expect_value(t, app.validation_log.warnings, u32(0))
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.warning, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

example3_test_init_app :: proc(app: ^Example3_Test_App) -> bool {
	if !gfx.ez_gfx_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	app.camera = shared.orbit_camera_default()
	app.camera.yaw = math.to_radians_f32(-30)
	app.camera.pitch = math.to_radians_f32(52)
	app.camera.distance = 2.2
	if !gfx.ez_gfx_window_create(
		&app.window,
		"ez_gfx_api example 3 test",
		WIDTH,
		HEIGHT,
		hidden = true,
	) {
		return false
	}
	if !gfx.ez_gfx_ctx_create_instance(
		&app.ctx,
		{
			enable_validation = true,
			validation_callback = validation_callback,
			validation_user_data = &app.validation_log,
			enable_debug = true,
		},
	) {
		return false
	}
	if !gfx.ez_gfx_window_create_surface(&app.window) do return false
	if !gfx.ez_gfx_ctx_init_device(app.window.surface) do return false
	if !gfx.ez_gfx_window_recreate_swapchain(&app.window) do return false
	return example3_test_init_resources(app)
}

example3_test_init_resources :: proc(app: ^Example3_Test_App) -> bool {
	if !gfx.ez_gfx_shader_compile(
		{
			path = EXAMPLE3_COMPUTE_SHADER_PATH,
			compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
			kind = .Compute,
		},
		&app.compute_shader,
	) {
		return false
	}
	app.compute_shader_loaded = true

	if !gfx.ez_gfx_shader_compile(
		{
			path = EXAMPLE3_DRAW_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&app.draw_shader,
	) {
		return false
	}
	app.draw_shader_loaded = true

	vertex_heap_names := [?]string{EXAMPLE3_POSITION_HEAP, EXAMPLE3_NORMAL_HEAP}
	gfx.ez_gfx_vertex_manager_create(
		&app.ctx.vertex_manager,
		vertex_heap_names[:],
		vk.DeviceSize(size_of(CUBE_TEST_POSITIONS[0])),
	)

	app.cube_index = gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		CUBE_TEST_INDICES[:],
	)
	app.cube_index_len = u32(len(CUBE_TEST_INDICES))
	app.cube_vertex = gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		EXAMPLE3_POSITION_HEAP,
		CUBE_TEST_POSITIONS[:],
	)

	normals := example3_test_cube_normals()
	defer delete(normals)
	app.cube_normal_vertex = gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		EXAMPLE3_NORMAL_HEAP,
		normals[:],
	)

	identity := shared.mat4_identity()
	app.mesh_descriptor = shared.Mesh_Descriptor {
		index_count          = app.cube_index_len,
		first_index          = app.cube_index,
		vertex_offset        = app.cube_vertex,
		normal_vertex_offset = app.cube_normal_vertex,
		transform            = identity,
	}
	app.mesh_instance = shared.Mesh_Instance {
		mesh_index = 0,
		transform  = identity,
	}
	return true
}

example3_test_cube_normals :: proc() -> [dynamic][4]f32 {
	normals := make([dynamic][4]f32, 0, len(CUBE_TEST_POSITIONS))
	for position in CUBE_TEST_POSITIONS {
		length := math.sqrt_f32(position.x * position.x + position.y * position.y + position.z * position.z)
		if length > 0 {
			append(&normals, [4]f32{position.x / length, position.y / length, position.z / length, 0})
		} else {
			append(&normals, [4]f32{0, 1, 0, 0})
		}
	}
	return normals
}

example3_test_draw_frame :: proc(app: ^Example3_Test_App) -> bool {
	if !gfx.ez_gfx_begin_render(&app.window) do return false

	indirect := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"example 3 test draw commands",
	)
	if !indirect.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	mesh_descriptors := gfx.ez_gfx_render_acquire_structured_buffer(
		shared.Mesh_Descriptor,
		1,
		"mesh_descriptors",
	)
	if !mesh_descriptors.handle.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	mesh_descriptors.elements[0] = app.mesh_descriptor

	mesh_instances := gfx.ez_gfx_render_acquire_structured_buffer(
		shared.Mesh_Instance,
		1,
		"mesh_instances",
	)
	if !mesh_instances.handle.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	mesh_instances.elements[0] = app.mesh_instance

	compute_bindings := [?]gfx.Ez_Gfx_Render_Binding {
		{name = "mesh_descriptors", structured = mesh_descriptors.handle},
		{name = "mesh_instances", structured = mesh_instances.handle},
		{name = "draw_commands", indirect = indirect},
	}
	compute := gfx.ez_gfx_render_add_compute_pipeline(
		&app.compute_shader,
		1,
		1,
		1,
		compute_bindings[:],
		Compute_Push_Constants{instance_count = 1},
	)
	if !compute.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(
		math.to_radians_f32(60),
		shared.window_aspect(&app.window),
		0.1,
		100.0,
	)
	draw_bindings := [?]gfx.Ez_Gfx_Render_Binding {
		{name = "mesh_instances", structured = mesh_instances.handle},
		{name = "mesh_descriptors", structured = mesh_descriptors.handle},
	}
	draw := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.draw_shader,
		indirect,
		draw_bindings[:],
		Draw_Push_Constants{mvp = shared.mat4_mul(projection, view)},
	)
	if !draw.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	return gfx.ez_gfx_finish_render()
}

example3_test_cleanup :: proc(app: ^Example3_Test_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if app.compute_shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.compute_shader)
		app.compute_shader_loaded = false
	}
	if app.draw_shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.draw_shader)
		app.draw_shader_loaded = false
	}
	gfx.ez_gfx_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	gfx.ez_gfx_glfw_terminate()
}

example3_test_reset_validation_counts :: proc(app: ^Example3_Test_App) {
	app.validation_log = {}
	app.ctx.validation_counts = {}
}
