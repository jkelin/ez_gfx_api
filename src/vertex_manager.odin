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

Ez_Gfx_Vertex_Upload_Kind :: enum u8 {
	Indices,
	Vertices,
}

Ez_Gfx_Vertex_Upload_Error :: enum u8 {
	None,
	Invalid_Context,
	Invalid_Arguments,
	Out_Of_Memory,
	Vulkan_Failed,
	Worker_Unavailable,
	Missing_Heap,
}

Ez_Gfx_Vertex_Uploaded_Callback :: #type proc(
	ctx: ^Ez_Gfx_Ctx,
	kind: Ez_Gfx_Vertex_Upload_Kind,
	heap_name: string,
	allocation: Ez_Gfx_Vertex_Allocation,
	err: Ez_Gfx_Vertex_Upload_Error,
	user_data: rawptr,
)

Ez_Gfx_Gpu_Heap :: struct {
	buffer:              Ez_Gfx_Buffer,
	capacity:            vk.DeviceSize,
	stride:              vk.DeviceSize,
	high_water:          vk.DeviceSize,
	used_bytes:          vk.DeviceSize,
	free_chunks:         [dynamic]Ez_Gfx_Heap_Chunk,
	pending_free_chunks: [dynamic]Ez_Gfx_Pending_Free_Chunk,
}

Ez_Gfx_Vertex_Upload_Job :: struct {
	kind:             Ez_Gfx_Vertex_Upload_Kind,
	heap:             ^Ez_Gfx_Gpu_Heap,
	heap_name:        [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	heap_name_len:    int,
	allocation:       Ez_Gfx_Vertex_Allocation,
	offset:           vk.DeviceSize,
	byte_size:        vk.DeviceSize,
	source_bytes:     []u8,
	source_allocator: mem.Allocator,
	transfer_timeline: u64,
}

Ez_Gfx_Vertex_Staging_Retire_Job :: struct {
	buffer:          Ez_Gfx_Buffer,
	command_buffer:  vk.CommandBuffer,
	retire_timeline: u64,
}

Ez_Gfx_Vertex_Graphics_Handoff_Job :: struct {
	buffer:            vk.Buffer,
	offset:            vk.DeviceSize,
	size:              vk.DeviceSize,
	transfer_timeline: u64,
}

Ez_Gfx_Named_Vertex_Heap :: struct {
	name:     [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	name_len: int,
	heap:     Ez_Gfx_Gpu_Heap,
}

Ez_Gfx_Vertex_Manager :: struct {
	index_heap:                      Ez_Gfx_Gpu_Heap,
	vertex_heaps:                    [EZ_GFX_MAX_VERTEX_HEAPS]Ez_Gfx_Named_Vertex_Heap,
	vertex_heap_count:               int,
	upload_command_pool:             vk.CommandPool,
	worker:                          ^thread.Thread,
	mutex:                           sync.Mutex,
	cond:                            sync.Cond,
	jobs:                            [dynamic]Ez_Gfx_Vertex_Upload_Job,
	pending_staging:                 [dynamic]Ez_Gfx_Vertex_Staging_Retire_Job,
	pending_graphics_handoffs:       [dynamic]Ez_Gfx_Vertex_Graphics_Handoff_Job,
	shutdown:                        bool,
	latest_scheduled_vertex_timeline: u64,
	latest_submitted_vertex_timeline: u64,
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
		usage | {.TRANSFER_DST},
		{.DEVICE_LOCAL},
		debug_name,
		0.7,
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
	fmt.eprintln("ez_gfx_gpu_heap_upload_allocation is not supported for device-local async heaps; use Ez_Gfx_Vertex_Manager upload APIs")
	return allocation, false
}

ez_gfx_gpu_heap_reserve_allocation :: proc(
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
	offset, alloc_ok = ez_gfx_gpu_heap_allocate_range(heap, byte_size)
	if !alloc_ok {
		fmt.eprintln("GPU heap upload exceeds heap capacity")
		return allocation, 0, false
	}

	allocation.start_index = u32(offset / heap.stride)
	allocation.count = element_count
	return allocation, offset, true
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
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	manager^ = {}
	manager.jobs = make([dynamic]Ez_Gfx_Vertex_Upload_Job)
	manager.pending_staging = make([dynamic]Ez_Gfx_Vertex_Staging_Retire_Job)
	manager.pending_graphics_handoffs = make([dynamic]Ez_Gfx_Vertex_Graphics_Handoff_Job)

	if !ez_gfx_vertex_manager_create_upload_commands(manager, ctx) {
		ez_gfx_vertex_manager_destroy(manager)
		return false
	}
	if !ez_gfx_gpu_heap_create(
		&manager.index_heap,
		EZ_GFX_DEFAULT_INDEX_HEAP_BYTES,
		vk.DeviceSize(size_of(u32)),
		{.INDEX_BUFFER},
		"ez_gfx index heap",
	) {
		ez_gfx_vertex_manager_destroy(manager)
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

	manager.worker = thread.create(ez_gfx_vertex_upload_thread)
	if manager.worker == nil {
		fmt.eprintln("failed to create vertex upload thread")
		ez_gfx_vertex_manager_destroy(manager)
		return false
	}
	manager.worker.data = manager
	thread.start(manager.worker)
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
	ctx := ez_gfx_get_current_ctx()
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
		ez_gfx_vertex_upload_job_release_source(&manager.jobs[i])
	}
	if raw_data(manager.jobs) != nil do delete(manager.jobs)
	for i in 0 ..< len(manager.pending_staging) {
		ez_gfx_buffer_destroy(&manager.pending_staging[i].buffer)
	}
	if raw_data(manager.pending_staging) != nil do delete(manager.pending_staging)
	if raw_data(manager.pending_graphics_handoffs) != nil do delete(manager.pending_graphics_handoffs)

	for i in 0 ..< manager.vertex_heap_count {
		ez_gfx_gpu_heap_destroy(&manager.vertex_heaps[i].heap)
		manager.vertex_heaps[i].name_len = 0
	}
	manager.vertex_heap_count = 0
	ez_gfx_gpu_heap_destroy(&manager.index_heap)
	if ctx != nil && ctx.device != nil && manager.upload_command_pool != vk.CommandPool(0) {
		vk.DestroyCommandPool(ctx.device, manager.upload_command_pool, nil)
	}
	manager^ = {}
}

ez_gfx_vertex_manager_create_upload_commands :: proc(
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

ez_gfx_vertex_manager_upload_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
) -> (
	start_index: u32,
	ok: bool,
) {
	allocation, alloc_ok := ez_gfx_vertex_manager_alloc_indices(manager, indices)
	return allocation.start_index, alloc_ok
}

ez_gfx_vertex_manager_alloc_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	return ez_gfx_vertex_manager_schedule_upload(
		manager,
		.Indices,
		"",
		&manager.index_heap,
		raw_data(indices),
		vk.DeviceSize(len(indices) * size_of(u32)),
		u32(len(indices)),
		vk.DeviceSize(size_of(u32)),
	)
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
	allocation, alloc_ok := ez_gfx_vertex_manager_schedule_upload(
		manager,
		.Vertices,
		heap_name,
		heap,
		raw_data(vertices),
		vk.DeviceSize(len(vertices) * size_of(T)),
		u32(len(vertices)),
		vk.DeviceSize(size_of(T)),
	)
	return allocation.start_index, alloc_ok
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
	return ez_gfx_vertex_manager_schedule_upload(
		manager,
		.Vertices,
		heap_name,
		heap,
		raw_data(vertices),
		vk.DeviceSize(len(vertices) * size_of(T)),
		u32(len(vertices)),
		vk.DeviceSize(size_of(T)),
	)
}

// Schedules a transfer-queue upload and copies caller data so async workers never
// observe stack memory after the upload API returns.
ez_gfx_vertex_manager_schedule_upload :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	kind: Ez_Gfx_Vertex_Upload_Kind,
	heap_name: string,
	heap: ^Ez_Gfx_Gpu_Heap,
	source: rawptr,
	byte_size: vk.DeviceSize,
	element_count: u32,
	element_size: vk.DeviceSize,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	ok: bool,
) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil || manager == nil || heap == nil do return allocation, false
	if manager.worker == nil do return allocation, false
	if heap.stride == 0 || element_size != heap.stride {
		fmt.eprintln("heap upload element size does not match heap stride")
		return allocation, false
	}

	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	offset: vk.DeviceSize
	allocation, offset, ok = ez_gfx_gpu_heap_reserve_allocation(heap, byte_size, element_count)
	if !ok do return allocation, false
	if byte_size == 0 do return allocation, true

	source_bytes, alloc_err := make([]u8, int(byte_size))
	if alloc_err != nil {
		_ = ez_gfx_gpu_heap_free_chunk(heap, Ez_Gfx_Heap_Chunk{offset = offset, size = byte_size})
		return allocation, false
	}
	mem.copy(raw_data(source_bytes), source, int(byte_size))

	timeline := ez_gfx_ctx_next_timeline_value(ctx)
	job := Ez_Gfx_Vertex_Upload_Job {
		kind = kind,
		heap = heap,
		allocation = allocation,
		offset = offset,
		byte_size = byte_size,
		source_bytes = source_bytes,
		source_allocator = context.allocator,
		transfer_timeline = timeline,
	}
	if kind == .Vertices {
		if !ez_gfx_copy_heap_name(&job.heap_name, &job.heap_name_len, heap_name) {
			ez_gfx_vertex_upload_job_release_source(&job)
			_ = ez_gfx_gpu_heap_free_chunk(heap, Ez_Gfx_Heap_Chunk{offset = offset, size = byte_size})
			return allocation, false
		}
	}
	append(&manager.jobs, job)
	intrinsics.atomic_store_explicit(&manager.latest_scheduled_vertex_timeline, timeline, .Seq_Cst)
	sync.cond_signal(&manager.cond)
	return allocation, true
}

ez_gfx_vertex_upload_thread :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	manager := cast(^Ez_Gfx_Vertex_Manager)worker.data
	if manager == nil do return
	ctx := ez_gfx_vertex_manager_find_owner(manager)
	if ctx == nil do return
	ez_gfx_set_current_ctx(ctx)

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
		err := ez_gfx_vertex_upload_job(manager, ctx, &job)
		ez_gfx_vertex_finish_job(manager, ctx, &job, err)
	}
}

ez_gfx_vertex_manager_find_owner :: proc(manager: ^Ez_Gfx_Vertex_Manager) -> ^Ez_Gfx_Ctx {
	return cast(^Ez_Gfx_Ctx)(uintptr(manager) - offset_of(Ez_Gfx_Ctx, vertex_manager))
}

ez_gfx_vertex_upload_job :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	ctx: ^Ez_Gfx_Ctx,
	job: ^Ez_Gfx_Vertex_Upload_Job,
) -> Ez_Gfx_Vertex_Upload_Error {
	if job.byte_size == 0 do return .None
	staging, staging_ok := ez_gfx_buffer_create(
		job.byte_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
		"ez_gfx vertex staging buffer",
		0.2,
	)
	if !staging_ok do return .Vulkan_Failed

	if !ez_gfx_buffer_write(&staging, job.source_bytes) {
		ez_gfx_buffer_destroy(&staging)
		return .Vulkan_Failed
	}

	command_buffer: vk.CommandBuffer
	upload_ok: bool
	command_buffer, upload_ok = ez_gfx_vertex_submit_upload(manager, ctx, job, &staging)
	if !upload_ok {
		ez_gfx_buffer_destroy(&staging)
		return .Vulkan_Failed
	}

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

ez_gfx_vertex_submit_upload :: proc(
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
		ez_gfx_vertex_buffer_barrier_queue_family(
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
	if job.transfer_timeline > 1 && !ez_gfx_ctx_wait_timeline(ctx, job.transfer_timeline - 1) {
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
	ez_gfx_vertex_manager_mark_submitted(manager, job.transfer_timeline)
	return command_buffer, true
}

ez_gfx_vertex_finish_job :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	ctx: ^Ez_Gfx_Ctx,
	job: ^Ez_Gfx_Vertex_Upload_Job,
	err: Ez_Gfx_Vertex_Upload_Error,
) {
	if err != .None {
		_ = ez_gfx_gpu_heap_free_allocation(job.heap, job.allocation)
		if ez_gfx_texture_signal_timeline(ctx, job.transfer_timeline) {
			ez_gfx_vertex_manager_mark_submitted(manager, job.transfer_timeline)
		}
	}
	if ctx.vertex_uploaded_callback != nil {
		heap_name := string(job.heap_name[:job.heap_name_len])
		ctx.vertex_uploaded_callback(
			ctx,
			job.kind,
			heap_name,
			job.allocation,
			err,
			ctx.vertex_uploaded_user_data,
		)
	}
	ez_gfx_vertex_upload_job_release_source(job)
}

ez_gfx_vertex_upload_job_release_source :: proc(job: ^Ez_Gfx_Vertex_Upload_Job) {
	if raw_data(job.source_bytes) == nil do return
	delete(job.source_bytes, job.source_allocator)
	job.source_bytes = nil
	job.source_allocator = {}
}

ez_gfx_vertex_manager_latest_scheduled_timeline :: proc(manager: ^Ez_Gfx_Vertex_Manager) -> u64 {
	if manager == nil do return 0
	return intrinsics.atomic_load_explicit(&manager.latest_scheduled_vertex_timeline, .Seq_Cst)
}

ez_gfx_vertex_manager_wait_submitted_timeline :: proc(
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

ez_gfx_vertex_manager_mark_submitted :: proc(manager: ^Ez_Gfx_Vertex_Manager, timeline: u64) {
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

ez_gfx_vertex_manager_collect_completed :: proc(manager: ^Ez_Gfx_Vertex_Manager) {
	if manager == nil do return
	ctx := ez_gfx_get_current_ctx()
	completed := ez_gfx_gpu_heap_completed_timeline()
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
		ez_gfx_buffer_destroy(&job.buffer)
		if ctx != nil && ctx.device != nil && job.command_buffer != nil {
			vk.FreeCommandBuffers(ctx.device, manager.upload_command_pool, 1, &job.command_buffer)
		}
		sync.mutex_lock(&manager.mutex)
	}
	ez_gfx_gpu_heap_collect_completed_frees(&manager.index_heap)
	for i in 0 ..< manager.vertex_heap_count {
		ez_gfx_gpu_heap_collect_completed_frees(&manager.vertex_heaps[i].heap)
	}
	sync.mutex_unlock(&manager.mutex)
}

ez_gfx_vertex_manager_record_graphics_handoffs :: proc(
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
			ez_gfx_vertex_buffer_barrier_queue_family(
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

ez_gfx_vertex_buffer_barrier_queue_family :: proc(
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
