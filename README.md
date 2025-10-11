# Sparze

A high-performance Entity Component System (ECS) library for Zig with compile-time type safety and zero runtime overhead.

## Features

- **Compile-Time Type Safety**
  - All component types known at compile time
  - Zero runtime overhead for component lookup
  - Type-safe system definitions

- **Optimized Data Structures**
  - Paginated sparse sets for O(1) component access
  - Cache-friendly packed arrays for fast iteration
  - Full-owning groups for high-performance multi-component queries

- **Entity Management**
  - 32-bit entity identifiers with built-in versioning
  - Automatic entity recycling with stale reference detection
  - Support for up to 65,535 concurrent entities

- **Flexible Query System**
  - **SingleQuery**: Iterate over entities with a single component
  - **Query**: Runtime intersection queries for multiple components (no setup required)
  - **Group**: Optimized multi-component iteration with cache-friendly layout
  - Automatic query resolution and dependency injection
  - Support for multiple query parameters per system

## Quick Start

### Installation

Add Sparze as a dependency:

```bash
zig fetch --save=sparze git+https://github.com/glassesneo/sparze.git
```

Then in your `build.zig`:

```zig
const sparze = b.dependency("sparze", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sparze", sparze.module("sparze"));
```

### Basic Example

```zig
const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

const World = sparze.World(struct { Position, Velocity });

const MovementGroup = struct { Position, Velocity };

// Define system
fn movementSystem(group: sparze.Group(World, MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x * 0.016; // 60 FPS
        pos.y += vel.y * 0.016;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create group for entities with both Position and Velocity
    try world.createGroup(MovementGroup);

    // Create entities
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(entity, Velocity, .{ .x = 1.0, .y = 2.0 });

    // Run system
    try world.runSystem(movementSystem);
}
```

### Query Types Comparison

Sparze provides three query types for different use cases:

#### SingleQuery - Single Component Iteration

```zig
fn healthSystem(query: sparze.SingleQuery(World, Health)) !void {
    for (query.entities, query.components) |entity, health| {
        std.debug.print("Entity {} has {} HP\n", .{ entity, health.hp });
    }
}
```

#### Query - Runtime Intersection (No Setup)

```zig
fn combatSystem(query: sparze.Query(World, struct { Position, Health })) !void {
    for (query.entities) |entity| {
        if (query.hasAllComponents(entity)) {
            const pos = query.getComponent(entity, Position).?;
            if (query.getComponentMut(entity, Health)) |health| {
                // Apply damage based on position
                const distance = @sqrt(pos.x * pos.x + pos.y * pos.y);
                if (distance > 50.0) {
                    health.hp -= 5;
                }
            }
        }
    }
}
```

**Use Query when:**
- You need multi-component queries without setup overhead
- Query patterns are dynamic or one-off
- Flexibility is more important than raw performance

#### Group - Optimized Multi-Component Iteration

```zig
fn movementSystem(group: sparze.Group(World, struct { Position, Velocity })) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x * 0.016;
        pos.y += vel.y * 0.016;
    }
}

// In main():
try world.createGroup(struct { Position, Velocity }); // Required setup
try world.runSystem(movementSystem);
```

**Use Group when:**
- Query runs frequently (every frame)
- Maximum iteration performance is critical
- Component combination is known upfront

#### Comparison Table

| Feature | SingleQuery | Query | Group |
|---------|------------|-------|-------|
| **Component Count** | 1 | 2+ | 2+ |
| **Setup Required** | ❌ None | ❌ None | ✅ `createGroup()` |
| **Manual Filtering** | ❌ No | ✅ Yes (`hasAllComponents`) | ❌ No |
| **Iteration Speed** | ⚡ Fast | ⚠️ Moderate | ⚡⚡ Fastest |
| **Memory Layout** | Packed | Sparse set | Cache-optimized |
| **Use Case** | Single component | Ad-hoc multi-component | Hot path iteration |

## Core Concepts

**Entities**: Lightweight 32-bit identifiers (16-bit index + 16-bit version)

**Components**: Plain Zig structs containing data

**Systems**: Functions that operate on entities with specific component combinations

**Query Types**:
- **SingleQuery**: Fast iteration over entities with a single component type
- **Query**: Flexible runtime intersection for multiple components without setup overhead
- **Group**: Optimized multi-component iteration requiring upfront `createGroup()` call for maximum performance

## Examples

Explore the `examples/` directory for comprehensive demonstrations:

- `basic.zig` - Entity and component basics
- `plugin_architecture.zig` - Plugin-style architecture
- `system_operations.zig` - System patterns and multi-query examples

Run all examples:
```bash
zig build run-examples
```

Run a specific example:
```bash
zig build run-basic
```

## Building and Testing

```bash
# Run tests
zig build test

# Build library
zig build

# Build all examples
zig build examples
```

## Performance

Sparze is designed for high-performance game and simulation workloads:

- **O(1) component access** via paginated sparse sets
- **Cache-friendly iteration** with packed component arrays
- **Group optimization** for multi-component queries
- **Zero runtime overhead** with compile-time component registration

## Requirements

- Zig 0.15.1 or later

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues or PRs.
