# Entity Lifecycle

Detailed documentation of entity creation, destruction, and version-based recycling in Sparze.

## Entity Structure

```zig
const std = @import("std");

pub const EntityIndex = u16;
pub const EntityVersion = u16;
pub const max_entities = std.math.maxInt(EntityIndex);

pub const Entity = packed struct(u32) {
    index: EntityIndex,
    version: EntityVersion,

    pub fn init(index: EntityIndex, version: EntityVersion) Entity {
        return .{ .index = index, .version = version };
    }

    pub fn toInt(self: Entity) u32 {
        return @bitCast(self);
    }

    pub fn fromInt(value: u32) Entity {
        return @bitCast(value);
    }
};
```

**Layout**: 32-bit packed struct
- **index** (lower 16 bits): Dense slot index (0-65,534)
- **version** (upper 16 bits): Generation guard

`Entity` is still bit-compatible with the previous u32 representation; use `toInt()` / `fromInt()` for serialization.

**Example**:
```
Entity ID: 0x0003_0042
           └──┬──┘ └──┬──┘
           Version  Index
           (3)      (66)
```

## Entity Creation Flow

```
User Code
  │
  ├─ Immediate: world.createEntity()
  │     │
  │     ├─> EntityRegistry.create()
  │     │     │
  │     │     ├─ Free list empty?
  │     │     │   ├─ Yes → Allocate new index, version = 0
  │     │     │   └─ No → Pop from free list, reuse stored version
  │     │     │
  │     │     └─> Return Entity{ index, version } (bitcast to u32 when needed)
  │     │
  │     └─> Return entity (immediately usable)
  │
  └─ Deferred: commands.createEntityWith(components)
        │
        ├─> Call world.createEntity() → get entity ID
        │
        └─> Queue component additions to command buffer
              (executed at endFrame)
```

**Key points**:
- `createEntity()` executes **immediately** (need ID for subsequent commands)
- `createEntityWith()` creates entity immediately but defers component additions
- No component validation at creation time (components added separately)

## Entity Destruction Flow

```
User Code
  │
  ├─ Deferred: commands.destroyEntity(entity)
  │     │
  │     └─> Queue destroy command to CommandBuffer
  │
  └─ Frame End: world.endFrame()
        │
        └─> CommandBuffer.flush()
              │
              ├─ For each destroy command:
              │   │
              │   ├─ Validate: entity_registry.isAlive(entity)?
              │   │   ├─ No → Skip (already destroyed)
              │   │   └─ Yes → Continue
              │   │
              │   ├─> Remove from all component storages
              │   │     (SparseSet.remove(), TagStorage.remove())
              │   │
              │   └─> EntityRegistry.destroy(entity)
              │         │
              │         ├─ Increment version at index
              │         │
              │         └─ Add index to free list
              │             (stored in entities[index])
              │
              └─> Old entity IDs now invalid (version mismatch)
```

**Key points**:
- `destroyEntity()` is **deferred** (safe during iteration)
- Entity liveness validated during flush (prevents double-destroy)
- Components automatically cleaned up before entity destruction
- Index recycled via free list, version incremented

## Version-Based Recycling

### Free List Structure

EntityRegistry keeps an **implicit free list** inside the packed `Entity` values:

- **Alive slot**: `entities[index] = Entity{ .index = index, .version = current }`
- **Free slot**: `entities[index] = Entity{ .index = next_free_index, .version = next_version }`
- **Head pointer**: `next_index_to_recycle.index` stores the head index (version field unused); `available` counts free slots

Because `isAlive()` checks `entities[index].index == index`, free slots are automatically rejected (their index field points to the next free node instead).

**Free list updates**:
- `destroy(entity)`: bump version, write `entities[index] = Entity{ .index = prev_head_index, .version = bumped_version }`, set `next_index_to_recycle` to this index, increment `available`.
- `create()`: pop `next_index_to_recycle.index`, read its stored version, advance head to the stored `next_free_index`, decrement `available`, and return `Entity{ .index = popped_index, .version = stored_version }`.

### Lifecycle Example

**Creation and Destruction Sequence**:

```
1. Initial state:
   next_index = 0, available = 0
   entities = []

2. Create entity A:
   → Allocate index 0, version 0
   → Entity A = Entity{ .index = 0, .version = 0 }
   → entities[0] = Entity{ .index = 0, .version = 0 }
   → next_index = 1

3. Create entity B:
   → Allocate index 1, version 0
   → Entity B = Entity{ .index = 1, .version = 0 }
   → entities[1] = Entity{ .index = 1, .version = 0 }
   → next_index = 2

4. Destroy entity A (Entity{ .index = 0, .version = 0 }):
   → bumped_version = 1
   → prev_head_index = 0 (free list was empty)
   → entities[0] = Entity{ .index = 0, .version = 1 }   // free node: points to itself
   → next_index_to_recycle = Entity{ .index = 0, .version = 0 }
   → available = 1

5. Create entity C:
   → Pop head index = 0, stored_version = 1, stored_next = 0
   → next_index_to_recycle = Entity{ .index = stored_next, .version = 0 }
   → entities[0] = Entity{ .index = 0, .version = 1 }   // now alive
   → Entity C = Entity{ .index = 0, .version = 1 }
   → available = 0

6. Try to use old entity A (Entity{ .index = 0, .version = 0 }):
   → isAlive(old_entity)?
   → entities[0] = Entity{ .index = 0, .version = 1 } (version mismatch)
   → Returns false → Safe rejection!
```

### Version Wraparound

After 65,535 recycles at the same index, version wraps to 0:

```
const new_version: EntityVersion = current_version + 1; // wraps after 0xFFFF
```

**Probability of collision**:
- Single index: 1 / 65,536 after full wrap
- Entire registry: Extremely rare in practice

## Integration with Component Storages

### Component Cleanup on Destruction

```
World.destroyEntity(entity)
  │
  └─> For each component storage:
        │
        ├─ SparseSet.remove(entity)
        │   └─> Swap-remove from dense array
        │
        └─ TagStorage.remove(entity)
            └─> Clear bitset, update reverse indices
```

**IMPORTANT**: Component storages do NOT validate entity before removal. EntityRegistry.destroy() is the source of truth for entity liveness.

### Component Operations After Destroy

**Scenario**: Entity destroyed, but command buffer has pending component additions.

```
Frame N:
  commands.destroyEntity(entity_42);
  commands.addComponent(entity_42, Position{ ... });

Frame N end (flush):
  1. Execute destroyEntity(entity_42)
     → entity_42 version increments
     → entity_42 index recycled

  2. Execute addComponent(entity_42, Position)
     → Validate: isAlive(entity_42)? → false (version mismatch)
     → Skip operation (no resurrection!)
```

**Safety guarantee**: Command buffer validates entity liveness before every component operation.

## Safety Mechanisms

### 1. Version Checking (Use-After-Free Prevention)

```zig
pub fn isAlive(self: EntityRegistry, entity: Entity) bool {
    const index = getIndex(entity);
    if (index >= self.next_index) return false; // never allocated
    const slot = self.entities[index];
    return slot.index == index and slot.version == entity.version;
}
```

**Used by**:
- Query/TagQuery filters (Debug/ReleaseSafe builds)
- CommandBuffer during flush
- User code (optional validation)

### 2. Entity Liveness Validation in Queries

**Debug/ReleaseSafe**:
```zig
fn filter(entity: Entity) bool {
    if (!entity_registry.isAlive(entity)) return false;
    // ... component checks
}
```

**ReleaseFast**: Validation compiled out (trust the system)

### 3. Command Buffer Validation

Before executing each deferred operation:
- **add_component**: Skip if entity not alive
- **remove_component**: Skip if entity not alive
- **destroy_entity**: Check isAlive() before destruction (idempotent)

### 4. EntityRegistry Constraints

**destroy() does NOT validate** entity is alive:
```zig
pub fn destroy(self: *EntityRegistry, entity: Entity) void {
    // No isAlive check - caller's responsibility
    const index = getIndex(entity);
    const current = self.entities[index];
    const new_version: EntityVersion = current.version + 1;
    const prev_head_index = if (self.available == 0) index else self.next_index_to_recycle.index;

    self.entities[index] = Entity{ .index = prev_head_index, .version = new_version };
    self.next_index_to_recycle = Entity{ .index = index, .version = 0 };
    self.available += 1;
}
```

**Rationale**: World/CommandBuffer handle validation. EntityRegistry is a low-level primitive.

## Memory Footprint

```
EntityRegistry memory:
  entities: 65,535 entities × 4 bytes = 256 KB
  free list overhead: stored in entities (no additional cost)
  Metadata: ~16 bytes

Total: ~256 KB fixed allocation
```

**Trade-off**: Fixed memory cost for O(1) recycling and version checking.

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| create() | O(1) | Pop from free list or increment counter |
| destroy() | O(1) | Push to free list, increment version |
| isAlive() | O(1) | Array lookup + comparison |
| Version increment | O(1) | Bitwise operations |

**Cache efficiency**: entities array accessed sequentially during iteration (good locality).

## Example: Full Lifecycle

```zig
// Create entity
const player = try world.createEntity();
try world.addComponent(player, Position{ .x = 0, .y = 0 });
try world.addComponent(player, Health{ .hp = 100 });

// Use entity
for (0..100) |frame| {
    try world.runSystem(movementSystem);
    if (player_dead) {
        try world.destroyEntity(player); // Deferred
        break;
    }
}

// Later: try to use old ID
try world.addComponent(player, Weapon{ ... });
// → Fails if player was destroyed (version mismatch)
```

See also:
- docs/ARCHITECTURE.md for EntityRegistry structure
- docs/STORAGE_INTERNALS.md for component cleanup details
- docs/SYSTEM_PATTERNS.md for entity creation patterns in systems
