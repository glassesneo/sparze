# System Functions

**Location:** `src/system/system.zig`

System functions execute game logic via parameter injection. **Cannot directly accept `World` as parameter.**

## Parameter Injection

World analyzes function signature at compile time and injects:

1. **Query Filters**: `SingleQuery(T)`, `SingleTag(T)`, `Query(...)`, `TagQuery(...)`, `Group(...)`
2. **Resource(T)**: Global singleton access
3. **EventWriter(E)** / **EventReader(E)**: Event communication
4. **Commands**: `anytype` parameter → receives `Commands(World)`
5. **Allocator**: `std.mem.Allocator`

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

    for (entities, positions, velocities) |e, *pos, vel| {
        pos.x += vel.x * delta.value;
        if (pos.x < 0) try commands.destroyEntity(e);
    }
}

try world.runSystem(movementSystem);
```

## Commands API

**Lines:** 571-689

Deferred operations safe during iteration.

### Structure

```zig
pub fn Commands(comptime WorldType: type) type {
    return struct {
        world: *WorldType,
        command_buffer: *CommandBuffer,
    };
}
```

### Key Characteristics

- **Deferred**: Component add/remove/destroy queued, executed at `endFrame()`
- **Immediate**: `createEntity()` and `createGroup()` execute immediately
- **InlineStorage**: Components ≤ 256 bytes stored inline (no heap per command)

### Methods

#### Entity Operations

```zig
pub fn createEntity() !Entity                           // Immediate
pub fn createEntityWith(components: anytype) !Entity    // Entity immediate, components deferred
pub fn destroyEntity(entity: Entity) !void              // Deferred
```

#### Component Operations (Deferred)

```zig
pub fn addComponent(entity: Entity, component: anytype) !void
pub fn removeComponent(entity: Entity, comptime T: type) !void
pub fn addTag(entity: Entity, comptime Tag: type) !void
pub fn removeTag(entity: Entity, comptime Tag: type) !void
```

#### Group & Serialization (Immediate)

```zig
pub fn createGroup(comptime GroupComponents: type) !void
pub fn serialize(writer: anytype) !void
pub fn deserialize(reader: anytype) !void
pub fn serializeToFile(path: []const u8) !void
pub fn deserializeFromFile(path: []const u8) !void
```

### Examples

```zig
// Spawn entity
const entity = commands.createEntity();
try commands.addComponent(entity, Position{ .x = 0, .y = 0 });
try commands.addComponent(entity, Velocity{ .x = 1, .y = 0 });

// Spawn with prefab
try commands.createEntityWith(.{
    .position = Position{ .x = 0, .y = 0 },
    .velocity = Velocity{ .x = 1, .y = 0 },
    .health = Health{ .value = 100 },
});

// Destroy
if (health.value <= 0) {
    try commands.destroyEntity(entity);
}
```

## CommandBuffer

**Lines:** 452-545

Internal queue for deferred operations.

### Structure

```zig
const CommandBuffer = struct {
    allocator: Allocator,
    commands: ArrayList(Command),
};

const Command = struct {
    command_type: CommandType,  // add_component, remove_component, destroy_entity
    entity: Entity,
    component_id: usize,
    component_data: InlineStorage,  // [256]u8
};
```

### Methods

```zig
pub fn recordAddComponent(entity, component_id, component) !void
pub fn recordRemoveComponent(entity, component_id) !void
pub fn recordDestroyEntity(entity) !void
pub fn flush(world) !void  // Execute all commands
```

**Called by**: `world.endFrame()`

## Frame Lifecycle

```zig
while (running) {
    world.beginFrame();              // Swap event buffers
    try world.runSystem(inputSystem);
    try world.runSystem(physicsSystem);
    try world.runSystem(renderSystem);
    try world.endFrame();            // Flush commands
}
```

### beginFrame()
Swaps event buffers (write ↔ read), clears new write buffer.

### endFrame()
Executes all queued commands in order.

## Immediate vs Deferred

| Operation | Timing | Reason |
|-----------|--------|--------|
| `createEntity()` | Immediate | Need ID for subsequent commands |
| `createGroup()` | Immediate | Group setup |
| `addComponent()` | Deferred | Safe during iteration |
| `removeComponent()` | Deferred | Safe during iteration |
| `destroyEntity()` | Deferred | Safe during iteration |
| Serialization | Immediate | Direct world access |

## Best Practices

### 1. Use Commands during iteration

```zig
// Good: Safe
for (entities) |entity| {
    try commands.destroyEntity(entity);
}

// Bad: Invalidates iterator
for (entities) |entity| {
    world.destroyEntity(entity); // DON'T
}
```

### 2. Batch component additions

```zig
const entity = commands.createEntity();
try commands.addComponent(entity, Position{});
try commands.addComponent(entity, Velocity{});
// All applied at endFrame()
```

### 3. Multi-stage systems with events

```zig
fn collisionDetection(
    query: Query(struct { Position, Collider }),
    writer: EventWriter(CollisionEvent),
) !void {
    var pairs = query.combinations();
    while (pairs.next()) |pair| {
        try writer.enqueue(CollisionEvent{ .a = pair[0], .b = pair[1] });
    }
}

fn collisionResponse(
    reader: EventReader(CollisionEvent),
    commands: anytype,
) !void {
    for (reader.queue) |event| {
        try commands.destroyEntity(event.a); // Next frame
    }
}
```

### 4. Conditional execution

```zig
fn updateSystem(state: Resource(GameState)) !void {
    if (state.paused) return;
    // Logic
}
```

## Error Handling

System functions can return errors:

```zig
fn riskySystem(commands: anytype) !void {
    return error.CustomError;
}

try world.runSystem(riskySystem); // Propagates
```

## createSystemFunction()

**Lines:** 763-825

Pre-compile system for repeated execution.

```zig
pub fn createSystemFunction(
    comptime WorldType: type,
    comptime systemFn: anytype,
) fn (*WorldType) anyerror!void

// Usage:
const movementFn = createSystemFunction(World, movementSystem);
try movementFn(&world);
```

## Integration

**Note**: System functions use injected parameters, not direct World access.

See [Query Filters](../query/CLAUDE.md) and [World API](../../CLAUDE.md).
