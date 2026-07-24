package tests

import shared "../examples/shared"
import gfx "../src"
import "core:math"
import "core:testing"
import vk "vendor:vulkan"

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

Example5_Compute_Push_Constants :: struct {
	primitive_count: u32,
}

Example5_Draw_Push_Constants :: struct {
	mvp: shared.Mat4,
}

Example5_Test_App :: struct {
	ctx:                   gfx.Ez_Gfx_Ctx,
	window:                gfx.Ez_Gfx_Window,
	compute_shader:        gfx.Ez_Gfx_Shader_Program,
	draw_shader:           gfx.Ez_Gfx_Shader_Program,
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
	if !testing.expect(
		t,
		example5_test_init_app(&app),
		"example 5 render test failed during init",
	) {
		example5_test_cleanup(&app)
		return
	}
	defer example5_test_cleanup(&app)
	example5_test_reset_validation_counts(&app)

	frames_drawn := 0
	attempts := 0
	target_frames := max(EXAMPLE5_TEST_FRAMES, int(app.window.swapchain.image_count) + 1)
	for frames_drawn < target_frames && attempts < 60 {
		attempts += 1
		gfx.ez_gfx_window_poll_events()
		if gfx.ez_gfx_window_should_close(&app.window) do return
		if example5_test_draw_frame(&app) {
			frames_drawn += 1
		}
	}
	if !testing.expect_value(t, frames_drawn, target_frames) {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	expect_window_snapshot(t, &app.window, "example5")
	testing.expect_value(t, app.validation_log.warnings, u32(0))
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.warning, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

example5_test_init_app :: proc(app: ^Example5_Test_App) -> bool {
	if !gfx.ez_gfx_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	app.camera = shared.orbit_camera_default()
	app.camera_start = shared.Orbit_Camera_Start {
		yaw      = math.to_radians_f32(35),
		pitch    = math.to_radians_f32(22),
		distance = 5.0,
	}
	shared.orbit_camera_apply_start(&app.camera, EXAMPLE5_ORBIT_CENTER, app.camera_start)

	if !gfx.ez_gfx_window_create(
		&app.window,
		"ez_gfx_api example 5 test",
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
	return example5_test_init_resources(app)
}

example5_test_init_resources :: proc(app: ^Example5_Test_App) -> bool {
	if !gfx.ez_gfx_shader_compile(
		{
			path = EXAMPLE5_COMPUTE_SHADER_PATH,
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
			path = EXAMPLE5_DRAW_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&app.draw_shader,
	) {
		return false
	}
	app.draw_shader_loaded = true

	mesh, mesh_ok := shared.gltf_load_meshes(EXAMPLE5_GLTF_PATH)
	if !mesh_ok do return false
	app.mesh = mesh
	app.mesh_loaded = true

	vertex_stride := vk.DeviceSize(size_of([4]f32))
	index_bytes := shared.gltf_mesh_index_heap_bytes(&app.mesh) + 4096
	vertex_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, vertex_stride) + 4096
	gfx.ez_gfx_vertex_manager_begin(&app.ctx.vertex_manager)
	gfx.ez_gfx_gpu_heap_create(
		&app.ctx.vertex_manager.index_heap,
		index_bytes,
		vk.DeviceSize(size_of(u32)),
		{.INDEX_BUFFER},
		"example 5 test index heap",
	)
	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		EXAMPLE5_POSITION_HEAP,
		vertex_bytes,
		vertex_stride,
	)
	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		EXAMPLE5_NORMAL_HEAP,
		vertex_bytes,
		vertex_stride,
	)

	example5_upload_gltf_primitives(
		&app.ctx.vertex_manager,
		&app.mesh,
		EXAMPLE5_POSITION_HEAP,
		EXAMPLE5_NORMAL_HEAP,
	)
	app.primitive_records = make([]Example5_Primitive_Record, len(app.mesh.descriptors))
	for descriptor, i in app.mesh.descriptors {
		app.primitive_records[i] = example5_descriptor_to_record(descriptor)
	}
	return true
}

example5_descriptor_to_record :: proc(descriptor: shared.Mesh_Descriptor) -> Example5_Primitive_Record {
	return Example5_Primitive_Record {
		first_index   = descriptor.first_index,
		index_count   = descriptor.index_count,
		vertex_offset = descriptor.vertex_offset,
		normal_offset = descriptor.normal_vertex_offset,
		transform     = descriptor.transform,
	}
}

example5_upload_gltf_primitives :: proc(
	manager: ^gfx.Ez_Gfx_Vertex_Manager,
	mesh: ^shared.Loaded_Mesh,
	position_heap, normal_heap: string,
) {
	for &cpu, prim_index in mesh.cpu_primitives {
		first_index := gfx.ez_gfx_vertex_manager_upload_indices(
			manager,
			cpu.indices[:],
		)
		vertex_start := gfx.ez_gfx_vertex_manager_upload_vertices(
			manager,
			position_heap,
			cpu.positions[:],
		)
		normal_start := gfx.ez_gfx_vertex_manager_upload_vertices(
			manager,
			normal_heap,
			cpu.normals[:],
		)

		descriptor := &mesh.descriptors[prim_index]
		descriptor.first_index = first_index
		descriptor.vertex_offset = vertex_start
		descriptor.normal_vertex_offset = normal_start
	}
}

example5_test_draw_frame :: proc(app: ^Example5_Test_App) -> bool {
	if !gfx.ez_gfx_begin_render(&app.window) do return false

	indirect := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		app.mesh.mesh_count,
		"example 5 test draw commands",
	)
	if !indirect.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	primitives := gfx.ez_gfx_render_acquire_structured_buffer(
		Example5_Primitive_Record,
		u32(len(app.primitive_records)),
		"primitives",
	)
	if !primitives.handle.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	for record, i in app.primitive_records {
		primitives.elements[i] = record
	}

	compute_bindings := [?]gfx.Ez_Gfx_Render_Binding {
		{name = "primitives", structured = primitives.handle},
		{name = "draw_commands", indirect = indirect},
	}
	compute := gfx.ez_gfx_render_add_compute_pipeline(
		&app.compute_shader,
		app.mesh.mesh_count,
		1,
		1,
		compute_bindings[:],
		Example5_Compute_Push_Constants{primitive_count = app.mesh.mesh_count},
	)
	if !compute.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	if !gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, app.mesh.mesh_count) {
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
	draw := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.draw_shader,
		indirect,
		draw_bindings[:],
		{},
		Example5_Draw_Push_Constants{mvp = shared.mat4_mul(projection, view)},
	)
	if !draw.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	return gfx.ez_gfx_finish_render()
}

example5_test_cleanup :: proc(app: ^Example5_Test_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if app.primitive_records != nil {
		delete(app.primitive_records)
		app.primitive_records = nil
	}
	if app.mesh_loaded {
		shared.gltf_loaded_mesh_destroy(&app.mesh)
		app.mesh_loaded = false
	}
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

example5_test_reset_validation_counts :: proc(app: ^Example5_Test_App) {
	app.validation_log = {}
	app.ctx.validation_counts = {}
}
