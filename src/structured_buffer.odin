#+private
package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_STRUCTURED_BUFFERS :: 64
EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS :: 32
EZ_GFX_STRUCTURED_BUFFER_NAME_MAX :: EZ_GFX_SHADER_TARGET_NAME_MAX


















render_acquire_structured_buffer :: proc(
	$T: typeid,
	element_count: u32,
	debug_name: cstring,
) -> Ez_Gfx_Structured_Buffer_View(T) {
	render := &get_current_ctx().render

	byte_size := vk.DeviceSize(element_count) * vk.DeviceSize(size_of(T))
	storage, acquire_ok := structured_buffer_manager_acquire(
		&render.ctx.structured_buffer_manager,
		byte_size,
		debug_name,
	)
	if !acquire_ok do return {}

	handle := Ez_Gfx_Structured_Buffer_Handle {
		buffer   = storage,
		cpu_ptr  = storage.cpu_ptr,
		size     = storage.size,
		frame_id = render.frame_id,
		ok       = true,
	}
	return Ez_Gfx_Structured_Buffer_View(T) {
		handle   = handle,
		elements = cast([^]T)storage.cpu_ptr,
	}
}

structured_buffer_manager_acquire :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
	size: vk.DeviceSize,
	debug_name: cstring = nil,
) -> (
	buffer: ^Ez_Gfx_Structured_Buffer,
	ok: bool,
) {

	if size > manager.peak_acquire_size {
		manager.peak_acquire_size = size
	}

	completed_timeline := structured_buffer_completed_timeline()
	best_index := -1
	for i in 0 ..< manager.count {
		candidate := &manager.buffers[i]
		if !candidate.in_use &&
		   candidate.last_used_timeline <= completed_timeline &&
		   candidate.capacity >= size &&
		   (best_index < 0 || candidate.capacity < manager.buffers[best_index].capacity) {
			best_index = i
		}
	}
	if best_index >= 0 {
		candidate := &manager.buffers[best_index]
		candidate.in_use = true
		candidate.size = size
		candidate.last_write_timeline = 0
		candidate.debug_name = debug_name
		manager.version += 1
		return candidate, true
	}

	if manager.count >= EZ_GFX_MAX_STRUCTURED_BUFFERS {
		fmt.eprintln("too many structured buffers are in use")
		return nil, false
	}

	slot := &manager.buffers[manager.count]
	manager.count += 1
	created, mapped, create_ok := buffer_create_mapped(
		size,
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
		debug_name,
		0.4,
	)
	if !create_ok {
		manager.count -= 1
		slot^ = {}
		return nil, false
	}
	slot.buffer = created
	slot.cpu_ptr = mapped
	slot.capacity = size
	slot.size = size
	slot.in_use = true
	slot.last_write_timeline = 0
	slot.last_used_timeline = 0
	slot.debug_name = debug_name
	manager.version += 1
	return slot, true
}

indirect_structured_name :: proc(
	shader_name: cstring,
	suffix: string,
	name: ^[EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte,
	name_len: ^int,
) -> bool {
	base_len := cstring_len(shader_name)
	name_len^ = base_len + len(suffix)
	if name_len^ >= EZ_GFX_STRUCTURED_BUFFER_NAME_MAX {
		fmt.eprintln("indirect structured buffer shader name is too long")
		return false
	}

	base_bytes := cast([^]byte)shader_name
	for i in 0 ..< base_len {
		name^[i] = base_bytes[i]
	}
	for i in 0 ..< len(suffix) {
		name^[base_len + i] = suffix[i]
	}
	return true
}

structured_buffer_manager_release_completed :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
) {
	completed_timeline := structured_buffer_completed_timeline()
	for i in 0 ..< manager.count {
		if manager.buffers[i].last_used_timeline <= completed_timeline {
			manager.buffers[i].in_use = false
		}
	}
	structured_buffer_manager_trim_idle(manager, completed_timeline)
	manager.peak_acquire_size = 0
}

structured_buffer_manager_trim_idle :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
	completed_timeline: u64,
) {
	peak_size := manager.peak_acquire_size
	i := 0
	for i < manager.count {
		buffer := &manager.buffers[i]
		if buffer.in_use ||
		   buffer.last_used_timeline > completed_timeline ||
		   buffer.capacity <= peak_size {
			i += 1
			continue
		}
		structured_buffer_manager_remove_at(manager, i)
	}
}

structured_buffer_manager_remove_at :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
	index: int,
) {
	if index < 0 || index >= manager.count do return
	structured_buffer_destroy(&manager.buffers[index])
	manager.count -= 1
	if index < manager.count {
		manager.buffers[index] = manager.buffers[manager.count]
	}
	manager.buffers[manager.count] = {}
	manager.version += 1
}

structured_buffer_manager_destroy :: proc(manager: ^Ez_Gfx_Structured_Buffer_Manager) {
	for i in 0 ..< manager.count {
		structured_buffer_destroy(&manager.buffers[i])
	}
	manager.count = 0
	manager.version = 0
	manager.peak_acquire_size = 0
}

structured_buffer_mark_submitted :: proc(
	buffer: ^Ez_Gfx_Structured_Buffer,
	timeline_value: u64,
) {
	if buffer == nil do return
	buffer.last_used_timeline = timeline_value
	buffer.in_use = false
}

structured_buffer_destroy :: proc(buffer: ^Ez_Gfx_Structured_Buffer) {
	buffer_destroy(&buffer.buffer)
	buffer.cpu_ptr = nil
	buffer.capacity = 0
	buffer.size = 0
	buffer.in_use = false
	buffer.last_write_timeline = 0
	buffer.last_used_timeline = 0
	buffer.debug_name = nil
}

structured_buffer_completed_timeline :: proc() -> u64 {
	ctx := get_current_ctx()
	if ctx == nil || ctx.timeline_semaphore == vk.Semaphore(0) do return 0
	value: u64
	if vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &value) != .SUCCESS {
		return 0
	}
	return value
}

cstring_len :: proc(value: cstring) -> int {
	if value == nil do return 0
	bytes := cast([^]byte)value
	count := 0
	for bytes[count] != 0 {
		count += 1
	}
	return count
}
