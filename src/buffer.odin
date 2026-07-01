package ez_gfx

import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"

Ez_Gfx_Buffer :: struct {
	handle: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
}

ez_gfx_find_memory_type :: proc(
	physical_device: vk.PhysicalDevice,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> u32 {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties)

	for i in 0 ..< mem_properties.memoryTypeCount {
		if type_filter & (1 << u32(i)) != 0 &&
		   (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
			return u32(i)
		}
	}

	fmt.eprintln("failed to find suitable memory type")
	return 0
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
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	if vk.CreateBuffer(ctx.device, &buffer_info, nil, &buffer.handle) != .SUCCESS {
		fmt.eprintln("failed to create buffer")
		return buffer, false
	}
	if debug_name != nil {
		ez_gfx_debug_set_object_name(ctx, .BUFFER, ez_gfx_debug_handle(buffer.handle), debug_name)
	}

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(ctx.device, buffer.handle, &mem_requirements)

	priority_info := vk.MemoryPriorityAllocateInfoEXT {
		sType    = .MEMORY_PRIORITY_ALLOCATE_INFO_EXT,
		priority = memory_priority,
	}
	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = ctx.memory_priority_enabled ? &priority_info : nil,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = ez_gfx_find_memory_type(
			ctx.physical_device,
			mem_requirements.memoryTypeBits,
			properties,
		),
	}
	if vk.AllocateMemory(ctx.device, &alloc_info, nil, &buffer.memory) != .SUCCESS {
		fmt.eprintln("failed to allocate buffer memory")
		ez_gfx_buffer_destroy(&buffer)
		return buffer, false
	}
	if debug_name != nil {
		ez_gfx_debug_set_object_name(
			ctx,
			.DEVICE_MEMORY,
			ez_gfx_debug_handle(buffer.memory),
			debug_name,
		)
	}

	if vk.BindBufferMemory(ctx.device, buffer.handle, buffer.memory, 0) != .SUCCESS {
		fmt.eprintln("failed to bind buffer memory")
		ez_gfx_buffer_destroy(&buffer)
		return buffer, false
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
	if vk.MapMemory(ctx.device, buffer.memory, offset, vk.DeviceSize(byte_size), {}, &mapped) !=
	   .SUCCESS {
		fmt.eprintln("failed to map buffer memory")
		return false
	}
	mem.copy(mapped, raw_data(data), byte_size)
	vk.UnmapMemory(ctx.device, buffer.memory)
	return true
}

ez_gfx_buffer_destroy :: proc(buffer: ^Ez_Gfx_Buffer) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	if ctx.device == nil do return
	if buffer.handle != vk.Buffer(0) {
		vk.DestroyBuffer(ctx.device, buffer.handle, nil)
		buffer.handle = vk.Buffer(0)
	}
	if buffer.memory != vk.DeviceMemory(0) {
		vk.FreeMemory(ctx.device, buffer.memory, nil)
		buffer.memory = vk.DeviceMemory(0)
	}
	buffer.size = 0
}
