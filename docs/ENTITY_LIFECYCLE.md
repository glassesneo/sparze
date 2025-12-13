# Entity Lifecycle

Detailed documentation of entity creation, destruction, and version-based recycling in Sparze.

## Entity Structure

```zig
pub const Entity = u32;
pub const max_entities = 65535;
```

**Layout**: 32-bit identifier
- **Lower 16 bits**: Index (0-65,534)
- **Upper 16 bits**: Version

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
  │     │     │   └─ No → Pop from free list, increment version
  │     │     │
  │     │     └─> Return entity ID (index | version << 16)
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
              │             (stored in entity_data[index])
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

EntityRegistry uses an **implicit free list** stored in the entity_data array itself:

```
Active entities: entity_data[index] = version
Free entities:   entity_data[index] = next_free_index | 0x8000_0000
                                       └──────┬────────┘   └────┬────┘
                                          Next index        Flag bit
```

**Example state**:
```
Index:  [0] [1] [2] [3] [4] [5]
Data:   [2] [5] [3] [1] [1] [0x8000_0002]
        │   │   │   │   │   └─> Free (next: 2)
        │   │   │   │   └─> Active (version 1)
        │   │   │   └─> Active (version 1)
        │   │   └─> Active (version 3)
        │   └─> Active (version 5)
        └─> Active (version 2)

free_head = 5
```

### Lifecycle Example

**Creation and Destruction Sequence**:

```
1. Initial state:
   free_head = 0 (empty)
   entity_data = []

2. Create entity A:
   → Allocate index 0, version 0
   → Entity A = 0x0000_0000
   → entity_data[0] = 0

3. Create entity B:
   → Allocate index 1, version 0
   → Entity B = 0x0000_0001
   → entity_data[1] = 0

4. Destroy entity A (ID 0x0000_0000):
   → Increment version: entity_data[0] = 1
   → Add to free list: entity_data[0] = 0x8000_0000 (next: 0, version encoded)
   → free_head = 0
   → Old ID 0x0000_0000 now invalid

5. Create entity C:
   → Pop from free list: index 0, increment version
   → Entity C = 0x0001_0000 (version 1, index 0)
   → entity_data[0] = 1 (active, version 1)

6. Try to use old entity A (0x0000_0000):
   → isAlive(0x0000_0000)?
   → entity_data[0] = 1 (version mismatch: 0 != 1)
   → Returns false → Safe rejection!
```

### Version Wraparound

After 65,535 recycles at the same index, version wraps to 0:

```
entity_data[index] = (current_version + 1) & 0xFFFF
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
pub fn isAlive(self: *const EntityRegistry, entity: Entity) bool {
    const index = entity & 0xFFFF;
    const version = entity >> 16;
    return self.entity_data[index] == version;
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
    const index = entity & 0xFFFF;
    self.entity_data[index] += 1; // Increment version
    // Add to free list...
}
```

**Rationale**: World/CommandBuffer handle validation. EntityRegistry is a low-level primitive.

## Memory Footprint

```
EntityRegistry memory:
  entity_data: 65,535 entities × u32 = 256 KB
  free list overhead: stored in entity_data (no additional cost)
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

**Cache efficiency**: entity_data array accessed sequentially during iteration (good locality).

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
- @docs/ARCHITECTURE.md for EntityRegistry structure
- @docs/STORAGE_INTERNALS.md for component cleanup details
- @docs/SYSTEM_PATTERNS.md for entity creation patterns in systems
