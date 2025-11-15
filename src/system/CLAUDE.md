# System Functions

**Location:** `src/system/system.zig`

System functions execute game logic via parameter injection. **Cannot directly accept `World` as parameter.**

## Parameter Injection

World analyzes function signature at compile time and injects:

1. **Query Filters**: `SingleQuery(T)`, `SingleTag(T)`, `Query(...)`, `TagQuery(...)`, `Group(...)`
2. **Resource(T)**: Global singleton
3. **EventWriter(E)** / **EventReader(E)**: Event communication
4. **Commands**: `anytype` parameter → receives `Commands(World)`
5. **Allocator**: `std.mem.Allocator`

```zig
fn movementSystem(
    movement: Group(struct { Position, Velocity }),
    delta: Resource(DeltaTime),
    commands: anytype,
) !void {
    for (movement.getEntities(),
         movement.getMutArrayOf(Position),
         movement.getArrayOf(Velocity)) |e, *pos, vel| {
        pos.x += vel.x * delta.value;
        if (pos.x < 0) try commands.destroyEntity(e);
    }
}

try world.runSystem(movementSystem);
```

## Commands API

Deferred operations safe during iteration.

### Key Characteristics

- **Deferred**: Component add/remove/destroy queued, executed at `endFrame()`
- **Immediate**: `createEntity()` and `createGroup()` execute immediately
- **InlineStorage**: Components ≤ 256 bytes stored inline

### Methods

```zig
// Entity (immediate)
createEntity() !Entity

// Entity with components (entity immediate, components deferred)
createEntityWith(components: anytype) !Entity

// Component operations (all deferred)
addComponent(entity, component) !void
removeComponent(entity, comptime T: type) !void
addTag(entity, comptime Tag: type) !void
removeTag(entity, comptime Tag: type) !void
destroyEntity(entity) !void

// Group & serialization (immediate)
createGroup(comptime GroupComponents: type) !void
serializeToFile(path: []const u8) !void
deserializeFromFile(path: []const u8) !void
```

## CommandBuffer

Internal queue for deferred operations. Components stored in `InlineStorage` ([256]u8).

**flush()** called by `world.endFrame()` to execute all queued commands.

## Frame Lifecycle

```zig
while (running) {
    world.beginFrame();  // Swap event buffers
    try world.runSystem(inputSystem);
    try world.runSystem(physicsSystem);
    try world.endFrame();  // Flush commands
}
```

## Immediate vs Deferred

| Operation | Timing | Reason |
|-----------|--------|--------|
| `createEntity()` | Immediate | Need ID for subsequent commands |
| `createGroup()` | Immediate | Group setup |
| Component ops | Deferred | Safe during iteration |
| `destroyEntity()` | Deferred | Safe during iteration |
| Serialization | Immediate | Direct world access |

## Critical Patterns

### 1. Use Commands during iteration

```zig
// Good
for (entities) |entity| {
    try commands.destroyEntity(entity);
}

// Bad - invalidates iterator
for (entities) |entity| {
    world.destroyEntity(entity); // DON'T
}
```

### 2. Multi-stage with events

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

## Integration

System functions use injected parameters, not direct World access.

See [Query Filters](../query/CLAUDE.md) and [World API](../../CLAUDE.md).
