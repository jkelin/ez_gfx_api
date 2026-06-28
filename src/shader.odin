package main

import sp "../vendor/odin-slang/slang"
import "core:fmt"
import "core:slice"
import vk "vendor:vulkan"

SLANG_SHADER_PATH :: "shaders/triangle.slang"
SLANG_VERTEX_ENTRY :: "vertexmain"
SLANG_FRAGMENT_ENTRY :: "fragmentmain"

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
ez_gfx_shader_compile_triangle :: proc(ctx: ^Ez_Gfx_Ctx) -> (module: vk.ShaderModule, ok: bool) {
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
		return module, false
	}
	defer session->release()

	diagnostics: ^sp.IBlob
	slang_module := session->loadModule(SLANG_SHADER_PATH, &diagnostics)
	if slang_module == nil {
		_ = ez_gfx_slang_diagnostics_check(diagnostics)
		fmt.eprintln("failed to load Slang shader module")
		return module, false
	}
	defer slang_module->release()
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return module, false

	vertex_entry: ^sp.IEntryPoint
	if !ez_gfx_slang_check(slang_module->findEntryPointByName(SLANG_VERTEX_ENTRY, &vertex_entry)) {
		return module, false
	}
	if vertex_entry == nil {
		fmt.eprintf("missing Slang entry point: %v\n", SLANG_VERTEX_ENTRY)
		return module, false
	}

	fragment_entry: ^sp.IEntryPoint
	if !ez_gfx_slang_check(
		slang_module->findEntryPointByName(SLANG_FRAGMENT_ENTRY, &fragment_entry),
	) {
		return module, false
	}
	if fragment_entry == nil {
		fmt.eprintf("missing Slang entry point: %v\n", SLANG_FRAGMENT_ENTRY)
		return module, false
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
		return module, false
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return module, false
	defer linked_program->release()

	target_code: ^sp.IBlob
	if !ez_gfx_slang_check(linked_program->getTargetCode(0, &target_code, &diagnostics)) {
		return module, false
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return module, false

	code_size := target_code->getBufferSize()
	spirv_bytes := slice.bytes_from_ptr(target_code->getBufferPointer(), auto_cast code_size)

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spirv_bytes),
		pCode    = raw_data(slice.reinterpret([]u32, spirv_bytes)),
	}
	if vk.CreateShaderModule(ctx.device, &create_info, nil, &module) != .SUCCESS {
		fmt.eprintln("failed to create Vulkan shader module")
		return module, false
	}

	return module, true
}
