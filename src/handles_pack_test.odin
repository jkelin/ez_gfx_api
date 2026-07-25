#+test
#+private
package ez_gfx

import "core:testing"

@(test)
handles_zero_invalid :: proc(t: ^testing.T) {
	_, ok := handle_unpack(0)
	testing.expect(t, !ok)
}

@(test)
handles_context_round_trip :: proc(t: ^testing.T) {
	local := Handle{slot = 3, generation = INITIAL_GENERATION}
	packed, pack_ok := handle_pack_context(local)
	testing.expect(t, pack_ok)
	testing.expect(t, packed != 0)

	parts, unpack_ok := handle_unpack(u64(packed))
	testing.expect(t, unpack_ok)
	testing.expect(t, parts.is_context)
	testing.expect_value(t, parts.context_slot, local.slot)
	testing.expect_value(t, parts.context_generation, local.generation)
	testing.expect_value(t, parts.child_slot, u32(0))
	testing.expect_value(t, parts.child_generation, u32(0))
}

@(test)
handles_child_encodes_owner :: proc(t: ^testing.T) {
	context_local := Handle{slot = 1, generation = 2}
	child_local := Handle{slot = 4, generation = 5}
	packed, pack_ok := handle_pack_child(context_local, child_local)
	testing.expect(t, pack_ok)

	parts, unpack_ok := handle_unpack(packed)
	testing.expect(t, unpack_ok)
	testing.expect(t, !parts.is_context)
	testing.expect_value(t, parts.context_slot, context_local.slot)
	testing.expect_value(t, parts.context_generation, context_local.generation)
	testing.expect_value(t, parts.child_slot, child_local.slot)
	testing.expect_value(t, parts.child_generation, child_local.generation)

	// Same child identity under a different owner must not collide.
	other_context := Handle{slot = 7, generation = 2}
	other_packed, other_ok := handle_pack_child(other_context, child_local)
	testing.expect(t, other_ok)
	testing.expect(t, other_packed != packed)
}

@(test)
handles_reject_out_of_range :: proc(t: ^testing.T) {
	_, ok_slot := handle_pack_context(Handle{
		slot = u32(HANDLE_MAX_CONTEXT_SLOT_PLUS_ONE),
		generation = INITIAL_GENERATION,
	})
	testing.expect(t, !ok_slot)

	_, ok_gen := handle_pack_context(Handle{
		slot = 0,
		generation = HANDLE_MAX_CONTEXT_GENERATION + 1,
	})
	testing.expect(t, !ok_gen)

	_, ok_child_slot := handle_pack_child(
		Handle{slot = 0, generation = INITIAL_GENERATION},
		Handle{slot = u32(HANDLE_MAX_CHILD_SLOT_PLUS_ONE), generation = INITIAL_GENERATION},
	)
	testing.expect(t, !ok_child_slot)

	_, ok_child_gen := handle_pack_child(
		Handle{slot = 0, generation = INITIAL_GENERATION},
		Handle{slot = 0, generation = HANDLE_MAX_CHILD_GENERATION + 1},
	)
	testing.expect(t, !ok_child_gen)
}

@(test)
handles_reject_context_with_child_gen_only :: proc(t: ^testing.T) {
	// Forged: child generation set while child slot+1 is zero.
	ctx_handle, ok := handle_pack_context(Handle{slot = 0, generation = INITIAL_GENERATION})
	testing.expect(t, ok)
	forged := u64(ctx_handle) | (u64(1) << HANDLE_CHILD_GEN_SHIFT)
	_, unpack_ok := handle_unpack(forged)
	testing.expect(t, !unpack_ok)
}
