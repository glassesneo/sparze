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
| `Group(struct {...})` | Yes | Yes | Fastest, no filtering |

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

Pre-organized multi-component iteration. Supports two group types:

### Group Types

| Type | Syntax | Owned Components | Free Components | Use Case |
|------|--------|------------------|-----------------|----------|
| **Full-owning** | `struct { A, B }` | All | None | Exclusive hot-path access |
| **Partial-owning** | `struct { A, Free(B) }` | Some | Some | Share components, optimize hot path |

### Full-Owning Groups (Default)

**Requires**: `try world.createGroup(struct { Position, Velocity });`

```zig
fn physicsSystem(physics: Group(struct { Position, Velocity })) !void {
    const entities = physics.getEntities();
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);

    for (entities, positions, velocities) |e, *pos, vel| { }
}
```

**Characteristics**:
- All components organized at array start (indices 0..group_size)
- Perfect cache locality, direct array access
- Components cannot be owned by multiple groups
- Fastest iteration possible

### Partial-Owning Groups (New)

Combines owned (organized, direct access) and free (unorganized, indirect access) components.

**Requires**: `try world.createGroup(struct { Position, Velocity, Free(Health) });`

```zig
fn physicsSystem(physics: Group(struct { Position, Velocity, Free(Health) })) !void {
    const entities = physics.getEntities();
    
    // Owned components: direct array access (fast)
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);
    
    for (entities, positions, velocities) |entity, *pos, vel| {
        pos.x += vel.dx;
        
        // Free component: sparse set lookup (one indirection)
        if (pos.x < 0) {
            const health = physics.getComponentMut(entity, Health);
            health.hp -= 10;
        }
    }
}
```

**Characteristics**:
- **Owned components**: Organized in group region, O(1) direct array access
- **Free components**: NOT organized, O(1) sparse set lookup (one indirection)
- **Component sharing**: Free components CAN be owned by other groups
- **All components required**: Entity must have ALL components (owned + free) to be in group

**Example - Component Sharing**:
```zig
// Group 1: owns Position, Velocity; uses Health as free
try world.createGroup(struct { Position, Velocity, Free(Health) });

// Group 2: owns Health, Shield (Health is owned here, free in Group 1)
try world.createGroup(struct { Health, Shield });

// This works! Health is owned by Group 2, free in Group 1
```

**API**:
- `getArrayOf(C)`: Only for owned components (compile error if free)
- `getMutArrayOf(C)`: Only for owned components (compile error if free)
- `getComponent(entity, C)`: Works for both owned and free components
- `getComponentMut(entity, C)`: Works for both owned and free components

### Performance Comparison

| Group Type | Owned Access | Free Access | Use When |
|------------|--------------|-------------|----------|
| Full-owning | O(1) direct | N/A | All components hot path, no sharing needed |
| Partial-owning | O(1) direct | O(1) indirect | Some components hot, others occasional, sharing needed |
| Query | N/A | O(1) indirect + filtering | Flexibility > performance |

### Critical Points

- **Validation**: `World.validateGroups(.{ Group1, Group2 })` checks owned component conflicts at compile time
- **Ownership rule**: Owned components cannot be in multiple groups
- **Free components**: Still REQUIRED for membership, just not organized
- **Panics** if group not created

## Filter Modifiers

**For Query and TagQuery:**

**Optional (?T)**: Match entities regardless of component presence. Access via `getOptional()`.

**Exclude(T)**: Filter out entities with component.

**For Group:**

**Free(T)**: Mark component as free (not owned) in partial-owning groups. Access via `getComponent()`.

```zig
Query(struct { Position, ?Color })                    // Color is optional
Query(struct { Enemy, Exclude(Player) })              // Enemy but NOT Player
Group(struct { Position, Velocity, Free(Health) })    // Health is free (not owned)
```

## Best Practices

- **Group** for hot paths (physics, rendering)
- **Query** for flexibility (prototyping, rare systems)
- **Validate groups** early with `World.validateGroups()`
- **crossProduct** for asymmetric pairs, **combinations** for symmetric

See [System Functions](../system/CLAUDE.md).