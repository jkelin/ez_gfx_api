package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_VERTEX_HEAPS :: 8
EZ_GFX_VERTEX_HEAP_NAME_MAX :: 32
EZ_GFX_DEFAULT_INDEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)
EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)

Ez_Gfx_Heap_Chunk :: struct {
	offset: vk.DeviceSize,
	size:   vk.DeviceSize,
}

Ez_Gfx_Pending_Free_Chunk :: struct {
	chunk:           Ez_Gfx_Heap_Chunk,
	retire_timeline: u64,
}

Ez_Gfx_Vertex_Allocation :: struct {
	start_index: u32,
	count:       u32,
}

Ez_Gfx_Gpu_Heap :: struct {
	buffer:              Ez_Gfx_Buffer,
	capacity:            vk.DeviceSize,
	stride:              vk.DeviceSize,
	high_water:          vk.DeviceSize,
	used_bytes:          vk.DeviceSize,
	free_chunks:         [dynamic]Ez_Gfx_Heap_Chunk,
	pending_free_chunks: [dynamic]Ez_Gfx_Pending_Free_Chunk,
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
	heap.high_water = 0
	heap.used_bytes = 0
	heap.free_chunks = make([dynamic]Ez_Gfx_Heap_Chunk)
	heap.pending_free_chunks = make([dynamic]Ez_Gfx_Pending_Free_Chunk)
	return true
}

ez_gfx_gpu_heap_destroy :: proc(heap: ^Ez_Gfx_Gpu_Heap) {
	ez_gfx_buffer_destroy(&heap.buffer)
	if raw_data(heap.free_chunks) != nil {
		delete(heap.free_chunks)
	}
	if raw_data(heap.pending_free_chunks) != nil {
		delete(heap.pending_free_chunks)
	}
	heap.capacity = 0
	heap.stride = 0
	heap.high_water = 0
	heap.used_bytes = 0
}

ez_gfx_gpu_heap_upload_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	data: []$T,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	byte_size := vk.DeviceSize(len(data) * size_of(T))
	if byte_size == 0 {
		allocation.start_index = u32(heap.high_water / heap.stride)
		return allocation, true
	}
	if vk.DeviceSize(size_of(T)) != heap.stride {
		fmt.eprintln("heap upload element size does not match heap stride")
		return allocation, false
	}
	offset, alloc_ok := ez_gfx_gpu_heap_allocate_range(heap, byte_size)
	if !alloc_ok {
		fmt.eprintln("GPU heap upload exceeds heap capacity")
		return allocation, false
	}

	if !ez_gfx_buffer_write_at(&heap.buffer, offset, data) {
		ez_gfx_gpu_heap_free_chunk(heap, Ez_Gfx_Heap_Chunk{offset = offset, size = byte_size})
		return allocation, false
	}

	allocation.start_index = u32(offset / heap.stride)
	allocation.count = u32(len(data))
	return allocation, true
}

ez_gfx_gpu_heap_upload :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	data: []$T,
) -> (
	start_index: u32,
	ok: bool,
) {
	allocation, alloc_ok := ez_gfx_gpu_heap_upload_allocation(heap, data)
	return allocation.start_index, alloc_ok
}

ez_gfx_gpu_heap_allocate_range :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
) -> (
	offset: vk.DeviceSize,
	ok: bool,
) {
	if heap.stride == 0 do return 0, false
	size := ez_gfx_gpu_heap_align_size(byte_size, heap.stride)
	if size == 0 do return heap.high_water, true

	ez_gfx_gpu_heap_collect_completed_frees(heap)

	for i in 0 ..< len(heap.free_chunks) {
		chunk := &heap.free_chunks[i]
		if chunk.size < size do continue

		offset = chunk.offset
		if chunk.size == size {
			ordered_remove(&heap.free_chunks, i)
		} else {
			chunk.offset += size
			chunk.size -= size
		}
		heap.used_bytes += size
		return offset, true
	}

	if heap.high_water + size > heap.capacity {
		return 0, false
	}
	offset = heap.high_water
	heap.high_water += size
	heap.used_bytes += size
	return offset, true
}

ez_gfx_gpu_heap_free_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> bool {
	if allocation.count == 0 do return true
	if heap.stride == 0 do return false
	chunk := Ez_Gfx_Heap_Chunk {
		offset = vk.DeviceSize(allocation.start_index) * heap.stride,
		size   = vk.DeviceSize(allocation.count) * heap.stride,
	}
	return ez_gfx_gpu_heap_free_chunk(heap, chunk)
}

ez_gfx_gpu_heap_free_chunk :: proc(heap: ^Ez_Gfx_Gpu_Heap, chunk: Ez_Gfx_Heap_Chunk) -> bool {
	if chunk.size == 0 do return true
	if chunk.offset + chunk.size > heap.high_water {
		fmt.eprintln("GPU heap free range exceeds allocated high-water mark")
		return false
	}
	if chunk.size > heap.used_bytes {
		fmt.eprintln("GPU heap free range exceeds live byte count")
		return false
	}

	heap.used_bytes -= chunk.size
	retire_timeline := ez_gfx_gpu_heap_retire_timeline()
	if retire_timeline <= ez_gfx_gpu_heap_completed_timeline() {
		if ez_gfx_gpu_heap_insert_free_chunk(heap, chunk) {
			return true
		}
		heap.used_bytes += chunk.size
		return false
	}

	append(&heap.pending_free_chunks, Ez_Gfx_Pending_Free_Chunk {
		chunk           = chunk,
		retire_timeline = retire_timeline,
	})
	return true
}

ez_gfx_gpu_heap_collect_completed_frees :: proc(heap: ^Ez_Gfx_Gpu_Heap) {
	completed_timeline := ez_gfx_gpu_heap_completed_timeline()
	i := 0
	for i < len(heap.pending_free_chunks) {
		pending := heap.pending_free_chunks[i]
		if pending.retire_timeline > completed_timeline {
			i += 1
			continue
		}
		ordered_remove(&heap.pending_free_chunks, i)
		if !ez_gfx_gpu_heap_insert_free_chunk(heap, pending.chunk) {
			fmt.eprintln("GPU heap pending free range overlaps an existing free chunk")
		}
	}
}

ez_gfx_gpu_heap_insert_free_chunk :: proc(heap: ^Ez_Gfx_Gpu_Heap, chunk: Ez_Gfx_Heap_Chunk) -> bool {
	if chunk.size == 0 do return true
	insert_at := 0
	for insert_at < len(heap.free_chunks) && heap.free_chunks[insert_at].offset < chunk.offset {
		insert_at += 1
	}

	if insert_at > 0 {
		prev := heap.free_chunks[insert_at - 1]
		if prev.offset + prev.size > chunk.offset {
			return false
		}
	}
	if insert_at < len(heap.free_chunks) {
		next := heap.free_chunks[insert_at]
		if chunk.offset + chunk.size > next.offset {
			return false
		}
	}

	append(&heap.free_chunks, chunk)
	for i := len(heap.free_chunks) - 1; i > insert_at; i -= 1 {
		heap.free_chunks[i] = heap.free_chunks[i - 1]
	}
	heap.free_chunks[insert_at] = chunk

	if insert_at > 0 {
		prev := &heap.free_chunks[insert_at - 1]
		curr := heap.free_chunks[insert_at]
		if prev.offset + prev.size == curr.offset {
			prev.size += curr.size
			ordered_remove(&heap.free_chunks, insert_at)
			insert_at -= 1
		}
	}

	for insert_at + 1 < len(heap.free_chunks) {
		curr := &heap.free_chunks[insert_at]
		next := heap.free_chunks[insert_at + 1]
		if curr.offset + curr.size != next.offset do break
		curr.size += next.size
		ordered_remove(&heap.free_chunks, insert_at + 1)
	}

	return true
}

ez_gfx_gpu_heap_align_size :: proc(size, alignment: vk.DeviceSize) -> vk.DeviceSize {
	if alignment == 0 do return size
	remainder := size % alignment
	if remainder == 0 do return size
	return size + alignment - remainder
}

ez_gfx_gpu_heap_completed_timeline :: proc() -> u64 {
	ctx := ez_gfx_current_ctx
	if ctx == nil || ctx.timeline_semaphore == vk.Semaphore(0) do return 0
	value: u64
	if vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &value) != .SUCCESS {
		return 0
	}
	return value
}

ez_gfx_gpu_heap_retire_timeline :: proc() -> u64 {
	ctx := ez_gfx_current_ctx
	if ctx == nil do return 0
	return ctx.timeline_counter
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
			ez_gfx_debug_handle(slot.heap.buffer.allocation_info.device_memory),
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

ez_gfx_vertex_manager_alloc_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	return ez_gfx_gpu_heap_upload_allocation(&manager.index_heap, indices)
}

ez_gfx_vertex_manager_free_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> bool {
	return ez_gfx_gpu_heap_free_allocation(&manager.index_heap, allocation)
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

ez_gfx_vertex_manager_alloc_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	vertices: []$T,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	heap := ez_gfx_vertex_manager_find_heap(manager, heap_name)
	if heap == nil {
		fmt.eprintf("missing vertex heap: %v\n", heap_name)
		return allocation, false
	}
	return ez_gfx_gpu_heap_upload_allocation(heap, vertices)
}

ez_gfx_vertex_manager_free_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> bool {
	heap := ez_gfx_vertex_manager_find_heap(manager, heap_name)
	if heap == nil {
		fmt.eprintf("missing vertex heap: %v\n", heap_name)
		return false
	}
	return ez_gfx_gpu_heap_free_allocation(heap, allocation)
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
