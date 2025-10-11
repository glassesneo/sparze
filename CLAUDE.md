# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sparze is an Entity Component System (ECS) library written in Zig. It provides two distinct architectures:

- **Dynamic World** (`src/dynamic/`): Runtime-flexible ECS where component types are registered dynamically
- **Fixed World** (`src/fixed/`): Compile-time ECS where all component types are known at compile time

Both architectures share core data structures (Entity registry, SparseSet) but have different APIs for component management and system execution.

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
- `AbstractSparseSet` provides type-erased interface using vtable for dynamic dispatch

### Dynamic World API

**Component Registration** (`src/dynamic/world.zig`):
- Components must be manually registered via `registerComponent(C, *SparseSet(C))`
- Component types identified by `typeId(T)` computed from `@typeName(T)`
- Sparse/dense index mapping for dynamic component lookup

**Systems** (`src/dynamic/system.zig`):
- `SingleQuery(Component)`: queries all entities with a single component
- `Group(struct { A, B, ... })`: queries entities with multiple components (requires `createGroup()` first)
- `createSystemFunction()`: wraps system functions for automatic query resolution

### Fixed World API

**Compile-Time Type Safety** (`src/fixed/world.zig`):
- World parameterized by component tuple: `FixedWorld(struct { Position, Velocity, Health })`
- All component types known at compile time
- Component IDs assigned sequentially at compile time (0, 1, 2...)
- Direct sparse set access without dynamic lookup

**Systems** (`src/fixed/system.zig`):
- `SingleQuery(World, Component)`: requires explicit World type parameter
- `Group(World, struct { A, B })`: requires explicit World type parameter
- `world.runSystem(systemFn)`: convenience method for inline system execution
- `createSystemFunction(World, systemFn)`: returns typed function pointer

**Group Validation**:
- `World.validateGroups(.{ struct { A, B }, struct { C, D } })`: compile-time validation ensures no overlapping components between groups
- Recommended to validate all groups upfront for compile-time safety

## Common Patterns

### Fixed World Pattern (Recommended)

```zig
const World = sparze.fixed.FixedWorld(struct { Position, Velocity, Health });

// Validate groups at compile time
World.validateGroups(.{
    struct { Position, Velocity },
    struct { Health, Armor },
});

var world = World.init(allocator);
try world.createGroup(struct { Position, Velocity });

// System with multiple query types
fn mySystem(
    movement: Group(World, struct { Position, Velocity }),
    health: SingleQuery(World, Health),
) !void {
    // Use movement.getEntities(), movement.getMutArrayOf(Position), etc.
    // Use health.entities, health.components
}

try world.runSystem(mySystem);
```

### Dynamic World Pattern

```zig
var world = sparze.dynamic.DynamicWorld.init(allocator);

// Register components
var position_set = sparze.SparseSet(Position).init(allocator);
var velocity_set = sparze.SparseSet(Velocity).init(allocator);
try world.registerComponent(Position, &position_set);
try world.registerComponent(Velocity, &velocity_set);

try world.createGroup(struct { Position, Velocity });

// System definition
fn systemWithGroup(group: Group(struct { Position, Velocity })) !void {
    for (group.getEntities(), group.getMutArrayOf(Position), group.getArrayOf(Velocity))
        |entity, *pos, vel| {
        pos.x += vel.x;
    }
}

// Use createSystemFunction for automatic query resolution
const createSystemFunction = sparze.dynamic.createSystemFunction;
const systemPtr = createSystemFunction(systemWithGroup);
try systemPtr(&world);
```

## Key Differences Between APIs

| Aspect | Dynamic World | Fixed World |
|--------|---------------|-------------|
| Component registration | Runtime (`registerComponent`) | Compile-time (tuple parameter) |
| Query types | `SingleQuery(C)` | `SingleQuery(World, C)` |
| Group types | `Group(struct { A, B })` | `Group(World, struct { A, B })` |
| Component lookup | Dynamic (hash-based typeId) | Direct (compile-time index) |
| System execution | Function pointer via `createSystemFunction` | `world.runSystem(fn)` or manual |
| Group validation | Runtime only | Compile-time with `validateGroups()` |

## Important Notes

- **Group ownership**: Groups use "full-owning" model where entities in the group are stored at the start of the packed array in all component sparse sets. This enables cache-friendly iteration but means groups cannot overlap (enforced at compile time for FixedWorld).

- **Entity versioning**: Always use the entity handles returned by create/destroy operations. Stale entity handles will fail version checks.

- **Memory management**:
  - Dynamic World: Sparse sets must outlive the World and be deinitialized separately
  - Fixed World: Component pools are owned by World and deinitialized automatically

- **Examples**: The `examples/` directory contains parallel implementations showing both dynamic and fixed approaches for the same patterns (e.g., `system_operations.zig` vs `fixed_system_operations.zig`).
