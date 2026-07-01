package tests

import gfx "../src"
import "core:testing"
import vk "vendor:vulkan"

vertex_allocator_test_heap :: proc(capacity, stride: vk.DeviceSize) -> gfx.Ez_Gfx_Gpu_Heap {
	heap: gfx.Ez_Gfx_Gpu_Heap
	heap.capacity = capacity
	heap.stride = stride
	heap.free_chunks = make([dynamic]gfx.Ez_Gfx_Heap_Chunk)
	heap.pending_free_chunks = make([dynamic]gfx.Ez_Gfx_Pending_Free_Chunk)
	return heap
}

vertex_allocator_delete_test_heap :: proc(heap: ^gfx.Ez_Gfx_Gpu_Heap) {
	delete(heap.free_chunks)
	delete(heap.pending_free_chunks)
	heap^ = {}
}

@(test)
vertex_allocator_reuses_first_fitting_chunk_and_splits_remainder :: proc(t: ^testing.T) {
	heap := vertex_allocator_test_heap(64, 4)
	defer vertex_allocator_delete_test_heap(&heap)

	first, first_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 16)
	second, second_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 8)
	testing.expect(t, first_ok)
	testing.expect(t, second_ok)
	testing.expect_value(t, first, vk.DeviceSize(0))
	testing.expect_value(t, second, vk.DeviceSize(16))

	freed := gfx.ez_gfx_gpu_heap_free_allocation(
		&heap,
		gfx.Ez_Gfx_Vertex_Allocation{start_index = 0, count = 4},
	)
	testing.expect(t, freed)

	reused, reused_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 8)
	testing.expect(t, reused_ok)
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

	_, a_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 8)
	_, b_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 8)
	_, c_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 8)
	testing.expect(t, a_ok)
	testing.expect(t, b_ok)
	testing.expect(t, c_ok)

	testing.expect(
		t,
		gfx.ez_gfx_gpu_heap_free_allocation(
			&heap,
			gfx.Ez_Gfx_Vertex_Allocation{start_index = 2, count = 2},
		),
	)
	testing.expect(
		t,
		gfx.ez_gfx_gpu_heap_free_allocation(
			&heap,
			gfx.Ez_Gfx_Vertex_Allocation{start_index = 0, count = 2},
		),
	)
	testing.expect(
		t,
		gfx.ez_gfx_gpu_heap_free_allocation(
			&heap,
			gfx.Ez_Gfx_Vertex_Allocation{start_index = 4, count = 2},
		),
	)

	testing.expect_value(t, len(heap.free_chunks), 1)
	testing.expect_value(t, heap.free_chunks[0].offset, vk.DeviceSize(0))
	testing.expect_value(t, heap.free_chunks[0].size, vk.DeviceSize(24))
}

@(test)
vertex_allocator_recovers_capacity_after_free :: proc(t: ^testing.T) {
	heap := vertex_allocator_test_heap(16, 4)
	defer vertex_allocator_delete_test_heap(&heap)

	full_offset, full_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 16)
	overflow_offset, overflow_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 4)
	testing.expect(t, full_ok)
	testing.expect_value(t, full_offset, vk.DeviceSize(0))
	testing.expect(t, !overflow_ok)
	testing.expect_value(t, overflow_offset, vk.DeviceSize(0))

	testing.expect(
		t,
		gfx.ez_gfx_gpu_heap_free_allocation(
			&heap,
			gfx.Ez_Gfx_Vertex_Allocation{start_index = 0, count = 4},
		),
	)
	reused, reused_ok := gfx.ez_gfx_gpu_heap_allocate_range(&heap, 8)
	testing.expect(t, reused_ok)
	testing.expect_value(t, reused, vk.DeviceSize(0))
	testing.expect_value(t, heap.high_water, vk.DeviceSize(16))
}
