# Sparze - High-Performance ECS Library for Zig

A fast, type-safe Entity Component System (ECS) library written in Zig, designed for game development and high-performance applications.

## Features

- 🚀 **High Performance**: Sparse set-based component storage for O(1) operations
- 🔒 **Type Safety**: Compile-time type checking with generics
- 💾 **Memory Efficient**: Entity ID recycling and efficient memory management
- 🔧 **Flexible Access**: Both copy-based and mutable pointer-based component access
- 📦 **Resource Management**: Global resource storage with type-safe access

## Quick Start

```zig
const std = @import("std");
const sparze = @import("sparze");

// Define your components
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: i32 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a world
    var world = sparze.World.init(allocator);
    defer world.deinit();

    // Create entities with components
    const player = try world.createEntityWith(.{
        Position{ .x = 100, .y = 200 },
        Velocity{ .x = 0, .y = 0 },
        Health{ .value = 100 },
    });

    const enemy = try world.createEntity();
    try world.attachComponent(enemy, Position, .{ .x = 300, .y = 150 });
    try world.attachComponent(enemy, Health, .{ .value = 50 });

    // Query components (copy-based access)
    if (world.getComponent(player, Position)) |pos| {
        std.debug.print("Player position: ({}, {})\n", .{ pos.x, pos.y });
    }

    // Mutate components in-place (pointer-based access)
    if (world.getComponentPtr(player, Velocity)) |vel| {
        vel.x = 5.0;
        vel.y = -2.0;
    }

    // Movement system example
    const entities = world.getAllEntities();
    for (entities) |entity| {
        if (world.getComponentPtr(entity, Position)) |pos| {
            if (world.getComponent(entity, Velocity)) |vel| {
                pos.x += vel.x;
                pos.y += vel.y;
            }
        }
    }

    // Resources
    const GameConfig = struct { gravity: f32, max_speed: f32 };
    try world.putResource(GameConfig, .{ .gravity = 9.8, .max_speed = 100.0 });
    
    if (world.getResourcePtr(GameConfig)) |config| {
        config.gravity = 12.0; // Modify resource in-place
    }
}
```

## Core Concepts

### Entities

Entities are lightweight identifiers that represent game objects. They consist of an ID and generation number for safe recycling.

```zig
const entity = try world.createEntity();
const player = try world.createEntityWith(.{
    Position{ .x = 0, .y = 0 },
    Health{ .value = 100 },
});
```

### Components

Components are pure data structures that define the properties of entities.

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: i32, max_value: i32 };

// Attach components
try world.attachComponent(entity, Position, .{ .x = 10, .y = 20 });
try world.attachComponents(entity, .{
    Velocity{ .x = 1, .y = 0 },
    Health{ .value = 100, .max_value = 100 },
});
```

### Component Access Patterns

Sparze provides two access patterns for maximum flexibility:

#### Copy-based Access (Read-only)
```zig
// Returns a copy of the component
if (world.getComponent(entity, Position)) |pos| {
    std.debug.print("Position: ({}, {})\n", .{ pos.x, pos.y });
}
```

#### Pointer-based Access (Mutable)
```zig
// Returns a mutable pointer for in-place modification
if (world.getComponentPtr(entity, Position)) |pos| {
    pos.x += velocity.x * delta_time;
    pos.y += velocity.y * delta_time;
}
```

### Resources

Resources are global, singleton-like data that exists independently of entities.

```zig
const GameState = struct { score: i32, level: u32 };

// Store resource
try world.putResource(GameState, .{ .score = 0, .level = 1 });

// Access resource (copy)
if (world.getResource(GameState)) |state| {
    std.debug.print("Score: {}, Level: {}\n", .{ state.score, state.level });
}

// Modify resource in-place
if (world.getResourcePtr(GameState)) |state| {
    state.score += 100;
}
```

## Architecture

Sparze is built with a layered architecture for maximum performance and flexibility:

```
World                    <- High-level ECS API
├── EntityManager        <- Entity lifecycle management
├── SparseSetStorage     <- Component storage
└── ResourceStorage      <- Resource storage
    ├── AbstractSparseSet <- Type-erased component containers
    └── AbstractResource  <- Type-erased resource containers
        └── SparseSet     <- Actual sparse set implementation
```

### Sparse Set Storage

Components are stored in sparse sets, providing:
- **O(1) insertion, removal, and lookup**
- **Dense iteration** over entities with specific components
- **Memory efficiency** through component packing

### Type Erasure

The abstract layer allows storing different component types in the same containers while maintaining type safety at the API level.

## Systems Pattern

While Sparze doesn't enforce a specific system architecture, here's a recommended pattern:

```zig
fn movementSystem(world: *World, delta_time: f32) void {
    const entities = world.getAllEntities();
    for (entities) |entity| {
        if (world.getComponentPtr(entity, Position)) |pos| {
            if (world.getComponent(entity, Velocity)) |vel| {
                pos.x += vel.x * delta_time;
                pos.y += vel.y * delta_time;
            }
        }
    }
}

fn collisionSystem(world: *World) void {
    const entities = world.getAllEntities();
    for (entities) |entity1| {
        if (!world.hasComponent(entity1, Position)) continue;
        if (!world.hasComponent(entity1, Collider)) continue;
        
        for (entities) |entity2| {
            if (entity1.id == entity2.id) continue;
            // ... collision logic
        }
    }
}
```
## Performance Characteristics

- **Entity Creation**: O(1) amortized
- **Component Attachment**: O(1) amortized  
- **Component Access**: O(1)
- **Component Removal**: O(1)
- **Entity Destruction**: O(C) where C is the number of component types
- **Iteration**: O(N) where N is the number of entities with the component

## Memory Management

- Entities use ID recycling to prevent memory fragmentation
- Components are stored in dense arrays for cache efficiency
- Resources are managed with reference counting via allocators
- All allocations go through the provided allocator for easy debugging

## Thread Safety

Sparze is **not thread-safe** by design for maximum performance. If you need concurrent access:

- Use separate World instances per thread
- Implement your own synchronization around World operations
- Consider message-passing between systems instead of shared state

## License

This project is licensed under the MIT License - see the COPYING for details.
