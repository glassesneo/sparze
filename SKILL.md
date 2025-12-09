---
name: sparze
description: Expert guidance for building Entity Component System (ECS) applications with Sparze, a Zig ECS library. Use when working with Sparze ECS code for (1) Writing system functions with query filters, (2) Organizing systems with single responsibility and proper execution order, (3) Designing component architectures and groups, (4) Using query modifiers (Optional, Exclude, Free), (5) Managing resources and events, (6) Understanding performance trade-offs between Query/Group/SingleQuery, (7) Implementing event-driven system chains, (8) Implementing deferred commands pattern, or (9) Any other Sparze ECS development tasks.
---

# Sparze ECS Skill

Expert guidance for building high-performance Entity Component System applications with Sparze.

## Core Concepts

**World**: ECS coordinator declared with component, resource, and event types known at compile time.

```zig
const World = sparze.World(
    struct { Position, Velocity, Health },  // Components
    struct { DeltaTime, Score },            // Resources
    struct { CollisionEvent }               // Events
);
```

**Entity**: 32-bit ID with generation versioning for safe entity references.

**Components**: Data attached to entities. Tag components (empty structs) use 1 bit per entity.

**Resources**: Global singletons accessed via `Resource(T)` or `ResourceMut(T)` injection.

**Events**: Frame-delayed communication. Events written in frame N are readable in frame N+1 via double-buffering. **Why delayed?** Ensures deterministic execution order and prevents systems from reacting to events mid-frame, which would create unpredictable system dependencies.

## System Functions

System functions receive injected parameters and **must use `commands: anytype` instead of accessing World directly**.

```zig
fn mySystem(
    allocator: std.mem.Allocator,           // World's allocator
    movement: Group(struct { Position, Velocity }),
    health: SingleQuery(Health),
    delta: Resource(DeltaTime),             // Read-only resource
    score: ResourceMut(Score),              // Mutable resource
    reader: EventReader(CollisionEvent),    // Read events from previous frame
    writer: EventWriter(DamageEvent),       // Write events to current frame
    commands: anytype,                      // Commands for deferred operations
) !void {
    // Implementation
}
```

### Commands API

Commands enable **deferred entity/component operations** that execute at frame end:

```zig
// Create entities
const entity = commands.createEntity();
const entity2 = try commands.createEntityWith(.{
    Position{ .x = 10, .y = 20 },
    Velocity{ .x = 1, .y = 0 },
});

// Deferred component operations (execute at world.endFrame())
try commands.addComponent(entity, Position, .{ .x = 0, .y = 0 });
try commands.removeComponent(entity, Velocity);
try commands.addTag(entity, Dead);
try commands.removeTag(entity, Enemy);
try commands.destroyEntity(entity);

// Immediate resource operations
commands.setResource(DeltaTime, .{ .dt = 0.016 });
const dt = commands.getResource(DeltaTime);
const score_ptr = commands.getResourcePtrMut(Score);
```

**Why Commands?** Prevents mid-iteration structural changes that could invalidate iterators and corrupt memory. Adding/removing components during query iteration would shift array indices, causing systems to skip entities or process the same entity twice.

## Query Filters

**Decision guide**:
- **SingleQuery**: Single component, any frequency → Simplest, fast
- **Query**: Multiple components, occasional use → No setup, flexible
- **Group**: Multiple components, every frame → Setup required, fastest

Choose based on **access frequency** and **component count**:

### SingleQuery(Component)

**Fastest** single-component iteration. Direct array access.

```zig
fn healthSystem(query: SingleQuery(Health)) !void {
    for (query.entities, query.components) |entity, *health| {
        health.hp = @max(0, health.hp);
    }
}
```

### Query(struct { ... })

Runtime intersection for multi-component queries. No setup required. Iterates smallest component set and filters.

```zig
fn combatSystem(query: Query(struct { Position, Health, ?Shield })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            const health = query.getComponentMut(entity, Health);
            const shield = query.getOptional(entity, Shield);
            // Process entity
        }
    }
}
```

**Iterator API**:
```zig
var it = query.iterator();
while (it.next()) |entity| {
    const pos = query.getComponent(entity, Position);
}
```

### Group(struct { ... })

**Fastest** multi-component iteration. Requires `world.createGroup()` setup. Entities organized at array start for cache-friendly access.

**Why fastest?** CPU cache loads 64 bytes per memory access. Sequential array access keeps data in cache, while Query's scattered lookups cause cache misses (100x+ slower than cache hits). Critical for hot-path systems processing 1000s of entities per frame.

```zig
// Setup (once, typically at startup)
const MovementGroup = struct { Position, Velocity };
try world.createGroup(MovementGroup);

// System
fn movementSystem(group: Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}
```

**Partial-owning groups**: Use `Free(Component)` for components owned by other groups:

```zig
// Group 1 owns Position, uses Health as free
try world.createGroup(struct { Position, Free(Health) });
// Group 2 can own Health
try world.createGroup(struct { Health, Shield });
```

Access free components via `group.getComponent(entity, T)` instead of array access.

**Why Free()?** Prevents component ownership conflicts. Only one group can own a component (organize it at array start). Other groups needing that component must declare it Free to access via lookup. Trade-off: fast owned access + slower free lookup vs. Query overhead.

### SingleTag(Tag) / TagQuery(struct { ... })

Tag-specific query filters. Same patterns as Query but for zero-sized components.

```zig
fn enemySystem(query: TagQuery(struct { Enemy, ?Boss, Exclude(Dead) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            if (query.hasTag(entity, Boss)) {
                // Special boss logic
            }
        }
    }
}
```

## Query Modifiers

### Optional Components (?T)

Match entities **regardless** of component presence:

```zig
fn renderSystem(query: Query(struct { Position, ?Sprite })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            if (query.getOptional(entity, Sprite)) |sprite| {
                // Render with sprite
            } else {
                // Render placeholder
            }
        }
    }
}
```

### Exclude(Component)

Filter out entities **with** the specified component:

```zig
// Process living enemies only
fn aiSystem(query: Query(struct { Enemy, Position, Exclude(Dead) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Process only living enemies
        }
    }
}

// Multiple excludes
fn system(query: Query(struct {
    Position,
    Velocity,
    Exclude(Static),
    Exclude(Frozen)
})) !void { }
```

### Free(Component)

For partial-owning groups - marks component as not owned (accessed via indirection).

## System Organization

Dividing game logic into well-organized systems is crucial for maintainable, performant ECS architecture.

### Single Responsibility Principle

Each system should handle **one specific task** and operate only on relevant components:

```zig
// GOOD: Focused systems
fn applyGravity(query: Query(struct { Velocity, Exclude(Grounded) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const vel = query.getComponentMut(entity, Velocity);
            vel.y += 9.8;
        }
    }
}

fn applyMovement(group: Group(struct { Position, Velocity })) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

// BAD: System doing too much
fn physicsSystem(...) !void {
    // Applies gravity, movement, collision, friction - too many responsibilities!
}
```

**Benefits**: Reusable across projects, easier to debug, simpler to test, better parallel processing.

### System Execution Order

Order matters when systems have dependencies. Execute in logical sequence:

```zig
// Frame structure with clear dependencies
world.beginFrame();

// 1. Input - Gather user input
try world.runSystem(inputSystem);

// 2. AI - Process AI decisions
try world.runSystem(aiSystem);

// 3. Physics - Update positions
try world.runSystem(applyGravity);
try world.runSystem(applyMovement);
try world.runSystem(collisionDetection);

// 4. Game Logic - Handle game rules
try world.runSystem(healthSystem);
try world.runSystem(scoreSystem);

// 5. Rendering - Prepare visuals
try world.runSystem(animationSystem);
try world.runSystem(cameraSystem);
try world.runSystem(renderSystem);

try world.endFrame();  // Flush commands, swap event buffers
```

**Rule**: Systems that **write** data must run before systems that **read** that data.

### Event-Driven System Chains

Use events to create **loosely coupled** system chains with clear data flow:

```zig
// Chain: Detection → Response → Application → Cleanup

// System 1: Detect collisions, write events
fn collisionDetection(
    query: Query(struct { Position, Collider }),
    writer: EventWriter(CollisionEvent),
) !void {
    // Detect collisions
    try writer.enqueue(.{ .a = entity1, .b = entity2 });
}

// System 2: Read collision events, write damage events
fn collisionResponse(
    reader: EventReader(CollisionEvent),
    writer: EventWriter(DamageEvent),
) !void {
    for (reader.queue) |collision| {
        try writer.enqueue(.{ .entity = collision.a, .amount = 10 });
    }
}

// System 3: Read damage events, apply to health
fn damageSystem(
    reader: EventReader(DamageEvent),
    health_query: Query(struct { Health }),
    writer: EventWriter(DeathEvent),
) !void {
    for (reader.queue) |damage| {
        if (health_query.getOptionalMut(damage.entity, Health)) |health| {
            health.hp -= damage.amount;
            if (health.hp <= 0) {
                try writer.enqueue(.{ .entity = damage.entity });
            }
        }
    }
}

// System 4: Cleanup destroyed entities
fn deathSystem(
    reader: EventReader(DeathEvent),
    commands: anytype,
) !void {
    for (reader.queue) |death| {
        try commands.destroyEntity(death.entity);
    }
}
```

**Execution across frames**:
- Frame N: `collisionDetection` writes events
- Frame N+1: `collisionResponse` reads collisions, writes damage
- Frame N+2: `damageSystem` reads damage, writes deaths
- Frame N+3: `deathSystem` reads deaths, destroys entities

**Benefits**: No tight coupling, each system independently testable, clear causality.

### Domain-Based Organization

Group related systems by domain for better code organization:

```zig
// Physics domain
fn physicsUpdate(world: *World) !void {
    try world.runSystem(applyGravity);
    try world.runSystem(applyVelocity);
    try world.runSystem(collisionDetection);
    try world.runSystem(collisionResolution);
}

// Combat domain
fn combatUpdate(world: *World) !void {
    try world.runSystem(weaponCooldown);
    try world.runSystem(damageApplication);
    try world.runSystem(healthRegeneration);
}

// Rendering domain
fn renderUpdate(world: *World) !void {
    try world.runSystem(updateAnimations);
    try world.runSystem(updateCamera);
    try world.runSystem(renderSprites);
}

// Main loop
while (running) {
    world.beginFrame();
    try physicsUpdate(&world);
    try combatUpdate(&world);
    try renderUpdate(&world);
    try world.endFrame();
}
```

**Plugin Architecture**: Organize components and systems by feature:

```zig
const MovementPlugin = struct {
    const Components = .{ Position, Velocity };

    fn install(world: *World) !void {
        try world.createGroup(struct { Position, Velocity });
    }

    fn update(world: *World) !void {
        try world.runSystem(movementSystem);
    }
};
```

### Behavioral Chains with Components

Split complex behaviors into sequential systems operating on different components:

```zig
// Behavior: Character follows mouse cursor

// System 1: Capture mouse input
fn inputSystem(
    query: SingleQuery(InputComponent),
    // Mouse input from external system
) !void {
    for (query.entities, query.components) |_, *input| {
        input.mouse_x = getMouseX();
        input.mouse_y = getMouseY();
    }
}

// System 2: Calculate direction to cursor
fn followCursorSystem(
    query: Query(struct { InputComponent, Position, Direction }),
) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const input = query.getComponent(entity, InputComponent);
            const pos = query.getComponent(entity, Position);
            const dir = query.getComponentMut(entity, Direction);

            const dx = input.mouse_x - pos.x;
            const dy = input.mouse_y - pos.y;
            const magnitude = @sqrt(dx * dx + dy * dy);

            dir.x = dx / magnitude;
            dir.y = dy / magnitude;
        }
    }
}

// System 3: Apply movement
fn movementSystem(group: Group(struct { Position, Direction, Speed })) !void {
    const positions = group.getMutArrayOf(Position);
    const directions = group.getArrayOf(Direction);
    const speeds = group.getArrayOf(Speed);

    for (positions, directions, speeds) |*pos, dir, speed| {
        pos.x += dir.x * speed.value;
        pos.y += dir.y * speed.value;
    }
}
```

**Benefits**: Each system reusable independently. `movementSystem` works for AI, player input, pathfinding, etc.

### System Granularity Guidelines

**Too granular** (avoid):
```zig
fn updatePositionX(...) !void { }  // Only updates X
fn updatePositionY(...) !void { }  // Only updates Y
```

**Too coarse** (avoid):
```zig
fn gameplaySystem(...) !void {
    // Does movement, combat, inventory, dialogue, etc.
}
```

**Just right**:
```zig
fn movementSystem(...) !void { }       // Updates position from velocity
fn combatSystem(...) !void { }         // Handles damage application
fn inventorySystem(...) !void { }      // Manages item pickup/use
```

**Rule of thumb**: If a system's name needs "and" or has 3+ responsibilities, split it.

### Parallel Processing Considerations

Design systems for potential parallelization:

**Safe for parallel** (read-only or disjoint writes):
```zig
// Multiple systems can run in parallel if they access different components
fn system1(query: Query(struct { Position, Velocity })) !void { }
fn system2(query: Query(struct { Health, Armor })) !void { }  // Parallel-safe
```

**Not safe** (concurrent writes to same component):
```zig
fn system1(query: Query(struct { Position })) !void {
    // Writes Position
}
fn system2(query: Query(struct { Position })) !void {
    // Also writes Position - CONFLICT
}
```

**Sparze is currently single-threaded**, but designing independent systems prepares for future parallelization.

### Common Anti-Patterns

**❌ Systems storing state**:
```zig
// BAD: System with state
fn badSystem(query: ...) !void {
    const accumulator = ...;  // State between frames
}

// GOOD: Use Resources for state
fn goodSystem(query: ..., state: ResourceMut(SystemState)) !void {
    state.value.accumulator += ...;
}
```

**❌ Systems knowing about entity "types"**:
```zig
// BAD: Checking entity types
if (isPlayer(entity)) { }

// GOOD: Use components/tags
fn playerSystem(query: Query(struct { Player, Position })) !void {
    // Only processes entities with Player component
}
```

**❌ Direct component access between systems**:
```zig
// BAD: System A calling System B
fn systemA(...) !void {
    systemB(...);  // Tight coupling
}

// GOOD: Use events or shared components
fn systemA(..., writer: EventWriter(SomeEvent)) !void {
    try writer.enqueue(...);
}
fn systemB(..., reader: EventReader(SomeEvent)) !void {
    for (reader.queue) |event| { }
}
```

## Advanced Patterns

### Cross Product Iteration

Iterate all pairs between two queries (N×M complexity):

```zig
fn collisionSystem(
    projectiles: Query(struct { Projectile, Transform }),
    enemies: Query(struct { Enemy, Transform }),
) !void {
    var cross = projectiles.crossProduct(&enemies);
    while (cross.next()) |pair| {
        const proj_entity, const enemy_entity = pair;
        // Check collision between entities
    }
}
```

### Combination Iteration

Iterate unique pairs within a single query:

```zig
fn entityInteractionSystem(query: Query(struct { Position, Collider })) !void {
    var combos = query.combinations();
    while (combos.next()) |pair| {
        const entity1, const entity2 = pair;
        // Process unique pair
    }
}
```

### Resource Initialization

**CRITICAL**: Resources must be initialized before use. Uninitialized access:
- Debug/ReleaseSafe: Assertion failure
- ReleaseFast: Undefined behavior (zeroes)

**Why strict?** Compile-time resource pool pre-allocates memory at fixed offsets. Uninitialized slots contain garbage. Unlike components (entity-driven, tracked), resources are globally accessible without entity association, making uninitialized access impossible to detect at compile time.

```zig
// Bulk initialization (recommended for startup)
try world.initResources(.{
    .delta_time = DeltaTime{ .dt = 0.016 },
    .score = Score{ .points = 0 },
});

// Safe checked access (returns error if uninitialized)
const dt = try world.tryGetResource(DeltaTime);

// Unsafe direct access (zero-cost, assumes initialized)
const dt = world.getResource(DeltaTime);
```

## Performance Guidelines

### Memory

- Tag components use 1 bit per entity
- Pre-allocate with `sparse_set.reserve(capacity)`
- Pagination: 4096 entities per page

### Iteration Speed

**Fastest to slowest** (performance impact):
1. **Group owned components** (`getMutArrayOf`) - 100% cache hits, vectorizable
2. **SingleQuery** - Direct array, some cache misses from entity gaps
3. **Group free components** (`getComponent`) - Lookup overhead per entity
4. **Query** - Filter overhead + scattered memory access

**Why it matters**: Cache miss = ~200 cycles. Cache hit = ~4 cycles. For 10,000 entities, Group vs Query can be 10-50x faster.

### Best Practices

- Use **Group** for hot-path queries (every frame, performance-critical)
- Use **Query** for ad-hoc or dynamic queries
- Use **SingleQuery** for single-component iterations
- Validate groups at compile time:

```zig
const MovementGroup = struct { Position, Velocity };
const RenderGroup = struct { Position, Sprite };

World.validateGroups(.{ MovementGroup, RenderGroup });  // Compile-time check
```

- Create groups early (startup) to organize entity layout

## Common Patterns

### Startup System

```zig
fn initSystem(commands: anytype) !void {
    // Initialize resources
    try commands.initResources(.{
        .delta_time = DeltaTime{ .dt = 0.016 },
        .score = Score{ .points = 0 },
    });

    // Create groups
    try commands.createGroup(struct { Position, Velocity });

    // Spawn initial entities
    const player = try commands.createEntityWith(.{
        Position{ .x = 0, .y = 0 },
        Health{ .hp = 100 },
    });
    _ = player;
}
```

### Conditional Entity Processing

```zig
fn damageSystem(
    query: Query(struct { Health, Exclude(Invincible) }),
    commands: anytype,
) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const health = query.getComponentMut(entity, Health);
            health.hp -= 10;
            if (health.hp <= 0) {
                try commands.addTag(entity, Dead);
            }
        }
    }
}
```

## Architecture Patterns

### Component Design

```zig
// POD components (auto-serializable)
const Position = struct { x: f32, y: f32 };

// Tag components (zero-sized markers)
const Enemy = struct {};
const Dead = struct {};

// Components with custom serialization
const CustomComponent = struct {
    data: []u8,
    pub const Serializer = struct {
        pub fn serialize(component: CustomComponent, writer: anytype) !void { }
        pub fn deserialize(reader: anytype, allocator: Allocator) !CustomComponent { }
    };
};

// Exclude from serialization
const TransientData = struct {
    cache: []u8,
    pub const serialized = false;
};
```

## Serialization

Serialize world state to files:

```zig
// Save
try commands.serializeToFile("save.dat");

// Load
try commands.deserializeFromFile("save.dat");

// Recreate groups after deserialization
try world.createGroup(struct { Position, Velocity });
```

**What's serialized**: Entities, components, resources, events (read buffer only)
**Not serialized**: Groups, command buffers, event write buffer, types with `serialized = false`

## Comparison to Other ECS

**vs Bevy (Rust)**:
- Sparze: Compile-time types, `?T` optional, `Exclude(T)`
- Bevy: `With<T>`, `Without<T>`, `Added<T>`, `Changed<T>`, query builder

**vs Flecs (C/C++)**:
- Sparze: Sparse set + groups (hybrid)
- Flecs: Pure archetype with query terms, component inheritance

**vs EnTT (C++)**:
- Sparze: Explicit group setup for performance
- EnTT: Pure sparse set with reactive views

## Quick Reference

| Task | API |
|------|-----|
| Create entity | `commands.createEntity()` |
| Add component | `try commands.addComponent(e, T, value)` |
| Query single | `SingleQuery(Health)` |
| Query multi | `Query(struct { Position, Velocity })` |
| Fastest iteration | `Group(struct { Position, Velocity })` |
| Optional component | `Query(struct { Position, ?Sprite })` |
| Exclude entities | `Query(struct { Enemy, Exclude(Dead) })` |
| Read resource | `Resource(DeltaTime)` |
| Write resource | `ResourceMut(Score)` |
| Read events | `EventReader(CollisionEvent)` |
| Write events | `EventWriter(DamageEvent)` |
| Tag iteration | `SingleTag(Enemy)` |
| Cross product | `query1.crossProduct(&query2)` |
| Unique pairs | `query.combinations()` |
