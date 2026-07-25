#+private
package ez_gfx

import vma "../vendor/odin-vma"
import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"



buffer_create :: proc(
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
	debug_name: cstring = nil,
	memory_priority: f32 = 0.5,
	persistently_mapped: bool = false,
) -> (
	buffer: Ez_Gfx_Buffer,
	ok: bool,
) {
	ctx := get_current_ctx()
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
	} else if persistently_mapped {
		alloc_info.flags |= {.Mapped}
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
		debug_set_object_name(ctx, .BUFFER, debug_handle(buffer.handle), debug_name)
		vma.set_allocation_name(ctx.vma_allocator, buffer.allocation, debug_name)
		debug_set_object_name(
			ctx,
			.DEVICE_MEMORY,
			debug_handle(buffer.allocation_info.device_memory),
			debug_name,
		)
	}

	buffer.size = size
	buffer.mapped_data = buffer.allocation_info.mapped_data
	return buffer, true
}

buffer_create_mapped :: proc(
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	debug_name: cstring = nil,
	memory_priority: f32 = 0.4,
) -> (
	buffer: Ez_Gfx_Buffer,
	mapped: rawptr,
	ok: bool,
) {
	ctx := get_current_ctx()
	if ctx == nil do return buffer, nil, false
	if ctx.vma_allocator == vma.Allocator(nil) {
		fmt.eprintln("Vulkan memory allocator is not initialized")
		return buffer, nil, false
	}
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	alloc_info := vma.Allocation_Create_Info {
		flags          = {.Mapped, .Host_Access_Random},
		usage          = .Auto_Prefer_Host,
		required_flags = {.HOST_VISIBLE, .HOST_COHERENT},
		priority       = memory_priority,
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
		fmt.eprintln("failed to create persistently mapped buffer")
		return buffer, nil, false
	}
	if buffer.allocation_info.mapped_data == nil {
		fmt.eprintln("persistently mapped buffer did not return a CPU pointer")
		buffer_destroy(&buffer)
		return buffer, nil, false
	}
	if debug_name != nil {
		debug_set_object_name(ctx, .BUFFER, debug_handle(buffer.handle), debug_name)
		vma.set_allocation_name(ctx.vma_allocator, buffer.allocation, debug_name)
		debug_set_object_name(
			ctx,
			.DEVICE_MEMORY,
			debug_handle(buffer.allocation_info.device_memory),
			debug_name,
		)
	}

	buffer.size = size
	return buffer, buffer.allocation_info.mapped_data, true
}

// Maps host-visible memory and copies slice data into the buffer.
buffer_write :: proc(buffer: ^Ez_Gfx_Buffer, data: []$T) -> bool {
	return buffer_write_at(buffer, 0, data)
}

// Maps host-visible memory and copies slice data into a byte range of the buffer.
buffer_write_at :: proc(buffer: ^Ez_Gfx_Buffer, offset: vk.DeviceSize, data: []$T) -> bool {
	ctx := get_current_ctx()
	if ctx == nil do return false
	byte_size := len(data) * size_of(T)
	if offset + vk.DeviceSize(byte_size) > buffer.size {
		fmt.eprintln("buffer write exceeds allocation size")
		return false
	}

	if buffer.mapped_data != nil {
		mapped_bytes := ([^]u8)(buffer.mapped_data)
		mem.copy(&mapped_bytes[int(offset)], raw_data(data), byte_size)
		return true
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
buffer_read_at :: proc(buffer: ^Ez_Gfx_Buffer, offset: vk.DeviceSize, dst: []u8) -> bool {
	ctx := get_current_ctx()
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

buffer_destroy :: proc(buffer: ^Ez_Gfx_Buffer) {
	ctx := get_current_ctx()
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
	buffer.mapped_data = nil
}
