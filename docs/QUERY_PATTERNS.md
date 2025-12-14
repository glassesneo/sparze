# Query Patterns and Filter Selection

Comprehensive guide to choosing and using query filters in Sparze.

## Decision Flowchart

```
START: Need to iterate entities with components?
│
├─ Single component only?
│  ├─ Regular component → Use SingleQuery(T)
│  └─ Tag component → Use SingleTag(T)
│
├─ Multiple components, hot path (frequent iteration)?
│  ├─ All components needed on every iteration?
│  │  └─ Use full-owning Group(struct { A, B, C })
│  └─ Some components needed occasionally?
│     └─ Use partial-owning Group(struct { A, B, Free(C) })
│
├─ Multiple components, flexibility over performance?
│  ├─ Need Optional/Exclude modifiers?
│  │  ├─ All tags → Use TagQuery(struct { ... })
│  │  └─ Regular components → Use Query(struct { ... })
│  └─ Simple filtering → Use Query(struct { A, B })
│
└─ Special iteration patterns?
   ├─ Unique pairs (i < j) → Query.combinations()
   └─ Cross product (N×M) → Query.crossProduct()
```

## Filter Comparison

| Filter | Setup Required | Modifiers | Access Pattern | Performance | Use Case |
|--------|----------------|-----------|----------------|-------------|----------|
| `SingleQuery(T)` | No | No | Direct array | Fastest | Single component iteration |
| `SingleTag(T)` | No | No | Direct array | Fastest | Single tag iteration |
| `Query(struct {...})` | No | Optional, Exclude | Sparse set lookup | Good | Flexible multi-component queries |
| `TagQuery(struct {...})` | No | Optional, Exclude | Bitset lookup | Good | Tag-only queries |
| `Group(struct {...})` | Compile-time | Free | Direct array (owned) | Fastest | Hot path multi-component |

## Filter Types in Detail

### SingleQuery(T) - Direct Component Access

**When to use**: Iterating a single component type, need maximum performance.

```zig
fn velocityDecaySystem(velocities: SingleQuery(Velocity)) !void {
    for (velocities.entities, velocities.components) |entity, *vel| {
        vel.x *= 0.99;
        vel.y *= 0.99;
    }
}
```

**Characteristics**:
- Direct packed array access
- No modifiers supported
- Iterates all entities with the component
- Zero overhead

### SingleTag(T) - Direct Tag Access

**When to use**: Iterating entities with a specific tag marker.

```zig
fn enemySpawnSystem(enemies: SingleTag(Enemy)) !void {
    for (enemies.entities) |entity| {
        // All entities tagged as Enemy
    }
}
```

**Characteristics**:
- Direct entity array access
- No component data (tags are zero-sized)
- Compile-time validated to be a tag type

### Query(struct { ... }) - Flexible Multi-Component Iteration

**When to use**: Need multiple components with optional filtering, or prototyping.

```zig
fn damageSystem(
    query: Query(struct { Health, ?Armor, Exclude(Invincible) })
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponentMut(entity, Health);
        const armor = query.getOptional(entity, Armor); // ?Armor (value copy)

        var damage = 10;
        if (armor) |a| damage -= a.value;
        health.hp -= damage;
    }
}
```

**Characteristics**:
- Runtime multi-component intersection
- Iterates smallest required component set (ignores optional/exclude for iteration)
- `getComponent/Mut()` panics if called on optional/excluded components
- `getOptional/Mut()` returns `?T` or `?*T`

**Entity liveness validation**:
- **Debug/ReleaseSafe**: Automatic validation via `entity_registry.isAlive()`
- **ReleaseFast**: Compiled out (zero overhead)
- Prevents iteration over destroyed entities

**Special iterators**:
```zig
// Unique pairs (i < j) - collision detection
var pairs = query.combinations();
while (pairs.next()) |[entity_a, entity_b]| {
    // Check collision between entity_a and entity_b
}

// Cross product (N×M) - asymmetric interactions
var pairs = missiles.crossProduct(&targets);
while (pairs.next()) |[missile, target]| {
    // Check if missile hits target
}
```

### TagQuery(struct { ... }) - Tag-Specific Queries

**When to use**: Querying multiple tag components with filtering.

```zig
fn activeEnemySystem(
    tags: TagQuery(struct { Active, Enemy, ?Sleeping, Exclude(Dead) })
) !void {
    var it = tags.iterator();
    while (it.next()) |entity| {
        if (tags.hasTag(entity, Sleeping)) continue;
        // Process active, non-sleeping enemies
    }
}
```

**Characteristics**:
- Compile-time validates all fields are tag types
- Same behavior as Query but for tags only
- Use `hasTag(entity, Tag)` to check optional tags

### Group(struct { ... }) - Pre-Organized Iteration

**When to use**: Hot path iteration where performance is critical.

#### Full-Owning Groups

**Defined in World signature**:
```zig
const World = sparze.World(
    struct { Position, Velocity },
    struct { DeltaTime },
    struct {},
    .{ struct { Position, Velocity } },
);
```

```zig
fn physicsSystem(physics: Group(struct { Position, Velocity })) !void {
    const entities = physics.getEntities();
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);

    for (entities, positions, velocities) |e, *pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}
```

**Characteristics**:
- All components organized at array start (indices 0..group_size)
- Perfect cache locality, direct array access
- Components cannot be owned by multiple groups
- Fastest iteration possible
- Group membership determined at compile time

#### Partial-Owning Groups

**Defined in World signature**:
```zig
const World = sparze.World(
    struct { Position, Velocity, Health },
    struct {},
    struct {},
    .{ struct { Position, Velocity, Free(Health) } },
);
```

```zig
fn physicsSystem(
    physics: Group(struct { Position, Velocity, Free(Health) })
) !void {
    const entities = physics.getEntities();

    // Owned components: direct array access (fast)
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);

    for (entities, positions, velocities) |entity, *pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;

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

**API differences**:
- `getArrayOf(C)` / `getMutArrayOf(C)`: Only for owned components (compile error if free)
- `getComponent(entity, C)` / `getComponentMut(entity, C)`: Works for both owned and free

## Component Sharing Patterns

### Pattern 1: Shared Read-Only Component

```zig
const World = sparze.World(
    struct { Position, Velocity, Health, Armor },
    struct {},
    struct {},
    .{
        // Group 1: Physics system owns Position, Velocity; reads Health
        struct { Position, Velocity, Free(Health) },
        // Group 2: Combat system owns Health, Armor
        struct { Health, Armor },
    },
);

// Health is owned by Group 2, free in Group 1
```

**Use case**: Physics needs to check health occasionally, combat system processes health frequently.

### Pattern 2: Disjoint Hot Paths

```zig
const World = sparze.World(
    struct { Position, Sprite, Layer, Velocity, Mass },
    struct {},
    struct {},
    .{
        // Group 1: Rendering
        struct { Position, Sprite, Layer },
        // Group 2: Physics (can't own Position - already owned by Group 1)
        struct { Velocity, Mass, Free(Position) },
    },
);
// This works! Position owned by Group 1, free in Group 2
```

**Use case**: Rendering iterates Position+Sprite, physics updates Velocity then applies to Position occasionally.

### Pattern 3: Multi-Stage Processing

```zig
const World = sparze.World(
    struct { AIState, Target, Position, Velocity },
    struct {},
    struct {},
    .{
        // Stage 1: AI decision making
        struct { AIState, Target },
        // Stage 2: Movement execution
        struct { Position, Velocity, Free(AIState) },
    },
);
// AIState drives both groups but owned by AI system
```

## Performance Comparison

| Pattern | Owned Component Access | Free Component Access | Cache Efficiency | Setup Cost |
|---------|------------------------|----------------------|------------------|------------|
| SingleQuery | N/A | O(1) direct | Excellent | None |
| Query | N/A | O(1) indirect + filter | Good | None |
| Full-owning Group | O(1) direct | N/A | Excellent | World signature |
| Partial-owning Group | O(1) direct | O(1) indirect | Very Good | World signature |

**Iteration speed** (entities/second, approximate):
- SingleQuery: 100M+ (memory bound)
- Full-owning Group: 100M+ (memory bound)
- Partial-owning Group owned access: 100M+, free access: 50M+
- Query: 50M+ (filtering overhead)

## Filter Modifiers

### Optional (?T)

**Purpose**: Match entities regardless of component presence.

```zig
Query(struct { Position, ?Color })
// Matches: entities with Position, with or without Color
```

**Access**:
- Use `getOptional(entity, T)` → returns `?T` (value copy)
- Use `getOptionalMut(entity, T)` → returns `?*T` (pointer)

**Iteration**: Optional components NOT used for iteration (iterates required components only)

### Exclude(T)

**Purpose**: Filter out entities that have a specific component.

```zig
Query(struct { Enemy, Exclude(Dead) })
// Matches: entities with Enemy but NOT Dead
```

**Access**: Cannot access excluded components (getComponent will panic)

**Iteration**: Excluded components NOT checked during iteration (filtered during next())

### Free(T) - Groups Only

**Purpose**: Mark component as free (not owned) in partial-owning groups.

```zig
Group(struct { Position, Velocity, Free(Health) })
// Owns: Position, Velocity
// Free: Health (required but not owned)
```

**Access**: Use `getComponent(entity, T)` for free components (not getArrayOf)

## Best Practices

1. **Start with Query, optimize to Group**: Prototype with Query, profile, then create Groups for hot paths

2. **Validate groups at startup**:
   ```zig
   World.validateGroups(.{ PhysicsGroup, RenderGroup, AIGroup });
   ```
   Compile-time error if ownership conflicts exist

3. **Use SingleQuery when possible**: Zero overhead for single-component iteration

4. **Group organization**:
   - Own components that are accessed together in tight loops
   - Mark rarely-accessed components as Free
   - Keep group size reasonable (2-4 owned components)

5. **Iteration patterns**:
   - `combinations()`: Collision detection, unique pairs
   - `crossProduct()`: Missiles vs targets, asymmetric interactions
   - Regular iteration: Most common case

6. **Query filtering**:
   - Use Optional for components that might not exist
   - Use Exclude to filter out entities in specific states
   - Combine both for complex filtering

## Common Pitfalls

1. **Forgetting to declare groups**: Groups must be listed in the `sparze.World` signature; omitting them means systems expecting a Group parameter won't compile.

2. **Ownership conflicts**: Two groups can't own the same component
   ```zig
   const World = sparze.World(
       struct { A, B, C },
       struct {},
       struct {},
       .{
           struct { A, B },
           struct { B, C }, // Error! B already owned
       },
   );
   ```

3. **Accessing optional components wrong**:
   ```zig
   // Wrong: getComponent panics on optional
   const color = query.getComponent(entity, Color); // PANIC

   // Right: use getOptional
   const color = query.getOptional(entity, Color); // ?Color (value)
   // Or use getOptionalMut for pointer
   const color_ptr = query.getOptionalMut(entity, Color); // ?*Color
   ```

4. **Using getArrayOf on Free components**:
   ```zig
   // Wrong: Free components can't use direct array access
   const health = group.getArrayOf(Health); // Compile error

   // Right: use getComponent
   const health = group.getComponent(entity, Health);
   ```

See also:
- docs/ARCHITECTURE.md for filter internals
- docs/SYSTEM_PATTERNS.md for system integration examples
