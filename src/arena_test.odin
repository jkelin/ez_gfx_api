#+test
#+private
package ez_gfx

import "core:testing"

@(test)
generational_arena_empty_lookup :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	ptr, err := arena_get_impl(&arena, Handle{slot = 0, generation = INITIAL_GENERATION})
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, Error.Invalid_Handle)
	testing.expect(t, !arena_valid_impl(&arena, Handle{slot = 0, generation = INITIAL_GENERATION}))
	testing.expect_value(t, arena_count_impl(&arena), 0)
}

@(test)
generational_arena_alloc_and_get :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	handle, insert_err := arena_insert_impl(&arena, 42)
	testing.expect_value(t, insert_err, Error.None)
	testing.expect_value(t, handle.slot, u32(0))
	testing.expect_value(t, handle.generation, INITIAL_GENERATION)
	testing.expect_value(t, arena_count_impl(&arena), 1)

	ptr, get_err := arena_get_impl(&arena, handle)
	testing.expect_value(t, get_err, Error.None)
	if !testing.expect(t, ptr != nil) {
		return
	}
	testing.expect_value(t, ptr^, 42)
	testing.expect(t, arena_valid_impl(&arena, handle))
}

@(test)
generational_arena_growth_pointer_stability :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena, capacity = 1), Error.None)
	defer arena_destroy_impl(&arena)

	first, first_err := arena_insert_impl(&arena, 7)
	testing.expect_value(t, first_err, Error.None)
	first_ptr, get_err := arena_get_impl(&arena, first)
	testing.expect_value(t, get_err, Error.None)
	if !testing.expect(t, first_ptr != nil) {
		return
	}
	stable_addr := first_ptr

	// Force slot-metadata growth well beyond the initial capacity.
	for i in 1 ..< 64 {
		_, err := arena_insert_impl(&arena, i)
		testing.expect_value(t, err, Error.None)
	}

	after_ptr, after_err := arena_get_impl(&arena, first)
	testing.expect_value(t, after_err, Error.None)
	testing.expect(t, after_ptr == stable_addr)
	testing.expect_value(t, after_ptr^, 7)
	testing.expect_value(t, arena_count_impl(&arena), 64)
}

@(test)
generational_arena_reuse_generation_change :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	first, first_err := arena_insert_impl(&arena, 1)
	testing.expect_value(t, first_err, Error.None)
	testing.expect_value(t, arena_remove_impl(&arena, first), Error.None)

	second, second_err := arena_insert_impl(&arena, 2)
	testing.expect_value(t, second_err, Error.None)
	testing.expect_value(t, second.slot, first.slot)
	testing.expect(t, second.generation != first.generation)
	testing.expect_value(t, second.generation, first.generation + 1)

	stale_ptr, stale_err := arena_get_impl(&arena, first)
	testing.expect(t, stale_ptr == nil)
	testing.expect_value(t, stale_err, Error.Invalid_Handle)

	live_ptr, live_err := arena_get_impl(&arena, second)
	testing.expect_value(t, live_err, Error.None)
	testing.expect_value(t, live_ptr^, 2)
}

@(test)
generational_arena_stale_handle :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	handle, insert_err := arena_insert_impl(&arena, 9)
	testing.expect_value(t, insert_err, Error.None)
	testing.expect_value(t, arena_remove_impl(&arena, handle), Error.None)

	testing.expect_value(t, arena_remove_impl(&arena, handle), Error.Invalid_Handle)
	ptr, err := arena_get_impl(&arena, handle)
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, Error.Invalid_Handle)
	testing.expect(t, !arena_valid_impl(&arena, handle))
}

@(test)
generational_arena_double_remove :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	handle, insert_err := arena_insert_impl(&arena, 3)
	testing.expect_value(t, insert_err, Error.None)
	testing.expect_value(t, arena_remove_impl(&arena, handle), Error.None)
	testing.expect_value(t, arena_remove_impl(&arena, handle), Error.Invalid_Handle)
	testing.expect_value(t, arena_count_impl(&arena), 0)
}

@(test)
generational_arena_zero_handle :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	_, insert_err := arena_insert_impl(&arena, 5)
	testing.expect_value(t, insert_err, Error.None)

	zero := Handle{}
	testing.expect(t, !arena_valid_impl(&arena, zero))
	ptr, err := arena_get_impl(&arena, zero)
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, Error.Invalid_Handle)
	testing.expect_value(t, arena_remove_impl(&arena, zero), Error.Invalid_Handle)

	zero_gen := Handle{slot = 0, generation = 0}
	zero_ptr, zero_gen_err := arena_get_impl(&arena, zero_gen)
	testing.expect(t, zero_ptr == nil)
	testing.expect_value(t, zero_gen_err, Error.Invalid_Handle)
}

@(test)
generational_arena_clear_destroy :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)

	handle, insert_err := arena_insert_impl(&arena, 11)
	testing.expect_value(t, insert_err, Error.None)
	arena_clear_impl(&arena)
	testing.expect_value(t, arena_count_impl(&arena), 0)
	testing.expect(t, !arena_valid_impl(&arena, handle))
	ptr, err := arena_get_impl(&arena, handle)
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, Error.Invalid_Handle)

	again, again_err := arena_insert_impl(&arena, 12)
	testing.expect_value(t, again_err, Error.None)
	testing.expect_value(t, again.slot, handle.slot)
	testing.expect_value(t, again.generation, handle.generation + 1)
	testing.expect(t, !arena_valid_impl(&arena, handle))
	again_ptr, again_get_err := arena_get_impl(&arena, again)
	testing.expect_value(t, again_get_err, Error.None)
	testing.expect_value(t, again_ptr^, 12)

	arena_destroy_impl(&arena)
	testing.expect_value(t, arena_count_impl(&arena), 0)
	testing.expect(t, !arena_valid_impl(&arena, again))
}

@(test)
generational_arena_clear_stale_then_reinsert :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	first, first_err := arena_insert_impl(&arena, 21)
	testing.expect_value(t, first_err, Error.None)
	second, second_err := arena_insert_impl(&arena, 22)
	testing.expect_value(t, second_err, Error.None)

	arena_clear_impl(&arena)
	testing.expect_value(t, arena_count_impl(&arena), 0)

	// Stale lookup after clear must fail closed before any reuse.
	first_ptr, first_lookup := arena_get_impl(&arena, first)
	testing.expect(t, first_ptr == nil)
	testing.expect_value(t, first_lookup, Error.Invalid_Handle)
	testing.expect(t, !arena_valid_impl(&arena, first))
	testing.expect(t, !arena_valid_impl(&arena, second))

	reused, reuse_err := arena_insert_impl(&arena, 23)
	testing.expect_value(t, reuse_err, Error.None)
	testing.expect(t, reused.slot == first.slot || reused.slot == second.slot)
	testing.expect(t, reused.generation == first.generation + 1 || reused.generation == second.generation + 1)

	// Pre-clear handles must remain invalid after reinsert into a cleared slot.
	stale_ptr, stale_err := arena_get_impl(&arena, first)
	testing.expect(t, stale_ptr == nil)
	testing.expect_value(t, stale_err, Error.Invalid_Handle)
	testing.expect(t, !arena_valid_impl(&arena, first))
	testing.expect(t, !arena_valid_impl(&arena, second))

	live_ptr, live_err := arena_get_impl(&arena, reused)
	testing.expect_value(t, live_err, Error.None)
	testing.expect_value(t, live_ptr^, 23)
	testing.expect_value(t, arena_count_impl(&arena), 1)
}

@(test)
generational_arena_generation_exhaustion :: proc(t: ^testing.T) {
	arena: Arena(int)
	testing.expect_value(t, arena_init_impl(&arena), Error.None)
	defer arena_destroy_impl(&arena)

	handle, insert_err := arena_insert_impl(&arena, 99)
	testing.expect_value(t, insert_err, Error.None)

	// Drive the slot to the last representable generation without wrapping.
	arena.slots[handle.slot].generation = max(u32)
	handle.generation = max(u32)

	testing.expect_value(t, arena_remove_impl(&arena, handle), Error.Generation_Exhausted)
	testing.expect(t, arena_valid_impl(&arena, handle))
	ptr, err := arena_get_impl(&arena, handle)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, ptr^, 99)
	testing.expect_value(t, arena_count_impl(&arena), 1)
}
