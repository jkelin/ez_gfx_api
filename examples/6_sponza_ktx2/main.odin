#+private
package main

import gfx "../../src"
import shared "../shared"
import cgltf "vendor:cgltf"
import "core:fmt"
import "core:math"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
COMPUTE_SHADER_PATH :: cstring("examples/6_sponza_ktx2/compute.slang")
DRAW_SHADER_PATH :: cstring("examples/6_sponza_ktx2/draw.slang")
GLTF_PATH :: "examples/shared/assets/sponza.glb"
POSITION_HEAP :: "position"
NORMAL_HEAP :: "normal"
UV_HEAP :: "uv"

SPONZA_ORBIT_CENTER :: shared.Vec3{0.0, -0.32, 0.0}
SPONZA_NEAR_PLANE :: f32(0.02)

// Matches the Slang PrimitiveRecord layout. The padding keeps the matrix
// aligned after the per-primitive draw and texture metadata.
Primitive_Record :: struct {
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


Compute_Push_Constants :: struct {
	primitive_count: u32,
}

Draw_Push_Constants :: struct {
	mvp: shared.Mat4,
}

WHITE_PIXEL :: [4]u8{255, 255, 255, 255}

App :: struct {
	ctx:                   gfx.Ez_Gfx_Context_Handle,
	windows:               [shared.EXAMPLE_MAX_WINDOWS]shared.Example_Window,
	window_count:          int,
	compute_shader:        gfx.Ez_Gfx_Shader_Handle,
	draw_shader:           gfx.Ez_Gfx_Shader_Handle,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	mesh:                  shared.Loaded_Mesh,
	mesh_loaded:           bool,
	primitive_records:     []Primitive_Record,
	texture_ids:           [dynamic]gfx.Ez_Gfx_Texture_Handle,
	texture_ids_by_image:  map[^cgltf.image]gfx.Ez_Gfx_Texture_Handle,
	fallback_texture_id:   gfx.Ez_Gfx_Texture_Handle,
	fallback_pixel:      [4]u8,
	camera:                shared.Orbit_Camera,
	orbit_center:          shared.Vec3,
	camera_start:          shared.Orbit_Camera_Start,
}

main :: proc() {
	app := new(App)
	defer free(app)
	defer cleanup(app)
	init_app(app)
	run(app)
}

init_app :: proc(app: ^App) {
	fmt.println("checkpoint: glfw init")
	assert(shared.example_glfw_init())

	fmt.println("checkpoint: instance create")
	ctx_handle, ctx_status := gfx.ez_gfx_context_create({
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	assert(ctx_status == .Ok)
	app.ctx = ctx_handle

	assert(gfx.ez_gfx_enable_all_decoders_for_context(app.ctx) == .Ok, "failed to enable image decoders")
	app.window_count = 1
	app.camera = shared.orbit_camera_default()
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(
		shared.example_window_create(main_window, app.ctx, "ez_gfx_api Sponza KTX2", WIDTH, HEIGHT),
	)
	shared.orbit_camera_install_callbacks(main_window)
	fmt.println("checkpoint: device init")
	assert(gfx.ez_gfx_surface_init_device(app.ctx, main_window.surface) == .Ok)
	fmt.println("checkpoint: swapchain recreate")
	assert(gfx.ez_gfx_surface_resize(app.ctx, main_window.surface, u32(main_window.framebuffer_width), u32(main_window.framebuffer_height)) == .Ok)
	fmt.println("checkpoint: example data init")
	example_init(app)
	fmt.println("checkpoint: init done")
}

example_init :: proc(app: ^App) {
	compute_shader_handle, compute_shader_status := gfx.ez_gfx_shader_create(app.ctx, {
		path = COMPUTE_SHADER_PATH,
		compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
		kind = .Compute,
	})
	assert(compute_shader_status == .Ok)
	app.compute_shader = compute_shader_handle
	app.compute_shader_loaded = true

	draw_shader_handle, draw_shader_status := gfx.ez_gfx_shader_create(app.ctx, {
		path = DRAW_SHADER_PATH,
		vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
		fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
	})
	assert(draw_shader_status == .Ok)
	app.draw_shader = draw_shader_handle
	app.draw_shader_loaded = true

	mesh, mesh_ok := shared.gltf_load_meshes(GLTF_PATH)
	assert(mesh_ok, "glTF mesh load failed")
	app.mesh = mesh
	app.mesh_loaded = true
	load_sponza_textures(app)

	app.orbit_center = SPONZA_ORBIT_CENTER
	app.camera_start = sponza_camera_start()
	shared.orbit_camera_apply_start(&app.camera, app.orbit_center, app.camera_start)

	position_stride := vk.DeviceSize(size_of([4]f32))
	normal_stride := vk.DeviceSize(size_of([4]f32))
	uv_stride := vk.DeviceSize(size_of([4]f32))
	index_bytes := shared.gltf_mesh_index_heap_bytes(&app.mesh) + 4096
	position_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, position_stride) + 4096
	normal_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, normal_stride) + 4096
	uv_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, uv_stride) + 4096
	gfx.ez_gfx_index_heap_create(app.ctx, index_bytes, "example 6 index heap")
	gfx.ez_gfx_vertex_heap_create(
		app.ctx,
		POSITION_HEAP,
		position_bytes,
		position_stride,
	)
	gfx.ez_gfx_vertex_heap_create(
		app.ctx,
		NORMAL_HEAP,
		normal_bytes,
		normal_stride,
	)
	gfx.ez_gfx_vertex_heap_create(
		app.ctx,
		UV_HEAP,
		uv_bytes,
		uv_stride,
	)

	upload_sponza_primitives(app.ctx, &app.mesh)
	app.primitive_records = make([]Primitive_Record, len(app.mesh.descriptors))
	for descriptor, i in app.mesh.descriptors {
		texture_id := app.fallback_texture_id
		if image := shared.gltf_base_color_image(&app.mesh.cpu_primitives[i]); image != nil {
			if mapped, ok := app.texture_ids_by_image[image]; ok {
				texture_id = mapped
			}
		}
		app.primitive_records[i] = mesh_descriptor_to_primitive_record(app.ctx, descriptor, texture_id)
	}
}

sponza_camera_start :: proc() -> shared.Orbit_Camera_Start {
	return shared.Orbit_Camera_Start {
		yaw      = math.to_radians_f32(90.0),
		pitch    = math.to_radians_f32(8.0),
		distance = 0.45,
	}
}

load_sponza_textures :: proc(app: ^App) {
	app.texture_ids_by_image = make(map[^cgltf.image]gfx.Ez_Gfx_Texture_Handle)
	app.fallback_pixel = WHITE_PIXEL

	fallback_id, fallback_err := gfx.ez_gfx_texture_load(
		app.ctx,
		{{data = app.fallback_pixel[:]}},
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
			debug_label        = "sponza fallback texture",
		},
	)
	assert(fallback_err == .None, "failed to schedule fallback texture")
	app.fallback_texture_id = fallback_id
	append(&app.texture_ids, fallback_id)

	for &prim in app.mesh.cpu_primitives {
		image := shared.gltf_base_color_image(&prim)
		if image == nil do continue
		if _, exists := app.texture_ids_by_image[image]; exists do continue

		data := shared.gltf_image_bytes(image)
		assert(len(data) > 0, "Sponza base-color image has no embedded bytes")
		texture_id, texture_err := gfx.ez_gfx_texture_load(
			app.ctx,
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
				debug_label        = "sponza base color KTX2",
			},
		)
		assert(texture_err == .None, "failed to schedule Sponza KTX2 texture")
		app.texture_ids_by_image[image] = texture_id
		append(&app.texture_ids, texture_id)
	}
}
mesh_descriptor_to_primitive_record :: proc(
	ctx: gfx.Ez_Gfx_Context_Handle,
	descriptor: shared.Mesh_Descriptor,
	texture_handle: gfx.Ez_Gfx_Texture_Handle,
) -> Primitive_Record {
	binding_index, binding_err := gfx.ez_gfx_texture_binding_index(ctx, texture_handle)
	assert(binding_err == .None, "failed to resolve sponza texture binding index")
	return Primitive_Record {
		first_index   = descriptor.first_index,
		index_count   = descriptor.index_count,
		vertex_offset = descriptor.vertex_offset,
		normal_offset = descriptor.normal_vertex_offset,
		uv_offset     = descriptor.uv_offset,
		texture_id    = binding_index,
		transform     = descriptor.transform,
	}
}


upload_sponza_primitives :: proc(
	ctx: gfx.Ez_Gfx_Context_Handle,
	mesh: ^shared.Loaded_Mesh,
) {
	for &cpu, prim_index in mesh.cpu_primitives {
		position_start, position_status := gfx.ez_gfx_vertex_upload(
			ctx,
			POSITION_HEAP,
			cpu.positions[:],
		)
		assert(position_status == .Ok, "failed to upload positions")

		global_indices := make([]u32, len(cpu.indices))
		for index, i in cpu.indices {
			global_indices[i] = index + position_start
		}
		first_index, index_status := gfx.ez_gfx_vertex_upload_indices(
			ctx,
			global_indices,
		)
		assert(index_status == .Ok, "failed to upload indices")
		delete(global_indices)

		normal_start, normal_status := gfx.ez_gfx_vertex_upload(
			ctx,
			NORMAL_HEAP,
			cpu.normals[:],
		)
		assert(normal_status == .Ok, "failed to upload normals")
		uv_start, uv_status := gfx.ez_gfx_vertex_upload(
			ctx,
			UV_HEAP,
			cpu.uvs[:],
		)
		assert(uv_status == .Ok, "failed to upload UVs")

		descriptor := &mesh.descriptors[prim_index]
		descriptor.first_index = first_index
		descriptor.vertex_offset = position_start
		descriptor.normal_vertex_offset = normal_start
		descriptor.uv_offset = uv_start
	}
}

run :: proc(app: ^App) {
	main_window := &app.windows[0]
	run_seconds := gfx.ez_gfx_config_run_seconds()
	max_frames := gfx.ez_gfx_config_max_frames()
	screenshot_enabled := gfx.ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()
	frame_count := 0
	previous_time := start_time

	for !shared.example_window_should_close(main_window) {
		shared.example_window_poll_events(main_window)
		shared.example_handle_window_input(main_window)

		now := glfw.GetTime()
		delta_time := f32(now - previous_time)
		previous_time = now
		shared.orbit_camera_update(
			&app.camera,
			main_window,
			app.orbit_center,
			app.camera_start,
			delta_time,
		)

		if max_frames > 0 && frame_count >= max_frames do break
		if run_seconds > 0 && now - start_time >= run_seconds do break
		draw_frame(app, main_window)
		frame_count += 1
	}

	gfx.ez_gfx_context_wait_idle(app.ctx)
	glfw.PollEvents()

	if screenshot_enabled {
		assert(gfx.ez_gfx_screenshot_save(app.ctx, main_window.surface, gfx.SCREENSHOT_PATH) == .Ok, "failed to save screenshot")
	}
}

draw_frame :: proc(app: ^App, window: ^shared.Example_Window) {
	if gfx.ez_gfx_begin_render_surface(app.ctx, window.surface) != .Ok do return

	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(
		math.to_radians_f32(60),
		shared.window_aspect(window),
		SPONZA_NEAR_PLANE,
		100.0,
	)
	primitive_count := u32(len(app.primitive_records))
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(
		app.ctx,
		primitive_count,
		"example 6 draw commands",
	)
	assert(indirect_status == .Ok, "failed to acquire Sponza indirect buffer")

	primitives, primitives_status := gfx.ez_gfx_acquire_structured(
		app.ctx,
		Primitive_Record,
		primitive_count,
		"example 6 primitives",
	)
	assert(primitives_status == .Ok, "failed to acquire Sponza primitive buffer")
	assert(gfx.ez_gfx_structured_write(app.ctx, primitives, raw_data(app.primitive_records), u64(len(app.primitive_records) * size_of(Primitive_Record))) == .Ok)

	compute_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding {
		{name = "primitives", structured = primitives},
		{name = "draw_commands", indirect = indirect},
	}
	compute_push := Compute_Push_Constants {
		primitive_count = primitive_count,
	}
	_, compute_status := gfx.ez_gfx_render_add_compute_pipeline_handles(
		app.ctx,
		app.compute_shader,
		primitive_count,
		1,
		1,
		compute_bindings[:],
		rawptr(&compute_push),
		u32(size_of(Compute_Push_Constants)),
	)
	assert(compute_status == .Ok, "failed to add Sponza compute pipeline")
	assert(gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, primitive_count) == .Ok, "failed to set Sponza indirect draw count")

	draw_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding {
		{name = "primitives", structured = primitives},
	}
	dynamic_state := gfx.Ez_Gfx_Render_Dynamic_State{
		front_face = .COUNTER_CLOCKWISE,
		cull_mode = {.BACK},
	}
	draw_push := Draw_Push_Constants {
		mvp = shared.mat4_mul(projection, view),
	}
	_, draw_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(
		app.ctx,
		app.draw_shader,
		indirect,
		draw_bindings[:],
		dynamic_state,
		rawptr(&draw_push),
		u32(size_of(Draw_Push_Constants)),
	)
	assert(draw_status == .Ok, "failed to add Sponza draw pipeline")

	assert(gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "failed to finish Sponza render")
}

cleanup :: proc(app: ^App) {
		gfx.ez_gfx_context_wait_idle(app.ctx)
	for texture_id in app.texture_ids {
		_ = gfx.ez_gfx_texture_unload(app.ctx, texture_id)
	}
	if len(app.texture_ids) > 0 {
		gfx.ez_gfx_context_wait_idle(app.ctx)
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
		gfx.ez_gfx_shader_release(app.ctx, app.compute_shader)
		app.compute_shader_loaded = false
	}
	if app.draw_shader_loaded {
		gfx.ez_gfx_shader_release(app.ctx, app.draw_shader)
		app.draw_shader_loaded = false
	}
	for i in 0 ..< app.window_count {
		shared.example_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}
