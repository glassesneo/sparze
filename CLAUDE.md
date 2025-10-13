# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sparze is an Entity Component System (ECS) library written in Zig. It provides compile-time ECS where all component types are known at compile time, offering zero runtime overhead and strong type safety.

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

### World API

**Component Registration** (`src/world.zig`):
- World parameterized by component tuple: `World(struct { Position, Velocity, Health })`
- All component types known at compile time
- Component IDs assigned sequentially at compile time (0, 1, 2...)
- Direct sparse set access without dynamic lookup

**Systems** (`src/system.zig`):
- Query filters: Types that filter entities based on component composition, used as system parameters
  - `SingleQuery(Component)`: single component query filter
  - `Query(struct { A, B, ... })`: multi-component runtime intersection query filter (no group setup required)
  - `Group(struct { A, B })`: optimized multi-component query filter with pre-allocated group (requires `createGroup()`)
- `world.runSystem(systemFn)`: convenience method for inline system execution
- `createSystemFunction(World, systemFn)`: returns typed function pointer

**Group Validation**:
- `World.validateGroups(.{ struct { A, B }, struct { C, D } })`: compile-time validation ensures no overlapping components between groups
- Recommended to validate all groups upfront for compile-time safety

## Common Patterns

### Standard World Pattern

```zig
const World = sparze.World(struct { Position, Velocity, Health });

// Validate groups at compile time
World.validateGroups(.{
    struct { Position, Velocity },
    struct { Health, Armor },
});

var world = World.init(allocator);
try world.createGroup(struct { Position, Velocity });

// System with Group (optimized, requires createGroup)
fn movementSystem(movement: Group(struct { Position, Velocity })) !void {
    const positions = movement.getMutArrayOf(Position);
    const velocities = movement.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
    }
}

// System with Query (flexible, no group setup required)
fn combatSystem(query: Query(struct { Position, Health })) !void {
    for (query.entities) |entity| {
        if (query.hasAllComponents(entity)) {
            const pos = query.getComponent(entity, Position).?;
            if (query.getComponentMut(entity, Health)) |health| {
                // Process entity
            }
        }
    }
}

// System with multiple query filters
fn mySystem(
    movement: Group(struct { Position, Velocity }),
    health: SingleQuery(Health),
) !void {
    // Use movement.getEntities(), movement.getMutArrayOf(Position), etc.
    // Use health.entities, health.components
}

try world.runSystem(movementSystem);
try world.runSystem(combatSystem);
```

## Query Filter Comparison

| Filter Type | Components | Setup Required | Performance | Use Case |
|-------------|------------|----------------|-------------|----------|
| `SingleQuery(C)` | 1 | None | O(n) - Fast | Single component iteration |
| `Query(struct { A, B, ... })` | 2+ | None | O(n) - Moderate | Ad-hoc multi-component queries |
| `Group(struct { A, B })` | 2+ | `createGroup()` required | O(n) - Fastest | Frequently used multi-component queries |

**When to use each**:
- **SingleQuery**: Iterating over entities with one component
- **Query**: Multi-component queries used occasionally or with varying component combinations
- **Group**: Hot-path multi-component queries (e.g., movement, rendering) where performance is critical

**Key differences**:
- **Query** performs runtime intersection, iterating smallest component set and checking for others
- **Group** has pre-organized memory layout with entities stored at start of all component arrays
- **Group** requires upfront `createGroup()` call and validation; **Query** has no setup overhead

## Best Practices

### 1. Declare Group Type Constants

Always declare a constant for group types before using them. This improves readability, maintainability, and reduces duplication since group types appear in multiple places (validation, creation, and system parameters).

```zig
// Recommended: Declare group constants
const MovementGroup = struct { Position, Velocity };
const CombatGroup = struct { Health, Armor };

World.validateGroups(.{
    MovementGroup,
    CombatGroup,
});

try world.createGroup(MovementGroup);
try world.createGroup(CombatGroup);

fn movementSystem(group: Group(MovementGroup)) !void {
    // System implementation
}

fn combatSystem(group: Group(CombatGroup)) !void {
    // System implementation
}
```

**Why use constants?**
- Reduces duplication (group types appear 3+ times: validation, creation, system parameter)
- Improves readability with semantic names
- Simplifies refactoring (change in one place)
- Self-documenting code

### 2. Define Systems as Plain Functions

Systems should be defined as plain functions that accept query filter parameters. This pattern is simple, idiomatic, and works seamlessly with `world.runSystem()`.

```zig
// Recommended: Plain function
fn movementSystem(group: Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

// Usage
try world.runSystem(movementSystem);
```

Systems can accept multiple query filter parameters:

```zig
fn complexSystem(
    movement: Group(MovementGroup),
    health: SingleQuery(Health),
    combat: Query(struct { Position, Armor }),
) !void {
    // Use multiple query filters in one system
}
```

## Performance Optimizations

### SparseSet Optimizations

**Bit-shift indexing** (`src/core/sparse_set.zig`):
- Page indexing uses `sparse_index >> 12` instead of division
- Slot indexing uses `sparse_index & 0xFFF` instead of modulo
- Applied to all hot paths: get, insert, remove, moveToGroup, moveFromGroup
- Results in ~20% faster component lookups

**Optimized remove**:
- Uses direct `swapRemove()` on both arrays to reduce memory copies
- Eliminates redundant component copy operation
- ~17% faster than previous implementation

**Reserve API**:
```zig
// Pre-allocate capacity to avoid reallocations during bulk inserts
try world.getSparseSetPtr(Position).reserve(expected_capacity);
```

### Command Buffer Optimizations

**Inline storage** (`src/system.zig`):
- Commands use inline array `[max_component_size]u8` instead of heap-allocated `[]u8`
- Eliminates `allocator.dupe()` call per command
- `max_component_size` computed at comptime per World
- Results in 77.8x faster command buffer operations (98.7% speedup)

### Internal Details

**World constants**:
- `World.max_component_size`: Computed at comptime, max @sizeOf() of all components
- Used by CommandBuffer for inline storage sizing

**Page configuration**:
- Page size: 4096 entities (2^12)
- Page shift constant: 12
- Page mask: 0xFFF

## Important Notes

- **Group ownership**: Groups use "full-owning" model where entities in the group are stored at the start of the packed array in all component sparse sets. This enables cache-friendly iteration but means groups cannot overlap (enforced at compile time).

- **Entity versioning**: Always use the entity handles returned by create/destroy operations. Stale entity handles will fail version checks.

- **Memory management**:
  - Component pools are owned by World and deinitialized automatically
  - Command buffer uses inline storage (no per-command allocation)

- **Performance**:
  - Use `reserve()` for bulk insertions to eliminate reallocation overhead
  - Prefer `Group` over `Query` for hot-path multi-component iteration
  - Command buffers are highly optimized with inline storage

- **Examples**: The `examples/` directory contains implementations showing various patterns (e.g., `system_operations.zig`, `plugin_architecture.zig`, `performance_benchmark.zig`).
