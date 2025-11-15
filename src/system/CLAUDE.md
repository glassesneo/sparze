# System Functions

**Location:** `src/system/system.zig`

System functions are the primary way to execute game logic in Sparze. They receive parameters through automatic injection and are executed by World.

## Overview

System functions are plain Zig functions that:
- Accept injected parameters (Query Filters, Resources, Events, Commands, Allocator)
- **Cannot directly accept `World` as a parameter**
- Are executed via `world.runSystem(systemFn)`
- Can be converted to executable form via `createSystemFunction(World, systemFn)`

## Parameter Injection

**Lines:** 774-820

World analyzes system function parameters at compile time and injects appropriate values.

### Accepted Parameter Types

1. **Query Filters**: For iterating entities and components
   - `SingleQuery(T)`: Single component iteration
   - `SingleTag(T)`: Single tag iteration
   - `Query(struct { ... })`: Multi-component intersection with filter modifiers
   - `TagQuery(struct { ... })`: Multi-tag intersection with filter modifiers
   - `Group(struct { ... })`: Pre-organized multi-component iteration

2. **Resource(T)**: Global singleton access

3. **Event access**:
   - `EventWriter(E)`: Write events to current frame
   - `EventReader(E)`: Read events from previous frame

4. **Commands**: `anytype` parameter receives `Commands(World)` for deferred operations

5. **Allocator**: `std.mem.Allocator` for temporary allocations

### Parameter Resolution Process

**Lines:** 774-820

```zig
// For each parameter in system function:
1. Check if type is std.mem.Allocator → inject world.allocator
2. Check if parameter name is "commands" → inject Commands instance
3. Detect filter type via FilterType.detect()
4. Initialize filter:
   - SingleQuery → from SparseSet
   - Query → from World with runtime filtering
   - Group → from World (panics if not created)
   - SingleTag → from TagStorage
   - TagQuery → from World with tag filtering
   - Resource → from resource pool
   - EventReader/EventWriter → from event storage
```

## System Function Example

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

        // Commands usage
        if (pos.x < 0) {
            try commands.destroyEntity(entity);
        }
    }
}

// Execute:
try world.runSystem(movementSystem);
```

## createSystemFunction()

**Lines:** 763-825

Converts a user-defined system function to an executable form.

```zig
pub fn createSystemFunction(
    comptime WorldType: type,
    comptime systemFn: anytype,
) fn (*WorldType) anyerror!void
```

**Parameters**:
- `WorldType`: The World type
- `systemFn`: System function to convert

**Returns**: Function pointer that accepts World

**Use case**: Pre-compile system functions for repeated execution

**Example**:
```zig
const movementSystemFn = createSystemFunction(World, movementSystem);

// Later:
try movementSystemFn(&world);
```

## Commands API

**Lines:** 571-689

Commands provide deferred entity/component operations that are safe during iteration.

### Structure

**Lines:** 571-582

```zig
pub fn Commands(comptime WorldType: type) type {
    return struct {
        world: *WorldType,
        command_buffer: *CommandBuffer,
    };
}
```

**Characteristics**:
- Pointer to World for immediate operations
- Pointer to CommandBuffer for deferred operations
- Injected via `anytype` parameter in system functions

### Key Characteristics

- **Deferred operations**: Component additions/removals queued and executed at `world.endFrame()`
- **Immediate entity creation**: `createEntity()` returns entity immediately
- **Safe during iteration**: Can be used inside query iteration without invalidation
- **InlineStorage**: Component data stored inline (no heap allocation per command)

### Methods

#### createEntity()

**Lines:** 588-591

Create entity immediately.

```zig
pub fn createEntity(self: *Self) !Entity
```

**Returns**: New Entity ID

**Behavior**: Immediate, calls `world.createEntity()` directly

**Example**:
```zig
const new_entity = commands.createEntity();
try commands.addComponent(new_entity, Position{ .x = 0, .y = 0 });
```

#### createEntityWith()

**Lines:** 593-601

Create entity with components (deferred).

```zig
pub fn createEntityWith(self: *Self, components: anytype) !Entity
```

**Parameters**:
- `components`: Struct with component fields

**Returns**: New Entity ID

**Behavior**: Entity created immediately, components added at `endFrame()`

**Example**:
```zig
const entity = try commands.createEntityWith(.{
    .position = Position{ .x = 0, .y = 0 },
    .velocity = Velocity{ .x = 1, .y = 0 },
});
```

#### addComponent()

**Lines:** 603-608

Add component to entity (deferred).

```zig
pub fn addComponent(self: *Self, entity: Entity, component: anytype) !void
```

**Parameters**:
- `entity`: Entity to add component to
- `component`: Component value

**Behavior**: Queued, executed at `endFrame()`

**Example**:
```zig
try commands.addComponent(entity, Health{ .value = 100 });
```

#### removeComponent()

**Lines:** 610-613

Remove component from entity (deferred).

```zig
pub fn removeComponent(self: *Self, entity: Entity, comptime Component: type) !void
```

**Parameters**:
- `entity`: Entity to remove component from
- `Component`: Component type to remove

**Behavior**: Queued, executed at `endFrame()`

**Example**:
```zig
try commands.removeComponent(entity, Velocity);
```

#### addTag() / removeTag()

**Lines:** 615-622

Add or remove tag component (deferred).

```zig
pub fn addTag(self: *Self, entity: Entity, comptime Tag: type) !void
pub fn removeTag(self: *Self, entity: Entity, comptime Tag: type) !void
```

**Parameters**:
- `entity`: Entity to modify
- `Tag`: Tag type

**Behavior**: Queued, executed at `endFrame()`

**Example**:
```zig
try commands.addTag(entity, Enemy);
try commands.removeTag(entity, Dead);
```

#### destroyEntity()

**Lines:** 633-640

Destroy entity (deferred).

```zig
pub fn destroyEntity(self: *Self, entity: Entity) !void
```

**Parameters**:
- `entity`: Entity to destroy

**Behavior**: Queued, executed at `endFrame()`

**Example**:
```zig
if (health.value <= 0) {
    try commands.destroyEntity(entity);
}
```

#### createGroup()

**Lines:** 685-688

Create group (immediate).

```zig
pub fn createGroup(self: *Self, comptime GroupComponents: type) !void
```

**Parameters**:
- `GroupComponents`: Struct type defining group components

**Behavior**: Immediate, creates and populates group

**Example**:
```zig
try commands.createGroup(struct { Position, Velocity });
```

#### Serialization Methods

**Lines:** 642-669

```zig
pub fn serialize(self: *Self, writer: anytype) !void
pub fn deserialize(self: *Self, reader: anytype) !void
pub fn serializeToFile(self: *Self, path: []const u8) !void
pub fn deserializeFromFile(self: *Self, path: []const u8) !void
```

**Use case**: Save/load world state

**Example**:
```zig
// Save
try commands.serializeToFile("save.dat");

// Load
try commands.deserializeFromFile("save.dat");
```

## CommandBuffer

**Lines:** 452-545

Internal buffer that queues deferred commands for batch execution.

### Structure

**Lines:** 452-460

```zig
const CommandBuffer = struct {
    allocator: Allocator,
    commands: ArrayList(Command),
};
```

### Command Types

**Lines:** 27-31

```zig
const CommandType = enum {
    add_component,
    remove_component,
    destroy_entity,
};
```

### Command Record

**Lines:** 33-38

```zig
const Command = struct {
    command_type: CommandType,
    entity: Entity,
    component_id: usize,
    component_data: InlineStorage,  // Inline component storage
};
```

### InlineStorage

**Lines:** 40-50

Fixed-size storage for component data to avoid heap allocation per command.

```zig
const max_component_size = 256;
const InlineStorage = [max_component_size]u8;
```

**Characteristics**:
- Components ≤ 256 bytes stored inline
- No separate heap allocation per command
- Reduced memory fragmentation

### Methods

#### init()

**Lines:** 463-472

Initialize empty command buffer.

```zig
pub fn init(allocator: Allocator) CommandBuffer
```

#### deinit()

**Lines:** 474-483

Free command buffer.

```zig
pub fn deinit(self: *CommandBuffer) void
```

#### recordAddComponent()

**Lines:** 485-500

Queue component addition.

```zig
pub fn recordAddComponent(
    self: *CommandBuffer,
    entity: Entity,
    component_id: usize,
    component: anytype,
) !void
```

**Behavior**: Serializes component into InlineStorage, adds to queue

#### recordRemoveComponent()

**Lines:** 502-513

Queue component removal.

```zig
pub fn recordRemoveComponent(
    self: *CommandBuffer,
    entity: Entity,
    component_id: usize,
) !void
```

#### recordDestroyEntity()

**Lines:** 515-522

Queue entity destruction.

```zig
pub fn recordDestroyEntity(
    self: *CommandBuffer,
    entity: Entity,
) !void
```

#### flush()

**Lines:** 524-543

Execute all queued commands on world.

```zig
pub fn flush(self: *CommandBuffer, world: anytype) !void
```

**Behavior**:
1. Iterate command queue
2. Execute each command (add/remove component, destroy entity)
3. Clear queue

**Called by**: `world.endFrame()`

## Frame Lifecycle

```zig
while (running) {
    world.beginFrame();              // Swap event buffers

    try world.runSystem(inputSystem);
    try world.runSystem(physicsSystem);
    try world.runSystem(renderSystem);

    try world.endFrame();            // Flush CommandBuffer
}
```

### beginFrame()

**Lines:** 703-709 (world.zig)**

```zig
pub fn beginFrame(self: *Self) void
```

**Behavior**:
1. Swap event buffers (write ↔ read)
2. Clear new write buffer

### endFrame()

**Lines:** 711-715 (world.zig)**

```zig
pub fn endFrame(self: *Self) !void
```

**Behavior**: Flush command buffer, executing all deferred operations

## System Execution Flow

1. **Setup**: World analyzes system function signature
2. **Parameter Injection**: World creates filter/resource/event instances
3. **Execution**: System function runs, may enqueue commands
4. **Deferred Execution**: Commands execute at `endFrame()`

### Example Flow

```zig
fn spawnSystem(
    spawners: SingleQuery(Spawner),
    commands: anytype,
) !void {
    for (spawners.entities, spawners.components) |entity, spawner| {
        // 1. Create entity (immediate)
        const new_entity = commands.createEntity();

        // 2. Add components (deferred, queued in CommandBuffer)
        try commands.addComponent(new_entity, Position{ .x = 0, .y = 0 });
        try commands.addComponent(new_entity, Velocity{ .x = 1, .y = 0 });
    }
}

// In game loop:
world.beginFrame();
try world.runSystem(spawnSystem);  // Commands queued
try world.endFrame();              // Commands executed here
```

## Performance Considerations

### Immediate vs Deferred

| Operation | Timing | Use Case |
|-----------|--------|----------|
| `createEntity()` | Immediate | Need ID for subsequent commands |
| `createGroup()` | Immediate | Group setup |
| `addComponent()` | Deferred | Safe during iteration |
| `removeComponent()` | Deferred | Safe during iteration |
| `destroyEntity()` | Deferred | Safe during iteration |

### InlineStorage Benefits

- **No heap allocation per command**: Components stored inline
- **Better cache locality**: Command data together
- **Limitation**: Components > 256 bytes will fail at compile time

### Batch Execution

- Commands executed in order at `endFrame()`
- Single pass through command buffer
- Component storage updates happen once

## Best Practices

1. **Use Commands for mutations during iteration**
   ```zig
   // Good: Safe during iteration
   for (entities) |entity| {
       try commands.destroyEntity(entity);
   }

   // Bad: Invalidates iterator
   for (entities) |entity| {
       world.destroyEntity(entity); // DON'T DO THIS
   }
   ```

2. **Batch operations when possible**
   ```zig
   // Create entity once, add multiple components
   const entity = commands.createEntity();
   try commands.addComponent(entity, Position{});
   try commands.addComponent(entity, Velocity{});
   ```

3. **Don't store Commands across frames**
   ```zig
   // Commands is temporary, don't store it
   fn mySystem(commands: anytype) !void {
       // Use commands here only
   }
   ```

4. **Use createEntityWith() for prefabs**
   ```zig
   try commands.createEntityWith(.{
       .position = Position{ .x = 0, .y = 0 },
       .velocity = Velocity{ .x = 1, .y = 0 },
       .health = Health{ .value = 100 },
   });
   ```

5. **Validate entity before destruction**
   ```zig
   if (registry.isAlive(entity)) {
       try commands.destroyEntity(entity);
   }
   ```

## Error Handling

System functions can return errors:

```zig
fn riskySy stem(
    query: Query(struct { Transform }),
    commands: anytype,
) !void {
    // Can return errors from:
    // - Command operations (OOM)
    // - Custom logic

    return error.CustomError;
}

// Caller handles error:
try world.runSystem(riskySystem); // Propagates error
```

## Integration with World

System functions are the primary interface for game logic:

1. **Query Filters**: Access entity/component data (see [Query Filters](../query/CLAUDE.md))
2. **Resources**: Access global state (see [World API](../../CLAUDE.md#resources))
3. **Events**: Inter-system communication (see [World API](../../CLAUDE.md#events))
4. **Commands**: Deferred mutations for safe iteration

**Note**: `World` cannot be passed directly to system functions. Use injected parameters instead.

## Advanced Patterns

### Multi-stage Systems

```zig
fn collisionDetection(
    query: Query(struct { Position, Collider }),
    writer: EventWriter(CollisionEvent),
) !void {
    var pairs = query.combinations();
    while (pairs.next()) |pair| {
        // Detect collision
        try writer.enqueue(CollisionEvent{ .a = pair[0], .b = pair[1] });
    }
}

fn collisionResponse(
    reader: EventReader(CollisionEvent),
    commands: anytype,
) !void {
    for (reader.queue) |event| {
        // Respond to collision (next frame)
        try commands.destroyEntity(event.a);
    }
}
```

### Conditional System Execution

```zig
fn updateSystem(state: Resource(GameState)) !void {
    if (state.paused) return; // Skip when paused

    // Update logic
}
```

### System Composition

```zig
fn parentSystem(
    query: Query(struct { Transform }),
    commands: anytype,
) !void {
    // Can call helper functions
    try helper(query, commands);
}

fn helper(query: anytype, commands: anytype) !void {
    // Helper logic
}
```
