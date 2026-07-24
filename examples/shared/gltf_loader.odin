package shared

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import cgltf "vendor:cgltf"
import vk "vendor:vulkan"

// GPU-facing mesh description shared by examples. The transform carries the
// glTF node transform (with scene normalization baked in).
Mesh_Descriptor :: struct {
	index_count:          u32,
	first_index:          u32,
	vertex_offset:        u32,
	normal_vertex_offset: u32,
	transform:            Mat4,
}

// One drawable instance of a mesh. The transform is a per-instance world
// transform applied on top of the mesh descriptor transform (identity by default).
Mesh_Instance :: struct {
	mesh_index: u32,
	_pad0:      u32,
	_pad1:      u32,
	_pad2:      u32,
	color:      [4]f32,
	transform:  Mat4,
}

Cpu_Primitive :: struct {
	positions:       [dynamic][3]f32,
	normals:         [dynamic][3]f32,
	indices:         [dynamic]u32,
	vertex_count:    u32,
	index_count:     u32,
	world_transform: linalg.Matrix4f32,
}

// Result of loading a glTF file. Vertex data lives in cpu_primitives until uploaded.
Loaded_Mesh :: struct {
	data:           ^cgltf.data,
	cpu_primitives: [dynamic]Cpu_Primitive,
	descriptors:    [dynamic]Mesh_Descriptor,
	instances:      [dynamic]Mesh_Instance,
	mesh_count:     u32,
}

GLTF_NORMALIZED_EXTENT :: f32(3.0)

gltf_load_meshes :: proc(path: string) -> (mesh: Loaded_Mesh, ok: bool) {
	if !os.exists(path) {
		fmt.eprintf("glTF file not found: %v\n", path)
		return mesh, false
	}

	c_path := strings.clone_to_cstring(path, context.temp_allocator)

	options: cgltf.options
	data, parse_res := cgltf.parse_file(options, c_path)
	if parse_res != .success || data == nil {
		fmt.eprintf("cgltf parse failed for %v: %v\n", path, parse_res)
		return mesh, false
	}
	mesh.data = data

	if load_res := cgltf.load_buffers(options, data, c_path); load_res != .success {
		fmt.eprintf("cgltf buffer load failed for %v: %v\n", path, load_res)
		gltf_loaded_mesh_destroy(&mesh)
		return mesh, false
	}

	identity := linalg.MATRIX4F32_IDENTITY
	if data.scene != nil {
		for node in data.scene.nodes {
			if node == nil do continue
			if !gltf_collect_node(node, identity, &mesh) {
				gltf_loaded_mesh_destroy(&mesh)
				return mesh, false
			}
		}
	} else {
		for &node in data.nodes {
			if node.parent != nil do continue
			if !gltf_collect_node(&node, identity, &mesh) {
				gltf_loaded_mesh_destroy(&mesh)
				return mesh, false
			}
		}
	}

	if len(mesh.cpu_primitives) == 0 {
		fmt.eprintln("glTF file did not contain supported triangle primitives")
		gltf_loaded_mesh_destroy(&mesh)
		return mesh, false
	}

	normalization := gltf_normalization_transform(&mesh, GLTF_NORMALIZED_EXTENT)
	mesh.descriptors = make([dynamic]Mesh_Descriptor, len(mesh.cpu_primitives))
	mesh.instances = make([dynamic]Mesh_Instance, len(mesh.cpu_primitives))
	for prim, prim_index in mesh.cpu_primitives {
		world := mat4_from_linalg(prim.world_transform)
		mesh_index := u32(prim_index)
		mesh.descriptors[prim_index] = Mesh_Descriptor {
			index_count = prim.index_count,
			transform   = mat4_mul(normalization, world),
		}
		mesh.instances[prim_index] = Mesh_Instance {
			mesh_index = mesh_index,
			color      = {1, 1, 1, 1},
			transform  = mat4_identity(),
		}
	}
	mesh.mesh_count = u32(len(mesh.descriptors))
	return mesh, true
}

gltf_loaded_mesh_destroy :: proc(mesh: ^Loaded_Mesh) {
	for &prim in mesh.cpu_primitives {
		delete(prim.positions)
		delete(prim.normals)
		delete(prim.indices)
	}
	delete(mesh.cpu_primitives)
	delete(mesh.descriptors)
	delete(mesh.instances)
	if mesh.data != nil {
		cgltf.free(mesh.data)
		mesh.data = nil
	}
	mesh^ = {}
}

gltf_mesh_index_heap_bytes :: proc(mesh: ^Loaded_Mesh) -> vk.DeviceSize {
	total: vk.DeviceSize
	for prim in mesh.cpu_primitives {
		total += vk.DeviceSize(prim.index_count) * size_of(u32)
	}
	return total
}

gltf_mesh_vertex_heap_bytes :: proc(mesh: ^Loaded_Mesh, stride: vk.DeviceSize) -> vk.DeviceSize {
	total: vk.DeviceSize
	for prim in mesh.cpu_primitives {
		total += vk.DeviceSize(prim.vertex_count) * stride
	}
	return total
}

gltf_collect_node :: proc(node: ^cgltf.node, parent: linalg.Matrix4f32, mesh: ^Loaded_Mesh) -> bool {
	local := gltf_node_local_matrix(node)
	world := linalg.mul(parent, local)

	if node.mesh != nil {
		if !gltf_collect_mesh(node.mesh, world, mesh) {
			return false
		}
	}
	for child in node.children {
		if child == nil do continue
		if !gltf_collect_node(child, world, mesh) {
			return false
		}
	}
	return true
}

gltf_collect_mesh :: proc(cgltf_mesh: ^cgltf.mesh, world: linalg.Matrix4f32, mesh: ^Loaded_Mesh) -> bool {
	for &primitive in cgltf_mesh.primitives {
		if primitive.type != .triangles do continue
		if !gltf_collect_primitive(&primitive, world, mesh) {
			return false
		}
	}
	return true
}

gltf_collect_primitive :: proc(
	primitive: ^cgltf.primitive,
	world: linalg.Matrix4f32,
	mesh: ^Loaded_Mesh,
) -> bool {
	position_accessor: ^cgltf.accessor
	for &attribute in primitive.attributes {
		if attribute.type == .position {
			position_accessor = attribute.data
			break
		}
	}
	if position_accessor == nil {
		fmt.eprintln("triangle primitive missing POSITION attribute")
		return false
	}
	if position_accessor.type != .vec3 || position_accessor.component_type != .r_32f {
		fmt.eprintln("POSITION accessor must be vec3 float")
		return false
	}

	prim: Cpu_Primitive
	prim.world_transform = world
	prim.vertex_count = u32(position_accessor.count)

	float_count := position_accessor.count * cgltf.num_components(.vec3)
	prim.positions = make([dynamic][3]f32, int(position_accessor.count))
	unpacked := cgltf.accessor_unpack_floats(
		position_accessor,
		cast([^]f32)raw_data(prim.positions),
		float_count,
	)
	if unpacked != float_count {
		fmt.eprintln("failed to unpack POSITION accessor")
		delete(prim.positions)
		return false
	}

	if !gltf_collect_normals(primitive, &prim) {
		delete(prim.positions)
		return false
	}
	if !gltf_collect_indices(primitive, &prim) {
		delete(prim.positions)
		delete(prim.normals)
		return false
	}
	if prim.index_count == 0 {
		delete(prim.positions)
		delete(prim.normals)
		delete(prim.indices)
		return true
	}

	append(&mesh.cpu_primitives, prim)
	return true
}

gltf_collect_normals :: proc(primitive: ^cgltf.primitive, prim: ^Cpu_Primitive) -> bool {
	for &attribute in primitive.attributes {
		if attribute.type != .normal do continue
		accessor := attribute.data
		if accessor == nil do continue
		if accessor.type != .vec3 || accessor.component_type != .r_32f {
			break
		}
		if accessor.count != uint(prim.vertex_count) {
			break
		}
		float_count := accessor.count * cgltf.num_components(.vec3)
		prim.normals = make([dynamic][3]f32, int(accessor.count))
		unpacked := cgltf.accessor_unpack_floats(
			accessor,
			cast([^]f32)raw_data(prim.normals),
			float_count,
		)
		if unpacked == float_count do return true
		delete(prim.normals)
		break
	}

	prim.normals = make([dynamic][3]f32, int(prim.vertex_count))
	for &normal in prim.normals {
		normal = {0, 1, 0}
	}
	return true
}

gltf_collect_indices :: proc(primitive: ^cgltf.primitive, prim: ^Cpu_Primitive) -> bool {
	if primitive.indices == nil {
		prim.indices = make([dynamic]u32, int(prim.vertex_count))
		for i in 0 ..< int(prim.vertex_count) {
			prim.indices[i] = u32(i)
		}
		prim.index_count = prim.vertex_count
		return true
	}

	accessor := primitive.indices
	if accessor.type != .scalar {
		fmt.eprintln("index accessor must be scalar")
		return false
	}

	prim.indices = make([dynamic]u32, int(accessor.count))
	unpacked := cgltf.accessor_unpack_indices(
		accessor,
		raw_data(prim.indices),
		size_of(u32),
		accessor.count,
	)
	if unpacked != accessor.count {
		fmt.eprintln("failed to unpack index accessor")
		return false
	}
	prim.index_count = u32(accessor.count)
	return true
}

gltf_node_local_matrix :: proc(node: ^cgltf.node) -> linalg.Matrix4f32 {
	if node.has_matrix {
		return gltf_matrix_from_cgltf(node.matrix_)
	}

	translation := linalg.Vector3f32{0, 0, 0}
	if node.has_translation {
		translation = linalg.Vector3f32 {
			node.translation[0],
			node.translation[1],
			node.translation[2],
		}
	}

	rotation: linalg.Quaternionf32 = quaternion(w = 1, x = 0, y = 0, z = 0)
	if node.has_rotation {
		rotation = quaternion(
			w = node.rotation[3],
			x = node.rotation[0],
			y = node.rotation[1],
			z = node.rotation[2],
		)
	}

	scale := linalg.Vector3f32{1, 1, 1}
	if node.has_scale {
		scale = linalg.Vector3f32{node.scale[0], node.scale[1], node.scale[2]}
	}

	return linalg.matrix4_from_trs_f32(translation, rotation, scale)
}

gltf_matrix_from_cgltf :: proc(flat: [16]f32) -> linalg.Matrix4f32 {
	result: linalg.Matrix4f32
	for col in 0 ..< 4 {
		for row in 0 ..< 4 {
			result[row, col] = flat[col * 4 + row]
		}
	}
	return result
}

gltf_normalization_transform :: proc(mesh: ^Loaded_Mesh, target_extent: f32) -> Mat4 {
	found := false
	min_p, max_p: linalg.Vector3f32
	for prim in mesh.cpu_primitives {
		world := mat4_from_linalg(prim.world_transform)
		for position in prim.positions {
			p := mat4_transform_point(world, {position.x, position.y, position.z, 1.0})
			world_p := linalg.Vector3f32{p.x, p.y, p.z}
			if !found {
				min_p = world_p
				max_p = world_p
				found = true
				continue
			}
			if world_p.x < min_p.x do min_p.x = world_p.x
			if world_p.y < min_p.y do min_p.y = world_p.y
			if world_p.z < min_p.z do min_p.z = world_p.z
			if world_p.x > max_p.x do max_p.x = world_p.x
			if world_p.y > max_p.y do max_p.y = world_p.y
			if world_p.z > max_p.z do max_p.z = world_p.z
		}
	}
	if !found do return mat4_identity()

	center := (min_p + max_p) * 0.5
	extent := max_p - min_p
	largest := max_f32(max_f32(extent.x, extent.y), extent.z)
	if largest <= 0 do return mat4_identity()
	scale := target_extent / largest

	return Mat4 {
		{scale, 0, 0, -center.x * scale},
		{0, scale, 0, -center.y * scale},
		{0, 0, scale, -center.z * scale},
		{0, 0, 0, 1},
	}
}
