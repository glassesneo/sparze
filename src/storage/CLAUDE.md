# Storage

Storage layer providing optimized data structures for components, tags, and events.

## ComponentStorage

**Location:** `src/storage/component_storage.zig`

Automatic storage type selection based on component characteristics.

### isTagComponent()

**Lines:** 10-12

Determines if a component type is a tag (zero-sized struct).

```zig
pub fn isTagComponent(comptime T: type) bool
```

**Returns**: `true` if T is zero-sized (empty struct), `false` otherwise

### ComponentStorage()

**Lines:** 14-16

Returns the appropriate storage type for a component.

```zig
pub fn ComponentStorage(comptime T: type) type
```

**Returns**:
- `TagStorage` if T is zero-sized
- `SparseSet(T)` otherwise

**Example**:
```zig
const Position = struct { x: f32, y: f32 };
const Enemy = struct {}; // Tag component

const PosStorage = ComponentStorage(Position); // SparseSet(Position)
const EnemyStorage = ComponentStorage(Enemy);   // TagStorage
```

## SparseSet

**Location:** `src/storage/sparse_set.zig`

Paginated sparse set for efficient component storage with O(1) operations and group support.

### Architecture

**Lines:** 23-35

```zig
// Pagination constants
pub const page_size = 4096;        // 2^12 entities per page
pub const page_shift = 12;
pub const page_mask = 0xFFF;
pub const max_pages = 16;          // 65536 / 4096

// Core structure (lines 37-45)
pub fn SparseSet(comptime T: type) type {
    return struct {
        sparse: [max_pages]?[]usize,    // Paginated sparse array
        packed: []Entity,                // Dense entity array
        components: []T,                 // Dense component array
        group_size: usize,               // Group boundary marker
        allocator: Allocator,
    };
}
```

**Memory layout**:
- **Sparse pages**: 16 pages max, 4096 entities each, allocated on-demand
- **Dense arrays**: Packed entities and components, grown together
- **Group area**: First `group_size` elements reserved for group entities

### Key Methods

#### init()

**Lines:** 50-61

Initialize empty sparse set.

```zig
pub fn init(allocator: Allocator) SparseSet(T)
```

**Returns**: Empty SparseSet with no allocated pages

**Complexity**: O(1)

#### deinit()

**Lines:** 63-72

Free all allocated memory.

```zig
pub fn deinit(self: *Self) void
```

**Complexity**: O(pages)

#### reserve()

**Lines:** 74-86

Pre-allocate capacity for entities and components.

```zig
pub fn reserve(self: *Self, new_capacity: usize) !void
```

**Parameters**:
- `new_capacity`: Number of entities to reserve space for

**Complexity**: O(n) where n = new_capacity

**Use case**: Call before bulk insertions to avoid reallocation

#### reservePages()

**Lines:** 88-97

Pre-allocate sparse pages.

```zig
pub fn reservePages(self: *Self, page_count: usize) !void
```

**Parameters**:
- `page_count`: Number of pages to allocate (max 16)

**Complexity**: O(page_count)

#### get() / getPtr() / getPtrMut()

**Lines:** 130-161

Retrieve component value or pointer.

```zig
pub fn get(self: *const Self, entity: Entity) T
pub fn getPtr(self: *const Self, entity: Entity) *const T
pub fn getPtrMut(self: *Self, entity: Entity) *T
```

**Parameters**:
- `entity`: Entity to retrieve component from

**Returns**: Component value or pointer

**Panics**: If entity doesn't have component

**Complexity**: O(1)

**Example**:
```zig
const pos = sparse_set.get(entity);
const pos_ptr = sparse_set.getPtrMut(entity);
pos_ptr.x += 10;
```

#### contains()

**Lines:** 124-128

Check if entity has component.

```zig
pub fn contains(self: *const Self, entity: Entity) bool
```

**Parameters**:
- `entity`: Entity to check

**Returns**: `true` if entity has component, `false` otherwise

**Complexity**: O(1)

#### insert()

**Lines:** 165-194

Insert or replace component for entity.

```zig
pub fn insert(self: *Self, entity: Entity, component: T) !void
```

**Parameters**:
- `entity`: Entity to add component to
- `component`: Component value

**Complexity**: O(1) amortized

**Behavior**:
1. If entity already has component: Replace value
2. Otherwise: Add to dense arrays, update sparse mapping
3. Group entities: Insert at group boundary (index group_size)
4. Non-group entities: Append to end

**Example**:
```zig
try sparse_set.insert(entity, Position{ .x = 0, .y = 0 });
```

#### remove()

**Lines:** 196-223

Remove component from entity.

```zig
pub fn remove(self: *Self, entity: Entity) void
```

**Parameters**:
- `entity`: Entity to remove component from

**Complexity**: O(1)

**Behavior**:
1. Swap entity with last entity in its region (group/non-group)
2. Update sparse mappings
3. Adjust group_size if entity was in group

**Safety**: Does not check if entity has component. Caller must verify.

#### moveToGroup()

**Lines:** 240-257

Move entity into group region.

```zig
pub fn moveToGroup(self: *Self, entity: Entity) void
```

**Parameters**:
- `entity`: Entity to move to group

**Complexity**: O(1)

**Behavior**: Swaps entity to position `group_size`, increments `group_size`

**Use case**: Called when entity gains all components required for a group

#### moveFromGroup()

**Lines:** 259-275

Move entity out of group region.

```zig
pub fn moveFromGroup(self: *Self, entity: Entity) void
```

**Parameters**:
- `entity`: Entity to move from group

**Complexity**: O(1)

**Behavior**: Swaps entity from group area to non-group area, decrements `group_size`

**Use case**: Called when entity loses a group component

#### getGroupEntities() / getGroupComponents()

**Lines:** 302-309

Direct access to group arrays for fast iteration.

```zig
pub fn getGroupEntities(self: *const Self) []const Entity
pub fn getGroupComponents(self: *Self) []T
```

**Returns**: Slices of first `group_size` elements

**Complexity**: O(1)

**Use case**: Fast group iteration without filtering

**Example**:
```zig
const entities = sparse_set.getGroupEntities();
const components = sparse_set.getGroupComponents();
for (entities, components) |e, *comp| {
    // Process group entities
}
```

### Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| `insert()` | O(1) amortized | May trigger reallocation |
| `remove()` | O(1) | Swap-remove |
| `get()` | O(1) | Direct sparse lookup |
| `contains()` | O(1) | Bounds check + sparse lookup |
| `moveToGroup()` | O(1) | Single swap |
| `moveFromGroup()` | O(1) | Single swap |

### Memory Efficiency

- **Sparse overhead**: 16 pages × 4096 × 8 bytes = 512 KB max (only if all pages allocated)
- **Dense storage**: Linear with entity count
- **Pagination benefit**: Sparse arrays for scattered entity IDs, dense arrays for active entities

## TagStorage

**Location:** `src/storage/tag_storage.zig`

Bitset-backed storage for zero-sized tag components.

### Architecture

**Lines:** 36-42

```zig
pub const TagStorage = struct {
    bitset: DynamicBitSet,           // 1 bit per entity
    packed: []Entity,                // Packed entity array
    sparse_to_dense: []usize,        // Reverse index for O(1) removal
    allocator: Allocator,
};
```

**Memory layout**:
- **Bitset**: 1 bit per entity (65536 bits = 8 KB)
- **Packed array**: Only entities with tag
- **Sparse index**: Maps entity index to packed index

### Key Methods

#### init()

**Lines:** 55-70

Initialize empty tag storage.

```zig
pub fn init(allocator: Allocator) !TagStorage
```

**Returns**: Empty TagStorage

**Complexity**: O(1)

#### deinit()

**Lines:** 72-83

Free all allocated memory.

```zig
pub fn deinit(self: *TagStorage) void
```

#### reserve()

**Lines:** 85-102

Pre-allocate capacity.

```zig
pub fn reserve(self: *TagStorage, new_capacity: usize) !void
```

**Parameters**:
- `new_capacity`: Number of entities to reserve for

**Complexity**: O(1) if sufficient capacity exists

#### set()

**Lines:** 104-144

Add tag to entity.

```zig
pub fn set(self: *TagStorage, entity: Entity) !void
```

**Parameters**:
- `entity`: Entity to add tag to

**Complexity**: O(1) amortized

**Behavior**:
1. If already set: Return early
2. Set bit in bitset
3. Add entity to packed array
4. Update sparse_to_dense mapping

**Example**:
```zig
try tag_storage.set(entity); // Entity now has tag
```

#### unset()

**Lines:** 146-179

Remove tag from entity.

```zig
pub fn unset(self: *TagStorage, entity: Entity) void
```

**Parameters**:
- `entity`: Entity to remove tag from

**Complexity**: O(1)

**Behavior**:
1. Clear bit in bitset
2. Swap-remove entity from packed array
3. Update sparse_to_dense for swapped entity

#### contains()

**Lines:** 181-188

Check if entity has tag.

```zig
pub fn contains(self: *const TagStorage, entity: Entity) bool
```

**Parameters**:
- `entity`: Entity to check

**Returns**: `true` if entity has tag, `false` otherwise

**Complexity**: O(1)

**Example**:
```zig
if (tag_storage.contains(entity)) {
    // Entity is an enemy
}
```

### Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| `set()` | O(1) amortized | May trigger reallocation |
| `unset()` | O(1) | Swap-remove |
| `contains()` | O(1) | Bitset lookup |
| Iteration | O(n) | n = tagged entities only |

### Memory Efficiency

- **Minimal overhead**: 1 bit per entity vs full component
- **Iteration efficiency**: Packed array contains only tagged entities
- **Best for**: Marker components, state flags (Enemy, Dead, Selected, etc.)

## EventStorage

**Location:** `src/storage/event_storage.zig`

Double-buffered event queue for frame-delayed event communication.

### Architecture

**Lines:** 8-13

```zig
pub fn EventStorage(comptime T: type) type {
    return struct {
        write_buffer: ArrayList(T),   // Current frame events
        read_buffer: ArrayList(T),    // Previous frame events
        allocator: Allocator,
    };
}
```

**Characteristics**:
- **Write buffer**: Events enqueued during current frame
- **Read buffer**: Events from previous frame (readable by systems)
- **Frame boundary**: Buffers swap at `world.beginFrame()`

### Key Methods

#### init()

**Lines:** 17-29

Initialize empty event storage.

```zig
pub fn init(allocator: Allocator) EventStorage(T)
```

**Returns**: EventStorage with empty buffers

**Complexity**: O(1)

#### deinit()

**Lines:** 31-35

Free all allocated memory.

```zig
pub fn deinit(self: *Self) void
```

#### enqueue()

**Lines:** 37-39

Add event to write buffer.

```zig
pub fn enqueue(self: *Self, event: T) !void
```

**Parameters**:
- `event`: Event to enqueue

**Complexity**: O(1) amortized

**Use case**: Called by EventWriter during system execution

**Example**:
```zig
try event_storage.enqueue(CollisionEvent{ .a = e1, .b = e2 });
```

#### clear()

**Lines:** 41-43

Clear write buffer.

```zig
pub fn clear(self: *Self) void
```

**Complexity**: O(1)

**Use case**: Called at `world.beginFrame()` after buffer swap

#### swap()

**Lines:** 45-51

Swap write and read buffers.

```zig
pub fn swap(self: *Self) void
```

**Complexity**: O(1)

**Use case**: Called at `world.beginFrame()` to make previous frame's events readable

**Behavior**: Pointer swap, then clear new write buffer

### Frame Lifecycle

```
Frame N:
  beginFrame()  → swap() + clear()
  Systems run   → Write to write_buffer, read from read_buffer
  endFrame()    → Flush commands

Frame N+1:
  beginFrame()  → swap() [Frame N events now in read_buffer]
  Systems run   → Read Frame N events, write Frame N+1 events
  endFrame()
```

### Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| `enqueue()` | O(1) amortized | ArrayList append |
| `swap()` | O(1) | Pointer swap |
| `clear()` | O(1) | Reset length |
| Read iteration | O(n) | n = events in read buffer |

### Memory Efficiency

- **Minimal overhead**: Two ArrayLists
- **Automatic growth**: Buffers grow as needed
- **Event lifetime**: Events automatically cleared after 2 frames

## Storage Comparison

| Feature | SparseSet | TagStorage | EventStorage |
|---------|-----------|------------|--------------|
| **Use case** | Regular components | Marker tags | Frame events |
| **Memory/entity** | sizeof(T) + 16 bytes | 1 bit + 12 bytes | N/A |
| **Insert** | O(1) amortized | O(1) amortized | O(1) amortized |
| **Remove** | O(1) | O(1) | N/A |
| **Lookup** | O(1) | O(1) | N/A |
| **Iteration** | O(n) all entities | O(m) tagged only | O(e) events |
| **Group support** | Yes | No | No |
| **Best for** | Data components | State flags | Cross-system messages |

## Best Practices

1. **Use TagStorage for markers**: Empty structs like `Enemy`, `Dead`, `Selected`
2. **Pre-allocate with reserve()**: Before bulk operations
3. **Leverage group iteration**: For hot-path multi-component queries
4. **Event frame delay**: Design systems accounting for 1-frame latency
5. **Pagination awareness**: SparseSet allocates pages on-demand

## Integration with World

- World creates storage pool from component types at compile time
- Component IDs map to storage indices
- Entity destruction triggers cleanup across all storages
- Group creation coordinates across multiple SparseSet instances

See [World API](../../CLAUDE.md#world-api) for integration details.
