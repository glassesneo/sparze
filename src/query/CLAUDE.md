# Query Filters

**Location:** `src/query/filter.zig`

Query Filters enable entity iteration in system functions via parameter injection.

## Filter Overview

| Filter | Setup | Modifiers | Key Characteristic |
|--------|-------|-----------|-------------------|
| `SingleQuery(T)` | No | No | Direct array access |
| `SingleTag(T)` | No | No | Direct array access |
| `Query(struct {...})` | No | Yes | Runtime filtering |
| `TagQuery(struct {...})` | No | Yes | Runtime filtering, tags only |
| `Group(struct {...})` | Yes | No | Fastest, no filtering |

## SingleQuery(T) / SingleTag(T)

Direct packed array access. No modifiers.

```zig
// SingleQuery
for (query.entities, query.components) |e, c| { ... }

// SingleTag
for (tag.entities) |e| { ... }
```

## Query(struct { ... })

Runtime multi-component intersection with modifiers.

```zig
fn damageSystem(
    query: Query(struct { Health, ?Armor, Exclude(Invincible) })
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponentMut(entity, Health);
        const armor = query.getOptional(entity, Armor); // ?*Armor
    }
}
```

**Key behaviors**:
- Iterates smallest required component set (ignores optional/exclude)
- `getComponent/Mut()` **panics if optional/excluded**
- `getOptional/Mut()` returns `?T` or `?*T`

**Iterators**:
- `combinations()`: Unique pairs (i < j), use for collision detection
- `crossProduct(&other)`: N×M pairs, use for asymmetric interactions

## TagQuery(struct { ... })

Tag-specific Query variant. **Compile-time validates** all fields are tags.

```zig
tags: TagQuery(struct { Active, ?Sleeping, Exclude(Dead) })
// Use hasTag(entity, Tag) for optional tags
```

## Group(struct { ... })

Pre-organized multi-component iteration (fastest).

**Requires**: `try world.createGroup(struct { Position, Velocity });`

```zig
fn physicsSystem(physics: Group(struct { Position, Velocity })) !void {
    const entities = physics.getEntities();
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);

    for (entities, positions, velocities) |e, *pos, vel| { }
}
```

**Critical points**:
- **Cache-friendly**: Group entities at array start (indices 0..group_size)
- **Full-owning**: Components cannot overlap between groups
- **Validate**: `World.validateGroups(.{ Group1, Group2 })` at compile time
- **Panics** if group not created

## Filter Modifiers

**Only for Query and TagQuery.**

**Optional (?T)**: Match entities regardless of component presence. Access via `getOptional()`.

**Exclude(T)**: Filter out entities with component.

```zig
Query(struct { Position, ?Color })       // Color is optional
Query(struct { Enemy, Exclude(Player) }) // Enemy but NOT Player
```

## Best Practices

- **Group** for hot paths (physics, rendering)
- **Query** for flexibility (prototyping, rare systems)
- **Validate groups** early with `World.validateGroups()`
- **crossProduct** for asymmetric pairs, **combinations** for symmetric

See [System Functions](../system/CLAUDE.md).
