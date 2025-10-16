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
  - Tag storage for zero-sized marker components (1 bit per entity)

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

// Define component types
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

// Define World with all component types
const World = sparze.World(struct { Position, Velocity });

// Declare group type constant (recommended best practice)
const MovementGroup = struct { Position, Velocity };

// Define system as plain function
fn movementSystem(group: sparze.Group(MovementGroup)) !void {
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

### Query Filters

Sparze provides multiple query filter types for different use cases:

#### SingleQuery - Single Component Iteration

For regular components (structs with data):

```zig
fn healthSystem(query: sparze.SingleQuery(Health)) !void {
    for (query.entities, query.components) |entity, health| {
        std.debug.print("Entity {} has {} HP\n", .{ entity, health.hp });
    }
}
```

#### SingleTag - Single Tag Iteration

For tag components (zero-sized marker components):

```zig
fn playerSystem(query: sparze.SingleTag(Player)) !void {
    for (query.entities) |entity| {
        std.debug.print("Player entity: {}\n", .{entity});
    }
}
```

**Use SingleTag when:**
- Iterating over entities with a single tag component
- Maximum type safety for tag-only queries

#### Query - Runtime Intersection (No Setup)

```zig
fn combatSystem(query: sparze.Query(struct { Position, Health })) !void {
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
- Mixing tags and regular components

#### TagQuery - Multi-Tag Runtime Intersection

For querying multiple tag components:

```zig
fn bossEnemySystem(query: sparze.TagQuery(struct { Enemy, Boss })) !void {
    for (query.entities) |entity| {
        if (query.hasAllTags(entity)) {
            // Process entities that are both enemies and bosses
            std.debug.print("Boss enemy: {}\n", .{entity});
        }
    }
}
```

**Use TagQuery when:**
- You need multi-tag queries (e.g., entities with both Enemy and Boss tags)
- All components are tags (zero-sized markers)
- You want explicit type safety for tag-only queries

#### Group - Optimized Multi-Component Iteration

```zig
// Best practice: Declare group type constant
const MovementGroup = struct { Position, Velocity };

fn movementSystem(group: sparze.Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x * 0.016;
        pos.y += vel.y * 0.016;
    }
}

// In main():
try world.createGroup(MovementGroup); // Required setup
try world.runSystem(movementSystem);
```

**Use Group when:**
- Query runs frequently (every frame)
- Maximum iteration performance is critical
- Component combination is known upfront

#### Comparison Table

| Feature | SingleQuery | SingleTag | Query | TagQuery | Group |
|---------|------------|-----------|-------|----------|-------|
| **Component Types** | Regular (1) | Tag (1) | Mixed (2+) | Tag only (2+) | Regular (2+) |
| **Setup Required** | ❌ None | ❌ None | ❌ None | ❌ None | ✅ `createGroup()` |
| **Manual Filtering** | ❌ No | ❌ No | ✅ Yes (`hasAllComponents`) | ✅ Yes (`hasAllTags`) | ❌ No |
| **Component Access** | ✅ Direct | ❌ N/A (zero-sized) | ✅ Via methods | ❌ N/A (zero-sized) | ✅ Direct arrays |
| **Iteration Speed** | ⚡ Fast | ⚡ Fast | ⚠️ Moderate | ⚠️ Moderate | ⚡⚡ Fastest |
| **Memory Layout** | Packed | Bit set | Sparse set | Bit set | Cache-optimized |
| **Use Case** | Single component | Single tag | Ad-hoc multi-query | Multi-tag queries | Hot path iteration |

### Tag Components

Tag components are zero-sized marker components (empty structs) used for entity categorization, state flags, or filtering. They consume only 1 bit per entity and support all query operations.

```zig
// Define tag components as empty structs
const Player = struct {};
const Enemy = struct {};
const Active = struct {};

const World = sparze.World(struct { Position, Player, Enemy, Active });

var world = World.init(allocator);
defer world.deinit();

// Create entity with tags
const entity = world.createEntity();
try world.addTag(entity, Player);
try world.addTag(entity, Active);

// Or use generic method (works for both tags and regular components)
try world.addComponent(entity, Player, .{});

// Check for tags
if (world.hasComponent(entity, Player)) {
    // Entity is a player
}

// Query entities with specific tags using SingleTag
fn playerSystem(query: sparze.SingleTag(Player)) !void {
    for (query.entities) |entity| {
        // Process all player entities
    }
}

// Query entities with multiple tags using TagQuery
fn bossEnemySystem(query: sparze.TagQuery(struct { Enemy, Boss })) !void {
    for (query.entities) |entity| {
        if (query.hasAllTags(entity)) {
            // Process entities that are both enemies and bosses
        }
    }
}

// Combine tags with regular components using Query
fn activePlayerSystem(query: sparze.Query(struct { Position, Player, Active })) !void {
    for (query.entities) |entity| {
        if (query.hasAllComponents(entity)) {
            // Process active players with positions
        }
    }
}
```

**Common Tag Use Cases**:
- **Entity types**: `Player`, `Enemy`, `NPC`, `Boss`
- **State flags**: `Active`, `Disabled`, `Selected`, `Paused`
- **Categories**: `UI`, `Renderable`, `Collidable`, `Static`
- **Events**: `Damaged`, `Died`, `LeveledUp` (single-frame markers)

**Performance**: Tags use bit sets for O(1) membership checking and are extremely memory-efficient, consuming only 1 bit per entity index instead of storing full component data.

## Core Concepts

**Entities**: Lightweight 32-bit identifiers (16-bit index + 16-bit version)

**Components**: Plain Zig structs containing data
- **Regular components**: Structs with fields, stored in sparse sets
- **Tag components**: Empty structs (`struct {}`), stored in bit sets for minimal memory usage

**Systems**: Functions that operate on entities with specific component combinations

**Query Filters**:
- **SingleQuery(Component)**: Fast iteration over entities with a single regular component
- **SingleTag(Tag)**: Fast iteration over entities with a single tag component
- **Query(struct { A, B, ... })**: Flexible runtime intersection for multiple components (mixed tags and regular components)
- **TagQuery(struct { A, B, ... })**: Runtime intersection for multiple tag components only
- **Group(struct { A, B })**: Optimized multi-component iteration requiring upfront `createGroup()` call for maximum performance

Query filters are types that filter entities based on component composition, used as parameters in system functions to specify which entities the system operates on.

## Examples

Explore the `examples/` directory for comprehensive demonstrations:

- `basic.zig` - Entity and component basics
- `plugin_architecture.zig` - Plugin-style architecture
- `system_operations.zig` - System patterns and multi-query examples
- `tag_components.zig` - Tag component usage and patterns

Run all examples:
```bash
zig build run-examples
```

Run a specific example:
```bash
zig build run-basic
zig build run-tag_components
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

- **O(1) component access** via paginated sparse sets with bit-shift optimized indexing
- **Cache-friendly iteration** with packed component arrays
- **Group optimization** for multi-component queries
- **Zero runtime overhead** with compile-time component registration
- **Optimized command buffer** with inline storage (77.8x faster than heap allocation)
- **Tag component optimization** with bit sets (1 bit per entity, O(1) membership checks)
- **Reserve API** for bulk insertion optimization

### Performance Characteristics

Recent benchmarks (10,000-100,000 iterations) show:
- **Component lookups**: ~0.09µs per operation
- **Component insertion**: ~0.75µs per operation (with 4 components)
- **Component removal**: ~0.35µs per operation
- **Group iteration**: ~0.43µs per 100 entities
- **Command buffer**: ~0.86µs per command (98.7% faster with inline storage)

### Bulk Insertion Optimization

For large-scale entity creation (e.g., loading scenes), use the `reserve()` API to pre-allocate capacity and eliminate reallocation overhead:

```zig
// Pre-reserve capacity for better performance
try world.getSparseSetPtr(Position).reserve(10000);
try world.getSparseSetPtr(Velocity).reserve(10000);
try world.getTagStoragePtr(Player).reserve(10000); // Also works for tags

// Now bulk insert without reallocations
for (0..10000) |_| {
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(entity, Velocity, .{ .x = 1.0, .y = 1.0 });
    try world.addTag(entity, Player);
}
```

This eliminates ArrayList reallocation overhead during bulk operations.

## Requirements

- Zig 0.15.1 or later

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues or PRs.
