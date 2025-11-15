# Storage

**Location:** `src/storage/`

## ComponentStorage

Automatic storage selection:
- **Zero-sized structs** (tags) → `TagStorage` (bitset)
- **Non-zero structs** → `SparseSet(T)`

```zig
pub fn isTagComponent(comptime T: type) bool
pub fn ComponentStorage(comptime T: type) type
```

## SparseSet

Paginated sparse set for component storage with group support.

### Architecture

```zig
// Constants
pub const page_size = 4096;        // Entities per page
pub const max_pages = 16;          // Total pages (65536 entities)

// Structure
pub fn SparseSet(comptime T: type) type {
    return struct {
        sparse: [max_pages]?[]usize,    // Paginated sparse array
        packed: []Entity,                // Dense entity array
        components: []T,                 // Dense component array
        group_size: usize,               // Group boundary
        allocator: Allocator,
    };
}
```

**Group layout**: First `group_size` elements in packed/components arrays reserved for group entities.

### Key Methods

#### reserve(capacity) / reservePages(count)
Pre-allocate to avoid reallocation. Call before bulk inserts.

#### insert(entity, component) - O(1) amortized
Replaces if exists. Group entities inserted at `group_size`, non-group appended to end.

#### remove(entity) - O(1)
Swap-remove from packed arrays. **Does not validate entity has component.**

#### get/getPtr/getPtrMut(entity) - O(1)
Direct sparse lookup. **Panics if entity doesn't have component.**

#### contains(entity) - O(1)
Check component presence.

#### moveToGroup/moveFromGroup(entity) - O(1)
Swap entity to/from group region (indices 0..group_size).

#### getGroupEntities/getGroupComponents() - O(1)
Direct slice access to group region for fast iteration.

### Performance

- **Sparse overhead**: 512 KB max (only if all pages allocated)
- **Dense storage**: Linear with entity count
- **Pagination**: Efficient for scattered entity IDs

## TagStorage

Bitset-backed storage for zero-sized tags.

### Architecture

```zig
pub const TagStorage = struct {
    bitset: DynamicBitSet,           // 1 bit per entity
    packed: []Entity,                // Tagged entities only
    sparse_to_dense: []usize,        // Reverse index
    allocator: Allocator,
};
```

### Key Methods

#### set(entity) - O(1) amortized
Set bit, add to packed array, update reverse index.

#### unset(entity) - O(1)
Clear bit, swap-remove from packed, update reverse index.

#### contains(entity) - O(1)
Bitset lookup.

### Performance

- **Memory**: 8 KB bitset + packed arrays
- **Iteration**: Only tagged entities (O(m) where m = tagged count)
- **Best for**: Markers (Enemy, Dead, Selected)

## EventStorage

Double-buffered event queue.

### Architecture

```zig
pub fn EventStorage(comptime T: type) type {
    return struct {
        write_buffer: ArrayList(T),   // Current frame
        read_buffer: ArrayList(T),    // Previous frame
        allocator: Allocator,
    };
}
```

### Frame Lifecycle

```
Frame N:   beginFrame() → swap() + clear()
           Systems write to write_buffer, read from read_buffer
           endFrame() → flush commands

Frame N+1: beginFrame() → swap() [Frame N events in read_buffer]
```

### Methods

#### enqueue(event) - O(1) amortized
Add to write buffer.

#### swap() - O(1)
Pointer swap write ↔ read.

#### clear() - O(1)
Clear write buffer.

## Storage Comparison

| Storage | Memory/Entity | Insert | Lookup | Iteration | Groups | Use Case |
|---------|--------------|--------|--------|-----------|--------|----------|
| SparseSet | sizeof(T) + 16B | O(1) | O(1) | O(n) | Yes | Data components |
| TagStorage | 1 bit + 12B | O(1) | O(1) | O(m) tagged | No | State flags |
| EventStorage | N/A | O(1) | N/A | O(e) events | No | Inter-system messages |

## Key Points

- **Pre-allocate** with `reserve()` before bulk operations
- **Group support** only in SparseSet (entities at array start)
- **Event frame delay**: 1-frame latency by design
- **Pages allocated on-demand** in SparseSet

See [World API](../../CLAUDE.md#world-api).
