# CLAUDE.md

A comprehensive guide for working with the Sparze codebase (Zig ECS library).

## Build commands

```bash
# Run tests
zig build test

# Run tests with wasm target
zig build test-wasm

# Build all examples
zig build examples

# Run all examples sequentially
zig build run-examples

# Run a specific example
zig build run-{example-name}

# Run a build with wasm target
zig build {command-name} -Dtarget=wasm32-wasi
```

## What Sparze is

A compile-time Entity Component System (ECS) in Zig where component, resource, and event types are known at compile time. This provides:

- **Zero runtime lookup overhead**: All type information resolved at compile time
- **Strong type safety**: Compile-time validation of component access and group definitions
- **High performance**: Cache-friendly data layouts with pagination and group-based iteration
- **Minimal API surface**: Simple, composable primitives for building complex systems

## Core concepts

### Entity system

**Location:** `src/core/entity.zig`

- **Entity**: 32-bit identifier (`u32`) composed of:
  - Lower 16 bits: entity index (up to 65,535 entities)
  - Upper 16 bits: version number for recycling
- **EntityRegistry**: Manages entity lifecycle with version-based recycling
  - `create()`: O(1) entity creation with automatic recycling
  - `destroy()`: O(1) entity destruction, adds to free list
  - `isAlive()`: O(1) version-based entity validation
  - `aliveCount()`: Returns count of living entities

### Component storage

**Location:** `src/core/component_storage.zig`

Sparze automatically selects storage based on component type:

- **Regular components** (structs with fields): Use `SparseSet` storage
- **Tag components** (empty structs): Use `TagStorage` (optimized bitset)

#### SparseSet

**Location:** `src/core/sparse_set.zig`

- Paginated sparse array (4096 entities per page, 16 pages max)
- Packed dense arrays for entities and components
- O(1) insert, remove, lookup, and contains operations
- Group-aware layout: group entities placed at array start for cache-friendly iteration
- **Key methods**:
  - `reserve(capacity)`: Pre-allocate capacity to avoid reallocation
  - `reservePages(count)`: Pre-allocate sparse pages
  - `insert()`, `remove()`, `get()`, `contains()`
  - `moveToGroup()`, `moveFromGroup()`: Group management
  - `getGroupEntities()`, `getGroupComponents()`: Direct group array access

#### TagStorage

**Location:** `src/core/tag_storage.zig`

- DynamicBitSet for presence checking (1 bit per entity)
- Packed entity array for iteration
- Reverse index for O(1) removal
- Optimized for zero-sized marker/state components
- **Key methods**: `set()`, `unset()`, `contains()`

### World structure

**Location:** `src/world.zig`

The World is parameterized by three tuples:

```zig
World(
    Components: struct { Position, Velocity, Health, ... },
    Resources: struct { DeltaTime, GameState, ... },
    Events: struct { Collision, SpawnEvent, ... }
)
```

**Key characteristics**:
- Component/resource/event IDs assigned at compile time
- Direct storage access without runtime lookup
- Manages entity registry, component pools, resource pool, event pool, groups, and command buffer
- **Note**: `World` cannot be used directly in system functions; use injected parameters instead

**Essential methods**:
- `init(allocator)`, `deinit()`: Lifecycle
- `createEntity()`, `destroyEntity()`: Entity management
- `addComponent()`, `addTag()`, `removeComponent()`, `removeTag()`: Component operations
- `setResource()`, `getResource()`, `getResourcePtr()`, `getResourcePtrMut()`: Resource access
- `createGroup()`: Group creation
- `validateGroups(...)`: Compile-time group overlap validation
- `beginFrame()`, `endFrame()`: Frame lifecycle
- `runSystem(systemFn)`: Execute system function with parameter injection

## System functions

**Location:** `src/system.zig`

System functions are registered and executed by the World via `world.runSystem(systemFn)`. They receive parameters through automatic injection and cannot directly accept `World` as a parameter.

### Accepted parameter types

System functions can accept any combination of:

1. **Query Filters**: For iterating entities and components
   - `SingleQuery(T)`: Single component iteration
   - `SingleTag(T)`: Single tag iteration
   - `Query(struct { ... })`: Multi-component intersection with filter modifiers
   - `TagQuery(struct { ... })`: Multi-tag intersection with filter modifiers
   - `Group(struct { ... })`: Pre-organized multi-component iteration (fastest)

2. **Resource access**: `Resource(T)` for global singleton access

3. **Event access**:
   - `EventWriter(E)`: Write events to current frame
   - `EventReader(E)`: Read events from previous frame

4. **Commands**: `anytype` parameter receives `Commands(World)` for deferred operations

5. **Allocator**: `std.mem.Allocator` for temporary allocations

### Example system function

```zig
fn movementSystem(
    allocator: std.mem.Allocator,
    movement: Group(struct { Position, Velocity }),
    delta: Resource(DeltaTime),
    commands: anytype,
) !void {
    const entities = movement.getEntities();
    const positions = movement.getMutArrayOf(Position);
    const velocities = movement.getArrayOf(Velocity);

    for (entities, positions, velocities) |entity, *pos, vel| {
        pos.x += vel.x * delta.value;
        pos.y += vel.y * delta.value;
    }
}
```

Execute with: `try world.runSystem(movementSystem);`

**Convenience helper**: `createSystemFunction(World, systemFn)` converts a system function to an executable form.

## Query Filters

**Location:** `src/filter.zig`

Query Filters allow system functions to iterate entities with specific components or tags. All filters are injected as parameters into system functions.

### SingleQuery(T)

Iterates entities with a single regular component.

```zig
fn healthSystem(health: SingleQuery(Health)) !void {
    for (health.entities, health.components) |entity, h| {
        // Process entity with health component
    }
}
```

**Characteristics**:
- Direct access to packed entity and component arrays
- No runtime filtering overhead
- Supports `crossProduct(&other)` for pair iteration

### SingleTag(T)

Iterates entities with a single tag component.

```zig
fn enemySystem(enemies: SingleTag(Enemy)) !void {
    for (enemies.entities) |entity| {
        // Process entity with Enemy tag
    }
}
```

**Characteristics**:
- Bitset-backed storage (1 bit per entity)
- Packed entity array for iteration
- Supports `crossProduct(&other)` for pair iteration

### Query(struct { ... })

Runtime multi-component intersection with support for filter modifiers.

```zig
fn damageSystem(
    query: Query(struct { Health, ?Armor, Exclude(Invincible) })
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponentMut(entity, Health);
        const armor = query.getOptional(entity, Armor);

        // Apply damage considering optional armor
    }
}
```

**Characteristics**:
- No setup required; performs intersection at query time
- Iterates smallest component set for efficiency
- Supports filter modifiers: optional (`?T`) and exclude (`Exclude(T)`)
- **Methods**:
  - `iterator()`: Returns filtered iterator
  - `getComponent(entity, T)`, `getComponentMut(entity, T)`: Access required components
  - `getOptional(entity, T)`, `getOptionalMut(entity, T)`: Access optional components
  - `combinations()`: Returns unique pairs iterator (i < j)
  - `crossProduct(&other)`: Returns Cartesian product iterator (N×M pairs)

### TagQuery(struct { ... })

Runtime multi-tag intersection with filter modifiers (tag-specific variant of Query).

```zig
fn stateSystem(
    tags: TagQuery(struct { Active, ?Sleeping, Exclude(Dead) })
) !void {
    var it = tags.iterator();
    while (it.next()) |entity| {
        const is_sleeping = tags.hasTag(entity, Sleeping);
        // Process based on tag state
    }
}
```

**Characteristics**:
- Similar to Query but for tag components only
- Validates all fields are tag components at compile time
- Supports filter modifiers
- **Methods**: `iterator()`, `hasTag(entity, Tag)`, `crossProduct(&other)`

### Group(struct { ... })

Pre-organized multi-component iteration (fastest option for multi-component queries).

```zig
fn physicsSystem(physics: Group(struct { Position, Velocity, Mass })) !void {
    const entities = physics.getEntities();
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);
    const masses = physics.getArrayOf(Mass);

    for (entities, positions, velocities, masses) |e, *pos, vel, mass| {
        // Direct array iteration - cache friendly and fast
    }
}
```

**Characteristics**:
- **Requires creation**: Use `world.createGroup(struct { ... })` before use
- **Fastest iteration**: Entities with all group components organized at array start
- **Full-owning model**: Components cannot overlap between groups
- **Compile-time validation**: Use `World.validateGroups(...)` to detect overlap
- **Methods**:
  - `getEntities()`: Get group entity array
  - `getArrayOf(T)`, `getMutArrayOf(T)`: Direct component array access
  - `crossProduct(&other)`: Cartesian product iterator

**Group validation example**:

```zig
const MovementGroup = struct { Position, Velocity };
const RenderGroup = struct { Position, Sprite }; // ERROR: Position overlaps!

// Validate at compile time:
World.validateGroups(.{ MovementGroup, RenderGroup }); // Compile error
```

## Filter Modifiers

**Location:** `src/filter.zig`

Filter modifiers customize how Query and TagQuery match entities. They are **only supported by Query and TagQuery**, not by SingleQuery, SingleTag, or Group.

### Optional (?T)

Match entities regardless of component presence.

```zig
fn renderSystem(query: Query(struct { Position, ?Color })) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const pos = query.getComponent(entity, Position);
        const color = query.getOptional(entity, Color); // May be null

        if (color) |c| {
            // Render with custom color
        } else {
            // Render with default color
        }
    }
}
```

### Exclude(T)

Filter out entities that have the specified component or tag.

```zig
fn aiSystem(query: Query(struct { Enemy, Exclude(Player) })) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        // Process only Enemy entities that are NOT players
    }
}
```

## Commands API

**Location:** `src/system.zig`

Commands provide deferred entity/component operations that are safe to execute during iteration. System functions receive Commands via an `anytype` parameter.

```zig
fn spawnSystem(spawners: SingleQuery(Spawner), commands: anytype) !void {
    for (spawners.entities, spawners.components) |entity, spawner| {
        const new_entity = commands.createEntity(); // Immediate
        try commands.addComponent(new_entity, Position{ .x = 0, .y = 0 }); // Deferred
        try commands.addComponent(new_entity, Velocity{ .x = 1, .y = 0 }); // Deferred
    }
}
```

**Key characteristics**:
- **Deferred operations**: Component additions/removals queued and executed at `world.endFrame()`
- **Immediate entity creation**: `createEntity()` returns entity immediately
- **Safe during iteration**: Can be used inside filter iteration without invalidation
- **InlineStorage**: Component data stored inline (no heap allocation per command)

**Methods**:
- `createEntity()`: Create entity (immediate), returns Entity
- `createEntityWith(struct { ... })`: Create entity with components (deferred)
- `destroyEntity(entity)`: Destroy entity (deferred)
- `addComponent(entity, component)`: Add component (deferred)
- `addTag(entity, Tag)`: Add tag (deferred)
- `removeComponent(entity, Component)`: Remove component (deferred)
- `removeTag(entity, Tag)`: Remove tag (deferred)
- `createGroup(struct { ... })`: Create group (immediate)
- `serialize(writer)`, `deserialize(reader)`: Serialization
- `serializeToFile(path)`, `deserializeFromFile(path)`: File I/O

**Execution**: All deferred commands execute when `world.endFrame()` is called.

## Resources

**Location:** `src/world.zig` (lines 313-331)

Resources are global singleton values accessible across system functions via `Resource(T)` parameter injection.

**Characteristics**:
- Must be initialized via `world.setResource(T, value)` before use
- Accessed in system functions via `Resource(T)` parameter
- Single instance per type
- Stored in resource pool tuple

**World methods**:
- `world.setResource(T, value)`: Initialize or update resource
- `world.getResource(T)`: Get resource value copy
- `world.getResourcePtr(T)`: Get immutable resource pointer
- `world.getResourcePtrMut(T)`: Get mutable resource pointer

**System function usage**:

```zig
fn updateSystem(
    delta: Resource(DeltaTime),
    state: Resource(GameState)
) !void {
    // Access resource values
    const dt = delta.value;
}
```

**Best practices**:
- Initialize resources after creating World
- Prefer single-purpose resources over large monolithic state
- Use meaningful type names for clarity

## Events

**Location:** `src/core/event_storage.zig`, `src/filter.zig`

Events provide frame-delayed communication between system functions via double-buffered storage.

**Event lifecycle**:
- Events written in frame N (via `EventWriter`) are readable in frame N+1 (via `EventReader`)
- Buffers swap at `world.beginFrame()`, previous write buffer becomes read buffer
- Write buffer cleared each frame

**Frame execution pattern**:

```zig
while (running) {
    world.beginFrame(); // Swap event buffers
    try world.runSystem(inputSystem); // May write events
    try world.runSystem(physicsSystem); // Reads events from previous frame
    try world.endFrame(); // Execute deferred commands
}
```

**System function usage**:

```zig
// Writing events
fn collisionDetectionSystem(
    writer: EventWriter(CollisionEvent)
) !void {
    // Detect collision
    try writer.enqueue(CollisionEvent{ .a = e1, .b = e2 });
}

// Reading events
fn collisionResponseSystem(
    reader: EventReader(CollisionEvent),
    commands: anytype
) !void {
    for (reader.queue) |event| {
        // Respond to collision from previous frame
        try commands.destroyEntity(event.a);
    }
}
```

**Important notes**:
- Events are frame-delayed by design (prevents ordering issues)
- Only the read buffer is serialized; write buffer is not saved
- Event order within a frame is preserved

## Iterator types

**Location:** `src/filter.zig`

### combinations()

Returns unique pairs within a single query filter (condition: i < j).

```zig
fn collisionSystem(
    entities: Query(struct { Position, Collider })
) !void {
    var pairs = entities.combinations();
    while (pairs.next()) |pair| {
        const pos1 = entities.getComponent(pair[0], Position);
        const pos2 = entities.getComponent(pair[1], Position);
        // Check collision between pair[0] and pair[1]
    }
}
```

**Characteristics**:
- O(n²) iteration where n = matching entities
- No duplicate pairs (i < j enforced)
- Single filter application per entity
- Useful for collision detection, pairwise interactions

### crossProduct(&other)

Returns Cartesian product between two query filters (N×M pairs).

```zig
fn projectileCollisionSystem(
    projectiles: Query(struct { Position, Projectile }),
    enemies: Query(struct { Position, Enemy })
) !void {
    var pairs = projectiles.crossProduct(&enemies);
    while (pairs.next()) |pair| {
        const proj_pos = projectiles.getComponent(pair[0], Position);
        const enemy_pos = enemies.getComponent(pair[1], Position);
        // Check collision between projectile and enemy
    }
}
```

**Characteristics**:
- O(N×M) iteration
- Applies filters from both queries
- Useful for asymmetric pair interactions (projectile-enemy, trigger-sensor, etc.)

## Serialization

**Location:** `src/serialization/`

High-performance binary serialization/deserialization for complete world state with type safety and integrity checking.

### What is serialized

- **Entities**: Entity registry state (indices, versions, free list)
- **Components**: All component storage (SparseSet and TagStorage)
- **Resources**: All resource values
- **Events**: Read buffer only (previous frame's events)

### What is NOT serialized

- **Groups**: Must be recreated after deserialization with `createGroup()`
- **Command buffers**: Commands are meant to be ephemeral
- **Event write buffer**: Current frame's events not yet available
- **Types marked with** `pub const serialized = false`

### Type support

**POD types** (Plain Old Data): Automatically serialized
- Primitives: integers, floats, booleans
- Structs composed of POD types
- Fixed-size arrays of POD types

**Non-POD types**: Require custom `Serializer`

```zig
pub const CustomComponent = struct {
    data: []u8,

    pub const Serializer = struct {
        pub fn serialize(
            component: CustomComponent,
            writer: anytype
        ) !void {
            // Custom serialization logic
        }

        pub fn deserialize(
            reader: anytype,
            allocator: std.mem.Allocator
        ) !CustomComponent {
            // Custom deserialization logic
        }
    };
};
```

### Exclusion feature

Mark types with `pub const serialized = false` to exclude from serialization:

```zig
pub const TemporaryComponent = struct {
    pub const serialized = false; // Not saved
    value: f32,
};
```

### Safety features

- **Type metadata hash**: Ensures serialized data matches current type definitions
- **CRC32 checksum**: Detects data corruption
- **Format version**: Forward compatibility support

### Usage

**Via Commands** (recommended):

```zig
// Save
try commands.serializeToFile("save.dat");

// Load
try commands.deserializeFromFile("save.dat");
```

**Via World**:

```zig
// Save
const file = try std.fs.cwd().createFile("save.dat", .{});
defer file.close();
try world.serialize(file.writer());

// Load
const file = try std.fs.cwd().openFile("save.dat", .{});
defer file.close();
try world.deserialize(file.reader());

// Recreate groups after load
try world.createGroup(struct { Position, Velocity });
```

**Best practices**:
- Serialize between frames (after `endFrame()`)
- Recreate all groups after deserialization
- Handle serialization errors (type mismatch, corruption)
- See `examples/serialization.zig` and `examples/serialization_exclusion.zig`

## Performance notes

### Memory optimization

1. **Use tag components for markers/state flags**
   - 1 bit per entity vs full component storage
   - Zero memory overhead for zero-sized structs

2. **Pre-allocate with reserve()**
   - Call `reserve()` on sparse sets before bulk inserts
   - Reduces reallocation overhead

3. **Pagination benefits**
   - 4096 entities per page reduces memory for sparse entity distributions
   - Pages allocated on-demand

### Iteration optimization

1. **Prefer Group for hot-path multi-component iteration**
   - Entities organized at array start
   - Cache-friendly memory access
   - No runtime filtering overhead

2. **Query optimizations**
   - Automatically iterates smallest component set
   - Optional/Exclude modifiers skipped during size calculation
   - Reduces iteration work

3. **Direct array access**
   - Use `getArrayOf()` / `getMutArrayOf()` with Group
   - Enables SIMD-friendly iteration patterns

### System organization

1. **Declare group type constants**

```zig
const PhysicsGroup = struct { Position, Velocity, Mass };
const RenderGroup = struct { Position, Sprite };

// Validate at compile time
World.validateGroups(.{ PhysicsGroup, RenderGroup });
```

2. **Define system functions as plain functions**
   - Accept injected parameters only
   - Do not pass World directly
   - Use `anytype` for Commands

3. **Avoid group overlap**
   - Use `validateGroups()` to catch overlap at compile time
   - Prevents duplicate definitions and ensures correctness

## Examples

**Location:** `examples/`

Comprehensive usage examples and performance benchmarks:

- `basic.zig`: Entity spawning, component operations, basic queries
- `movement_example.zig`: Group creation, validation, frame loop
- `events.zig`: Event writers/readers, multi-frame event pipeline
- `resources.zig`: Multiple resources, resource access, Exclude modifier
- `tag_components.zig`: Tag definition, SingleTag, TagQuery, optional tags
- `multiple_groups.zig`: Compile-time group validation, non-overlapping groups
- `combination_iterator.zig`: Unique pairs iteration, collision detection
- `cross_product.zig`: Cartesian product iteration, projectile-enemy collisions
- `serialization.zig`: POD/custom serializers, world save/load
- `serialization_exclusion.zig`: Excluding types from serialization
- `benchmarks/`: Performance testing and optimization validation

## Architecture summary

### Core data structures

| Structure | Location | Purpose |
|-----------|----------|---------|
| Entity | `src/core/entity.zig` | 32-bit ID with version recycling |
| EntityRegistry | `src/core/entity.zig` | Entity lifecycle management |
| SparseSet | `src/core/sparse_set.zig` | Regular component storage |
| TagStorage | `src/core/tag_storage.zig` | Tag component storage (bitset) |
| EventStorage | `src/core/event_storage.zig` | Double-buffered event queue |
| ComponentStorage | `src/core/component_storage.zig` | Storage type selection |

### Main API

| Component | Location | Purpose |
|-----------|----------|---------|
| World | `src/world.zig` | Central ECS coordinator |
| System functions | `src/system.zig` | System execution & parameter injection |
| Commands | `src/system.zig` | Deferred entity/component operations |
| Query Filters | `src/filter.zig` | Entity iteration with component matching |
| Serialization | `src/serialization/` | Binary save/load with type safety |

### Design principles

1. **Compile-time type resolution**: Zero runtime lookup overhead
2. **Strong type safety**: Compile errors for invalid operations
3. **Cache-friendly layouts**: Packed arrays, group organization
4. **Minimal API surface**: Composable primitives over complex abstractions
5. **Explicit over implicit**: Clear semantics, no hidden costs

## Notes for contributors

- Read source files in `src/` for implementation details
- Keep changes focused and consistent with Zig idioms
- Add tests in `src/tests/` for new features
- Update examples when adding public API
- Run `zig build test` before committing
- Follow existing code style and naming conventions
