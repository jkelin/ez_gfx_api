#+test
package ez_gfx

import ga "./generational_arena"
import "core:testing"

@(private)
test_context_insert :: proc(t: ^testing.T) -> (Ez_Gfx_Context_Handle, ^Ez_Gfx_Ctx, ga.Handle) {
	if !testing.expect(t, ensure_context_arena()) do return 0, nil, {}
	local, err := ga.insert(&context_arena, Ez_Gfx_Ctx{})
	if err == .None {
		ctx, get_err := ga.get(&context_arena, local)
		if get_err == .None {
			ctx.local_handle = local
			if !ctx_child_arenas_init(ctx) {
				_ = ga.remove(&context_arena, local)
				return 0, nil, {}
			}
			handle, ok := handle_pack_context(local)
			if !testing.expect(t, ok) {
				ctx_child_arenas_destroy(ctx)
				_ = ga.remove(&context_arena, local)
				return 0, nil, {}
			}
			return handle, ctx, local
		}
	}
	ga.destroy(&context_arena)
	context_arena_ready = false
	if !testing.expect(t, ensure_context_arena()) do return 0, nil, {}
	local, err = ga.insert(&context_arena, Ez_Gfx_Ctx{})
	if !testing.expect_value(t, err, ga.Error.None) do return 0, nil, {}
	ctx, get_err := ga.get(&context_arena, local)
	if !testing.expect_value(t, get_err, ga.Error.None) do return 0, nil, {}
	ctx.local_handle = local
	if !testing.expect(t, ctx_child_arenas_init(ctx)) {
		_ = ga.remove(&context_arena, local)
		return 0, nil, {}
	}
	handle, ok := handle_pack_context(local)
	if !testing.expect(t, ok) {
		ctx_child_arenas_destroy(ctx)
		_ = ga.remove(&context_arena, local)
		return 0, nil, {}
	}
	return handle, ctx, local
}

@(private)
test_context_remove :: proc(ctx: ^Ez_Gfx_Ctx) {
	if ctx == nil do return
	local := ctx.local_handle
	ctx_child_arenas_destroy(ctx)
	_ = ga.remove(&context_arena, local)
}

@(test)
handles_stale_context_reuse_fails :: proc(t: ^testing.T) {
	handle, ctx, local := test_context_insert(t)
	if ctx == nil do return
	test_context_remove(ctx)
	_, stale_status := resolve_context(handle)
	testing.expect_value(t, stale_status, Ez_Gfx_Status.Invalid_Context)

	reused_local, err := ga.insert(&context_arena, Ez_Gfx_Ctx{})
	if !testing.expect_value(t, err, ga.Error.None) do return
	defer {
		if reused_ctx, get_err := ga.get(&context_arena, reused_local); get_err == .None do ctx_child_arenas_destroy(reused_ctx)
		_ = ga.remove(&context_arena, reused_local)
	}
	testing.expect_value(t, reused_local.slot, local.slot)
	testing.expect(t, reused_local.generation != local.generation)
	_, reused_stale_status := resolve_context(handle)
	testing.expect_value(t, reused_stale_status, Ez_Gfx_Status.Invalid_Context)
}

@(test)
handles_child_owner_and_cross_context_fail_closed :: proc(t: ^testing.T) {
	owner_handle, owner, _ := test_context_insert(t)
	if owner == nil do return
	defer test_context_remove(owner)
	other_handle, other, _ := test_context_insert(t)
	if other == nil do return
	defer test_context_remove(other)
	_ = owner_handle
	_ = other_handle

	child_local, err := ga.insert(&owner.surface_arena, Ez_Gfx_Window{native_window = rawptr(uintptr(1)), surface_platform = u32(EZ_GFX_SURFACE_PLATFORM_GLFW), framebuffer_width = 1, framebuffer_height = 1})
	if !testing.expect_value(t, err, ga.Error.None) do return
	defer _ = ga.remove(&owner.surface_arena, child_local)
	packed, pack_status := pack_child_handle(owner, .Surface, child_local)
	if !testing.expect_value(t, pack_status, Ez_Gfx_Status.Ok) do return

	resolved, resolve_status := resolve_surface(owner, Ez_Gfx_Surface_Handle(packed))
	testing.expect_value(t, resolve_status, Ez_Gfx_Status.Ok)
	testing.expect(t, resolved != nil)
	_, cross_status := resolve_surface(other, Ez_Gfx_Surface_Handle(packed))
	testing.expect_value(t, cross_status, Ez_Gfx_Status.Invalid_Context)
}

@(test)
handles_cross_kind_reuse_fails_closed :: proc(t: ^testing.T) {
	_, owner, _ := test_context_insert(t)
	if owner == nil do return
	defer test_context_remove(owner)

	surface_local, surface_err := ga.insert(&owner.surface_arena, Ez_Gfx_Window{native_window = rawptr(uintptr(2)), surface_platform = u32(EZ_GFX_SURFACE_PLATFORM_GLFW), framebuffer_width = 1, framebuffer_height = 1})
	if !testing.expect_value(t, surface_err, ga.Error.None) do return
	defer _ = ga.remove(&owner.surface_arena, surface_local)
	packed, pack_status := pack_child_handle(owner, .Surface, surface_local)
	if !testing.expect_value(t, pack_status, Ez_Gfx_Status.Ok) do return

	// Same packed bits presented as a shader handle must fail kind validation.
	_, shader_status := resolve_shader(owner, Ez_Gfx_Shader_Handle(packed))
	testing.expect_value(t, shader_status, Ez_Gfx_Status.Invalid_Context)
}

@(test)
handles_forged_child_bits_fail_closed :: proc(t: ^testing.T) {
	_, owner, _ := test_context_insert(t)
	if owner == nil do return
	defer test_context_remove(owner)
	forged := u64(0)
	forged |= (u64(owner.local_handle.slot) + 1) << HANDLE_CONTEXT_SLOT_SHIFT
	forged |= u64(owner.local_handle.generation) << HANDLE_CONTEXT_GEN_SHIFT
	forged |= u64(HANDLE_MAX_CHILD_SLOT_PLUS_ONE) << HANDLE_CHILD_SLOT_SHIFT
	forged |= u64(1) << HANDLE_CHILD_GEN_SHIFT
	_, status := resolve_surface(owner, Ez_Gfx_Surface_Handle(forged))
	testing.expect_value(t, status, Ez_Gfx_Status.Invalid_Context)
}

@(test)
handles_context_destruction_invalidates_children :: proc(t: ^testing.T) {
	handle, owner, _ := test_context_insert(t)
	if owner == nil do return
	child_local, err := ga.insert(&owner.shader_arena, Ez_Gfx_Shader_Program{})
	if !testing.expect_value(t, err, ga.Error.None) do return
	packed, pack_status := pack_child_handle(owner, .Shader, child_local)
	if !testing.expect_value(t, pack_status, Ez_Gfx_Status.Ok) do return
	_, before_status := resolve_shader(owner, Ez_Gfx_Shader_Handle(packed))
	testing.expect_value(t, before_status, Ez_Gfx_Status.Ok)

	ctx_child_arenas_destroy(owner)
	_, after_status := resolve_shader(owner, Ez_Gfx_Shader_Handle(packed))
	testing.expect_value(t, after_status, Ez_Gfx_Status.Invalid_Context)

	local := owner.local_handle
	_ = ga.remove(&context_arena, local)
	_, context_status := resolve_context(handle)
	testing.expect_value(t, context_status, Ez_Gfx_Status.Invalid_Context)
}
