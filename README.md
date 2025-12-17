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
  - **SingleTag**: Iterate over entities with a single tag component
  - **Query**: Runtime intersection queries for multiple components with optional component support (no setup required)
  - **TagQuery**: Runtime intersection queries for multiple tag components with optional tag support
  - **Group**: Optimized multi-component iteration with cache-friendly layout
  - **CombinationIterator**: Iterate over all unique pairs of entities from a query
  - Automatic query resolution and dependency injection
  - Support for multiple query parameters per system
  - Optional components/tags using `?Component` or `?Tag` syntax

- **World State Persistence**
  - Binary serialization for complete world state (entities, components, resources, events)
  - Hybrid approach: automatic POD serialization, custom serializers for complex types
  - Type-safe with FNV-1a hash validation
  - CRC32 checksums for data integrity
  - High-performance buffered I/O (64KB buffers)
  - Available through both World and Commands APIs

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

// Declare group type constant (recommended best practice)
const MovementGroup = struct { Position, Velocity };

// Define World with component types, resources, events, and groups
const World = sparze.World(
    .{ Position, Velocity },      // Components
    .{},                          // Resources (none in this example)
    .{},                          // Events (none in this example)
    .{ MovementGroup },           // Groups (compile-time)
);

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
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            const health = query.getComponentMut(entity, Health);
            // Apply damage based on position
            const distance = @sqrt(pos.x * pos.x + pos.y * pos.y);
            if (distance > 50.0) {
                health.hp -= 5;
            }
        }
    }
}

// Query with optional components (using ?Component syntax)
fn movementSystem(query: sparze.Query(struct { Position, Velocity, ?Health })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponentMut(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            
            // Apply movement
            pos.x += vel.x * 0.016;
            pos.y += vel.y * 0.016;
            
            // Optional: slow down if injured
            if (query.getOptional(entity, Health)) |health| {
                if (health.hp < 30) {
                    pos.x -= vel.x * 0.008; // Half speed
                    pos.y -= vel.y * 0.008;
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
- Some components are optional (use `?Component` syntax)

#### TagQuery - Multi-Tag Runtime Intersection

For querying multiple tag components:

```zig
fn bossEnemySystem(query: sparze.TagQuery(struct { Enemy, Boss })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Process entities that are both enemies and bosses
            std.debug.print("Boss enemy: {}\n", .{entity});
        }
    }
}

// TagQuery with optional tags (using ?Tag syntax)
fn enemyAISystem(query: sparze.TagQuery(struct { Enemy, ?Boss, ?Elite })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Base enemy AI for all enemies
            
            // Check for optional tags
            if (query.hasOptional(entity, Boss)) {
                // Enhanced boss AI
            }
            
            if (query.hasOptional(entity, Elite)) {
                // Elite enemy behavior
            }
        }
    }
}
```

**Use TagQuery when:**
- You need multi-tag queries (e.g., entities with both Enemy and Boss tags)
- All components are tags (zero-sized markers)
- You want explicit type safety for tag-only queries
- Some tags are optional (use `?Tag` syntax)

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
| **Optional Support** | ❌ No | ❌ No | ✅ Yes (`?C`) | ✅ Yes (`?Tag`) | ❌ No |
| **Setup Required** | ❌ None | ❌ None | ❌ None | ❌ None | ✅ `createGroup()` |
| **Manual Filtering** | ❌ No | ❌ No | ✅ Yes (`filter`) | ✅ Yes (`filter`) | ❌ No |
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

const World = sparze.World(.{ Position, Player, Enemy, Active }, .{}, .{}, .{});

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
        if (query.filter(entity)) {
            // Process entities that are both enemies and bosses
        }
    }
}

// Combine tags with regular components using Query
fn activePlayerSystem(query: sparze.Query(struct { Position, Player, Active })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
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

### Resources

Resources are global, singleton data that can be accessed across systems. Unlike components which are attached to entities, resources exist independently and are shared by all systems. They're perfect for storing game state, configuration, and data that doesn't belong to any specific entity.

```zig
const std = @import("std");
const sparze = @import("sparze");

// Define resource types
const DeltaTime = struct { dt: f32 };
const Score = struct { points: i32, combo: i32 };
const GameConfig = struct {
    gravity: f32,
    max_speed: f32,
};

// Define components
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

// Create world with both components and resources
const World = sparze.World(
    .{ Position, Velocity },              // Components
    .{ DeltaTime, Score, GameConfig },    // Resources
    .{},                                   // Events
    .{},                                   // Groups
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Initialize resources - MUST be done before use
    try world.setResource(DeltaTime, .{ .dt = 0.016 }); // 60 FPS
    try world.setResource(Score, .{ .points = 0, .combo = 0 });
    try world.setResource(GameConfig, .{ .gravity = 9.8, .max_speed = 100.0 });

    // Systems can access resources alongside queries
    try world.runSystem(physicsSystem);
    try world.runSystem(scoreSystem);

    // Access resources outside systems
    const current_score = world.getResource(Score);
    std.debug.print("Final Score: {d}\n", .{current_score.points});
}

// System with resource and query parameters
fn physicsSystem(
    delta: sparze.Resource(DeltaTime),
    config: sparze.Resource(GameConfig),
    query: sparze.SingleQuery(Position),
) !void {
    const dt = delta.value.dt;
    const max_speed = config.value.max_speed;
    
    for (query.components) |*pos| {
        // Use resources in system logic
        pos.y -= config.value.gravity * dt;
    }
}

// System that mutates resources
fn scoreSystem(score: sparze.Resource(Score)) !void {
    score.value.points += 100;
    score.value.combo += 1;
}
```

**Resource API**:
- `world.setResource(R, resource)` - Initialize or update a resource
- `world.getResource(R)` - Get resource by value (copy)
- `world.getResourcePtr(R)` - Get const pointer to resource
- `world.getResourcePtrMut(R)` - Get mutable pointer to resource
- `sparze.Resource(R)` - System parameter type for resource injection

**Common Use Cases**:
- **Time**: Delta time, total elapsed time, frame count
- **Game state**: Score, level, lives, game mode
- **Configuration**: Physics constants, difficulty settings, game rules
- **Input**: Keyboard/mouse state, controller input
- **Rendering**: Camera transform, viewport size
- **Audio**: Volume settings, music state

**Best Practices**:
- Always initialize resources with `setResource()` before running systems that use them
- Use resources for global data, components for per-entity data
- Keep resources focused and single-purpose
- Resources are passed to systems as mutable pointers via `Resource(T).value`

### Optional Components and Tags

Both `Query` and `TagQuery` support optional components/tags using the `?Component` or `?Tag` syntax. This allows queries to match entities based on required components while optionally checking for additional ones.

```zig
// Query with optional components
fn combatSystem(query: sparze.Query(struct { Health, ?Shield })) !void {
    const damage = 15;
    
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const health = query.getComponentMut(entity, Health);
            var actual_damage = damage;
            
            // Shield absorbs damage if present
            if (query.getOptionalMut(entity, Shield)) |shield| {
                const absorbed = @min(shield.value, actual_damage);
                shield.value -= absorbed;
                actual_damage -= absorbed;
            }
            
            health.hp -= actual_damage;
        }
    }
}

// TagQuery with optional tags
fn enemyProcessingSystem(query: sparze.TagQuery(struct { Enemy, ?Boss, ?Active })) !void {
    var stats = .{ .regular = 0, .boss = 0, .active = 0 };
    
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            if (query.hasOptional(entity, Boss)) {
                stats.boss += 1;
            } else {
                stats.regular += 1;
            }
            
            if (query.hasOptional(entity, Active)) {
                stats.active += 1;
            }
        }
    }
}
```

**Optional Component/Tag API**:
- **Required components**: `getComponent()` / `getComponentMut()` - asserts component exists
- **Optional components**: `getOptional()` / `getOptionalMut()` - returns `?C` or `?*C`
- **Optional tags**: `hasOptional(entity, Tag)` - returns `bool`
- **Filtering**: `filter()` only checks required (non-optional) fields

**Benefits**:
- Match entities with required components while optionally checking others
- Query optimization only considers required components/tags for iteration
- Explicit `?Component` syntax shows optional components at compile time
- Avoid multiple separate queries when some components are optional

**Use cases**:
- Systems that apply special behavior when certain components exist (e.g., damage absorption with optional Shield)
- AI systems with base behavior and optional enhancements (e.g., Enemy with optional Boss or Elite behaviors)
- Status systems that display all available information (e.g., entity info with optional Health, Armor, Status effects)

### Serialization and Persistence

Sparze provides high-performance binary serialization for complete world state persistence. The system supports POD types automatically and allows custom serializers for complex types.

#### World API

```zig
const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Score = struct { points: i32 };

const World = sparze.World(
    .{ Position, Velocity },
    .{ Score },
    .{},
    .{},
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // ... populate world with entities and components ...
    try world.setResource(Score, .{ .points = 100 });

    // Save world state
    const save_file = try std.fs.cwd().createFile("save.spze", .{});
    defer save_file.close();
    try world.serialize(save_file.writer());

    // Load world state
    const load_file = try std.fs.cwd().openFile("save.spze", .{});
    defer load_file.close();
    try world.deserialize(load_file.reader());

    // Note: Groups must be recreated after deserialization
    try world.createGroup(struct { Position, Velocity });
}
```

#### Commands API

For architectures where systems only access Commands (not World directly), use the Commands serialization API:

```zig
// Save system - uses Commands only
fn saveGameSystem(commands: anytype) !void {
    try commands.serializeToFile("save.spze");
}

// Load system - uses Commands only
fn loadGameSystem(commands: anytype) !void {
    try commands.deserializeFromFile("save.spze");
}

// Run in game loop
try world.runSystem(saveGameSystem);
try world.endFrame();

// Later...
try world.runSystem(loadGameSystem);
try world.endFrame();
```

**Serialization API**:
- `world.serialize(writer)` / `commands.serialize(writer)` - Serialize to writer
- `world.deserialize(reader)` / `commands.deserialize(reader)` - Deserialize from reader
- `world.serializeToFile(path)` / `commands.serializeToFile(path)` - Convenience: save to file
- `world.deserializeFromFile(path)` / `commands.deserializeFromFile(path)` - Convenience: load from file

#### Custom Serializers

For types that aren't POD (contain pointers, slices, or dynamic allocations), provide a custom `Serializer`:

```zig
const Name = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    // Custom serializer - only writes actual name length
    pub const Serializer = struct {
        pub fn serialize(name: Name, writer: anytype) !void {
            try writer.writeInt(u16, @intCast(name.len), .little);
            try writer.writeAll(name.buffer[0..name.len]);
        }

        pub fn deserialize(reader: anytype) !Name {
            const len = try reader.readInt(u16, .little);
            var name = Name{};
            name.len = len;
            try reader.readNoEof(name.buffer[0..len]);
            return name;
        }
    };
};
```

**What Gets Serialized**:
- Entities (complete entity registry including version numbers and free list state)
- Components (all component data for regular and tag components)
- Resources (all initialized resource values)
- Events (read buffer only - events from previous frame)

**What Does NOT Get Serialized**:
- Groups (must call `createGroup()` after deserialization)
- Command buffers (cleared after serialization)
- Event write buffer (only read buffer is serialized)

**Features**:
- **Type safety**: FNV-1a hash validation ensures loaded data matches expected types
- **Data integrity**: CRC32 checksums detect file corruption
- **Performance**: Buffered I/O (64KB buffers) minimizes syscalls
- **Hybrid approach**: Automatic POD serialization, custom serializers for complex types
- **Binary format**: `.spze` files (Sparze serialization format)

See `examples/serialization.zig` and `examples/commands_serialization.zig` for complete examples.

## Core Concepts

**Entities**: Lightweight 32-bit identifiers (16-bit index + 16-bit version)

**Components**: Plain Zig structs containing data attached to entities
- **Regular components**: Structs with fields, stored in sparse sets
- **Tag components**: Empty structs (`struct {}`), stored in bit sets for minimal memory usage

**Resources**: Global, singleton data accessible across all systems
- Defined at World creation time alongside components
- Must be initialized with `setResource()` before use
- Accessed in systems via `Resource(T)` parameter type

**Systems**: Functions that operate on entities with specific component combinations and/or access global resources

**Query Filters**:
- **SingleQuery(Component)**: Fast iteration over entities with a single regular component
- **SingleTag(Tag)**: Fast iteration over entities with a single tag component
- **Query(struct { A, B, ?C, ... })**: Flexible runtime intersection for multiple components (mixed tags and regular components, supports optional components)
  - **CombinationIterator**: Via `query.combinations()` - iterates over all unique pairs of entities from a Query
- **TagQuery(struct { A, B, ?C, ... })**: Runtime intersection for multiple tag components only (supports optional tags)
- **Group(struct { A, B })**: Optimized multi-component iteration requiring upfront `createGroup()` call for maximum performance

Query filters are types that filter entities based on component composition, used as parameters in system functions to specify which entities the system operates on.

## Examples

Explore the `examples/` directory for comprehensive demonstrations:

- `basic.zig` - Entity and component basics
- `combination_iterator.zig` - Iterating over all unique pairs of entities (collision detection example)
- `cross_product.zig` - Cross-product iteration between different entity types
- `events.zig` - Event system demonstration with collision detection
- `exclude_example.zig` - Exclude modifier for filtering entities
- `movement_example.zig` - Simple movement system using groups
- `multiple_groups.zig` - Multiple non-overlapping groups with validation
- `optional_components.zig` - Optional components and tags demonstration
- `plugin_architecture.zig` - Plugin-style architecture
- `resources.zig` - Global resources and state management
- `serialization.zig` - World state persistence with custom serializers
- `commands_serialization.zig` - Save/load using Commands API only
- `system_operations.zig` - System patterns and multi-query examples
- `tag_components.zig` - Tag component usage and patterns

Run all examples:
```bash
zig build run-examples
```

Run a specific example:
```bash
zig build run-basic
zig build run-combination_iterator
zig build run-cross_product
zig build run-events
zig build run-exclude_example
zig build run-movement_example
zig build run-multiple_groups
zig build run-optional_components
zig build run-plugin_architecture
zig build run-resources
zig build run-serialization
zig build run-commands_serialization
zig build run-system_operations
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
