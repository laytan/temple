package temple_cli

import "core:mem"

Small_Array :: struct($N: int, $T: typeid) {
	inline: [N]T,
	count:  int,
	spill:  [dynamic]T,
}

small_array_append :: proc(a: ^Small_Array($N, $T), item: T, allocator := context.allocator) -> int {
	if a.spill == nil && a.count < N {
		idx := a.count
		a.inline[idx] = item
		a.count += 1
		return idx
	}
	if a.spill == nil {
		a.spill = make([dynamic]T, 0, max(N * 2, 4), allocator)
		for i in 0 ..< a.count {
			append(&a.spill, a.inline[i])
		}
	}
	idx := len(a.spill)
	append(&a.spill, item)
	return idx
}

small_array_pop :: proc(a: ^Small_Array($N, $T)) {
	if a.spill != nil {
		pop(&a.spill)
	} else if a.count > 0 {
		a.count -= 1
	}
}

small_array_slice :: #force_inline proc(a: ^Small_Array($N, $T)) -> []T {
	if a.spill != nil {
		return a.spill[:]
	}
	return a.inline[:a.count]
}

small_array_len :: #force_inline proc(a: ^Small_Array($N, $T)) -> int {
	if a.spill != nil {
		return len(a.spill)
	}
	return a.count
}

small_array_get_ptr :: #force_inline proc(a: ^Small_Array($N, $T), idx: int) -> ^T {
	if a.spill != nil {
		return &a.spill[idx]
	}
	return &a.inline[idx]
}

small_array_clear :: proc(a: ^Small_Array($N, $T)) {
	if a.spill != nil {
		clear(&a.spill)
	}
	a.count = 0
}

Small_Map_Entry :: struct($K, $V: typeid) {
	key: K,
	val: V,
}

Small_Map :: struct($N: int, $K, $V: typeid) {
	inline: [N]Small_Map_Entry(K, V),
	count:  int,
	spill:  map[K]V,
}

small_map_get :: proc(m: ^Small_Map($N, $K, $V), key: K) -> (V, bool) {
	for i in 0 ..< m.count {
		if m.inline[i].key == key {
			return m.inline[i].val, true
		}
	}
	if m.spill.allocator.procedure != nil {
		if val, found := m.spill[key]; found {
			return val, true
		}
	}
	return {}, false
}

small_map_set :: proc(m: ^Small_Map($N, $K, $V), key: K, val: V, allocator := context.allocator) {
	for i in 0 ..< m.count {
		if m.inline[i].key == key {
			m.inline[i].val = val
			return
		}
	}
	if m.count < N {
		m.inline[m.count] = {key = key, val = val}
		m.count += 1
		return
	}
	if m.spill.allocator.procedure == nil {
		m.spill = make(map[K]V, allocator)
	}
	m.spill[key] = val
}

small_map_set_if_absent :: proc(m: ^Small_Map($N, $K, $V), key: K, val: V, allocator := context.allocator) -> bool {
	for i in 0 ..< m.count {
		if m.inline[i].key == key {
			return false
		}
	}
	if m.count < N {
		m.inline[m.count] = {key = key, val = val}
		m.count += 1
		return true
	}
	if m.spill.allocator.procedure == nil {
		m.spill = make(map[K]V, allocator)
	}
	if _, exists := m.spill[key]; exists {
		return false
	}
	m.spill[key] = val
	return true
}

Node_Slab :: struct {
	buf: []byte,
	off: int,
}

slab_alloc_node :: proc(s: ^Node_Slab, $T: typeid, allocator: mem.Allocator, min_slab_bytes := 1024) -> ^T {
	align :: int(align_of(T))
	size :: int(size_of(T))
	off := (s.off + (align - 1)) & ~(align - 1)
	if off + size > len(s.buf) {
		slab_bytes := max(min_slab_bytes, size + align)
		s.buf = make([]byte, slab_bytes, allocator)
		off = 0
	}
	res := cast(^T)&s.buf[off]
	s.off = off + size
	return res
}
