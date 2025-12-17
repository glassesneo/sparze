# System Function Patterns

Comprehensive guide to writing system functions, using Commands API, and organizing game logic in Sparze.

## System Function Basics

### Parameter Injection

System functions use **compile-time parameter injection** - World analyzes the function signature and provides the required parameters automatically.

**Supported parameter types**:
1. **Query Filters**: `SingleQuery(T)`, `SingleTag(T)`, `Query(...)`, `TagQuery(...)`, `Group(...)`
2. **Resource(T)** / **ResourceMut(T)**: Global singleton access
3. **EventWriter(E)** / **EventReader(E)**: Event communication
4. **Commands**: `anytype` parameter → receives `Commands(World)`
5. **Allocator**: `std.mem.Allocator`

**IMPORTANT**: System functions CANNOT directly accept `World` as parameter.

### Return Type

System functions support two return types:

```zig
fn systemVoid(...) void { }        // No errors
fn systemTry(...) !void { }        // Can propagate errors
```

`World.runSystem` will automatically `try` when the system function returns an error union.

### Full Example

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const DeltaTime = struct { value: f32 };
const CollisionEvent = struct { a: Entity, b: Entity };

fn movementSystem(
    // Query filter
    movement: Group(struct { Position, Velocity }),
    // Resource access
    delta: Resource(DeltaTime),
    // Event writer
    events: EventWriter(CollisionEvent),
    // Commands for entity operations
    commands: anytype,
) !void {
    const entities = movement.getEntities();
    const positions = movement.getMutArrayOf(Position);
    const velocities = movement.getArrayOf(Velocity);

    for (entities, positions, velocities) |entity, *pos, vel| {
        // Update position
        pos.x += vel.x * delta.value.value;
        pos.y += vel.y * delta.value.value;

        // Boundary check
        if (pos.x < 0 or pos.x > 800) {
            try events.enqueue(CollisionEvent{ .a = entity, .b = 0 });
            try commands.destroyEntity(entity);
        }
    }
}

// Execute system
try world.runSystem(movementSystem);
```

## Commands API Reference

Commands provide deferred and immediate operations for safe entity/component manipulation.

### Entity Operations

#### createEntity() Entity - Immediate

Creates an entity and returns its ID immediately.

```zig
fn spawnSystem(commands: anytype) !void {
    const player = commands.createEntity();
    try commands.addComponent(player, Position{ .x = 0, .y = 0 });
    try commands.addComponent(player, Health{ .hp = 100 });
}
```

**Timing**: Immediate (need ID for subsequent commands)

**Use case**: When you need the entity ID to reference it later in the same frame

#### createEntityWith(components) Entity - Hybrid

Creates entity immediately, defers component additions.

```zig
fn spawnWithComponents(commands: anytype) !void {
    const enemy = commands.createEntityWith(.{
        Position{ .x = 100, .y = 100 },
        Health{ .hp = 50 },
        Enemy{},
    });
    // entity ID available immediately
    // components added at endFrame()
}
```

**Timing**: Entity immediate, components deferred

**Use case**: Convenient entity creation when you don't need components immediately

#### destroyEntity(entity) !void - Deferred

Queues entity for destruction at frame end.

```zig
fn cleanupSystem(
    query: Query(struct { Health }),
    commands: anytype
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponent(entity, Health);
        if (health.hp <= 0) {
            try commands.destroyEntity(entity);
        }
    }
}
```

**Timing**: Deferred (executed at endFrame)

**Safety**: Entity liveness validated during flush (idempotent, zombie-safe)

### Component Operations (All Deferred)

#### addComponent(entity, component) !void

```zig
fn powerupSystem(
    query: Query(struct { Position }),
    commands: anytype
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        try commands.addComponent(entity, Shield{ .duration = 5.0 });
    }
}
```

**Safety**: Skipped if entity not alive during flush

#### removeComponent(entity, T) !void

```zig
fn shieldDecaySystem(
    query: Query(struct { Shield }),
    commands: anytype
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const shield = query.getComponentMut(entity, Shield);
        shield.duration -= 0.016;
        if (shield.duration <= 0) {
            try commands.removeComponent(entity, Shield);
        }
    }
}
```

**Safety**: Skipped if entity not alive during flush

#### addTag(entity, Tag) !void / removeTag(entity, Tag) !void

```zig
fn stateSystem(
    query: Query(struct { Health }),
    commands: anytype
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponent(entity, Health);
        if (health.hp < 20) {
            try commands.addTag(entity, LowHealth);
        } else {
            try commands.removeTag(entity, LowHealth);
        }
    }
}
```

**Timing**: Deferred

### Resource Operations (All Immediate)

#### setResource(T, value) void

```zig
fn initializeSystem(commands: anytype) !void {
    commands.setResource(DeltaTime, .{ .value = 0.016 });
    commands.setResource(Score, .{ .points = 0 });
}
```

**Timing**: Immediate

#### initResources(resources) !void - Bulk Initialization

```zig
fn startupSystem(commands: anytype) !void {
    try commands.initResources(.{
        .delta_time = DeltaTime{ .value = 0.016 },
        .score = Score{ .points = 0 },
        .config = GameConfig{ .gravity = 9.8 },
    });
}
```

**Timing**: Immediate

**Best practice**: Use this at startup to initialize all resources

#### getResource(T) / getResourcePtr(T) / getResourcePtrMut(T)

```zig
fn scoreSystem(commands: anytype) !void {
    const score_ptr = commands.getResourcePtrMut(Score);
    score_ptr.points += 100;

    // Or value copy
    const config = commands.getResource(GameConfig);
}
```

**Timing**: Immediate

**Safety**:
- Debug/ReleaseSafe: Panic if uninitialized
- ReleaseFast: Undefined memory (zeroes)

#### tryGetResource(T) / tryGetResourceMut(T) - Safe Access

```zig
fn optionalConfigSystem(commands: anytype) !void {
    if (commands.tryGetResource(OptionalConfig)) |config| {
        // Use config
    } else |_| {
        // Config not initialized, use defaults
    }
}
```

**Timing**: Immediate

**Returns**: Error if resource not initialized

#### isResourceInitialized(T) bool

```zig
fn conditionalSystem(commands: anytype) !void {
    if (commands.isResourceInitialized(GameState)) {
        const state = commands.getResource(GameState);
        // Safe to use
    }
}
```

**Timing**: Immediate

### Group Operations (Immediate)

Groups are defined at compile-time in the `World` signature. Declare required groups in the `.groups` parameter and validate with `World.validateGroups()` if needed.

### Serialization Operations (Immediate)

#### serializeToFile(path) !void / deserializeFromFile(path) !void

```zig
const World = sparze.World(
.{ Position, Velocity },
.{ DeltaTime },
.{},
    .{ struct { Position, Velocity } }, // Groups
);

fn saveSystem(commands: anytype) !void {
    try commands.serializeToFile("save.dat");
}

fn loadSystem(commands: anytype) !void {
    try commands.deserializeFromFile("save.dat");
}
```

**Timing**: Immediate

**Important**: Groups are defined at compile-time in the `World` signature; ensure save/load use the same signature across builds

## Frame Lifecycle

### Complete Frame Flow

```
┌─────────────────────────────────────────────────────┐
│                 Game Loop Iteration                  │
└─────────────────────────────────────────────────────┘
         │
         ├─> world.beginFrame()
         │     │
         │     ├─ Swap event buffers (write ↔ read)
         │     └─ Clear write buffer
         │
         ├─> world.runSystem(inputSystem)
         │     │
         │     ├─ Read EventReader (previous frame's events)
         │     ├─ Write EventWriter (current frame's events)
         │     ├─ Query entities
         │     └─ Queue Commands to buffer
         │
         ├─> world.runSystem(physicsSystem)
         │     │
         │     ├─ Read EventReader
         │     ├─ Write EventWriter
         │     └─ Queue Commands
         │
         ├─> world.runSystem(renderSystem)
         │     │
         │     └─ Read-only queries (no Commands)
         │
         └─> world.endFrame()
               │
               └─ CommandBuffer.flush()
                   │
                   ├─ For each queued command:
                   │   ├─ Validate entity liveness
                   │   ├─ Execute if valid
                   │   └─ Skip if entity destroyed
                   │
                   └─ Clear command buffer
```

### Typical Game Loop

```zig
const World = sparze.World(
.{ Position, Velocity },
.{ DeltaTime },
.{},
    .{ struct { Position, Velocity }, .{ Sprite, Layer } },  // Groups
);

pub fn main() !void {
    var world = try World.init(allocator);
    defer world.deinit();

    // Setup
    try world.setResource(DeltaTime, .{ .value = 0.016 });

    // Game loop
    while (gameRunning) {
        world.beginFrame();

        try world.runSystem(inputSystem);
        try world.runSystem(aiSystem);
        try world.runSystem(physicsSystem);
        try world.runSystem(collisionSystem);
        try world.runSystem(renderSystem);

        try world.endFrame();
    }
}
```

## Critical Patterns

### Pattern 1: Safe Iteration with Commands

**GOOD**: Use Commands during iteration

```zig
fn cleanupSystem(
    query: Query(struct { Health }),
    commands: anytype
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponent(entity, Health);
        if (health.hp <= 0) {
            try commands.destroyEntity(entity);  // Deferred
        }
    }
}
```

**BAD**: Direct world mutation during iteration

```zig
fn brokenSystem(
    query: Query(struct { Health }),
    // DON'T DO THIS - can't access World directly
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        world.destroyEntity(entity);  // ILLEGAL - invalidates iterator!
    }
}
```

### Pattern 2: Multi-Stage Event Processing

**Frame N**: Detection

```zig
fn collisionDetection(
    query: Query(struct { Position, Collider }),
    writer: EventWriter(CollisionEvent),
) !void {
    var pairs = query.combinations();
    while (pairs.next()) |[a, b]| {
        if (checkCollision(a, b)) {
            try writer.enqueue(CollisionEvent{ .a = a, .b = b });
        }
    }
}
```

**Frame N+1**: Response

```zig
fn collisionResponse(
    reader: EventReader(CollisionEvent),
    commands: anytype,
) !void {
    for (reader.queue) |event| {
        try commands.destroyEntity(event.a);
        try commands.destroyEntity(event.b);
    }
}
```

**Why frame delay?**: Prevents circular dependencies and ensures clean execution order.

### Pattern 3: Resource Initialization and Access

**Startup**: Bulk initialization

```zig
fn startupSystem(commands: anytype) !void {
    try commands.initResources(.{
        .delta_time = DeltaTime{ .value = 0.016 },
        .game_state = GameState{ .score = 0 },
        .config = Config{ .difficulty = .normal },
    });
}
```

**Runtime**: Mixed access

```zig
fn gameLogicSystem(
    delta: Resource(DeltaTime),      // Read-only via parameter
    state: ResourceMut(GameState),   // Mutable via parameter
    commands: anytype,
) !void {
    const dt = delta.value.value;
    state.value.score += 10;

    // Can also access via Commands
    if (commands.isResourceInitialized(PowerUpState)) {
        const powerup = commands.getResource(PowerUpState);
        state.value.score += powerup.multiplier * 10;
    }
}
```

**Options for resource access**:
1. **Resource(T) parameter** - Read-only, preferred for clarity
2. **ResourceMut(T) parameter** - Mutable, preferred for clarity
3. **Commands methods** - Useful for conditional access or initialization

### Pattern 4: Entity Creation with Components

**Option 1**: Immediate entity, deferred components

```zig
fn spawnEnemies(commands: anytype) !void {
    for (0..10) |i| {
        const enemy = commands.createEntity();
        try commands.addComponent(enemy, Position{ .x = @floatFromInt(i * 50), .y = 0 });
        try commands.addComponent(enemy, Health{ .hp = 50 });
        try commands.addTag(enemy, Enemy);
    }
}
```

**Option 2**: Hybrid (createEntityWith)

```zig
fn spawnEnemies(commands: anytype) !void {
    for (0..10) |i| {
        _ = commands.createEntityWith(.{
            Position{ .x = @floatFromInt(i * 50), .y = 0 },
            Health{ .hp = 50 },
            Enemy{},
        });
    }
}
```

**Choose createEntityWith when**: You don't need the entity ID immediately.

### Pattern 5: Conditional Component Operations

```zig
fn upgradeSystem(
    query: Query(struct { Level, ?Weapon }),
    commands: anytype,
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const level = query.getComponent(entity, Level);

        if (level.value >= 5) {
            // Check if already has weapon
            if (query.getOptional(entity, Weapon) == null) {
                try commands.addComponent(entity, Weapon{ .damage = 10 });
            }
        }
    }
}
```

### Pattern 6: State Machine with Tags

```zig
const Idle = struct {};
const Walking = struct {};
const Attacking = struct {};

fn stateTransitionSystem(
    query: Query(struct { Velocity }),
    commands: anytype,
) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const vel = query.getComponent(entity, Velocity);

        // Transition based on velocity
        if (vel.x == 0 and vel.y == 0) {
            try commands.removeTag(entity, Walking);
            try commands.removeTag(entity, Attacking);
            try commands.addTag(entity, Idle);
        } else {
            try commands.removeTag(entity, Idle);
            try commands.addTag(entity, Walking);
        }
    }
}
```

## CommandBuffer Internals

### Structure

```zig
const CommandBuffer = struct {
    commands: ArrayList(Command),
    allocator: Allocator,

    const Command = union(enum) {
        add_component: AddComponentCmd,
        remove_component: RemoveComponentCmd,
        destroy_entity: Entity,
        // ... other commands
    };

    const AddComponentCmd = struct {
        entity: Entity,
        component_type_index: usize,
        component_data: InlineStorage,  // [World.max_component_size]u8 buffer
    };
};
```

### InlineStorage

Components ≤ World.max_component_size stored inline in command buffer:

```zig
const InlineStorage = [World.max_component_size]u8;
```

**Component serialization**:
```zig
var storage: InlineStorage = undefined;
@memcpy(storage[0..@sizeOf(T)], std.mem.asBytes(&component));
```

**Component deserialization**:
```zig
const component = @as(*const T, @ptrCast(@alignCast(&storage))).*;
```

**Limitation**: Components > World.max_component_size are rejected in `recordAddComponent`. The max size is determined at compile-time based on the largest component type in the world.

### Safety Guarantees

During `flush()`, each command validates entity liveness:

```zig
fn flush(self: *CommandBuffer, world: *World) !void {
    for (self.commands.items) |cmd| {
        switch (cmd) {
            .add_component => |ac| {
                // Validate entity still alive
                if (!world.entity_registry.isAlive(ac.entity)) {
                    continue;  // Skip - entity destroyed
                }
                // Execute command...
            },
            .remove_component => |rc| {
                if (!world.entity_registry.isAlive(rc.entity)) {
                    continue;  // Skip - entity destroyed
                }
                // Execute command...
            },
            .destroy_entity => |entity| {
                // Idempotent - check before destroying
                if (world.entity_registry.isAlive(entity)) {
                    world.entity_registry.destroy(entity);
                    // Clean up components...
                }
            },
        }
    }
    self.commands.clearRetainingCapacity();
}
```

**Prevents**:
- Zombie entities (destroyed entity receiving components)
- Double-destroy
- Component resurrection

## Common Pitfalls

1. **Accessing uninitialized resources**:
   ```zig
   // BAD: Might panic if not initialized
   const config = commands.getResource(Config);

   // GOOD: Check first
   if (commands.isResourceInitialized(Config)) {
       const config = commands.getResource(Config);
   }
   ```

2. **Forgetting to declare groups in the World signature**:
   ```zig
   // BAD: Will panic if group missing from signature
   const WorldWithoutGroups = sparze.World(
       .{ A, B },
       .{},
       .{},
       .{}, // No groups defined
   );

   // GOOD: Declare groups at compile-time in the World signature
   const World = sparze.World(
       .{ A, B },
       .{},
       .{},
       .{ struct { A, B } },
   );
   ```

3. **Using wrong resource access method**:
   ```zig
   // BAD: Copying large resource
   fn system(config: Resource(LargeConfig)) !void {
       // config.value is a copy
   }

   // GOOD: Use pointer for large resources
   fn system(commands: anytype) !void {
       const config = commands.getResourcePtr(LargeConfig);
   }
   ```

See also:
- docs/QUERY_PATTERNS.md for iteration patterns
- docs/ENTITY_LIFECYCLE.md for entity management
- docs/ARCHITECTURE.md for system architecture
