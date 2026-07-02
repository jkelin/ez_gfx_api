package tests

import gfx "../src"
import "core:os"
import "core:testing"

Shader_Case :: struct {
	path:                  cstring,
	should_pass:           bool,
	expected_usages:       int,
	expected_declarations: int,
}

shader_test_ctx: gfx.Ez_Gfx_Ctx

@(test)
valid_targets_reflects_metadata :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/valid_targets.slang", true, 2, 1})
}

@(test)
multiple_color_targets_reflects_metadata :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/multiple_color_targets.slang", true, 3, 2})
}

@(test)
color_history_read_reflects_metadata :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/color_history_read.slang", true, 1, 1})
}

@(test)
managed_rwtexture_reflects_as_target_declaration :: proc(t: ^testing.T) {
	program, ok := reflect_shader(t, "tests/rt_storage_write.slang")
	if !ok do return
	testing.expect_value(t, program.target_usage_count, 1)
	testing.expect_value(t, program.target_declaration_count, 1)
	testing.expect(t, program.target_declarations[0].storage)
}

@(test)
load_target_reflects_metadata :: proc(t: ^testing.T) {
	program, ok := reflect_shader(t, "tests/load_target.slang")
	if !ok do return
	testing.expect_value(t, program.target_declaration_count, 1)
	testing.expect(t, program.target_declarations[0].load_on_frame_begin)
}

@(test)
invalid_load_target_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/invalid_load_target.slang", false, 0, 0})
}

@(test)
missing_declaration_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/missing_declaration.slang", false, 0, 0})
}

@(test)
duplicate_target_declarations_are_rejected :: proc(t: ^testing.T) {
	program: gfx.Ez_Gfx_Shader_Program
	testing.expect(
		t,
		gfx.ez_gfx_copy_shader_target_name_cstring(
			program.target_declarations[0].name[:],
			&program.target_declarations[0].name_len,
			"depth",
		),
	)
	testing.expect(
		t,
		gfx.ez_gfx_copy_shader_target_name_cstring(
			program.target_declarations[1].name[:],
			&program.target_declarations[1].name_len,
			"depth",
		),
	)
	program.target_declaration_count = 2
	testing.expect(t, !gfx.ez_gfx_shader_validate_unique_target_declarations(&program))
}

@(test)
invalid_access_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/invalid_access.slang", false, 0, 0})
}

@(test)
invalid_scale_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/invalid_scale.slang", false, 0, 0})
}

@(test)
missing_scale_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/missing_scale.slang", false, 0, 0})
}

@(test)
swapchain_read_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/swapchain_read.slang", false, 0, 0})
}

@(test)
compute_structured_reflects_metadata :: proc(t: ^testing.T) {
	program, ok := reflect_compute_shader(t, "tests/compute_structured.slang")
	if !ok do return

	testing.expect_value(t, program.structured_buffer_binding_count, 1)
	testing.expect_value(t, program.structured_buffer_bindings[0].access, gfx.Ez_Gfx_Buffer_Access.Read_Write)
	testing.expect(t, program.structured_buffer_bindings[0].stages == {.COMPUTE})
}

@(test)
compute_indirect_reflects_count_and_elements :: proc(t: ^testing.T) {
	program, ok := reflect_compute_shader(t, "tests/compute_indirect.slang")
	if !ok do return

	testing.expect_value(t, program.structured_buffer_binding_count, 2)
	count_binding := &program.structured_buffer_bindings[0]
	element_binding := &program.structured_buffer_bindings[1]
	testing.expect(
		t,
		gfx.ez_gfx_shader_target_name_equals_cstring(
			count_binding.name[:],
			count_binding.name_len,
			"draws.count",
		),
	)
	testing.expect(
		t,
		gfx.ez_gfx_shader_target_name_equals_cstring(
			element_binding.name[:],
			element_binding.name_len,
			"draws.elements",
		),
	)
	testing.expect_value(t, count_binding.access, gfx.Ez_Gfx_Buffer_Access.Read_Write)
	testing.expect_value(t, element_binding.access, gfx.Ez_Gfx_Buffer_Access.Read_Write)
	testing.expect_value(t, count_binding.binding, u32(0))
	testing.expect_value(t, element_binding.binding, u32(1))
	testing.expect(t, count_binding.stages == {.COMPUTE})
	testing.expect(t, element_binding.stages == {.COMPUTE})
}

@(test)
graphics_structured_reflects_metadata :: proc(t: ^testing.T) {
	program, ok := reflect_shader(t, "tests/graphics_structured.slang")
	if !ok do return

	testing.expect_value(t, program.vertex_heap_binding_count, 1)
	testing.expect_value(t, program.structured_buffer_binding_count, 1)
	testing.expect_value(t, program.structured_buffer_bindings[0].access, gfx.Ez_Gfx_Buffer_Access.Read)
}

@(test)
structured_unsupported_set_fails_reflection :: proc(t: ^testing.T) {
	program, ok := reflect_shader(t, "tests/structured_unsupported_set.slang")
	_ = program
	testing.expect(t, !ok)
}

@(test)
color_feedback_loop_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/color_feedback_loop.slang", false, 0, 0})
}

@(test)
color_depth_mismatch_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/color_depth_mismatch.slang", false, 0, 0})
}

@(test)
unsupported_set_fails_reflection :: proc(t: ^testing.T) {
	expect_shader_case(t, {"tests/unsupported_set.slang", false, 0, 0})
}

@(test)
shader_path_resolves_from_parent_directory :: proc(t: ^testing.T) {
	cwd, cwd_err := os.getwd(context.allocator)
	if !testing.expectf(t, cwd_err == nil, "failed to get cwd: %v", cwd_err) {
		return
	}
	defer delete(cwd)

	if err := os.setwd("out");
	   !testing.expectf(t, err == nil, "failed to enter out directory: %v", err) {
		return
	}
	defer os.setwd(cwd)

	expect_shader_case(t, {"examples/1_triangle/triangle.slang", true, 0, 0})
}

expect_shader_case :: proc(t: ^testing.T, test_case: Shader_Case) {
	program, ok := reflect_shader(t, test_case.path)
	if !testing.expectf(
		t,
		ok == test_case.should_pass,
		"shader reflection case failed: %v expected=%v got=%v",
		test_case.path,
		test_case.should_pass,
		ok,
	) {
		return
	}

	if !ok do return
	if test_case.expected_usages > 0 {
		testing.expect_value(t, program.target_usage_count, test_case.expected_usages)
	}
	if test_case.expected_declarations > 0 {
		testing.expect_value(t, program.target_declaration_count, test_case.expected_declarations)
	}
}

reflect_shader :: proc(
	t: ^testing.T,
	path: cstring,
) -> (
	program: gfx.Ez_Gfx_Shader_Program,
	ok: bool,
) {
	_ = t
	gfx.ez_gfx_set_current_ctx(&shader_test_ctx)
	ok = gfx.ez_gfx_shader_reflect(
		{
			path = path,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&program,
	)
	return
}

reflect_compute_shader :: proc(
	t: ^testing.T,
	path: cstring,
) -> (
	program: gfx.Ez_Gfx_Shader_Program,
	ok: bool,
) {
	_ = t
	gfx.ez_gfx_set_current_ctx(&shader_test_ctx)
	ok = gfx.ez_gfx_shader_reflect(
		{
			path = path,
			compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
			kind = .Compute,
		},
		&program,
	)
	return
}
