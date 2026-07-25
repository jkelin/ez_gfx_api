package ez_gfx

// These records deliberately keep all ABI-facing state behind opaque handles.
// The parent application owns the native window; this layer owns only the Vulkan surface.

Ez_Gfx_C_Context :: struct {
	ctx:                       Ez_Gfx_Ctx,
	texture_data:              [dynamic][]u8,
	imgui_context:              rawptr,
	imgui_shader:               Ez_Gfx_Shader_Program,
	imgui_shader_loaded:        bool,
	imgui_font_texture_id:      Ez_Gfx_Texture_ID,
	imgui_font_texture_loaded:  bool,
	imgui_font_atlas_pixels:    []u8,
	imgui_texture_data:         [dynamic][]u8,
	imgui_identity_index_start: u32,
	imgui_identity_index_loaded: bool,
}
Ez_Gfx_C_Surface :: struct {
	owner:   ^Ez_Gfx_C_Context,
	surface: Ez_Gfx_Window,
}

Ez_Gfx_C_Shader :: struct {
	owner:       ^Ez_Gfx_C_Context,
	shader:      Ez_Gfx_Shader_Program,
	string_data: [4][]u8,
}

Ez_Gfx_C_Indirect :: struct {
	owner:  ^Ez_Gfx_C_Context,
	handle: Ez_Gfx_Indirect_Buffer_Handle,
}

Ez_Gfx_C_Structured :: struct {
	owner:  ^Ez_Gfx_C_Context,
	handle: Ez_Gfx_Structured_Buffer_Handle,
}

Ez_Gfx_C_Context_Desc :: struct {
	enable_debug:      i32,
	enable_validation: i32,
	surface_platform:  u32,
}

Ez_Gfx_C_Surface_Desc :: struct {
	window:  rawptr,
	display: rawptr,
	platform: u32,
	width:   u32,
	height:  u32,
}

Ez_Gfx_C_Shader_Desc :: struct {
	path:           cstring,
	vertex_entry:   cstring,
	fragment_entry: cstring,
	compute_entry:  cstring,
	kind:           u32,
}

Ez_Gfx_C_Texture_Desc :: struct {
	source_format:      u32,
	destination_format: u32,
	width:              u32,
	height:             u32,
	mip_count:          u32,
	generate_mips:      i32,
	min_filter:         u32,
	mag_filter:         u32,
	max_anisotropy:     f32,
	address_mode_u:     u32,
	address_mode_v:     u32,
	address_mode_w:     u32,
	debug_label:        cstring,
}

Ez_Gfx_C_Binding :: struct {
	name:       cstring,
	structured: u64,
	indirect:   u64,
}

Ez_Gfx_C_Dynamic_State :: struct {
	cull_mode:      u32,
	front_face:     u32,
	primitive_type: u32,
	blend_mode:     u32,
}

Ez_Gfx_C_Draw_Indexed_Command :: struct {
	index_count:    u32,
	instance_count: u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}
