# CLAUDE.md

Comprehensive guide for Sparze (Zig ECS library).

## Build Commands

```bash
zig build test
zig build test-wasm
zig build examples
zig build run-examples
zig build run-{example-name}
zig build {command} -Dtarget=wasm32-wasi
```

## What Sparze Is

Compile-time ECS: component, resource, and event types known at compile time.

- Zero runtime lookup
- Strong type safety
- Cache-friendly layouts, pagination, groups
- Minimal API

## Module Documentation

- **[Entity System](src/entity/CLAUDE.md)**: Entity IDs, EntityRegistry
- **[Storage](src/storage/CLAUDE.md)**: ComponentStorage, SparseSet, TagStorage, EventStorage
- **[Query Filters](src/query/CLAUDE.md)**: SingleQuery, Query, Group, TagQuery, modifiers
- **[System Functions](src/system/CLAUDE.md)**: Parameter injection, Commands

## World API

**Location:** `src/world.zig`

```zig
World(
    Components: struct { Position, Velocity, ... },
    Resources: struct { DeltaTime, GameState, ... },
    Events: struct { Collision, SpawnEvent, ... }
)
```

**Cannot be used directly in system functions** - use injected parameters.

**Key methods**: `init`, `deinit`, `createEntity`, `destroyEntity`, `addComponent`, `addTag`, `removeComponent`, `removeTag`, `setResource`, `getResource`, `createGroup`, `validateGroups`, `beginFrame`, `endFrame`, `runSystem`

## Resources

Global singletons accessible via `Resource(T)` injection.

### Initialization

**IMPORTANT**: Resources must be initialized before use. Accessing uninitialized resources will:
- **Debug/ReleaseSafe builds**: Trigger assertion (panic)
- **ReleaseFast builds**: Return undefined memory (zeroes)

### Initialization Methods

```zig
// Method 1: Individual initialization
try world.setResource(DeltaTime, .{ .value = 0.016 });
try world.setResource(Score, .{ .points = 0 });

// Method 2: Bulk initialization (recommended for startup)
try world.initResources(.{
    .delta_time = DeltaTime{ .value = 0.016 },
    .score = Score{ .points = 0 },
    .config = GameConfig{ .gravity = 9.8 },
});

// Method 3: Direct pool access (requires manual marking)
world.resource_pool[0] = DeltaTime{ .value = 0.016 };
world.markResourceInitialized(DeltaTime);
```

### Accessing Resources

```zig
// In systems (preferred)
fn updateSystem(delta: Resource(DeltaTime)) !void {
    const dt = delta.value.value;
}

// Direct access (unchecked, zero-cost)
const delta = world.getResource(DeltaTime);
const delta_ptr = world.getResourcePtr(DeltaTime);
const delta_mut = world.getResourcePtrMut(DeltaTime);

// Safe checked access (returns error if uninitialized)
const delta_ptr = try world.tryGetResource(DeltaTime);
const delta_mut = try world.tryGetResourceMut(DeltaTime);

// Check initialization status
if (world.isResourceInitialized(DeltaTime)) {
    // Safe to access
}
```

### Best Practices

1. **Initialize all resources at startup** using `initResources()`
2. **Use `Resource(T)` injection in systems** for clean code
3. **Use `tryGetResource*()` for optional resources** that might not exist
4. **Run tests in Debug mode** to catch initialization bugs early

## Events

Frame-delayed communication via double-buffered storage. Events written in frame N readable in frame N+1.

```zig
// Write
fn detectionSystem(writer: EventWriter(CollisionEvent)) !void {
    try writer.enqueue(CollisionEvent{ .a = e1, .b = e2 });
}

// Read (next frame)
fn responseSystem(reader: EventReader(CollisionEvent), commands: anytype) !void {
    for (reader.queue) |event| {
        try commands.destroyEntity(event.a);
    }
}
```

## Serialization

**Location:** `src/serialization/`

**Serialized**: Entities, components, resources, events (read buffer only)

**Not serialized**: Groups, command buffers, event write buffer, types with `pub const serialized = false`

**POD types**: Auto-serialized

**Non-POD**: Require custom `Serializer`:

```zig
pub const CustomComponent = struct {
    data: []u8,

    pub const Serializer = struct {
        pub fn serialize(component: CustomComponent, writer: anytype) !void { }
        pub fn deserialize(reader: anytype, allocator: Allocator) !CustomComponent { }
    };
};
```

**Exclude**: `pub const serialized = false;`

**Usage**:
```zig
try commands.serializeToFile("save.dat");
try commands.deserializeFromFile("save.dat");
try world.createGroup(struct { Position, Velocity });  // Recreate groups
```

**Safety**: Type metadata hash, CRC32 checksum, format version.

## Performance

**Memory**: Tag components (1 bit/entity), pre-allocate with `reserve()`, pagination (4096/page).

**Iteration**: Group for hot paths, Query iterates smallest set, direct array access with Group.

**System organization**:
```zig
const PhysicsGroup = struct { Position, Velocity };
World.validateGroups(.{ PhysicsGroup, RenderGroup });  // Compile-time validation
```

## Examples

**Location:** `examples/`

`basic.zig`, `movement_example.zig`, `events.zig`, `resources.zig`, `tag_components.zig`, `multiple_groups.zig`, `combination_iterator.zig`, `cross_product.zig`, `serialization.zig`, `serialization_exclusion.zig`, `benchmarks/`

## Architecture

### Core Structures

| Structure | Location | Purpose |
|-----------|----------|---------|
| Entity/EntityRegistry | `src/entity/entity.zig` | 32-bit ID, lifecycle |
| SparseSet | `src/storage/sparse_set.zig` | Component storage |
| TagStorage | `src/storage/tag_storage.zig` | Tag storage (bitset) |
| EventStorage | `src/storage/event_storage.zig` | Event queue |

### Main API

| Component | Location | Purpose |
|-----------|----------|---------|
| World | `src/world.zig` | ECS coordinator |
| System functions | `src/system/system.zig` | Execution & injection |
| Commands | `src/system/system.zig` | Deferred ops |
| Query Filters | `src/query/filter.zig` | Entity iteration |

### Design Principles

Compile-time type resolution, strong type safety, cache-friendly layouts, minimal API, explicit over implicit.
