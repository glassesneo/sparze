# Storage Internals

Deep dive into component storage mechanisms in Sparze: SparseSet, TagStorage, and EventStorage.

## ComponentStorage Type Selection

Sparze automatically selects storage type based on component size:

```zig
pub fn ComponentStorage(comptime T: type) type {
    if (@sizeOf(T) == 0) {
        return TagStorage;  // Zero-sized types
    } else {
        return SparseSet(T);  // Regular components
    }
}
```

**Examples**:
```zig
const Position = struct { x: f32, y: f32 };           // → SparseSet(Position)
const Enemy = struct {};                              // → TagStorage
const Marker = struct { pub const tag = true; };      // → TagStorage
```

## SparseSet(T) - Dense Component Storage

### Structure

SparseSet implements a **sparse set** data structure with pagination and group support.

```
┌─────────────────────────────────────────────────────┐
│                   SPARSE ARRAY                      │
│  (entity index → dense array index)                 │
│                                                      │
│  Page 0    Page 1    Page 2    ...    Page 15       │
│ [4K ents] [4K ents] [4K ents]  ...   [4K ents]     │
│                                                      │
│  Allocated on-demand (per-page)                     │
└─────────────────────────────────────────────────────┘
         │ index mapping
         ▼
┌─────────────────────────────────────────────────────┐
│                   DENSE ARRAY                        │
│  (packed entities and components)                    │
│                                                      │
│ [Group Region (0..group_size)] [Non-Group Region]   │
│  entities: [e₀, e₁, e₂, ...]                        │
│  components: [c₀, c₁, c₂, ...]                      │
│                                                      │
│  Linear, packed, cache-friendly                     │
└─────────────────────────────────────────────────────┘
```

### Constants

```zig
pub const entities_per_page = 4096;  // 4KB page (cache-friendly)
pub const max_pages = 16;            // 65,536 entities max
```

### Sparse Array Details

**Purpose**: Map entity ID → dense array index in O(1).

**Layout**:
```zig
sparse: [max_pages]?[entities_per_page]usize
```

**Access**:
```zig
const entity_index = entity & 0xFFFF;
const page_index = entity_index / entities_per_page;
const offset = entity_index % entities_per_page;

if (sparse[page_index]) |page| {
    const dense_index = page[offset];
}
```

**Memory**:
- Per page: 4096 × sizeof(usize) = 32 KB (64-bit) or 16 KB (32-bit)
- Max allocation: 16 pages × 32 KB = 512 KB (64-bit)
- **On-demand**: Pages allocated only when needed

### Dense Array Details

**Purpose**: Store entities and components contiguously for cache efficiency.

**Layout**:
```zig
entities: ArrayList(Entity)      // Packed entity IDs
components: ArrayList(T)          // Packed component data
```

**Size**: Linear with entity count (not max index)
```
Memory = entity_count × (sizeof(Entity) + sizeof(T))
```

**Example**:
```zig
// 1000 entities with Position component
Position = struct { x: f32, y: f32 };  // 8 bytes

entities: 1000 × 4 bytes = 4 KB
components: 1000 × 8 bytes = 8 KB
Total: 12 KB (vs. 512 KB if using entity_index directly!)
```

### Group Layout

Groups organize entities at the start of dense array for optimal iteration.

```
Dense Array Layout:
┌──────────────────────┬─────────────────────────┐
│   Group Region       │   Non-Group Region      │
│  (0..group_size)     │  (group_size..len)      │
├──────────────────────┼─────────────────────────┤
│ entities: [e₀,e₁,..] │ entities: [e₁₀,e₁₁,..] │
│ components: [c₀,c₁,..] │ components: [c₁₀,c₁₁,..] │
└──────────────────────┴─────────────────────────┘
         ▲                          ▲
         │                          │
   Belongs to group          Does not belong to group
```

**group_size**: Number of entities in the group (contiguous at index 0)

### Operations

#### insert(entity, component)

```
1. Allocate sparse page if needed
2. Determine insertion position:
   - If entity in group → insert at group_size
   - Else → append to end
3. Update sparse[entity] = new_dense_index
4. Update dense arrays (entity, component)
```

**Example with groups**:
```
Before: group_size = 2, len = 4
entities: [e₀, e₁ | e₂, e₃]
          [Group | Non-group]

Insert e₄ (in group):
entities: [e₀, e₁, e₄ | e₂, e₃]
                    ▲
          inserted at group_size (2)
group_size = 3, len = 5
```

#### remove(entity)

**IMPORTANT**: Does NOT validate entity has component (caller's responsibility).

```
1. Get dense_index from sparse[entity]
2. Swap entity with last element
3. Update sparse for swapped entity
4. Pop last element
5. If in group region, decrement group_size
```

**Example**:
```
Before: len = 5, group_size = 3
entities: [e₀, e₁, e₂ | e₃, e₄]
components: [c₀, c₁, c₂ | c₃, c₄]

Remove e₁ (index 1):
1. Swap with last (e₄ at index 4)
   entities: [e₀, e₄, e₂ | e₃]
   components: [c₀, c₄, c₂ | c₃]

2. Pop last
   len = 4

3. Update sparse[e₄] = 1

4. Decrement group_size = 2 (e₁ was in group)
```

#### get/getPtr/getPtrMut(entity)

**IMPORTANT**: Returns null if entity doesn't have component.

```zig
pub fn get(self: *const Self, entity: Entity) ?T {
    const dense_index = self.sparse[page][offset];
    if (dense_index == missing_sentinel) return null;
    return self.components.items[dense_index];
}
```

**Caller responsibility**: Handle null before dereferencing.

#### moveToGroup(entity) / moveFromGroup(entity)

**Purpose**: Move entity between group and non-group regions.

**moveToGroup**:
```
1. Get current dense_index
2. Swap with entity at group_size
3. Increment group_size
```

**moveFromGroup**:
```
1. Get current dense_index (must be < group_size)
2. Swap with entity at group_size - 1
3. Decrement group_size
```

**Used by**: World when adding/removing components to maintain group invariants.

### Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| insert | O(1) amortized | ArrayList append |
| remove | O(1) | Swap-and-pop |
| get | O(1) | Sparse + dense lookup |
| moveToGroup | O(1) | Single swap |
| iteration | O(n) | Linear scan of dense array |

**Cache efficiency**: Dense array iteration has excellent spatial locality (sequential access).

## TagStorage - Efficient Zero-Sized Component Storage

### Purpose

Specialized storage for zero-sized "marker" or "tag" components (e.g., Enemy, Dead, Selected).

**Memory savings**: ~98% reduction vs. treating tags as regular components.

### Structure

```
┌─────────────────────────────────────────────────────┐
│                   SPARSE ARRAY                      │
│             (paged bitset storage)                   │
│                                                      │
│  Page 0           Page 1           Page N           │
│ ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│ │ Bitset      │  │ Bitset      │  │ Bitset      │  │
│ │ [4096 bits] │  │ [4096 bits] │  │ [4096 bits] │  │
│ │ 512 bytes   │  │ 512 bytes   │  │ 512 bytes   │  │
│ ├─────────────┤  ├─────────────┤  ├─────────────┤  │
│ │ Reverse     │  │ Reverse     │  │ Reverse     │  │
│ │ Indices     │  │ Indices     │  │ Indices     │  │
│ │ [4096×u32]  │  │ [4096×u32]  │  │ [4096×u32]  │  │
│ │ 16 KB       │  │ 16 KB       │  │ 16 KB       │  │
│ └─────────────┘  └─────────────┘  └─────────────┘  │
│ Total: ~16.5KB   Total: ~16.5KB   Total: ~16.5KB   │
│                                                      │
│  Allocated on-demand (per-page)                     │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│                   DENSE ARRAY                        │
│             (packed entity IDs)                      │
│                                                      │
│  entities: [e₀, e₁, e₂, e₃, ..., eₙ]                │
│                                                      │
│  Linear, packed, cache-friendly                     │
└─────────────────────────────────────────────────────┘
```

### Page Structure

Each page handles 4096 entities (same as SparseSet):

```zig
const Page = struct {
    bitset: [512]u8,              // 4096 bits (1 per entity)
    reverse_indices: [4096]u32,   // Dense index per entity
};
```

**Memory per page**: 512 bytes + 16 KB = ~16.5 KB

**Max pages**: 16 (same as SparseSet)

**Total max memory**: 16 × 16.5 KB = ~264 KB (vs. SparseSet's 512 KB sparse + component data)

### Bitset Details

**Purpose**: O(1) membership test (does entity have tag?).

**Layout**: 512 bytes = 4096 bits (1 bit per entity in page)

**Access**:
```zig
const byte_index = entity_offset / 8;
const bit_index = entity_offset % 8;
const has_tag = (bitset[byte_index] & (1 << bit_index)) != 0;
```

**Operations**:
- Set bit: `bitset[byte] |= (1 << bit)`
- Clear bit: `bitset[byte] &= ~(1 << bit)`

### Reverse Indices

**Purpose**: Map entity ID → dense array index (same as SparseSet sparse array).

**Layout**: 4096 × u32 = 16 KB per page

**Access**: `dense_index = page.reverse_indices[entity_offset]`

### Dense Array

**Purpose**: Packed list of entities with the tag (for iteration).

```zig
entities: ArrayList(Entity)
```

**Size**: Linear with tag count (not max entity index)

### Operations

#### insert(entity)

```
1. Allocate page if needed
2. Set bitset bit for entity
3. Append entity to dense array
4. Store dense index in reverse_indices
```

**Example**:
```
Insert entity 5000:
Page index: 5000 / 4096 = 1
Offset: 5000 % 4096 = 904

1. Allocate page 1 if not exists
2. Set page[1].bitset[904 / 8] |= (1 << (904 % 8))
3. dense_index = entities.len (e.g., 42)
4. page[1].reverse_indices[904] = 42
5. entities.append(5000)
```

#### remove(entity)

**IMPORTANT**: Does NOT validate entity has tag.

```
1. Get dense_index from reverse_indices
2. Swap entity with last in dense array
3. Update reverse_indices for swapped entity
4. Clear bitset bit
5. Pop last element
```

**Complexity**: O(1) (same as SparseSet)

#### has(entity)

```zig
pub fn has(self: *const Self, entity: Entity) bool {
    const page = self.getPage(entity);
    if (page == null) return false;

    const offset = entity % entities_per_page;
    const byte_index = offset / 8;
    const bit_index = offset % 8;

    return (page.bitset[byte_index] & (1 << bit_index)) != 0;
}
```

**Complexity**: O(1)

### Memory Comparison

**Scenario**: 10,000 entities, 1,000 have "Enemy" tag, sparse distribution (entity IDs 0-65,535)

**SparseSet approach** (if Enemy was regular component):
- Sparse: ~512 KB (16 pages)
- Dense: 1,000 × (4 + 0) = 4 KB (0 bytes for zero-sized component)
- **Total: ~516 KB**

**TagStorage approach**:
- Pages needed: 16 (assume sparse distribution)
- Page memory: 16 × 16.5 KB = 264 KB
- Dense: 1,000 × 4 = 4 KB
- **Total: ~268 KB**

**But**: If entities are concentrated (e.g., first 10,000 indices):
- Pages needed: 10,000 / 4096 = 3 pages
- Page memory: 3 × 16.5 KB = ~50 KB
- Dense: 1,000 × 4 = 4 KB
- **Total: ~54 KB (90% reduction!)**

### Best Practices

Use TagStorage for:
- Marker components (Enemy, Dead, Selected)
- State flags (Active, Disabled, Initialized)
- Binary properties (IsPlayer, HasWeapon)

**NOT** for:
- Components with data (Position, Health)
- Frequently changing properties (better as resource or component)

## EventStorage - Double-Buffered Event Queue

### Structure

```zig
pub fn EventStorage(comptime E: type) type {
    return struct {
        write_buffer: ArrayList(E),
        read_buffer: ArrayList(E),
    };
}
```

**Purpose**: Frame-delayed event communication between systems.

### Frame Lifecycle

```
Frame N:
  beginFrame() → swap(write_buffer, read_buffer) → clear(write_buffer)
  Systems → write to write_buffer, read from read_buffer
  endFrame() → flush commands

Frame N+1:
  beginFrame() → swap buffers (N's writes become N+1's reads)
  ...
```

**Event delay**: Exactly 1 frame (by design, prevents same-frame circular dependencies)

### Operations

#### enqueue(event) - Writer

```zig
pub fn enqueue(self: *EventStorage(E), event: E) !void {
    try self.write_buffer.append(event);
}
```

**Accessed via**: `EventWriter(E)` parameter in system functions

#### Reading Events

**EventReader access**: Use `EventReader(E).queue` (alias of `read_buffer.items`) to consume events.

**Direct storage access**: `storage.read_buffer.items`

**Note**: There is no `queue()` method on EventStorage. EventReader provides the `queue` field for convenient access.

#### swap() and clear()

```zig
pub fn swap(self: *EventStorage(E)) void {
    std.mem.swap(ArrayList(E), &self.write_buffer, &self.read_buffer);
}

pub fn clear(self: *EventStorage(E)) void {
    self.write_buffer.clearRetainingCapacity();
}
```

**Called by**: `World.beginFrame()`

### Usage Pattern

```zig
// Frame N: Detection system writes
fn collisionDetection(writer: EventWriter(CollisionEvent)) !void {
    try writer.enqueue(CollisionEvent{ .a = e1, .b = e2 });
    // Written to write_buffer
}

// Frame N+1: Response system reads
fn collisionResponse(
    reader: EventReader(CollisionEvent),
    commands: anytype
) !void {
    for (reader.queue) |event| {
        // Read from read_buffer (N's writes)
        try commands.destroyEntity(event.a);
    }
}
```

### Memory

**Per event type**:
- 2 × ArrayList (write + read)
- Memory = 2 × event_count × sizeof(E)

**Growth**: ArrayLists grow as needed (doubling strategy)

**Cleanup**: `clear()` retains capacity (no reallocation each frame)

## Storage Selection Summary

| Component Type | Storage | Memory Efficiency | Best For |
|----------------|---------|-------------------|----------|
| Regular (sized) | SparseSet | O(entity_count) | Components with data |
| Zero-sized | TagStorage | O(pages_used) | Marker components |
| Events | EventStorage | O(event_count) | Frame-delayed messaging |

See also:
- @docs/ARCHITECTURE.md for high-level overview
- @docs/ENTITY_LIFECYCLE.md for entity management
- @docs/QUERY_PATTERNS.md for iteration patterns
