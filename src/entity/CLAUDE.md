# Entity System

**Location:** `src/entity/entity.zig`

The entity system provides lightweight identifiers with version-based recycling for managing game objects.

## Entity

**Lines:** 3-11

A 32-bit identifier (`u32`) composed of:
- **Lower 16 bits (index)**: Entity pool index (0-65,535)
- **Upper 16 bits (version)**: Version number for recycling detection

```zig
pub const Entity = u32;
pub const EntityIndex = u16;
pub const EntityVersion = u16;
pub const max_entities = 65535;
```

### Helper functions

**Lines:** 13-22

```zig
// Extract index from entity ID
pub fn getIndex(entity: Entity) EntityIndex {
    return @truncate(entity & index_mask);
}

// Extract version from entity ID
pub fn getVersion(entity: Entity) EntityVersion {
    return @truncate((entity >> index_bits) & version_mask);
}

// Create entity ID from index and version
pub fn createEntity(index: EntityIndex, version: EntityVersion) Entity {
    return (@as(Entity, version) << index_bits) | @as(Entity, index);
}
```

## EntityRegistry

**Lines:** 25-132

Manages entity lifecycle with version-based recycling. Uses implicit free list via entity array for O(1) operations.

### Structure

```zig
pub const EntityRegistry = struct {
    entities: [max_entities]Entity,    // Entity pool
    alive_count: usize,                 // Count of living entities
    next_free: EntityIndex,             // Next free index in free list
};
```

**Key characteristics**:
- Fixed-size array of 65,535 entities
- Implicit free list: dead entities store next free index
- Version increments on recycling to invalidate old references

### Methods

#### init()

**Lines:** 32-42

Initialize an empty registry.

```zig
pub fn init() EntityRegistry
```

**Returns**: Empty EntityRegistry with all entities marked as dead (version 0).

**Complexity**: O(1)

#### create()

**Lines:** 44-71

Create a new entity, recycling from free list if available.

```zig
pub fn create(self: *EntityRegistry) !Entity
```

**Returns**: New Entity ID

**Errors**: `error.EntityLimitReached` if all 65,535 entities are alive

**Complexity**: O(1)

**Behavior**:
1. If free list empty and alive_count < max_entities: Use next sequential index
2. If free list available: Pop from free list, increment version
3. If all entities alive: Return error

**Example**:
```zig
var registry = EntityRegistry.init();
const entity1 = try registry.create();
const entity2 = try registry.create();
```

#### destroy()

**Lines:** 73-93

Destroy an entity, adding it to the free list.

```zig
pub fn destroy(self: *EntityRegistry, entity: Entity) void
```

**Parameters**:
- `entity`: Entity ID to destroy

**Complexity**: O(1)

**Behavior**:
1. Extract index from entity
2. Increment version at index
3. Store old next_free in entity slot (building free list)
4. Update next_free to current index
5. Decrement alive_count

**Safety**: Does not validate if entity is actually alive. Caller must ensure entity validity.

**Example**:
```zig
registry.destroy(entity1);
// entity1 is now invalid, index added to free list
```

#### isAlive()

**Lines:** 95-105

Check if an entity is currently alive via version comparison.

```zig
pub fn isAlive(self: *const EntityRegistry, entity: Entity) bool
```

**Parameters**:
- `entity`: Entity ID to check

**Returns**: `true` if entity is alive, `false` otherwise

**Complexity**: O(1)

**Behavior**: Compares entity version with current version at that index. Match indicates alive entity.

**Example**:
```zig
if (registry.isAlive(entity1)) {
    // Entity is valid
}
```

#### aliveCount()

**Lines:** 107-113

Get the count of currently living entities.

```zig
pub fn aliveCount(self: *const EntityRegistry) usize
```

**Returns**: Number of alive entities

**Complexity**: O(1)

**Example**:
```zig
const count = registry.aliveCount(); // 0-65535
```

#### clear()

**Lines:** 115-127

Reset registry to initial state, destroying all entities.

```zig
pub fn clear(self: *EntityRegistry) void
```

**Complexity**: O(1)

**Behavior**: Resets alive_count and next_free. Does not zero entity array (versions remain).

**Example**:
```zig
registry.clear();
// All entities destroyed, ready for reuse
```

## Usage patterns

### Basic entity lifecycle

```zig
const std = @import("std");
const entity = @import("entity.zig");

pub fn main() !void {
    var registry = entity.EntityRegistry.init();

    // Create entities
    const e1 = try registry.create();
    const e2 = try registry.create();
    const e3 = try registry.create();

    std.debug.print("Alive: {}\n", .{registry.aliveCount()}); // 3

    // Destroy and check
    registry.destroy(e2);
    std.debug.print("E2 alive? {}\n", .{registry.isAlive(e2)}); // false
    std.debug.print("Alive: {}\n", .{registry.aliveCount()}); // 2

    // Recycling
    const e4 = try registry.create(); // Reuses e2's index with incremented version
    std.debug.print("E2 alive? {}\n", .{registry.isAlive(e2)}); // false (old version)
    std.debug.print("E4 alive? {}\n", .{registry.isAlive(e4)}); // true (new version)
}
```

### Version-based validation

```zig
// Store entity reference
const player = try registry.create();

// Later, even if index is recycled:
if (registry.isAlive(player)) {
    // Safe to use - this is the original entity
} else {
    // Entity was destroyed and possibly recycled
    // Old reference is invalid
}
```

## Performance characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| `create()` | O(1) | Constant time creation/recycling |
| `destroy()` | O(1) | Constant time destruction |
| `isAlive()` | O(1) | Simple version comparison |
| `aliveCount()` | O(1) | Cached counter |
| `clear()` | O(1) | Reset counters only |

## Memory layout

- **Total size**: 65,535 × 4 bytes (Entity) + 8 bytes (alive_count + next_free) = ~256 KB
- **Cache-friendly**: Contiguous array, good locality
- **Fixed allocation**: No dynamic memory allocation required

## Best practices

1. **Always check isAlive()** before using stored entity references
2. **Don't assume entity validity** across frames or after destruction
3. **Use version comparison** for entity equality, not index comparison
4. **Pre-allocate** if you know maximum entity count (registry is fixed-size)
5. **Batch operations** when possible to reduce alive_count updates

## Integration with ECS

EntityRegistry is the foundation of the World:
- World wraps EntityRegistry for entity management
- Components are stored separately, indexed by entity
- Entity destruction triggers component cleanup
- Version checking prevents use-after-free bugs

See [World API](../../CLAUDE.md#world-api) for integration details.
