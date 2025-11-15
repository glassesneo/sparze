# Query Filters

**Location:** `src/query/filter.zig`

Query Filters provide entity iteration capabilities for system functions. All filters are injected as parameters via World's parameter injection system.

## Filter Types Overview

| Filter | Components | Setup Required | Modifiers | Use Case |
|--------|-----------|----------------|-----------|----------|
| `SingleQuery(T)` | 1 regular | No | No | Single component iteration |
| `SingleTag(T)` | 1 tag | No | No | Single tag iteration |
| `Query(struct {...})` | Multiple regular | No | Yes | Ad-hoc multi-component queries |
| `TagQuery(struct {...})` | Multiple tags | No | Yes | Ad-hoc multi-tag queries |
| `Group(struct {...})` | Multiple regular | Yes (`createGroup()`) | No | Fastest multi-component iteration |

## SingleQuery(T)

**Lines:** 48-70

Single component query filter for iterating entities with one regular component.

### Structure

```zig
pub fn SingleQuery(comptime Component: type) type {
    return struct {
        entities: []const Entity,      // Packed entity array
        components: []Component,        // Packed component array
    };
}
```

### Usage

```zig
fn healthSystem(health: SingleQuery(Health)) !void {
    for (health.entities, health.components) |entity, h| {
        std.debug.print("Entity {} has {} HP\n", .{entity, h.value});
    }
}
```

### Methods

#### init()

**Lines:** 58-64

Initialize from SparseSet.

```zig
pub fn init(sparse_set: anytype) Self
```

**Internal use**: Called by World during parameter injection

#### crossProduct()

**Lines:** 66-69

Create cross-product iterator with another query filter.

```zig
pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator
```

**Returns**: Iterator over N×M pairs

**Use case**: Asymmetric pair interactions (e.g., bullets × enemies)

### Characteristics

- **No runtime filtering**: Direct array access
- **Cache-friendly**: Packed arrays
- **No modifiers**: Cannot use `?T` or `Exclude(T)`
- **Best for**: Simple single-component iteration

## SingleTag(T)

**Lines:** 540-560

Single tag component query filter.

### Structure

```zig
pub const SingleTag = struct {
    entities: []const Entity,    // Packed entity array (tags only)
};
```

### Usage

```zig
fn enemySystem(enemies: SingleTag(Enemy)) !void {
    for (enemies.entities) |entity| {
        std.debug.print("Enemy entity: {}\n", .{entity});
    }
}
```

### Methods

#### init()

**Lines:** 549-554

Initialize from TagStorage.

```zig
pub fn init(tag_storage: anytype) Self
```

#### crossProduct()

**Lines:** 556-559

Create cross-product iterator.

```zig
pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator
```

### Characteristics

- **Bitset-backed**: 1 bit per entity
- **Packed iteration**: Only tagged entities
- **No component data**: Tags are markers only
- **Best for**: State flags, markers

## Query(struct { ... })

**Lines:** 97-300

Runtime multi-component intersection with filter modifier support.

### Structure

```zig
pub fn Query(comptime QueryComponents: type) type {
    return struct {
        world: *const WorldType,
        smallest_sparse_set_id: usize,
        smallest_sparse_set_size: usize,
    };
}
```

### Usage

```zig
fn damageSystem(
    query: Query(struct { Health, ?Armor, Exclude(Invincible) })
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponentMut(entity, Health);
        const armor = query.getOptional(entity, Armor);

        if (armor) |arm| {
            // Damage with armor
        } else {
            // Damage without armor
        }
    }
}
```

### Methods

#### init()

**Lines:** 137-158

Initialize and find smallest component set for iteration.

```zig
pub fn init(world: *const WorldType) Self
```

**Behavior**:
1. Find smallest required component set (ignores optional/exclude)
2. Store sparse set ID and size for iteration

**Internal use**: Called by World during parameter injection

#### filter()

**Lines:** 209-223

Check if entity satisfies all query requirements.

```zig
fn filter(self: *const Self, entity: Entity) bool
```

**Returns**: `true` if entity has all required components and doesn't have excluded ones

**Behavior**:
1. Check all required components
2. Skip optional components
3. Ensure excluded components absent

#### getComponent() / getComponentMut()

**Lines:** 186-196

Retrieve required component.

```zig
pub fn getComponent(self: *const Self, entity: Entity, comptime Component: type) Component
pub fn getComponentMut(self: *Self, entity: Entity, comptime Component: type) *Component
```

**Parameters**:
- `entity`: Entity to get component from
- `Component`: Component type (must not be optional or excluded)

**Returns**: Component value or mutable pointer

**Panics**: If component is optional or excluded

#### getOptional() / getOptionalMut()

**Lines:** 198-206

Retrieve optional component.

```zig
pub fn getOptional(self: *const Self, entity: Entity, comptime Component: type) ?Component
pub fn getOptionalMut(self: *Self, entity: Entity, comptime Component: type) ?*Component
```

**Parameters**:
- `entity`: Entity to get component from
- `Component`: Component type (must be marked optional with `?T`)

**Returns**: Component value/pointer or `null`

#### iterator()

**Lines:** 225-230

Create filtered iterator.

```zig
pub fn iterator(self: *const Self) Iterator
```

**Returns**: Iterator that yields matching entities

**Use case**: Standard entity iteration

#### combinations()

**Lines:** 232-293

Create unique pairs iterator (i < j).

```zig
pub fn combinations(self: *const Self) CombinationIterator
```

**Returns**: Iterator over unique entity pairs

**Complexity**: O(n²) where n = matching entities

**Use case**: Collision detection, pairwise interactions

**Example**:
```zig
fn collisionSystem(entities: Query(struct { Position, Collider })) !void {
    var pairs = entities.combinations();
    while (pairs.next()) |pair| {
        const pos1 = entities.getComponent(pair[0], Position);
        const pos2 = entities.getComponent(pair[1], Position);
        // Check collision between pair[0] and pair[1]
    }
}
```

#### crossProduct()

**Lines:** 296-299

Create Cartesian product with another query.

```zig
pub fn crossProduct(self: *const Self, other: anytype) CrossProductIterator
```

**Returns**: Iterator over N×M pairs

**Use case**: Asymmetric interactions (projectiles × enemies)

**Example**:
```zig
fn projectileSystem(
    projectiles: Query(struct { Position, Projectile }),
    enemies: Query(struct { Position, Enemy })
) !void {
    var pairs = projectiles.crossProduct(&enemies);
    while (pairs.next()) |pair| {
        // Check projectile-enemy collision
    }
}
```

### Iterator Types

#### Iterator

**Lines:** 238-250

Filtered entity iterator.

```zig
const Iterator = struct {
    query: *const QueryType,
    index: usize,

    pub fn next(self: *Iterator) ?Entity
};
```

**Behavior**: Iterates smallest component set, filters each entity

#### CombinationIterator

**Lines:** 252-293

Unique pairs iterator (i < j).

```zig
const CombinationIterator = struct {
    query: *const QueryType,
    i: usize,
    j: usize,

    pub fn next(self: *CombinationIterator) ?[2]Entity
};
```

**Behavior**: Nested loop with i < j constraint, filters both entities

### Characteristics

- **No setup required**: Works immediately
- **Runtime filtering**: Checks components during iteration
- **Modifier support**: `?T` and `Exclude(T)` supported
- **Optimization**: Iterates smallest component set
- **Best for**: Ad-hoc queries, prototyping

## TagQuery(struct { ... })

**Lines:** 590-704

Runtime multi-tag intersection (tag-specific variant of Query).

### Structure

```zig
pub fn TagQuery(comptime QueryTags: type) type {
    return struct {
        world: *const WorldType,
        smallest_tag_storage_id: usize,
        smallest_tag_storage_size: usize,
    };
}
```

### Usage

```zig
fn stateSystem(
    tags: TagQuery(struct { Active, ?Sleeping, Exclude(Dead) })
) !void {
    var it = tags.iterator();
    while (it.next()) |entity| {
        const is_sleeping = tags.hasTag(entity, Sleeping);
        if (is_sleeping) {
            // Handle sleeping entity
        }
    }
}
```

### Methods

#### init()

**Lines:** 637-676

Initialize and find smallest tag set.

```zig
pub fn init(world: *const WorldType) Self
```

**Compile-time validation**: Ensures all fields are tag components

#### filter()

**Lines:** 678-693

Check if entity satisfies tag requirements.

```zig
fn filter(self: *const Self, entity: Entity) bool
```

**Returns**: `true` if entity has required tags and lacks excluded tags

#### hasTag()

**Lines:** 695-698

Check if entity has specific tag.

```zig
pub fn hasTag(self: *const Self, entity: Entity, comptime Tag: type) bool
```

**Parameters**:
- `entity`: Entity to check
- `Tag`: Tag type (can be optional)

**Returns**: `true` if entity has tag

**Use case**: Check optional tags

#### crossProduct()

**Lines:** 700-703

Create cross-product iterator.

```zig
pub fn crossProduct(self: *const Self, other: anytype) CrossProductIterator
```

### Characteristics

- **Tag-specific**: Validates all fields are tags at compile time
- **Modifier support**: `?T` and `Exclude(T)` supported
- **Bitset operations**: Fast tag checking
- **Best for**: State-based queries

## Group(struct { ... })

**Lines:** 456-538

Pre-organized multi-component iteration (fastest option).

### Structure

```zig
pub fn Group(comptime GroupComponents: type) type {
    return struct {
        world: *const WorldType,
        sparse_set_ids: [num_components]usize,
    };
}
```

### Setup Required

Groups must be created before use:

```zig
// In initialization code:
try world.createGroup(struct { Position, Velocity });

// In system function:
fn physicsSystem(physics: Group(struct { Position, Velocity })) !void {
    // ...
}
```

### Usage

```zig
fn physicsSystem(physics: Group(struct { Position, Velocity, Mass })) !void {
    const entities = physics.getEntities();
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);
    const masses = physics.getArrayOf(Mass);

    for (entities, positions, velocities, masses) |e, *pos, vel, mass| {
        pos.x += vel.x * delta;
        pos.y += vel.y * delta;
    }
}
```

### Methods

#### init()

**Lines:** 493-518

Initialize from world, get sparse set pointers.

```zig
pub fn init(world: *const WorldType) Self
```

**Panics**: If group not created via `world.createGroup()`

#### getEntities()

**Lines:** 520-523

Get group entity array.

```zig
pub fn getEntities(self: *const Self) []const Entity
```

**Returns**: Slice of entities in group (first `group_size` elements)

**Complexity**: O(1)

#### getArrayOf() / getMutArrayOf()

**Lines:** 525-531

Get component array.

```zig
pub fn getArrayOf(self: *const Self, comptime Component: type) []const Component
pub fn getMutArrayOf(self: *Self, comptime Component: type) []Component
```

**Parameters**:
- `Component`: Component type in group

**Returns**: Slice of components (first `group_size` elements)

**Complexity**: O(1)

#### crossProduct()

**Lines:** 534-537

Create cross-product iterator.

```zig
pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator
```

### Group Validation

**World.validateGroups()** ensures groups don't overlap:

```zig
const PhysicsGroup = struct { Position, Velocity, Mass };
const RenderGroup = struct { Position, Sprite }; // ERROR: Position overlaps!

// Validate at compile time:
World.validateGroups(.{ PhysicsGroup, RenderGroup }); // Compile error
```

### Characteristics

- **Fastest iteration**: No runtime filtering
- **Cache-friendly**: Entities organized at array start
- **Full-owning**: Components cannot overlap between groups
- **Setup required**: Must call `createGroup()` first
- **No modifiers**: Cannot use `?T` or `Exclude(T)`
- **Best for**: Hot-path multi-component iteration

## Filter Modifiers

**Lines:** 797-810

Modifiers customize component matching in Query and TagQuery.

### Optional (?T)

**Lines:** 804-810

Match entities regardless of component presence.

```zig
// In query definition:
Query(struct { Position, ?Color })

// Access:
const color = query.getOptional(entity, Color);
if (color) |c| {
    // Use custom color
} else {
    // Use default color
}
```

**Behavior**:
- Entity matches query whether it has component or not
- Access via `getOptional()` / `getOptionalMut()`
- Returns `?T` (nullable)

**Use case**: Optional customization, fallback behavior

### Exclude(T)

**Lines:** 797-802

Filter out entities that have the component.

```zig
// In query definition:
Query(struct { Enemy, Exclude(Player) })

// Iteration:
var it = query.iterator();
while (it.next()) |entity| {
    // Only entities with Enemy but NOT Player
}
```

**Behavior**:
- Entity must NOT have excluded component
- Cannot access excluded components
- Multiple excludes allowed

**Use case**: State filtering, exclusion logic

### Modifier Support

| Filter | Optional (?T) | Exclude(T) |
|--------|--------------|------------|
| `SingleQuery` | ❌ | ❌ |
| `SingleTag` | ❌ | ❌ |
| `Query` | ✅ | ✅ |
| `TagQuery` | ✅ | ✅ |
| `Group` | ❌ | ❌ |

## Iterator Utilities

### CrossProductIterator

**Lines:** 324-372

Cartesian product with filter application.

```zig
const CrossProductIterator = struct {
    left: *const LeftQuery,
    right: *const RightQuery,
    left_index: usize,
    right_index: usize,

    pub fn next(self: *CrossProductIterator) ?[2]Entity
};
```

**Behavior**: Nested loop, applies filters from both queries

**Use case**: Query × Query cross-products

### SimpleCrossProductIterator

**Lines:** 394-428

Cartesian product without filtering.

```zig
const SimpleCrossProductIterator = struct {
    left_entities: []const Entity,
    right_entities: []const Entity,
    left_index: usize,
    right_index: usize,

    pub fn next(self: *SimpleCrossProductIterator) ?[2]Entity
};
```

**Behavior**: Simple nested loop, assumes entities pre-filtered

**Use case**: SingleQuery/SingleTag/Group cross-products

## Performance Comparison

| Filter | Setup | Iteration | Filtering | Memory |
|--------|-------|-----------|-----------|--------|
| `SingleQuery` | None | O(n) | None | Minimal |
| `SingleTag` | None | O(m) | None | 1 bit/entity |
| `Query` | None | O(n) | Runtime | Minimal |
| `TagQuery` | None | O(m) | Runtime | 1 bit/entity |
| `Group` | O(n) | O(g) | None | Boundary marker |

Where:
- n = entities with smallest component
- m = entities with smallest tag
- g = entities in group

## Best Practices

1. **Use Group for hot paths**: Physics, rendering, frequently-run systems
2. **Use Query for flexibility**: Prototyping, rarely-run systems
3. **Leverage SingleQuery**: When only one component needed
4. **Validate groups early**: Use `World.validateGroups()` at startup
5. **Profile before optimizing**: Query might be fast enough
6. **Consider cache locality**: Group iteration is cache-friendly
7. **Use modifiers judiciously**: Optional/Exclude add runtime checks

## Integration with System Functions

Filters are automatically injected by World:

```zig
fn mySystem(
    positions: SingleQuery(Position),
    enemies: Query(struct { Health, Exclude(Dead) }),
    physics: Group(struct { Position, Velocity }),
) !void {
    // Filters ready to use
}

// Execute:
try world.runSystem(mySystem);
```

See [System Functions](../system/CLAUDE.md) for parameter injection details.
