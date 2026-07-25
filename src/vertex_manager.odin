#+private
package ez_gfx

import intrinsics "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:thread"
import vk "vendor:vulkan"

EZ_GFX_MAX_VERTEX_HEAPS :: 8
EZ_GFX_VERTEX_HEAP_NAME_MAX :: 32
EZ_GFX_DEFAULT_INDEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)
EZ_GFX_INTERNAL_DEFAULT_VERTEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)
























@(private)
vertex_manager_fault :: proc(message: string) {
	fmt.eprintln(message)
	panic(message)
}

gpu_heap_create :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	debug_name: cstring = nil,
) {
	buffer, ok := buffer_create(
		capacity,
		usage | {.TRANSFER_DST},
		{.DEVICE_LOCAL},
		debug_name,
		0.7,
	)
	if !ok {
		vertex_manager_fault("failed to create GPU heap buffer")
	}

	heap.buffer = buffer
	heap.capacity = capacity
	heap.stride = stride
	heap.high_water = 0
	heap.used_bytes = 0
	heap.free_chunks = make([dynamic]Ez_Gfx_Heap_Chunk)
	heap.pending_free_chunks = make([dynamic]Ez_Gfx_Pending_Free_Chunk)
}

gpu_heap_destroy :: proc(heap: ^Ez_Gfx_Gpu_Heap) {
	buffer_destroy(&heap.buffer)
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

gpu_heap_upload_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	data: []$T,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	fmt.eprintln("ez_gfx_gpu_heap_upload_allocation is not supported for device-local async heaps; use Ez_Gfx_Vertex_Manager upload APIs")
	return allocation, false
}

gpu_heap_reserve_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
	element_count: u32,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	offset: vk.DeviceSize,
	ok: bool,
) {
	if byte_size == 0 {
		allocation.start_index = u32(heap.high_water / heap.stride)
		return allocation, heap.high_water, true
	}
	alloc_ok: bool
	offset, alloc_ok = gpu_heap_allocate_range(heap, byte_size)
	if !alloc_ok {
		fmt.eprintln("GPU heap upload exceeds heap capacity")
		return allocation, 0, false
	}

	allocation.start_index = u32(offset / heap.stride)
	allocation.count = element_count
	return allocation, offset, true
}

gpu_heap_upload :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	data: []$T,
) -> (
	start_index: u32,
	ok: bool,
) {
	allocation, alloc_ok := gpu_heap_upload_allocation(heap, data)
	return allocation.start_index, alloc_ok
}

gpu_heap_allocate_range :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
) -> (
	offset: vk.DeviceSize,
	ok: bool,
) {
	if heap.stride == 0 do return 0, false
	size := gpu_heap_align_size(byte_size, heap.stride)
	if size == 0 do return heap.high_water, true

	gpu_heap_collect_completed_frees(heap)

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

gpu_heap_free_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> bool {
	if allocation.count == 0 do return true
	if heap.stride == 0 do return false
	chunk := Ez_Gfx_Heap_Chunk {
		offset = vk.DeviceSize(allocation.start_index) * heap.stride,
		size   = vk.DeviceSize(allocation.count) * heap.stride,
	}
	return gpu_heap_free_chunk(heap, chunk)
}

gpu_heap_free_chunk :: proc(heap: ^Ez_Gfx_Gpu_Heap, chunk: Ez_Gfx_Heap_Chunk) -> bool {
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
	retire_timeline := gpu_heap_retire_timeline()
	if retire_timeline <= gpu_heap_completed_timeline() {
		if gpu_heap_insert_free_chunk(heap, chunk) {
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

gpu_heap_collect_completed_frees :: proc(heap: ^Ez_Gfx_Gpu_Heap) {
	completed_timeline := gpu_heap_completed_timeline()
	i := 0
	for i < len(heap.pending_free_chunks) {
		pending := heap.pending_free_chunks[i]
		if pending.retire_timeline > completed_timeline {
			i += 1
			continue
		}
		ordered_remove(&heap.pending_free_chunks, i)
		if !gpu_heap_insert_free_chunk(heap, pending.chunk) {
			fmt.eprintln("GPU heap pending free range overlaps an existing free chunk")
		}
	}
}

gpu_heap_insert_free_chunk :: proc(heap: ^Ez_Gfx_Gpu_Heap, chunk: Ez_Gfx_Heap_Chunk) -> bool {
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

gpu_heap_align_size :: proc(size, alignment: vk.DeviceSize) -> vk.DeviceSize {
	if alignment == 0 do return size
	remainder := size % alignment
	if remainder == 0 do return size
	return size + alignment - remainder
}

gpu_heap_completed_timeline :: proc() -> u64 {
	ctx := get_current_ctx()
	if ctx == nil || ctx.timeline_semaphore == vk.Semaphore(0) do return 0
	value: u64
	if vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &value) != .SUCCESS {
		return 0
	}
	return value
}

gpu_heap_retire_timeline :: proc() -> u64 {
	ctx := get_current_ctx()
	if ctx == nil do return 0
	return ctx.timeline_counter
}

vertex_manager_begin :: proc(manager: ^Ez_Gfx_Vertex_Manager) {
	ctx := get_current_ctx()
	if ctx == nil {
		vertex_manager_fault(
			"ez_gfx_vertex_manager_begin called without a current context",
		)
	}
	if manager.worker != nil ||
	   manager.upload_command_pool != vk.CommandPool(0) ||
	   manager.index_heap.buffer.handle != vk.Buffer(0) ||
	   manager.vertex_heap_count > 0 {
		// A second begin is a reset request; release the previous worker,
		// command pool, and heaps before rebuilding the manager in place.
		vertex_manager_destroy(manager)
	}
	manager^ = {}
	manager.jobs = make([dynamic]Ez_Gfx_Vertex_Upload_Job)
	manager.pending_staging = make([dynamic]Ez_Gfx_Vertex_Staging_Retire_Job)
	manager.pending_graphics_handoffs = make([dynamic]Ez_Gfx_Vertex_Graphics_Handoff_Job)

	if !vertex_manager_create_upload_commands(manager, ctx) {
		vertex_manager_destroy(manager)
		vertex_manager_fault("failed to create vertex upload command pool")
	}

	manager.worker = thread.create(vertex_upload_thread)
	if manager.worker == nil {
		vertex_manager_destroy(manager)
		vertex_manager_fault("failed to create vertex upload thread")
	}
	manager.worker.data = manager
	thread.start(manager.worker)
}

vertex_manager_create :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	vertex_heap_names: []string,
	vertex_stride: vk.DeviceSize,
) {
	// Context initialization owns the manager lifetime; later callers only add
	// application-specific heaps and must not replace its live upload resources.
	if manager.worker == nil {
		vertex_manager_begin(manager)
		gpu_heap_create(
			&manager.index_heap,
			EZ_GFX_DEFAULT_INDEX_HEAP_BYTES,
			vk.DeviceSize(size_of(u32)),
			{.INDEX_BUFFER},
			"ez_gfx index heap",
		)
	}

	for name in vertex_heap_names {
		vertex_manager_add_heap(
			manager,
			name,
			EZ_GFX_INTERNAL_DEFAULT_VERTEX_HEAP_BYTES,
			vertex_stride,
		)
	}
}

vertex_manager_add_heap :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	name: string,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
) {

	slot := &manager.vertex_heaps[manager.vertex_heap_count]
	copy_heap_name(&slot.name, &slot.name_len, name)
	gpu_heap_create(&slot.heap, capacity, stride, {.STORAGE_BUFFER})
	ctx := get_current_ctx()
	if ctx != nil {
		debug_set_named_object(
			ctx,
			.BUFFER,
			debug_handle(slot.heap.buffer.handle),
			"ez_gfx vertex heap",
			slot.name[:],
			slot.name_len,
		)
		debug_set_named_object(
			ctx,
			.DEVICE_MEMORY,
			debug_handle(slot.heap.buffer.allocation_info.device_memory),
			"ez_gfx vertex heap memory",
			slot.name[:],
			slot.name_len,
		)
	}

	manager.vertex_heap_count += 1
}

vertex_manager_destroy :: proc(manager: ^Ez_Gfx_Vertex_Manager) {
	ctx := get_current_ctx()
	if manager.worker != nil {
		sync.mutex_lock(&manager.mutex)
		manager.shutdown = true
		sync.mutex_unlock(&manager.mutex)
		sync.cond_broadcast(&manager.cond)
		thread.join(manager.worker)
		thread.destroy(manager.worker)
		manager.worker = nil
	}
	for i in 0 ..< len(manager.jobs) {
		vertex_upload_job_release_source(&manager.jobs[i])
	}
	if raw_data(manager.jobs) != nil do delete(manager.jobs)
	for i in 0 ..< len(manager.pending_staging) {
		buffer_destroy(&manager.pending_staging[i].buffer)
	}
	if raw_data(manager.pending_staging) != nil do delete(manager.pending_staging)
	if raw_data(manager.pending_graphics_handoffs) != nil do delete(manager.pending_graphics_handoffs)

	for i in 0 ..< manager.vertex_heap_count {
		gpu_heap_destroy(&manager.vertex_heaps[i].heap)
		manager.vertex_heaps[i].name_len = 0
	}
	manager.vertex_heap_count = 0
	gpu_heap_destroy(&manager.index_heap)
	if ctx != nil && ctx.device != nil && manager.upload_command_pool != vk.CommandPool(0) {
		vk.DestroyCommandPool(ctx.device, manager.upload_command_pool, nil)
	}
	manager^ = {}
}

vertex_manager_create_upload_commands :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	ctx: ^Ez_Gfx_Ctx,
) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.transfer_queue_family_index,
	}
	if vk.CreateCommandPool(ctx.device, &pool_info, nil, &manager.upload_command_pool) != .SUCCESS {
		fmt.eprintln("failed to create vertex upload command pool")
		return false
	}
	return true
}

// `source_stride` is the byte distance between consecutive source indices; 0 means
// tightly packed. A non-zero stride lets callers reference index data in place (for
// example inside a parsed glTF buffer) so it is copied straight into the staging
// buffer without an intermediate packed array.
vertex_manager_upload_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
	source_stride: vk.DeviceSize = 0,
) -> u32 {
	allocation, alloc_ok := vertex_manager_alloc_indices(manager, indices, source_stride)
	if !alloc_ok {
		fmt.eprintln("index upload failed")
		panic("index upload failed")
	}
	return allocation.start_index
}

vertex_manager_alloc_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
	source_stride: vk.DeviceSize = 0,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	return vertex_manager_schedule_upload(
		manager,
		.Indices,
		"",
		&manager.index_heap,
		raw_data(indices),
		u32(len(indices)),
		vk.DeviceSize(size_of(u32)),
		source_stride,
	)
}

vertex_manager_free_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> bool {
	return gpu_heap_free_allocation(&manager.index_heap, allocation)
}

// `source_stride` is the byte distance between consecutive source vertices; 0 means
// tightly packed (size_of(T)). With a non-zero stride `vertices` acts as a strided
// view: raw_data(vertices) is the base pointer, len(vertices) is the element count,
// and only size_of(T) payload bytes are read per element. This lets callers upload
// attributes straight out of interleaved source data (such as glTF buffer views)
// with a single copy into the staging buffer. When size_of(T) is smaller than the
// heap stride the remaining destination bytes are zero-filled. Panics on failure
// after logging to stderr.
vertex_manager_upload_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	vertices: []$T,
	source_stride: vk.DeviceSize = 0,
) -> u32 {
	allocation, alloc_ok := vertex_manager_alloc_vertices(
		manager,
		heap_name,
		vertices,
		source_stride,
	)
	if !alloc_ok {
		fmt.eprintln("vertex upload failed")
		panic("vertex upload failed")
	}
	return allocation.start_index
}

vertex_manager_alloc_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	vertices: []$T,
	source_stride: vk.DeviceSize = 0,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	heap := vertex_manager_find_heap(manager, heap_name)
	if heap == nil {
		fmt.eprintf("missing vertex heap: %v\n", heap_name)
		return allocation, false
	}
	return vertex_manager_schedule_upload(
		manager,
		.Vertices,
		heap_name,
		heap,
		raw_data(vertices),
		u32(len(vertices)),
		vk.DeviceSize(size_of(T)),
		source_stride,
	)
}

// Copies `element_count` elements of `element_size` payload bytes from a source
// laid out with `src_stride` into a destination laid out with `dst_stride`. Strides
// are byte distances between consecutive elements and must be at least
// `element_size`; bytes between payloads are left untouched. Pure: reads only from
// src, writes only into dst, never allocates. Collapses to a single memcpy when both
// sides are tightly packed and uses unaligned SIMD/scalar-register moves for the
// common vertex payload sizes so per-element gathers stay fast.
vertex_copy_strided :: proc "contextless" (
	dst: rawptr,
	dst_stride: int,
	src: rawptr,
	src_stride: int,
	element_size: int,
	element_count: int,
) {

	if dst_stride == element_size && src_stride == element_size {
		intrinsics.mem_copy_non_overlapping(dst, src, element_size * element_count)
		return
	}

	dst_bytes := ([^]u8)(dst)
	src_bytes := ([^]u8)(src)
	switch element_size {
	case 16:
		// Full float4/uint4 payloads move as one unaligned 128-bit SIMD lane.
		for i in 0 ..< element_count {
			value := intrinsics.unaligned_load(cast(^#simd[16]u8)&src_bytes[i * src_stride])
			intrinsics.unaligned_store(cast(^#simd[16]u8)&dst_bytes[i * dst_stride], value)
		}
	case 12:
		// float3 payloads (typical glTF positions/normals) move as a 64-bit and a
		// 32-bit register pair instead of a per-element memcpy call.
		for i in 0 ..< element_count {
			src_element := i * src_stride
			dst_element := i * dst_stride
			low := intrinsics.unaligned_load(cast(^u64)&src_bytes[src_element])
			high := intrinsics.unaligned_load(cast(^u32)&src_bytes[src_element + 8])
			intrinsics.unaligned_store(cast(^u64)&dst_bytes[dst_element], low)
			intrinsics.unaligned_store(cast(^u32)&dst_bytes[dst_element + 8], high)
		}
	case 8:
		for i in 0 ..< element_count {
			value := intrinsics.unaligned_load(cast(^u64)&src_bytes[i * src_stride])
			intrinsics.unaligned_store(cast(^u64)&dst_bytes[i * dst_stride], value)
		}
	case 4:
		for i in 0 ..< element_count {
			value := intrinsics.unaligned_load(cast(^u32)&src_bytes[i * src_stride])
			intrinsics.unaligned_store(cast(^u32)&dst_bytes[i * dst_stride], value)
		}
	case 2:
		for i in 0 ..< element_count {
			value := intrinsics.unaligned_load(cast(^u16)&src_bytes[i * src_stride])
			intrinsics.unaligned_store(cast(^u16)&dst_bytes[i * dst_stride], value)
		}
	case 1:
		for i in 0 ..< element_count {
			dst_bytes[i * dst_stride] = src_bytes[i * src_stride]
		}
	case:
		for i in 0 ..< element_count {
			intrinsics.mem_copy_non_overlapping(
				&dst_bytes[i * dst_stride],
				&src_bytes[i * src_stride],
				element_size,
			)
		}
	}
}

// Schedules a transfer-queue upload. The caller's data is copied straight into the
// staging buffer here (honoring `source_stride`), so async workers never observe
// caller memory after this returns and no intermediate CPU packing buffer exists.
// `element_size` is the payload copied per element and may be smaller than the heap
// stride (destination padding is zero-filled); `source_stride` of 0 means tightly
// packed source data.
vertex_manager_schedule_upload :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	kind: Ez_Gfx_Vertex_Upload_Kind,
	heap_name: string,
	heap: ^Ez_Gfx_Gpu_Heap,
	source: rawptr,
	element_count: u32,
	element_size: vk.DeviceSize,
	source_stride: vk.DeviceSize = 0,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	ctx := get_current_ctx()
	stride := source_stride
	if stride == 0 do stride = element_size
	byte_size := vk.DeviceSize(element_count) * heap.stride
	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	offset: vk.DeviceSize
	allocation, offset, ok = gpu_heap_reserve_allocation(heap, byte_size, element_count)
	if !ok do return allocation, false
	if byte_size == 0 do return allocation, true

	staging, mapped, staging_ok := buffer_create_mapped(
		byte_size,
		{.TRANSFER_SRC},
		"ez_gfx vertex staging buffer",
		0.2,
	)
	if !staging_ok {
		_ = gpu_heap_free_chunk(heap, Ez_Gfx_Heap_Chunk{offset = offset, size = byte_size})
		return allocation, false
	}
	if element_size < heap.stride {
		// Freshly created staging memory is uninitialized; clear it so destination
		// padding lanes (e.g. the w component of float3 payloads) are deterministic.
		mem.zero(mapped, int(byte_size))
	}
	vertex_copy_strided(
		mapped,
		int(heap.stride),
		source,
		int(stride),
		int(element_size),
		int(element_count),
	)

	timeline := ctx_next_timeline_value(ctx)
	job := Ez_Gfx_Vertex_Upload_Job {
		kind = kind,
		heap = heap,
		allocation = allocation,
		offset = offset,
		byte_size = byte_size,
		staging = staging,
		transfer_timeline = timeline,
	}
	if kind == .Vertices {
		copy_heap_name(&job.heap_name, &job.heap_name_len, heap_name)
	}
	append(&manager.jobs, job)
	intrinsics.atomic_store_explicit(&manager.latest_scheduled_vertex_timeline, timeline, .Seq_Cst)
	sync.cond_signal(&manager.cond)
	return allocation, true
}

vertex_upload_thread :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	manager := cast(^Ez_Gfx_Vertex_Manager)worker.data
	if manager == nil do return
	ctx := vertex_manager_find_owner(manager)
	if ctx == nil do return
	context.user_ptr = ctx

	for {
		job: Ez_Gfx_Vertex_Upload_Job
		has_job := false

		sync.mutex_lock(&manager.mutex)
		for len(manager.jobs) == 0 && !manager.shutdown {
			sync.cond_wait(&manager.cond, &manager.mutex)
		}
		if manager.shutdown {
			sync.mutex_unlock(&manager.mutex)
			break
		}
		job = manager.jobs[0]
		ordered_remove(&manager.jobs, 0)
		has_job = true
		sync.mutex_unlock(&manager.mutex)

		if !has_job do continue
		err := vertex_upload_job(manager, ctx, &job)
		vertex_finish_job(manager, ctx, &job, err)
	}
}

vertex_manager_find_owner :: proc(manager: ^Ez_Gfx_Vertex_Manager) -> ^Ez_Gfx_Ctx {
	return cast(^Ez_Gfx_Ctx)(uintptr(manager) - offset_of(Ez_Gfx_Ctx, vertex_manager))
}

vertex_upload_job :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	ctx: ^Ez_Gfx_Ctx,
	job: ^Ez_Gfx_Vertex_Upload_Job,
) -> Ez_Gfx_Vertex_Upload_Error {
	if job.byte_size == 0 do return .None
	// The staging buffer was filled at schedule time; the worker only records the
	// GPU-side copy and hands the buffer to the retire queue.
	command_buffer: vk.CommandBuffer
	upload_ok: bool
	command_buffer, upload_ok = vertex_submit_upload(manager, ctx, job, &job.staging)
	if !upload_ok {
		return .Vulkan_Failed
	}

	staging := job.staging
	job.staging = {}
	sync.mutex_lock(&manager.mutex)
	append(&manager.pending_staging, Ez_Gfx_Vertex_Staging_Retire_Job {
		buffer = staging,
		command_buffer = command_buffer,
		retire_timeline = job.transfer_timeline,
	})
	append(&manager.pending_graphics_handoffs, Ez_Gfx_Vertex_Graphics_Handoff_Job {
		buffer = job.heap.buffer.handle,
		offset = job.offset,
		size = job.byte_size,
		transfer_timeline = job.transfer_timeline,
	})
	sync.mutex_unlock(&manager.mutex)
	return .None
}

vertex_submit_upload :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	ctx: ^Ez_Gfx_Ctx,
	job: ^Ez_Gfx_Vertex_Upload_Job,
	staging: ^Ez_Gfx_Buffer,
) -> (
	command_buffer: vk.CommandBuffer,
	ok: bool,
) {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = manager.upload_command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(ctx.device, &alloc_info, &command_buffer) != .SUCCESS {
		fmt.eprintln("failed to allocate vertex upload command buffer")
		return command_buffer, false
	}
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
		vk.FreeCommandBuffers(ctx.device, manager.upload_command_pool, 1, &command_buffer)
		return command_buffer, false
	}

	copy_region := vk.BufferCopy {
		srcOffset = 0,
		dstOffset = job.offset,
		size = job.byte_size,
	}
	vk.CmdCopyBuffer(command_buffer, staging.handle, job.heap.buffer.handle, 1, &copy_region)
	if ctx.transfer_queue_family_index != ctx.queue_family_index {
		vertex_buffer_barrier_queue_family(
			command_buffer,
			job.heap.buffer.handle,
			job.offset,
			job.byte_size,
			{.TRANSFER_WRITE},
			{},
			{.TRANSFER},
			{.ALL_COMMANDS},
			ctx.transfer_queue_family_index,
			ctx.queue_family_index,
		)
	}

	if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
		vk.FreeCommandBuffers(ctx.device, manager.upload_command_pool, 1, &command_buffer)
		return command_buffer, false
	}

	signal_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = ctx.timeline_semaphore,
		value     = job.transfer_timeline,
		stageMask = {.ALL_COMMANDS},
	}
	command_submit := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = command_buffer,
	}
	submit_info := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &command_submit,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos = &signal_info,
	}
	if job.transfer_timeline > 1 && !ctx_wait_timeline(ctx, job.transfer_timeline - 1) {
		vk.FreeCommandBuffers(ctx.device, manager.upload_command_pool, 1, &command_buffer)
		return command_buffer, false
	}
	sync.mutex_lock(&ctx.queue_mutex)
	result := vk.QueueSubmit2(ctx.transfer_queue, 1, &submit_info, vk.Fence(0))
	sync.mutex_unlock(&ctx.queue_mutex)
	if result != .SUCCESS {
		vk.FreeCommandBuffers(ctx.device, manager.upload_command_pool, 1, &command_buffer)
		return command_buffer, false
	}
	vertex_manager_mark_submitted(manager, job.transfer_timeline)
	return command_buffer, true
}

vertex_finish_job :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	ctx: ^Ez_Gfx_Ctx,
	job: ^Ez_Gfx_Vertex_Upload_Job,
	err: Ez_Gfx_Vertex_Upload_Error,
) {
	if err != .None {
		_ = gpu_heap_free_allocation(job.heap, job.allocation)
		if texture_signal_timeline(ctx, job.transfer_timeline) {
			vertex_manager_mark_submitted(manager, job.transfer_timeline)
		}
	}
	if ctx.vertex_uploaded_callback != nil {
		heap_name_bytes: [EZ_GFX_VERTEX_HEAP_NAME_MAX + 1]byte
		for i in 0 ..< job.heap_name_len {
			heap_name_bytes[i] = job.heap_name[i]
		}
		heap_name_bytes[job.heap_name_len] = 0
		context_handle, handle_ok := handle_pack_context(ctx.local_handle)
		if handle_ok {
			ctx.vertex_uploaded_callback(
				context_handle,
				job.kind,
				cast(cstring)rawptr(&heap_name_bytes[0]),
				job.allocation,
				err,
				ctx.vertex_uploaded_user_data,
			)
		}
	}
	vertex_upload_job_release_source(job)
}

vertex_upload_job_release_source :: proc(job: ^Ez_Gfx_Vertex_Upload_Job) {
	if job.staging.handle == vk.Buffer(0) do return
	buffer_destroy(&job.staging)
	job.staging = {}
}

vertex_manager_latest_scheduled_timeline :: proc(manager: ^Ez_Gfx_Vertex_Manager) -> u64 {
	if manager == nil do return 0
	return intrinsics.atomic_load_explicit(&manager.latest_scheduled_vertex_timeline, .Seq_Cst)
}

vertex_manager_wait_submitted_timeline :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	target_timeline: u64,
) -> bool {
	if manager == nil || target_timeline == 0 do return true
	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	for !manager.shutdown &&
	    intrinsics.atomic_load_explicit(&manager.latest_submitted_vertex_timeline, .Seq_Cst) <
	    target_timeline {
		sync.cond_wait(&manager.cond, &manager.mutex)
	}
	return intrinsics.atomic_load_explicit(&manager.latest_submitted_vertex_timeline, .Seq_Cst) >=
	       target_timeline
}

vertex_manager_mark_submitted :: proc(manager: ^Ez_Gfx_Vertex_Manager, timeline: u64) {
	if manager == nil || timeline == 0 do return
	sync.mutex_lock(&manager.mutex)
	if timeline > manager.latest_submitted_vertex_timeline {
		intrinsics.atomic_store_explicit(
			&manager.latest_submitted_vertex_timeline,
			timeline,
			.Seq_Cst,
		)
	}
	sync.mutex_unlock(&manager.mutex)
	sync.cond_broadcast(&manager.cond)
}

vertex_manager_collect_completed :: proc(manager: ^Ez_Gfx_Vertex_Manager) {
	if manager == nil do return
	ctx := get_current_ctx()
	completed := gpu_heap_completed_timeline()
	sync.mutex_lock(&manager.mutex)
	staging_index := 0
	for staging_index < len(manager.pending_staging) {
		if manager.pending_staging[staging_index].retire_timeline > completed {
			staging_index += 1
			continue
		}
		job := manager.pending_staging[staging_index]
		ordered_remove(&manager.pending_staging, staging_index)
		sync.mutex_unlock(&manager.mutex)
		buffer_destroy(&job.buffer)
		if ctx != nil && ctx.device != nil && job.command_buffer != nil {
			vk.FreeCommandBuffers(ctx.device, manager.upload_command_pool, 1, &job.command_buffer)
		}
		sync.mutex_lock(&manager.mutex)
	}
	gpu_heap_collect_completed_frees(&manager.index_heap)
	for i in 0 ..< manager.vertex_heap_count {
		gpu_heap_collect_completed_frees(&manager.vertex_heaps[i].heap)
	}
	sync.mutex_unlock(&manager.mutex)
}

vertex_manager_record_graphics_handoffs :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	ctx: ^Ez_Gfx_Ctx,
	command_buffer: vk.CommandBuffer,
	up_to_timeline: u64,
) {
	if manager == nil || ctx == nil || command_buffer == nil do return
	sync.mutex_lock(&manager.mutex)
	i := 0
	for i < len(manager.pending_graphics_handoffs) {
		handoff := manager.pending_graphics_handoffs[i]
		if handoff.transfer_timeline > up_to_timeline {
			i += 1
			continue
		}
		ordered_remove(&manager.pending_graphics_handoffs, i)
		sync.mutex_unlock(&manager.mutex)
		if ctx.transfer_queue_family_index != ctx.queue_family_index {
			vertex_buffer_barrier_queue_family(
				command_buffer,
				handoff.buffer,
				handoff.offset,
				handoff.size,
				{},
				{.INDEX_READ, .SHADER_STORAGE_READ},
				{.ALL_COMMANDS},
				{.INDEX_INPUT, .VERTEX_SHADER, .FRAGMENT_SHADER},
				ctx.transfer_queue_family_index,
				ctx.queue_family_index,
			)
		}
		sync.mutex_lock(&manager.mutex)
	}
	sync.mutex_unlock(&manager.mutex)
}

vertex_buffer_barrier_queue_family :: proc(
	command_buffer: vk.CommandBuffer,
	buffer: vk.Buffer,
	offset, size: vk.DeviceSize,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_queue_family_index, dst_queue_family_index: u32,
) {
	barrier := vk.BufferMemoryBarrier2 {
		sType = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		srcQueueFamilyIndex = src_queue_family_index,
		dstQueueFamilyIndex = dst_queue_family_index,
		buffer = buffer,
		offset = offset,
		size = size,
	}
	dependency := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers = &barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &dependency)
}

vertex_manager_free_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> bool {
	heap := vertex_manager_find_heap(manager, heap_name)
	if heap == nil {
		fmt.eprintf("missing vertex heap: %v\n", heap_name)
		return false
	}
	return gpu_heap_free_allocation(heap, allocation)
}

vertex_manager_find_heap :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
) -> ^Ez_Gfx_Gpu_Heap {
	for i in 0 ..< manager.vertex_heap_count {
		vertex_heap := &manager.vertex_heaps[i]
		if heap_name_equals_string(vertex_heap.name[:], vertex_heap.name_len, heap_name) {
			return &vertex_heap.heap
		}
	}
	return nil
}

vertex_manager_find_heap_by_stored_name :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	name: []byte,
	name_len: int,
) -> ^Ez_Gfx_Gpu_Heap {
	for i in 0 ..< manager.vertex_heap_count {
		vertex_heap := &manager.vertex_heaps[i]
		if heap_name_equals_bytes(
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

copy_heap_name :: proc(
	dst: ^[EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	dst_len: ^int,
	name: string,
) {
	if len(name) > EZ_GFX_VERTEX_HEAP_NAME_MAX {
		fmt.eprintf("vertex heap name is too long: %v\n", name)
		panic("vertex heap name is too long")
	}

	for i in 0 ..< EZ_GFX_VERTEX_HEAP_NAME_MAX {
		dst[i] = 0
	}
	for i in 0 ..< len(name) {
		dst[i] = name[i]
	}
	dst_len^ = len(name)
}

heap_name_equals_string :: proc(name: []byte, name_len: int, other: string) -> bool {
	if name_len != len(other) do return false
	for i in 0 ..< len(other) {
		if name[i] != other[i] do return false
	}
	return true
}

heap_name_equals_bytes :: proc(a: []byte, a_len: int, b: []byte, b_len: int) -> bool {
	if a_len != b_len do return false
	for i in 0 ..< a_len {
		if a[i] != b[i] do return false
	}
	return true
}
