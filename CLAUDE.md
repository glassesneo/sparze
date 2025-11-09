# CLAUDE.md

A concise guide for working with the Sparze codebase (Zig ECS library).

Build commands

```bash
# Run tests
zig build test

# Build all examples
zig build examples

# Run all examples sequentially
zig build run-examples

# Run a specific example
zig build run-{example-name}
```

What Sparze is

- A compile-time Entity Component System (ECS) in Zig: component and resource types are known at compile time for zero runtime lookup overhead and strong type safety.

Core data structures (where to look)

- Entity (`src/core/entity.zig`): 32-bit id (16-bit index, 16-bit version) with version-based recycling and an `EntityRegistry` free list.
- SparseSet (`src/core/sparse_set.zig`): paginated sparse array (4096 entities/page), packed dense arrays, O(1) lookups, and group-aware layout for fast iteration.
- TagStorage (`src/core/tag_storage.zig`): optimized bitset-backed storage for zero-sized tag components (1 bit/entity) and packed entity arrays.

World API (overview)

- World is parameterized by component, resource, and event tuples, e.g. `World(struct { Position, Velocity }, struct { DeltaTime }, struct { Collision })`.
- Component/resource/event IDs are assigned at compile time; component storage is directly accessible (no dynamic lookup).
- Resources are singletons that must be initialized via `setResource()` before use.

Systems and injection

- System functions receive injected parameters from the World. Common parameter types:
  - Query filters: `SingleQuery(T)`, `SingleTag(T)`, `Query(struct { ... })`, `TagQuery(struct { ... })`, `Group(struct { ... })` (groups require `createGroup()`).
  - `Resource(T)`: access to global resources inside systems.
  - `anytype` parameter: receives `Commands(World)` for deferred operations.
  - `std.mem.Allocator`: World's allocator for temporary allocations.
- Convenience: `world.runSystem(systemFn)` and `createSystemFunction(World, fn)`.
- Validate groups at compile time using `World.validateGroups(...)` to ensure groups do not overlap.

Commands API

- `Commands(World)` provides deferred entity/component operations via `CommandBuffer`.
- Systems receive commands via `anytype` parameter: `fn system(commands: anytype) !void`.
- Operations are executed at `world.endFrame()`, ensuring safe iteration.
- Group management: `commands.createGroup(GroupComponents)` creates groups from within systems.

Queries & iterators (summary)

- `SingleQuery(C)`: iterate a single regular component (packed array).
- `SingleTag(T)`: iterate entities with a tag (bitset-backed).
- `Query(struct { ... })`: ad-hoc multi-component query supporting optional (`?T`) and exclude (`Exclude(T)`) modifiers.
- `TagQuery(struct { ... })`: like `Query` but tag-only.
- `Group(struct { ... })`: pre-organized, fastest multi-component iteration (requires creation and validation).
- Pair iterators:
  - `combinations()` — unique pairs within one query (i < j).
  - `crossProduct(&other)` — Cartesian product across two queries (N×M pairs).

Modifiers

- Optional (`?T`): match regardless of presence; access via `getOptional()`/`getOptionalMut()`.
- Exclude (`Exclude(T)`): filter out entities that have `T`.
- Modifiers are supported by `Query` and `TagQuery` but not by `SingleQuery`, `SingleTag`, or `Group`.

Resources

- Global, singleton values accessible via `Resource(T)` in systems.
- API highlights: `world.setResource(T, value)`, `world.getResource(T)`, `world.getResourcePtrMut(T)`.
- Best practice: initialize resources after creating the World; prefer single-purpose resources.

Events

- Frame-delayed events: events written in frame N are readable in frame N+1.
- Use `EventWriter(E)` to enqueue events and `EventReader(E)` to read the previous frame's events.
- Lifecycle: call `world.beginFrame()` (swap buffers), run systems, then `world.endFrame()`.

Serialization (essential points)

- High-performance binary serialization/deserialization for complete world state (entities, components, resources, events read buffer).
- POD types are serialized automatically; non-POD types require a custom `Serializer` (see `examples/serialization.zig`).
- Type safety via metadata hash; CRC32 checksum for integrity.
- **Exclusion feature**: Mark types with `pub const serialized = false` to exclude them from serialization (see `examples/serialization_exclusion.zig`).
- Things not serialized: groups (must recreate after load), command buffers, and the event write buffer.
- Best practice: serialize between frames (after `endFrame()`), and recreate groups with `createGroup()` after deserialization.

Performance notes & best practices

- Use `reserve()` on sparse sets before bulk inserts to avoid reallocations.
- Prefer `Group` for hot-path, multi-component iteration.
- Use tag components for marker/state flags (1 bit per entity) to save memory.
- Declare group type constants and validate groups at compile time to avoid overlap and duplicate definitions.
- Define systems as plain functions that accept injected parameters and call `world.runSystem()`.

Where to find examples

- `examples/` contains comprehensive usage and performance benchmarks.

Notes for contributors

- Read source files in `src/` for implementation details referenced above.
- Keep changes focused and consistent with Zig idioms used in the repo.
