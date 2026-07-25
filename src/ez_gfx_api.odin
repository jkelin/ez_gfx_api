package ez_gfx

import sp "../vendor/odin-slang/slang"
import vma "../vendor/odin-vma"
import "base:runtime"
import "core:c"
import "core:mem"
import "core:sync"
import "core:thread"
import im "../vendor/odin-imgui"
import vk "vendor:vulkan"

// Public C ABI descriptors live beside private opaque-owner bookkeeping.
@(private)
Ez_Gfx_C_Context :: struct {
	opaque_handle:             u64,
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

@(private)
Ez_Gfx_C_Surface :: struct {
	opaque_handle: u64,
	owner:   ^Ez_Gfx_C_Context,
	surface: Ez_Gfx_Window,
}

@(private)
Ez_Gfx_C_Shader :: struct {
	opaque_handle: u64,
	owner:       ^Ez_Gfx_C_Context,
	shader:      Ez_Gfx_Shader_Program,
	string_data: [4][]u8,
}

@(private)
Ez_Gfx_C_Indirect :: struct {
	opaque_handle: u64,
	owner:  ^Ez_Gfx_C_Context,
	handle: Ez_Gfx_Indirect_Buffer_Handle,
}

@(private)
Ez_Gfx_C_Structured :: struct {
	opaque_handle: u64,
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


Ez_Gfx_Buffer :: struct {
	handle:          vk.Buffer,
	allocation:      vma.Allocation,
	allocation_info: vma.Allocation_Info,
	size:            vk.DeviceSize,
	mapped_data:     rawptr,
}

// C ABI ImGui push-constant layout.
Ez_Gfx_C_ImGui_Push_Constants :: struct {
	display_size: [2]f32,
}

// C ABI ImGui vertex layout.
Ez_Gfx_C_ImGui_Vertex :: struct {
	pos:   im.Vec2,
	uv:    im.Vec2,
	col:   u32,
	_pad0: u32,
	_pad1: u32,
	_pad2: u32,
}

// C ABI ImGui indirect command layout.
Ez_Gfx_C_ImGui_Draw_Command :: struct {
	clip_rect:  [4]f32,
	texture_id: u32,
	idx_offset: u32,
	vtx_offset: u32,
	_pad:       u32,
}


// Moved from src\ctx.odin:19.
Ez_Gfx_Frame_Slot :: struct {
	command_buffers:         [EZ_GFX_FRAME_COMMAND_BUFFERS]vk.CommandBuffer,
	image_available:         vk.Semaphore,
	last_submitted_timeline: u64,
}

// Moved from src\ctx.odin:25.
Ez_Gfx_Validation_Message :: struct {
	severity:        vk.DebugUtilsMessageSeverityFlagsEXT,
	message_type:    vk.DebugUtilsMessageTypeFlagsEXT,
	message_id_name: cstring,
	message:         cstring,
}

// Moved from src\ctx.odin:32.
Ez_Gfx_Validation_Callback :: #type proc(
	ctx: ^Ez_Gfx_Ctx,
	message: Ez_Gfx_Validation_Message,
	user_data: rawptr,
)

// Moved from src\ctx.odin:38.
Ez_Gfx_Ctx_Desc :: struct {
	enable_validation:    bool,
	validation_callback:  Ez_Gfx_Validation_Callback,
	validation_user_data: rawptr,
	enable_debug:         bool,
	texture_loaded_callback:  Ez_Gfx_Texture_Loaded_Callback,
	texture_loaded_user_data: rawptr,
	vertex_uploaded_callback:  Ez_Gfx_Vertex_Uploaded_Callback,
	vertex_uploaded_user_data: rawptr,
	texture_decode_worker_count: u32,
	surface_platform: u32,
	instance_extensions: []cstring,
}

// Moved from src\ctx.odin:52.
Ez_Gfx_Validation_Counts :: struct {
	verbose: u32,
	info:    u32,
	warning: u32,
	error:   u32,
}

// Moved from src\ctx.odin:59.
Ez_Gfx_Ctx_Info :: struct {
	swapchain_present_modes:      [EZ_GFX_MAX_PRESENT_MODES]vk.PresentModeKHR,
	swapchain_present_mode_count: u32,
	swapchain_present_mode:       vk.PresentModeKHR,
}

// Moved from src\ctx.odin:65.
Ez_Gfx_Ctx :: struct {
	instance:                             vk.Instance,
	surface_platform:                    u32,
	debug_messenger:                      vk.DebugUtilsMessengerEXT,
	physical_device:                      vk.PhysicalDevice,
	device:                               vk.Device,
	queue_family_index:                   u32,
	transfer_queue_family_index:          u32,
	graphics_queue:                       vk.Queue,
	transfer_queue:                       vk.Queue,
	queue_mutex:                          sync.Mutex,
	command_pool:                         vk.CommandPool,
	frame_slots:                          [EZ_GFX_FRAMES_IN_FLIGHT]Ez_Gfx_Frame_Slot,
	current_frame_slot:                   u32,
	render_frame_counter:                 u64,
	timeline_semaphore:                   vk.Semaphore,
	timeline_counter:                     u64,
	vma_vulkan_functions:                 vma.Vulkan_Functions,
	vma_allocator:                        vma.Allocator,
	slang_session:                        ^sp.IGlobalSession,
	vertex_manager:                       Ez_Gfx_Vertex_Manager,
	texture_manager:                      Ez_Gfx_Texture_Manager,
	pipeline_manager:                     Ez_Gfx_Pipeline_Manager,
	indirect_manager:                     Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager,
	structured_buffer_manager:            Ez_Gfx_Structured_Buffer_Manager,
	render_target_manager:                Ez_Gfx_Render_Target_Manager,
	max_sampler_anisotropy:               f32,
	min_storage_buffer_offset_alignment:  vk.DeviceSize,
	enable_validation:                    bool,
	enable_debug:                         bool,
	debug_utils_enabled:                  bool,
	memory_priority_enabled:              bool,
	sampler_anisotropy_enabled:            bool,
	pageable_device_local_memory_enabled: bool,
	present_mode_fifo_latest_enabled:     bool,
	shared_presentable_image_enabled:     bool,
	swapchain_present_mode:               vk.PresentModeKHR,
	swapchain_present_modes:              [EZ_GFX_MAX_PRESENT_MODES]vk.PresentModeKHR,
	swapchain_present_mode_count:         u32,
	validation_callback:                  Ez_Gfx_Validation_Callback,
	validation_user_data:                 rawptr,
	texture_loaded_callback:              Ez_Gfx_Texture_Loaded_Callback,
	texture_loaded_user_data:             rawptr,
	vertex_uploaded_callback:             Ez_Gfx_Vertex_Uploaded_Callback,
	vertex_uploaded_user_data:            rawptr,
	texture_decode_worker_count:          u32,
	validation_counts:                    Ez_Gfx_Validation_Counts,
	render:                              Ez_Gfx_Render,
}

// Moved from src\indirect_buffer.odin:9.
Ez_Gfx_Multi_Draw_Indirect_Buffer :: struct {
	buffer:             Ez_Gfx_Buffer,
	stride:             vk.DeviceSize,
	draw_offset:        vk.DeviceSize,
	capacity:           u32,
	in_use:             bool,
	last_used_timeline: u64,
}

// Moved from src\indirect_buffer.odin:18.
Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager :: struct {
	buffers: [EZ_GFX_MAX_INDIRECT_BUFFERS]Ez_Gfx_Multi_Draw_Indirect_Buffer,
	count:   int,
}

// Moved from src\indirect_buffer.odin:23.
Ez_Gfx_Indirect_Buffer_Handle :: struct {
	buffer:   ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	stride:   vk.DeviceSize,
	capacity: u32,
	frame_id: u64,
	ok:       bool,
}

// Moved from src\indirect_buffer.odin:31.
Ez_Gfx_Vertex_Pipeline_Descriptor :: struct {
	pipeline:           ^Ez_Gfx_Pipeline_Record,
	descriptor_set_index: int,
	dynamic_state:      Ez_Gfx_Render_Dynamic_State,
	indirect_buffer:    ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	indirect_stride:    vk.DeviceSize,
	indirect_count:     u32,
	push_constant_size: u32,
	push_constant_data: [EZ_GFX_MAX_PUSH_CONSTANT_BYTES]byte,
	ok:                 bool,
}

// Moved from src\pipeline.odin:14.
Ez_Gfx_Pipeline_Record :: struct {
	kind:                  Ez_Gfx_Shader_Kind,
	shader_identity:       u64,
	shader:                ^Ez_Gfx_Shader_Program,
	blend_mode:            Ez_Gfx_Blend_Mode,
	color_formats:         [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.Format,
	color_format_count:    int,
	depth_format:          vk.Format,
	has_depth:             bool,
	pipeline_layout:       vk.PipelineLayout,
	pipeline:              vk.Pipeline,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_pool:       vk.DescriptorPool,
	descriptor_sets:       [EZ_GFX_MAX_PIPELINE_DESCRIPTOR_SETS]vk.DescriptorSet,
	descriptor_versions:   [EZ_GFX_MAX_PIPELINE_DESCRIPTOR_SETS]u64,
	last_used:             u64,
}

// Moved from src\pipeline.odin:31.
Ez_Gfx_Primitive_Type :: enum u8 {
	Triangle_List,
	Point_List,
	Line_List,
	Line_Strip,
	Triangle_Strip,
	Triangle_Fan,
}

// Moved from src\pipeline.odin:42.
Ez_Gfx_Render_Dynamic_State :: struct {
	cull_mode:      vk.CullModeFlags,
	front_face:     vk.FrontFace,
	primitive_type: Ez_Gfx_Primitive_Type,
	blend_mode:     Ez_Gfx_Blend_Mode,
}

// Moved from src\pipeline.odin:69.
Ez_Gfx_Pipeline_Manager :: struct {
	records: [EZ_GFX_MAX_PIPELINES]Ez_Gfx_Pipeline_Record,
	count:   int,
	clock:   u64,
}

// Moved from src\pipeline.odin:75.
Ez_Gfx_Compute_Pipeline_Descriptor :: struct {
	pipeline:           ^Ez_Gfx_Pipeline_Record,
	descriptor_set_index: int,
	dispatch_x:         u32,
	dispatch_y:         u32,
	dispatch_z:         u32,
	push_constant_size: u32,
	push_constant_data: [EZ_GFX_MAX_PUSH_CONSTANT_BYTES]byte,
	ok:                 bool,
}

// Moved from src\render.odin:12.
Ez_Gfx_Render :: struct {
	ctx:                          ^Ez_Gfx_Ctx,
	window:                       ^Ez_Gfx_Window,
	frame:                        ^Ez_Gfx_Frame_Slot,
	frame_slot:                   u32,
	image_index:                  u32,
	timeline_end:                 u64,
	frame_id:                     u64,
	texture_upload_wait_timeline: u64,
	vertex_upload_wait_timeline:  u64,
	graph:                        Ez_Gfx_Render_Graph,
	pipeline_count:               int,
	active:                       bool,
	ready:                        bool,
}

// Moved from src\render_graph.odin:14.
Ez_Gfx_Render_Graph_Resource_Kind :: enum u8 {
	Managed,
	Swapchain,
	Structured_Buffer,
}

// Moved from src\render_graph.odin:20.
Ez_Gfx_Render_Graph_Node_Kind :: enum u8 {
	Graphics,
	Compute,
}

// Moved from src\render_graph.odin:25.
Ez_Gfx_Render_Graph_Access :: struct {
	name:                   [EZ_GFX_SHADER_TARGET_NAME_MAX]byte,
	name_len:               int,
	resource_kind:          Ez_Gfx_Render_Graph_Resource_Kind,
	target_kind:            Ez_Gfx_Render_Target_Kind,
	target:                 ^Ez_Gfx_Render_Target_Texture,
	structured_binding:     ^Ez_Gfx_Node_Buffer_Binding,
	sampled_read:           bool,
	storage_read:           bool,
	storage_write:          bool,
	structured_read:        bool,
	structured_write:       bool,
	color_write:            bool,
	depth_write:            bool,
	color_attachment_index: u32,
}

// Moved from src\render_graph.odin:42.
Ez_Gfx_Render_Graph_Node :: struct {
	kind:            Ez_Gfx_Render_Graph_Node_Kind,
	shader:          ^Ez_Gfx_Shader_Program,
	descriptor:      Ez_Gfx_Vertex_Pipeline_Descriptor,
	compute:         Ez_Gfx_Compute_Pipeline_Descriptor,
	buffer_bindings: [EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS]Ez_Gfx_Node_Buffer_Binding,
	buffer_binding_count: int,
	accesses:        [EZ_GFX_MAX_RENDER_GRAPH_ACCESSES]Ez_Gfx_Render_Graph_Access,
	access_count:    int,
	has_color_write: bool,
	has_depth_write: bool,
	timeline_value:  u64,
}

// Moved from src\render_graph.odin:56.
Ez_Gfx_Render_Graph :: struct {
	nodes:          [EZ_GFX_MAX_RENDER_PIPELINES]Ez_Gfx_Render_Graph_Node,
	node_count:     int,
	swapchain_used: bool,
}

// Moved from src\render_target.odin:10.
Ez_Gfx_Render_Target_Texture :: struct {
	name:                [EZ_GFX_SHADER_TARGET_NAME_MAX]byte,
	name_len:            int,
	image:               vk.Image,
	allocation:          vma.Allocation,
	allocation_info:     vma.Allocation_Info,
	image_view:          vk.ImageView,
	attachment_view:     vk.ImageView,
	sampler:             vk.Sampler,
	format:              vk.Format,
	extent:              vk.Extent2D,
	relative_scale:      f32,
	kind:                Ez_Gfx_Render_Target_Kind,
	layout:              vk.ImageLayout,
	initialized:         bool,
	load_on_frame_begin: bool,
	frame_clear_pending: bool,
	last_write_timeline: u64,
	generation:          u64,
	described:           bool,
	has_image:           bool,
}

// Moved from src\render_target.odin:33.
Ez_Gfx_Render_Target_Manager :: struct {
	targets: [EZ_GFX_MAX_RENDER_TARGETS]Ez_Gfx_Render_Target_Texture,
	count:   int,
	version: u64,
}

// Moved from src\shader.odin:32.
Ez_Gfx_Shader_Stage :: enum u8 {
	Vertex,
	Fragment,
	Compute,
}

// Moved from src\shader.odin:38.
Ez_Gfx_Shader_Kind :: enum u8 {
	Graphics,
	Compute,
}

// Moved from src\shader.odin:43.
Ez_Gfx_Target_Access :: enum u8 {
	Read,
	Write,
	Read_Write,
}

// Moved from src\shader.odin:49.
Ez_Gfx_Render_Target_Kind :: enum u8 {
	Color,
	Depth,
}

// Moved from src\shader.odin:54.
Ez_Gfx_Blend_Mode :: enum u8 {
	None,
	Alpha,
}

// Moved from src\shader.odin:59.
Ez_Gfx_Vertex_Heap_Binding :: struct {
	name:     [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	name_len: int,
	binding:  u32,
	set:      u32,
}

// Moved from src\shader.odin:66.
Ez_Gfx_Structured_Buffer_Binding :: struct {
	name:     [EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte,
	name_len: int,
	binding:  u32,
	set:      u32,
	access:   Ez_Gfx_Buffer_Access,
	stages:   vk.ShaderStageFlags,
}

// Moved from src\shader.odin:75.
Ez_Gfx_Shader_Target_Usage :: struct {
	name:                   [EZ_GFX_SHADER_TARGET_NAME_MAX]byte,
	name_len:               int,
	access:                 Ez_Gfx_Target_Access,
	stage:                  Ez_Gfx_Shader_Stage,
	core:                   bool,
	color_attachment_index: u32,
}

// Moved from src\shader.odin:84.
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

// Moved from src\shader.odin:96.
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

// Moved from src\shader.odin:112.
Ez_Gfx_Shader_Desc :: struct {
	path:           cstring,
	vertex_entry:   cstring,
	fragment_entry: cstring,
	compute_entry:  cstring,
	kind:           Ez_Gfx_Shader_Kind,
}

// Moved from src\shader.odin:121.
Ez_Gfx_Slang_Linked_Program :: struct {
	session:        ^sp.ISession,
	shared_module: ^sp.IModule,
	slang_module:   ^sp.IModule,
	vertex_entry:   ^sp.IEntryPoint,
	fragment_entry: ^sp.IEntryPoint,
	compute_entry:  ^sp.IEntryPoint,
	linked_program: ^sp.IComponentType,
}

// Moved from src\structured_buffer.odin:11.
Ez_Gfx_Buffer_Access :: enum u8 {
	Read,
	Write,
	Read_Write,
}

// Moved from src\structured_buffer.odin:17.
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

// Moved from src\structured_buffer.odin:28.
Ez_Gfx_Structured_Buffer_Manager :: struct {
	buffers:           [EZ_GFX_MAX_STRUCTURED_BUFFERS]Ez_Gfx_Structured_Buffer,
	count:             int,
	version:           u64,
	peak_acquire_size: vk.DeviceSize,
}

// Moved from src\structured_buffer.odin:35.
Ez_Gfx_Structured_Buffer_Handle :: struct {
	buffer:   ^Ez_Gfx_Structured_Buffer,
	cpu_ptr:  rawptr,
	size:     vk.DeviceSize,
	frame_id: u64,
	ok:       bool,
}

// Moved from src\structured_buffer.odin:43.
Ez_Gfx_Structured_Buffer_View :: struct($T: typeid) {
	handle:   Ez_Gfx_Structured_Buffer_Handle,
	elements: [^]T,
}

// Moved from src\structured_buffer.odin:48.
Ez_Gfx_Render_Target_Id :: struct {
	index:      int,
	generation: u64,
	ok:         bool,
}

// Moved from src\structured_buffer.odin:54.
Ez_Gfx_Render_Binding :: struct {
	name:          cstring,
	structured:    Ez_Gfx_Structured_Buffer_Handle,
	indirect:      Ez_Gfx_Indirect_Buffer_Handle,
	render_target: Ez_Gfx_Render_Target_Id,
}

// Moved from src\structured_buffer.odin:61.
Ez_Gfx_Node_Buffer_Binding_Kind :: enum u8 {
	Structured,
	Indirect_Count,
	Indirect_Elements,
}

// Moved from src\structured_buffer.odin:67.
Ez_Gfx_Node_Buffer_Binding :: struct {
	name:              [EZ_GFX_STRUCTURED_BUFFER_NAME_MAX]byte,
	name_len:          int,
	kind:              Ez_Gfx_Node_Buffer_Binding_Kind,
	buffer:            ^Ez_Gfx_Buffer,
	offset:            vk.DeviceSize,
	size:              vk.DeviceSize,
	frame_id:          u64,
	structured_buffer: ^Ez_Gfx_Structured_Buffer,
	indirect_buffer:   ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	indirect_stride:   vk.DeviceSize,
	indirect_capacity: u32,
}

// Moved from src\swapchain.odin:11.
Ez_Gfx_Swapchain :: struct {
	handle:               vk.SwapchainKHR,
	format:               vk.Format,
	extent:               vk.Extent2D,
	present_mode:         vk.PresentModeKHR,
	images:               [MAX_SWAPCHAIN_IMAGES]vk.Image,
	image_views:          [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
	image_layouts:        [MAX_SWAPCHAIN_IMAGES]vk.ImageLayout,
	last_write_timeline:  [MAX_SWAPCHAIN_IMAGES]u64,
	present_ready:        [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
	image_count:          u32,
	last_presented_index: u32,
	has_presented_image:  bool,
	presented_snapshot_pixels: []u8,
	presented_snapshot_valid:  bool,
}

// Moved from src\texture_manager.odin:23.
Ez_Gfx_Texture_ID :: distinct u32

// Moved from src\texture_manager.odin:25.
Ez_Gfx_Source_Texture_Format :: enum u8 {
	RGB,
	RGBA,
	BMP,
	JPEG,
	PNG,
	TGA,
	KTX2,
}

// Moved from src\texture_manager.odin:35.
Ez_Gfx_Texture_Error :: enum u8 {
	None,
	Invalid_Context,
	Invalid_Arguments,
	Unsupported_Format,
	Out_Of_Texture_Handles,
	Out_Of_Memory,
	Decode_Failed,
	Vulkan_Failed,
	Worker_Unavailable,
	Not_Found,
}

// Moved from src\texture_manager.odin:48.
Ez_Gfx_Texture_Memory_Region :: struct {
	data: []u8,
}

// Moved from src\texture_manager.odin:52.
Ez_Gfx_Texture_Filter :: enum u8 {
	Nearest,
	Linear,
}

// Moved from src\texture_manager.odin:57.
Ez_Gfx_Texture_Address_Mode :: enum u8 {
	Repeat,
	Clamp_To_Edge,
}

// Moved from src\texture_manager.odin:62.
Ez_Gfx_Load_Texture_Desc :: struct {
	source_format:      Ez_Gfx_Source_Texture_Format,
	destination_format: vk.Format,
	width:              u32,
	height:             u32,
	mip_count:          u32,
	generate_mips:      bool,
	min_filter:         Ez_Gfx_Texture_Filter,
	mag_filter:         Ez_Gfx_Texture_Filter,
	max_anisotropy:     f32,
	address_mode_u:     Ez_Gfx_Texture_Address_Mode,
	address_mode_v:     Ez_Gfx_Texture_Address_Mode,
	address_mode_w:     Ez_Gfx_Texture_Address_Mode,
	debug_label:        string,
}

// Moved from src\texture_manager.odin:78.
Ez_Gfx_Texture_Loaded_Callback :: #type proc(
	ctx: ^Ez_Gfx_Ctx,
	texture_id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
	user_data: rawptr,
)

// Moved from src\texture_manager.odin:84.
Ez_Gfx_Image_Decoder_Callback :: #type proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job

// Moved from src\texture_manager.odin:88.
Ez_Gfx_Texture_State :: enum u8 {
	Empty,
	Queued,
	Loading,
	Ready,
	Failed,
	Unloading,
}

// Moved from src\texture_manager.odin:97.
Ez_Gfx_Texture_Record :: struct {
	id:                 Ez_Gfx_Texture_ID,
	state:              Ez_Gfx_Texture_State,
	image:              vk.Image,
	allocation:         vma.Allocation,
	allocation_info:    vma.Allocation_Info,
	image_view:         vk.ImageView,
	sampler:            vk.Sampler,
	format:             vk.Format,
	width:              u32,
	height:             u32,
	mip_count:          u32,
	layout:             vk.ImageLayout,
	last_write_timeline: u64,
	last_use_timeline:   u64,
	error:              Ez_Gfx_Texture_Error,
	debug_label:        [EZ_GFX_TEXTURE_DEBUG_LABEL_MAX]byte,
	debug_label_len:    int,
}

// Moved from src\texture_manager.odin:117.
Ez_Gfx_Texture_Load_Job :: struct {
	id:      Ez_Gfx_Texture_ID,
	regions: [dynamic]Ez_Gfx_Texture_Memory_Region,
	desc:    Ez_Gfx_Load_Texture_Desc,
}

// Moved from src\texture_manager.odin:123.
Ez_Gfx_Texture_Decoded_Source :: enum u8 {
	None,
	RGB,
	RGBA,
}

// Moved from src\texture_manager.odin:129.
Ez_Gfx_Texture_Upload_Job :: struct {
	load:         Ez_Gfx_Texture_Load_Job,
	pixels:       []u8,
	width:        u32,
	height:       u32,
	source:       Ez_Gfx_Texture_Decoded_Source,
	owns_pixels:  bool,
	err:          Ez_Gfx_Texture_Error,
}

// Moved from src\texture_manager.odin:213.
Ez_Gfx_Texture_Destroy_Job :: struct {
	record:          Ez_Gfx_Texture_Record,
	retire_timeline: u64,
}

// Moved from src\texture_manager.odin:218.
Ez_Gfx_Texture_Staging_Retire_Job :: struct {
	buffer:          Ez_Gfx_Buffer,
	retire_timeline: u64,
}

// Moved from src\texture_manager.odin:223.
Ez_Gfx_Texture_Graphics_Handoff_Job :: struct {
	id:                Ez_Gfx_Texture_ID,
	image:             vk.Image,
	width:             u32,
	height:            u32,
	mip_count:         u32,
	transfer_timeline: u64,
}

// Moved from src\texture_manager.odin:232.
Ez_Gfx_Texture_Manager :: struct {
	textures:                         [EZ_GFX_MAX_TEXTURES]Ez_Gfx_Texture_Record,
	descriptor_set_layout:            vk.DescriptorSetLayout,
	descriptor_pool:                  vk.DescriptorPool,
	descriptor_set:                   vk.DescriptorSet,
	upload_command_pool:              vk.CommandPool,
	upload_command_buffer:            vk.CommandBuffer,
	upload_worker:                    ^thread.Thread,
	decode_workers:                   [dynamic]^thread.Thread,
	decode_worker_count:              u32,
	mutex:                            sync.Mutex,
	cond:                             sync.Cond,
	decode_jobs:                      [dynamic]Ez_Gfx_Texture_Load_Job,
	upload_jobs:                      [dynamic]Ez_Gfx_Texture_Upload_Job,
	pending_destroys:                 [dynamic]Ez_Gfx_Texture_Destroy_Job,
	pending_staging:                  [dynamic]Ez_Gfx_Texture_Staging_Retire_Job,
	pending_graphics_handoffs:        [dynamic]Ez_Gfx_Texture_Graphics_Handoff_Job,
	shutdown:                         bool,
	latest_scheduled_texture_timeline: u64,
	latest_submitted_texture_timeline: u64,
	latest_completed_texture_timeline: u64,
}

// Moved from src\vertex_manager.odin:17.
Ez_Gfx_Heap_Chunk :: struct {
	offset: vk.DeviceSize,
	size:   vk.DeviceSize,
}

// Moved from src\vertex_manager.odin:22.
Ez_Gfx_Pending_Free_Chunk :: struct {
	chunk:           Ez_Gfx_Heap_Chunk,
	retire_timeline: u64,
}

// Moved from src\vertex_manager.odin:27.
Ez_Gfx_Vertex_Allocation :: struct {
	start_index: u32,
	count:       u32,
}

// Moved from src\vertex_manager.odin:32.
Ez_Gfx_Vertex_Upload_Kind :: enum u8 {
	Indices,
	Vertices,
}

// Moved from src\vertex_manager.odin:37.
Ez_Gfx_Vertex_Upload_Error :: enum u8 {
	None,
	Invalid_Context,
	Invalid_Arguments,
	Out_Of_Memory,
	Vulkan_Failed,
	Worker_Unavailable,
	Missing_Heap,
}

// Moved from src\vertex_manager.odin:47.
Ez_Gfx_Vertex_Uploaded_Callback :: #type proc(
	ctx: ^Ez_Gfx_Ctx,
	kind: Ez_Gfx_Vertex_Upload_Kind,
	heap_name: string,
	allocation: Ez_Gfx_Vertex_Allocation,
	err: Ez_Gfx_Vertex_Upload_Error,
	user_data: rawptr,
)

// Moved from src\vertex_manager.odin:56.
Ez_Gfx_Gpu_Heap :: struct {
	buffer:              Ez_Gfx_Buffer,
	capacity:            vk.DeviceSize,
	stride:              vk.DeviceSize,
	high_water:          vk.DeviceSize,
	used_bytes:          vk.DeviceSize,
	free_chunks:         [dynamic]Ez_Gfx_Heap_Chunk,
	pending_free_chunks: [dynamic]Ez_Gfx_Pending_Free_Chunk,
}

// Moved from src\vertex_manager.odin:66.
Ez_Gfx_Vertex_Upload_Job :: struct {
	kind:              Ez_Gfx_Vertex_Upload_Kind,
	heap:              ^Ez_Gfx_Gpu_Heap,
	heap_name:         [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	heap_name_len:     int,
	allocation:        Ez_Gfx_Vertex_Allocation,
	offset:            vk.DeviceSize,
	byte_size:         vk.DeviceSize,
	// Staging buffer already filled with the caller's data at schedule time, so the
	// worker only records and submits the GPU copy. Ownership moves to the retire
	// queue once the transfer is submitted.
	staging:           Ez_Gfx_Buffer,
	transfer_timeline: u64,
}

// Moved from src\vertex_manager.odin:81.
Ez_Gfx_Vertex_Staging_Retire_Job :: struct {
	buffer:          Ez_Gfx_Buffer,
	command_buffer:  vk.CommandBuffer,
	retire_timeline: u64,
}

// Moved from src\vertex_manager.odin:87.
Ez_Gfx_Vertex_Graphics_Handoff_Job :: struct {
	buffer:            vk.Buffer,
	offset:            vk.DeviceSize,
	size:              vk.DeviceSize,
	transfer_timeline: u64,
}

// Moved from src\vertex_manager.odin:94.
Ez_Gfx_Named_Vertex_Heap :: struct {
	name:     [EZ_GFX_VERTEX_HEAP_NAME_MAX]byte,
	name_len: int,
	heap:     Ez_Gfx_Gpu_Heap,
}

// Moved from src\vertex_manager.odin:100.
Ez_Gfx_Vertex_Manager :: struct {
	index_heap:                      Ez_Gfx_Gpu_Heap,
	vertex_heaps:                    [EZ_GFX_MAX_VERTEX_HEAPS]Ez_Gfx_Named_Vertex_Heap,
	vertex_heap_count:               int,
	upload_command_pool:             vk.CommandPool,
	worker:                          ^thread.Thread,
	mutex:                           sync.Mutex,
	cond:                            sync.Cond,
	jobs:                            [dynamic]Ez_Gfx_Vertex_Upload_Job,
	pending_staging:                 [dynamic]Ez_Gfx_Vertex_Staging_Retire_Job,
	pending_graphics_handoffs:       [dynamic]Ez_Gfx_Vertex_Graphics_Handoff_Job,
	shutdown:                        bool,
	latest_scheduled_vertex_timeline: u64,
	latest_submitted_vertex_timeline: u64,
}

// Moved from src\window.odin:15.
Ez_Gfx_Window :: struct {
	native_window:          rawptr,
	host_window:            rawptr,
	native_display:         rawptr,
	surface_platform:       u32,
	surface:                vk.SurfaceKHR,
	framebuffer_resized:    bool,
	cache_presented_snapshots: bool,
	framebuffer_width:      c.int,
	framebuffer_height:     c.int,
	swapchain:              Ez_Gfx_Swapchain,
}


// Public constants used by the example-facing Odin API.
EZ_GFX_DEFAULT_COMPUTE_ENTRY :: cstring("computemain")
EZ_GFX_DEFAULT_FRAGMENT_ENTRY :: cstring("fragmentmain")
EZ_GFX_DEFAULT_VERTEX_ENTRY :: cstring("vertexmain")
EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)
EZ_GFX_SURFACE_PLATFORM_GLFW :: u32(1)
EZ_GFX_SURFACE_PLATFORM_WIN32 :: u32(0)
SCREENSHOT_PATH :: "screenshot.png"
EZ_GFX_C_ABI_VERSION :: u32(5)
EZ_GFX_C_RESULT_OK :: i32(0)
EZ_GFX_C_RESULT_INVALID_ARGUMENT :: i32(1)
EZ_GFX_C_RESULT_INVALID_CONTEXT :: i32(2)
EZ_GFX_C_RESULT_NATIVE_FAILURE :: i32(3)
EZ_GFX_C_RESULT_NOT_READY :: i32(4)

// Public Odin procedures, public type layouts, and C adapters live in this
// facade. All implementation modules are package-private through #+private.

// Public status values are the stable result vocabulary for Odin and C APIs.
Ez_Gfx_Status :: enum u8 {
	Ok,
	Invalid_Argument,
	Invalid_Context,
	Native_Failure,
	Not_Ready,
}

@(private)
status_from_bool :: proc(ok: bool) -> Ez_Gfx_Status {
	if ok do return .Ok
	return .Native_Failure
}

@(private)
validate_context :: proc(ctx: ^Ez_Gfx_Ctx) -> Ez_Gfx_Status {
	if ctx == nil do return .Invalid_Context
	return .Ok
}

@(private)
validate_window :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if window == nil || window.native_window == nil {
		return .Invalid_Argument
	}
	if window.surface_platform != EZ_GFX_SURFACE_PLATFORM_GLFW &&
	   window.surface_platform != EZ_GFX_SURFACE_PLATFORM_WIN32 {
		return .Invalid_Argument
	}
	if window.surface_platform == EZ_GFX_SURFACE_PLATFORM_WIN32 && window.native_display == nil {
		return .Invalid_Argument
	}
	return validate_context(get_current_ctx())
}

@(private)
validate_window_surface_identity :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if get_current_ctx().surface_platform != window.surface_platform {
		return .Invalid_Argument
	}
	return .Ok
}

@(private)
validate_shader :: proc(desc: Ez_Gfx_Shader_Desc, program: ^Ez_Gfx_Shader_Program) -> Ez_Gfx_Status {
	if program == nil || desc.path == nil do return .Invalid_Argument
	if desc.kind > Ez_Gfx_Shader_Kind.Compute do return .Invalid_Argument
	return validate_context(get_current_ctx())
}

@(private)
validate_active_render :: proc() -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	render := &get_current_ctx().render
	if !render.active || !render.ready do return .Not_Ready
	return .Ok
}

@(private)
validate_pipeline_common :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	bindings: []Ez_Gfx_Render_Binding,
	push_constant_data: rawptr,
	push_constant_size: u32,
) -> Ez_Gfx_Status {
	if shader == nil || len(bindings) > EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS {
		return .Invalid_Argument
	}
	if push_constant_size != shader.push_constant_size ||
	   push_constant_size > EZ_GFX_MAX_PUSH_CONSTANT_BYTES ||
	   (push_constant_size > 0 && push_constant_data == nil) {
		return .Invalid_Argument
	}
	for binding in bindings {
		if binding.name == nil do return .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return status
	if get_current_ctx().render.pipeline_count >= EZ_GFX_MAX_RENDER_PIPELINES {
		return .Not_Ready
	}
	return .Ok
}

// Runtime-sized push constants enter through this public boundary. Typed
// overloads and C adapters delegate here after marshalling their inputs.
ez_gfx_render_add_vertex_pipeline_raw :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
	push_constant_data: rawptr,
	push_constant_size: u32,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	if status := validate_pipeline_common(shader, bindings, push_constant_data, push_constant_size); status != .Ok {
		return descriptor, status
	}
	if shader.desc.kind != .Graphics ||
	   !indirect.ok ||
	   indirect.buffer == nil ||
	   indirect.frame_id != get_current_ctx().render.frame_id {
		return descriptor, .Invalid_Argument
	}
	descriptor = render_add_vertex_pipeline_impl(
		shader,
		indirect,
		bindings,
		dynamic_state,
		push_constant_data,
		push_constant_size,
	)
	if !descriptor.ok do return descriptor, .Native_Failure
	return descriptor, .Ok
}

// Runtime-sized push constants enter through this public boundary. Typed
// overloads and C adapters delegate here after marshalling their inputs.
ez_gfx_render_add_compute_pipeline_raw :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
	push_constant_data: rawptr,
	push_constant_size: u32,
) -> (
	descriptor: Ez_Gfx_Compute_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	if dispatch_x == 0 || dispatch_y == 0 || dispatch_z == 0 {
		return descriptor, .Invalid_Argument
	}
	if status := validate_pipeline_common(shader, bindings, push_constant_data, push_constant_size); status != .Ok {
		return descriptor, status
	}
	if shader.desc.kind != .Compute do return descriptor, .Invalid_Argument
	descriptor = render_add_compute_pipeline_impl(
		shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		bindings,
		push_constant_data,
		push_constant_size,
	)
	if !descriptor.ok do return descriptor, .Native_Failure
	return descriptor, .Ok
}


@(private)
validate_texture_load_arguments :: proc(
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> Ez_Gfx_Texture_Error {
	desc := texture_prepare_desc(desc)
	if len(regions) == 0 || len(regions) > 16 do return .Invalid_Arguments
	if desc.source_format > .KTX2 ||
	   desc.min_filter > .Linear ||
	   desc.mag_filter > .Linear ||
	   desc.address_mode_u > .Clamp_To_Edge ||
	   desc.address_mode_v > .Clamp_To_Edge ||
	   desc.address_mode_w > .Clamp_To_Edge {
		return .Invalid_Arguments
	}
	if (desc.source_format == .RGB || desc.source_format == .RGBA) &&
	   (desc.width == 0 || desc.height == 0) {
		return .Invalid_Arguments
	}
	for region in regions {
		if len(region.data) == 0 do return .Invalid_Arguments
	}
	return .None
}



ez_gfx_ctx_create_instance :: proc(ctx: ^Ez_Gfx_Ctx, desc: Ez_Gfx_Ctx_Desc = {}) -> Ez_Gfx_Status {
	if status := validate_context(ctx); status != .Ok do return status
	if get_current_ctx() != ctx do return .Invalid_Context
	if desc.surface_platform != EZ_GFX_SURFACE_PLATFORM_GLFW &&
	   desc.surface_platform != EZ_GFX_SURFACE_PLATFORM_WIN32 {
		return .Invalid_Argument
	}
	return status_from_bool(ctx_create_instance(ctx, desc))
}


ez_gfx_ctx_init_device :: proc(surface: vk.SurfaceKHR) -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if surface == vk.SurfaceKHR(0) do return .Invalid_Argument
	return status_from_bool(ctx_init_device(surface))
}


ez_gfx_ctx_wait_idle :: proc() -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	ctx_wait_idle()
	return .Ok
}


ez_gfx_ctx_destroy :: proc() -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	ctx_destroy()
	return .Ok
}


ez_gfx_window_create_surface :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window_surface_identity(window); status != .Ok do return status
	if window.framebuffer_width <= 0 || window.framebuffer_height <= 0 {
		return .Invalid_Argument
	}
	return status_from_bool(window_create_surface(window))
}

ez_gfx_window_create_surface_u32 :: proc(
	window: ^Ez_Gfx_Window,
	width, height: u32,
) -> Ez_Gfx_Status {
	if status := validate_window_surface_identity(window); status != .Ok do return status
	if width == 0 || height == 0 ||
	   width > u32(max(c.int)) || height > u32(max(c.int)) {
		return .Invalid_Argument
	}
	window.framebuffer_width = c.int(width)
	window.framebuffer_height = c.int(height)
	return status_from_bool(window_create_surface(window))
}


ez_gfx_window_recreate_swapchain :: proc(window: ^Ez_Gfx_Window, width, height: c.int) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if width < 0 || height < 0 do return .Invalid_Argument
	if window.surface == vk.SurfaceKHR(0) do return .Not_Ready
	if width == 0 || height == 0 {
		if width != 0 || height != 0 do return .Invalid_Argument
		return status_from_bool(window_set_extent(window, 0, 0))
	}
	return status_from_bool(window_recreate_swapchain(window, width, height))
}

ez_gfx_window_recreate_swapchain_u32 :: proc(
	window: ^Ez_Gfx_Window,
	width, height: u32,
) -> Ez_Gfx_Status {
	if width > u32(max(c.int)) || height > u32(max(c.int)) {
		return .Invalid_Argument
	}
	return ez_gfx_window_recreate_swapchain(window, c.int(width), c.int(height))
}


ez_gfx_window_get_framebuffer_size :: proc(window: ^Ez_Gfx_Window) -> (width, height: c.int, status: Ez_Gfx_Status) {
	if status := validate_window(window); status != .Ok do return 0, 0, status
	width, height = window_get_framebuffer_size(window)
	if width <= 0 || height <= 0 do return width, height, .Not_Ready
	return width, height, .Ok
}

ez_gfx_window_resize_pending :: proc(window: ^Ez_Gfx_Window) -> (pending: bool, status: Ez_Gfx_Status) {
	if status := validate_window(window); status != .Ok do return false, status
	return window_resize_pending(window), .Ok
}


ez_gfx_window_set_snapshot_cache :: proc(window: ^Ez_Gfx_Window, enabled: bool) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	window.cache_presented_snapshots = enabled
	return .Ok
}

ez_gfx_window_set_snapshot_cache_i32 :: proc(window: ^Ez_Gfx_Window, enabled: i32) -> Ez_Gfx_Status {
	if enabled != 0 && enabled != 1 do return .Invalid_Argument
	return ez_gfx_window_set_snapshot_cache(window, enabled != 0)
}


ez_gfx_window_destroy :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	window_destroy(window)
	return .Ok
}


ez_gfx_shader_compile :: proc(desc: Ez_Gfx_Shader_Desc, program: ^Ez_Gfx_Shader_Program) -> Ez_Gfx_Status {
	if status := validate_shader(desc, program); status != .Ok do return status
	return status_from_bool(shader_compile(desc, program))
}


ez_gfx_shader_destroy :: proc(program: ^Ez_Gfx_Shader_Program) -> Ez_Gfx_Status {
	if program == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	shader_destroy(program)
	return .Ok
}


ez_gfx_enable_all_decoders :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_all_decoders())
}


ez_gfx_vertex_manager_begin :: proc(manager: ^Ez_Gfx_Vertex_Manager) -> Ez_Gfx_Status {
	if manager == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	vertex_manager_begin(manager)
	return .Ok
}


ez_gfx_gpu_heap_create :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	debug_name: cstring = nil,
) -> Ez_Gfx_Status {
	if heap == nil || capacity == 0 || stride == 0 ||
	   capacity > vk.DeviceSize(max(int)) || stride > vk.DeviceSize(max(int)) {
		return .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	gpu_heap_create(heap, capacity, stride, usage, debug_name)
	return .Ok
}


ez_gfx_vertex_manager_add_heap :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	name: string,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if manager == nil || len(name) == 0 || capacity == 0 || stride == 0 ||
	   capacity > vk.DeviceSize(max(int)) || stride > vk.DeviceSize(max(int)) {
		return .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if manager.vertex_heap_count >= EZ_GFX_MAX_VERTEX_HEAPS do return .Invalid_Argument
	vertex_manager_add_heap(manager, name, capacity, stride)
	return .Ok
}

@(private)
validate_vertex_upload :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap: ^Ez_Gfx_Gpu_Heap,
	element_count: u32,
	element_size, source_stride: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if manager == nil || heap == nil || element_count == 0 || element_size == 0 ||
	   u64(element_count) > u64(max(int)) ||
	   element_size > vk.DeviceSize(max(int)) ||
	   heap.stride > vk.DeviceSize(max(int)) {
		return .Invalid_Argument
	}
	if manager.worker == nil || heap.stride == 0 do return .Not_Ready
	actual_source_stride := source_stride
	if actual_source_stride == 0 do actual_source_stride = element_size
	if actual_source_stride > vk.DeviceSize(max(int)) ||
	   element_size > heap.stride || actual_source_stride < element_size {
		return .Invalid_Argument
	}
	count := int(element_count)
	element_size_int := int(element_size)
	if u64(element_count) > u64(max(vk.DeviceSize)) / u64(heap.stride) ||
	   u64(element_count) > u64(max(int)) / u64(heap.stride) {
		return .Invalid_Argument
	}
	if count > 1 {
		max_offset := max(int) - element_size_int
		if int(heap.stride) > max_offset / (count - 1) ||
		   int(actual_source_stride) > max_offset / (count - 1) {
			return .Invalid_Argument
		}
	}
	return .Ok
}


ez_gfx_vertex_manager_upload_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
	source_stride: vk.DeviceSize = 0,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if manager == nil || len(indices) == 0 || u64(len(indices)) > u64(max(u32)) {
		return 0, .Invalid_Argument
	}
	if status := validate_vertex_upload(
		manager,
		&manager.index_heap,
		u32(len(indices)),
		vk.DeviceSize(size_of(u32)),
		source_stride,
	); status != .Ok {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, status
	allocation, ok := vertex_manager_alloc_indices(manager, indices, source_stride)
	if !ok do return 0, .Native_Failure
	return allocation.start_index, .Ok
}

ez_gfx_vertex_manager_upload_indices_raw :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	data: rawptr,
	count: u32,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if data == nil || count == 0 {
		return 0, .Invalid_Argument
	}
	indices_ptr := cast([^]u32)data
	indices := indices_ptr[:count]
	return ez_gfx_vertex_manager_upload_indices(manager, indices)
}


ez_gfx_vertex_manager_upload_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	vertices: []$T,
	source_stride: vk.DeviceSize = 0,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if manager == nil || len(heap_name) == 0 || len(vertices) == 0 ||
	   u64(len(vertices)) > u64(max(u32)) {
		return 0, .Invalid_Argument
	}
	heap := vertex_manager_find_heap(manager, heap_name)
	if heap == nil do return 0, .Invalid_Argument
	if status := validate_vertex_upload(
		manager,
		heap,
		u32(len(vertices)),
		vk.DeviceSize(size_of(T)),
		source_stride,
	); status != .Ok {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, status
	allocation, ok := vertex_manager_alloc_vertices(manager, heap_name, vertices, source_stride)
	if !ok do return 0, .Native_Failure
	return allocation.start_index, .Ok
}

ez_gfx_vertex_manager_upload_raw :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	data: rawptr,
	element_count: u32,
	element_size: vk.DeviceSize,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if manager == nil || len(heap_name) == 0 || data == nil || element_count == 0 || element_size == 0 {
		return 0, .Invalid_Argument
	}
	heap := vertex_manager_find_heap(manager, heap_name)
	if heap == nil do return 0, .Invalid_Argument
	if status := validate_vertex_upload(manager, heap, element_count, element_size, 0); status != .Ok {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, status
	allocation, ok := vertex_manager_schedule_upload(
		manager,
		.Vertices,
		heap_name,
		heap,
		data,
		element_count,
		element_size,
	)
	if !ok do return 0, .Native_Failure
	return allocation.start_index, .Ok
}
ez_gfx_load_texture :: proc(
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (texture_id: Ez_Gfx_Texture_ID, status: Ez_Gfx_Texture_Error) {
	if status := validate_texture_load_arguments(regions, desc); status != .None {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, .Invalid_Context
	return load_texture(regions, desc)
}


@(private)
texture_load_desc_from_c :: proc(desc: ^Ez_Gfx_C_Texture_Desc) -> Ez_Gfx_Load_Texture_Desc {
	return Ez_Gfx_Load_Texture_Desc {
		source_format      = Ez_Gfx_Source_Texture_Format(desc.source_format),
		destination_format = .R8G8B8A8_UNORM,
		width              = desc.width,
		height             = desc.height,
		mip_count          = desc.mip_count,
		generate_mips      = desc.generate_mips != 0,
		min_filter         = Ez_Gfx_Texture_Filter(desc.min_filter),
		mag_filter         = Ez_Gfx_Texture_Filter(desc.mag_filter),
		max_anisotropy     = desc.max_anisotropy,
		address_mode_u     = Ez_Gfx_Texture_Address_Mode(desc.address_mode_u),
		address_mode_v     = Ez_Gfx_Texture_Address_Mode(desc.address_mode_v),
		address_mode_w     = Ez_Gfx_Texture_Address_Mode(desc.address_mode_w),
		debug_label        = shader_cstring_to_string(desc.debug_label),
	}
}

ez_gfx_texture_load_bytes :: proc(
	data: rawptr,
	data_size: u64,
	desc: ^Ez_Gfx_C_Texture_Desc,
) -> (
	owned_data: []u8,
	texture_id: Ez_Gfx_Texture_ID,
	status: Ez_Gfx_Texture_Error,
) {
	if data == nil || data_size == 0 || data_size > u64(max(int)) ||
	   desc == nil || desc.destination_format != 0 {
		return nil, 0, .Invalid_Arguments
	}
	odin_desc := texture_load_desc_from_c(desc)
	source_data := cast([^]u8)data
	source_regions := [1]Ez_Gfx_Texture_Memory_Region{{data = source_data[:int(data_size)]}}
	if status := validate_texture_load_arguments(source_regions[:], odin_desc); status != .None {
		return nil, 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok {
		return nil, 0, .Invalid_Context
	}
	// C input may expire after the adapter returns, so copy only validated bytes.
	owned_data = make([]u8, int(data_size))
	mem.copy(raw_data(owned_data), data, int(data_size))
	regions := [1]Ez_Gfx_Texture_Memory_Region{{data = owned_data}}
	texture_id, status = load_texture(regions[:], odin_desc)
	if status != .None {
		delete(owned_data)
		return nil, 0, status
	}
	return owned_data, texture_id, .None
}

ez_gfx_unload_texture :: proc(texture_id: Ez_Gfx_Texture_ID) -> Ez_Gfx_Texture_Error {
	if status := validate_context(get_current_ctx()); status != .Ok do return .Invalid_Context
	return unload_texture(texture_id)
}


ez_gfx_begin_render :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if window.framebuffer_width <= 0 || window.framebuffer_height <= 0 do return .Not_Ready
	if get_current_ctx().render.active do return .Not_Ready
	return status_from_bool(begin_render(window))
}


ez_gfx_finish_render :: proc() -> Ez_Gfx_Status {
	if status := validate_active_render(); status != .Ok do return status
	return status_from_bool(finish_render())
}


ez_gfx_indirect_buffer_set_draw_count :: proc(handle: ^Ez_Gfx_Indirect_Buffer_Handle, count: u32) -> Ez_Gfx_Status {
	if handle == nil || !handle.ok || handle.buffer == nil || count > handle.capacity {
		return .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return status
	if handle.frame_id != get_current_ctx().render.frame_id do return .Invalid_Argument
	return status_from_bool(indirect_buffer_set_draw_count(handle, count))
}


ez_gfx_indirect_buffer_write_draw :: proc(
	handle: ^Ez_Gfx_Indirect_Buffer_Handle,
	index: u32,
	command: vk.DrawIndexedIndirectCommand,
) -> Ez_Gfx_Status {
	if handle == nil || !handle.ok || handle.buffer == nil || index >= handle.capacity {
		return .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return status
	if handle.frame_id != get_current_ctx().render.frame_id do return .Invalid_Argument
	return status_from_bool(indirect_buffer_write_draw(handle, index, command))
}



// C and other untyped hosts use this byte-sized boundary. It owns validation
// before invoking the internal typed structured-buffer allocator.
ez_gfx_render_acquire_structured_buffer_bytes :: proc(
	element_size, element_count: u32,
	debug_name: cstring,
) -> (
	handle: Ez_Gfx_Structured_Buffer_Handle,
	status: Ez_Gfx_Status,
) {
	if element_size == 0 || element_count == 0 || debug_name == nil {
		return handle, .Invalid_Argument
	}
	byte_count := u64(element_size) * u64(element_count)
	if byte_count > u64(max(u32)) do return handle, .Invalid_Argument
	if status := validate_active_render(); status != .Ok do return handle, status
	view := render_acquire_structured_buffer(u8, u32(byte_count), debug_name)
	if !view.handle.ok do return handle, .Native_Failure
	return view.handle, .Ok
}

ez_gfx_structured_buffer_write :: proc(
	handle: ^Ez_Gfx_Structured_Buffer_Handle,
	data: rawptr,
	data_size: u64,
) -> Ez_Gfx_Status {
	if handle == nil || !handle.ok || data_size > u64(handle.size) || data_size > u64(max(int)) {
		return .Invalid_Argument
	}
	if data_size > 0 && data == nil do return .Invalid_Argument
	if status := validate_active_render(); status != .Ok do return status
	if handle.frame_id != get_current_ctx().render.frame_id do return .Invalid_Argument
	if data_size > 0 {
		mem.copy(handle.cpu_ptr, data, int(data_size))
	}
	return .Ok
}


@(private)
render_add_vertex_pipeline_from_c :: proc(
	owner: ^Ez_Gfx_C_Context,
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: [^]Ez_Gfx_C_Binding,
	binding_count: u32,
	dynamic_state: ^Ez_Gfx_C_Dynamic_State,
	push_constants: rawptr,
	push_constant_size: u32,
) -> Ez_Gfx_Status {
	if owner == nil do return .Invalid_Context
	odin_bindings: [EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding
	if !c_copy_bindings(bindings, binding_count, owner, &odin_bindings) do return .Invalid_Argument
	odin_dynamic, dynamic_ok := c_build_dynamic_state(dynamic_state)
	if !dynamic_ok do return .Invalid_Argument
	_, status := ez_gfx_render_add_vertex_pipeline_raw(
		shader,
		indirect,
		odin_bindings[:int(binding_count)],
		odin_dynamic,
		push_constants,
		push_constant_size,
	)
	return status
}


@(private)
render_add_compute_pipeline_from_c :: proc(
	owner: ^Ez_Gfx_C_Context,
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: [^]Ez_Gfx_C_Binding,
	binding_count: u32,
	push_constants: rawptr,
	push_constant_size: u32,
) -> Ez_Gfx_Status {
	if owner == nil do return .Invalid_Context
	odin_bindings: [EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding
	if !c_copy_bindings(bindings, binding_count, owner, &odin_bindings) do return .Invalid_Argument
	_, status := ez_gfx_render_add_compute_pipeline_raw(
		shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		odin_bindings[:int(binding_count)],
		push_constants,
		push_constant_size,
	)
	return status
}


ez_gfx_screenshot_save_window :: proc(window: ^Ez_Gfx_Window, path: string) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if len(path) == 0 do return .Invalid_Argument
	return status_from_bool(screenshot_save_window(window, path))
}

// Typed render entry points keep validation and status mapping at the public
// Odin boundary; internal render procedures only receive validated inputs.
ez_gfx_render_acquire_indirect_buffer :: proc(
	$T: typeid,
	element_count: u32,
	debug_name: cstring,
) -> (
	handle: Ez_Gfx_Indirect_Buffer_Handle,
	status: Ez_Gfx_Status,
) {
	indirect_stride := vk.DeviceSize(size_of(T))
	if element_count == 0 || debug_name == nil ||
	   indirect_stride < vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)) ||
	   indirect_stride % 4 != 0 {
		return handle, .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return handle, status
	handle = render_acquire_indirect_buffer(T, element_count, debug_name)
	if !handle.ok do return handle, .Native_Failure
	return handle, .Ok
}

ez_gfx_render_acquire_structured_buffer :: proc(
	$T: typeid,
	element_count: u32,
	debug_name: cstring,
) -> (
	view: Ez_Gfx_Structured_Buffer_View(T),
	status: Ez_Gfx_Status,
) {
	element_size := u64(size_of(T))
	if element_count == 0 || element_size == 0 || debug_name == nil ||
	   element_size > u64(max(vk.DeviceSize)) / u64(element_count) {
		return view, .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return view, status
	view = render_acquire_structured_buffer(T, element_count, debug_name)
	if !view.handle.ok do return view, .Native_Failure
	return view, .Ok
}

ez_gfx_render_add_compute_pipeline :: proc {
	ez_gfx_render_add_compute_pipeline_without_push_constants,
	ez_gfx_render_add_compute_pipeline_with_push_constants,
}

ez_gfx_render_add_compute_pipeline_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
) -> (
	descriptor: Ez_Gfx_Compute_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	return ez_gfx_render_add_compute_pipeline_raw(shader, dispatch_x, dispatch_y, dispatch_z, bindings, nil, 0)
}

ez_gfx_render_add_compute_pipeline_with_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
	push_constants: $T,
) -> (
	descriptor: Ez_Gfx_Compute_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	data := push_constants
	return ez_gfx_render_add_compute_pipeline_raw(
		shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		bindings,
		rawptr(&data),
		u32(size_of(T)),
	)
}

ez_gfx_render_add_vertex_pipeline :: proc {
	ez_gfx_render_add_vertex_pipeline_without_push_constants,
	ez_gfx_render_add_vertex_pipeline_with_dynamic_state_without_push_constants,
	ez_gfx_render_add_vertex_pipeline_with_dynamic_state_and_push_constants,
}

ez_gfx_render_add_vertex_pipeline_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	return ez_gfx_render_add_vertex_pipeline_raw(shader, indirect, bindings, {}, nil, 0)
}

ez_gfx_render_add_vertex_pipeline_with_dynamic_state_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	return ez_gfx_render_add_vertex_pipeline_raw(shader, indirect, bindings, dynamic_state, nil, 0)
}

ez_gfx_render_add_vertex_pipeline_with_dynamic_state_and_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
	push_constants: $T,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	data := push_constants
	return ez_gfx_render_add_vertex_pipeline_raw(
		shader,
		indirect,
		bindings,
		dynamic_state,
		rawptr(&data),
		u32(size_of(T)),
	)
}

// Configuration helpers are pure reads and do not need a status result.
ez_gfx_config_hidden_window :: proc() -> bool { return config_hidden_window() }
ez_gfx_config_max_frames :: proc() -> int { return config_max_frames() }
ez_gfx_config_run_seconds :: proc() -> f64 { return config_run_seconds() }
ez_gfx_config_screenshot_enabled :: proc() -> bool { return config_screenshot_enabled() }

// Focused public helpers used by tests and by host integrations that need
// deterministic queries without taking ownership of internal managers.
ez_gfx_ctx_next_timeline_value :: proc(ctx: ^Ez_Gfx_Ctx) -> u64 {
	if ctx == nil do return 0
	return ctx_next_timeline_value(ctx)
}

ez_gfx_ctx_get_info :: proc(info: ^Ez_Gfx_Ctx_Info) -> Ez_Gfx_Status {
	if info == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	return status_from_bool(ctx_get_info(info))
}

ez_gfx_ctx_set_swapchain_present_mode :: proc(mode: vk.PresentModeKHR) -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	return status_from_bool(ctx_set_swapchain_present_mode(mode))
}

ez_gfx_ctx_choose_transfer_queue_family :: proc(
	queues: []vk.QueueFamilyProperties,
	graphics_queue_index: u32,
) -> u32 {
	return ctx_choose_transfer_queue_family(queues, graphics_queue_index)
}

ez_gfx_swapchain_choose_present_mode :: proc(
	available_present_modes: []vk.PresentModeKHR,
	requested: vk.PresentModeKHR,
) -> vk.PresentModeKHR {
	return swapchain_choose_present_mode(available_present_modes, requested)
}

ez_gfx_texture_decode_worker_count_from_logical :: proc(logical_cpu_count: int) -> u32 {
	return texture_decode_worker_count_from_logical(logical_cpu_count)
}

ez_gfx_ctx_resolve_texture_decode_worker_count :: proc(requested: u32) -> u32 {
	return ctx_resolve_texture_decode_worker_count(requested)
}

ez_gfx_vertex_manager_create :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	vertex_heap_names: []string,
	vertex_stride: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if manager == nil || len(vertex_heap_names) == 0 || vertex_stride == 0 {
		return .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if manager.vertex_heap_count < 0 ||
	   manager.vertex_heap_count > EZ_GFX_MAX_VERTEX_HEAPS ||
	   len(vertex_heap_names) > EZ_GFX_MAX_VERTEX_HEAPS - manager.vertex_heap_count {
		return .Invalid_Argument
	}
	vertex_manager_create(manager, vertex_heap_names, vertex_stride)
	return .Ok
}

ez_gfx_shader_reflect :: proc(
	desc: Ez_Gfx_Shader_Desc,
	program: ^Ez_Gfx_Shader_Program,
) -> Ez_Gfx_Status {
	if status := validate_shader(desc, program); status != .Ok do return status
	return status_from_bool(shader_reflect(desc, program))
}

ez_gfx_render_target_describe :: proc(
	width: u32,
	height: u32,
	debug_label: cstring,
) -> (
	id: Ez_Gfx_Render_Target_Id,
	status: Ez_Gfx_Status,
) {
	if width == 0 || height == 0 || debug_label == nil ||
	   cstring_len(debug_label) >= EZ_GFX_SHADER_TARGET_NAME_MAX {
		return id, .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return id, status
	id = render_target_describe(width, height, debug_label)
	if !id.ok do return id, .Native_Failure
	return id, .Ok
}

ez_gfx_screenshot_read_swapchain_bgra :: proc(
	swapchain: ^Ez_Gfx_Swapchain,
	pixels: ^[]u8,
) -> Ez_Gfx_Status {
	if swapchain == nil || pixels == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if swapchain.extent.width == 0 || swapchain.extent.height == 0 do return .Not_Ready
	return status_from_bool(screenshot_read_swapchain_bgra(swapchain, pixels))
}

ez_gfx_register_image_decoder :: proc(
	format: Ez_Gfx_Source_Texture_Format,
	callback: Ez_Gfx_Image_Decoder_Callback,
) -> Ez_Gfx_Status {
	if format > .KTX2 do return .Invalid_Argument
	return status_from_bool(register_image_decoder(format, callback))
}

ez_gfx_enable_bmp_decoder :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_bmp_decoder())
}

ez_gfx_enable_png_decoder :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_png_decoder())
}

ez_gfx_enable_ktx2_decoder :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_ktx2_decoder())
}

ez_gfx_texture_manager_load :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (texture_id: Ez_Gfx_Texture_ID, error: Ez_Gfx_Texture_Error) {
	if manager == nil || ctx == nil do return 0, .Invalid_Context
	if status := validate_texture_load_arguments(regions, desc); status != .None {
		return 0, status
	}
	return texture_manager_load(manager, ctx, regions, desc)
}

ez_gfx_texture_decode_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	return texture_decode_upload_job(job)
}

ez_gfx_texture_decode_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
	out_pixels: ^[]u8,
	out_width: ^u32,
	out_height: ^u32,
) -> Ez_Gfx_Texture_Error {
	return texture_decode_job(job, out_pixels, out_width, out_height)
}

ez_gfx_texture_upload_job_destroy :: proc(job: ^Ez_Gfx_Texture_Upload_Job) {
	texture_upload_job_destroy(job)
}

ez_gfx_texture_staging_size :: proc(job: ^Ez_Gfx_Texture_Upload_Job) -> vk.DeviceSize {
	if job == nil do return 0
	return texture_staging_size(job)
}

ez_gfx_texture_full_mip_count :: proc(width, height: u32) -> u32 {
	return texture_full_mip_count(width, height)
}

ez_gfx_texture_manager_alloc_slot :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
) -> (slot: ^Ez_Gfx_Texture_Record, slot_index: u32) {
	if manager == nil do return nil, 0
	return texture_manager_alloc_slot(manager)
}

ez_gfx_texture_manager_find_locked :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	id: Ez_Gfx_Texture_ID,
) -> ^Ez_Gfx_Texture_Record {
	if manager == nil do return nil
	return texture_manager_find_locked(manager, id)
}

@(private)
validate_gpu_heap_range :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if heap == nil || heap.stride == 0 ||
	   byte_size > max(vk.DeviceSize) - (heap.stride - 1) {
		return .Invalid_Argument
	}
	return .Ok
}

ez_gfx_gpu_heap_allocate_range :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
) -> (offset: vk.DeviceSize, status: Ez_Gfx_Status) {
	if status := validate_gpu_heap_range(heap, byte_size); status != .Ok do return 0, status
	ok: bool
	offset, ok = gpu_heap_allocate_range(heap, byte_size)
	if !ok do return 0, .Native_Failure
	return offset, .Ok
}

ez_gfx_gpu_heap_reserve_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
	element_count: u32,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	offset: vk.DeviceSize,
	status: Ez_Gfx_Status,
) {
	if status := validate_gpu_heap_range(heap, byte_size); status != .Ok {
		return {}, 0, status
	}
	if element_count == 0 {
		if byte_size != 0 do return {}, 0, .Invalid_Argument
	} else {
		if vk.DeviceSize(element_count) > max(vk.DeviceSize) / heap.stride ||
		   byte_size != vk.DeviceSize(element_count) * heap.stride {
			return {}, 0, .Invalid_Argument
		}
	}
	ok: bool
	allocation, offset, ok = gpu_heap_reserve_allocation(heap, byte_size, element_count)
	if !ok do return {}, 0, .Native_Failure
	return allocation, offset, .Ok
}

ez_gfx_gpu_heap_free_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> Ez_Gfx_Status {
	if heap == nil || heap.stride == 0 do return .Invalid_Argument
	if allocation.count > 0 {
		start := vk.DeviceSize(allocation.start_index)
		count := vk.DeviceSize(allocation.count)
		if start > max(vk.DeviceSize) / heap.stride ||
		   count > max(vk.DeviceSize) / heap.stride {
			return .Invalid_Argument
		}
		offset := start * heap.stride
		size := count * heap.stride
		if offset > max(vk.DeviceSize) - size || offset + size > heap.high_water {
			return .Invalid_Argument
		}
	}
	if !gpu_heap_free_allocation(heap, allocation) do return .Native_Failure
	return .Ok
}

ez_gfx_vertex_copy_strided :: proc "contextless" (
	dst: rawptr,
	dst_stride: int,
	src: rawptr,
	src_stride: int,
	element_size: int,
	element_count: int,
) -> Ez_Gfx_Status {
	if element_size <= 0 || element_count < 0 ||
	   dst_stride < element_size || src_stride < element_size {
		return .Invalid_Argument
	}
	// A zero-element transfer is a valid no-op and intentionally permits nil
	// pointers because neither pointer is dereferenced.
	if element_count == 0 do return .Ok
	if dst == nil || src == nil ||
	   element_size > max(int) / element_count ||
	   (element_count > 1 &&
		(dst_stride > (max(int) - element_size) / (element_count - 1) ||
		 src_stride > (max(int) - element_size) / (element_count - 1))) {
		return .Invalid_Argument
	}
	vertex_copy_strided(dst, dst_stride, src, src_stride, element_size, element_count)
	return .Ok
}

ez_gfx_render_dynamic_state_to_vk_topology :: proc(
	primitive_type: Ez_Gfx_Primitive_Type,
) -> vk.PrimitiveTopology {
	return render_dynamic_state_to_vk_topology(primitive_type)
}

ez_gfx_copy_shader_target_name_cstring :: proc(
	dst: []byte,
	dst_len: ^int,
	name: cstring,
) -> Ez_Gfx_Status {
	if dst_len == nil || name == nil || len(dst) < EZ_GFX_SHADER_TARGET_NAME_MAX {
		return .Invalid_Argument
	}
	name_len := 0
	name_bytes := cast([^]byte)name
	for name_len < EZ_GFX_SHADER_TARGET_NAME_MAX && name_bytes[name_len] != 0 {
		name_len += 1
	}
	if name_len == EZ_GFX_SHADER_TARGET_NAME_MAX do return .Invalid_Argument
	if !copy_shader_target_name(dst, dst_len, name, name_len) do return .Native_Failure
	return .Ok
}

ez_gfx_shader_target_name_equals_cstring :: proc(
	name: []byte,
	name_len: int,
	other: cstring,
) -> bool {
	return shader_target_name_equals_cstring(name, name_len, other)
}

ez_gfx_shader_validate_unique_target_declarations :: proc(
	program: ^Ez_Gfx_Shader_Program,
) -> Ez_Gfx_Status {
	if program == nil do return .Invalid_Argument
	if !shader_validate_unique_target_declarations(program) do return .Native_Failure
	return .Ok
}

ez_gfx_screenshot_bgra_to_rgba :: proc(
	bgra: []u8,
	width, height: int,
) -> (rgba: []u8, status: Ez_Gfx_Status) {
	if width <= 0 || height <= 0 ||
	   width > max(int) / height ||
	   width * height > max(int) / 4 ||
	   len(bgra) != width * height * 4 {
		return nil, .Invalid_Argument
	}
	ok: bool
	rgba, ok = screenshot_bgra_to_rgba(bgra, width, height)
	if !ok do return nil, .Native_Failure
	return rgba, .Ok
}

ez_gfx_screenshot_write_png :: proc(
	path: string,
	width, height: int,
	bgra: []u8,
) -> Ez_Gfx_Status {
	if len(path) == 0 || width <= 0 || height <= 0 ||
	   width > int(max(c.int)) / 4 ||
	   height > int(max(c.int)) ||
	   width > max(int) / height ||
	   width * height > max(int) / 4 ||
	   len(bgra) != width * height * 4 {
		return .Invalid_Argument
	}
	if !screenshot_write_png(path, width, height, bgra) do return .Native_Failure
	return .Ok
}

// C adapter bookkeeping remains private to the facade. Live registries make
// opaque C handles fail closed before a stale address can be dereferenced.
@(private)
c_status :: proc(status: Ez_Gfx_Status) -> i32 {
	switch status {
	case .Ok:
		return EZ_GFX_C_RESULT_OK
	case .Invalid_Argument:
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	case .Invalid_Context:
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	case .Native_Failure:
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	case .Not_Ready:
		return EZ_GFX_C_RESULT_NOT_READY
	}
	return EZ_GFX_C_RESULT_NATIVE_FAILURE
}

@(private)
EZ_GFX_C_MAX_BINDINGS :: EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS

c_live_handles: [dynamic]Ez_Gfx_C_Live_Handle
c_live_handles_mutex: sync.Mutex
c_next_live_handle: u64 = 1

@(private)
Ez_Gfx_C_Handle_Kind :: enum u8 {
	Context,
	Surface,
	Shader,
	Indirect,
	Structured,
}

@(private)
Ez_Gfx_C_Live_Handle :: struct {
	kind:   Ez_Gfx_C_Handle_Kind,
	handle: u64,
	value:  rawptr,
}

// C handles are monotonic IDs rather than allocation addresses. This prevents
// a stale handle from becoming valid if its old wrapper address is recycled.
@(private)
c_handle_register :: proc(kind: Ez_Gfx_C_Handle_Kind, value: rawptr) -> u64 {
	if value == nil do return 0
	sync.mutex_lock(&c_live_handles_mutex)
	defer sync.mutex_unlock(&c_live_handles_mutex)
	if c_next_live_handle == 0 {
		panic("C handle space exhausted")
	}
	handle := c_next_live_handle
	c_next_live_handle += 1
	append(&c_live_handles, Ez_Gfx_C_Live_Handle{
		kind = kind,
		handle = handle,
		value = value,
	})
	return handle
}

@(private)
c_handle_unregister :: proc(kind: Ez_Gfx_C_Handle_Kind, handle: u64) {
	if handle == 0 do return
	sync.mutex_lock(&c_live_handles_mutex)
	defer sync.mutex_unlock(&c_live_handles_mutex)
	for live, index in c_live_handles {
		if live.kind == kind && live.handle == handle {
			ordered_remove(&c_live_handles, index)
			return
		}
	}
}

@(private)
c_handle_find :: proc(kind: Ez_Gfx_C_Handle_Kind, handle: u64) -> rawptr {
	if handle == 0 do return nil
	sync.mutex_lock(&c_live_handles_mutex)
	defer sync.mutex_unlock(&c_live_handles_mutex)
	for live in c_live_handles {
		if live.kind == kind && live.handle == handle do return live.value
	}
	return nil
}

@(private)
c_context_register :: proc(ctx: ^Ez_Gfx_C_Context) {
	if ctx == nil do return
	ctx.opaque_handle = c_handle_register(.Context, rawptr(ctx))
}

@(private)
c_context_unregister :: proc(ctx: ^Ez_Gfx_C_Context) {
	if ctx == nil do return
	c_handle_unregister(.Context, ctx.opaque_handle)
	ctx.opaque_handle = 0
}

@(private)
c_resource_register :: proc(kind: Ez_Gfx_C_Handle_Kind, value: rawptr) -> u64 {
	return c_handle_register(kind, value)
}

@(private)
c_resource_unregister :: proc(kind: Ez_Gfx_C_Handle_Kind, handle: u64) {
	c_handle_unregister(kind, handle)
}


@(private)
c_resource_owner :: proc(resource: Ez_Gfx_C_Live_Handle) -> ^Ez_Gfx_C_Context {
	switch resource.kind {
	case .Context:
		return nil
	case .Surface:
		surface := cast(^Ez_Gfx_C_Surface)resource.value
		return surface.owner
	case .Shader:
		shader := cast(^Ez_Gfx_C_Shader)resource.value
		return shader.owner
	case .Indirect:
		indirect := cast(^Ez_Gfx_C_Indirect)resource.value
		return indirect.owner
	case .Structured:
		structured := cast(^Ez_Gfx_C_Structured)resource.value
		return structured.owner
	}
	return nil
}

@(private)
c_resource_take_owned :: proc(
	owner: ^Ez_Gfx_C_Context,
) -> (resource: Ez_Gfx_C_Live_Handle, found: bool) {
	if owner == nil do return
	sync.mutex_lock(&c_live_handles_mutex)
	defer sync.mutex_unlock(&c_live_handles_mutex)
	for live_resource, index in c_live_handles {
		if c_resource_owner(live_resource) == owner {
			ordered_remove(&c_live_handles, index)
			return live_resource, true
		}
	}
	return
}

// Destroys wrappers while their owner's native context remains usable. The
// registry entry is removed first so later C destroy calls are idempotent.
@(private)
c_resource_destroy_owned :: proc(owner: ^Ez_Gfx_C_Context) {
	for {
		resource, found := c_resource_take_owned(owner)
		if !found do return
		switch resource.kind {
		case .Context:
			panic("context entered resource destruction")
		case .Surface:
			surface := cast(^Ez_Gfx_C_Surface)resource.value
			_ = ez_gfx_window_destroy(&surface.surface)
			free(surface)
		case .Shader:
			shader := cast(^Ez_Gfx_C_Shader)resource.value
			_ = ez_gfx_shader_destroy(&shader.shader)
			c_shader_strings_destroy(shader)
			free(shader)
		case .Indirect:
			free(cast(^Ez_Gfx_C_Indirect)resource.value)
		case .Structured:
			free(cast(^Ez_Gfx_C_Structured)resource.value)
		}
	}
}

@(private)
c_context_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Context {
	return cast(^Ez_Gfx_C_Context)c_handle_find(.Context, handle)
}

@(private)
c_surface_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Surface {
	return cast(^Ez_Gfx_C_Surface)c_handle_find(.Surface, handle)
}

@(private)
c_shader_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Shader {
	return cast(^Ez_Gfx_C_Shader)c_handle_find(.Shader, handle)
}

@(private)
c_indirect_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Indirect {
	return cast(^Ez_Gfx_C_Indirect)c_handle_find(.Indirect, handle)
}

@(private)
c_structured_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Structured {
	return cast(^Ez_Gfx_C_Structured)c_handle_find(.Structured, handle)
}

@(private)
c_context_handle :: proc(ctx: ^Ez_Gfx_C_Context) -> u64 {
	if ctx == nil do return 0
	return ctx.opaque_handle
}

@(private)
c_surface_handle :: proc(surface: ^Ez_Gfx_C_Surface) -> u64 {
	if surface == nil do return 0
	return surface.opaque_handle
}

@(private)
c_shader_handle :: proc(shader: ^Ez_Gfx_C_Shader) -> u64 {
	if shader == nil do return 0
	return shader.opaque_handle
}

@(private)
c_indirect_handle :: proc(indirect: ^Ez_Gfx_C_Indirect) -> u64 {
	if indirect == nil do return 0
	return indirect.opaque_handle
}

@(private)
c_structured_handle :: proc(structured: ^Ez_Gfx_C_Structured) -> u64 {
	if structured == nil do return 0
	return structured.opaque_handle
}

@(private)
c_clone_cstring :: proc(value: cstring) -> []u8 {
	if value == nil do return nil
	source := shader_cstring_to_string(value)
	bytes := make([]u8, len(source) + 1)
	if len(source) > 0 {
		mem.copy(raw_data(bytes), raw_data(source), len(source))
	}
	bytes[len(source)] = 0
	return bytes
}

@(private)
c_shader_string :: proc(bytes: []u8) -> cstring {
	if len(bytes) == 0 do return nil
	return cast(cstring)raw_data(bytes)
}

@(private)
c_shader_strings_destroy :: proc(shader: ^Ez_Gfx_C_Shader) {
	if shader == nil do return
	for bytes in shader.string_data {
		if raw_data(bytes) != nil {
			delete(bytes)
		}
	}
	shader.string_data = {}
}

@(private)
c_use_context :: proc(owner: ^Ez_Gfx_C_Context) -> rawptr {
	if owner == nil do return nil
	return &owner.ctx
}

@(private)
c_build_dynamic_state :: proc(
	state: ^Ez_Gfx_C_Dynamic_State,
) -> (
	render_state: Ez_Gfx_Render_Dynamic_State,
	ok: bool,
) {
	if state == nil do return render_state, true
	if state.cull_mode > 3 || state.front_face > 1 {
		return render_state, false
	}
	if state.primitive_type >= u32(len(Ez_Gfx_Primitive_Type)) || state.blend_mode > u32(Ez_Gfx_Blend_Mode.Alpha) {
		return render_state, false
	}
	switch state.cull_mode {
	case 0:
		render_state.cull_mode = {}
	case 1:
		render_state.cull_mode = {.FRONT}
	case 2:
		render_state.cull_mode = {.BACK}
	case 3:
		render_state.cull_mode = {.FRONT, .BACK}
	}
	if state.front_face == 0 {
		render_state.front_face = .COUNTER_CLOCKWISE
	} else {
		render_state.front_face = .CLOCKWISE
	}
	render_state.primitive_type = Ez_Gfx_Primitive_Type(state.primitive_type)
	render_state.blend_mode = Ez_Gfx_Blend_Mode(state.blend_mode)
	return render_state, true
}

@(private)
c_copy_bindings :: proc(
	source: [^]Ez_Gfx_C_Binding,
	count: u32,
	owner: ^Ez_Gfx_C_Context,
	destination: ^[EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding,
) -> bool {
	if count > EZ_GFX_C_MAX_BINDINGS do return false
	if count > 0 && source == nil do return false
	for i in 0 ..< int(count) {
		c_binding := source[i]
		binding := &destination[i]
		binding^ = {}
		if c_binding.name == nil do return false
		binding.name = c_binding.name
		if c_binding.structured != 0 {
			structured := c_structured_from_handle(c_binding.structured)
			if structured == nil || structured.owner != owner || !structured.handle.ok do return false
			binding.structured = structured.handle
		}
		if c_binding.indirect != 0 {
			indirect := c_indirect_from_handle(c_binding.indirect)
			if indirect == nil || indirect.owner != owner || !indirect.handle.ok do return false
			binding.indirect = indirect.handle
		}
	}
	return true
}
@(private)
IMGUI_C_SHADER_PATH :: cstring("examples/4_imgui/imgui.slang")
@(private)
IMGUI_C_IDENTITY_INDEX_COUNT :: 65536

@(private)
c_imgui_context :: proc(owner: ^Ez_Gfx_C_Context) -> ^im.Context {
	if owner == nil || owner.imgui_context == nil do return nil
	return cast(^im.Context)owner.imgui_context
}

@(private)
c_imgui_init :: proc(owner: ^Ez_Gfx_C_Context) -> bool {
	if owner == nil do return false
	if owner.imgui_context != nil {
		im.set_current_context(c_imgui_context(owner))
		return true
	}

	imgui_context := im.create_context()
	if imgui_context == nil do return false
	owner.imgui_context = imgui_context
	im.set_current_context(imgui_context)
	im.CHECKVERSION()

	io := im.get_io()
	io.ini_filename = nil
	io.backend_flags += {.Renderer_Has_Textures}
	io.display_framebuffer_scale = {1, 1}
	io.delta_time = 1.0 / 60.0

	if !shader_compile({
		path = IMGUI_C_SHADER_PATH,
		vertex_entry = EZ_GFX_INTERNAL_DEFAULT_VERTEX_ENTRY,
		fragment_entry = EZ_GFX_INTERNAL_DEFAULT_FRAGMENT_ENTRY,
	}, &owner.imgui_shader) {
		im.destroy_context(imgui_context)
		owner.imgui_context = nil
		return false
	}
	owner.imgui_shader_loaded = true

	indices := make([]u32, IMGUI_C_IDENTITY_INDEX_COUNT)
	defer delete(indices)
	for index in 0 ..< IMGUI_C_IDENTITY_INDEX_COUNT {
		indices[index] = u32(index)
	}
	allocation, ok := vertex_manager_schedule_upload(
		&owner.ctx.vertex_manager,
		.Indices,
		"",
		&owner.ctx.vertex_manager.index_heap,
		raw_data(indices),
		IMGUI_C_IDENTITY_INDEX_COUNT,
		vk.DeviceSize(size_of(u32)),
	)
	if !ok {
		shader_destroy(&owner.imgui_shader)
		owner.imgui_shader_loaded = false
		im.destroy_context(imgui_context)
		owner.imgui_context = nil
		return false
	}
	owner.imgui_identity_index_start = allocation.start_index
	owner.imgui_identity_index_loaded = true
	return true
}

@(private)
c_imgui_upload_textures :: proc(
	owner: ^Ez_Gfx_C_Context,
	draw_data: ^im.Draw_Data,
) -> bool {
	if owner == nil || draw_data == nil || draw_data.textures == nil do return true

	textures := draw_data.textures^
	for texture in mem.slice_ptr(textures.data, int(textures.size)) {
		if texture == nil do continue
		#partial switch texture.status {
		case .Want_Create, .Want_Updates:
			byte_count := int(im.texture_data_get_size_in_bytes(texture))
			pixels := im.texture_data_get_pixels(texture)
			if pixels == nil || byte_count <= 0 do return false

			if owner.imgui_font_texture_loaded {
				ctx_wait_idle()
				_ = unload_texture(owner.imgui_font_texture_id)
				owner.imgui_font_texture_loaded = false
			}

			pixel_data := make([]u8, byte_count)
			mem.copy(raw_data(pixel_data), pixels, byte_count)
			// The texture manager's decode workers borrow this memory until their
			// completion callback. Keep every upload alive until context teardown.
			append(&owner.imgui_texture_data, pixel_data)
			owner.imgui_font_atlas_pixels = pixel_data

			regions := [1]Ez_Gfx_Texture_Memory_Region{{data = pixel_data}}
			texture_desc := Ez_Gfx_Load_Texture_Desc {
				source_format      = .RGBA,
				destination_format = .R8G8B8A8_UNORM,
				width              = u32(texture.width),
				height             = u32(texture.height),
				generate_mips      = false,
				min_filter         = .Linear,
				mag_filter         = .Linear,
				address_mode_u     = .Clamp_To_Edge,
				address_mode_v     = .Clamp_To_Edge,
				address_mode_w     = .Clamp_To_Edge,
				debug_label        = "imgui font atlas",
			}
			texture_id, texture_error := load_texture(regions[:], texture_desc)
			if texture_error != .None do return false
			owner.imgui_font_texture_id = texture_id
			owner.imgui_font_texture_loaded = true
			im.texture_data_set_tex_id(texture, im.Texture_ID(texture_id))
			im.texture_data_set_status(texture, .OK)
		case .Want_Destroy:
			texture_id := Ez_Gfx_Texture_ID(im.texture_data_get_tex_id(texture))
			if texture_id == owner.imgui_font_texture_id && owner.imgui_font_texture_loaded {
				ctx_wait_idle()
				_ = unload_texture(texture_id)
				owner.imgui_font_texture_loaded = false
			}
			im.texture_data_set_status(texture, .Destroyed)
		}
	}
	return true
}

// Releases ImGui GPU objects before the owning Vulkan context is destroyed.
// Pixel buffers intentionally remain owned by Ez_Gfx_C_Context until after the
// texture workers have shut down in ez_gfx_c_context_destroy.
@(private)
c_imgui_destroy :: proc(owner: ^Ez_Gfx_C_Context) {
	if owner == nil do return
	if owner.imgui_context != nil {
		im.set_current_context(c_imgui_context(owner))
	}
	if owner.imgui_font_texture_loaded {
		ctx_wait_idle()
		_ = unload_texture(owner.imgui_font_texture_id)
		owner.imgui_font_texture_loaded = false
	}
	if owner.imgui_shader_loaded {
		ctx_wait_idle()
		shader_destroy(&owner.imgui_shader)
		owner.imgui_shader_loaded = false
	}
	if owner.imgui_context != nil {
		im.destroy_context(c_imgui_context(owner))
		owner.imgui_context = nil
	}
	owner.imgui_font_texture_id = 0
	owner.imgui_font_atlas_pixels = nil
	owner.imgui_identity_index_start = 0
	owner.imgui_identity_index_loaded = false
}
@(private)
c_context_for_handle :: proc "c" (
	context_handle: u64,
) -> (
	odin_context: runtime.Context,
	owner: ^Ez_Gfx_C_Context,
	status: i32,
) {
	odin_context = runtime.default_context()
	context = odin_context
	owner = c_context_from_handle(context_handle)
	if owner == nil do return odin_context, nil, EZ_GFX_C_RESULT_INVALID_CONTEXT
	odin_context.user_ptr = c_use_context(owner)
	if odin_context.user_ptr == nil do return odin_context, nil, EZ_GFX_C_RESULT_INVALID_CONTEXT
	return odin_context, owner, EZ_GFX_C_RESULT_OK
}

@(private)
c_context_surface_for_handle :: proc "c" (
	context_handle, surface_handle: u64,
) -> (
	odin_context: runtime.Context,
	owner: ^Ez_Gfx_C_Context,
	surface: ^Ez_Gfx_C_Surface,
	status: i32,
) {
	odin_context, owner, status = c_context_for_handle(context_handle)
	c_context := odin_context
	if status != EZ_GFX_C_RESULT_OK do return c_context, owner, nil, status
	context = c_context
	// Odin context scope is lexical, so the C adapter reuses c_context for its
	// own subsequent public-call scope after this helper returns.
	surface = c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner != owner {
		return c_context, owner, nil, EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	return c_context, owner, surface, EZ_GFX_C_RESULT_OK
}



// C ABI exports. Link names are intentionally attached only to these C adapters.

@(link_name="ez_gfx_c_abi_version")
@(export)
ez_gfx_c_abi_version :: proc "c" () -> u32 {
	return EZ_GFX_C_ABI_VERSION
}

@(link_name="ez_gfx_c_context_create")
@(export)
ez_gfx_c_context_create :: proc "c" (
	desc: ^Ez_Gfx_C_Context_Desc,
	out_context: ^u64,
) -> i32 {
	context = runtime.default_context()
	if out_context == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_context^ = 0
	if desc == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	// A failed creation must restore the caller's prior Odin context.
	previous_user_ptr := context.user_ptr
	owner := new(Ez_Gfx_C_Context)
	context.user_ptr = c_use_context(owner)
	if context.user_ptr == nil {
		context.user_ptr = previous_user_ptr
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	odin_desc := Ez_Gfx_Ctx_Desc {
		enable_debug      = desc.enable_debug != 0,
		enable_validation = desc.enable_validation != 0,
		surface_platform  = desc.surface_platform,
	}
	status := ez_gfx_ctx_create_instance(&owner.ctx, odin_desc)
	if status != .Ok {
		context.user_ptr = previous_user_ptr
		free(owner)
		return c_status(status)
	}
	c_context_register(owner)
	out_context^ = c_context_handle(owner)
	return EZ_GFX_C_RESULT_OK
}


@(link_name="ez_gfx_c_context_wait_idle")
@(export)
ez_gfx_c_context_wait_idle :: proc "c" (context_handle: u64) -> i32 {
	odin_context, _, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = odin_context
	return c_status(ez_gfx_ctx_wait_idle())
}

@(link_name="ez_gfx_c_context_destroy")
@(export)
ez_gfx_c_context_destroy :: proc "c" (context_handle: u64) {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return
	context = c_context
	c_context_unregister(owner)
	c_imgui_destroy(owner)
	c_resource_destroy_owned(owner)
	_ = ez_gfx_ctx_destroy()
	for bytes in owner.texture_data {
		delete(bytes)
	}
	if raw_data(owner.texture_data) != nil {
		delete(owner.texture_data)
	}
	for bytes in owner.imgui_texture_data {
		delete(bytes)
	}
	if raw_data(owner.imgui_texture_data) != nil {
		delete(owner.imgui_texture_data)
	}
	// No later Odin API call may observe the context after its owner is freed.
	context.user_ptr = nil
	free(owner)
}

@(link_name="ez_gfx_c_surface_create")
@(export)
ez_gfx_c_surface_create :: proc "c" (
	desc: ^Ez_Gfx_C_Surface_Desc,
	out_surface: ^u64,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	if out_surface == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_surface^ = 0
	if desc == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	context = c_context
	surface := new(Ez_Gfx_C_Surface)
	surface.owner = owner
	surface.surface = Ez_Gfx_Window {
		native_window       = desc.window,
		native_display      = desc.display,
		surface_platform    = desc.platform,
		cache_presented_snapshots = false,
		framebuffer_width   = 0,
		framebuffer_height  = 0,
	}
	status := ez_gfx_window_create_surface_u32(&surface.surface, desc.width, desc.height)
	if status != .Ok {
		free(surface)
		return c_status(status)
	}
	surface.opaque_handle = c_resource_register(.Surface, rawptr(surface))
	out_surface^ = c_surface_handle(surface)
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_context_init_device")
@(export)
ez_gfx_c_context_init_device :: proc "c" (surface_handle: u64, context_handle: u64) -> i32 {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_ctx_init_device(surface.surface.surface))
}

@(link_name="ez_gfx_c_surface_resize")
@(export)
ez_gfx_c_surface_resize :: proc "c" (
	surface_handle: u64,
	width, height: u32,
	context_handle: u64,
) -> i32 {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_window_recreate_swapchain_u32(
		&surface.surface,
		width,
		height,
	))
}

@(link_name="ez_gfx_c_surface_get_extent")
@(export)
ez_gfx_c_surface_get_extent :: proc "c" (
	surface_handle: u64,
	out_width: ^u32,
	out_height: ^u32,
	context_handle: u64,
) -> i32 {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	if out_width == nil || out_height == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_width^ = 0
	out_height^ = 0
	width, height, status := ez_gfx_window_get_framebuffer_size(&surface.surface)
	out_width^ = u32(max(width, 0))
	out_height^ = u32(max(height, 0))
	return c_status(status)
}
@(link_name="ez_gfx_c_surface_resize_pending")
@(export)
ez_gfx_c_surface_resize_pending :: proc "c" (
	surface_handle: u64,
	out_pending: ^i32,
	context_handle: u64,
) -> i32 {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	if out_pending == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_pending^ = 0
	pending, status := ez_gfx_window_resize_pending(&surface.surface)
	out_pending^ = i32(pending)
	return c_status(status)
}

@(link_name="ez_gfx_c_surface_set_snapshot_cache")
@(export)
ez_gfx_c_surface_set_snapshot_cache :: proc "c" (
	surface_handle: u64,
	enabled: i32,
	context_handle: u64,
) -> i32 {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_window_set_snapshot_cache_i32(&surface.surface, enabled))
}

@(link_name="ez_gfx_c_surface_destroy")
@(export)
ez_gfx_c_surface_destroy :: proc "c" (surface_handle: u64, context_handle: u64) {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return
	context = c_context
	c_resource_unregister(.Surface, surface_handle)
	_ = ez_gfx_window_destroy(&surface.surface)
	free(surface)
}

@(link_name="ez_gfx_c_shader_compile")
@(export)
ez_gfx_c_shader_compile :: proc "c" (
	desc: ^Ez_Gfx_C_Shader_Desc,
	out_shader: ^u64,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	if out_shader == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_shader^ = 0
	if desc == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	context = c_context
	shader := new(Ez_Gfx_C_Shader)
	shader.owner = owner
	shader.string_data[0] = c_clone_cstring(desc.path)
	shader.string_data[1] = c_clone_cstring(desc.vertex_entry)
	shader.string_data[2] = c_clone_cstring(desc.fragment_entry)
	shader.string_data[3] = c_clone_cstring(desc.compute_entry)
	odin_desc := Ez_Gfx_Shader_Desc {
		path           = c_shader_string(shader.string_data[0]),
		vertex_entry   = c_shader_string(shader.string_data[1]),
		fragment_entry = c_shader_string(shader.string_data[2]),
		compute_entry  = c_shader_string(shader.string_data[3]),
		kind           = Ez_Gfx_Shader_Kind(desc.kind),
	}
	status := ez_gfx_shader_compile(odin_desc, &shader.shader)
	if status != .Ok {
		c_shader_strings_destroy(shader)
		free(shader)
		return c_status(status)
	}
	shader.opaque_handle = c_resource_register(.Shader, rawptr(shader))
	out_shader^ = c_shader_handle(shader)
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_shader_destroy")
@(export)
ez_gfx_c_shader_destroy :: proc "c" (shader_handle: u64, context_handle: u64) {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return
	context = c_context
	shader := c_shader_from_handle(shader_handle)
	if shader == nil || shader.owner != owner do return
	_ = ez_gfx_shader_destroy(&shader.shader)
	c_resource_unregister(.Shader, shader_handle)
	c_shader_strings_destroy(shader)
	free(shader)
}

@(link_name="ez_gfx_c_vertex_heap_create")
@(export)
ez_gfx_c_vertex_heap_create :: proc "c" (
	name: cstring,
	capacity: u64,
	stride: u64,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_vertex_manager_add_heap(
		&owner.ctx.vertex_manager,
		shader_cstring_to_string(name),
		vk.DeviceSize(capacity),
		vk.DeviceSize(stride),
	))
}

@(link_name="ez_gfx_c_index_heap_create")
@(export)
ez_gfx_c_index_heap_create :: proc "c" (
	capacity: u64,
	debug_name: cstring,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_gpu_heap_create(
		&owner.ctx.vertex_manager.index_heap,
		vk.DeviceSize(capacity),
		vk.DeviceSize(size_of(u32)),
		{.INDEX_BUFFER},
		debug_name,
	))
}

@(link_name="ez_gfx_c_vertex_upload_indices")
@(export)
ez_gfx_c_vertex_upload_indices :: proc "c" (
	data: rawptr,
	count: u32,
	out_start_index: ^u32,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	if out_start_index == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_start_index^ = 0
	context = c_context
	start_index, status := ez_gfx_vertex_manager_upload_indices_raw(
		&owner.ctx.vertex_manager,
		data,
		count,
	)
	out_start_index^ = start_index
	return c_status(status)
}

@(link_name="ez_gfx_c_vertex_upload")
@(export)
ez_gfx_c_vertex_upload :: proc "c" (
	heap_name: cstring,
	data: rawptr,
	element_count: u32,
	element_size: u64,
	out_start_index: ^u32,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	if out_start_index == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_start_index^ = 0
	context = c_context
	start_index, status := ez_gfx_vertex_manager_upload_raw(
		&owner.ctx.vertex_manager,
		shader_cstring_to_string(heap_name),
		data,
		element_count,
		vk.DeviceSize(element_size),
	)
	out_start_index^ = start_index
	return c_status(status)
}

@(link_name="ez_gfx_c_enable_all_decoders")
@(export)
ez_gfx_c_enable_all_decoders :: proc "c" (context_handle: u64) -> i32 {
	c_context, _, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_enable_all_decoders())
}

@(link_name="ez_gfx_c_texture_load")
@(export)
ez_gfx_c_texture_load :: proc "c" (
	data: rawptr,
	data_size: u64,
	desc: ^Ez_Gfx_C_Texture_Desc,
	out_texture_id: ^u32,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	if out_texture_id == nil do return i32(Ez_Gfx_Texture_Error.Invalid_Arguments)
	out_texture_id^ = 0
	context = c_context
	owned_bytes, texture_id, err := ez_gfx_texture_load_bytes(data, data_size, desc)
	if err != .None do return i32(err)
	append(&owner.texture_data, owned_bytes)
	out_texture_id^ = u32(texture_id)
	return i32(err)
}

@(link_name="ez_gfx_c_texture_unload")
@(export)
ez_gfx_c_texture_unload :: proc "c" (
	texture_id: u32,
	context_handle: u64,
) -> i32 {
	c_context, _, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	context = c_context
	return i32(ez_gfx_unload_texture(Ez_Gfx_Texture_ID(texture_id)))
}

@(link_name="ez_gfx_c_begin_render")
@(export)
ez_gfx_c_begin_render :: proc "c" (surface_handle: u64, context_handle: u64) -> i32 {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_begin_render(&surface.surface))
}

@(link_name="ez_gfx_c_acquire_indirect")
@(export)
ez_gfx_c_acquire_indirect :: proc "c" (
	capacity: u32,
	debug_name: cstring,
	out_indirect: ^u64,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	if out_indirect == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_indirect^ = 0
	context = c_context
	handle, status := ez_gfx_render_acquire_indirect_buffer(vk.DrawIndexedIndirectCommand, capacity, debug_name)
	if status != .Ok {
		return c_status(status)
	}
	indirect := new(Ez_Gfx_C_Indirect)
	indirect.owner = owner
	indirect.handle = handle
	indirect.opaque_handle = c_resource_register(.Indirect, rawptr(indirect))
	out_indirect^ = c_indirect_handle(indirect)
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_indirect_write_draw")
@(export)
ez_gfx_c_indirect_write_draw :: proc "c" (
	indirect_handle: u64,
	index: u32,
	command: ^Ez_Gfx_C_Draw_Indexed_Command,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	indirect := c_indirect_from_handle(indirect_handle)
	if indirect == nil || indirect.owner != owner {
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	if command == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	odin_command := vk.DrawIndexedIndirectCommand {
		indexCount    = command.index_count,
		instanceCount = command.instance_count,
		firstIndex    = command.first_index,
		vertexOffset  = command.vertex_offset,
		firstInstance = command.first_instance,
	}
	return c_status(ez_gfx_indirect_buffer_write_draw(&indirect.handle, index, odin_command))
}

@(link_name="ez_gfx_c_indirect_set_draw_count")
@(export)
ez_gfx_c_indirect_set_draw_count :: proc "c" (
	indirect_handle: u64,
	count: u32,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	indirect := c_indirect_from_handle(indirect_handle)
	if indirect == nil || indirect.owner != owner {
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	return c_status(ez_gfx_indirect_buffer_set_draw_count(&indirect.handle, count))
}

@(link_name="ez_gfx_c_indirect_release")
@(export)
ez_gfx_c_indirect_release :: proc "c" (indirect_handle: u64, context_handle: u64) {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return
	context = c_context
	indirect := c_indirect_from_handle(indirect_handle)
	if indirect == nil || indirect.owner != owner do return
	c_resource_unregister(.Indirect, indirect_handle)
	free(indirect)
}

@(link_name="ez_gfx_c_structured_acquire")
@(export)
ez_gfx_c_structured_acquire :: proc "c" (
	element_size: u32,
	element_count: u32,
	debug_name: cstring,
	out_structured: ^u64,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	if out_structured == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_structured^ = 0
	context = c_context
	handle, status := ez_gfx_render_acquire_structured_buffer_bytes(element_size, element_count, debug_name)
	if status != .Ok do return c_status(status)
	structured := new(Ez_Gfx_C_Structured)
	structured.owner = owner
	structured.handle = handle
	structured.opaque_handle = c_resource_register(.Structured, rawptr(structured))
	out_structured^ = c_structured_handle(structured)
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_structured_write")
@(export)
ez_gfx_c_structured_write :: proc "c" (
	structured_handle: u64,
	data: rawptr,
	data_size: u64,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	structured := c_structured_from_handle(structured_handle)
	if structured == nil || structured.owner != owner {
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	return c_status(ez_gfx_structured_buffer_write(&structured.handle, data, data_size))
}

@(link_name="ez_gfx_c_structured_release")
@(export)
ez_gfx_c_structured_release :: proc "c" (structured_handle: u64, context_handle: u64) {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return
	context = c_context
	structured := c_structured_from_handle(structured_handle)
	if structured == nil || structured.owner != owner do return
	c_resource_unregister(.Structured, structured_handle)
	free(structured)
}

@(link_name="ez_gfx_c_render_add_vertex_pipeline")
@(export)
ez_gfx_c_render_add_vertex_pipeline :: proc "c" (
	shader_handle: u64,
	indirect_handle: u64,
	bindings: [^]Ez_Gfx_C_Binding,
	binding_count: u32,
	dynamic_state: ^Ez_Gfx_C_Dynamic_State,
	push_constants: rawptr,
	push_constant_size: u32,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	shader := c_shader_from_handle(shader_handle)
	indirect := c_indirect_from_handle(indirect_handle)
	if shader == nil || shader.owner != owner || indirect == nil || indirect.owner != owner {
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	return c_status(render_add_vertex_pipeline_from_c(
		owner,
		&shader.shader,
		indirect.handle,
		bindings,
		binding_count,
		dynamic_state,
		push_constants,
		push_constant_size,
	))
}

@(link_name="ez_gfx_c_render_add_compute_pipeline")
@(export)
ez_gfx_c_render_add_compute_pipeline :: proc "c" (
	shader_handle: u64,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: [^]Ez_Gfx_C_Binding,
	binding_count: u32,
	push_constants: rawptr,
	push_constant_size: u32,
	context_handle: u64,
) -> i32 {
	c_context, owner, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	shader := c_shader_from_handle(shader_handle)
	if shader == nil || shader.owner != owner {
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	return c_status(render_add_compute_pipeline_from_c(
		owner,
		&shader.shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		bindings,
		binding_count,
		push_constants,
		push_constant_size,
	))
}

@(link_name="ez_gfx_c_finish_render")
@(export)
ez_gfx_c_finish_render :: proc "c" (context_handle: u64) -> i32 {
	c_context, _, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_finish_render())
}

@(link_name="ez_gfx_c_screenshot_save")
@(export)
ez_gfx_c_screenshot_save :: proc "c" (
	surface_handle: u64,
	path: cstring,
	context_handle: u64,
) -> i32 {
	c_context, _, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	return c_status(ez_gfx_screenshot_save_window(&surface.surface, shader_cstring_to_string(path)))
}
@(link_name="ez_gfx_c_imgui_render_demo")
@(export)
ez_gfx_c_imgui_render_demo :: proc "c" (surface_handle: u64, context_handle: u64) -> i32 {
	c_context, owner, surface, context_status := c_context_surface_for_handle(context_handle, surface_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	context = c_context
	if !c_imgui_init(owner) do return EZ_GFX_C_RESULT_NATIVE_FAILURE

	width, height := window_get_framebuffer_size(&surface.surface)
	if width <= 0 || height <= 0 do return EZ_GFX_C_RESULT_NOT_READY
	im.set_current_context(c_imgui_context(owner))
	io := im.get_io()
	io.display_size = {f32(width), f32(height)}

	im.new_frame()
	im.show_demo_window(nil)
	im.render()
	draw_data := im.get_draw_data()
	if draw_data == nil || !draw_data.valid do return EZ_GFX_C_RESULT_NATIVE_FAILURE
	if !c_imgui_upload_textures(owner, draw_data) {
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	}

	if draw_data.cmd_lists_count <= 0 || draw_data.total_vtx_count <= 0 || draw_data.total_idx_count <= 0 {
		if status := ez_gfx_begin_render(&surface.surface); status != .Ok do return c_status(status)
		return c_status(ez_gfx_finish_render())
	}

	total_vtx := int(draw_data.total_vtx_count)
	total_idx := int(draw_data.total_idx_count)
	total_cmds := 0
	cmd_lists := mem.slice_ptr(draw_data.cmd_lists.data, int(draw_data.cmd_lists_count))
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		for cmd in mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size)) {
			if cmd.user_callback == nil do total_cmds += 1
		}
	}
	if total_cmds == 0 do return EZ_GFX_C_RESULT_NATIVE_FAILURE

	vertices := make([]Ez_Gfx_C_ImGui_Vertex, total_vtx)
	indices := make([]u32, total_idx)
	commands := make([]Ez_Gfx_C_ImGui_Draw_Command, total_cmds)
	defer delete(vertices)
	defer delete(indices)
	defer delete(commands)

	display_pos := draw_data.display_pos
	framebuffer_scale := draw_data.framebuffer_scale
	vtx_offset := 0
	idx_offset := 0
	cmd_offset := 0
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		vtx := mem.slice_ptr(cmd_list.vtx_buffer.data, int(cmd_list.vtx_buffer.size))
		for vertex_index in 0 ..< len(vtx) {
			source := vtx[vertex_index]
			destination := &vertices[vtx_offset + vertex_index]
			destination.pos = {
				(source.pos.x - display_pos.x) * framebuffer_scale.x,
				(source.pos.y - display_pos.y) * framebuffer_scale.y,
			}
			destination.uv = source.uv
			destination.col = source.col
		}

		idx := mem.slice_ptr(cmd_list.idx_buffer.data, int(cmd_list.idx_buffer.size))
		for index_index in 0 ..< len(idx) {
			indices[idx_offset + index_index] = u32(idx[index_index])
		}

		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for source_index in 0 ..< len(cmds) {
			source := &cmds[source_index]
			if source.user_callback != nil do continue
			destination := &commands[cmd_offset]
			clip := source.clip_rect
			destination.clip_rect = {
				(clip.x - display_pos.x) * framebuffer_scale.x,
				(clip.y - display_pos.y) * framebuffer_scale.y,
				(clip.z - display_pos.x) * framebuffer_scale.x,
				(clip.w - display_pos.y) * framebuffer_scale.y,
			}
			destination.texture_id = u32(im.draw_cmd_get_tex_id(source))
			destination.idx_offset = u32(idx_offset) + source.idx_offset
			destination.vtx_offset = u32(vtx_offset) + source.vtx_offset
			cmd_offset += 1
		}
		vtx_offset += len(vtx)
		idx_offset += len(idx)
	}

	if status := ez_gfx_begin_render(&surface.surface); status != .Ok do return c_status(status)
	vertex_buffer, vertex_status := ez_gfx_render_acquire_structured_buffer(
		Ez_Gfx_C_ImGui_Vertex,
		u32(total_vtx),
		"imgui vertices",
	)
	if vertex_status != .Ok {
		get_current_ctx().render = {}
		return c_status(vertex_status)
	}
	index_buffer, index_status := ez_gfx_render_acquire_structured_buffer(
		u32,
		u32(total_idx),
		"imgui indices",
	)
	if index_status != .Ok {
		get_current_ctx().render = {}
		return c_status(index_status)
	}
	command_buffer, command_status := ez_gfx_render_acquire_structured_buffer(
		Ez_Gfx_C_ImGui_Draw_Command,
		u32(total_cmds),
		"imgui draw commands",
	)
	if command_status != .Ok {
		get_current_ctx().render = {}
		return c_status(command_status)
	}
	mem.copy(vertex_buffer.elements, raw_data(vertices), len(vertices) * size_of(Ez_Gfx_C_ImGui_Vertex))
	mem.copy(index_buffer.elements, raw_data(indices), len(indices) * size_of(u32))
	mem.copy(command_buffer.elements, raw_data(commands), len(commands) * size_of(Ez_Gfx_C_ImGui_Draw_Command))

	indirect, indirect_status := ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		u32(total_cmds),
		"imgui indirect draws",
	)
	if indirect_status != .Ok {
		get_current_ctx().render = {}
		return c_status(indirect_status)
	}
	bindings := [3]Ez_Gfx_Render_Binding {
		{name = "imgui_vertices", structured = vertex_buffer.handle},
		{name = "imgui_indices", structured = index_buffer.handle},
		{name = "imgui_commands", structured = command_buffer.handle},
	}
	push := Ez_Gfx_C_ImGui_Push_Constants{display_size = {
		draw_data.display_size.x * draw_data.framebuffer_scale.x,
		draw_data.display_size.y * draw_data.framebuffer_scale.y,
	}}
	_, pipeline_status := ez_gfx_render_add_vertex_pipeline(
		&owner.imgui_shader,
		indirect,
		bindings[:],
		{blend_mode = .Alpha},
		push,
	)
	if pipeline_status != .Ok {
		get_current_ctx().render = {}
		return c_status(pipeline_status)
	}

	active_command := 0
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for source_index in 0 ..< len(cmds) {
			source := &cmds[source_index]
			if source.user_callback != nil do continue
			draw := vk.DrawIndexedIndirectCommand {
				indexCount = source.elem_count,
				instanceCount = 1,
				firstIndex = owner.imgui_identity_index_start,
				vertexOffset = 0,
				firstInstance = u32(active_command),
			}
			if status := ez_gfx_indirect_buffer_write_draw(&indirect, u32(active_command), draw); status != .Ok {
				get_current_ctx().render = {}
				return c_status(status)
			}
			active_command += 1
		}
	}
	if status := ez_gfx_indirect_buffer_set_draw_count(&indirect, u32(active_command)); status != .Ok {
		get_current_ctx().render = {}
		return c_status(status)
	}
	return c_status(ez_gfx_finish_render())
}
