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

// Resource operations (all immediate)
setResource(comptime R: type, resource: R) !void
getResource(comptime R: type) R
getResourcePtr(comptime R: type) *const R
getResourcePtrMut(comptime R: type) *R
tryGetResource(comptime R: type) !*const R
tryGetResourceMut(comptime R: type) !*R
initResources(resources: anytype) !void
isResourceInitialized(comptime R: type) bool

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
| Resource ops | Immediate | Global state, immediate access needed |
| Component ops | Deferred | Safe during iteration |
| `destroyEntity()` | Deferred | Safe during iteration |
| Serialization | Immediate | Direct world access |

## Critical Patterns

### 1. Resource access through Commands

Resources can be accessed either through Commands or system parameter injection:

```zig
// Option 1: Via Resource parameter (preferred for read-only)
fn updateSystem(delta: Resource(DeltaTime), commands: anytype) !void {
    const dt = delta.value.dt;
    // Use dt...
}

// Option 2: Via Commands (useful for initialization or conditional access)
fn initSystem(commands: anytype) !void {
    try commands.initResources(.{
        .delta_time = DeltaTime{ .dt = 0.016 },
        .score = Score{ .points = 0 },
    });
}

// Option 3: Mixed - Resource parameter + Commands mutation
fn scoreSystem(score: ResourceMut(Score), commands: anytype) !void {
    score.value.points += 100;  // Via parameter

    // Can also access via Commands
    if (commands.isResourceInitialized(GameConfig)) {
        const config = commands.getResource(GameConfig);
        // Use config...
    }
}
```

**Safety**: Commands resource methods have same safety features as World:
- Debug assertions fire on uninitialized access
- `tryGetResource*()` variants return errors
- `initResources()` for bulk initialization

### 2. Use Commands during iteration

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

### 3. Multi-stage with events

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
