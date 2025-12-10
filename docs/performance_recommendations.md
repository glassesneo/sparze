# Performance Optimization Recommendations for Sparze

This document outlines performance optimization opportunities identified through code analysis and benchmarking.

## Implemented Optimizations ✓

### 1. Iterator Filter Caching
**Location**: `src/query/filter.zig`
- **CombinationIterator**: Added `i_cached` flag to cache entity_i filter result across inner loop iterations
- **CrossProductIterator**: Added `entity1_cached` flag to cache entity1 filter result across inner loop iterations

**Impact**: Reduces redundant filter calls from O(N×M) to O(N+M) for the outer entity, particularly beneficial for:
- Collision detection with large entity counts
- Cross-product queries (projectiles × enemies)
- Combination iteration over entity pairs

**Performance Gain**: Estimated 15-30% improvement in benchmark 2 & 3 of `performance_bottleneck_benchmark.zig`

## Recommended Future Optimizations

### 2. Batch Entity Processing
**Priority**: Medium
**Complexity**: Medium

Add batch processing methods for common operations to reduce function call overhead:

```zig
// In World
pub fn addComponentsBatch(self: *Self, entities: []const Entity, comptime C: type, component: C) !void {
    const storage = self.getSparseSetPtrMut(C);
    const component_id = comptime getComponentId(C);
    
    // Reserve capacity upfront
    try storage.reserve(storage.packed_array.items.len + entities.len);
    
    for (entities) |entity| {
        try storage.insert(entity, component);
    }
    
    // Update groups once for all entities
    for (entities) |entity| {
        self.updateGroupsOnAdd(entity, component_id);
    }
}
```

**Benefits**:
- Reduces per-entity overhead
- Enables better memory allocation patterns
- Useful for spawning large groups of similar entities

### 3. Query Result Caching
**Priority**: Low
**Complexity**: High

For systems that query the same component combinations multiple times per frame, cache the filtered entity list:

```zig
pub const CachedQuery = struct {
    entities: []Entity,
    valid: bool = false,
    
    pub fn refresh(self: *CachedQuery, query: anytype) void {
        // Rebuild entity list only when invalidated
    }
};
```

**Trade-offs**:
- Adds memory overhead for cached results
- Requires invalidation logic when entities/components change
- Only beneficial when same query runs 10+ times per frame

### 4. SIMD Optimization for Filter Checks
**Priority**: Low
**Complexity**: High

For large entity counts, vectorize the filter checking loop:

```zig
// Use SIMD to check multiple entities' component presence simultaneously
// Particularly useful for TagQuery with bitset operations
```

**Benefits**:
- 2-4x speedup for large tag queries
- Especially effective with AVX2/AVX-512

**Challenges**:
- Platform-specific code
- Limited gain for small entity counts (<1000)
- Zig's SIMD support still evolving

### 5. Hot/Cold Data Splitting
**Priority**: Medium
**Complexity**: Medium

Split frequently-accessed component data from rarely-accessed data:

```zig
const Transform = struct {
    // Hot: accessed every frame
    position: Vec3,
    rotation: Quat,
    
    // Could be split to separate component:
    // - parent: EntityRef (rarely changes)
    // - metadata: TransformMetadata (debug info)
};
```

**Benefits**:
- Better cache utilization
- Reduced memory bandwidth usage

### 6. Parallel System Execution
**Priority**: High (Future Feature)
**Complexity**: Very High

Enable parallel execution of systems that don't conflict:

```zig
// Dependency graph analysis
pub fn runSystemsParallel(systems: []const System) !void {
    // Analyze read/write dependencies
    // Schedule non-conflicting systems to thread pool
}
```

**Benefits**:
- Massive performance gains on multi-core systems
- Essential for large-scale games

**Challenges**:
- Complex dependency analysis
- Thread synchronization overhead
- API changes required

## Micro-Optimizations Already Present ✓

The codebase already includes several micro-optimizations:

1. **Inline storage for command buffer** (line 34, system.zig): Avoids heap allocations for small components
2. **Bit shift indexing** (sparse_set.zig): Fast page/slot calculation using `>>` and `&`
3. **Compile-time unrolling** (filter.zig): `inline for` unrolls filter checks
4. **Direct page/slot checking** (sparse_set.zig:172): Optimized to avoid redundant `hasIndex()` calls
5. **Smallest set iteration** (filter.zig:145): Query iterates smallest component set first
6. **Release mode checks** (filter.zig:217): `isAlive()` only in Debug/ReleaseSafe builds

## Benchmarking Guidelines

When adding optimizations:

1. **Measure before and after** using existing benchmarks
2. **Test multiple entity counts**: 100, 1000, 10000, 100000
3. **Profile in Release mode** with `-Doptimize=ReleaseFast`
4. **Consider memory overhead**: Faster doesn't always mean better
5. **Document trade-offs**: Explain when to use vs. not use

## Performance Best Practices for Users

Document these patterns in user-facing docs:

### Use `reserve()` for Bulk Operations
```zig
try world.getSparseSetPtr(Position).reserve(10000);
try world.getSparseSetPtr(Velocity).reserve(10000);
// Now bulk create without reallocations
```

### Prefer Groups for Hot Paths
```zig
// Setup once
try world.createGroup(struct { Position, Velocity });

// Fast iteration every frame
fn movementSystem(group: Group(struct { Position, Velocity })) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.* = pos.* + vel.* * dt;
    }
}
```

### Use Query for Flexible Patterns
```zig
// Ad-hoc queries without setup
fn damageSystem(query: Query(struct { Health, ?Armor })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            var health = query.getComponentMut(entity, Health);
            const armor = query.getOptional(entity, Armor) orelse 0;
            health.hp -= max(0, damage - armor);
        }
    }
}
```

### Minimize Component Changes
```zig
// Bad: constant add/remove causes group updates
fn badSystem(commands: anytype) !void {
    const entity = commands.createEntity();
    try commands.addComponent(entity, Health, .{ .hp = 100 });
    commands.removeComponent(entity, Health);  // Expensive!
    try commands.addComponent(entity, Health, .{ .hp = 50 }); // Expensive!
}

// Good: set once, modify in place
fn goodSystem(query: Query(struct { Health })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const health = query.getComponentMut(entity, Health);
            health.hp = 50; // Fast!
        }
    }
}
```

## Conclusion

Sparze is already highly optimized for an ECS library. The most impactful improvements are:

1. **✓ Iterator filter caching** (implemented)
2. **Batch operations API** (recommended)
3. **Parallel system execution** (future)
4. **User education on best practices** (documentation)

Focus should be on providing clear documentation and examples showing users how to leverage existing optimizations rather than adding complexity for marginal gains.
