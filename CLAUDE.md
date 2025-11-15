# CLAUDE.md

Comprehensive guide for the Sparze codebase (Zig ECS library).

## Build Commands

```bash
zig build test                              # Run tests
zig build test-wasm                         # Tests with wasm target
zig build examples                          # Build all examples
zig build run-examples                      # Run all examples
zig build run-{example-name}                # Run specific example
zig build {command} -Dtarget=wasm32-wasi    # Build with wasm
```

## What Sparze Is

Compile-time Entity Component System where component, resource, and event types are known at compile time:

- **Zero runtime lookup**: All type info resolved at compile time
- **Strong type safety**: Compile-time validation
- **High performance**: Cache-friendly layouts, pagination, groups
- **Minimal API**: Composable primitives

## Directory Structure

```
src/
├── entity/          # Entity and EntityRegistry (see src/entity/CLAUDE.md)
├── storage/         # Component, tag, event storage (see src/storage/CLAUDE.md)
├── query/           # Query Filters and modifiers (see src/query/CLAUDE.md)
├── system/          # System functions and Commands (see src/system/CLAUDE.md)
├── serialization/   # Binary serialization/deserialization
└── world.zig        # Central ECS coordinator
```

## Module Documentation

- **[Entity System](src/entity/CLAUDE.md)**: Entity IDs, EntityRegistry, lifecycle
- **[Storage](src/storage/CLAUDE.md)**: ComponentStorage, SparseSet, TagStorage, EventStorage
- **[Query Filters](src/query/CLAUDE.md)**: SingleQuery, Query, Group, TagQuery, modifiers
- **[System Functions](src/system/CLAUDE.md)**: System execution, parameter injection, Commands

## World API

**Location:** `src/world.zig`

```zig
World(
    Components: struct { Position, Velocity, Health, ... },
    Resources: struct { DeltaTime, GameState, ... },
    Events: struct { Collision, SpawnEvent, ... }
)
```

**Characteristics**:
- Component/resource/event IDs assigned at compile time
- Direct storage access without runtime lookup
- **Cannot be used directly in system functions** - use injected parameters

**Key methods**:
- `init(allocator)`, `deinit()`
- `createEntity()`, `destroyEntity()`
- `addComponent()`, `addTag()`, `removeComponent()`, `removeTag()`
- `setResource()`, `getResource()`, `getResourcePtr()`, `getResourcePtrMut()`
- `createGroup()`, `validateGroups(...)`
- `beginFrame()`, `endFrame()`, `runSystem(systemFn)`

## Resources

Global singleton values accessible via `Resource(T)` injection.

```zig
// Initialize
world.setResource(DeltaTime, DeltaTime{ .value = 0.016 });

// Use in system
fn updateSystem(delta: Resource(DeltaTime)) !void {
    const dt = delta.value;
}
```

**Methods**: `setResource(T, value)`, `getResource(T)`, `getResourcePtr(T)`, `getResourcePtrMut(T)`

## Events

Frame-delayed communication via double-buffered storage.

**Lifecycle**: Events written in frame N readable in frame N+1.

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

// Frame loop
while (running) {
    world.beginFrame();  // Swap event buffers
    try world.runSystem(detectionSystem);
    try world.runSystem(responseSystem);
    try world.endFrame();  // Flush commands
}
```

## Serialization

**Location:** `src/serialization/`

Binary serialization with type safety and integrity checking.

### What's Serialized

- Entities, components, resources
- Events (read buffer only)

### What's NOT Serialized

- Groups (recreate with `createGroup()`)
- Command buffers
- Event write buffer
- Types with `pub const serialized = false`

### Type Support

**POD types**: Auto-serialized (primitives, POD structs, fixed arrays)

**Non-POD types**: Require custom `Serializer`:

```zig
pub const CustomComponent = struct {
    data: []u8,

    pub const Serializer = struct {
        pub fn serialize(component: CustomComponent, writer: anytype) !void { }
        pub fn deserialize(reader: anytype, allocator: Allocator) !CustomComponent { }
    };
};
```

**Exclude from serialization**:

```zig
pub const TemporaryComponent = struct {
    pub const serialized = false;
    value: f32,
};
```

### Usage

```zig
// Via Commands (recommended)
try commands.serializeToFile("save.dat");
try commands.deserializeFromFile("save.dat");

// Via World
try world.serialize(file.writer());
try world.deserialize(file.reader());
try world.createGroup(struct { Position, Velocity });  // Recreate groups
```

**Safety**: Type metadata hash, CRC32 checksum, format version.

## Performance Notes

### Memory

1. **Tag components** for markers: 1 bit/entity vs full storage
2. **Pre-allocate** with `reserve()` before bulk inserts
3. **Pagination**: 4096 entities/page, allocated on-demand

### Iteration

1. **Use Group** for hot paths: No filtering, cache-friendly
2. **Query optimizations**: Iterates smallest component set
3. **Direct array access**: `getArrayOf()`/`getMutArrayOf()` with Group

### System Organization

```zig
const PhysicsGroup = struct { Position, Velocity, Mass };
const RenderGroup = struct { Position, Sprite };

// Validate at compile time
World.validateGroups(.{ PhysicsGroup, RenderGroup });

// System functions: plain functions with injected parameters
fn physicsSystem(physics: Group(PhysicsGroup), delta: Resource(DeltaTime)) !void { }
fn renderSystem(render: Group(RenderGroup)) !void { }
```

## Examples

**Location:** `examples/`

- `basic.zig`: Entity spawning, queries
- `movement_example.zig`: Groups, validation, frame loop
- `events.zig`: EventWriter/EventReader
- `resources.zig`: Resources, Exclude modifier
- `tag_components.zig`: SingleTag, TagQuery
- `multiple_groups.zig`: Group validation
- `combination_iterator.zig`: Collision detection
- `cross_product.zig`: Projectile-enemy collisions
- `serialization.zig`: POD/custom serializers
- `serialization_exclusion.zig`: Excluding types
- `benchmarks/`: Performance testing

## Architecture Summary

### Core Data Structures

| Structure | Location | Purpose |
|-----------|----------|---------|
| Entity | `src/entity/entity.zig` | 32-bit ID with version |
| EntityRegistry | `src/entity/entity.zig` | Lifecycle management |
| SparseSet | `src/storage/sparse_set.zig` | Component storage |
| TagStorage | `src/storage/tag_storage.zig` | Tag storage (bitset) |
| EventStorage | `src/storage/event_storage.zig` | Event queue |
| ComponentStorage | `src/storage/component_storage.zig` | Storage selection |

### Main API

| Component | Location | Purpose |
|-----------|----------|---------|
| World | `src/world.zig` | ECS coordinator |
| System functions | `src/system/system.zig` | Execution & injection |
| Commands | `src/system/system.zig` | Deferred operations |
| Query Filters | `src/query/filter.zig` | Entity iteration |
| Serialization | `src/serialization/` | Save/load |

### Design Principles

1. **Compile-time type resolution**: Zero runtime overhead
2. **Strong type safety**: Compile errors for invalid ops
3. **Cache-friendly layouts**: Packed arrays, groups
4. **Minimal API**: Composable primitives
5. **Explicit over implicit**: Clear semantics, no hidden costs

## Notes for Contributors

- Read `src/` for implementation details
- Keep changes consistent with Zig idioms
- Add tests for new features
- Update examples when adding public API
- Run `zig build test` before committing
