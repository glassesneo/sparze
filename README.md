# Sparze

A high-performance Entity Component System (ECS) library for Zig, offering both compile-time and runtime-flexible architectures.

## Features

- **Dual Architecture Design**
  - **Fixed World**: Compile-time type safety with zero runtime overhead
  - **Dynamic World**: Runtime flexibility for dynamic component registration

- **Optimized Data Structures**
  - Paginated sparse sets for O(1) component access
  - Cache-friendly packed arrays for fast iteration
  - Full-owning groups for high-performance multi-component queries

- **Entity Management**
  - 32-bit entity identifiers with built-in versioning
  - Automatic entity recycling with stale reference detection
  - Support for up to 65,535 concurrent entities

- **Flexible System Design**
  - Query single components or groups of components
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

### Basic Example (Fixed World)

```zig
const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

const World = sparze.fixed.FixedWorld(struct { Position, Velocity });

const MovementGroup = struct { Position, Velocity };

// Define system
fn movementSystem(group: sparze.fixed.Group(World, MovementGroup)) !void {
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

### Basic Example (Dynamic World)

```zig
const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

const MovementGroup = struct { Position, Velocity };

// Define system
fn movementSystem(group: sparze.dynamic.Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x * 0.016;
        pos.y += vel.y * 0.016;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = sparze.dynamic.DynamicWorld.init(allocator);
    defer world.deinit();

    // Register component types
    var position_set = sparze.SparseSet(Position).init(allocator);
    defer position_set.deinit();
    var velocity_set = sparze.SparseSet(Velocity).init(allocator);
    defer velocity_set.deinit();

    try world.registerComponent(Position, &position_set);
    try world.registerComponent(Velocity, &velocity_set);

    // Create group
    try world.createGroup(struct { Position, Velocity });

    // Create entities
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(entity, Velocity, .{ .x = 1.0, .y = 2.0 });

    // Run system
    const systemFn = sparze.dynamic.createSystemFunction(movementSystem);
    try systemFn(&world);
}
```

## Architecture Overview

### Fixed World vs Dynamic World

**Fixed World** is recommended for most use cases:
- All component types known at compile time
- Zero runtime overhead for component lookup
- Compile-time validation of group constraints
- Type-safe system definitions

**Dynamic World** is useful when:
- Component types need to be loaded from plugins or configuration
- Runtime flexibility is more important than performance
- Component types cannot be known at compile time

### Core Concepts

**Entities**: Lightweight 32-bit identifiers (16-bit index + 16-bit version)

**Components**: Plain Zig structs containing data

**Systems**: Functions that operate on entities with specific component combinations

**Groups**: Optimized multi-component queries with cache-friendly memory layout

**Queries**: Single-component iteration over entities

## Examples

Explore the `examples/` directory for comprehensive demonstrations:

- `basic.zig` - Entity and component basics
- `world_operations.zig` - Dynamic world operations
- `system_operations.zig` - Dynamic system patterns
- `plugin_architecture.zig` - Dynamic plugin-style architecture
- `fixed_plugin_architecture.zig` - Fixed world plugin pattern
- `fixed_system_operations.zig` - Fixed world system patterns

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
- **Minimal indirection** in Fixed World mode

## Requirements

- Zig 0.15.1 or later

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues or PRs.

