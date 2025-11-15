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

Bitset-backed storage for zero-sized tags.

**Structure**: DynamicBitSet (1 bit/entity) + packed entity array + reverse index.

**Memory**: 8 KB bitset + packed arrays.

**Best for**: Markers (Enemy, Dead, Selected).

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
- **Pages allocated on-demand** in SparseSet

See [World API](../../CLAUDE.md#world-api).
