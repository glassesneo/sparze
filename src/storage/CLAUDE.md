# Storage

**Location:** `src/storage/`

## ComponentStorage

Automatic storage selection: zero-sized structs → `TagStorage` (bitset), non-zero → `SparseSet(T)`.

## SparseSet

Paginated sparse set for component storage with group support.

**Constants**: 4096 entities/page, 16 pages max (65536 entities).

**Group layout**: First `group_size` elements reserved for group entities.

### Critical Details

**insert()**: Group entities inserted at `group_size`, non-group appended to end.

**remove() does not validate** entity has component.

**get/getPtr/getPtrMut() panics** if entity doesn't have component.

**moveToGroup/moveFromGroup**: Swap entity to/from group region (indices 0..group_size).

**Memory**: 512 KB sparse max (only if all pages allocated), dense linear with entity count.

## TagStorage

Paged sparse storage for zero-sized tags (marker components).

**Structure**: Paged sparse array (allocated on-demand) + packed entity array.

**Constants**: 4096 entities/page, 16 pages max (65536 entities), ~16.5KB per page.

**Page structure**: Bitset (512 bytes, 4096 bits) + reverse indices (16KB, 4096 × u32).

**Memory**: O(pages_used) instead of O(max_entity_index). For sparse entity allocations, achieves ~98% memory reduction vs. non-paged approach.

**Best for**: Markers (Enemy, Dead, Selected), state flags (Active, Disabled).

## EventStorage

Double-buffered event queue: `write_buffer` (current frame) + `read_buffer` (previous frame).

**Frame lifecycle**:
```
beginFrame() → swap() + clear()
Systems run → write to write_buffer, read from read_buffer
endFrame() → flush commands
```

**Event delay**: 1-frame latency by design.

## Key Points

- **Pre-allocate** with `reserve()` before bulk operations
- **Group support** only in SparseSet
- **Pages allocated on-demand** in both SparseSet and TagStorage

See [World API](../../CLAUDE.md#world-api).
