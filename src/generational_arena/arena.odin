package generational_arena

import "base:runtime"

// Generations start nonzero so the zero handle is never a live entry.
INITIAL_GENERATION :: u32(1)

// Free-list sentinel; slot indices never use this value as a live next link target
// beyond the empty-list case.
FREE_NIL :: max(u32)

// Local handle: slot index plus generation. No owner identity here; the API layer
// can wrap this later with context ownership.
Handle :: struct {
	slot:       u32,
	generation: u32,
}

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Handle,
	Generation_Exhausted,
	Capacity_Exhausted,
}

@(private)
Slot :: struct($T: typeid) {
	generation: u32,
	occupied:   bool,
	next_free:  u32,
	value:      ^T,
}

// Generic arena over T. Live values are individually allocated so growth of the
// slot metadata array cannot invalidate returned ^T pointers.
Arena :: struct($T: typeid) {
	slots:      [dynamic]Slot(T),
	free_head:  u32,
	live_count: int,
	allocator:  runtime.Allocator,
}

init :: proc(
	arena: ^Arena($T),
	allocator: runtime.Allocator = context.allocator,
	capacity: int = 0,
) -> Error {
	arena^ = {}
	arena.allocator = allocator
	arena.free_head = FREE_NIL

	slots, alloc_err := make([dynamic]Slot(T), 0, capacity, allocator)
	if alloc_err != nil {
		return .Out_Of_Memory
	}
	arena.slots = slots
	return .None
}

destroy :: proc(arena: ^Arena($T)) {
	if arena == nil {
		return
	}
	clear(arena)
	delete(arena.slots)
	arena^ = {}
}

// Drops every live value while retaining slot metadata capacity. Occupied slots
// advance their generation; already-free slots keep the generation from remove.
// The free-list is rebuilt in place so pre-clear handles stay invalid even when
// those slots are reused by a later insert. Generation wrap is refused.
clear :: proc(arena: ^Arena($T)) {
	if arena == nil {
		return
	}

	arena.free_head = FREE_NIL
	arena.live_count = 0

	for i := len(arena.slots) - 1; i >= 0; i -= 1 {
		slot := &arena.slots[i]
		if slot.occupied {
			if slot.value != nil {
				free(slot.value, arena.allocator)
				slot.value = nil
			}
			slot.occupied = false

			// Advance so the live pre-clear handle can never match again.
			// Retire rather than wrap when the generation is exhausted.
			if slot.generation == max(u32) {
				slot.next_free = FREE_NIL
				continue
			}
			slot.generation += 1
		}

		slot.next_free = arena.free_head
		arena.free_head = u32(i)
	}
}

count :: proc(arena: ^Arena($T)) -> int {
	if arena == nil {
		return 0
	}
	return arena.live_count
}

valid :: proc(arena: ^Arena($T), handle: Handle) -> bool {
	_, err := get(arena, handle)
	return err == .None
}

get :: proc(arena: ^Arena($T), handle: Handle) -> (^T, Error) {
	if arena == nil || !handle_fields_ok(handle) {
		return nil, .Invalid_Handle
	}
	if int(handle.slot) >= len(arena.slots) {
		return nil, .Invalid_Handle
	}

	slot := &arena.slots[handle.slot]
	if !slot.occupied || slot.generation != handle.generation || slot.value == nil {
		return nil, .Invalid_Handle
	}
	return slot.value, .None
}

insert :: proc(arena: ^Arena($T), value: T) -> (Handle, Error) {
	if arena == nil {
		return {}, .Invalid_Handle
	}

	ptr, alloc_err := new_clone(value, arena.allocator)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}

	if arena.free_head != FREE_NIL {
		slot_index := arena.free_head
		slot := &arena.slots[slot_index]
		arena.free_head = slot.next_free

		slot.occupied = true
		slot.next_free = FREE_NIL
		slot.value = ptr
		arena.live_count += 1
		return Handle{slot = slot_index, generation = slot.generation}, .None
	}

	// Indices are u32; refuse to grow past the last representable slot index.
	if len(arena.slots) > int(max(u32)) {
		free(ptr, arena.allocator)
		return {}, .Capacity_Exhausted
	}

	slot_index := u32(len(arena.slots))
	_, append_err := append(
		&arena.slots,
		Slot(T){
			generation = INITIAL_GENERATION,
			occupied = true,
			next_free = FREE_NIL,
			value = ptr,
		},
	)
	if append_err != nil {
		free(ptr, arena.allocator)
		return {}, .Out_Of_Memory
	}

	arena.live_count += 1
	return Handle{slot = slot_index, generation = INITIAL_GENERATION}, .None
}

remove :: proc(arena: ^Arena($T), handle: Handle) -> Error {
	if arena == nil || !handle_fields_ok(handle) {
		return .Invalid_Handle
	}
	if int(handle.slot) >= len(arena.slots) {
		return .Invalid_Handle
	}

	slot := &arena.slots[handle.slot]
	if !slot.occupied || slot.generation != handle.generation {
		return .Invalid_Handle
	}

	// Refuse silent wrap; leave the live entry untouched when generation cannot advance.
	if slot.generation == max(u32) {
		return .Generation_Exhausted
	}

	free(slot.value, arena.allocator)
	slot.value = nil
	slot.occupied = false
	slot.generation += 1
	slot.next_free = arena.free_head
	arena.free_head = handle.slot
	arena.live_count -= 1
	return .None
}

@(private)
handle_fields_ok :: proc(handle: Handle) -> bool {
	// Zero handle and any zero generation are never valid live references.
	return handle.generation != 0
}
