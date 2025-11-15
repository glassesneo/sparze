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

## Directory structure

```
src/
├── entity/          # Entity and EntityRegistry (see src/entity/CLAUDE.md)
├── storage/         # Component, tag, and event storage (see src/storage/CLAUDE.md)
├── query/           # Query Filters and Filter Modifiers (see src/query/CLAUDE.md)
├── system/          # System functions and Commands API (see src/system/CLAUDE.md)
├── serialization/   # Binary serialization/deserialization
└── world.zig        # Central ECS coordinator
```

## Module documentation

Each module has its own detailed CLAUDE.md:

- **[Entity System](src/entity/CLAUDE.md)**: Entity IDs, EntityRegistry, lifecycle management
- **[Storage](src/storage/CLAUDE.md)**: ComponentStorage, SparseSet, TagStorage, EventStorage
- **[Query Filters](src/query/CLAUDE.md)**: SingleQuery, Query, Group, TagQuery, Filter Modifiers
- **[System Functions](src/system/CLAUDE.md)**: System execution, parameter injection, Commands API

## World API

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

**Location:** `src/storage/event_storage.zig`, `src/query/filter.zig`

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
| Entity | `src/entity/entity.zig` | 32-bit ID with version recycling |
| EntityRegistry | `src/entity/entity.zig` | Entity lifecycle management |
| SparseSet | `src/storage/sparse_set.zig` | Regular component storage |
| TagStorage | `src/storage/tag_storage.zig` | Tag component storage (bitset) |
| EventStorage | `src/storage/event_storage.zig` | Double-buffered event queue |
| ComponentStorage | `src/storage/component_storage.zig` | Storage type selection |

### Main API

| Component | Location | Purpose |
|-----------|----------|---------|
| World | `src/world.zig` | Central ECS coordinator |
| System functions | `src/system/system.zig` | System execution & parameter injection |
| Commands | `src/system/system.zig` | Deferred entity/component operations |
| Query Filters | `src/query/filter.zig` | Entity iteration with component matching |
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
