# Entity System

**Location:** `src/entity/entity.zig`

## Entity

32-bit identifier composed of:
- **Lower 16 bits**: Entity index (0-65,535)
- **Upper 16 bits**: Version for recycling detection

```zig
pub const Entity = u32;
pub const max_entities = 65535;

// Extract index/version or create entity
pub fn getIndex(entity: Entity) EntityIndex
pub fn getVersion(entity: Entity) EntityVersion
pub fn createEntity(index: EntityIndex, version: EntityVersion) Entity
```

## EntityRegistry

Manages entity lifecycle with version-based recycling using implicit free list.

### Structure

```zig
pub const EntityRegistry = struct {
    entities: [max_entities]Entity,
    alive_count: usize,
    next_free: EntityIndex,
};
```

### Methods

#### create() - O(1)
Returns new Entity. Recycles from free list if available, otherwise uses sequential index.
Errors with `EntityLimitReached` if all 65,535 entities alive.

#### destroy() - O(1)
Increments version at index, adds to free list, decrements alive_count.
**Does not validate entity is alive** - caller must ensure validity.

#### isAlive() - O(1)
Version comparison: entity version matches current version at index.

#### aliveCount() - O(1)
Returns count of living entities.

#### clear() - O(1)
Resets alive_count and next_free. Versions remain for safety.

## Key Behaviors

**Recycling**: Destroyed entity index goes to free list, version increments. Old entity references become invalid.

**Version wraparound**: After 65,535 recycles of same index, version wraps to 0. Rare in practice.

**Memory**: ~256 KB fixed allocation (65,535 × 4 bytes + metadata).

## Integration with World

- World wraps EntityRegistry
- Component storages indexed by entity
- Entity destruction triggers component cleanup
- Version checking prevents use-after-free

See [World API](../../CLAUDE.md#world-api).
