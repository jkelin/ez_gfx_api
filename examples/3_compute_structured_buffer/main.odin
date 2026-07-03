package main

import gfx "../../src"
import gltf "../../vendor/glTF2"
import shared "../shared"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
COMPUTE_SHADER_PATH :: cstring("examples/3_compute_structured_buffer/compute.slang")
DRAW_SHADER_PATH :: cstring("examples/3_compute_structured_buffer/draw.slang")
GLTF_PATH :: "examples/shared/assets/sponza.glb"
POSITION_HEAP :: "position"
NORMAL_HEAP :: "normal"

Mesh_Descriptor :: struct {
	index_count:   u32,
	first_index:   u32,
	vertex_offset: u32,
	_pad0:         u32,
}

Mesh_Instance :: struct {
	mesh_index: u32,
	_pad0:      u32,
	_pad1:      u32,
	_pad2:      u32,
	color:      [4]f32,
}

Compute_Push_Constants :: struct {
	instance_count: u32,
}

Draw_Push_Constants :: struct {
	mvp: shared.Mat4,
}

Loaded_Mesh :: struct {
	positions:   [dynamic][4]f32,
	normals:     [dynamic][4]f32,
	indices:     [dynamic]u32,
	descriptors: [dynamic]Mesh_Descriptor,
	instances:   [dynamic]Mesh_Instance,
	mesh_count:  u32,
}

App :: struct {
	ctx:                   gfx.Ez_Gfx_Ctx,
	windows:               [gfx.MAX_WINDOWS]gfx.Ez_Gfx_Window,
	window_count:          int,
	compute_shader:        gfx.Ez_Gfx_Shader_Program,
	draw_shader:           gfx.Ez_Gfx_Shader_Program,
	compute_shader_loaded: bool,
	draw_shader_loaded:    bool,
	mesh_descriptors:      []Mesh_Descriptor,
	mesh_instances:        []Mesh_Instance,
	mesh_count:            u32,
	camera:                shared.Orbit_Camera,
	input:                 shared.Example_Input,
}

main :: proc() {
	app: App
	if !init_app(&app) {
		cleanup(&app)
		return
	}
	run(&app)
	cleanup(&app)
}

init_app :: proc(app: ^App) -> bool {
	fmt.println("checkpoint: glfw init")
	if !shared.example_step("glfw init", gfx.ez_gfx_glfw_init()) do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	app.window_count = 1
	app.camera = shared.orbit_camera_default()
	app.camera.target = {0.0, 0.55, 0.0}
	app.camera.yaw = math.to_radians_f32(-30)
	app.camera.pitch = math.to_radians_f32(52)
	app.camera.distance = 2.2
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	if !shared.example_step(
		"window create",
		gfx.ez_gfx_window_create(main_window, "ez_gfx_api compute structured buffer", WIDTH, HEIGHT),
	) {
		return false
	}
	fmt.println("checkpoint: instance create")
	if !shared.example_step(
		"instance create",
		gfx.ez_gfx_ctx_create_instance(&app.ctx, {enable_debug = true}),
	) {
		return false
	}
	fmt.println("checkpoint: surface create")
	if !shared.example_step("surface create", gfx.ez_gfx_window_create_surface(main_window)) do return false
	fmt.println("checkpoint: device init")
	if !shared.example_step("device init", gfx.ez_gfx_ctx_init_device(main_window.surface)) do return false
	fmt.println("checkpoint: swapchain recreate")
	if !shared.example_step("swapchain recreate", gfx.ez_gfx_window_recreate_swapchain(main_window)) do return false
	fmt.println("checkpoint: example data init")
	if !shared.example_step("example data init", example_init(app)) do return false
	fmt.println("checkpoint: init done")
	return true
}

example_init :: proc(app: ^App) -> bool {
	if !shared.example_step(
		"compute shader compile",
		gfx.ez_gfx_shader_compile(
			{
				path = COMPUTE_SHADER_PATH,
				compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
				kind = .Compute,
			},
			&app.compute_shader,
		),
	) {
		return false
	}
	app.compute_shader_loaded = true

	if !shared.example_step(
		"draw shader compile",
		gfx.ez_gfx_shader_compile(
			{
				path = DRAW_SHADER_PATH,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&app.draw_shader,
		),
	) {
		return false
	}
	app.draw_shader_loaded = true

	mesh, mesh_ok := load_gltf_meshes(GLTF_PATH)
	if !shared.example_step("glTF mesh load", mesh_ok) do return false
	defer {
		delete(mesh.positions)
		delete(mesh.normals)
		delete(mesh.indices)
		delete(mesh.descriptors)
		delete(mesh.instances)
	}

	index_heap_bytes := vk.DeviceSize(len(mesh.indices) * size_of(mesh.indices[0]) + 4096)
	vertex_heap_bytes := vk.DeviceSize(len(mesh.positions) * size_of(mesh.positions[0]) + 4096)
	if !shared.example_step(
		"vertex manager begin",
		gfx.ez_gfx_vertex_manager_begin(&app.ctx.vertex_manager),
	) {
		return false
	}
	if !shared.example_step(
		"index heap create",
		gfx.ez_gfx_gpu_heap_create(
			&app.ctx.vertex_manager.index_heap,
			index_heap_bytes,
			vk.DeviceSize(size_of(u32)),
			{.INDEX_BUFFER},
			"example 3 index heap",
		),
	) {
		return false
	}
	if !shared.example_step(
		"position heap create",
		gfx.ez_gfx_vertex_manager_add_heap(
			&app.ctx.vertex_manager,
			POSITION_HEAP,
			vertex_heap_bytes,
			vk.DeviceSize(size_of(mesh.positions[0])),
		),
	) {
		return false
	}
	if !shared.example_step(
		"normal heap create",
		gfx.ez_gfx_vertex_manager_add_heap(
			&app.ctx.vertex_manager,
			NORMAL_HEAP,
			vertex_heap_bytes,
			vk.DeviceSize(size_of(mesh.normals[0])),
		),
	) {
		return false
	}

	index_start, index_ok := gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		mesh.indices[:],
	)
	if !shared.example_step("index upload", index_ok) do return false

	vertex_start, vertex_ok := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		POSITION_HEAP,
		mesh.positions[:],
	)
	if !shared.example_step("position upload", vertex_ok) do return false
	_, normal_ok := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		NORMAL_HEAP,
		mesh.normals[:],
	)
	if !shared.example_step("normal upload", normal_ok) do return false

	for &descriptor in mesh.descriptors {
		descriptor.first_index += index_start
		descriptor.vertex_offset += vertex_start
	}
	app.mesh_count = mesh.mesh_count

	app.mesh_descriptors = make([]Mesh_Descriptor, len(mesh.descriptors))
	mem.copy(
		raw_data(app.mesh_descriptors),
		raw_data(mesh.descriptors[:]),
		len(mesh.descriptors) * size_of(Mesh_Descriptor),
	)
	app.mesh_instances = make([]Mesh_Instance, len(mesh.instances))
	mem.copy(
		raw_data(app.mesh_instances),
		raw_data(mesh.instances[:]),
		len(mesh.instances) * size_of(Mesh_Instance),
	)
	return true
}

load_gltf_meshes :: proc(path: string) -> (mesh: Loaded_Mesh, ok: bool) {
	data, load_err := gltf.load_from_file(path)
	if load_err != nil {
		fmt.eprintf("failed to load glTF mesh: %v\n", load_err)
		return mesh, false
	}
	defer gltf.unload(data)
	if len(data.meshes) == 0 {
		fmt.eprintln("glTF file does not contain meshes")
		return mesh, false
	}

	mesh.positions = make([dynamic][4]f32)
	mesh.normals = make([dynamic][4]f32)
	mesh.indices = make([dynamic]u32)
	mesh.descriptors = make([dynamic]Mesh_Descriptor)
	mesh.instances = make([dynamic]Mesh_Instance)

	root_transform := shared.mat4_identity()
	if scene_index, has_scene := data.scene.?; has_scene && int(scene_index) < len(data.scenes) {
		for node_index in data.scenes[scene_index].nodes {
			if !append_gltf_node(data, node_index, root_transform, &mesh) {
				return mesh, false
			}
		}
	} else {
		for node, node_index in data.nodes {
			_ = node
			if !append_gltf_node(data, gltf.Integer(node_index), root_transform, &mesh) {
				return mesh, false
			}
		}
	}

	if len(mesh.descriptors) == 0 {
		fmt.eprintln("glTF file did not contain supported triangle primitives")
		return mesh, false
	}
	normalize_positions(mesh.positions[:])
	mesh.mesh_count = u32(len(mesh.descriptors))
	return mesh, true
}

append_gltf_node :: proc(
	data: ^gltf.Data,
	node_index: gltf.Integer,
	parent_transform: shared.Mat4,
	mesh: ^Loaded_Mesh,
) -> bool {
	if int(node_index) >= len(data.nodes) {
		shared.example_exit("glTF node index out of range")
		return false
	}
	node := data.nodes[node_index]
	local := gltf_node_matrix(node)
	transform := shared.mat4_mul(parent_transform, local)

	if mesh_index, has_mesh := node.mesh.?; has_mesh {
		if int(mesh_index) >= len(data.meshes) {
			shared.example_exit("glTF mesh index out of range")
			return false
		}
		if !append_gltf_mesh(data, data.meshes[mesh_index], transform, mesh) {
			return false
		}
	}
	for child_index in node.children {
		if !append_gltf_node(data, child_index, transform, mesh) {
			return false
		}
	}
	return true
}

append_gltf_mesh :: proc(
	data: ^gltf.Data,
	gltf_mesh: gltf.Mesh,
	transform: shared.Mat4,
	mesh: ^Loaded_Mesh,
) -> bool {
	for primitive in gltf_mesh.primitives {
		if primitive.mode != .Triangles do continue
		position_accessor, position_ok := primitive.attributes["POSITION"]
		if !position_ok do continue

		vertex_offset := u32(len(mesh.positions))
		position_count, positions_ok := append_gltf_positions(
			data,
			position_accessor,
			transform,
			&mesh.positions,
		)
		if !positions_ok {
			shared.example_exit("glTF position append")
			return false
		}
		if !append_gltf_normals(data, primitive, position_count, transform, &mesh.normals) {
			append_default_normals(position_count, transform, &mesh.normals)
		}
		first_index := u32(len(mesh.indices))
		index_count, indices_ok := shared.gltf_append_indices_u32(
			data,
			primitive,
			position_count,
			&mesh.indices,
		)
		if !indices_ok {
			shared.example_exit("glTF index append")
			return false
		}
		if index_count == 0 do continue
		for i in int(first_index) ..< int(first_index + index_count) {
			mesh.indices[i] += vertex_offset
		}

		mesh_index := u32(len(mesh.descriptors))
		append(
			&mesh.descriptors,
			Mesh_Descriptor {
				index_count = index_count,
				first_index = first_index,
				vertex_offset = 0,
			},
		)
		append(
			&mesh.instances,
			Mesh_Instance{mesh_index = mesh_index},
		)
	}
	return true
}

append_gltf_positions :: proc(
	data: ^gltf.Data,
	accessor_index: gltf.Integer,
	transform: shared.Mat4,
	positions: ^[dynamic][4]f32,
) -> (
	count: u32,
	ok: bool,
) {
	accessor := data.accessors[accessor_index]
	if accessor.component_type != .Float || accessor.type != .Vector3 {
		fmt.eprintln("example 3 only supports f32 vec3 positions")
		return 0, false
	}
	view, view_ok := shared.gltf_accessor_view(data, accessor_index)
	if !view_ok do return 0, false

	for i in 0 ..< int(accessor.count) {
		p := shared.gltf_read_vec3_f32(view, i)
		append(positions, transform_point(transform, {p.x, p.y, p.z, 1.0}))
	}
	return accessor.count, true
}

append_gltf_normals :: proc(
	data: ^gltf.Data,
	primitive: gltf.Mesh_Primitive,
	position_count: u32,
	transform: shared.Mat4,
	normals: ^[dynamic][4]f32,
) -> bool {
	normal_accessor, normal_ok := primitive.attributes["NORMAL"]
	if !normal_ok do return false

	accessor := data.accessors[normal_accessor]
	if accessor.component_type != .Float ||
	   accessor.type != .Vector3 ||
	   accessor.count != position_count {
		return false
	}
	view, view_ok := shared.gltf_accessor_view(data, normal_accessor)
	if !view_ok do return false

	for i in 0 ..< int(accessor.count) {
		n := shared.gltf_read_vec3_f32(view, i)
		append(normals, transform_normal(transform, {n.x, n.y, n.z, 0.0}))
	}
	return true
}

append_default_normals :: proc(count: u32, transform: shared.Mat4, normals: ^[dynamic][4]f32) {
	normal := transform_normal(transform, {0.0, 1.0, 0.0, 0.0})
	for _ in 0 ..< int(count) {
		append(normals, normal)
	}
}

gltf_node_matrix :: proc(node: gltf.Node) -> shared.Mat4 {
	base := gltf_matrix_to_mat4(node.mat)
	trs := shared.mat4_from_linalg(
		linalg.matrix4_from_trs(
			linalg.Vector3f32 {
				f32(node.translation.x),
				f32(node.translation.y),
				f32(node.translation.z),
			},
			gltf_quaternion_to_linalg(node.rotation),
			linalg.Vector3f32{f32(node.scale.x), f32(node.scale.y), f32(node.scale.z)},
		),
	)
	return shared.mat4_mul(base, trs)
}

gltf_quaternion_to_linalg :: proc(q_value: gltf.Quaternion) -> linalg.Quaternionf32 {
	q_storage := q_value
	q := (cast(^[4]f32)(&q_storage))^
	return quaternion(w = q[3], x = q[0], y = q[1], z = q[2])
}

gltf_matrix_to_mat4 :: proc(gltf_matrix: gltf.Matrix4) -> shared.Mat4 {
	result: shared.Mat4
	for row in 0 ..< 4 {
		for col in 0 ..< 4 {
			result[row][col] = f32(gltf_matrix[row, col])
		}
	}
	return result
}

transform_point :: proc(m: shared.Mat4, p: [4]f32) -> [4]f32 {
	return shared.mat4_transform_point(m, p)
}

transform_normal :: proc(m: shared.Mat4, n: [4]f32) -> [4]f32 {
	return shared.mat4_transform_direction(m, n)
}

normalize_positions :: proc(positions: [][4]f32) {
	if len(positions) == 0 do return
	min_p := [3]f32{positions[0].x, positions[0].y, positions[0].z}
	max_p := min_p
	for p in positions {
		if p.x < min_p.x do min_p.x = p.x
		if p.y < min_p.y do min_p.y = p.y
		if p.z < min_p.z do min_p.z = p.z
		if p.x > max_p.x do max_p.x = p.x
		if p.y > max_p.y do max_p.y = p.y
		if p.z > max_p.z do max_p.z = p.z
	}
	center := (min_p + max_p) * 0.5
	extent := max_p - min_p
	largest := max_f32(max_f32(extent.x, extent.y), extent.z)
	if largest <= 0 do return
	scale := 3.0 / largest
	for &p in positions {
		p.x = (p.x - center.x) * scale
		p.y = (p.y - center.y) * scale
		p.z = (p.z - center.z) * scale
	}
}

max_f32 :: proc(a, b: f32) -> f32 {
	if a > b do return a
	return b
}

run :: proc(app: ^App) {
	main_window := &app.windows[0]
	run_seconds := gfx.ez_gfx_config_run_seconds()
	screenshot_enabled := gfx.ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()
	previous_time := start_time

	for !gfx.ez_gfx_window_should_close(main_window) {
		gfx.ez_gfx_window_poll_events()
		shared.example_input_begin_frame(&app.input, main_window)

		now := glfw.GetTime()
		delta_time := f32(now - previous_time)
		previous_time = now
		shared.orbit_camera_update(&app.camera, &app.input, delta_time)

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
		vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)),
		app.mesh_count,
	)
	if !indirect.ok {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	descriptor_bytes := vk.DeviceSize(len(app.mesh_descriptors) * size_of(Mesh_Descriptor))
	mesh_descriptors_ptr := gfx.ez_gfx_render_acquire_structured_buffer(
		"mesh_descriptors",
		descriptor_bytes,
	)
	if mesh_descriptors_ptr == nil {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	mesh_descriptors := cast([^]Mesh_Descriptor)mesh_descriptors_ptr
	for descriptor, i in app.mesh_descriptors {
		mesh_descriptors[i] = descriptor
	}

	instance_bytes := vk.DeviceSize(len(app.mesh_instances) * size_of(Mesh_Instance))
	mesh_instances_ptr := gfx.ez_gfx_render_acquire_structured_buffer(
		"mesh_instances",
		instance_bytes,
	)
	if mesh_instances_ptr == nil {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	mesh_instances := cast([^]Mesh_Instance)mesh_instances_ptr
	for instance, i in app.mesh_instances {
		mesh_instances[i] = instance
	}

	if !gfx.ez_gfx_render_add_indirect_structured_buffer("draw_commands", &indirect) {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	compute_push := Compute_Push_Constants {
		instance_count = app.mesh_count,
	}
	compute := gfx.ez_gfx_render_add_compute_pipeline(
		&app.compute_shader,
		app.mesh_count,
		1,
		1,
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
	draw := gfx.ez_gfx_render_add_vertex_pipeline_with_indirect(
		&app.draw_shader,
		&indirect,
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
	if app.mesh_instances != nil {
		delete(app.mesh_instances)
		app.mesh_instances = nil
	}
	if app.mesh_descriptors != nil {
		delete(app.mesh_descriptors)
		app.mesh_descriptors = nil
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
