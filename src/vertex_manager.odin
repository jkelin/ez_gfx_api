package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_VERTEX_HEAPS :: 8
EZ_GFX_VERTEX_HEAP_NAME_MAX :: 32
EZ_GFX_DEFAULT_INDEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)
EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)

Ez_Gfx_Gpu_Heap :: struct {
	buffer:   Ez_Gfx_Buffer,
	capacity: vk.DeviceSize,
	stride:   vk.DeviceSize,
	used:     vk.DeviceSize,
}

Ez_Gfx_Named_Vertex_Heap :: struct {
	name:     [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	name_len: int,
	heap:     Ez_Gfx_Gpu_Heap,
}

Ez_Gfx_Vertex_Manager :: struct {
	index_heap:        Ez_Gfx_Gpu_Heap,
	vertex_heaps:      [EZ_GFX_MAX_VERTEX_HEAPS]Ez_Gfx_Named_Vertex_Heap,
	vertex_heap_count: int,
}

ez_gfx_gpu_heap_create :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	debug_name: cstring = nil,
) -> bool {
	buffer, ok := ez_gfx_buffer_create(
		capacity,
		usage,
		{.HOST_VISIBLE, .HOST_COHERENT},
		debug_name,
		0.4,
	)
	if !ok do return false

	heap.buffer = buffer
	heap.capacity = capacity
	heap.stride = stride
	heap.used = 0
	return true
}

ez_gfx_gpu_heap_destroy :: proc(heap: ^Ez_Gfx_Gpu_Heap) {
	ez_gfx_buffer_destroy(&heap.buffer)
	heap.capacity = 0
	heap.stride = 0
	heap.used = 0
}

ez_gfx_gpu_heap_upload :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	data: []$T,
) -> (
	start_index: u32,
	ok: bool,
) {
	byte_size := vk.DeviceSize(len(data) * size_of(T))
	if byte_size == 0 {
		return u32(heap.used / heap.stride), true
	}
	if vk.DeviceSize(size_of(T)) != heap.stride {
		fmt.eprintln("heap upload element size does not match heap stride")
		return 0, false
	}
	if heap.used + byte_size > heap.capacity {
		// TODO: Replace the append-only bump allocator with free-list or ring reuse.
		fmt.eprintln("GPU heap upload exceeds heap capacity")
		return 0, false
	}

	start_index = u32(heap.used / heap.stride)
	if !ez_gfx_buffer_write_at(&heap.buffer, heap.used, data) {
		return 0, false
	}

	heap.used += byte_size
	return start_index, true
}

ez_gfx_vertex_manager_create :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	vertex_heap_names: []string,
	vertex_stride: vk.DeviceSize,
) -> bool {
	if !ez_gfx_gpu_heap_create(
		&manager.index_heap,
		EZ_GFX_DEFAULT_INDEX_HEAP_BYTES,
		vk.DeviceSize(size_of(u32)),
		{.INDEX_BUFFER},
		"ez_gfx index heap",
	) {
		return false
	}

	for name in vertex_heap_names {
		if !ez_gfx_vertex_manager_add_heap(
			manager,
			name,
			EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES,
			vertex_stride,
		) {
			ez_gfx_vertex_manager_destroy(manager)
			return false
		}
	}

	return true
}

ez_gfx_vertex_manager_add_heap :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	name: string,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
) -> bool {
	if manager.vertex_heap_count >= EZ_GFX_MAX_VERTEX_HEAPS {
		fmt.eprintln("too many vertex heaps")
		return false
	}

	slot := &manager.vertex_heaps[manager.vertex_heap_count]
	if !ez_gfx_copy_heap_name(&slot.name, &slot.name_len, name) {
		return false
	}
	if !ez_gfx_gpu_heap_create(&slot.heap, capacity, stride, {.STORAGE_BUFFER}) {
		return false
	}
	ctx := ez_gfx_get_current_ctx()
	if ctx != nil {
		ez_gfx_debug_set_named_object(
			ctx,
			.BUFFER,
			ez_gfx_debug_handle(slot.heap.buffer.handle),
			"ez_gfx vertex heap",
			slot.name[:],
			slot.name_len,
		)
		ez_gfx_debug_set_named_object(
			ctx,
			.DEVICE_MEMORY,
			ez_gfx_debug_handle(slot.heap.buffer.memory),
			"ez_gfx vertex heap memory",
			slot.name[:],
			slot.name_len,
		)
	}

	manager.vertex_heap_count += 1
	return true
}

ez_gfx_vertex_manager_destroy :: proc(manager: ^Ez_Gfx_Vertex_Manager) {
	for i in 0 ..< manager.vertex_heap_count {
		ez_gfx_gpu_heap_destroy(&manager.vertex_heaps[i].heap)
		manager.vertex_heaps[i].name_len = 0
	}
	manager.vertex_heap_count = 0
	ez_gfx_gpu_heap_destroy(&manager.index_heap)
}

ez_gfx_vertex_manager_upload_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
) -> (
	start_index: u32,
	ok: bool,
) {
	return ez_gfx_gpu_heap_upload(&manager.index_heap, indices)
}

ez_gfx_vertex_manager_upload_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	vertices: []$T,
) -> (
	start_index: u32,
	ok: bool,
) {
	heap := ez_gfx_vertex_manager_find_heap(manager, heap_name)
	if heap == nil {
		fmt.eprintf("missing vertex heap: %v\n", heap_name)
		return 0, false
	}
	return ez_gfx_gpu_heap_upload(heap, vertices)
}

ez_gfx_vertex_manager_find_heap :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
) -> ^Ez_Gfx_Gpu_Heap {
	for i in 0 ..< manager.vertex_heap_count {
		vertex_heap := &manager.vertex_heaps[i]
		if ez_gfx_heap_name_equals_string(vertex_heap.name[:], vertex_heap.name_len, heap_name) {
			return &vertex_heap.heap
		}
	}
	return nil
}

ez_gfx_vertex_manager_find_heap_by_stored_name :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	name: []byte,
	name_len: int,
) -> ^Ez_Gfx_Gpu_Heap {
	for i in 0 ..< manager.vertex_heap_count {
		vertex_heap := &manager.vertex_heaps[i]
		if ez_gfx_heap_name_equals_bytes(
			vertex_heap.name[:],
			vertex_heap.name_len,
			name,
			name_len,
		) {
			return &vertex_heap.heap
		}
	}
	return nil
}

ez_gfx_copy_heap_name :: proc(
	dst: ^[EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	dst_len: ^int,
	name: string,
) -> bool {
	if len(name) > EZ_GFX_VERTEX_HEAP_NAME_MAX {
		fmt.eprintf("vertex heap name is too long: %v\n", name)
		return false
	}

	for i in 0 ..< EZ_GFX_VERTEX_HEAP_NAME_MAX {
		dst[i] = 0
	}
	for i in 0 ..< len(name) {
		dst[i] = name[i]
	}
	dst_len^ = len(name)
	return true
}

ez_gfx_heap_name_equals_string :: proc(name: []byte, name_len: int, other: string) -> bool {
	if name_len != len(other) do return false
	for i in 0 ..< len(other) {
		if name[i] != other[i] do return false
	}
	return true
}

ez_gfx_heap_name_equals_bytes :: proc(a: []byte, a_len: int, b: []byte, b_len: int) -> bool {
	if a_len != b_len do return false
	for i in 0 ..< a_len {
		if a[i] != b[i] do return false
	}
	return true
}
