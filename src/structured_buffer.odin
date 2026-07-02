package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_STRUCTURED_BUFFERS :: 64
EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS :: 32
EZ_GFX_STRUCTURED_BUFFER_NAME_MAX :: EZ_GFX_SHADER_TARGET_NAME_MAX

Ez_Gfx_Buffer_Access :: enum u8 {
	Read,
	Write,
	Read_Write,
}

Ez_Gfx_Structured_Buffer :: struct {
	buffer:              Ez_Gfx_Buffer,
	cpu_ptr:             rawptr,
	capacity:            vk.DeviceSize,
	size:                vk.DeviceSize,
	in_use:              bool,
	last_write_timeline: u64,
	last_used_timeline:  u64,
	debug_name:          cstring,
}

Ez_Gfx_Structured_Buffer_Manager :: struct {
	buffers:           [EZ_GFX_MAX_STRUCTURED_BUFFERS]Ez_Gfx_Structured_Buffer,
	count:             int,
	version:           u64,
	peak_acquire_size: vk.DeviceSize,
}

Ez_Gfx_Render_Structured_Binding :: struct {
	name:              [EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte,
	name_len:          int,
	buffer:            ^Ez_Gfx_Buffer,
	offset:            vk.DeviceSize,
	size:              vk.DeviceSize,
	structured_buffer: ^Ez_Gfx_Structured_Buffer,
	indirect_buffer:   ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
}

ez_gfx_render_acquire_structured_buffer :: proc(
	shader_name: cstring,
	size: vk.DeviceSize,
) -> rawptr {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_render_acquire_structured_buffer called without an active render")
		return nil
	}
	if shader_name == nil {
		fmt.eprintln("structured buffer shader name is required")
		return nil
	}
	if size == 0 {
		fmt.eprintln("structured buffer size must be greater than zero")
		return nil
	}

	storage, acquire_ok := ez_gfx_structured_buffer_manager_acquire(
		&render.ctx.structured_buffer_manager,
		size,
		shader_name,
	)
	if !acquire_ok do return nil

	if !ez_gfx_render_add_structured_binding(
		render,
		shader_name,
		&storage.buffer,
		0,
		storage.size,
		storage,
		nil,
	) {
		storage.in_use = false
		return nil
	}
	return storage.cpu_ptr
}

ez_gfx_structured_buffer_manager_acquire :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
	size: vk.DeviceSize,
	debug_name: cstring = nil,
) -> (
	buffer: ^Ez_Gfx_Structured_Buffer,
	ok: bool,
) {
	if size == 0 {
		fmt.eprintln("structured buffer size must be greater than zero")
		return nil, false
	}

	if size > manager.peak_acquire_size {
		manager.peak_acquire_size = size
	}

	completed_timeline := ez_gfx_structured_buffer_completed_timeline()
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
	created, mapped, create_ok := ez_gfx_buffer_create_mapped(
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

ez_gfx_render_add_indirect_structured_buffer :: proc(
	shader_name: cstring,
	descriptor: ^Ez_Gfx_Vertex_Pipeline_Descriptor,
) -> bool {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln(
			"ez_gfx_render_add_indirect_structured_buffer called without an active render",
		)
		return false
	}
	if descriptor == nil || !descriptor.ok || descriptor.indirect_buffer == nil {
		fmt.eprintln("indirect descriptor is not valid")
		return false
	}
	indirect := descriptor.indirect_buffer
	count_size := vk.DeviceSize(size_of(u32))
	draw_offset := indirect.draw_offset
	draw_size := indirect.buffer.size - draw_offset
	return(
		ez_gfx_render_add_indirect_structured_buffer_part(
			render,
			shader_name,
			".count",
			&indirect.buffer,
			0,
			count_size,
			indirect,
		) &&
		ez_gfx_render_add_indirect_structured_buffer_part(
			render,
			shader_name,
			".elements",
			&indirect.buffer,
			draw_offset,
			draw_size,
			indirect,
		) \
	)
}

ez_gfx_render_add_structured_binding :: proc(
	render: ^Ez_Gfx_Render,
	shader_name: cstring,
	buffer: ^Ez_Gfx_Buffer,
	offset: vk.DeviceSize,
	size: vk.DeviceSize,
	structured_buffer: ^Ez_Gfx_Structured_Buffer,
	indirect_buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
) -> bool {
	if shader_name == nil {
		fmt.eprintln("structured buffer shader name is required")
		return false
	}

	name_len := ez_gfx_cstring_len(shader_name)
	if name_len >= EZ_GFX_STRUCTURED_BUFFER_NAME_MAX {
		fmt.eprintln("structured buffer shader name is too long")
		return false
	}
	name_bytes := cast([^]byte)shader_name
	return ez_gfx_render_add_structured_binding_bytes(
		render,
		name_bytes[:name_len],
		name_len,
		buffer,
		offset,
		size,
		structured_buffer,
		indirect_buffer,
	)
}

ez_gfx_render_add_structured_binding_bytes :: proc(
	render: ^Ez_Gfx_Render,
	shader_name: []byte,
	shader_name_len: int,
	buffer: ^Ez_Gfx_Buffer,
	offset: vk.DeviceSize,
	size: vk.DeviceSize,
	structured_buffer: ^Ez_Gfx_Structured_Buffer,
	indirect_buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
) -> bool {
	for i in 0 ..< render.structured_binding_count {
		binding := &render.structured_bindings[i]
		if ez_gfx_shader_target_name_equals_bytes(
			binding.name[:],
			binding.name_len,
			shader_name,
			shader_name_len,
		) {
			binding.buffer = buffer
			binding.offset = offset
			binding.size = size
			binding.structured_buffer = structured_buffer
			binding.indirect_buffer = indirect_buffer
			render.structured_binding_version += 1
			return true
		}
	}

	if render.structured_binding_count >= EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS {
		fmt.eprintln("too many structured buffers bound to this render")
		return false
	}
	binding := &render.structured_bindings[render.structured_binding_count]
	render.structured_binding_count += 1
	if !ez_gfx_copy_shader_target_name(
		binding.name[:],
		&binding.name_len,
		cast(cstring)raw_data(shader_name),
		shader_name_len,
	) {
		render.structured_binding_count -= 1
		return false
	}
	binding.buffer = buffer
	binding.offset = offset
	binding.size = size
	binding.structured_buffer = structured_buffer
	binding.indirect_buffer = indirect_buffer
	render.structured_binding_version += 1
	return true
}

ez_gfx_render_add_indirect_structured_buffer_part :: proc(
	render: ^Ez_Gfx_Render,
	shader_name: cstring,
	suffix: string,
	buffer: ^Ez_Gfx_Buffer,
	offset: vk.DeviceSize,
	size: vk.DeviceSize,
	indirect_buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
) -> bool {
	base_len := ez_gfx_cstring_len(shader_name)
	name_len := base_len + len(suffix)
	if name_len >= EZ_GFX_STRUCTURED_BUFFER_NAME_MAX {
		fmt.eprintln("indirect structured buffer shader name is too long")
		return false
	}

	name: [EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte
	base_bytes := cast([^]byte)shader_name
	for i in 0 ..< base_len {
		name[i] = base_bytes[i]
	}
	for i in 0 ..< len(suffix) {
		name[base_len + i] = suffix[i]
	}
	return ez_gfx_render_add_structured_binding_bytes(
		render,
		name[:name_len],
		name_len,
		buffer,
		offset,
		size,
		nil,
		indirect_buffer,
	)
}

ez_gfx_render_find_structured_binding :: proc(
	render: ^Ez_Gfx_Render,
	name: []byte,
	name_len: int,
) -> ^Ez_Gfx_Render_Structured_Binding {
	if render == nil do return nil
	for i in 0 ..< render.structured_binding_count {
		binding := &render.structured_bindings[i]
		if ez_gfx_shader_target_name_equals_bytes(
			binding.name[:],
			binding.name_len,
			name,
			name_len,
		) {
			return binding
		}
	}
	return nil
}

ez_gfx_structured_buffer_manager_release_completed :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
) {
	completed_timeline := ez_gfx_structured_buffer_completed_timeline()
	for i in 0 ..< manager.count {
		if manager.buffers[i].last_used_timeline <= completed_timeline {
			manager.buffers[i].in_use = false
		}
	}
	ez_gfx_structured_buffer_manager_trim_idle(manager, completed_timeline)
	manager.peak_acquire_size = 0
}

ez_gfx_structured_buffer_manager_trim_idle :: proc(
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
		ez_gfx_structured_buffer_manager_remove_at(manager, i)
	}
}

ez_gfx_structured_buffer_manager_remove_at :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
	index: int,
) {
	if index < 0 || index >= manager.count do return
	ez_gfx_structured_buffer_destroy(&manager.buffers[index])
	manager.count -= 1
	if index < manager.count {
		manager.buffers[index] = manager.buffers[manager.count]
	}
	manager.buffers[manager.count] = {}
	manager.version += 1
}

ez_gfx_structured_buffer_manager_destroy :: proc(manager: ^Ez_Gfx_Structured_Buffer_Manager) {
	for i in 0 ..< manager.count {
		ez_gfx_structured_buffer_destroy(&manager.buffers[i])
	}
	manager.count = 0
	manager.version = 0
	manager.peak_acquire_size = 0
}

ez_gfx_structured_buffer_mark_submitted :: proc(
	buffer: ^Ez_Gfx_Structured_Buffer,
	timeline_value: u64,
) {
	if buffer == nil do return
	buffer.last_used_timeline = timeline_value
	buffer.in_use = false
}

ez_gfx_structured_buffer_destroy :: proc(buffer: ^Ez_Gfx_Structured_Buffer) {
	ez_gfx_buffer_destroy(&buffer.buffer)
	buffer.cpu_ptr = nil
	buffer.capacity = 0
	buffer.size = 0
	buffer.in_use = false
	buffer.last_write_timeline = 0
	buffer.last_used_timeline = 0
	buffer.debug_name = nil
}

ez_gfx_structured_buffer_completed_timeline :: proc() -> u64 {
	ctx := ez_gfx_current_ctx
	if ctx == nil || ctx.timeline_semaphore == vk.Semaphore(0) do return 0
	value: u64
	if vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &value) != .SUCCESS {
		return 0
	}
	return value
}

ez_gfx_cstring_len :: proc(value: cstring) -> int {
	if value == nil do return 0
	bytes := cast([^]byte)value
	count := 0
	for bytes[count] != 0 {
		count += 1
	}
	return count
}
