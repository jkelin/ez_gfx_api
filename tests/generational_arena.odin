#+private
package tests

import ga "../src/generational_arena"
import "core:testing"

@(test)
generational_arena_empty_lookup :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	ptr, err := ga.get(&arena, ga.Handle{slot = 0, generation = ga.INITIAL_GENERATION})
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, ga.Error.Invalid_Handle)
	testing.expect(t, !ga.valid(&arena, ga.Handle{slot = 0, generation = ga.INITIAL_GENERATION}))
	testing.expect_value(t, ga.count(&arena), 0)
}

@(test)
generational_arena_alloc_and_get :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	handle, insert_err := ga.insert(&arena, 42)
	testing.expect_value(t, insert_err, ga.Error.None)
	testing.expect_value(t, handle.slot, u32(0))
	testing.expect_value(t, handle.generation, ga.INITIAL_GENERATION)
	testing.expect_value(t, ga.count(&arena), 1)

	ptr, get_err := ga.get(&arena, handle)
	testing.expect_value(t, get_err, ga.Error.None)
	if !testing.expect(t, ptr != nil) {
		return
	}
	testing.expect_value(t, ptr^, 42)
	testing.expect(t, ga.valid(&arena, handle))
}

@(test)
generational_arena_growth_pointer_stability :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena, capacity = 1), ga.Error.None)
	defer ga.destroy(&arena)

	first, first_err := ga.insert(&arena, 7)
	testing.expect_value(t, first_err, ga.Error.None)
	first_ptr, get_err := ga.get(&arena, first)
	testing.expect_value(t, get_err, ga.Error.None)
	if !testing.expect(t, first_ptr != nil) {
		return
	}
	stable_addr := first_ptr

	// Force slot-metadata growth well beyond the initial capacity.
	for i in 1 ..< 64 {
		_, err := ga.insert(&arena, i)
		testing.expect_value(t, err, ga.Error.None)
	}

	after_ptr, after_err := ga.get(&arena, first)
	testing.expect_value(t, after_err, ga.Error.None)
	testing.expect(t, after_ptr == stable_addr)
	testing.expect_value(t, after_ptr^, 7)
	testing.expect_value(t, ga.count(&arena), 64)
}

@(test)
generational_arena_reuse_generation_change :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	first, first_err := ga.insert(&arena, 1)
	testing.expect_value(t, first_err, ga.Error.None)
	testing.expect_value(t, ga.remove(&arena, first), ga.Error.None)

	second, second_err := ga.insert(&arena, 2)
	testing.expect_value(t, second_err, ga.Error.None)
	testing.expect_value(t, second.slot, first.slot)
	testing.expect(t, second.generation != first.generation)
	testing.expect_value(t, second.generation, first.generation + 1)

	stale_ptr, stale_err := ga.get(&arena, first)
	testing.expect(t, stale_ptr == nil)
	testing.expect_value(t, stale_err, ga.Error.Invalid_Handle)

	live_ptr, live_err := ga.get(&arena, second)
	testing.expect_value(t, live_err, ga.Error.None)
	testing.expect_value(t, live_ptr^, 2)
}

@(test)
generational_arena_stale_handle :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	handle, insert_err := ga.insert(&arena, 9)
	testing.expect_value(t, insert_err, ga.Error.None)
	testing.expect_value(t, ga.remove(&arena, handle), ga.Error.None)

	testing.expect_value(t, ga.remove(&arena, handle), ga.Error.Invalid_Handle)
	ptr, err := ga.get(&arena, handle)
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, ga.Error.Invalid_Handle)
	testing.expect(t, !ga.valid(&arena, handle))
}

@(test)
generational_arena_double_remove :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	handle, insert_err := ga.insert(&arena, 3)
	testing.expect_value(t, insert_err, ga.Error.None)
	testing.expect_value(t, ga.remove(&arena, handle), ga.Error.None)
	testing.expect_value(t, ga.remove(&arena, handle), ga.Error.Invalid_Handle)
	testing.expect_value(t, ga.count(&arena), 0)
}

@(test)
generational_arena_zero_handle :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	_, insert_err := ga.insert(&arena, 5)
	testing.expect_value(t, insert_err, ga.Error.None)

	zero := ga.Handle{}
	testing.expect(t, !ga.valid(&arena, zero))
	ptr, err := ga.get(&arena, zero)
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, ga.Error.Invalid_Handle)
	testing.expect_value(t, ga.remove(&arena, zero), ga.Error.Invalid_Handle)

	zero_gen := ga.Handle{slot = 0, generation = 0}
	zero_ptr, zero_gen_err := ga.get(&arena, zero_gen)
	testing.expect(t, zero_ptr == nil)
	testing.expect_value(t, zero_gen_err, ga.Error.Invalid_Handle)
}

@(test)
generational_arena_clear_destroy :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)

	handle, insert_err := ga.insert(&arena, 11)
	testing.expect_value(t, insert_err, ga.Error.None)
	ga.clear(&arena)
	testing.expect_value(t, ga.count(&arena), 0)
	testing.expect(t, !ga.valid(&arena, handle))
	ptr, err := ga.get(&arena, handle)
	testing.expect(t, ptr == nil)
	testing.expect_value(t, err, ga.Error.Invalid_Handle)

	again, again_err := ga.insert(&arena, 12)
	testing.expect_value(t, again_err, ga.Error.None)
	testing.expect_value(t, again.slot, handle.slot)
	testing.expect_value(t, again.generation, handle.generation + 1)
	testing.expect(t, !ga.valid(&arena, handle))
	again_ptr, again_get_err := ga.get(&arena, again)
	testing.expect_value(t, again_get_err, ga.Error.None)
	testing.expect_value(t, again_ptr^, 12)

	ga.destroy(&arena)
	testing.expect_value(t, ga.count(&arena), 0)
	testing.expect(t, !ga.valid(&arena, again))
}

@(test)
generational_arena_clear_stale_then_reinsert :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	first, first_err := ga.insert(&arena, 21)
	testing.expect_value(t, first_err, ga.Error.None)
	second, second_err := ga.insert(&arena, 22)
	testing.expect_value(t, second_err, ga.Error.None)

	ga.clear(&arena)
	testing.expect_value(t, ga.count(&arena), 0)

	// Stale lookup after clear must fail closed before any reuse.
	first_ptr, first_lookup := ga.get(&arena, first)
	testing.expect(t, first_ptr == nil)
	testing.expect_value(t, first_lookup, ga.Error.Invalid_Handle)
	testing.expect(t, !ga.valid(&arena, first))
	testing.expect(t, !ga.valid(&arena, second))

	reused, reuse_err := ga.insert(&arena, 23)
	testing.expect_value(t, reuse_err, ga.Error.None)
	testing.expect(t, reused.slot == first.slot || reused.slot == second.slot)
	testing.expect(t, reused.generation == first.generation + 1 || reused.generation == second.generation + 1)

	// Pre-clear handles must remain invalid after reinsert into a cleared slot.
	stale_ptr, stale_err := ga.get(&arena, first)
	testing.expect(t, stale_ptr == nil)
	testing.expect_value(t, stale_err, ga.Error.Invalid_Handle)
	testing.expect(t, !ga.valid(&arena, first))
	testing.expect(t, !ga.valid(&arena, second))

	live_ptr, live_err := ga.get(&arena, reused)
	testing.expect_value(t, live_err, ga.Error.None)
	testing.expect_value(t, live_ptr^, 23)
	testing.expect_value(t, ga.count(&arena), 1)
}

@(test)
generational_arena_generation_exhaustion :: proc(t: ^testing.T) {
	arena: ga.Arena(int)
	testing.expect_value(t, ga.init(&arena), ga.Error.None)
	defer ga.destroy(&arena)

	handle, insert_err := ga.insert(&arena, 99)
	testing.expect_value(t, insert_err, ga.Error.None)

	// Drive the slot to the last representable generation without wrapping.
	arena.slots[handle.slot].generation = max(u32)
	handle.generation = max(u32)

	testing.expect_value(t, ga.remove(&arena, handle), ga.Error.Generation_Exhausted)
	testing.expect(t, ga.valid(&arena, handle))
	ptr, err := ga.get(&arena, handle)
	testing.expect_value(t, err, ga.Error.None)
	testing.expect_value(t, ptr^, 99)
	testing.expect_value(t, ga.count(&arena), 1)
}
