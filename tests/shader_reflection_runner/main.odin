package main

import gfx "../../src"
import "core:fmt"

Shader_Case :: struct {
	path:                  cstring,
	should_pass:           bool,
	expected_usages:       int,
	expected_declarations: int,
}

main :: proc() {
	ctx: gfx.Ez_Gfx_Ctx
	gfx.ez_gfx_set_current_ctx(&ctx)
	defer gfx.ez_gfx_shader_destroy_session(&ctx)

	cases := [?]Shader_Case {
		{"tests/shader_reflection/shaders/valid_targets.slang", true, 2, 1},
		{"tests/shader_reflection/shaders/multiple_color_targets.slang", true, 3, 2},
		{"tests/shader_reflection/shaders/missing_declaration.slang", false, 0, 0},
		{"tests/shader_reflection/shaders/duplicate_declaration.slang", false, 0, 0},
		{"tests/shader_reflection/shaders/invalid_access.slang", false, 0, 0},
		{"tests/shader_reflection/shaders/invalid_scale.slang", false, 0, 0},
		{"tests/shader_reflection/shaders/missing_scale.slang", false, 0, 0},
		{"tests/shader_reflection/shaders/swapchain_read.slang", false, 0, 0},
		{"tests/shader_reflection/shaders/color_depth_mismatch.slang", false, 0, 0},
		{"tests/shader_reflection/shaders/unsupported_set.slang", false, 0, 0},
	}

	failed := 0
	for test_case in cases {
		program: gfx.Ez_Gfx_Shader_Program
		ok := gfx.ez_gfx_shader_reflect(
			{
				path = test_case.path,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&program,
		)
		if ok != test_case.should_pass {
			fmt.eprintf(
				"shader reflection case failed: %v expected=%v got=%v\n",
				test_case.path,
				test_case.should_pass,
				ok,
			)
			failed += 1
			continue
		}

		if ok &&
		   (program.target_usage_count != test_case.expected_usages ||
				   program.target_declaration_count != test_case.expected_declarations) {
			fmt.eprintf(
				"shader reflection metadata failed: %v usages=%d/%d declarations=%d/%d\n",
				test_case.path,
				program.target_usage_count,
				test_case.expected_usages,
				program.target_declaration_count,
				test_case.expected_declarations,
			)
			failed += 1
		}
	}

	if failed > 0 {
		fmt.eprintf("shader reflection tests failed: %d\n", failed)
		panic("shader reflection tests failed")
	}

	fmt.println("shader reflection tests passed")
}
