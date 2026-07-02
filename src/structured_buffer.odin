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
	size:                vk.DeviceSize,
	live:                bool,
	pending_destroy:     bool,
	last_write_timeline: u64,
	debug_name:          cstring,
}

Ez_Gfx_Structured_Buffer_Manager :: struct {
	buffers: [EZ_GFX_MAX_STRUCTURED_BUFFERS]Ez_Gfx_Structured_Buffer,
	count:   int,
	version: u64,
}

Ez_Gfx_Render_Structured_Binding :: struct {
	name:            [EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte,
	name_len:        int,
	buffer:          ^Ez_Gfx_Buffer,
	size:            vk.DeviceSize,
	structured_buffer:  ^Ez_Gfx_Structured_Buffer,
	indirect_buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
}

ez_gfx_allocate_structured_buffer :: proc(
	size: vk.DeviceSize,
	debug_name: cstring = nil,
) -> rawptr {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return nil
	if size == 0 {
		fmt.eprintln("structured buffer size must be greater than zero")
		return nil
	}

	manager := &ctx.structured_buffer_manager
	ez_gfx_structured_buffer_manager_collect_completed(manager)
	if manager.count >= EZ_GFX_MAX_STRUCTURED_BUFFERS {
		fmt.eprintln("too many structured buffers")
		return nil
	}

	slot := &manager.buffers[manager.count]
	manager.count += 1
	buffer, mapped, ok := ez_gfx_buffer_create_mapped(
		size,
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
		debug_name,
		0.4,
	)
	if !ok {
		manager.count -= 1
		slot^ = {}
		return nil
	}

	slot.buffer = buffer
	slot.cpu_ptr = mapped
	slot.size = size
	slot.live = true
	slot.debug_name = debug_name
	manager.version += 1
	return mapped
}

ez_gfx_deallocate_structured_buffer :: proc(ptr: rawptr) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	buffer := ez_gfx_structured_buffer_manager_find_by_ptr(&ctx.structured_buffer_manager, ptr)
	if buffer == nil {
		fmt.eprintln("structured buffer pointer was not allocated by ez_gfx")
		return false
	}
	if !buffer.live {
		fmt.eprintln("structured buffer was already deallocated")
		return false
	}

	buffer.live = false
	completed := ez_gfx_structured_buffer_completed_timeline()
	if buffer.last_write_timeline <= completed {
		ez_gfx_structured_buffer_destroy(buffer)
		ez_gfx_structured_buffer_manager_compact(&ctx.structured_buffer_manager)
	} else {
		buffer.pending_destroy = true
	}
	ctx.structured_buffer_manager.version += 1
	return true
}

ez_gfx_render_add_structured_buffer :: proc(
	shader_name: cstring,
	ptr: rawptr,
) -> bool {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_render_add_structured_buffer called without an active render")
		return false
	}
	storage := ez_gfx_structured_buffer_manager_find_by_ptr(&render.ctx.structured_buffer_manager, ptr)
	if storage == nil || !storage.live {
		fmt.eprintln("structured buffer pointer is not live")
		return false
	}
	return ez_gfx_render_add_structured_binding(
		render,
		shader_name,
		&storage.buffer,
		storage.size,
		storage,
		nil,
	)
}

ez_gfx_render_add_indirect_structured_buffer :: proc(
	shader_name: cstring,
	descriptor: ^Ez_Gfx_Vertex_Pipeline_Descriptor,
) -> bool {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_render_add_indirect_structured_buffer called without an active render")
		return false
	}
	if descriptor == nil || !descriptor.ok || descriptor.indirect_buffer == nil {
		fmt.eprintln("indirect descriptor is not valid")
		return false
	}
	return ez_gfx_render_add_structured_binding(
		render,
		shader_name,
		&descriptor.indirect_buffer.buffer,
		descriptor.indirect_buffer.buffer.size,
		nil,
		descriptor.indirect_buffer,
	)
}

ez_gfx_render_add_structured_binding :: proc(
	render: ^Ez_Gfx_Render,
	shader_name: cstring,
	buffer: ^Ez_Gfx_Buffer,
	size: vk.DeviceSize,
	structured_buffer: ^Ez_Gfx_Structured_Buffer,
	indirect_buffer: ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
) -> bool {
	if shader_name == nil {
		fmt.eprintln("structured buffer shader name is required")
		return false
	}

	name_len := ez_gfx_cstring_len(shader_name)
	if name_len > EZ_GFX_STRUCTURED_BUFFER_NAME_MAX {
		fmt.eprintln("structured buffer shader name is too long")
		return false
	}

	for i in 0 ..< render.structured_binding_count {
		binding := &render.structured_bindings[i]
		if ez_gfx_shader_target_name_equals_cstring(binding.name[:], binding.name_len, shader_name) {
			binding.buffer = buffer
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
	if !ez_gfx_copy_shader_target_name_cstring(binding.name[:], &binding.name_len, shader_name) {
		render.structured_binding_count -= 1
		return false
	}
	binding.buffer = buffer
	binding.size = size
	binding.structured_buffer = structured_buffer
	binding.indirect_buffer = indirect_buffer
	render.structured_binding_version += 1
	return true
}

ez_gfx_render_find_structured_binding :: proc(
	render: ^Ez_Gfx_Render,
	name: []byte,
	name_len: int,
) -> ^Ez_Gfx_Render_Structured_Binding {
	if render == nil do return nil
	for i in 0 ..< render.structured_binding_count {
		binding := &render.structured_bindings[i]
		if ez_gfx_shader_target_name_equals_bytes(binding.name[:], binding.name_len, name, name_len) {
			return binding
		}
	}
	return nil
}

ez_gfx_structured_buffer_manager_find_by_ptr :: proc(
	manager: ^Ez_Gfx_Structured_Buffer_Manager,
	ptr: rawptr,
) -> ^Ez_Gfx_Structured_Buffer {
	if ptr == nil do return nil
	for i in 0 ..< manager.count {
		if manager.buffers[i].cpu_ptr == ptr {
			return &manager.buffers[i]
		}
	}
	return nil
}

ez_gfx_structured_buffer_manager_destroy :: proc(manager: ^Ez_Gfx_Structured_Buffer_Manager) {
	for i in 0 ..< manager.count {
		ez_gfx_structured_buffer_destroy(&manager.buffers[i])
	}
	manager.count = 0
	manager.version = 0
}

ez_gfx_structured_buffer_manager_collect_completed :: proc(manager: ^Ez_Gfx_Structured_Buffer_Manager) {
	completed := ez_gfx_structured_buffer_completed_timeline()
	for i in 0 ..< manager.count {
		buffer := &manager.buffers[i]
		if buffer.pending_destroy && buffer.last_write_timeline <= completed {
			ez_gfx_structured_buffer_destroy(buffer)
		}
	}
	ez_gfx_structured_buffer_manager_compact(manager)
}

ez_gfx_structured_buffer_manager_compact :: proc(manager: ^Ez_Gfx_Structured_Buffer_Manager) {
	i := 0
	for i < manager.count {
		if manager.buffers[i].buffer.handle != vk.Buffer(0) || manager.buffers[i].live {
			i += 1
			continue
		}
		for j := i; j + 1 < manager.count; j += 1 {
			manager.buffers[j] = manager.buffers[j + 1]
		}
		manager.count -= 1
		manager.buffers[manager.count] = {}
	}
}

ez_gfx_structured_buffer_destroy :: proc(buffer: ^Ez_Gfx_Structured_Buffer) {
	ez_gfx_buffer_destroy(&buffer.buffer)
	buffer.cpu_ptr = nil
	buffer.size = 0
	buffer.live = false
	buffer.pending_destroy = false
	buffer.last_write_timeline = 0
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
