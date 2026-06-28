package main

import sp "../vendor/odin-slang/slang"
import "core:fmt"
import "core:slice"
import vk "vendor:vulkan"

SLANG_SHADER_PATH :: "shaders/triangle.slang"
SLANG_VERTEX_ENTRY :: "vertexmain"
SLANG_FRAGMENT_ENTRY :: "fragmentmain"
SLANG_VERTEX_HEAP_ATTRIBUTE :: "VertexHeap"
EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS :: 8

Ez_Gfx_Vertex_Heap_Binding :: struct {
	name:     [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	name_len: int,
	binding:  u32,
	set:      u32,
}

Ez_Gfx_Shader_Program :: struct {
	module:                    vk.ShaderModule,
	vertex_heap_bindings:      [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS]Ez_Gfx_Vertex_Heap_Binding,
	vertex_heap_binding_count: int,
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
ez_gfx_shader_init_session :: proc(ctx: ^Ez_Gfx_Ctx) -> bool {
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

// Compiles the triangle shader to SPIR-V and creates a Vulkan shader module.
ez_gfx_shader_compile_triangle :: proc(
	ctx: ^Ez_Gfx_Ctx,
) -> (
	program: Ez_Gfx_Shader_Program,
	ok: bool,
) {
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
		return program, false
	}
	defer session->release()

	diagnostics: ^sp.IBlob
	slang_module := session->loadModule(SLANG_SHADER_PATH, &diagnostics)
	if slang_module == nil {
		_ = ez_gfx_slang_diagnostics_check(diagnostics)
		fmt.eprintln("failed to load Slang shader module")
		return program, false
	}
	defer slang_module->release()
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return program, false

	vertex_entry: ^sp.IEntryPoint
	if !ez_gfx_slang_check(slang_module->findEntryPointByName(SLANG_VERTEX_ENTRY, &vertex_entry)) {
		return program, false
	}
	if vertex_entry == nil {
		fmt.eprintf("missing Slang entry point: %v\n", SLANG_VERTEX_ENTRY)
		return program, false
	}

	fragment_entry: ^sp.IEntryPoint
	if !ez_gfx_slang_check(
		slang_module->findEntryPointByName(SLANG_FRAGMENT_ENTRY, &fragment_entry),
	) {
		return program, false
	}
	if fragment_entry == nil {
		fmt.eprintf("missing Slang entry point: %v\n", SLANG_FRAGMENT_ENTRY)
		return program, false
	}

	components: [3]^sp.IComponentType = {slang_module, vertex_entry, fragment_entry}
	linked_program: ^sp.IComponentType
	if !ez_gfx_slang_check(
		session->createCompositeComponentType(
			&components[0],
			len(components),
			&linked_program,
			&diagnostics,
		),
	) {
		return program, false
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return program, false
	defer linked_program->release()

	if !ez_gfx_shader_reflect_vertex_heap_bindings(ctx, linked_program, &program, &diagnostics) {
		return program, false
	}

	target_code: ^sp.IBlob
	if !ez_gfx_slang_check(linked_program->getTargetCode(0, &target_code, &diagnostics)) {
		return program, false
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return program, false

	code_size := target_code->getBufferSize()
	spirv_bytes := slice.bytes_from_ptr(target_code->getBufferPointer(), auto_cast code_size)

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spirv_bytes),
		pCode    = raw_data(slice.reinterpret([]u32, spirv_bytes)),
	}
	if vk.CreateShaderModule(ctx.device, &create_info, nil, &program.module) != .SUCCESS {
		fmt.eprintln("failed to create Vulkan shader module")
		return program, false
	}

	return program, true
}

ez_gfx_shader_reflect_vertex_heap_bindings :: proc(
	ctx: ^Ez_Gfx_Ctx,
	linked_program: ^sp.IComponentType,
	program: ^Ez_Gfx_Shader_Program,
	diagnostics: ^^sp.IBlob,
) -> bool {
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
