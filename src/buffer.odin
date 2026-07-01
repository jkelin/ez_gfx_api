package ez_gfx

import vma "../vendor/odin-vma"
import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"

Ez_Gfx_Buffer :: struct {
	handle:          vk.Buffer,
	allocation:      vma.Allocation,
	allocation_info: vma.Allocation_Info,
	size:            vk.DeviceSize,
}

ez_gfx_buffer_create :: proc(
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
	debug_name: cstring = nil,
	memory_priority: f32 = 0.5,
) -> (
	buffer: Ez_Gfx_Buffer,
	ok: bool,
) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return buffer, false
	if ctx.vma_allocator == vma.Allocator(nil) {
		fmt.eprintln("Vulkan memory allocator is not initialized")
		return buffer, false
	}
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	alloc_info := vma.Allocation_Create_Info {
		flags           = {.Host_Access_Sequential_Write},
		usage           = .Auto,
		required_flags  = properties,
		preferred_flags = properties,
		priority        = memory_priority,
	}
	if (properties & {.HOST_VISIBLE}) == {} {
		alloc_info.flags = {}
	}
	result := vma.create_buffer(
		ctx.vma_allocator,
		buffer_info,
		alloc_info,
		&buffer.handle,
		&buffer.allocation,
		&buffer.allocation_info,
	)
	if result != .SUCCESS {
		fmt.eprintln("failed to create buffer")
		return buffer, false
	}
	if debug_name != nil {
		ez_gfx_debug_set_object_name(ctx, .BUFFER, ez_gfx_debug_handle(buffer.handle), debug_name)
		vma.set_allocation_name(ctx.vma_allocator, buffer.allocation, debug_name)
		ez_gfx_debug_set_object_name(
			ctx,
			.DEVICE_MEMORY,
			ez_gfx_debug_handle(buffer.allocation_info.device_memory),
			debug_name,
		)
	}

	buffer.size = size
	return buffer, true
}

// Maps host-visible memory and copies slice data into the buffer.
ez_gfx_buffer_write :: proc(buffer: ^Ez_Gfx_Buffer, data: []$T) -> bool {
	return ez_gfx_buffer_write_at(buffer, 0, data)
}

// Maps host-visible memory and copies slice data into a byte range of the buffer.
ez_gfx_buffer_write_at :: proc(buffer: ^Ez_Gfx_Buffer, offset: vk.DeviceSize, data: []$T) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	byte_size := len(data) * size_of(T)
	if offset + vk.DeviceSize(byte_size) > buffer.size {
		fmt.eprintln("buffer write exceeds allocation size")
		return false
	}

	mapped: rawptr
	if vma.map_memory(ctx.vma_allocator, buffer.allocation, &mapped) != .SUCCESS {
		fmt.eprintln("failed to map buffer memory")
		return false
	}
	defer vma.unmap_memory(ctx.vma_allocator, buffer.allocation)

	mapped_bytes := ([^]u8)(mapped)
	mem.copy(&mapped_bytes[int(offset)], raw_data(data), byte_size)
	return true
}

// Maps host-visible memory and copies a byte range from the buffer into dst.
ez_gfx_buffer_read_at :: proc(buffer: ^Ez_Gfx_Buffer, offset: vk.DeviceSize, dst: []u8) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	byte_size := vk.DeviceSize(len(dst))
	if offset + byte_size > buffer.size {
		fmt.eprintln("buffer read exceeds allocation size")
		return false
	}

	mapped: rawptr
	if vma.map_memory(ctx.vma_allocator, buffer.allocation, &mapped) != .SUCCESS {
		fmt.eprintln("failed to map buffer memory")
		return false
	}
	defer vma.unmap_memory(ctx.vma_allocator, buffer.allocation)

	mapped_bytes := ([^]u8)(mapped)
	mem.copy(raw_data(dst), &mapped_bytes[int(offset)], len(dst))
	return true
}

ez_gfx_buffer_destroy :: proc(buffer: ^Ez_Gfx_Buffer) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	if ctx.device == nil do return
	if buffer.handle != vk.Buffer(0) || buffer.allocation != vma.Allocation(nil) {
		if ctx.vma_allocator != vma.Allocator(nil) {
			vma.destroy_buffer(ctx.vma_allocator, buffer.handle, buffer.allocation)
		}
		buffer.handle = vk.Buffer(0)
		buffer.allocation = vma.Allocation(nil)
	}
	buffer.allocation_info = {}
	buffer.size = 0
}
