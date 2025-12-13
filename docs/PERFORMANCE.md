# Performance Optimization Guide

Strategies and best practices for optimizing Sparze ECS applications.

## Core Performance Principles

Sparze is designed for performance through three mechanisms:

1. **Compile-time type resolution**: Zero runtime lookup overhead
2. **Cache-friendly memory layouts**: Pagination, dense packing, group organization
3. **Minimal indirection**: Direct array access where possible

This document covers how to leverage these principles effectively.

## Memory Optimization

### Tag Components for Markers

Use zero-sized structs for marker components to minimize memory usage.

**BAD** (wastes memory):
```zig
const Enemy = struct { _marker: u8 = 0 };  // 1 byte per entity
// 10,000 enemies = 10 KB + sparse overhead
```

**GOOD** (efficient):
```zig
const Enemy = struct {};  // 0 bytes
// 10,000 enemies = ~4 KB (entity IDs only)
```

**Memory savings**: ~98% reduction for sparse entity distributions (see docs/STORAGE_INTERNALS.md)

### Pre-allocation with reserve()

Avoid repeated allocations by pre-allocating storage before bulk operations.

**BAD** (many allocations):
```zig
fn spawnWave(commands: anytype) !void {
    for (0..10000) |_| {
        // Each createEntity may trigger reallocation
        const e = try commands.createEntity();
        try commands.addComponent(e, Position{ .x = 0, .y = 0 });
    }
}
```

**GOOD** (pre-allocated):
```zig
fn spawnWave(commands: anytype, world: *World) !void {
    // Pre-allocate storage for 10,000 entities
    try world.getSparseSetPtrMut(Position).reserve(10000);

    for (0..10000) |_| {
        const e = commands.createEntity();
        try commands.addComponent(e, Position{ .x = 0, .y = 0 });
    }
}
```

**Note**: Use `world.getSparseSetPtrMut(Component).reserve()` to pre-allocate; World has no `reserve()` helper.

**Impact**: Eliminates reallocation overhead, improves cache locality.

### Pagination Benefits

Sparze uses 4096-entity pages (4KB) for both SparseSet and TagStorage:

- **CPU cache friendly**: 4KB matches common L1 cache line size
- **Memory efficiency**: Allocate only needed pages
- **Fragmentation reduction**: Fixed-size allocations

**Example**: 100 active entities with sparse IDs (0-10000)
- Without pagination: 10,000 × sizeof(index) = ~40 KB allocated
- With pagination: 3 pages × 32 KB = ~96 KB, but only for active pages

**Trade-off**: Slight overhead for very dense allocations, but excellent for typical sparse patterns.

## Iteration Performance

### Group vs Query Performance

| Filter | Access Pattern | Cache Efficiency | Overhead | Throughput (entities/sec) |
|--------|---------------|------------------|----------|---------------------------|
| Group (owned) | Direct array | Excellent | None | 100M+ (memory bound) |
| Group (free) | Sparse lookup | Good | 1 indirection | 50M+ |
| Query | Sparse lookup + filter | Good | Filtering logic | 50M+ |
| SingleQuery | Direct array | Excellent | None | 100M+ (memory bound) |

### Hot Path Optimization with Groups

**BAD** (Query in hot path):
```zig
fn physicsSystem(query: Query(struct { Position, Velocity })) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const pos = query.getComponentMut(entity, Position);
        const vel = query.getComponent(entity, Velocity);
        // Sparse lookup × 2 per entity + filtering
        pos.x += vel.x;
        pos.y += vel.y;
    }
}
```

**GOOD** (Group for hot path):
```zig
fn physicsSystem(physics: Group(struct { Position, Velocity })) !void {
    const entities = physics.getEntities();
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);

    // Direct array iteration, perfect cache locality
    for (entities, positions, velocities) |_, *pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}
```

**Setup**:
```zig
try world.createGroup(struct { Position, Velocity });
```

**Speedup**: 2-3× for tight loops (depends on component size and filter complexity)

### Partial-Owning Groups for Mixed Access

Use partial-owning groups when some components are accessed frequently, others rarely:

```zig
// Own Position/Velocity (hot path), access Health occasionally
try world.createGroup(struct { Position, Velocity, Free(Health) });

fn physicsWithDamage(
    physics: Group(struct { Position, Velocity, Free(Health) })
) !void {
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);

    for (physics.getEntities(), positions, velocities) |entity, *pos, vel| {
        // Hot path: direct array access
        pos.x += vel.x;
        pos.y += vel.y;

        // Cold path: sparse lookup (acceptable overhead)
        if (pos.y < 0) {
            const health = physics.getComponentMut(entity, Health);
            health.hp -= 10;
        }
    }
}
```

**Best for**: Physics systems, rendering systems, AI systems with occasional cross-component access.

## System Organization

### Group Validation

Compile-time validation catches ownership conflicts early:

```zig
const PhysicsGroup = struct { Position, Velocity };
const RenderGroup = struct { Position, Sprite, Layer };  // Error! Position owned by Physics

// Instead:
const RenderGroup = struct { Sprite, Layer, Free(Position) };  // OK

// Validate at compile time
World.validateGroups(.{ PhysicsGroup, RenderGroup });
```

**Benefit**: Zero runtime cost, catches errors before shipping.

### System Ordering for Cache Locality

**BAD** (thrashing):
```zig
try world.runSystem(physicsSystem);   // Touches Position, Velocity
try world.runSystem(renderSystem);    // Touches Sprite, Layer
try world.runSystem(aiSystem);        // Touches Position, AIState
// Position touched twice, cache miss likely
```

**GOOD** (locality):
```zig
try world.runSystem(aiSystem);        // Position, AIState
try world.runSystem(physicsSystem);   // Position, Velocity (Position still hot)
try world.runSystem(renderSystem);    // Sprite, Layer
// Position accessed in sequence, better cache reuse
```

**Guideline**: Group systems that touch the same components together.

### Minimize Components in Groups

**BAD** (large group):
```zig
try world.createGroup(struct { A, B, C, D, E, F });
// Entity must have ALL 6 components to be in group
// Small group size, high invalidation cost
```

**GOOD** (focused group):
```zig
try world.createGroup(struct { A, B, Free(C), Free(D) });
// Owns A, B (hot path), accesses C, D (cold path)
// Larger group size, lower overhead
```

**Guideline**: Own 2-4 components, mark others as Free.

## Query Optimization

### Filter Selection Strategy

```
1. Single component → SingleQuery(T)
2. Hot path, multiple components → Group(struct { ... })
3. Need flexibility, occasional access → Query(struct { ... })
4. Special patterns (pairs, cross product) → Query with combinators
```

### Iteration Order Matters

Query iterates the **smallest required component set**:

```zig
// 10,000 Position, 100 Weapon, 10 PowerUp
Query(struct { Position, Weapon, PowerUp })
// Iterates PowerUp (10 entities), filters for Position + Weapon
// Not Position (10,000 entities)
```

**Optimization**: Put rare components in queries to reduce iteration count.

### Optional Components for Sparse Data

**BAD** (two queries):
```zig
fn damageSystem(
    with_armor: Query(struct { Health, Armor }),
    without_armor: Query(struct { Health, Exclude(Armor) }),
) !void {
    // Process with_armor...
    // Process without_armor...
}
```

**GOOD** (single query with optional):
```zig
fn damageSystem(query: Query(struct { Health, ?Armor })) !void {
    var it = query.iterator();
    while (it.next()) |entity| {
        const health = query.getComponentMut(entity, Health);
        const armor = query.getOptional(entity, Armor);

        var damage = 10;
        if (armor) |a| damage -= a.value;
        health.hp -= damage;
    }
}
```

**Benefit**: Single iteration, less code, similar performance.

## Event System Performance

### Frame Delay is Intentional

Events have 1-frame latency by design:

**Benefit**:
- Prevents circular dependencies
- Clean system ordering
- No mid-frame synchronization

**Cost**: 1-frame response delay (acceptable for most game logic)

**When it matters**: Real-time input (use Resources instead) or same-frame reactions (use direct component access).

### Event Storage Growth

EventStorage uses ArrayList with doubling strategy:

```zig
// Frame with 100 events
write_buffer capacity: 128 (next: 256)

// Frame with 1000 events
write_buffer capacity: 1024 (next: 2048)
```

**clearRetainingCapacity()** avoids reallocation:
```zig
pub fn clear(self: *EventStorage(E)) void {
    self.write_buffer.clearRetainingCapacity();
    // Memory retained for next frame
}
```

**Trade-off**: Memory retained across frames, but eliminates allocation overhead.

## Resource Access Patterns

### Resource vs Component

**Use Resource for**:
- Global game state (score, level, time)
- Configuration (difficulty, settings)
- Singletons (input manager, audio system)

**Use Component for**:
- Per-entity data (position, health, AI state)
- Data tied to entity lifetime

**Why**: Resources are zero-cost singletons, components are associated with entities.

### Resource Initialization

**CRITICAL**: Initialize resources at startup to avoid runtime panics.

```zig
fn startup(commands: anytype) !void {
    try commands.initResources(.{
        .delta_time = DeltaTime{ .value = 0.016 },
        .game_state = GameState{ .score = 0 },
    });
}
```

**Cost of uninitialized access**:
- **Debug/ReleaseSafe**: Panic (caught early)
- **ReleaseFast**: Undefined memory (zeroes, hard to debug)

## Benchmarking and Profiling

### Benchmark Examples

See `examples/benchmarks/` for performance tests:

- `group_iteration.zig`: Group vs Query iteration
- `sparse_vs_dense.zig`: Sparse vs dense entity allocation
- `tag_storage.zig`: TagStorage vs SparseSet for markers

**Run benchmarks**:
```bash
zig build run-benchmark-group_iteration
zig build run-benchmark-sparse_vs_dense
```

### Profiling Tips

1. **Use ReleaseFast** for accurate measurements:
   ```bash
   zig build -Doptimize=ReleaseFast
   ```

2. **Measure iteration only** (exclude setup):
   ```zig
   const start = std.time.nanoTimestamp();
   for (0..iterations) |_| {
       try world.runSystem(physicsSystem);
   }
   const elapsed = std.time.nanoTimestamp() - start;
   ```

3. **Test with realistic data**:
   - Sparse entity distributions
   - Typical component counts
   - Realistic system ordering

## Performance Checklist

**Memory**:
- [ ] Use tag components (zero-sized structs) for markers
- [ ] Pre-allocate with `getSparseSetPtrMut(Component).reserve()` before bulk operations
- [ ] Monitor memory usage with pagination in mind

**Iteration**:
- [ ] Use Groups for hot-path multi-component iteration
- [ ] Use SingleQuery for single-component iteration
- [ ] Use partial-owning Groups for mixed access patterns
- [ ] Validate groups at startup with `validateGroups()`

**System organization**:
- [ ] Order systems to maximize cache locality
- [ ] Minimize owned components in groups (2-4 components)
- [ ] Group systems touching same components together

**Resources**:
- [ ] Initialize all resources at startup
- [ ] Use Resources for global state, Components for per-entity data
- [ ] Check initialization with `isResourceInitialized()` for optional resources

**Events**:
- [ ] Understand 1-frame latency is by design
- [ ] Use Resources for same-frame communication if needed
- [ ] Accept clearRetainingCapacity() memory retention

## Common Performance Anti-Patterns

1. **Over-using Query in hot paths**:
   - Problem: Sparse lookup overhead
   - Solution: Create Groups for frequently iterated component combinations

2. **Creating too many small groups**:
   - Problem: High maintenance overhead, entity fragmentation
   - Solution: Own 2-4 core components, use Free for others

3. **Not pre-allocating**:
   - Problem: Repeated reallocation during bulk operations
   - Solution: Call `getSparseSetPtrMut(Component).reserve()` before spawning entities

4. **Ignoring system ordering**:
   - Problem: Cache thrashing
   - Solution: Group systems by component access patterns

5. **Using regular components for markers**:
   - Problem: Memory waste
   - Solution: Use zero-sized structs (tags)

See also:
- docs/QUERY_PATTERNS.md for iteration strategies
- docs/STORAGE_INTERNALS.md for memory layout details
- docs/ARCHITECTURE.md for design principles
