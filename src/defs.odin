package ez_gfx

import sp "../vendor/odin-slang/slang"
import vma "../vendor/odin-vma"
import ga "./generational_arena"
import "core:c"
import "core:sync"
import "core:thread"
import vk "vendor:vulkan"

Ez_Gfx_Buffer :: struct {
	handle:          vk.Buffer,
	allocation:      vma.Allocation,
	allocation_info: vma.Allocation_Info,
	size:            vk.DeviceSize,
	mapped_data:     rawptr,
}

// Moved from src\\ctx.odin:19.
Ez_Gfx_Frame_Slot :: struct {
	command_buffers:         [EZ_GFX_FRAME_COMMAND_BUFFERS]vk.CommandBuffer,
	image_available:         vk.Semaphore,
	last_submitted_timeline: u64,
}

// Moved from src\\ctx.odin:25.
Ez_Gfx_Validation_Message :: struct {
	severity:        vk.DebugUtilsMessageSeverityFlagsEXT,
	message_type:    vk.DebugUtilsMessageTypeFlagsEXT,
	message_id_name: cstring,
	message:         cstring,
}

// Moved from src\\ctx.odin:32.
Ez_Gfx_Validation_Callback :: #type proc(
	ctx: ^Ez_Gfx_Ctx,
	message: Ez_Gfx_Validation_Message,
	user_data: rawptr,
)

// Moved from src\\ctx.odin:38.
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

// Moved from src\\ctx.odin:52.
Ez_Gfx_Validation_Counts :: struct {
	verbose: u32,
	info:    u32,
	warning: u32,
	error:   u32,
}

// Moved from src\\ctx.odin:59.
Ez_Gfx_Ctx_Info :: struct {
	swapchain_present_modes:      [EZ_GFX_MAX_PRESENT_MODES]vk.PresentModeKHR,
	swapchain_present_mode_count: u32,
	swapchain_present_mode:       vk.PresentModeKHR,
	validation_counts:            Ez_Gfx_Validation_Counts,
}

// Moved from src\\ctx.odin:65.
@(private)
Ez_Gfx_Handle_Resource_Kind :: enum u8 {
	Surface,
	Shader,
	Indirect,
	Structured,
	Render_Target,
	Texture,
}

@(private)
Ez_Gfx_Handle_Identity :: struct {
	kind:  Ez_Gfx_Handle_Resource_Kind,
	local: ga.Handle,
}

@(private)
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
	local_handle:                         ga.Handle,
	handle_identity_arena:                ga.Arena(Ez_Gfx_Handle_Identity),
	surface_arena:                        ga.Arena(Ez_Gfx_Window),
	shader_arena:                         ga.Arena(Ez_Gfx_Shader_Program),
	indirect_arena:                       ga.Arena(Ez_Gfx_Indirect_Buffer_Handle),
	structured_arena:                     ga.Arena(Ez_Gfx_Structured_Buffer_Handle),
	render_target_arena:                  ga.Arena(Ez_Gfx_Render_Target_Id),
	texture_arena:                        ga.Arena(Ez_Gfx_Texture_ID),
	c_texture_data:                       [dynamic][]u8,
	imgui_context:                        rawptr,
	imgui_shader:                         Ez_Gfx_Shader_Handle,
	imgui_shader_loaded:                  bool,
	imgui_font_texture:                   Ez_Gfx_Texture_Handle,
	imgui_font_texture_loaded:            bool,
	imgui_font_atlas_pixels:              []u8,
	imgui_texture_data:                   [dynamic][]u8,
	imgui_identity_index_start:           u32,
	imgui_identity_index_loaded:          bool,
}

// Moved from src\\indirect_buffer.odin:9.
Ez_Gfx_Multi_Draw_Indirect_Buffer :: struct {
	buffer:             Ez_Gfx_Buffer,
	stride:             vk.DeviceSize,
	draw_offset:        vk.DeviceSize,
	capacity:           u32,
	in_use:             bool,
	last_used_timeline: u64,
}

// Moved from src\\indirect_buffer.odin:18.
Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager :: struct {
	buffers: [EZ_GFX_MAX_INDIRECT_BUFFERS]Ez_Gfx_Multi_Draw_Indirect_Buffer,
	count:   int,
}

// Moved from src\\indirect_buffer.odin:23.
Ez_Gfx_Indirect_Buffer_Handle :: struct {
	buffer:   ^Ez_Gfx_Multi_Draw_Indirect_Buffer,
	stride:   vk.DeviceSize,
	capacity: u32,
	frame_id: u64,
	ok:       bool,
}

// Moved from src\\indirect_buffer.odin:31.
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

// Moved from src\\pipeline.odin:14.
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

// Moved from src\\pipeline.odin:31.
Ez_Gfx_Primitive_Type :: enum u8 {
	Triangle_List,
	Point_List,
	Line_List,
	Line_Strip,
	Triangle_Strip,
	Triangle_Fan,
}

// Moved from src\\pipeline.odin:42.
Ez_Gfx_Render_Dynamic_State :: struct {
	cull_mode:      vk.CullModeFlags,
	front_face:     vk.FrontFace,
	primitive_type: Ez_Gfx_Primitive_Type,
	blend_mode:     Ez_Gfx_Blend_Mode,
}

// Moved from src\\pipeline.odin:69.
Ez_Gfx_Pipeline_Manager :: struct {
	records: [EZ_GFX_MAX_PIPELINES]Ez_Gfx_Pipeline_Record,
	count:   int,
	clock:   u64,
}

// Moved from src\\pipeline.odin:75.
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

// Moved from src\\render.odin:12.
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
@(private)
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
	slang_module:  ^sp.IModule,
	vertex_entry:  ^sp.IEntryPoint,
	fragment_entry: ^sp.IEntryPoint,
	compute_entry: ^sp.IEntryPoint,
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
Ez_Gfx_Public_Render_Binding :: struct {
	name:          cstring,
	structured:    Ez_Gfx_Structured_Handle,
	indirect:      Ez_Gfx_Indirect_Handle,
	render_target: Ez_Gfx_Render_Target_Handle,
}

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
	presented_snapshot_valid: bool,
}
// Moved from src\texture_manager.odin:23.
@(private)
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
	cond:                             sync.Cond,
	jobs:                             [dynamic]Ez_Gfx_Vertex_Upload_Job,
	pending_staging:                 [dynamic]Ez_Gfx_Vertex_Staging_Retire_Job,
	pending_graphics_handoffs:       [dynamic]Ez_Gfx_Vertex_Graphics_Handoff_Job,
	shutdown:                        bool,
	latest_scheduled_vertex_timeline: u64,
	latest_submitted_vertex_timeline: u64,
}

// Moved from src\window.odin:15.
@(private)
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

// Public opaque handles share one packed u64 layout. Distinct Odin types keep
// call sites from mixing resource kinds even though C sees uint64_t.
// Packing helpers and bit-layout constants live in the private handles module.
Ez_Gfx_Context_Handle :: distinct u64
Ez_Gfx_Surface_Handle :: distinct u64
Ez_Gfx_Shader_Handle :: distinct u64
Ez_Gfx_Indirect_Handle :: distinct u64
Ez_Gfx_Structured_Handle :: distinct u64
Ez_Gfx_Render_Target_Handle :: distinct u64
Ez_Gfx_Texture_Handle :: distinct u64

Ez_Gfx_Surface_Desc :: struct {
	native_window: rawptr,
	native_display: rawptr,
	platform: u32,
	width: u32,
	height: u32,
	cache_presented_snapshots: bool,
}

// Public constants used by the example-facing Odin API.
EZ_GFX_DEFAULT_COMPUTE_ENTRY :: cstring("computemain")
EZ_GFX_DEFAULT_FRAGMENT_ENTRY :: cstring("fragmentmain")
EZ_GFX_DEFAULT_VERTEX_ENTRY :: cstring("vertexmain")
EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES :: vk.DeviceSize(1024 * 1024)
EZ_GFX_SURFACE_PLATFORM_GLFW :: u32(1)
EZ_GFX_SURFACE_PLATFORM_WIN32 :: u32(0)
SCREENSHOT_PATH :: "screenshot.png"


// Public status values are the stable result vocabulary for Odin and C APIs.
Ez_Gfx_Status :: enum u8 {
	Ok,
	Invalid_Argument,
	Invalid_Context,
	Native_Failure,
	Not_Ready,
}
