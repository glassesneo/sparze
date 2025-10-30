# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sparze is an Entity Component System (ECS) library written in Zig. It provides compile-time ECS where all component types are known at compile time, offering zero runtime overhead and strong type safety.

## Build Commands

```bash
# Run all tests
zig build test

# Build all examples
zig build examples

# Run all examples sequentially
zig build run-examples

# Run a specific example
zig build run-{example-name}
```

## Architecture

### Core Data Structures

**Entity** (`src/core/entity.zig`):
- 32-bit identifier: 16 bits for index, 16 bits for version
- Version-based recycling prevents stale references
- `EntityRegistry` manages entity lifecycle with implicit free list

**SparseSet** (`src/core/sparse_set.zig`):
- Paginated sparse array (4096 entities per page) for O(1) entity→component lookup
- Packed dense arrays for cache-friendly iteration
- Group support: entities in groups are stored at the beginning of the packed array for fast iteration

**TagStorage** (`src/core/tag_storage.zig`):
- Specialized storage for tag components (zero-sized marker components)
- Uses DynamicBitSet for O(1) presence checking
- Packed entity array for efficient iteration
- No component data stored, only entity membership
- Automatically used for empty struct components via `ComponentStorage` type dispatch

### World API

**Component Registration** (`src/world.zig`):
- World parameterized by component tuple: `World(struct { Position, Velocity, Health }, struct {})`
- All component types known at compile time
- Component IDs assigned sequentially at compile time (0, 1, 2...)
- Direct sparse set access without dynamic lookup

**Resource Registration** (`src/world.zig`):
- World parameterized by component and resource tuples: `World(struct { Position, Velocity }, struct { DeltaTime, Score })`
- All resource types known at compile time
- Resources are global, singleton data accessible across systems
- Resource IDs assigned sequentially at compile time (0, 1, 2...)
- Resources are left undefined at initialization - must be set via `setResource()` before use

**Systems** (`src/system.zig`):
- System functions accept parameters that are automatically injected by the World:
  - Query filters: Types that filter entities based on component composition
    - `SingleQuery(Component)`: single regular component query filter
    - `SingleTag(Tag)`: single tag component query filter
      - `Query(struct { A, B, ?C, Exclude(D), ... })`: multi-component runtime intersection query filter (mixed tags and regular components, supports optional and exclude modifiers, no group setup required)
      - `TagQuery(struct { A, B, ?C, Exclude(D), ... })`: multi-tag runtime intersection query filter (tag components only, supports optional and exclude modifiers, no group setup required)
    - `Group(struct { A, B })`: optimized multi-component query filter with pre-allocated group (requires `createGroup()`)
  - `Resource(ResourceType)`: Global resource access for singleton data
  - `anytype` parameter: Receives `Commands(World)` for deferred entity/component operations
  - `std.mem.Allocator`: Receives the World's allocator for dynamic allocations within systems
- `world.runSystem(systemFn)`: convenience method for inline system execution
- `createSystemFunction(World, systemFn)`: returns typed function pointer

**Group Validation**:
- `World.validateGroups(.{ struct { A, B }, struct { C, D } })`: compile-time validation ensures no overlapping components between groups
- Recommended to validate all groups upfront for compile-time safety

## Common Patterns

### Standard World Pattern

```zig
const World = sparze.World(
    struct { Position, Velocity, Health }, // Components
    struct {},                              // Resources (empty if none)
    struct {}                               // Events (empty if none)
);

// Validate groups at compile time
World.validateGroups(.{
    struct { Position, Velocity },
    struct { Health, Armor },
});

var world = World.init(allocator);
try world.createGroup(struct { Position, Velocity });

// System with Group (optimized, requires createGroup)
fn movementSystem(movement: Group(struct { Position, Velocity })) !void {
    const positions = movement.getMutArrayOf(Position);
    const velocities = movement.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
    }
}

// System with Query (flexible, no group setup required)
fn combatSystem(query: Query(struct { Position, Health })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position).?;
            if (query.getComponentMut(entity, Health)) |health| {
                // Process entity
            }
        }
    }
}

// System with multiple query filters
fn mySystem(
    movement: Group(struct { Position, Velocity }),
    health: SingleQuery(Health),
) !void {
    // Use movement.getEntities(), movement.getMutArrayOf(Position), etc.
    // Use health.entities, health.components
}

// System with tag filters
fn playerSystem(query: SingleTag(Player)) !void {
    for (query.entities) |entity| {
        // Process all player entities
    }
}

fn bossEnemySystem(query: TagQuery(struct { Enemy, Boss })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Process entities that are both enemies and bosses
        }
    }
}

try world.runSystem(movementSystem);
try world.runSystem(combatSystem);
try world.runSystem(playerSystem);
try world.runSystem(bossEnemySystem);
```

### Resources

Resources are global, singleton data that can be accessed across systems. Unlike components which are attached to entities, resources exist independently and are shared by all systems.

```zig
// Define resource types
const DeltaTime = struct { dt: f32 };
const Score = struct { points: i32, combo: i32 };
const GameConfig = struct {
    gravity: f32,
    max_speed: f32,
};

const World = sparze.World(
    struct { Position, Velocity },  // Components
    struct { DeltaTime, Score, GameConfig }  // Resources
);

var world = World.init(allocator);

// Initialize resources using setResource()
try world.setResource(DeltaTime, .{ .dt = 0.016 });
try world.setResource(Score, .{ .points = 0, .combo = 0 });
try world.setResource(GameConfig, .{ .gravity = 9.8, .max_speed = 100.0 });

// Access resources in systems using Resource(T)
fn updatePhysics(
    delta: Resource(DeltaTime),
    config: Resource(GameConfig),
    movement: Group(struct { Position, Velocity }),
) !void {
    const dt = delta.value.dt;
    const gravity = config.value.gravity;
    
    const positions = movement.getMutArrayOf(Position);
    const velocities = movement.getMutArrayOf(Velocity);
    
    for (positions, velocities) |*pos, *vel| {
        vel.y -= gravity * dt;
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
        
        // Apply max speed limit
        const speed = @sqrt(vel.x * vel.x + vel.y * vel.y);
        if (speed > config.value.max_speed) {
            const scale = config.value.max_speed / speed;
            vel.x *= scale;
            vel.y *= scale;
        }
    }
}

// Mutate resources
fn scoreSystem(
    score: Resource(Score),
    enemies: SingleTag(DefeatedEnemy),
) !void {
    for (enemies.entities) |_| {
        score.value.points += 100;
        score.value.combo += 1;
    }
}

try world.runSystem(updatePhysics);
try world.runSystem(scoreSystem);

// Get resource value outside systems
const current_score = world.getResource(Score);
std.debug.print("Score: {d}\n", .{current_score.points});
```

**Resource Usage Patterns**:
- **Game state**: Score, level, game mode, player lives
- **Configuration**: Physics constants, game rules, difficulty settings
- **Time**: Delta time, total elapsed time, frame count
- **Input state**: Keyboard/mouse input, controller state
- **Render state**: Camera transform, viewport dimensions
- **Audio state**: Master volume, music/SFX settings

**Resource API**:
- `world.setResource(R, resource)`: Initialize or update a resource
- `world.getResource(R)`: Get resource by value (copy)
- `world.getResourcePtr(R)`: Get const pointer to resource
- `world.getResourcePtrMut(R)`: Get mutable pointer to resource
- `Resource(R)` system parameter: Injected as mutable pointer in systems

**Best Practices**:
- Initialize all resources with `setResource()` after creating the world
- Use resources for data that doesn't belong to any specific entity
- Keep resources focused and single-purpose (separate DeltaTime from GameConfig)
- Resources are always passed as mutable pointers to systems via `Resource(T).value`
- Prefer immutable resources (config) over mutable ones (state) where possible

### Events

Events provide frame-based communication between systems. Events sent in frame N are consumed in frame N+1, ensuring stable and predictable event handling with no mid-frame mutations.

```zig
// Define event types
const Collision = struct { entityA: Entity, entityB: Entity };
const Damage = struct { entity: Entity, amount: i32 };
const Death = struct { entity: Entity };

const World = sparze.World(
    struct { Position, Velocity, Health },  // Components
    struct {},  // Resources
    struct { Collision, Damage, Death },  // Events
);

var world = World.init(allocator);

// System that sends events
fn collisionDetection(
    positions: Query(struct { Position }),
    writer: EventWriter(Collision),
) !void {
    // Detect collisions between entities
    for (positions.entities) |entity_a| {
        for (positions.entities) |entity_b| {
            if (entity_a == entity_b) continue;
            // Collision logic...
            try writer.send(.{ .entityA = entity_a, .entityB = entity_b });
        }
    }
}

// System that reads events from previous frame
fn collisionResponse(
    reader: EventReader(Collision),
    writer: EventWriter(Damage),
) !void {
    for (reader.read()) |collision| {
        // Process collision and send damage events
        try writer.send(.{ .entity = collision.entityA, .amount = 10 });
        try writer.send(.{ .entity = collision.entityB, .amount = 10 });
    }
}

// Frame loop
world.beginFrame(); // Swap buffers: events from N-1 → readable, events from N → writable
try world.runSystem(collisionDetection);  // Writes to frame N
try world.runSystem(collisionResponse);   // Reads from frame N-1
try world.endFrame();  // Flush commands
```

**Event Lifecycle**:
1. **Frame N**: Systems write events to the write buffer using `EventWriter`
2. **`beginFrame()`**: Swap buffers - write buffer becomes read buffer, new write buffer is cleared
3. **Frame N+1**: Systems read events from read buffer using `EventReader`

**Event Storage**:
- All events use `ArrayList` for storage - dynamic and unbounded
- Events grow as needed with minimal overhead
- Memory scales automatically with actual usage

**Event System Parameters**:
- `EventReader(E)`: Read-only access to events from previous frame
  - API: `reader.read()` returns `[]const E`
- `EventWriter(E)`: Write-only access to send events to current frame
  - API: `try writer.send(event)`

**Event Usage Patterns**:
- **System communication**: Damage events, collision events, spawn requests
- **State changes**: Entity death, level completion, game over
- **Input handling**: Key press events, mouse click events
- **Gameplay**: Pickup collected, quest completed, achievement unlocked

**Best Practices**:
- Events are frame-delayed by design for stability (N → N+1)
- Use commands for immediate entity/component operations
- Keep event types focused and single-purpose
- Event data should be small and copyable
- Always use `beginFrame()` / `endFrame()` for proper event lifecycle management
- Events are cleared automatically each frame after swapping

**Example**: See `examples/events.zig` for a complete demonstration of the event system with collision detection, damage, and death handling.

### Tag Components

Tag components are zero-sized marker components used for entity categorization or state flags. They are defined as empty structs and automatically use `TagStorage` for optimized memory usage.

```zig
// Define tag components as empty structs
const Player = struct {};
const Enemy = struct {};
const Active = struct {};

const World = sparze.World(struct { Position, Player, Enemy, Active }, struct {}, struct {});

var world = World.init(allocator);

// Add/remove tags using dedicated methods
const entity = try world.createEntity();
try world.addTag(entity, Player);
try world.addTag(entity, Active);

// Check for tags
if (world.hasComponent(entity, Player)) {
    // Entity is a player
}

// Iterate over entities with a specific tag using SingleTag
fn playerSystem(query: SingleTag(Player)) !void {
    for (query.entities) |entity| {
        // Process all player entities
    }
}

// Query multiple tags using TagQuery
fn bossEnemySystem(query: TagQuery(struct { Enemy, Boss })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Process entities that are both enemies and bosses
        }
    }
}

// Combine tags with regular components using Query
fn activePlayerSystem(query: Query(struct { Position, Player, Active })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Process active players with position
        }
    }
}

// Remove tags
world.removeTag(entity, Active);
```

**Tag Component Usage**:
- **Marker components**: `Player`, `Enemy`, `NPC` - entity categorization
- **State flags**: `Active`, `Disabled`, `Selected` - entity state tracking
- **Group membership**: `UI`, `Renderable`, `Collidable` - system filtering
- **Events**: `Damaged`, `Died`, `LeveledUp` - single-frame event markers

**Performance**: Tags use bit sets for O(1) membership checking and consume only 1 bit per entity index, making them extremely memory-efficient compared to regular components.


### Component Modifiers

Component modifiers allow you to change how components behave in queries. Sparze supports two modifiers: **Optional** (`?T`) and **Exclude** (`Exclude(T)`).

#### Optional Modifier (`?T`)

The optional modifier (`?T`) allows queries to match entities regardless of whether they have the optional component. This is useful when you want to process entities with a base set of components and optionally handle additional components if present.

**Syntax**: `?ComponentType` or `?TagType`

```zig
// Query with optional components
fn combatSystem(query: Query(struct { Health, ?Shield })) !void {
    const damage = 15;
    
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const health = query.getComponentMut(entity, Health);
            var actual_damage = damage;
            
            // Shield absorbs some damage if present
            if (query.getOptionalMut(entity, Shield)) |shield| {
                const absorbed = @min(shield.value, actual_damage);
                shield.value -= absorbed;
                actual_damage -= absorbed;
            }
            
            health.hp -= actual_damage;
        }
    }
}

// TagQuery with optional tags
fn enemyAISystem(query: TagQuery(struct { Enemy, ?Boss, ?Elite })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Base enemy AI
            
            if (query.hasTag(entity, Boss)) {
                // Enhanced boss AI
            }
            
            if (query.hasTag(entity, Elite)) {
                // Elite enemy behavior
            }
        }
    }
}
```

**Optional Component API**:
- **Required components**: Use `getComponent()` / `getComponentMut()` - asserts component exists
- **Optional components**: Use `getOptional()` / `getOptionalMut()` - returns `?C` or `?*C`
- **Optional tags**: Use `hasTag(entity, Tag)` - returns `bool`

#### Exclude Modifier (`Exclude(T)`)

The exclude modifier filters out entities that have the specified component or tag. This is useful for implementing state-based filtering (e.g., excluding dead entities, frozen entities, or static objects).

**Syntax**: `Exclude(ComponentType)` or `Exclude(TagType)`

```zig
const Exclude = sparze.Exclude;

// Exclude dead enemies from combat
fn combatSystem(query: Query(struct { Enemy, Health, Exclude(Dead) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Only processes living enemies
            const health = query.getComponentMut(entity, Health);
            // Apply damage...
        }
    }
}

// Exclude static objects from movement
fn movementSystem(query: Query(struct { Position, Velocity, Exclude(Static) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponentMut(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            pos.x += vel.dx;
            pos.y += vel.dy;
        }
    }
}

// Multiple excludes - only active enemies (not dead, not frozen, not disabled)
fn activeEnemySystem(query: TagQuery(struct { Enemy, Exclude(Dead), Exclude(Frozen), Exclude(Disabled) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Process only active enemies
        }
    }
}
```

**Exclude Use Cases**:
- **State filtering**: `Exclude(Dead)`, `Exclude(Disabled)`, `Exclude(Paused)` - Skip entities in certain states
- **Object types**: `Exclude(Static)`, `Exclude(Invulnerable)` - Exclude specific object categories
- **Performance**: `Exclude(Heavy)` - Skip expensive operations for certain entities
- **Gameplay**: `Exclude(Friendly)`, `Exclude(Boss)` - Filter based on gameplay categories

#### Combining Modifiers

You can combine optional and exclude modifiers in a single query for powerful filtering:

```zig
// Process all living enemies, optionally applying boss-specific logic
fn enemyAISystem(query: Query(struct { Position, Enemy, ?Boss, Exclude(Dead), Exclude(Frozen) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            
            // Base AI for all living, unfrozen enemies
            // ...
            
            // Optional: Enhanced AI for bosses
            if (query.getOptional(entity, Boss)) |_| {
                // Boss-specific behavior
            }
        }
    }
}
```

**Modifier Rules**:
- **Optional (`?T`)**: Entity matches regardless of component presence; use `getOptional()` to safely access
- **Exclude (`Exclude(T)`)**: Entity matches only if it does NOT have the component
- **Filtering**: `filter()` checks required components and excludes, ignoring optional components
- **Combining**: Use multiple modifiers freely - e.g., `struct { A, ?B, Exclude(C), Exclude(D) }`

**Benefits**:
- **Optional**: 
  - Match entities with required components while optionally checking others
  - Explicit `?Component` syntax shows optional components at compile time
  - Avoid multiple separate queries when some components are optional
- **Exclude**:
  - Clean state-based filtering without manual checking
  - Combine multiple excludes for complex filtering logic
  - Works with both regular components and tags
- **Performance**: 
  - Query optimization only considers required (non-optional, non-excluded) components for iteration
  - Excludes are checked during filtering with O(1) component storage lookup
- **Type Safety**: 
  - Compile-time validation of all modifier usage
  - Clear intent through explicit modifier syntax

**Common Patterns**:
```zig
// All living entities with health
Query(struct { Health, Exclude(Dead) })

// Active players (not frozen or disabled)
Query(struct { Player, Exclude(Frozen), Exclude(Disabled) })

// Movable entities (not static)
Query(struct { Position, Velocity, Exclude(Static) })

// Damageable entities with optional shield
Query(struct { Health, ?Shield, Exclude(Dead), Exclude(Invulnerable) })

// Active enemies with optional boss enhancement
TagQuery(struct { Enemy, ?Boss, Exclude(Dead), Exclude(Frozen) })
```

## Query Filter Comparison

| Filter Type | Component Types | Modifiers | Setup Required | Performance | Use Case |
|-------------|----------------|-----------|----------------|-------------|----------|
| `SingleQuery(C)` | Regular | None | None | O(n) - Fast | Single component iteration |
| `SingleTag(T)` | Tag | None | None | O(n) - Fast | Single tag iteration |
| `Query(struct { A, B, ... })` | Mixed | `?T`, `Exclude(T)` | None | O(n) - Moderate | Ad-hoc multi-query with flexible filtering |
| `TagQuery(struct { A, B, ... })` | Tag only | `?T`, `Exclude(T)` | None | O(n) - Moderate | Ad-hoc multi-tag queries with filtering |
| `Group(struct { A, B })` | Regular | None | `createGroup()` required | O(n) - Fastest | Hot-path multi-component queries |

**When to use each**:
- **SingleQuery**: Iterating over entities with one regular component
- **SingleTag**: Iterating over entities with one tag component (explicit type safety)
- **Query**: Multi-component queries with flexible filtering via modifiers (can mix tags and regular components)
- **TagQuery**: Multi-tag queries with flexible filtering via modifiers (tag components only, explicit type safety)
- **Group**: Hot-path multi-component queries (e.g., movement, rendering) where performance is critical

**Key differences**:
- **SingleQuery** and **SingleTag**: Direct iteration over packed arrays (SingleQuery) or bit sets (SingleTag)
- **Query** and **TagQuery**: Perform runtime intersection, iterating smallest set and checking for others
- **Query** works with mixed tags and regular components with modifier support; **TagQuery** enforces tag-only at compile time with modifier support
- **Group** has pre-organized memory layout with entities stored at start of all component arrays
- **Group** requires upfront `createGroup()` call and validation, does not support modifiers; **Query** and **TagQuery** have no setup overhead and support modifiers

**Modifier Support**:
- **Optional (`?T`)**: Supported by `Query` and `TagQuery` - allows optional component/tag access
- **Exclude (`Exclude(T)`)**: Supported by `Query` and `TagQuery` - filters out entities with the component/tag
- **SingleQuery**, **SingleTag**, and **Group**: Do not support modifiers (use `Query`/`TagQuery` if modifiers are needed)

## Best Practices

### 1. Declare Group Type Constants

Always declare a constant for group types before using them. This improves readability, maintainability, and reduces duplication since group types appear in multiple places (validation, creation, and system parameters).

```zig
// Recommended: Declare group constants
const MovementGroup = struct { Position, Velocity };
const CombatGroup = struct { Health, Armor };

World.validateGroups(.{
    MovementGroup,
    CombatGroup,
});

try world.createGroup(MovementGroup);
try world.createGroup(CombatGroup);

fn movementSystem(group: Group(MovementGroup)) !void {
    // System implementation
}

fn combatSystem(group: Group(CombatGroup)) !void {
    // System implementation
}
```

**Why use constants?**
- Reduces duplication (group types appear 3+ times: validation, creation, system parameter)
- Improves readability with semantic names
- Simplifies refactoring (change in one place)
- Self-documenting code

### 2. Define Systems as Plain Functions

Systems should be defined as plain functions that accept query filter parameters. This pattern is simple, idiomatic, and works seamlessly with `world.runSystem()`.

```zig
// Recommended: Plain function
fn movementSystem(group: Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

// Usage
try world.runSystem(movementSystem);
```

Systems can accept multiple parameter types:

```zig
fn complexSystem(
    allocator: std.mem.Allocator,
    movement: Group(MovementGroup),
    health: SingleQuery(Health),
    combat: Query(struct { Position, Armor }),
) !void {
    // Use allocator for temporary data structures
    var list: std.ArrayList(Entity) = .{};
    defer list.deinit(allocator);

    // Use multiple query filters in one system
}
```

**System Parameter Types**:
- **Query filters**: `SingleQuery`, `SingleTag`, `Query`, `TagQuery`, `Group` - Filter entities by component composition
- **Resource**: `Resource(T)` - Access global singleton resources
- **Commands**: `anytype` parameter - Receives `Commands(World)` for deferred entity/component operations
- **Allocator**: `std.mem.Allocator` - Receives the World's allocator for dynamic allocations

All parameter types can be mixed in any order within a single system function.

## Performance Optimizations

### SparseSet Optimizations

**Bit-shift indexing** (`src/core/sparse_set.zig`):
- Page indexing uses `sparse_index >> 12` instead of division
- Slot indexing uses `sparse_index & 0xFFF` instead of modulo
- Applied to all hot paths: get, insert, remove, moveToGroup, moveFromGroup
- Results in ~20% faster component lookups

**Optimized remove**:
- Uses direct `swapRemove()` on both arrays to reduce memory copies
- Eliminates redundant component copy operation
- ~17% faster than previous implementation

**Reserve API**:
```zig
// Pre-allocate capacity to avoid reallocations during bulk inserts
try world.getSparseSetPtr(Position).reserve(expected_capacity);
```

### Command Buffer Optimizations

**Inline storage** (`src/system.zig`):
- Commands use inline array `[max_component_size]u8` instead of heap-allocated `[]u8`
- Eliminates `allocator.dupe()` call per command
- `max_component_size` computed at comptime per World
- Results in 77.8x faster command buffer operations (98.7% speedup)

### Internal Details

**World constants**:
- `World.max_component_size`: Computed at comptime, max @sizeOf() of all components
- Used by CommandBuffer for inline storage sizing

**Page configuration**:
- Page size: 4096 entities (2^12)
- Page shift constant: 12
- Page mask: 0xFFF

## Important Notes

- **Group ownership**: Groups use "full-owning" model where entities in the group are stored at the start of the packed array in all component sparse sets. This enables cache-friendly iteration but means groups cannot overlap (enforced at compile time).

- **Entity versioning**: Always use the entity handles returned by create/destroy operations. Stale entity handles will fail version checks.

- **Tag components**: Empty structs (`struct {}`) are automatically treated as tag components and use `TagStorage` instead of `SparseSet`. Use `world.addTag()` and `world.removeTag()` for tag-specific operations, or use the generic `world.addComponent()` / `world.removeComponent()` which dispatch correctly.

- **Memory management**:
  - Component pools are owned by World and deinitialized automatically
  - Command buffer uses inline storage (no per-command allocation)
  - Tag storage uses bit sets (1 bit per entity) for minimal memory overhead

- **Performance**:
  - Use `reserve()` for bulk insertions to eliminate reallocation overhead
  - Prefer `Group` over `Query` for hot-path multi-component iteration
  - Command buffers are highly optimized with inline storage
  - Use tag components for markers/flags to save memory (1 bit vs full component size)
  - Use `Exclude` modifier for state-based filtering instead of manual checks

  - **Component Modifiers**: 
    - Optional (`?T`) allows flexible queries that can handle varying component combinations
    - Exclude (`Exclude(T)`) provides clean state-based filtering (e.g., exclude dead/frozen entities)
    - Both modifiers work with `Query` and `TagQuery` but not with `SingleQuery`, `SingleTag`, or `Group`

  - **Examples**: The `examples/` directory contains implementations showing various patterns:
    - `basic.zig` - Entity and component basics
    - `resources.zig` - Global resources and state management
    - `system_operations.zig` - Basic system patterns and multi-query examples
    - `plugin_architecture.zig` - Plugin-style architecture
    - `performance_benchmark.zig` - Performance benchmarks
    - `tag_components.zig` - Tag component usage and patterns
    - `optional_components.zig` - Optional component modifier examples
    - `exclude_example.zig` - Exclude modifier usage and state-based filtering
