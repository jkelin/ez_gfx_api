package main

import gfx "../../src"
import shared "../shared"
import "core:fmt"
import "core:math"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
COMPUTE_SHADER_PATH :: cstring("examples/5_helmet_cgltf/compute.slang")
DRAW_SHADER_PATH :: cstring("examples/5_helmet_cgltf/draw.slang")
GLTF_PATH :: "examples/shared/assets/helmet.glb"
POSITION_HEAP :: "position"
NORMAL_HEAP :: "normal"

HELMET_ORBIT_CENTER :: shared.Vec3{0.0, 0.0, 0.0}

// Matches the Slang PrimitiveRecord layout (field order differs from Mesh_Descriptor).
Primitive_Record :: struct {
	first_index:   u32,
	index_count:   u32,
	vertex_offset: u32,
	normal_offset: u32,
	transform:     shared.Mat4,
}

helmet_camera_start :: proc() -> shared.Orbit_Camera_Start {
	return shared.Orbit_Camera_Start {
		yaw      = math.to_radians_f32(35),
		pitch    = math.to_radians_f32(22),
		distance = 5.0,
	}
}

Compute_Push_Constants :: struct {
	primitive_count: u32,
}

Draw_Push_Constants :: struct {
	mvp: shared.Mat4,
}

App :: struct {
	ctx:                   gfx.Ez_Gfx_Ctx,
	windows:               [gfx.MAX_WINDOWS]gfx.Ez_Gfx_Window,
	window_count:          int,
	compute_shader:        gfx.Ez_Gfx_Shader_Program,
	draw_shader:           gfx.Ez_Gfx_Shader_Program,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	mesh:                  shared.Loaded_Mesh,
	mesh_loaded:           bool,
	primitive_records:     []Primitive_Record,
	camera:                shared.Orbit_Camera,
	orbit_center:          shared.Vec3,
	camera_start:          shared.Orbit_Camera_Start,
}

main :: proc() {
	app: App
	defer cleanup(&app)
	init_app(&app)
	run(&app)
}

init_app :: proc(app: ^App) {
	fmt.println("checkpoint: glfw init")
	assert(gfx.ez_gfx_glfw_init())

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	app.window_count = 1
	app.camera = shared.orbit_camera_default()
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(
		gfx.ez_gfx_window_create(main_window, "ez_gfx_api helmet cgltf", WIDTH, HEIGHT),
	)
	shared.orbit_camera_install_callbacks(main_window)
	fmt.println("checkpoint: instance create")
	assert(gfx.ez_gfx_ctx_create_instance(&app.ctx, {enable_debug = true}))
	fmt.println("checkpoint: surface create")
	assert(gfx.ez_gfx_window_create_surface(main_window))
	fmt.println("checkpoint: device init")
	assert(gfx.ez_gfx_ctx_init_device(main_window.surface))
	fmt.println("checkpoint: swapchain recreate")
	assert(gfx.ez_gfx_window_recreate_swapchain(main_window))
	fmt.println("checkpoint: example data init")
	example_init(app)
	fmt.println("checkpoint: init done")
}

example_init :: proc(app: ^App) {
	assert(
		gfx.ez_gfx_shader_compile(
			{
				path = COMPUTE_SHADER_PATH,
				compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
				kind = .Compute,
			},
			&app.compute_shader,
		),
	)
	app.compute_shader_loaded = true

	assert(
		gfx.ez_gfx_shader_compile(
			{
				path = DRAW_SHADER_PATH,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&app.draw_shader,
		),
	)
	app.draw_shader_loaded = true

	mesh, mesh_ok := shared.gltf_load_meshes(GLTF_PATH)
	assert(mesh_ok, "glTF mesh load failed")
	app.mesh = mesh
	app.mesh_loaded = true

	app.orbit_center = HELMET_ORBIT_CENTER
	app.camera_start = helmet_camera_start()
	shared.orbit_camera_apply_start(&app.camera, app.orbit_center, app.camera_start)

	vertex_stride := vk.DeviceSize(size_of([4]f32))
	index_bytes := shared.gltf_mesh_index_heap_bytes(&app.mesh) + 4096
	vertex_bytes := shared.gltf_mesh_vertex_heap_bytes(&app.mesh, vertex_stride) + 4096
	gfx.ez_gfx_vertex_manager_begin(&app.ctx.vertex_manager)
	gfx.ez_gfx_gpu_heap_create(
		&app.ctx.vertex_manager.index_heap,
		index_bytes,
		vk.DeviceSize(size_of(u32)),
		{.INDEX_BUFFER},
		"example 5 index heap",
	)
	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		POSITION_HEAP,
		vertex_bytes,
		vertex_stride,
	)
	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		NORMAL_HEAP,
		vertex_bytes,
		vertex_stride,
	)

	upload_gltf_primitives(&app.ctx.vertex_manager, &app.mesh)
	app.primitive_records = make([]Primitive_Record, len(app.mesh.descriptors))
	for descriptor, i in app.mesh.descriptors {
		app.primitive_records[i] = mesh_descriptor_to_primitive_record(descriptor)
	}
}

mesh_descriptor_to_primitive_record :: proc(descriptor: shared.Mesh_Descriptor) -> Primitive_Record {
	return Primitive_Record {
		first_index   = descriptor.first_index,
		index_count   = descriptor.index_count,
		vertex_offset = descriptor.vertex_offset,
		normal_offset = descriptor.normal_vertex_offset,
		transform     = descriptor.transform,
	}
}

upload_gltf_primitives :: proc(manager: ^gfx.Ez_Gfx_Vertex_Manager, mesh: ^shared.Loaded_Mesh) {
	for &cpu, prim_index in mesh.cpu_primitives {
		first_index := gfx.ez_gfx_vertex_manager_upload_indices(
			manager,
			cpu.indices[:],
		)
		vertex_start := gfx.ez_gfx_vertex_manager_upload_vertices(
			manager,
			POSITION_HEAP,
			cpu.positions[:],
		)
		normal_start := gfx.ez_gfx_vertex_manager_upload_vertices(
			manager,
			NORMAL_HEAP,
			cpu.normals[:],
		)

		descriptor := &mesh.descriptors[prim_index]
		descriptor.first_index = first_index
		descriptor.vertex_offset = vertex_start
		descriptor.normal_vertex_offset = normal_start
	}
}

run :: proc(app: ^App) {
	main_window := &app.windows[0]
	run_seconds := gfx.ez_gfx_config_run_seconds()
	screenshot_enabled := gfx.ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()
	previous_time := start_time

	for !gfx.ez_gfx_window_should_close(main_window) {
		gfx.ez_gfx_window_poll_events()
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

		if run_seconds > 0 && now - start_time >= run_seconds do break
		draw_frame(app, main_window)
	}

	gfx.ez_gfx_ctx_wait_idle()
	glfw.PollEvents()

	if screenshot_enabled {
		if !gfx.ez_gfx_screenshot_save_window(main_window, gfx.SCREENSHOT_PATH) {
			fmt.eprintln("failed to save screenshot")
		}
	}
}

draw_frame :: proc(app: ^App, window: ^gfx.Ez_Gfx_Window) {
	if !gfx.ez_gfx_begin_render(window) do return

	indirect := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		app.mesh.mesh_count,
		"example 5 draw commands",
	)
	if !indirect.ok {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	primitives := gfx.ez_gfx_render_acquire_structured_buffer(
		Primitive_Record,
		u32(len(app.primitive_records)),
		"primitives",
	)
	if !primitives.handle.ok {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	for record, i in app.primitive_records {
		primitives.elements[i] = record
	}

	compute_bindings := [?]gfx.Ez_Gfx_Render_Binding {
		{name = "primitives", structured = primitives.handle},
		{name = "draw_commands", indirect = indirect},
	}

	compute_push := Compute_Push_Constants {
		primitive_count = app.mesh.mesh_count,
	}
	compute := gfx.ez_gfx_render_add_compute_pipeline(
		&app.compute_shader,
		app.mesh.mesh_count,
		1,
		1,
		compute_bindings[:],
		compute_push,
	)
	if !compute.ok {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(
		math.to_radians_f32(60),
		shared.window_aspect(window),
		0.1,
		100.0,
	)
	draw_push := Draw_Push_Constants {
		mvp = shared.mat4_mul(projection, view),
	}
	draw_bindings := [?]gfx.Ez_Gfx_Render_Binding {
		{name = "primitives", structured = primitives.handle},
	}
	draw := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.draw_shader,
		indirect,
		draw_bindings[:],
		draw_push,
	)
	if !draw.ok {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	_ = gfx.ez_gfx_finish_render()
}

cleanup :: proc(app: ^App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	gfx.ez_gfx_ctx_wait_idle()
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
	for i in 0 ..< app.window_count {
		gfx.ez_gfx_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_ctx_destroy()
	gfx.ez_gfx_glfw_terminate()
}
