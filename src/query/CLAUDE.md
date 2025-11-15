# Query Filters

**Location:** `src/query/filter.zig`

Query Filters enable entity iteration in system functions via parameter injection.

## Filter Overview

| Filter | Components | Setup | Modifiers | Use Case |
|--------|-----------|-------|-----------|----------|
| `SingleQuery(T)` | 1 regular | No | No | Single component |
| `SingleTag(T)` | 1 tag | No | No | Single tag |
| `Query(struct {...})` | Multiple | No | Yes | Ad-hoc queries |
| `TagQuery(struct {...})` | Multiple tags | No | Yes | Ad-hoc tag queries |
| `Group(struct {...})` | Multiple | Yes | No | Fastest iteration |

## SingleQuery(T)

Direct array access for single component.

```zig
pub fn SingleQuery(comptime Component: type) type {
    return struct {
        entities: []const Entity,
        components: []Component,
    };
}
```

**Usage**: `for (query.entities, query.components) |e, c| { ... }`

**No modifiers supported.**

## SingleTag(T)

Direct array access for single tag.

```zig
pub const SingleTag = struct {
    entities: []const Entity,
};
```

**Usage**: `for (tag.entities) |e| { ... }`

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

### Key Methods

#### iterator() → Iterator
Standard filtered iteration.

#### combinations() → CombinationIterator
Unique pairs (i < j). O(n²). Use for collision detection.

```zig
var pairs = query.combinations();
while (pairs.next()) |pair| { // [2]Entity
    // Process pair[0], pair[1]
}
```

#### crossProduct(&other) → CrossProductIterator
Cartesian product (N×M). Use for asymmetric interactions.

```zig
var pairs = projectiles.crossProduct(&enemies);
while (pairs.next()) |pair| { // [2]Entity
    // pair[0] from projectiles, pair[1] from enemies
}
```

#### getComponent/getComponentMut(entity, T)
Access required components. **Panics if optional/excluded.**

#### getOptional/getOptionalMut(entity, T)
Access optional components. Returns `?T` or `?*T`.

### Behavior

- Iterates smallest required component set (ignores optional/exclude)
- Runtime filtering checks all requirements
- **Modifiers supported**: `?T`, `Exclude(T)`

## TagQuery(struct { ... })

Tag-specific variant of Query.

```zig
fn stateSystem(
    tags: TagQuery(struct { Active, ?Sleeping, Exclude(Dead) })
) !void {
    var it = tags.iterator();
    while (it.next()) |entity| {
        if (tags.hasTag(entity, Sleeping)) { ... }
    }
}
```

**Compile-time validates** all fields are tag components.

### Methods

- `iterator()`, `crossProduct(&other)`: Same as Query
- `hasTag(entity, Tag)`: Check optional tag presence

## Group(struct { ... })

Pre-organized multi-component iteration (fastest).

**Requires setup**: `try world.createGroup(struct { Position, Velocity });`

```zig
fn physicsSystem(physics: Group(struct { Position, Velocity, Mass })) !void {
    const entities = physics.getEntities();
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);
    const masses = physics.getArrayOf(Mass);

    for (entities, positions, velocities, masses) |e, *pos, vel, mass| {
        pos.x += vel.x;
    }
}
```

### Key Points

- **Fastest**: No runtime filtering, direct array access
- **Cache-friendly**: Group entities at array start (indices 0..group_size)
- **Full-owning**: Components cannot overlap between groups
- **Validate with**: `World.validateGroups(.{ Group1, Group2 })` (compile-time)
- **No modifiers supported**

### Methods

- `getEntities()`: []const Entity
- `getArrayOf(T)` / `getMutArrayOf(T)`: Component slices
- `crossProduct(&other)`: Cross-product iterator

## Filter Modifiers

**Only for Query and TagQuery.**

### Optional (?T)

Match entities regardless of component presence.

```zig
Query(struct { Position, ?Color })

const color = query.getOptional(entity, Color); // ?*Color
if (color) |c| { /* use */ } else { /* default */ }
```

### Exclude(T)

Filter out entities with component.

```zig
Query(struct { Enemy, Exclude(Player) })
// Only entities with Enemy but NOT Player
```

## Performance Comparison

| Filter | Setup | Iteration | Filtering | Best For |
|--------|-------|-----------|-----------|----------|
| SingleQuery | None | O(n) | None | Simple queries |
| SingleTag | None | O(m) | None | Single tag |
| Query | None | O(n) | Runtime | Prototyping, flexibility |
| TagQuery | None | O(m) | Runtime | Tag-based logic |
| Group | O(n) once | O(g) | None | Hot paths |

Where: n = entities with component, m = tagged entities, g = group entities

## Best Practices

1. **Use Group for hot paths**: Physics, rendering
2. **Use Query for flexibility**: Rarely-run systems
3. **Validate groups early**: `World.validateGroups()` at startup
4. **Pre-allocate groups**: Before adding entities
5. **Consider crossProduct**: For asymmetric pairs vs combinations

## Integration

Filters automatically injected by World:

```zig
fn mySystem(
    pos: SingleQuery(Position),
    enemies: Query(struct { Health, Exclude(Dead) }),
    physics: Group(struct { Position, Velocity }),
) !void { }

try world.runSystem(mySystem);
```

See [System Functions](../system/CLAUDE.md).
