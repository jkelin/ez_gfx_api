package ez_gfx

import sp "../vendor/odin-slang/slang"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

EZ_GFX_DEFAULT_VERTEX_ENTRY :: cstring("vertexmain")
EZ_GFX_DEFAULT_FRAGMENT_ENTRY :: cstring("fragmentmain")
EZ_GFX_DEFAULT_COMPUTE_ENTRY :: cstring("computemain")
// Slang resolves `import ez_gfx;` against this directory (src/ez_gfx.slang).
EZ_GFX_SLANG_MODULE_SEARCH_PATH :: cstring("src")
SLANG_VERTEX_HEAP_ATTRIBUTE :: "VertexHeap"
SLANG_STRUCTURED_BUFFER_ATTRIBUTE :: "StructuredBuffer"
SLANG_COLOR_TARGET_ATTRIBUTE :: "ColorTarget"
SLANG_DEPTH_TARGET_ATTRIBUTE :: "DepthTarget"
SLANG_RELATIVE_SCALE_ATTRIBUTE :: "RelativeScale"
SLANG_TARGET_LAYOUT_ATTRIBUTE :: "TargetLayout"
SLANG_LOAD_TARGET_ATTRIBUTE :: "LoadTarget"
SLANG_BLEND_MODE_ATTRIBUTE :: "BlendMode"
EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS :: 8
EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS :: 16
EZ_GFX_MAX_SHADER_TARGET_USAGES :: 8
EZ_GFX_MAX_SHADER_TARGET_DECLARATIONS :: 8
EZ_GFX_SHADER_TARGET_NAME_MAX :: 32
EZ_GFX_MAX_PUSH_CONSTANT_BYTES :: 128

Ez_Gfx_Shader_Stage :: enum u8 {
	Vertex,
	Fragment,
	Compute,
}

Ez_Gfx_Shader_Kind :: enum u8 {
	Graphics,
	Compute,
}

Ez_Gfx_Target_Access :: enum u8 {
	Read,
	Write,
	Read_Write,
}

Ez_Gfx_Render_Target_Kind :: enum u8 {
	Color,
	Depth,
}

Ez_Gfx_Blend_Mode :: enum u8 {
	None,
	Alpha,
}

Ez_Gfx_Vertex_Heap_Binding :: struct {
	name:     [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	name_len: int,
	binding:  u32,
	set:      u32,
}

Ez_Gfx_Structured_Buffer_Binding :: struct {
	name:     [EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte,
	name_len: int,
	binding:  u32,
	set:      u32,
	access:   Ez_Gfx_Buffer_Access,
	stages:   vk.ShaderStageFlags,
}

Ez_Gfx_Shader_Target_Usage :: struct {
	name:                   [EZ_GFX_SHADER_TARGET_NAME_MAX]byte,
	name_len:               int,
	access:                 Ez_Gfx_Target_Access,
	stage:                  Ez_Gfx_Shader_Stage,
	core:                   bool,
	color_attachment_index: u32,
}

Ez_Gfx_Shader_Target_Declaration :: struct {
	name:                [EZ_GFX_SHADER_TARGET_NAME_MAX]byte,
	name_len:            int,
	relative_scale:      f32,
	kind:                Ez_Gfx_Render_Target_Kind,
	format:              vk.Format,
	binding:             u32,
	set:                 u32,
	storage:             bool,
	load_on_frame_begin: bool,
}

Ez_Gfx_Shader_Program :: struct {
	desc:                      Ez_Gfx_Shader_Desc,
	identity:                  u64,
	module:                    vk.ShaderModule,
	vertex_heap_bindings:      [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS]Ez_Gfx_Vertex_Heap_Binding,
	vertex_heap_binding_count: int,
	structured_buffer_bindings:      [EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS]Ez_Gfx_Structured_Buffer_Binding,
	structured_buffer_binding_count: int,
	target_usages:             [EZ_GFX_MAX_SHADER_TARGET_USAGES]Ez_Gfx_Shader_Target_Usage,
	target_usage_count:        int,
	target_declarations:       [EZ_GFX_MAX_SHADER_TARGET_DECLARATIONS]Ez_Gfx_Shader_Target_Declaration,
	target_declaration_count:  int,
	push_constant_size:        u32,
	blend_mode:                Ez_Gfx_Blend_Mode,
}

Ez_Gfx_Shader_Desc :: struct {
	path:           cstring,
	vertex_entry:   cstring,
	fragment_entry: cstring,
	compute_entry:  cstring,
	kind:           Ez_Gfx_Shader_Kind,
}

@(private)
Ez_Gfx_Slang_Linked_Program :: struct {
	session:        ^sp.ISession,
	shared_module: ^sp.IModule,
	slang_module:   ^sp.IModule,
	vertex_entry:   ^sp.IEntryPoint,
	fragment_entry: ^sp.IEntryPoint,
	compute_entry:  ^sp.IEntryPoint,
	linked_program: ^sp.IComponentType,
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

@(private)
ez_gfx_slang_blob_release :: proc(blob: ^^sp.IBlob) {
	if blob != nil && blob^ != nil {
		blob^->release()
		blob^ = nil
	}
}

@(private)
ez_gfx_slang_diagnostics_check :: proc(diagnostics: ^^sp.IBlob) -> bool {
	if diagnostics == nil || diagnostics^ == nil do return true
	buffer := slice.bytes_from_ptr(
		diagnostics^->getBufferPointer(),
		int(diagnostics^->getBufferSize()),
	)
	fmt.eprintf("Slang diagnostics:\n%v\n", string(buffer))
	ez_gfx_slang_blob_release(diagnostics)
	return false
}

@(private)
ez_gfx_slang_linked_program_release :: proc(program: ^Ez_Gfx_Slang_Linked_Program) {
	if program == nil do return
	// Directly releasing module/entry/composite handles corrupts Slang's heap; the session owns them.
	if program.session != nil {
		program.session->release()
		program.session = nil
	}
	program.linked_program = nil
	program.compute_entry = nil
	program.fragment_entry = nil
	program.vertex_entry = nil
	program.slang_module = nil
	program.shared_module = nil
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

ez_gfx_shader_prepare_desc :: proc(desc: Ez_Gfx_Shader_Desc) -> Ez_Gfx_Shader_Desc {
	shader_desc := desc
	if shader_desc.kind == .Compute {
		if shader_desc.compute_entry == nil do shader_desc.compute_entry = EZ_GFX_DEFAULT_COMPUTE_ENTRY
	} else {
		if shader_desc.vertex_entry == nil do shader_desc.vertex_entry = EZ_GFX_DEFAULT_VERTEX_ENTRY
		if shader_desc.fragment_entry == nil do shader_desc.fragment_entry = EZ_GFX_DEFAULT_FRAGMENT_ENTRY
	}
	return shader_desc
}

// Reflects shader metadata without creating a Vulkan shader module.
ez_gfx_shader_reflect :: proc(desc: Ez_Gfx_Shader_Desc, program: ^Ez_Gfx_Shader_Program) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if ctx.slang_session == nil {
		if !ez_gfx_shader_init_session() do return false
	}
	program^ = {}
	shader_desc := ez_gfx_shader_prepare_desc(desc)
	program.desc = shader_desc
	program.identity = ez_gfx_shader_desc_identity(shader_desc)

	// Render targets are part of the engine contract, not just SPIR-V usage.
	// This unoptimized metadata pass preserves declarations that the final
	// optimized shader could otherwise remove as unused.
	diagnostics: ^sp.IBlob
	linked_program, linked_program_ok := ez_gfx_shader_create_linked_program(
		shader_desc,
		.NONE,
		true,
		&diagnostics,
	)
	if !linked_program_ok do return false
	defer ez_gfx_slang_linked_program_release(&linked_program)

	if !ez_gfx_shader_reflect_metadata(linked_program.linked_program, program, &diagnostics) {
		return false
	}

	return true
}

// Compiles a Slang shader to SPIR-V and creates a Vulkan shader module.
ez_gfx_shader_compile :: proc(desc: Ez_Gfx_Shader_Desc, program: ^Ez_Gfx_Shader_Program) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if !ez_gfx_shader_reflect(desc, program) do return false

	diagnostics: ^sp.IBlob
	linked_program, linked_program_ok := ez_gfx_shader_create_linked_program(
		program.desc,
		.DEFAULT,
		false,
		&diagnostics,
	)
	if !linked_program_ok do return false
	defer ez_gfx_slang_linked_program_release(&linked_program)

	target_code: ^sp.IBlob
	defer ez_gfx_slang_blob_release(&target_code)
	diagnostics = nil
	if !ez_gfx_slang_check(
		linked_program.linked_program->getTargetCode(0, &target_code, &diagnostics),
	) {
		_ = ez_gfx_slang_diagnostics_check(&diagnostics)
		return false
	}
	if !ez_gfx_slang_diagnostics_check(&diagnostics) do return false

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
	ez_gfx_debug_set_object_name(
		ctx,
		.SHADER_MODULE,
		ez_gfx_debug_handle(program.module),
		program.desc.path,
	)

	return true
}

ez_gfx_shader_create_linked_program :: proc(
	shader_desc: Ez_Gfx_Shader_Desc,
	optimization: sp.OptimizationLevel,
	preserve_parameters: bool,
	diagnostics: ^^sp.IBlob,
) -> (
	program: Ez_Gfx_Slang_Linked_Program,
	ok: bool,
) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return

	target_desc := sp.TargetDesc {
		structureSize = size_of(sp.TargetDesc),
		format        = .SPIRV,
		flags         = {.GENERATE_SPIRV_DIRECTLY},
		profile       = ctx.slang_session->findProfile("sm_6_0"),
	}

	compiler_option_entries := [4]sp.CompilerOptionEntry {
		{name = .VulkanUseEntryPointName, value = {kind = .Int, intValue0 = 1}},
		{name = .Optimization, value = {kind = .Int, intValue0 = i32(optimization)}},
		{
			name = .MinimumSlangOptimization,
			value = {kind = .Int, intValue0 = preserve_parameters ? 1 : 0},
		},
		{
			name = .PreserveParameters,
			value = {kind = .Int, intValue0 = preserve_parameters ? 1 : 0},
		},
	}
	shader_path := shader_desc.path
	slang_search_paths: [2]cstring
	slang_search_paths[0] = EZ_GFX_SLANG_MODULE_SEARCH_PATH
	search_path_count := 1
	if resolved_path, resolved_search_path, resolved := ez_gfx_shader_resolve_load_path(
		shader_desc.path,
	); resolved {
		shader_path = resolved_path
		if resolved_search_path != nil {
			slang_search_paths[search_path_count] = resolved_search_path
			search_path_count += 1
		}
	}
	if !ez_gfx_shader_validate_source_attributes(shader_path) do return
	session_desc := sp.SessionDesc {
		structureSize            = size_of(sp.SessionDesc),
		targets                  = &target_desc,
		targetCount              = 1,
		searchPaths              = &slang_search_paths[0],
		searchPathCount          = search_path_count,
		compilerOptionEntries    = &compiler_option_entries[0],
		compilerOptionEntryCount = len(compiler_option_entries),
	}

	cleanup_on_failure := true
	defer {
		if cleanup_on_failure {
			ez_gfx_slang_linked_program_release(&program)
		}
	}

	if !ez_gfx_slang_check(ctx.slang_session->createSession(session_desc, &program.session)) {
		return
	}

	diagnostics^ = nil
	program.slang_module = program.session->loadModule(shader_path, diagnostics)
	if program.slang_module == nil {
		_ = ez_gfx_slang_diagnostics_check(diagnostics)
		fmt.eprintln("failed to load Slang shader module")
		return
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return

	diagnostics^ = nil
	program.shared_module = program.session->loadModule("ez_gfx", diagnostics)
	if program.shared_module == nil {
		_ = ez_gfx_slang_diagnostics_check(diagnostics)
		fmt.eprintln("failed to load shared ez_gfx Slang module")
		return
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return

	components: [4]^sp.IComponentType
	component_count := 0
	components[component_count] = program.shared_module
	component_count += 1
	components[component_count] = program.slang_module
	component_count += 1

	if shader_desc.kind == .Compute {
		if !ez_gfx_slang_check(
			program.slang_module->findEntryPointByName(
				shader_desc.compute_entry,
				&program.compute_entry,
			),
		) {
			return
		}
		if program.compute_entry == nil {
			fmt.eprintf("missing Slang entry point: %v\n", shader_desc.compute_entry)
			return
		}
		components[component_count] = program.compute_entry
		component_count += 1
	} else {
		if !ez_gfx_slang_check(
			program.slang_module->findEntryPointByName(
				shader_desc.vertex_entry,
				&program.vertex_entry,
			),
		) {
			return
		}
		if program.vertex_entry == nil {
			fmt.eprintf("missing Slang entry point: %v\n", shader_desc.vertex_entry)
			return
		}

		if !ez_gfx_slang_check(
			program.slang_module->findEntryPointByName(
				shader_desc.fragment_entry,
				&program.fragment_entry,
			),
		) {
			return
		}
		if program.fragment_entry == nil {
			fmt.eprintf("missing Slang entry point: %v\n", shader_desc.fragment_entry)
			return
		}
		components[component_count] = program.vertex_entry
		component_count += 1
		components[component_count] = program.fragment_entry
		component_count += 1
	}
	diagnostics^ = nil
	if !ez_gfx_slang_check(
		program.session->createCompositeComponentType(
			&components[0],
			component_count,
			&program.linked_program,
			diagnostics,
		),
	) {
		_ = ez_gfx_slang_diagnostics_check(diagnostics)
		return
	}
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return
	cleanup_on_failure = false
	ok = true
	return
}

ez_gfx_shader_validate_source_attributes :: proc(path: cstring) -> bool {
	source_path := ez_gfx_shader_cstring_to_string(path)
	if len(source_path) == 0 do return true

	source_bytes, read_err := os.read_entire_file(source_path, context.temp_allocator)
	if read_err != nil {
		return true
	}
	source := string(source_bytes)
	if ez_gfx_shader_source_has_load_target_arguments(source) {
		// Slang currently crashes on this zero-field attribute misuse, so fail before loadModule.
		fmt.eprintln("LoadTarget attribute does not take arguments")
		return false
	}
	return true
}

ez_gfx_shader_source_has_load_target_arguments :: proc(source: string) -> bool {
	i := 0
	for i < len(source) {
		if i + 1 < len(source) && source[i] == '/' && source[i + 1] == '/' {
			i += 2
			for i < len(source) && source[i] != '\n' {
				i += 1
			}
			continue
		}
		if i + 1 < len(source) && source[i] == '/' && source[i + 1] == '*' {
			i += 2
			for i + 1 < len(source) && !(source[i] == '*' && source[i + 1] == '/') {
				i += 1
			}
			if i + 1 < len(source) do i += 2
			continue
		}
		if source[i] == '"' || source[i] == '\'' {
			quote := source[i]
			i += 1
			for i < len(source) {
				if source[i] == '\\' {
					i += 2
					continue
				}
				if source[i] == quote {
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		if source[i] == '[' {
			i += 1
			i = ez_gfx_shader_skip_slang_whitespace(source, i)
			if i + len(SLANG_LOAD_TARGET_ATTRIBUTE) <= len(source) &&
			   source[i:i + len(SLANG_LOAD_TARGET_ATTRIBUTE)] == SLANG_LOAD_TARGET_ATTRIBUTE {
				end := i + len(SLANG_LOAD_TARGET_ATTRIBUTE)
				if end >= len(source) || !ez_gfx_shader_is_identifier_byte(source[end]) {
					end = ez_gfx_shader_skip_slang_whitespace(source, end)
					if end < len(source) && source[end] == '(' {
						return true
					}
				}
			}
			continue
		}
		i += 1
	}
	return false
}

ez_gfx_shader_skip_slang_whitespace :: proc(source: string, index: int) -> int {
	i := index
	for i < len(source) {
		if source[i] != ' ' && source[i] != '\t' && source[i] != '\n' && source[i] != '\r' {
			break
		}
		i += 1
	}
	return i
}

ez_gfx_shader_is_identifier_byte :: proc(value: byte) -> bool {
	return(
		('a' <= value && value <= 'z') ||
		('A' <= value && value <= 'Z') ||
		('0' <= value && value <= '9') ||
		value == '_' \
	)
}

ez_gfx_shader_resolve_load_path :: proc(
	path: cstring,
) -> (
	resolved_path: cstring,
	resolved_search_path: cstring,
	ok: bool,
) {
	path_string := ez_gfx_shader_cstring_to_string(path)
	if len(path_string) == 0 || filepath.is_abs(path_string) {
		return nil, nil, false
	}

	working_dir, cwd_err := os.getwd(context.temp_allocator)
	if cwd_err != nil {
		return nil, nil, false
	}

	dir := working_dir
	for {
		candidate, join_err := filepath.join([]string{dir, path_string}, context.temp_allocator)
		if join_err == nil && os.exists(candidate) {
			candidate_c, path_err := strings.clone_to_cstring(candidate, context.temp_allocator)
			if path_err != nil do return nil, nil, false

			search_path, search_err := filepath.join(
				[]string{dir, ez_gfx_shader_cstring_to_string(EZ_GFX_SLANG_MODULE_SEARCH_PATH)},
				context.temp_allocator,
			)
			if search_err != nil do return candidate_c, nil, true
			search_c, search_c_err := strings.clone_to_cstring(search_path, context.temp_allocator)
			if search_c_err != nil do return candidate_c, nil, true
			return candidate_c, search_c, true
		}

		parent, has_parent := ez_gfx_shader_parent_dir(dir)
		if !has_parent do break
		dir = parent
	}

	return nil, nil, false
}

ez_gfx_shader_cstring_to_string :: proc(value: cstring) -> string {
	if value == nil do return ""
	bytes := cast([^]byte)value
	count := 0
	for bytes[count] != 0 {
		count += 1
	}
	return string(bytes[:count])
}

ez_gfx_shader_parent_dir :: proc(path: string) -> (parent: string, ok: bool) {
	if len(path) == 0 do return "", false

	root_len := 0
	if len(path) >= 2 && path[1] == ':' {
		root_len = 2
	}
	if len(path) > root_len && os.is_path_separator(path[root_len]) {
		root_len += 1
	}

	end := len(path)
	for end > root_len && os.is_path_separator(path[end - 1]) {
		end -= 1
	}
	if end <= root_len {
		return "", false
	}

	for i := end - 1; i >= root_len; i -= 1 {
		if os.is_path_separator(path[i]) {
			return path[:i], true
		}
	}
	if root_len > 0 && end > root_len {
		return path[:root_len], true
	}
	return "", false
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
	hash = ez_gfx_hash_cstring(hash, desc.compute_entry)
	hash = (hash ~ u64(desc.kind)) * 1099511628211
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

ez_gfx_shader_reflect_metadata :: proc(
	linked_program: ^sp.IComponentType,
	program: ^Ez_Gfx_Shader_Program,
	diagnostics: ^^sp.IBlob,
) -> bool {
	diagnostics^ = nil
	program_layout := linked_program->getLayout(0, diagnostics)
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return false
	if program_layout == nil {
		fmt.eprintln("failed to get Slang program layout")
		return false
	}

	if !ez_gfx_shader_reflect_vertex_heap_bindings_from_layout(program_layout, program) {
		return false
	}
	if !ez_gfx_shader_reflect_structured_buffer_bindings_from_layout(program_layout, program) {
		return false
	}
	if !ez_gfx_shader_reflect_push_constants_from_layout(program_layout, program) {
		return false
	}
	if !ez_gfx_shader_reflect_target_declarations_from_layout(program_layout, program) {
		return false
	}
	if !ez_gfx_shader_reflect_target_usages_from_layout(program_layout, program) {
		return false
	}
	return ez_gfx_shader_validate_targets(program)
}

ez_gfx_shader_reflect_push_constants_from_layout :: proc(
	program_layout: ^sp.ProgramLayout,
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	global_params := sp.program_layout_getGlobalParamsVarLayout(program_layout)
	if global_params == nil do return true

	global_type_layout := sp.variable_layout_getTypeLayout(global_params)
	if global_type_layout == nil do return true

	field_count := sp.type_layout_getFieldCount(global_type_layout)
	for i in 0 ..< field_count {
		field_layout := sp.type_layout_getFieldByIndex(global_type_layout, i)
		if field_layout == nil do continue
		if !ez_gfx_shader_variable_layout_has_category(field_layout, .PushConstantBuffer) {
			continue
		}

		field_type_layout := sp.variable_layout_getTypeLayout(field_layout)
		if field_type_layout == nil do continue
		data_layout := sp.type_layout_getElementTypeLayout(field_type_layout)
		if data_layout == nil do continue

		size := sp.type_layout_getSize(data_layout, .Uniform)
		if size == 0 {
			size = sp.type_layout_getSize(data_layout)
		}
		if !ez_gfx_shader_set_push_constant_size(program, size) {
			return false
		}
	}

	range_count := sp.type_layout_getBindingRangeCount(global_type_layout)
	for i in 0 ..< range_count {
		if sp.type_layout_getBindingRangeType(global_type_layout, i) != .PUSH_CONSTANT {
			continue
		}

		constant_buffer_layout := sp.type_layout_getBindingRangeLeafTypeLayout(global_type_layout, i)
		if constant_buffer_layout == nil do continue
		data_layout := sp.type_layout_getElementTypeLayout(constant_buffer_layout)
		if data_layout == nil do continue

		size := sp.type_layout_getSize(data_layout)
		if size == 0 do continue
		if !ez_gfx_shader_set_push_constant_size(program, size) {
			return false
		}
	}

	return true
}

ez_gfx_shader_variable_layout_has_category :: proc(
	layout: ^sp.VariableLayoutReflection,
	category: sp.ParameterCategory,
) -> bool {
	category_count := sp.variable_layout_getCategoryCount(layout)
	for i in 0 ..< category_count {
		if sp.variable_layout_getCategoryByIndex(layout, i) == category {
			return true
		}
	}
	return sp.variable_layout_getCategory(layout) == category
}

ez_gfx_shader_set_push_constant_size :: proc(
	program: ^Ez_Gfx_Shader_Program,
	size: uint,
) -> bool {
	if size == 0 do return true
	if program.push_constant_size != 0 {
		fmt.eprintln("only one shader push constant range is supported")
		return false
	}
	if size > EZ_GFX_MAX_PUSH_CONSTANT_BYTES {
		fmt.eprintln("shader push constant range exceeds ez_gfx limit")
		return false
	}
	program.push_constant_size = u32(size)
	return true
}

ez_gfx_shader_reflect_vertex_heap_bindings :: proc(
	linked_program: ^sp.IComponentType,
	program: ^Ez_Gfx_Shader_Program,
	diagnostics: ^^sp.IBlob,
) -> bool {
	diagnostics^ = nil
	program_layout := linked_program->getLayout(0, diagnostics)
	if !ez_gfx_slang_diagnostics_check(diagnostics) do return false
	if program_layout == nil {
		fmt.eprintln("failed to get Slang program layout")
		return false
	}
	return ez_gfx_shader_reflect_vertex_heap_bindings_from_layout(program_layout, program)
}

ez_gfx_shader_reflect_vertex_heap_bindings_from_layout :: proc(
	program_layout: ^sp.ProgramLayout,
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

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

ez_gfx_shader_reflect_structured_buffer_bindings_from_layout :: proc(
	program_layout: ^sp.ProgramLayout,
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

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
			SLANG_STRUCTURED_BUFFER_ATTRIBUTE,
		)
		if attribute == nil do continue

		if program.structured_buffer_binding_count >= EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS {
			fmt.eprintln("too many shader structured buffer bindings")
			return false
		}
		if sp.ReflectionUserAttribute_GetArgumentCount(attribute) != 1 {
			fmt.eprintln("StructuredBuffer attribute requires one string buffer name")
			return false
		}

		name_len: uint
		name := sp.ReflectionUserAttribute_GetArgumentValueString(attribute, 0, &name_len)
		if name == nil {
			fmt.eprintln("StructuredBuffer argument must be a string")
			return false
		}

		field_type_layout := sp.variable_layout_getTypeLayout(field_layout)
		access: Ez_Gfx_Buffer_Access
		if ez_gfx_shader_try_reflect_structured_buffer_access(field_type_layout, &access) {
			if !ez_gfx_shader_add_structured_buffer_binding(
				program,
				name,
				int(name_len),
				field_layout,
				field_type_layout,
				access,
			) {
				return false
			}
		} else if !ez_gfx_shader_reflect_structured_buffer_fields(
			      program,
			      name,
			      int(name_len),
			      sp.variable_layout_getBindingIndex(field_layout),
			      field_type_layout,
		      ) {
			return false
		}
	}

	return true
}

ez_gfx_shader_reflect_structured_buffer_fields :: proc(
	program: ^Ez_Gfx_Shader_Program,
	base_name: cstring,
	base_name_len: int,
	base_binding: u32,
	type_layout: ^sp.TypeLayoutReflection,
) -> bool {
	if type_layout == nil {
		fmt.eprintln("StructuredBuffer wrapper is missing type layout")
		return false
	}
	field_count := sp.type_layout_getFieldCount(type_layout)
	if field_count == 0 {
		fmt.eprintln("StructuredBuffer must reflect as a buffer or wrapper with buffer fields")
		return false
	}

	reflected_field_count := 0
	for i in 0 ..< field_count {
		field_layout := sp.type_layout_getFieldByIndex(type_layout, i)
		if field_layout == nil do continue
		field_type_layout := sp.variable_layout_getTypeLayout(field_layout)
		access: Ez_Gfx_Buffer_Access
		if !ez_gfx_shader_try_reflect_structured_buffer_access(field_type_layout, &access) {
			continue
		}
		field_name := sp.variable_layout_getName(field_layout)
		if field_name == nil {
			fmt.eprintln("StructuredBuffer wrapper field is missing a reflected name")
			return false
		}
		field_name_len := ez_gfx_cstring_len(field_name)
		combined_name: [EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte
		combined_name_len: int
		if !ez_gfx_copy_shader_target_name_with_suffix(
			combined_name[:],
			&combined_name_len,
			base_name,
			base_name_len,
			field_name,
			field_name_len,
		) {
			return false
		}
		if !ez_gfx_shader_add_structured_buffer_binding_bytes(
			program,
			combined_name[:],
			combined_name_len,
			field_layout,
			field_type_layout,
			access,
			base_binding,
		) {
			return false
		}
		reflected_field_count += 1
	}
	if reflected_field_count == 0 {
		fmt.eprintln("StructuredBuffer wrapper does not contain reflected buffer fields")
		return false
	}
	return true
}

ez_gfx_shader_add_structured_buffer_binding :: proc(
	program: ^Ez_Gfx_Shader_Program,
	name: cstring,
	name_len: int,
	layout: ^sp.VariableLayoutReflection,
	type_layout: ^sp.TypeLayoutReflection,
	access: Ez_Gfx_Buffer_Access,
	binding_offset: u32 = 0,
) -> bool {
	if program.structured_buffer_binding_count >= EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS {
		fmt.eprintln("too many shader structured buffer bindings")
		return false
	}
	binding := &program.structured_buffer_bindings[program.structured_buffer_binding_count]
	if !ez_gfx_copy_shader_target_name(binding.name[:], &binding.name_len, name, name_len) {
		return false
	}
	return ez_gfx_shader_finish_structured_buffer_binding(
		program,
		binding,
		layout,
		type_layout,
		access,
		binding_offset,
	)
}

ez_gfx_shader_add_structured_buffer_binding_bytes :: proc(
	program: ^Ez_Gfx_Shader_Program,
	name: []byte,
	name_len: int,
	layout: ^sp.VariableLayoutReflection,
	type_layout: ^sp.TypeLayoutReflection,
	access: Ez_Gfx_Buffer_Access,
	binding_offset: u32 = 0,
) -> bool {
	if program.structured_buffer_binding_count >= EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS {
		fmt.eprintln("too many shader structured buffer bindings")
		return false
	}
	binding := &program.structured_buffer_bindings[program.structured_buffer_binding_count]
	if !ez_gfx_copy_shader_target_name(binding.name[:], &binding.name_len, cast(cstring)raw_data(name), name_len) {
		return false
	}
	return ez_gfx_shader_finish_structured_buffer_binding(
		program,
		binding,
		layout,
		type_layout,
		access,
		binding_offset,
	)
}

ez_gfx_shader_finish_structured_buffer_binding :: proc(
	program: ^Ez_Gfx_Shader_Program,
	binding: ^Ez_Gfx_Structured_Buffer_Binding,
	layout: ^sp.VariableLayoutReflection,
	type_layout: ^sp.TypeLayoutReflection,
	access: Ez_Gfx_Buffer_Access,
	binding_offset: u32,
) -> bool {
	_ = type_layout
	binding.access = access
	binding.binding = binding_offset + sp.variable_layout_getBindingIndex(layout)
	binding_space_category := sp.ParameterCategory.ShaderResource
	if binding.access == .Write || binding.access == .Read_Write {
		binding_space_category = .UnorderedAccess
	}
	binding.set = u32(sp.variable_layout_getBindingSpace(layout, binding_space_category))
	if binding.set != 0 {
		fmt.eprintln("only descriptor set 0 is supported for structured buffers")
		return false
	}
	binding.stages = ez_gfx_shader_desc_stage_flags(program)
	program.structured_buffer_binding_count += 1
	return true
}

ez_gfx_shader_try_reflect_structured_buffer_access :: proc(
	type_layout: ^sp.TypeLayoutReflection,
	access: ^Ez_Gfx_Buffer_Access,
) -> bool {
	if type_layout == nil do return false
	#partial switch sp.type_layout_getResourceAccess(type_layout) {
	case .READ:
		access^ = .Read
		return true
	case .READ_WRITE:
		access^ = .Read_Write
		return true
	case .WRITE:
		access^ = .Write
		return true
	}
	return false
}

ez_gfx_shader_reflect_structured_buffer_access :: proc(
	type_layout: ^sp.TypeLayoutReflection,
	access: ^Ez_Gfx_Buffer_Access,
) -> bool {
	if type_layout == nil {
		fmt.eprintln("StructuredBuffer reflection is missing type layout")
		return false
	}
	if ez_gfx_shader_try_reflect_structured_buffer_access(type_layout, access) do return true
	fmt.eprintln("StructuredBuffer must reflect as StructuredBuffer or RWStructuredBuffer")
	return false
}

ez_gfx_shader_reflect_target_declarations_from_layout :: proc(
	program_layout: ^sp.ProgramLayout,
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	if program.desc.kind == .Compute do return true
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

	global_params := sp.program_layout_getGlobalParamsVarLayout(program_layout)
	if global_params == nil do return true

	global_type_layout := sp.variable_layout_getTypeLayout(global_params)
	field_count := sp.type_layout_getFieldCount(global_type_layout)
	for i in 0 ..< field_count {
		field_layout := sp.type_layout_getFieldByIndex(global_type_layout, i)
		if field_layout == nil do continue

		field_variable := sp.variable_layout_getVariable(field_layout)
		if field_variable == nil do continue

		scale_attribute := sp.variable_findAttributeByName(
			field_variable,
			ctx.slang_session,
			SLANG_RELATIVE_SCALE_ATTRIBUTE,
		)
		if scale_attribute == nil do continue

		if program.target_declaration_count >= EZ_GFX_MAX_SHADER_TARGET_DECLARATIONS {
			fmt.eprintln("too many shader render target declarations")
			return false
		}
		if sp.ReflectionUserAttribute_GetArgumentCount(scale_attribute) != 1 {
			fmt.eprintln("RelativeScale attribute requires one float argument")
			return false
		}

		relative_scale: f32
		if !ez_gfx_slang_check(
			sp.ReflectionUserAttribute_GetArgumentValueFloat(scale_attribute, 0, &relative_scale),
		) {
			fmt.eprintln("RelativeScale attribute argument must be a float")
			return false
		}
		if relative_scale <= 0 {
			fmt.eprintln("RelativeScale must be greater than zero")
			return false
		}

		layout_attribute := sp.variable_findAttributeByName(
			field_variable,
			ctx.slang_session,
			SLANG_TARGET_LAYOUT_ATTRIBUTE,
		)
		if layout_attribute == nil {
			fmt.eprintln("render target declaration is missing TargetLayout")
			return false
		}
		if sp.ReflectionUserAttribute_GetArgumentCount(layout_attribute) != 2 {
			fmt.eprintln("TargetLayout attribute requires kind and format strings")
			return false
		}

		kind_len, format_len: uint
		kind_name := sp.ReflectionUserAttribute_GetArgumentValueString(
			layout_attribute,
			0,
			&kind_len,
		)
		format_name := sp.ReflectionUserAttribute_GetArgumentValueString(
			layout_attribute,
			1,
			&format_len,
		)
		if kind_name == nil || format_name == nil {
			fmt.eprintln("TargetLayout arguments must be strings")
			return false
		}

		load_attribute := sp.variable_findAttributeByName(
			field_variable,
			ctx.slang_session,
			SLANG_LOAD_TARGET_ATTRIBUTE,
		)
		load_on_frame_begin := false
		if load_attribute != nil {
			if sp.ReflectionUserAttribute_GetArgumentCount(load_attribute) != 0 {
				fmt.eprintln("LoadTarget attribute does not take arguments")
				return false
			}
			load_on_frame_begin = true
		}

		declaration := &program.target_declarations[program.target_declaration_count]
		field_name := sp.variable_layout_getName(field_layout)
		if field_name == nil {
			fmt.eprintln("render target declaration has no reflected name")
			return false
		}
		if !ez_gfx_copy_shader_target_name_cstring(
			declaration.name[:],
			&declaration.name_len,
			field_name,
		) {
			return false
		}
		if ez_gfx_shader_find_target_declaration(
			   program,
			   declaration.name[:],
			   declaration.name_len,
		   ) !=
		   nil {
			fmt.eprintln("duplicate render target declaration")
			return false
		}
		declaration.relative_scale = relative_scale
		if !ez_gfx_shader_parse_target_layout(
			kind_name,
			int(kind_len),
			format_name,
			int(format_len),
			&declaration.kind,
			&declaration.format,
		) {
			return false
		}
		field_type_layout := sp.variable_layout_getTypeLayout(field_layout)
		declaration.storage = ez_gfx_shader_target_declaration_is_storage(field_type_layout)
		if declaration.storage && declaration.kind != .Color {
			fmt.eprintln("RW render targets currently support color targets only")
			return false
		}
		declaration.binding = sp.variable_layout_getBindingIndex(field_layout)
		binding_category := declaration.storage ? sp.LayoutUnit.UnorderedAccess : sp.LayoutUnit.ShaderResource
		declaration.set = u32(sp.variable_layout_getBindingSpace(field_layout, binding_category))
		declaration.load_on_frame_begin = load_on_frame_begin
		if declaration.set != 0 {
			fmt.eprintln("only descriptor set 0 is supported for render targets")
			return false
		}
		program.target_declaration_count += 1
	}

	return true
}

ez_gfx_shader_target_declaration_is_storage :: proc(type_layout: ^sp.TypeLayoutReflection) -> bool {
	if type_layout == nil do return false
	return sp.type_layout_getResourceAccess(type_layout) == .READ_WRITE ||
	       sp.type_layout_getResourceAccess(type_layout) == .WRITE
}

ez_gfx_shader_reflect_target_usages_from_layout :: proc(
	program_layout: ^sp.ProgramLayout,
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	if program.desc.kind == .Compute do return true
	vertex_entry := sp.program_layout_findEntryPointByName(
		program_layout,
		program.desc.vertex_entry,
	)
	if vertex_entry == nil {
		fmt.eprintf("missing reflected vertex entry point: %v\n", program.desc.vertex_entry)
		return false
	}
	if !ez_gfx_shader_reflect_entry_function_target_usage(
		vertex_entry,
		program,
		SLANG_DEPTH_TARGET_ATTRIBUTE,
		.Vertex,
		false,
	) {
		return false
	}

	fragment_entry := sp.program_layout_findEntryPointByName(
		program_layout,
		program.desc.fragment_entry,
	)
	if fragment_entry == nil {
		fmt.eprintf("missing reflected fragment entry point: %v\n", program.desc.fragment_entry)
		return false
	}
	if !ez_gfx_shader_reflect_fragment_color_targets(fragment_entry, program) {
		return false
	}
	if !ez_gfx_shader_reflect_fragment_blend_mode(fragment_entry, program) {
		return false
	}
	if !ez_gfx_shader_reflect_entry_function_target_usage(
		fragment_entry,
		program,
		SLANG_DEPTH_TARGET_ATTRIBUTE,
		.Fragment,
		false,
	) {
		return false
	}
	return true
}

ez_gfx_shader_reflect_fragment_blend_mode :: proc(
	entry: ^sp.EntryPointReflection,
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

	function := sp.entry_point_getFunction(entry)
	if function == nil do return true

	attribute := sp.function_findAttributeByName(function, ctx.slang_session, SLANG_BLEND_MODE_ATTRIBUTE)
	if attribute == nil do return true
	if sp.ReflectionUserAttribute_GetArgumentCount(attribute) != 1 {
		fmt.eprintln("BlendMode attribute requires one string mode argument")
		return false
	}

	mode_len: uint
	mode := sp.ReflectionUserAttribute_GetArgumentValueString(attribute, 0, &mode_len)
	if mode == nil {
		fmt.eprintln("BlendMode attribute argument must be a string")
		return false
	}
	mode_bytes := cast([^]byte)mode
	if ez_gfx_shader_target_name_equals_cstring(mode_bytes[:mode_len], int(mode_len), "alpha") {
		program.blend_mode = .Alpha
		return true
	}
	fmt.eprintf("unsupported BlendMode value: %.*s\n", mode_len, mode)
	return false
}

ez_gfx_shader_reflect_entry_function_target_usage :: proc(
	entry: ^sp.EntryPointReflection,
	program: ^Ez_Gfx_Shader_Program,
	attribute_name: cstring,
	stage: Ez_Gfx_Shader_Stage,
	core: bool,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

	function := sp.entry_point_getFunction(entry)
	if function == nil do return true

	attribute := sp.function_findAttributeByName(function, ctx.slang_session, attribute_name)
	if attribute == nil do return true

	if program.target_usage_count >= EZ_GFX_MAX_SHADER_TARGET_USAGES {
		fmt.eprintln("too many shader render target usages")
		return false
	}
	if sp.ReflectionUserAttribute_GetArgumentCount(attribute) != 2 {
		fmt.eprintln("target usage attributes require target name and access strings")
		return false
	}

	name_len, access_len: uint
	name := sp.ReflectionUserAttribute_GetArgumentValueString(attribute, 0, &name_len)
	access := sp.ReflectionUserAttribute_GetArgumentValueString(attribute, 1, &access_len)
	if name == nil || access == nil {
		fmt.eprintln("target usage arguments must be strings")
		return false
	}

	usage := &program.target_usages[program.target_usage_count]
	if !ez_gfx_copy_shader_target_name(usage.name[:], &usage.name_len, name, int(name_len)) {
		return false
	}
	if !ez_gfx_shader_parse_target_access(access, int(access_len), &usage.access) {
		return false
	}
	usage.stage = stage
	usage.core = core
	usage.color_attachment_index = 0
	program.target_usage_count += 1
	return true
}

ez_gfx_shader_reflect_fragment_color_targets :: proc(
	entry: ^sp.EntryPointReflection,
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

	result_layout := sp.entry_point_getResultVarLayout(entry)
	if result_layout == nil do return true

	result_type_layout := sp.variable_layout_getTypeLayout(result_layout)
	if result_type_layout == nil do return true

	field_count := sp.type_layout_getFieldCount(result_type_layout)
	color_index: u32
	for i in 0 ..< field_count {
		field_layout := sp.type_layout_getFieldByIndex(result_type_layout, i)
		if field_layout == nil do continue

		field_variable := sp.variable_layout_getVariable(field_layout)
		if field_variable == nil do continue

		attribute := sp.variable_findAttributeByName(
			field_variable,
			ctx.slang_session,
			SLANG_COLOR_TARGET_ATTRIBUTE,
		)
		if attribute == nil do continue

		if !ez_gfx_shader_reflect_attribute_target_usage(
			attribute,
			program,
			.Fragment,
			true,
			color_index,
		) {
			return false
		}
		color_index += 1
	}
	return true
}

ez_gfx_shader_reflect_attribute_target_usage :: proc(
	attribute: ^sp.Attribute,
	program: ^Ez_Gfx_Shader_Program,
	stage: Ez_Gfx_Shader_Stage,
	core: bool,
	color_attachment_index: u32,
) -> bool {
	if program.target_usage_count >= EZ_GFX_MAX_SHADER_TARGET_USAGES {
		fmt.eprintln("too many shader render target usages")
		return false
	}
	if sp.ReflectionUserAttribute_GetArgumentCount(attribute) != 2 {
		fmt.eprintln("target usage attributes require target name and access strings")
		return false
	}

	name_len, access_len: uint
	name := sp.ReflectionUserAttribute_GetArgumentValueString(attribute, 0, &name_len)
	access := sp.ReflectionUserAttribute_GetArgumentValueString(attribute, 1, &access_len)
	if name == nil || access == nil {
		fmt.eprintln("target usage arguments must be strings")
		return false
	}

	usage := &program.target_usages[program.target_usage_count]
	if !ez_gfx_copy_shader_target_name(usage.name[:], &usage.name_len, name, int(name_len)) {
		return false
	}
	if !ez_gfx_shader_parse_target_access(access, int(access_len), &usage.access) {
		return false
	}
	usage.stage = stage
	usage.core = core
	usage.color_attachment_index = color_attachment_index
	program.target_usage_count += 1
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

ez_gfx_copy_shader_target_name :: proc(
	dst: []byte,
	dst_len: ^int,
	name: cstring,
	name_len: int,
) -> bool {
	if name_len >= EZ_GFX_SHADER_TARGET_NAME_MAX {
		fmt.eprintln("shader target name is too long")
		return false
	}

	for i in 0 ..< len(dst) {
		dst[i] = 0
	}
	name_bytes := cast([^]byte)name
	for i in 0 ..< name_len {
		dst[i] = name_bytes[i]
	}
	dst_len^ = name_len
	return true
}

ez_gfx_copy_shader_target_name_cstring :: proc(dst: []byte, dst_len: ^int, name: cstring) -> bool {
	name_len := 0
	bytes := cast([^]byte)name
	for bytes[name_len] != 0 {
		name_len += 1
	}
	return ez_gfx_copy_shader_target_name(dst, dst_len, name, name_len)
}

ez_gfx_copy_shader_target_name_with_suffix :: proc(
	dst: []byte,
	dst_len: ^int,
	base: cstring,
	base_len: int,
	suffix: cstring,
	suffix_len: int,
) -> bool {
	name_len := base_len + 1 + suffix_len
	if name_len >= EZ_GFX_SHADER_TARGET_NAME_MAX {
		fmt.eprintln("shader target name is too long")
		return false
	}

	for i in 0 ..< len(dst) {
		dst[i] = 0
	}
	base_bytes := cast([^]byte)base
	for i in 0 ..< base_len {
		dst[i] = base_bytes[i]
	}
	dst[base_len] = '.'
	suffix_bytes := cast([^]byte)suffix
	for i in 0 ..< suffix_len {
		dst[base_len + 1 + i] = suffix_bytes[i]
	}
	dst_len^ = name_len
	return true
}

ez_gfx_shader_target_name_equals_cstring :: proc(
	name: []byte,
	name_len: int,
	other: cstring,
) -> bool {
	other_bytes := cast([^]byte)other
	for i in 0 ..< name_len {
		if other_bytes[i] == 0 || name[i] != other_bytes[i] do return false
	}
	return other_bytes[name_len] == 0
}

ez_gfx_shader_target_name_equals_bytes :: proc(
	a: []byte,
	a_len: int,
	b: []byte,
	b_len: int,
) -> bool {
	if a_len != b_len do return false
	for i in 0 ..< a_len {
		if a[i] != b[i] do return false
	}
	return true
}

ez_gfx_shader_cstring_arg_equals :: proc(
	value: cstring,
	value_len: int,
	expected: string,
) -> bool {
	if value_len != len(expected) do return false
	bytes := cast([^]byte)value
	for i in 0 ..< len(expected) {
		if bytes[i] != expected[i] do return false
	}
	return true
}

ez_gfx_shader_parse_target_access :: proc(
	value: cstring,
	value_len: int,
	access: ^Ez_Gfx_Target_Access,
) -> bool {
	if ez_gfx_shader_cstring_arg_equals(value, value_len, "read") {
		access^ = .Read
		return true
	}
	if ez_gfx_shader_cstring_arg_equals(value, value_len, "write") {
		access^ = .Write
		return true
	}
	if ez_gfx_shader_cstring_arg_equals(value, value_len, "read_write") {
		access^ = .Read_Write
		return true
	}
	fmt.eprintln("target access must be read, write, or read_write")
	return false
}

ez_gfx_shader_parse_buffer_access :: proc(
	value: cstring,
	value_len: int,
	access: ^Ez_Gfx_Buffer_Access,
) -> bool {
	if ez_gfx_shader_cstring_arg_equals(value, value_len, "read") {
		access^ = .Read
		return true
	}
	if ez_gfx_shader_cstring_arg_equals(value, value_len, "write") {
		access^ = .Write
		return true
	}
	if ez_gfx_shader_cstring_arg_equals(value, value_len, "read_write") {
		access^ = .Read_Write
		return true
	}
	fmt.eprintln("structured buffer access must be read, write, or read_write")
	return false
}

ez_gfx_shader_desc_stage_flags :: proc(program: ^Ez_Gfx_Shader_Program) -> vk.ShaderStageFlags {
	if program.desc.kind == .Compute {
		return {.COMPUTE}
	}
	return {.VERTEX, .FRAGMENT}
}

ez_gfx_shader_parse_target_layout :: proc(
	kind_value: cstring,
	kind_len: int,
	format_value: cstring,
	format_len: int,
	kind: ^Ez_Gfx_Render_Target_Kind,
	format: ^vk.Format,
) -> bool {
	if ez_gfx_shader_cstring_arg_equals(kind_value, kind_len, "depth") {
		kind^ = .Depth
		if ez_gfx_shader_cstring_arg_equals(format_value, format_len, "d32_float") {
			format^ = .D24_UNORM_S8_UINT
			return true
		}
		fmt.eprintln("unsupported depth target format")
		return false
	}
	if ez_gfx_shader_cstring_arg_equals(kind_value, kind_len, "color") {
		kind^ = .Color
		if ez_gfx_shader_cstring_arg_equals(format_value, format_len, "rgba8") {
			format^ = .R8G8B8A8_UNORM
			return true
		}
		if ez_gfx_shader_cstring_arg_equals(format_value, format_len, "rgba16f") {
			format^ = .R16G16B16A16_SFLOAT
			return true
		}
		fmt.eprintln("unsupported color target format")
		return false
	}
	fmt.eprintln("TargetLayout kind must be color or depth")
	return false
}

ez_gfx_shader_find_target_declaration :: proc(
	program: ^Ez_Gfx_Shader_Program,
	name: []byte,
	name_len: int,
) -> ^Ez_Gfx_Shader_Target_Declaration {
	for i in 0 ..< program.target_declaration_count {
		declaration := &program.target_declarations[i]
		if ez_gfx_shader_target_name_equals_bytes(
			declaration.name[:],
			declaration.name_len,
			name,
			name_len,
		) {
			return declaration
		}
	}
	return nil
}

ez_gfx_shader_validate_unique_target_declarations :: proc(
	program: ^Ez_Gfx_Shader_Program,
) -> bool {
	for i in 0 ..< program.target_declaration_count {
		a := &program.target_declarations[i]
		for j in i + 1 ..< program.target_declaration_count {
			b := &program.target_declarations[j]
			if ez_gfx_shader_target_name_equals_bytes(
				a.name[:],
				a.name_len,
				b.name[:],
				b.name_len,
			) {
				fmt.eprintln("duplicate render target declaration")
				return false
			}
		}
	}
	return true
}

ez_gfx_shader_validate_targets :: proc(program: ^Ez_Gfx_Shader_Program) -> bool {
	if !ez_gfx_shader_validate_unique_target_declarations(program) {
		return false
	}
	for i in 0 ..< program.target_usage_count {
		usage := &program.target_usages[i]
		if ez_gfx_shader_target_name_equals_cstring(usage.name[:], usage.name_len, "swapchain") {
			if usage.access != .Write {
				fmt.eprintln("swapchain target currently supports write access only")
				return false
			}
			continue
		}

		declaration := ez_gfx_shader_find_target_declaration(
			program,
			usage.name[:],
			usage.name_len,
		)
		if declaration == nil {
			fmt.eprintln("shader target usage is missing a matching texture declaration")
			return false
		}
		if usage.core && declaration.kind != .Color {
			fmt.eprintln("ColorTarget must reference a color target declaration")
			return false
		}
		if usage.core && usage.access == .Read_Write {
			fmt.eprintln(
				"managed ColorTarget read_write would require an unsupported attachment feedback loop",
			)
			return false
		}
		if !usage.core && declaration.kind != .Depth {
			fmt.eprintln("DepthTarget must reference a depth target declaration")
			return false
		}
	}
	return true
}
