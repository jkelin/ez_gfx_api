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
	ctx:                   gfx.Ez_Gfx_Context_Handle,
	window:                shared.Example_Window,
	compute_shader:        gfx.Ez_Gfx_Shader_Handle,
	draw_shader:           gfx.Ez_Gfx_Shader_Handle,
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
	target_frames := EXAMPLE3_TEST_FRAMES
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

	gfx.ez_gfx_context_wait_idle(app.ctx)
	expect_window_snapshot(t, &app.window, "example3")
	testing.expect_value(t, app.validation_log.warnings, u32(0))
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

example3_test_init_app :: proc(app: ^Example3_Test_App) -> bool {
	if !shared.example_glfw_init() do return false

		app.camera = shared.orbit_camera_default()
	app.camera.yaw = math.to_radians_f32(-30)
	app.camera.pitch = math.to_radians_f32(52)
	app.camera.distance = 2.2
	ctx, ctx_status := gfx.ez_gfx_context_create({
		enable_validation = true,
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	if ctx_status != .Ok do return false
	app.ctx = ctx
	if !shared.example_window_create(&app.window, app.ctx, "ez_gfx_api example 3 test", WIDTH, HEIGHT) do return false
	if gfx.ez_gfx_surface_init_device(app.ctx, app.window.surface) != .Ok do return false
	if gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, u32(app.window.framebuffer_width), u32(app.window.framebuffer_height)) != .Ok do return false
	return example3_test_init_resources(app)
}

example3_test_init_resources :: proc(app: ^Example3_Test_App) -> bool {
	compute_shader_handle, compute_shader_status := gfx.ez_gfx_shader_create(app.ctx, {
			path = EXAMPLE3_COMPUTE_SHADER_PATH,
			compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
			kind = .Compute,
		})
	if compute_shader_status != .Ok {
		return false
	}
	app.compute_shader = compute_shader_handle
	app.compute_shader_loaded = true

	draw_shader_handle, draw_shader_status := gfx.ez_gfx_shader_create(app.ctx, {
			path = EXAMPLE3_DRAW_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		})
	if draw_shader_status != .Ok {
		return false
	}
	app.draw_shader = draw_shader_handle
	app.draw_shader_loaded = true

	if gfx.ez_gfx_index_heap_create(app.ctx, vk.DeviceSize(size_of(CUBE_TEST_INDICES) + 4096), "example3 index heap") != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, EXAMPLE3_POSITION_HEAP, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, vk.DeviceSize(size_of(CUBE_TEST_POSITIONS[0]))) != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, EXAMPLE3_NORMAL_HEAP, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, vk.DeviceSize(size_of(CUBE_TEST_POSITIONS[0]))) != .Ok do return false

	index_start, index_status := gfx.ez_gfx_vertex_upload_indices(app.ctx, CUBE_TEST_INDICES[:])
	if index_status != .Ok do return false
	app.cube_index = index_start
	app.cube_index_len = u32(len(CUBE_TEST_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_upload(app.ctx, EXAMPLE3_POSITION_HEAP, CUBE_TEST_POSITIONS[:])
	if vertex_status != .Ok do return false
	app.cube_vertex = vertex_start

	normals := example3_test_cube_normals()
	defer delete(normals)
	normal_start, normal_status := gfx.ez_gfx_vertex_upload(app.ctx, EXAMPLE3_NORMAL_HEAP, normals[:])
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
	if gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) != .Ok do return false

	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(
		app.ctx,
		1,
		"example 3 test draw commands",
	)
	if indirect_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}

	primitives, primitives_status := gfx.ez_gfx_acquire_structured(
		app.ctx,
		Example3_Primitive_Record,
		1,
		"primitives",
	)
	if primitives_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}
	if gfx.ez_gfx_structured_write(app.ctx, primitives, rawptr(&app.primitive_record), u64(size_of(Example3_Primitive_Record))) != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}

	compute_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding {
		{name = "primitives", structured = primitives},
		{name = "draw_commands", indirect = indirect},
	}
	_, compute_status := gfx.ez_gfx_render_add_compute_pipeline_handles(
		app.ctx,
		app.compute_shader,
		1,
		1,
		1,
		compute_bindings[:],
		rawptr(&Example3_Compute_Push_Constants{primitive_count = 1}),
		u32(size_of(Example3_Compute_Push_Constants)),
	)
	if compute_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}
	if gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, 1) != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}

	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(
		math.to_radians_f32(60),
		shared.window_aspect(&app.window),
		0.1,
		100.0,
	)
	draw_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding {
		{name = "primitives", structured = primitives},
	}
	_, draw_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(
		app.ctx,
		app.draw_shader,
		indirect,
		draw_bindings[:],
		{},
		rawptr(&Example3_Draw_Push_Constants{mvp = shared.mat4_mul(projection, view)}),
		u32(size_of(Example3_Draw_Push_Constants)),
	)
	if draw_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}

	return gfx.ez_gfx_finish_render_context(app.ctx) == .Ok
}

example3_test_cleanup :: proc(app: ^Example3_Test_App) {
		if app.compute_shader_loaded {
		gfx.ez_gfx_shader_release(app.ctx, app.compute_shader)
		app.compute_shader_loaded = false
	}
	if app.draw_shader_loaded {
		gfx.ez_gfx_shader_release(app.ctx, app.draw_shader)
		app.draw_shader_loaded = false
	}
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}

example3_test_reset_validation_counts :: proc(app: ^Example3_Test_App) {
	app.validation_log = {}
	
}
