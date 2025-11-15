# Entity System

**Location:** `src/entity/entity.zig`

## Entity

32-bit identifier: lower 16 bits = index (0-65,535), upper 16 bits = version.

```zig
pub const Entity = u32;
pub const max_entities = 65535;
```

## EntityRegistry

Manages entity lifecycle with version-based recycling using implicit free list.

### Key Behaviors

**Recycling**: Destroyed entity index → free list, version increments. Old references become invalid.

**destroy() does not validate** entity is alive - caller must ensure validity.

**Version wraparound**: After 65,535 recycles at same index, version wraps to 0 (rare).

**Memory**: ~256 KB fixed allocation.

### Integration

- World wraps EntityRegistry
- Component storages indexed by entity
- Entity destruction triggers component cleanup
- Version checking prevents use-after-free

See [World API](../../CLAUDE.md#world-api).
