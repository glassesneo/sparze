# Sparze - Compile-Time ECS

**Build & Test**:
```bash
zig build test                # Run tests
zig build examples            # Build examples
zig build run-{example-name}  # Run specific example
```

**What is Sparze**: Zero-cost compile-time ECS with strong type safety, cache-friendly memory layouts, and minimal API.

**CRITICAL**: Resources MUST be initialized before use (`initResources()` at startup). Accessing uninitialized resources triggers panic in Debug/ReleaseSafe builds.

**Module Documentation**:
- **Entity System**: @src/entity/CLAUDE.md - 32-bit entity lifecycle, version-based recycling
- **Storage**: @src/storage/CLAUDE.md - Component storage (SparseSet, TagStorage, EventStorage)
- **Query Filters**: @src/query/CLAUDE.md - Entity iteration (SingleQuery, Query, Group, TagQuery)
- **System Functions**: @src/system/CLAUDE.md - Parameter injection, Commands API, frame lifecycle

**Detailed Documentation**:
- **Architecture**: @docs/ARCHITECTURE.md - Core structures, World API, memory layout
- **Query Patterns**: @docs/QUERY_PATTERNS.md - Decision flowchart, filter selection, performance comparison
- **Entity Lifecycle**: @docs/ENTITY_LIFECYCLE.md - Creation/destruction flows, version recycling, safety mechanisms
- **Storage Internals**: @docs/STORAGE_INTERNALS.md - SparseSet/TagStorage implementation, pagination, group layout
- **System Patterns**: @docs/SYSTEM_PATTERNS.md - System examples, Commands API reference, frame lifecycle
- **Performance**: @docs/PERFORMANCE.md - Optimization strategies, benchmarking, anti-patterns

**Examples**: `examples/` directory contains `basic.zig`, `movement_example.zig`, `events.zig`, `resources.zig`, `tag_components.zig`, `multiple_groups.zig`, `serialization.zig`, and `benchmarks/`.

**Quick Start**:
```zig
const World = sparze.World(
    struct { Position, Velocity },      // Components
    struct { DeltaTime },                 // Resources
    struct {},                            // Events
    .{ struct { Position, Velocity } },  // Groups (compile-time)
);
var world = try World.init(allocator);
try world.initResources(.{ .delta_time = DeltaTime{ .value = 0.016 } });
try world.runSystem(movementSystem);
```
