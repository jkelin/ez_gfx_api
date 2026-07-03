package shared

import gltf "../../vendor/glTF2"
import "core:fmt"
import "core:math/linalg"
import vk "vendor:vulkan"

// GPU-facing mesh description shared by all examples. The transform carries the
// glTF node transform (with scene normalization baked in) so vertex data can be
// uploaded untouched from the glTF buffers and positioned on the GPU.
// `vertex_offset` and `normal_vertex_offset` index into separate vertex heaps and
// may differ when each heap allocates independently.
Mesh_Descriptor :: struct {
	index_count:         u32,
	first_index:         u32,
	vertex_offset:       u32,
	normal_vertex_offset: u32,
	transform:           Mat4,
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

// One triangle primitive referencing vertex data in place inside the loaded glTF
// buffers. The slices are strided views: raw_data() is the base pointer, len() is
// the element count, and elements sit `*_stride` bytes apart. This lets the vertex
// manager copy the data straight into its staging buffer without an intermediate
// packed array. `owned_*` hold backing storage for data that had to be generated
// or converted (missing normals, non-u32 indices).
Gltf_Primitive :: struct {
	positions:       [][3]f32,
	position_stride: int,
	normals:         [][3]f32,
	normal_stride:   int,
	owned_normals:   [dynamic][3]f32,
	indices:         []u32,
	index_stride:    int,
	owned_indices:   [dynamic]u32,
	vertex_count:    u32,
	index_count:     u32,
	transform:       Mat4,
}

// Result of loading a glTF file. Keeps the parsed glTF document alive because the
// primitives alias its buffer memory; destroy with gltf_loaded_mesh_destroy after
// the vertex data has been uploaded.
Loaded_Mesh :: struct {
	data:        ^gltf.Data,
	primitives:  [dynamic]Gltf_Primitive,
	descriptors: [dynamic]Mesh_Descriptor,
	instances:   [dynamic]Mesh_Instance,
	mesh_count:  u32,
}

// Extent (largest bounding-box side) the loaded scene is normalized to.
GLTF_NORMALIZED_EXTENT :: f32(3.0)

// Loads all triangle primitives of a glTF file, computes per-node transforms and
// a scene normalization transform, and prepares strided views for zero-copy
// uploads. Vertex data is left inside the glTF buffers; transforms are carried in
// the mesh descriptors and applied on the GPU.
gltf_load_meshes :: proc(path: string) -> (mesh: Loaded_Mesh, ok: bool) {
	data, load_err := gltf.load_from_file(path)
	if load_err != nil {
		fmt.eprintf("failed to load glTF mesh: %v\n", load_err)
		return mesh, false
	}
	mesh.data = data
	if len(data.meshes) == 0 {
		fmt.eprintln("glTF file does not contain meshes")
		gltf_loaded_mesh_destroy(&mesh)
		return mesh, false
	}

	mesh.primitives = make([dynamic]Gltf_Primitive)
	mesh.descriptors = make([dynamic]Mesh_Descriptor)
	mesh.instances = make([dynamic]Mesh_Instance)

	root_transform := mat4_identity()
	if scene_index, has_scene := data.scene.?; has_scene && int(scene_index) < len(data.scenes) {
		for node_index in data.scenes[scene_index].nodes {
			if !gltf_collect_node(data, node_index, root_transform, &mesh) {
				gltf_loaded_mesh_destroy(&mesh)
				return mesh, false
			}
		}
	} else {
		for _, node_index in data.nodes {
			if !gltf_collect_node(data, gltf.Integer(node_index), root_transform, &mesh) {
				gltf_loaded_mesh_destroy(&mesh)
				return mesh, false
			}
		}
	}

	if len(mesh.primitives) == 0 {
		fmt.eprintln("glTF file did not contain supported triangle primitives")
		gltf_loaded_mesh_destroy(&mesh)
		return mesh, false
	}

	// Bake scene normalization into the descriptor transforms instead of touching
	// the vertex data, so positions upload directly from the glTF buffers.
	normalization := gltf_normalization_transform(&mesh, GLTF_NORMALIZED_EXTENT)
	for prim, prim_index in mesh.primitives {
		mesh_index := u32(prim_index)
		append(
			&mesh.descriptors,
			Mesh_Descriptor {
				index_count = prim.index_count,
				transform = mat4_mul(normalization, prim.transform),
			},
		)
		append(
			&mesh.instances,
			Mesh_Instance {
				mesh_index = mesh_index,
				color = {1, 1, 1, 1},
				transform = mat4_identity(),
			},
		)
	}
	mesh.mesh_count = u32(len(mesh.descriptors))
	return mesh, true
}

gltf_loaded_mesh_destroy :: proc(mesh: ^Loaded_Mesh) {
	for &prim in mesh.primitives {
		if raw_data(prim.owned_normals) != nil do delete(prim.owned_normals)
		if raw_data(prim.owned_indices) != nil do delete(prim.owned_indices)
	}
	if raw_data(mesh.primitives) != nil do delete(mesh.primitives)
	if raw_data(mesh.descriptors) != nil do delete(mesh.descriptors)
	if raw_data(mesh.instances) != nil do delete(mesh.instances)
	if mesh.data != nil do gltf.unload(mesh.data)
	mesh^ = {}
}

// Total index heap bytes required to upload all primitives.
gltf_mesh_index_heap_bytes :: proc(mesh: ^Loaded_Mesh) -> vk.DeviceSize {
	total: vk.DeviceSize
	for prim in mesh.primitives {
		total += vk.DeviceSize(prim.index_count) * size_of(u32)
	}
	return total
}

// Total vertex heap bytes required per attribute heap with the given stride.
gltf_mesh_vertex_heap_bytes :: proc(mesh: ^Loaded_Mesh, stride: vk.DeviceSize) -> vk.DeviceSize {
	total: vk.DeviceSize
	for prim in mesh.primitives {
		total += vk.DeviceSize(prim.vertex_count) * stride
	}
	return total
}

gltf_collect_node :: proc(
	data: ^gltf.Data,
	node_index: gltf.Integer,
	parent_transform: Mat4,
	mesh: ^Loaded_Mesh,
) -> bool {
	if int(node_index) >= len(data.nodes) {
		fmt.eprintln("glTF node index out of range")
		return false
	}
	node := data.nodes[node_index]
	local := gltf_node_matrix(node)
	transform := mat4_mul(parent_transform, local)

	if mesh_index, has_mesh := node.mesh.?; has_mesh {
		if int(mesh_index) >= len(data.meshes) {
			fmt.eprintln("glTF mesh index out of range")
			return false
		}
		if !gltf_collect_mesh(data, data.meshes[mesh_index], transform, mesh) {
			return false
		}
	}
	for child_index in node.children {
		if !gltf_collect_node(data, child_index, transform, mesh) {
			return false
		}
	}
	return true
}

gltf_collect_mesh :: proc(
	data: ^gltf.Data,
	gltf_mesh: gltf.Mesh,
	transform: Mat4,
	mesh: ^Loaded_Mesh,
) -> bool {
	for primitive in gltf_mesh.primitives {
		if primitive.mode != .Triangles do continue
		position_accessor, position_ok := primitive.attributes["POSITION"]
		if !position_ok do continue

		prim: Gltf_Primitive
		prim.transform = transform
		if !gltf_primitive_collect_positions(data, position_accessor, &prim) {
			return false
		}
		gltf_primitive_collect_normals(data, primitive, &prim)
		if !gltf_primitive_collect_indices(data, primitive, &prim) {
			gltf_primitive_destroy(&prim)
			return false
		}
		if prim.index_count == 0 {
			gltf_primitive_destroy(&prim)
			continue
		}
		append(&mesh.primitives, prim)
	}
	return true
}

gltf_primitive_destroy :: proc(prim: ^Gltf_Primitive) {
	if raw_data(prim.owned_normals) != nil do delete(prim.owned_normals)
	if raw_data(prim.owned_indices) != nil do delete(prim.owned_indices)
	prim^ = {}
}

// Builds a strided view over the glTF position data; no copy is made.
gltf_primitive_collect_positions :: proc(
	data: ^gltf.Data,
	accessor_index: gltf.Integer,
	prim: ^Gltf_Primitive,
) -> bool {
	accessor := data.accessors[accessor_index]
	if accessor.component_type != .Float || accessor.type != .Vector3 {
		fmt.eprintln("glTF loader only supports f32 vec3 positions")
		return false
	}
	view, view_ok := gltf_accessor_view(data, accessor_index)
	if !view_ok do return false

	prim.positions = gltf_strided_view(view, [3]f32)
	prim.position_stride = view.stride
	prim.vertex_count = accessor.count
	return true
}

// Builds a strided view over the glTF normal data, or generates constant up
// normals when the primitive has no usable NORMAL attribute. Generated normals
// are in mesh-local space; the descriptor transform orients them on the GPU.
gltf_primitive_collect_normals :: proc(
	data: ^gltf.Data,
	primitive: gltf.Mesh_Primitive,
	prim: ^Gltf_Primitive,
) {
	if normal_accessor, has_normals := primitive.attributes["NORMAL"]; has_normals {
		accessor := data.accessors[normal_accessor]
		if accessor.component_type == .Float &&
		   accessor.type == .Vector3 &&
		   accessor.count == prim.vertex_count {
			if view, view_ok := gltf_accessor_view(data, normal_accessor); view_ok {
				prim.normals = gltf_strided_view(view, [3]f32)
				prim.normal_stride = view.stride
				return
			}
		}
	}

	prim.owned_normals = make([dynamic][3]f32, int(prim.vertex_count))
	for &normal in prim.owned_normals {
		normal = {0, 1, 0}
	}
	prim.normals = prim.owned_normals[:]
	prim.normal_stride = size_of([3]f32)
}

// References u32 index data in place; u8/u16 indices (and index-less primitives)
// are converted into an owned u32 array since the GPU index heap is u32.
gltf_primitive_collect_indices :: proc(
	data: ^gltf.Data,
	primitive: gltf.Mesh_Primitive,
	prim: ^Gltf_Primitive,
) -> bool {
	index_accessor, has_indices := primitive.indices.?
	if !has_indices {
		prim.owned_indices = make([dynamic]u32, int(prim.vertex_count))
		for i in 0 ..< int(prim.vertex_count) {
			prim.owned_indices[i] = u32(i)
		}
		prim.indices = prim.owned_indices[:]
		prim.index_stride = size_of(u32)
		prim.index_count = prim.vertex_count
		return true
	}

	accessor := data.accessors[index_accessor]
	if accessor.type != .Scalar {
		fmt.eprintln("glTF index accessor must be scalar")
		return false
	}
	view, view_ok := gltf_accessor_view(data, index_accessor)
	if !view_ok do return false

	#partial switch accessor.component_type {
	case .Unsigned_Int:
		prim.indices = gltf_strided_view(view, u32)
		prim.index_stride = view.stride
	case .Unsigned_Byte, .Unsigned_Short:
		prim.owned_indices = make([dynamic]u32, int(accessor.count))
		for i in 0 ..< int(accessor.count) {
			offset := view.base_offset + i * view.stride
			if accessor.component_type == .Unsigned_Byte {
				prim.owned_indices[i] = u32(view.bytes[offset])
			} else {
				ptr: rawptr = &view.bytes[offset]
				prim.owned_indices[i] = u32((cast(^u16)ptr)^)
			}
		}
		prim.indices = prim.owned_indices[:]
		prim.index_stride = size_of(u32)
	case:
		fmt.eprintln("glTF indices must use an unsigned integer component type")
		return false
	}
	prim.index_count = accessor.count
	return true
}

// Reinterprets accessor memory as a strided slice view: only raw_data() and len()
// are meaningful, elements sit view.stride bytes apart. Callers must pass the
// stride alongside the slice (e.g. to the vertex manager upload procs).
gltf_strided_view :: proc(view: Gltf_Accessor_View, $T: typeid) -> []T {
	if view.count == 0 do return nil
	base: rawptr = &view.bytes[view.base_offset]
	return (cast([^]T)base)[:int(view.count)]
}

// Reads one strided position for CPU-side bounds computation; the vertex data
// itself is never rewritten.
gltf_primitive_position :: proc(prim: ^Gltf_Primitive, index: int) -> [3]f32 {
	base := uintptr(raw_data(prim.positions)) + uintptr(index * prim.position_stride)
	return (cast(^[3]f32)rawptr(base))^
}

// Computes a transform that centers the transformed scene at the origin and
// scales its largest bounding-box side to target_extent. Returned as a matrix so
// it can be baked into descriptor transforms instead of rewriting positions.
gltf_normalization_transform :: proc(mesh: ^Loaded_Mesh, target_extent: f32) -> Mat4 {
	found := false
	min_p: [3]f32
	max_p: [3]f32
	for &prim in mesh.primitives {
		for i in 0 ..< int(prim.vertex_count) {
			p := gltf_primitive_position(&prim, i)
			world := mat4_transform_point(prim.transform, {p.x, p.y, p.z, 1.0})
			point := [3]f32{world.x, world.y, world.z}
			if !found {
				min_p = point
				max_p = point
				found = true
				continue
			}
			if point.x < min_p.x do min_p.x = point.x
			if point.y < min_p.y do min_p.y = point.y
			if point.z < min_p.z do min_p.z = point.z
			if point.x > max_p.x do max_p.x = point.x
			if point.y > max_p.y do max_p.y = point.y
			if point.z > max_p.z do max_p.z = point.z
		}
	}
	if !found do return mat4_identity()

	center := (min_p + max_p) * 0.5
	extent := max_p - min_p
	largest := max_f32(max_f32(extent.x, extent.y), extent.z)
	if largest <= 0 do return mat4_identity()
	scale := target_extent / largest

	// Row-major scale-then-translate: p' = (p - center) * scale.
	return Mat4 {
		{scale, 0, 0, -center.x * scale},
		{0, scale, 0, -center.y * scale},
		{0, 0, scale, -center.z * scale},
		{0, 0, 0, 1},
	}
}

gltf_node_matrix :: proc(node: gltf.Node) -> Mat4 {
	base := gltf_matrix_to_mat4(node.mat)
	trs := mat4_from_linalg(
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
	return mat4_mul(base, trs)
}

gltf_quaternion_to_linalg :: proc(q_value: gltf.Quaternion) -> linalg.Quaternionf32 {
	q_storage := q_value
	q := (cast(^[4]f32)(&q_storage))^
	return quaternion(w = q[3], x = q[0], y = q[1], z = q[2])
}

gltf_matrix_to_mat4 :: proc(gltf_matrix: gltf.Matrix4) -> Mat4 {
	result: Mat4
	for row in 0 ..< 4 {
		for col in 0 ..< 4 {
			result[row][col] = f32(gltf_matrix[row, col])
		}
	}
	return result
}

Gltf_Accessor_View :: struct {
	bytes:       []byte,
	base_offset: int,
	stride:      int,
	count:       u32,
}

gltf_accessor_view :: proc(
	data: ^gltf.Data,
	accessor_index: gltf.Integer,
) -> (
	view: Gltf_Accessor_View,
	ok: bool,
) {
	accessor := data.accessors[accessor_index]
	view_index, has_view := accessor.buffer_view.?
	if !has_view {
		fmt.eprintln("glTF accessor does not support sparse or viewless accessors")
		return {}, false
	}

	buffer_view := data.buffer_views[view_index]
	uri := data.buffers[buffer_view.buffer].uri
	#partial switch buffer_bytes in uri {
	case []byte:
		view.bytes = buffer_bytes
	case:
		fmt.eprintln("glTF buffer data is not loaded as bytes")
		return {}, false
	}

	view.base_offset = int(buffer_view.byte_offset + accessor.byte_offset)
	view_stride, has_stride := buffer_view.byte_stride.?
	if has_stride {
		view.stride = int(view_stride)
	} else {
		view.stride = gltf_accessor_tight_stride(accessor)
	}
	view.count = accessor.count
	return view, true
}

gltf_read_vec3_f32 :: proc(view: Gltf_Accessor_View, index: int) -> [3]f32 {
	offset := view.base_offset + index * view.stride
	ptr: rawptr = &view.bytes[offset]
	return (cast(^[3]f32)ptr)^
}

gltf_accessor_tight_stride :: proc(accessor: gltf.Accessor) -> int {
	return gltf_component_size(accessor.component_type) * gltf_component_count(accessor.type)
}

gltf_component_size :: proc(component_type: gltf.Component_Type) -> int {
	#partial switch component_type {
	case .Byte, .Unsigned_Byte:
		return 1
	case .Short, .Unsigned_Short:
		return 2
	case .Unsigned_Int, .Float:
		return 4
	}
	return 0
}

gltf_component_count :: proc(accessor_type: gltf.Accessor_Type) -> int {
	#partial switch accessor_type {
	case .Scalar:
		return 1
	case .Vector2:
		return 2
	case .Vector3:
		return 3
	case .Vector4:
		return 4
	case .Matrix2:
		return 4
	case .Matrix3:
		return 9
	case .Matrix4:
		return 16
	}
	return 0
}
