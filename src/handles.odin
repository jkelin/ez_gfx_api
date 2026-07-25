#+private
package ez_gfx


// Packed layout (context ownership + optional child identity):
// bits 0-19:  context slot+1
// bits 20-39: context generation
// bits 40-51: child slot+1 (0 for context handles)
// bits 52-63: child generation (0 for context handles)
//
// Child bits do NOT address typed resource arenas directly. Each context owns a
// shared handle-identity arena; packed child slot/generation indexes that arena.
// The identity record stores (Resource_Kind, typed-arena local handle). Every
// resolver and C wrapper validates the recorded kind before dereferencing the
// typed arena, so equal child slot/generation values reused across kinds cannot
// alias under C ABI uint64_t misuse. Kind is intentionally not packed into the
// u64 so the contract layout stays 20/20/12/12.
HANDLE_CONTEXT_SLOT_BITS :: 20
HANDLE_CONTEXT_GEN_BITS :: 20
HANDLE_CHILD_SLOT_BITS :: 12
HANDLE_CHILD_GEN_BITS :: 12

HANDLE_CONTEXT_SLOT_SHIFT :: 0
HANDLE_CONTEXT_GEN_SHIFT :: HANDLE_CONTEXT_SLOT_BITS
HANDLE_CHILD_SLOT_SHIFT :: HANDLE_CONTEXT_SLOT_BITS + HANDLE_CONTEXT_GEN_BITS
HANDLE_CHILD_GEN_SHIFT :: HANDLE_CHILD_SLOT_SHIFT + HANDLE_CHILD_SLOT_BITS

HANDLE_CONTEXT_SLOT_MASK :: (u64(1) << HANDLE_CONTEXT_SLOT_BITS) - 1
HANDLE_CONTEXT_GEN_MASK :: (u64(1) << HANDLE_CONTEXT_GEN_BITS) - 1
HANDLE_CHILD_SLOT_MASK :: (u64(1) << HANDLE_CHILD_SLOT_BITS) - 1
HANDLE_CHILD_GEN_MASK :: (u64(1) << HANDLE_CHILD_GEN_BITS) - 1

HANDLE_MAX_CONTEXT_SLOT_PLUS_ONE :: HANDLE_CONTEXT_SLOT_MASK
HANDLE_MAX_CONTEXT_GENERATION :: u32(HANDLE_CONTEXT_GEN_MASK)
HANDLE_MAX_CHILD_SLOT_PLUS_ONE :: HANDLE_CHILD_SLOT_MASK
HANDLE_MAX_CHILD_GENERATION :: u32(HANDLE_CHILD_GEN_MASK)

Handle_Parts :: struct {
	context_slot:       u32,
	context_generation: u32,
	child_slot:         u32,
	child_generation:   u32,
	is_context:         bool,
}

handle_pack_context :: proc(local: Handle) -> (Ez_Gfx_Context_Handle, bool) {
	if local.generation == 0 {
		return 0, false
	}
	if u64(local.slot) + 1 > HANDLE_MAX_CONTEXT_SLOT_PLUS_ONE {
		return 0, false
	}
	if local.generation > HANDLE_MAX_CONTEXT_GENERATION {
		return 0, false
	}

	value := (u64(local.slot) + 1) << HANDLE_CONTEXT_SLOT_SHIFT
	value |= u64(local.generation) << HANDLE_CONTEXT_GEN_SHIFT
	return Ez_Gfx_Context_Handle(value), true
}

handle_pack_child :: proc(context_local: Handle, child_local: Handle) -> (u64, bool) {
	context_handle, context_ok := handle_pack_context(context_local)
	if !context_ok {
		return 0, false
	}
	if child_local.generation == 0 {
		return 0, false
	}
	if u64(child_local.slot) + 1 > HANDLE_MAX_CHILD_SLOT_PLUS_ONE {
		return 0, false
	}
	if child_local.generation > HANDLE_MAX_CHILD_GENERATION {
		return 0, false
	}

	value := u64(context_handle)
	value |= (u64(child_local.slot) + 1) << HANDLE_CHILD_SLOT_SHIFT
	value |= u64(child_local.generation) << HANDLE_CHILD_GEN_SHIFT
	return value, true
}

handle_unpack :: proc(value: u64) -> (parts: Handle_Parts, ok: bool) {
	if value == 0 {
		return {}, false
	}

	context_slot_plus_one := (value >> HANDLE_CONTEXT_SLOT_SHIFT) & HANDLE_CONTEXT_SLOT_MASK
	context_generation := (value >> HANDLE_CONTEXT_GEN_SHIFT) & HANDLE_CONTEXT_GEN_MASK
	child_slot_plus_one := (value >> HANDLE_CHILD_SLOT_SHIFT) & HANDLE_CHILD_SLOT_MASK
	child_generation := (value >> HANDLE_CHILD_GEN_SHIFT) & HANDLE_CHILD_GEN_MASK

	if context_slot_plus_one == 0 || context_generation == 0 {
		return {}, false
	}
	if child_slot_plus_one == 0 {
		if child_generation != 0 {
			return {}, false
		}
		parts = Handle_Parts {
			context_slot = u32(context_slot_plus_one - 1),
			context_generation = u32(context_generation),
			is_context = true,
		}
		return parts, true
	}
	if child_generation == 0 {
		return {}, false
	}

	parts = Handle_Parts {
		context_slot = u32(context_slot_plus_one - 1),
		context_generation = u32(context_generation),
		child_slot = u32(child_slot_plus_one - 1),
		child_generation = u32(child_generation),
		is_context = false,
	}
	return parts, true
}

handle_context_local :: proc(parts: Handle_Parts) -> Handle {
	return Handle {
		slot = parts.context_slot,
		generation = parts.context_generation,
	}
}

handle_child_local :: proc(parts: Handle_Parts) -> Handle {
	return Handle {
		slot = parts.child_slot,
		generation = parts.child_generation,
	}
}
