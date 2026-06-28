package ez_gfx

import sp "../vendor/odin-slang/slang"
import "core:fmt"
import "core:slice"
import vk "vendor:vulkan"

EZ_GFX_DEFAULT_VERTEX_ENTRY :: cstring("vertexmain")
EZ_GFX_DEFAULT_FRAGMENT_ENTRY :: cstring("fragmentmain")
SLANG_VERTEX_HEAP_ATTRIBUTE :: "VertexHeap"
EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS :: 8

Ez_Gfx_Vertex_Heap_Binding :: struct {
	name:     [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	name_len: int,
	binding:  u32,
	set:      u32,
}

Ez_Gfx_Shader_Program :: struct {
	desc:                      Ez_Gfx_Shader_Desc,
	identity:                  u64,
	module:                    vk.ShaderModule,
	vertex_heap_bindings:      [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS]Ez_Gfx_Vertex_Heap_Binding,
	vertex_heap_binding_count: int,
}

Ez_Gfx_Shader_Desc :: struct {
	path:           cstring,
	vertex_entry:   cstring,
	fragment_entry: cstring,
}

ez_gfx_slang_check :: proc(result: sp.Result, loc := #caller_location) -> bool {
	if sp.FAILED(result) {
		code := sp.GET_RESULT_CODE(result)
		facility := sp.GET_RESULT_FACILITY(result)
		fmt.eprintf("Slang failed: code=%v facility=%v\n", code, facility)
		return false
	}
	return true
}

ez_gfx_slang_diagnostics_check :: proc(diagnostics: ^sp.IBlob) -> bool {
	if diagnostics == nil do return true
	buffer := slice.bytes_from_ptr(
		diagnostics->getBufferPointer(),
		int(diagnostics->getBufferSize()),
	)
	fmt.eprintf("Slang diagnostics:\n%v\n", string(buffer))
	return false
}

// Creates the long-lived Slang global session used for shader compilation.
ez_gfx_shader_init_session :: proc() -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if ctx.slang_session != nil do return true
	if sp.createGlobalSession(sp.API_VERSION, &ctx.slang_session) != sp.OK {
		fmt.eprintln("failed to create Slang global session")
		return false
	}
	return true
}

ez_gfx_shader_destroy_session :: proc(ctx: ^Ez_Gfx_Ctx) {
	if ctx.slang_session != nil {
		ctx.slang_session->release()
		ctx.slang_session = nil
	}
}

// Compiles a Slang shader to SPIR-V and creates a Vulkan shader module.
ez_gfx_shader_compile :: proc(desc: Ez_Gfx_Shader_Desc, program: ^Ez_Gfx_Shader_Program) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if ctx.slang_session == nil {
		if !ez_gfx_shader_init_session() do return false
	}
	program^ = {}
	shader_desc := desc
	if shader_desc.vertex_entry == nil do shader_desc.vertex_entry = EZ_GFX_DEFAULT_VERTEX_ENTRY
	if shader_desc.fragment_entry == nil do shader_desc.fragment_entry = EZ_GFX_DEFAULT_FRAGMENT_ENTRY
	program.desc = shader_desc
	program.identity = ez_gfx_shader_desc_identity(shader_desc)

	target_desc := sp.TargetDesc {
		structureSize = size_of(sp.TargetDesc),
		format        = .SPIRV,
		flags         = {.GENERATE_SPIRV_DIRECTLY},
		profile       = ctx.slang_session->findProfile("sm_6_0"),
	}

	compiler_option_entries := [?]sp.CompilerOptionEntry {
		{name = .VulkanUseEntryPointName, value = {intValue0 = 1}},
	}
	session_desc := sp.SessionDesc {
		structureSize            = size_of(sp.SessionDesc),
		targets                  = &target_desc,
		targetCount              = 1,
		compilerOptionEntries    = &compiler_option_entries[0],
		compilerOptionEntryCount = 1,
	}

	session: ^sp.ISession
	if !ez_gfx_slang_check(ctx.slang_session->createSession(session_desc, &session)) {
		return false
	}
	// TODO: Audit odin-slang ownership before releasing session/module/component objects here.

	diagnostics: ^sp.IBlob
	slang_module := session->loadModule(shader_desc.path, &diagnostics)
	if slang_module == nil {
		_ = ez_gfx_slang_diagnostics_check(diagnostics)
		fmt.eprintln("failed to load Slang shader module")
		return false
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return false

	vertex_entry: ^sp.IEntryPoint
	if !ez_gfx_slang_check(
		slang_module->findEntryPointByName(shader_desc.vertex_entry, &vertex_entry),
	) {
		return false
	}
	if vertex_entry == nil {
		fmt.eprintf("missing Slang entry point: %v\n", shader_desc.vertex_entry)
		return false
	}

	fragment_entry: ^sp.IEntryPoint
	if !ez_gfx_slang_check(
		slang_module->findEntryPointByName(shader_desc.fragment_entry, &fragment_entry),
	) {
		return false
	}
	if fragment_entry == nil {
		fmt.eprintf("missing Slang entry point: %v\n", shader_desc.fragment_entry)
		return false
	}

	components: [3]^sp.IComponentType = {slang_module, vertex_entry, fragment_entry}
	linked_program: ^sp.IComponentType
	diagnostics = nil
	if !ez_gfx_slang_check(
		session->createCompositeComponentType(
			&components[0],
			len(components),
			&linked_program,
			&diagnostics,
		),
	) {
		return false
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return false

	if !ez_gfx_shader_reflect_vertex_heap_bindings(linked_program, program, &diagnostics) {
		return false
	}

	target_code: ^sp.IBlob
	diagnostics = nil
	if !ez_gfx_slang_check(linked_program->getTargetCode(0, &target_code, &diagnostics)) {
		return false
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return false

	code_size := target_code->getBufferSize()

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = auto_cast code_size,
		pCode    = cast([^]u32)target_code->getBufferPointer(),
	}
	if vk.CreateShaderModule(ctx.device, &create_info, nil, &program.module) != .SUCCESS {
		fmt.eprintln("failed to create Vulkan shader module")
		return false
	}

	return true
}

ez_gfx_shader_destroy :: proc(program: ^Ez_Gfx_Shader_Program) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	if program.module != vk.ShaderModule(0) {
		vk.DestroyShaderModule(ctx.device, program.module, nil)
		program.module = vk.ShaderModule(0)
	}
}

ez_gfx_shader_desc_identity :: proc(desc: Ez_Gfx_Shader_Desc) -> u64 {
	hash: u64 = 14695981039346656037
	hash = ez_gfx_hash_cstring(hash, desc.path)
	hash = ez_gfx_hash_cstring(hash, desc.vertex_entry)
	hash = ez_gfx_hash_cstring(hash, desc.fragment_entry)
	return hash
}

ez_gfx_hash_cstring :: proc(hash: u64, value: cstring) -> u64 {
	result := hash
	if value == nil do return result
	bytes := cast([^]u8)value
	for i := 0; bytes[i] != 0; i += 1 {
		result = (result ~ u64(bytes[i])) * 1099511628211
	}
	return result
}

ez_gfx_shader_reflect_vertex_heap_bindings :: proc(
	linked_program: ^sp.IComponentType,
	program: ^Ez_Gfx_Shader_Program,
	diagnostics: ^^sp.IBlob,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	diagnostics^ = nil
	program_layout := linked_program->getLayout(0, diagnostics)
	if !ez_gfx_slang_diagnostics_check(diagnostics^) do return false
	if program_layout == nil {
		fmt.eprintln("failed to get Slang program layout")
		return false
	}

	global_params := sp.program_layout_getGlobalParamsVarLayout(program_layout)
	if global_params == nil do return true

	global_type_layout := sp.variable_layout_getTypeLayout(global_params)
	field_count := sp.type_layout_getFieldCount(global_type_layout)
	for i in 0 ..< field_count {
		field_layout := sp.type_layout_getFieldByIndex(global_type_layout, i)
		if field_layout == nil do continue

		field_variable := sp.variable_layout_getVariable(field_layout)
		if field_variable == nil do continue

		attribute := sp.variable_findAttributeByName(
			field_variable,
			ctx.slang_session,
			SLANG_VERTEX_HEAP_ATTRIBUTE,
		)
		if attribute == nil do continue

		if program.vertex_heap_binding_count >= EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS {
			fmt.eprintln("too many shader vertex heap bindings")
			return false
		}
		if sp.ReflectionUserAttribute_GetArgumentCount(attribute) != 1 {
			fmt.eprintln("VertexHeap attribute requires one string heap name")
			return false
		}

		name_len: uint
		name := sp.ReflectionUserAttribute_GetArgumentValueString(attribute, 0, &name_len)
		if name == nil {
			fmt.eprintln("VertexHeap attribute argument must be a string")
			return false
		}

		binding := &program.vertex_heap_bindings[program.vertex_heap_binding_count]
		if !ez_gfx_copy_vertex_heap_binding_name(binding, name, int(name_len)) {
			return false
		}
		binding.binding = sp.variable_layout_getBindingIndex(field_layout)
		binding.set = u32(sp.variable_layout_getBindingSpace(field_layout, .ShaderResource))
		program.vertex_heap_binding_count += 1
	}

	return true
}

ez_gfx_copy_vertex_heap_binding_name :: proc(
	binding: ^Ez_Gfx_Vertex_Heap_Binding,
	name: cstring,
	name_len: int,
) -> bool {
	if name_len > EZ_GFX_VERTEX_HEAP_NAME_MAX {
		fmt.eprintln("reflected vertex heap name is too long")
		return false
	}

	for i in 0 ..< EZ_GFX_VERTEX_HEAP_NAME_MAX {
		binding.name[i] = 0
	}
	name_bytes := cast([^]byte)name
	for i in 0 ..< name_len {
		binding.name[i] = name_bytes[i]
	}
	binding.name_len = name_len
	return true
}
