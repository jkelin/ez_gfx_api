#+private
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

Example3_Primitive_Record :: struct {
	first_index:   u32,
	index_count:   u32,
	vertex_offset: u32,
	normal_offset: u32,
	transform:     shared.Mat4,
}

Example3_Compute_Push_Constants :: struct {
	primitive_count: u32,
}

Example3_Draw_Push_Constants :: struct {
	mvp: shared.Mat4,
}

Example3_Test_App :: struct {
	ctx:                   gfx.Ez_Gfx_Ctx,
	window:                gfx.Ez_Gfx_Window,
	compute_shader:        gfx.Ez_Gfx_Shader_Program,
	draw_shader:           gfx.Ez_Gfx_Shader_Program,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	primitive_record:      Example3_Primitive_Record,
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
	context.user_ptr = &app.ctx
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
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return
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
	if !shared.example_glfw_init() do return false

	context.user_ptr = &app.ctx
	app.camera = shared.orbit_camera_default()
	app.camera.yaw = math.to_radians_f32(-30)
	app.camera.pitch = math.to_radians_f32(52)
	app.camera.distance = 2.2
	if !shared.example_window_create(&app.window,
		"ez_gfx_api example 3 test",
		WIDTH,
		HEIGHT) {
		return false
	}
	if gfx.ez_gfx_ctx_create_instance(&app.ctx,
		{
			enable_validation = true,
			validation_callback = validation_callback,
			validation_user_data = &app.validation_log,
			enable_debug = true,
		},) != .Ok {
		return false
	}
	if gfx.ez_gfx_window_create_surface(&app.window) != .Ok do return false
	if gfx.ez_gfx_ctx_init_device(app.window.surface) != .Ok do return false
	if gfx.ez_gfx_window_recreate_swapchain(&app.window, app.window.framebuffer_width, app.window.framebuffer_height) != .Ok do return false
	return example3_test_init_resources(app)
}

example3_test_init_resources :: proc(app: ^Example3_Test_App) -> bool {
	if gfx.ez_gfx_shader_compile({
			path = EXAMPLE3_COMPUTE_SHADER_PATH,
			compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
			kind = .Compute,
		},
		&app.compute_shader,) != .Ok {
		return false
	}
	app.compute_shader_loaded = true

	if gfx.ez_gfx_shader_compile({
			path = EXAMPLE3_DRAW_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&app.draw_shader,) != .Ok {
		return false
	}
	app.draw_shader_loaded = true

	vertex_heap_names := [?]string{EXAMPLE3_POSITION_HEAP, EXAMPLE3_NORMAL_HEAP}
	if gfx.ez_gfx_vertex_manager_create(
		&app.ctx.vertex_manager,
		vertex_heap_names[:],
		vk.DeviceSize(size_of(CUBE_TEST_POSITIONS[0])),
	) != .Ok {
		return false
	}

	index_start, index_status := gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		CUBE_TEST_INDICES[:],
	)
	if index_status != .Ok do return false
	app.cube_index = index_start
	app.cube_index_len = u32(len(CUBE_TEST_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		EXAMPLE3_POSITION_HEAP,
		CUBE_TEST_POSITIONS[:],
	)
	if vertex_status != .Ok do return false
	app.cube_vertex = vertex_start

	normals := example3_test_cube_normals()
	defer delete(normals)
	normal_start, normal_status := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		EXAMPLE3_NORMAL_HEAP,
		normals[:],
	)
	if normal_status != .Ok do return false
	app.cube_normal_vertex = normal_start

	identity := shared.mat4_identity()
	app.primitive_record = Example3_Primitive_Record {
		index_count   = app.cube_index_len,
		first_index   = app.cube_index,
		vertex_offset = app.cube_vertex,
		normal_offset = app.cube_normal_vertex,
		transform     = identity,
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
	if gfx.ez_gfx_begin_render(&app.window) != .Ok do return false

	indirect, indirect_status := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"example 3 test draw commands",
	)
	if indirect_status != .Ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	primitives, primitives_status := gfx.ez_gfx_render_acquire_structured_buffer(
		Example3_Primitive_Record,
		1,
		"primitives",
	)
	if primitives_status != .Ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	primitives.elements[0] = app.primitive_record

	compute_bindings := [?]gfx.Ez_Gfx_Render_Binding {
		{name = "primitives", structured = primitives.handle},
		{name = "draw_commands", indirect = indirect},
	}
	_, compute_status := gfx.ez_gfx_render_add_compute_pipeline(
		&app.compute_shader,
		1,
		1,
		1,
		compute_bindings[:],
		Example3_Compute_Push_Constants{primitive_count = 1},
	)
	if compute_status != .Ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	if gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1) != .Ok {
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
		{name = "primitives", structured = primitives.handle},
	}
	_, draw_status := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.draw_shader,
		indirect,
		draw_bindings[:],
		{},
		Example3_Draw_Push_Constants{mvp = shared.mat4_mul(projection, view)},
	)
	if draw_status != .Ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	return gfx.ez_gfx_finish_render() == .Ok
}

example3_test_cleanup :: proc(app: ^Example3_Test_App) {
	context.user_ptr = &app.ctx
	if app.compute_shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.compute_shader)
		app.compute_shader_loaded = false
	}
	if app.draw_shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.draw_shader)
		app.draw_shader_loaded = false
	}
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	shared.example_glfw_terminate()
}

example3_test_reset_validation_counts :: proc(app: ^Example3_Test_App) {
	app.validation_log = {}
	app.ctx.validation_counts = {}
}
