package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_INDIRECT_BUFFERS :: 16

Ez_Gfx_Multi_Draw_Indirect_Buffer :: struct {
	buffer:             Ez_Gfx_Buffer,
	stride:             vk.DeviceSize,
	draw_offset:        vk.DeviceSize,
	capacity:           u32,
	in_use:             bool,
	last_used_timeline: u64,
}

Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager :: struct {
	buffers: [EZ_GFX_MAX_INDIRECT_BUFFERS]Ez_Gfx_Multi_Draw_Indirect_Buffer,
	count:   int,
}

Ez_Gfx_Indirect_Buffer_Handle :: struct {
	buffer:   ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	stride:   vk.DeviceSize,
	capacity: u32,
	frame_id: u64,
	ok:       bool,
}

Ez_Gfx_Vertex_Pipeline_Descriptor :: struct {
	pipeline:           ^Ez_Gfx_Pipeline_Record,
	indirect_buffer:    ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	indirect_stride:    vk.DeviceSize,
	indirect_count:     u32,
	push_constant_size: u32,
	push_constant_data: [EZ_GFX_MAX_PUSH_CONSTANT_BYTES]byte,
	ok:                 bool,
}

ez_gfx_indirect_buffer_manager_acquire :: proc(
	manager: ^Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager,
	stride: vk.DeviceSize,
	capacity: u32,
) -> (
	buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	ok: bool,
) {
	if stride < vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)) {
		fmt.eprintln("indirect stride is smaller than DrawIndexedIndirectCommand")
		return nil, false
	}
	if stride % 4 != 0 {
		fmt.eprintln("indirect stride must be a multiple of four bytes")
		return nil, false
	}
	if capacity == 0 {
		fmt.eprintln("indirect buffer capacity must be greater than zero")
		return nil, false
	}
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return nil, false
	alignment := ctx.min_storage_buffer_offset_alignment
	if alignment == 0 do alignment = vk.DeviceSize(size_of(u32))
	draw_offset := ez_gfx_align_device_size(vk.DeviceSize(size_of(u32)), alignment)

	completed_timeline := ez_gfx_indirect_completed_timeline()
	for i in 0 ..< manager.count {
		candidate := &manager.buffers[i]
		if !candidate.in_use &&
		   candidate.last_used_timeline <= completed_timeline &&
		   candidate.stride == stride &&
		   candidate.draw_offset == draw_offset &&
		   candidate.capacity >= capacity {
			candidate.in_use = true
			ez_gfx_indirect_buffer_clear(candidate)
			return candidate, true
		}
	}

	if manager.count >= EZ_GFX_MAX_INDIRECT_BUFFERS {
		fmt.eprintln("too many indirect buffers are in use")
		return nil, false
	}

	slot := &manager.buffers[manager.count]
	manager.count += 1
	slot.stride = stride
	slot.draw_offset = draw_offset
	slot.capacity = capacity
	slot.in_use = true
	size := draw_offset + stride * vk.DeviceSize(capacity)
	created, create_ok := ez_gfx_buffer_create(
		size,
		{.INDIRECT_BUFFER, .STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
		{.HOST_VISIBLE, .HOST_COHERENT},
		"ez_gfx multi-draw indirect buffer",
		0.4,
	)
	if !create_ok {
		slot.in_use = false
		return nil, false
	}
	slot.buffer = created
	ez_gfx_indirect_buffer_clear(slot)
	return slot, true
}

ez_gfx_indirect_completed_timeline :: proc() -> u64 {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil || ctx.timeline_semaphore == vk.Semaphore(0) do return 0
	value: u64
	if vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &value) != .SUCCESS {
		return 0
	}
	return value
}

ez_gfx_indirect_buffer_clear :: proc(buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer) {
	draw_count := [?]u32{0}
	_ = ez_gfx_buffer_write_at(&buffer.buffer, 0, draw_count[:])
}

ez_gfx_indirect_buffer_manager_release_completed :: proc(
	manager: ^Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager,
) {
	completed_timeline := ez_gfx_indirect_completed_timeline()
	for i in 0 ..< manager.count {
		if manager.buffers[i].last_used_timeline <= completed_timeline {
			manager.buffers[i].in_use = false
		}
	}
}

ez_gfx_indirect_buffer_mark_submitted :: proc(
	buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	timeline_value: u64,
) {
	if buffer == nil do return
	buffer.last_used_timeline = timeline_value
	buffer.in_use = false
}

ez_gfx_indirect_buffer_manager_destroy :: proc(
	manager: ^Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager,
) {
	for i in 0 ..< manager.count {
		ez_gfx_buffer_destroy(&manager.buffers[i].buffer)
		manager.buffers[i].stride = 0
		manager.buffers[i].draw_offset = 0
		manager.buffers[i].capacity = 0
		manager.buffers[i].in_use = false
		manager.buffers[i].last_used_timeline = 0
	}
	manager.count = 0
}

ez_gfx_indirect_buffer_set_draw_count :: proc(
	handle: ^Ez_Gfx_Indirect_Buffer_Handle,
	count: u32,
) -> bool {
	if handle == nil || !handle.ok || handle.buffer == nil do return false
	if count > handle.buffer.capacity {
		fmt.eprintln("draw count exceeds indirect buffer capacity")
		return false
	}
	draw_count := [?]u32{count}
	if !ez_gfx_buffer_write_at(&handle.buffer.buffer, 0, draw_count[:]) {
		return false
	}
	return true
}

ez_gfx_indirect_buffer_write_draw :: proc(
	handle: ^Ez_Gfx_Indirect_Buffer_Handle,
	index: u32,
	command: vk.DrawIndexedIndirectCommand,
) -> bool {
	if handle == nil || !handle.ok || handle.buffer == nil do return false
	if index >= handle.buffer.capacity {
		fmt.eprintln("draw command index exceeds indirect buffer capacity")
		return false
	}
	commands := [?]vk.DrawIndexedIndirectCommand{command}
	offset := handle.buffer.draw_offset + handle.stride * vk.DeviceSize(index)
	return ez_gfx_buffer_write_at(&handle.buffer.buffer, offset, commands[:])
}

ez_gfx_indirect_buffer_write_draw_payload :: proc(
	handle: ^Ez_Gfx_Indirect_Buffer_Handle,
	index: u32,
	payload: []$T,
) -> bool {
	if handle == nil || !handle.ok || handle.buffer == nil do return false
	if index >= handle.buffer.capacity {
		fmt.eprintln("draw payload index exceeds indirect buffer capacity")
		return false
	}
	payload_bytes := vk.DeviceSize(len(payload) * size_of(T))
	command_bytes := vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand))
	if command_bytes + payload_bytes > handle.stride {
		fmt.eprintln("draw payload exceeds per-draw indirect stride")
		return false
	}
	offset := handle.buffer.draw_offset +
		handle.stride * vk.DeviceSize(index) +
		command_bytes
	return ez_gfx_buffer_write_at(&handle.buffer.buffer, offset, payload)
}

ez_gfx_align_device_size :: proc(value, alignment: vk.DeviceSize) -> vk.DeviceSize {
	if alignment == 0 do return value
	remainder := value % alignment
	if remainder == 0 do return value
	return value + alignment - remainder
}
