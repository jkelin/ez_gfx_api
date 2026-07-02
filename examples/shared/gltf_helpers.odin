package shared

import gltf "../../vendor/glTF2"
import "core:fmt"

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

gltf_read_vec3_f32 :: proc(
	view: Gltf_Accessor_View,
	index: int,
) -> [3]f32 {
	offset := view.base_offset + index * view.stride
	ptr: rawptr = &view.bytes[offset]
	return (cast(^[3]f32)ptr)^
}

gltf_append_indices_u32 :: proc(
	data: ^gltf.Data,
	primitive: gltf.Mesh_Primitive,
	position_count: u32,
	indices: ^[dynamic]u32,
) -> (
	count: u32,
	ok: bool,
) {
	index_accessor, has_indices := primitive.indices.?
	if !has_indices {
		for i in 0 ..< int(position_count) {
			append(indices, u32(i))
		}
		return position_count, true
	}

	accessor := data.accessors[index_accessor]
	if accessor.type != .Scalar {
		fmt.eprintln("glTF index accessor must be scalar")
		return 0, false
	}
	view, view_ok := gltf_accessor_view(data, index_accessor)
	if !view_ok do return 0, false

	for i in 0 ..< int(accessor.count) {
		offset := view.base_offset + i * view.stride
		#partial switch accessor.component_type {
		case .Unsigned_Byte:
			append(indices, u32(view.bytes[offset]))
		case .Unsigned_Short:
			ptr: rawptr = &view.bytes[offset]
			append(indices, u32((cast(^u16)ptr)^))
		case .Unsigned_Int:
			ptr: rawptr = &view.bytes[offset]
			append(indices, (cast(^u32)ptr)^)
		case:
			fmt.eprintln("glTF indices must use an unsigned integer component type")
			return 0, false
		}
	}
	return accessor.count, true
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
