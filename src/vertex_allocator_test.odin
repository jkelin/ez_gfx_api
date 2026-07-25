#+test
#+private
package ez_gfx

import "core:testing"
import vk "vendor:vulkan"

vertex_allocator_test_heap :: proc(capacity, stride: vk.DeviceSize) -> Ez_Gfx_Gpu_Heap {
	heap: Ez_Gfx_Gpu_Heap
	heap.capacity = capacity
	heap.stride = stride
	heap.free_chunks = make([dynamic]Ez_Gfx_Heap_Chunk)
	heap.pending_free_chunks = make([dynamic]Ez_Gfx_Pending_Free_Chunk)
	return heap
}

vertex_allocator_delete_test_heap :: proc(heap: ^Ez_Gfx_Gpu_Heap) {
	delete(heap.free_chunks)
	delete(heap.pending_free_chunks)
	heap^ = {}
}

@(test)
vertex_allocator_reuses_first_fitting_chunk_and_splits_remainder :: proc(t: ^testing.T) {
	heap := vertex_allocator_test_heap(64, 4)
	defer vertex_allocator_delete_test_heap(&heap)

	first, first_status := api_gpu_heap_allocate_range(&heap, 16)
	second, second_status := api_gpu_heap_allocate_range(&heap, 8)
	testing.expect_value(t, first_status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, second_status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, first, vk.DeviceSize(0))
	testing.expect_value(t, second, vk.DeviceSize(16))

	freed_status := api_gpu_heap_free_allocation(
		&heap,
		Ez_Gfx_Vertex_Allocation{start_index = 0, count = 4},
	)
	testing.expect_value(t, freed_status, Ez_Gfx_Status.Ok)

	reused, reused_status := api_gpu_heap_allocate_range(&heap, 8)
	testing.expect_value(t, reused_status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, reused, vk.DeviceSize(0))
	testing.expect_value(t, len(heap.free_chunks), 1)
	testing.expect_value(t, heap.free_chunks[0].offset, vk.DeviceSize(8))
	testing.expect_value(t, heap.free_chunks[0].size, vk.DeviceSize(8))
	testing.expect_value(t, heap.high_water, vk.DeviceSize(24))
}

@(test)
vertex_allocator_merges_adjacent_free_chunks :: proc(t: ^testing.T) {
	heap := vertex_allocator_test_heap(64, 4)
	defer vertex_allocator_delete_test_heap(&heap)

	_, a_status := api_gpu_heap_allocate_range(&heap, 8)
	_, b_status := api_gpu_heap_allocate_range(&heap, 8)
	_, c_status := api_gpu_heap_allocate_range(&heap, 8)
	testing.expect_value(t, a_status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, b_status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, c_status, Ez_Gfx_Status.Ok)

	allocations := [?]Ez_Gfx_Vertex_Allocation {
		Ez_Gfx_Vertex_Allocation{start_index = 2, count = 2},
		Ez_Gfx_Vertex_Allocation{start_index = 0, count = 2},
		Ez_Gfx_Vertex_Allocation{start_index = 4, count = 2},
	}
	for allocation in allocations {
		testing.expect_value(
			t,
			api_gpu_heap_free_allocation(&heap, allocation),
			Ez_Gfx_Status.Ok,
		)
	}

	testing.expect_value(t, len(heap.free_chunks), 1)
	testing.expect_value(t, heap.free_chunks[0].offset, vk.DeviceSize(0))
	testing.expect_value(t, heap.free_chunks[0].size, vk.DeviceSize(24))
}

@(test)
vertex_allocator_recovers_capacity_after_free :: proc(t: ^testing.T) {
	heap := vertex_allocator_test_heap(16, 4)
	defer vertex_allocator_delete_test_heap(&heap)

	full_offset, full_status := api_gpu_heap_allocate_range(&heap, 16)
	overflow_offset, overflow_status := api_gpu_heap_allocate_range(&heap, 4)
	testing.expect_value(t, full_status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, full_offset, vk.DeviceSize(0))
	testing.expect_value(t, overflow_status, Ez_Gfx_Status.Native_Failure)
	testing.expect_value(t, overflow_offset, vk.DeviceSize(0))

	testing.expect_value(
		t,
		api_gpu_heap_free_allocation(
			&heap,
			Ez_Gfx_Vertex_Allocation{start_index = 0, count = 4},
		),
		Ez_Gfx_Status.Ok,
	)
	reused, reused_status := api_gpu_heap_allocate_range(&heap, 8)
	testing.expect_value(t, reused_status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, reused, vk.DeviceSize(0))
	testing.expect_value(t, heap.high_water, vk.DeviceSize(16))
}

@(test)
vertex_allocator_reserves_range_without_cpu_upload :: proc(t: ^testing.T) {
	heap := vertex_allocator_test_heap(64, 4)
	defer vertex_allocator_delete_test_heap(&heap)

	allocation, offset, status := api_gpu_heap_reserve_allocation(&heap, 12, 3)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, offset, vk.DeviceSize(0))
	testing.expect_value(t, allocation.start_index, u32(0))
	testing.expect_value(t, allocation.count, u32(3))
	testing.expect_value(t, heap.high_water, vk.DeviceSize(12))
	testing.expect_value(t, heap.used_bytes, vk.DeviceSize(12))
	_, _, inconsistent_status := api_gpu_heap_reserve_allocation(&heap, 12, 1)
	testing.expect_value(t, inconsistent_status, Ez_Gfx_Status.Invalid_Argument)
	testing.expect_value(t, heap.high_water, vk.DeviceSize(12))
}
