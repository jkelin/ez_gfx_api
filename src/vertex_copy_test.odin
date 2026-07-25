#+test
#+private
package ez_gfx

import "core:testing"

@(test)
vertex_copy_tightly_packed_uses_single_copy :: proc(t: ^testing.T) {
	source := [6]u32{1, 2, 3, 4, 5, 6}
	destination: [6]u32

	status := api_vertex_copy_strided(
		&destination[0],
		size_of(u32),
		&source[0],
		size_of(u32),
		size_of(u32),
		len(source),
	)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	for value, i in source {
		testing.expect_value(t, destination[i], value)
	}
}

@(test)
vertex_copy_gathers_positions_from_interleaved_source :: proc(t: ^testing.T) {
	// Interleaved vertex layout: position float3 followed by normal float3,
	// mirroring a glTF buffer view with a 24-byte stride.
	Interleaved_Vertex :: struct {
		position: [3]f32,
		normal:   [3]f32,
	}
	source := [3]Interleaved_Vertex {
		{position = {1, 2, 3}, normal = {0, 1, 0}},
		{position = {4, 5, 6}, normal = {0, 1, 0}},
		{position = {7, 8, 9}, normal = {0, 1, 0}},
	}
	destination: [3][3]f32

	status := api_vertex_copy_strided(
		&destination[0],
		size_of([3]f32),
		&source[0],
		size_of(Interleaved_Vertex),
		size_of([3]f32),
		len(source),
	)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	for vertex, i in source {
		testing.expect_value(t, destination[i], vertex.position)
	}
}

@(test)
vertex_copy_scatter_leaves_destination_padding_untouched :: proc(t: ^testing.T) {
	// float3 payloads expanded into float4 slots: the fourth lane must keep
	// whatever the destination already contained (the vertex manager zero-fills
	// staging memory before scattering).
	source := [2][3]f32{{1, 2, 3}, {4, 5, 6}}
	destination := [2][4]f32{{9, 9, 9, 42}, {9, 9, 9, 43}}

	status := api_vertex_copy_strided(
		&destination[0],
		size_of([4]f32),
		&source[0],
		size_of([3]f32),
		size_of([3]f32),
		len(source),
	)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, destination[0], [4]f32{1, 2, 3, 42})
	testing.expect_value(t, destination[1], [4]f32{4, 5, 6, 43})
}

@(test)
vertex_copy_moves_full_float4_elements_between_strided_layouts :: proc(t: ^testing.T) {
	Padded_Source :: struct {
		value: [4]f32,
		extra: u64,
	}
	source := [2]Padded_Source {
		{value = {1, 2, 3, 4}, extra = 111},
		{value = {5, 6, 7, 8}, extra = 222},
	}
	Padded_Destination :: struct {
		value: [4]f32,
		tag:   u32,
		_pad:  [3]u32,
	}
	destination := [2]Padded_Destination {
		{tag = 7},
		{tag = 8},
	}

	status := api_vertex_copy_strided(
		&destination[0],
		size_of(Padded_Destination),
		&source[0],
		size_of(Padded_Source),
		size_of([4]f32),
		len(source),
	)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, destination[0].value, [4]f32{1, 2, 3, 4})
	testing.expect_value(t, destination[1].value, [4]f32{5, 6, 7, 8})
	testing.expect_value(t, destination[0].tag, u32(7))
	testing.expect_value(t, destination[1].tag, u32(8))
}

@(test)
vertex_copy_gathers_strided_u32_indices :: proc(t: ^testing.T) {
	// u32 indices with an 8-byte stride, as produced by a glTF buffer view that
	// interleaves index data with other content.
	source: [4][2]u32
	for i in 0 ..< 4 {
		source[i][0] = u32(i + 1)
		source[i][1] = u32(0x1111 + i)
	}
	destination: [4]u32

	status := api_vertex_copy_strided(
		&destination[0],
		size_of(u32),
		&source[0],
		size_of([2]u32),
		size_of(u32),
		len(source),
	)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	testing.expect_value(t, destination, [4]u32{1, 2, 3, 4})
}

@(test)
vertex_copy_handles_generic_element_sizes :: proc(t: ^testing.T) {
	// 6-byte payloads exercise the generic per-element fallback path.
	source: [3][8]u8
	for i in 0 ..< 3 {
		for j in 0 ..< 8 {
			source[i][j] = u8(i * 10 + j + 1)
		}
	}
	destination: [3][6]u8

	status := api_vertex_copy_strided(
		&destination[0],
		6,
		&source[0],
		8,
		6,
		3,
	)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	for i in 0 ..< 3 {
		for j in 0 ..< 6 {
			testing.expect_value(t, destination[i][j], u8(i * 10 + j + 1))
		}
	}
}

@(test)
vertex_copy_handles_unaligned_simd_payloads :: proc(t: ^testing.T) {
	// 16-byte payloads at offsets that are not 16-byte aligned must still copy
	// correctly because the implementation uses unaligned SIMD loads/stores.
	source_backing: [64]u8
	destination_backing: [64]u8
	for i in 0 ..< 64 {
		source_backing[i] = u8(i)
	}

	// Start one byte in so neither pointer is aligned to the payload size.
	status := api_vertex_copy_strided(
		&destination_backing[1],
		20,
		&source_backing[1],
		18,
		16,
		2,
	)

	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	for i in 0 ..< 16 {
		testing.expect_value(t, destination_backing[1 + i], source_backing[1 + i])
	}
	for i in 0 ..< 16 {
		testing.expect_value(t, destination_backing[21 + i], source_backing[19 + i])
	}
}

@(test)
vertex_copy_rejects_invalid_arguments :: proc(t: ^testing.T) {
	source := [2]u32{1, 2}
	destination: [2]u32

	invalid_statuses := [?]Ez_Gfx_Status {
		api_vertex_copy_strided(&destination[0], 2, &source[0], 4, 4, 2),
		api_vertex_copy_strided(&destination[0], 4, &source[0], 2, 4, 2),
		api_vertex_copy_strided(&destination[0], 4, &source[0], 4, 0, 2),
		api_vertex_copy_strided(&destination[0], 4, &source[0], 4, 4, -1),
		api_vertex_copy_strided(nil, 4, &source[0], 4, 4, 2),
		api_vertex_copy_strided(&destination[0], 4, nil, 4, 4, 2),
		api_vertex_copy_strided(&destination[0], max(int), &source[0], max(int), 4, 2),
	}
	for status in invalid_statuses {
		testing.expect_value(t, status, Ez_Gfx_Status.Invalid_Argument)
	}
	// A zero-element copy is a no-op and intentionally permits nil pointers.
	testing.expect_value(
		t,
		api_vertex_copy_strided(nil, 4, nil, 4, 4, 0),
		Ez_Gfx_Status.Ok,
	)
}
