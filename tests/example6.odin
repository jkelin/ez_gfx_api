package tests

import shared "../examples/shared"
import gfx "../src"
import cgltf "vendor:cgltf"
import "core:math"
import "core:testing"
import vk "vendor:vulkan"

EXAMPLE6_TEST_FRAMES :: 2
EXAMPLE6_COMPUTE_SHADER_PATH :: cstring("examples/6_sponza_ktx2/compute.slang")
EXAMPLE6_DRAW_SHADER_PATH :: cstring("examples/6_sponza_ktx2/draw.slang")
EXAMPLE6_GLTF_PATH :: "examples/shared/assets/sponza.glb"
EXAMPLE6_POSITION_HEAP :: "position"
EXAMPLE6_NORMAL_HEAP :: "normal"
EXAMPLE6_UV_HEAP :: "uv"
EXAMPLE6_ORBIT_CENTER :: shared.Vec3{0.0, -0.32, 0.0}
EXAMPLE6_NEAR_PLANE :: f32(0.02)
EXAMPLE6_WHITE_PIXEL :: [4]u8{255, 255, 255, 255}

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


Example6_Compute_Push_Constants :: struct {
	primitive_count: u32,
}

Example6_Draw_Push_Constants :: struct {
	mvp: shared.Mat4,
}

Example6_Test_App :: struct {
	ctx:                   gfx.Ez_Gfx_Ctx,
	window:                gfx.Ez_Gfx_Window,
	compute_shader:        gfx.Ez_Gfx_Shader_Program,
	draw_shader:           gfx.Ez_Gfx_Shader_Program,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	mesh:                  shared.Loaded_Mesh,
	mesh_loaded:           bool,
	primitive_records:     []Example6_Primitive_Record,
	texture_ids:           [dynamic]gfx.Ez_Gfx_Texture_ID,
	texture_ids_by_image:  map[^cgltf.image]gfx.Ez_Gfx_Texture_ID,
	fallback_texture_id:   gfx.Ez_Gfx_Texture_ID,
	camera:                shared.Orbit_Camera,
	camera_start:          shared.Orbit_Camera_Start,
	validation_log:        Validation_Log,
}

@(test)
example6_sponza_ktx2_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Example6_Test_App
	if !testing.expect(
		t,
		example6_test_init_app(&app),
		"example 6 render test failed during init",
	) {
		example6_test_cleanup(&app)
		return
	}
	defer example6_test_cleanup(&app)
	example6_test_reset_validation_counts(&app)

	frames_drawn := 0
	attempts := 0
	target_frames := max(EXAMPLE6_TEST_FRAMES, int(app.window.swapchain.image_count) + 1)
	for frames_drawn < target_frames && attempts < 60 {
		attempts += 1
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return
		if example6_test_draw_frame(&app) {
			frames_drawn += 1
		}
	}
	if !testing.expect_value(t, frames_drawn, target_frames) {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	expect_window_snapshot(t, &app.window, "example6")
	testing.expect_value(t, app.validation_log.warnings, u32(0))
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.warning, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

example6_test_init_app :: proc(app: ^Example6_Test_App) -> bool {
	if !shared.example_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	app.camera = shared.orbit_camera_default()
	app.camera_start = shared.Orbit_Camera_Start {
		yaw      = math.to_radians_f32(90.0),
		pitch    = math.to_radians_f32(8.0),
		distance = 0.45,
	}
	shared.orbit_camera_apply_start(&app.camera, EXAMPLE6_ORBIT_CENTER, app.camera_start)

	if !shared.example_window_create(&app.window,
		"ez_gfx_api example 6 test",
		WIDTH,
		HEIGHT) {
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
	if !gfx.ez_gfx_window_recreate_swapchain(&app.window, app.window.framebuffer_width, app.window.framebuffer_height) do return false
	return example6_test_init_resources(app)
}

example6_test_init_resources :: proc(app: ^Example6_Test_App) -> bool {
	gfx.ez_gfx_enable_ktx2_decoder()
	if !gfx.ez_gfx_shader_compile(
		{
			path = EXAMPLE6_COMPUTE_SHADER_PATH,
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
			path = EXAMPLE6_DRAW_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&app.draw_shader,
	) {
		return false
	}
	app.draw_shader_loaded = true

	mesh, mesh_ok := shared.gltf_load_meshes(EXAMPLE6_GLTF_PATH)
	if !mesh_ok do return false
	app.mesh = mesh
	app.mesh_loaded = true
	if !example6_test_load_textures(app) do return false

	position_stride := vk.DeviceSize(size_of([4]f32))
	normal_stride := vk.DeviceSize(size_of([4]f32))
	uv_stride := vk.DeviceSize(size_of([4]f32))
	index_bytes := shared.gltf_mesh_index_heap_bytes(&app.mesh) + 4096
	position_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, position_stride) + 4096
	normal_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, normal_stride) + 4096
	uv_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, uv_stride) + 4096
	gfx.ez_gfx_vertex_manager_begin(&app.ctx.vertex_manager)
	gfx.ez_gfx_gpu_heap_create(
		&app.ctx.vertex_manager.index_heap,
		index_bytes,
		vk.DeviceSize(size_of(u32)),
		{.INDEX_BUFFER},
		"example 6 test index heap",
	)
	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		EXAMPLE6_POSITION_HEAP,
		position_bytes,
		position_stride,
	)
	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		EXAMPLE6_NORMAL_HEAP,
		normal_bytes,
		normal_stride,
	)
	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		EXAMPLE6_UV_HEAP,
		uv_bytes,
		uv_stride,
	)

	example6_upload_gltf_primitives(&app.ctx.vertex_manager, &app.mesh)
	app.primitive_records = make([]Example6_Primitive_Record, len(app.mesh.descriptors))
	for descriptor, i in app.mesh.descriptors {
		texture_id := app.fallback_texture_id
		if image := shared.gltf_base_color_image(&app.mesh.cpu_primitives[i]); image != nil {
			if mapped, ok := app.texture_ids_by_image[image]; ok {
				texture_id = mapped
			}
		}
		app.primitive_records[i] = example6_descriptor_to_record(descriptor, texture_id)
	}
	return true
}

example6_test_load_textures :: proc(app: ^Example6_Test_App) -> bool {
	app.texture_ids_by_image = make(map[^cgltf.image]gfx.Ez_Gfx_Texture_ID)
	white_pixel: [4]u8 = EXAMPLE6_WHITE_PIXEL
	fallback_id, fallback_err := gfx.ez_gfx_load_texture(
		{{data = white_pixel[:]}},
		{
			source_format      = .RGBA,
			destination_format = .R8G8B8A8_UNORM,
			width              = 1,
			height             = 1,
			mip_count          = 1,
			min_filter         = .Linear,
			mag_filter         = .Linear,
			address_mode_u     = .Repeat,
			address_mode_v     = .Repeat,
			debug_label        = "example 6 fallback texture",
		},
	)
	if fallback_err != .None do return false
	app.fallback_texture_id = fallback_id
	append(&app.texture_ids, fallback_id)

	for &prim in app.mesh.cpu_primitives {
		image := shared.gltf_base_color_image(&prim)
		if image == nil do continue
		if _, exists := app.texture_ids_by_image[image]; exists do continue
		data := shared.gltf_image_bytes(image)
		if len(data) == 0 do return false
		texture_id, texture_err := gfx.ez_gfx_load_texture(
			{{data = data}},
			{
				source_format      = .KTX2,
				destination_format = .R8G8B8A8_UNORM,
				generate_mips      = true,
				min_filter         = .Linear,
				mag_filter         = .Linear,
				max_anisotropy    = 16.0,
				address_mode_u     = .Repeat,
				address_mode_v     = .Repeat,
				debug_label        = "example 6 base color KTX2",
			},
		)
		if texture_err != .None do return false
		app.texture_ids_by_image[image] = texture_id
		append(&app.texture_ids, texture_id)
	}
	return true
}

example6_descriptor_to_record :: proc(
	descriptor: shared.Mesh_Descriptor,
	texture_id: gfx.Ez_Gfx_Texture_ID,
) -> Example6_Primitive_Record {
	return Example6_Primitive_Record {
		first_index   = descriptor.first_index,
		index_count   = descriptor.index_count,
		vertex_offset = descriptor.vertex_offset,
		normal_offset = descriptor.normal_vertex_offset,
		uv_offset     = descriptor.uv_offset,
		texture_id    = u32(texture_id),
		transform     = descriptor.transform,
	}
}


example6_upload_gltf_primitives :: proc(
	manager: ^gfx.Ez_Gfx_Vertex_Manager,
	mesh: ^shared.Loaded_Mesh,
) {
	for &cpu, prim_index in mesh.cpu_primitives {
		position_start := gfx.ez_gfx_vertex_manager_upload_vertices(
			manager,
			EXAMPLE6_POSITION_HEAP,
			cpu.positions[:],
		)
		global_indices := make([]u32, len(cpu.indices))
		for index, i in cpu.indices {
			global_indices[i] = index + position_start
		}
		first_index := gfx.ez_gfx_vertex_manager_upload_indices(
			manager,
			global_indices,
		)
		delete(global_indices)
		normal_start := gfx.ez_gfx_vertex_manager_upload_vertices(
			manager,
			EXAMPLE6_NORMAL_HEAP,
			cpu.normals[:],
		)
		uv_start := gfx.ez_gfx_vertex_manager_upload_vertices(
			manager,
			EXAMPLE6_UV_HEAP,
			cpu.uvs[:],
		)

		descriptor := &mesh.descriptors[prim_index]
		descriptor.first_index = first_index
		descriptor.vertex_offset = position_start
		descriptor.normal_vertex_offset = normal_start
		descriptor.uv_offset = uv_start
	}
}

example6_test_draw_frame :: proc(app: ^Example6_Test_App) -> bool {
	if !gfx.ez_gfx_begin_render(&app.window) do return false

	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(
		math.to_radians_f32(60),
		shared.window_aspect(&app.window),
		EXAMPLE6_NEAR_PLANE,
		100.0,
	)
	primitive_count := u32(len(app.primitive_records))
	indirect := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		primitive_count,
		"example 6 test draw commands",
	)
	if !indirect.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	primitives := gfx.ez_gfx_render_acquire_structured_buffer(
		Example6_Primitive_Record,
		primitive_count,
		"example 6 test primitives",
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
		primitive_count,
		1,
		1,
		compute_bindings[:],
		Example6_Compute_Push_Constants{primitive_count = primitive_count},
	)
	if !compute.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	if !gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, primitive_count) {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	draw_bindings := [?]gfx.Ez_Gfx_Render_Binding {
		{name = "primitives", structured = primitives.handle},
	}
	dynamic_state := gfx.Ez_Gfx_Render_Dynamic_State{
		front_face = .COUNTER_CLOCKWISE,
		cull_mode = {.BACK},
	}
	draw := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.draw_shader,
		indirect,
		draw_bindings[:],
		dynamic_state,
		Example6_Draw_Push_Constants{mvp = shared.mat4_mul(projection, view)},
	)
	if !draw.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	return gfx.ez_gfx_finish_render()
}

example6_test_cleanup :: proc(app: ^Example6_Test_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	gfx.ez_gfx_ctx_wait_idle()
	for texture_id in app.texture_ids {
		_ = gfx.ez_gfx_unload_texture(texture_id)
	}
	if len(app.texture_ids) > 0 {
		gfx.ez_gfx_ctx_wait_idle()
		delete(app.texture_ids)
	}
	if app.texture_ids_by_image != nil {
		delete(app.texture_ids_by_image)
	}
	if app.primitive_records != nil {
		delete(app.primitive_records)
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
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	shared.example_glfw_terminate()
}

example6_test_reset_validation_counts :: proc(app: ^Example6_Test_App) {
	app.validation_log = {}
	app.ctx.validation_counts = {}
}
