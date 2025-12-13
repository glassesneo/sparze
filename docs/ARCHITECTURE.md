# Sparze Architecture

Comprehensive architecture documentation for Sparze ECS library.

## Philosophy

Sparze is a **compile-time ECS** (Entity Component System) where all component, resource, and event types are known at compile time. This design enables:

- **Zero runtime lookup**: All type information resolved at compile time
- **Strong type safety**: Compiler catches type mismatches
- **Cache-friendly layouts**: Contiguous memory, pagination, group organization
- **Minimal API**: Small, focused interface with maximum performance

## Design Principles

1. **Compile-time type resolution**: No runtime type IDs, no dynamic dispatch
2. **Strong type safety**: Leverage Zig's comptime for type checking
3. **Cache-friendly layouts**: Arrays-of-structs, pagination, group locality
4. **Minimal API**: Simple, orthogonal operations
5. **Explicit over implicit**: Clear operation costs and behaviors

## Core Structures

### Entity Management

| Structure | Location | Purpose | Details |
|-----------|----------|---------|---------|
| Entity | `src/entity/entity.zig` | 32-bit identifier | 16-bit index + 16-bit version |
| EntityRegistry | `src/entity/entity.zig` | Lifecycle management | Free list recycling, version tracking |

**Memory footprint**: ~256 KB fixed allocation (65,536 entities max)

### Storage Layer

| Structure | Location | Purpose | Details |
|-----------|----------|---------|---------|
| SparseSet | `src/storage/sparse_set.zig` | Component storage | Paginated sparse set with group support |
| TagStorage | `src/storage/tag_storage.zig` | Tag storage | Paged bitset + reverse indices |
| EventStorage | `src/storage/event_storage.zig` | Event queue | Double-buffered, frame-delayed |

#### SparseSet Internal Structure

**Layout**: Sparse array (entity → dense index) + Dense array (packed components)

**Pagination**:
- 4096 entities per page
- 16 pages maximum (65,536 entities total)
- Pages allocated on-demand

**Group Layout**:
```
Dense Array: [Group Region (0..group_size) | Non-Group Region (group_size..len)]
```

First `group_size` elements reserved for group entities, enabling direct array iteration.

**Memory**:
- Sparse: ~512 KB max (only if all pages allocated)
- Dense: Linear with entity count (component_size × entity_count)

#### TagStorage Internal Structure

**Layout**: Paged sparse storage optimized for zero-sized marker components.

**Page Structure** (4096 entities/page, 16KB/page):
- Bitset: 512 bytes (4096 bits)
- Reverse indices: 16KB (4096 × u32)

**Memory efficiency**: O(pages_used) instead of O(max_entity_index). For sparse entity allocations, achieves ~98% memory reduction vs. non-paged approach.

### Main API Components

| Component | Location | Purpose | Key Operations |
|-----------|----------|---------|----------------|
| World | `src/world.zig` | ECS coordinator | Entity/component/resource management, system execution |
| System functions | `src/system/system.zig` | Game logic execution | Parameter injection, compile-time signature analysis |
| Commands | `src/system/system.zig` | Deferred operations | Safe mutations during iteration |
| Query Filters | `src/query/filter.zig` | Entity iteration | SingleQuery, Query, Group, TagQuery |

## World Structure

```zig
World(
    Components: struct { Position, Velocity, Health, ... },
    Resources: struct { DeltaTime, GameState, ... },
    Events: struct { Collision, SpawnEvent, ... }
)
```

The World type is parameterized by three compile-time struct types:
- **Components**: All component types in the ECS
- **Resources**: Global singleton types
- **Events**: Event types for frame-delayed communication

### World Key Methods

**Entity management**:
- `createEntity() Entity` - Create new entity (immediate, infallible)
- `destroyEntity(Entity) void` - Destroy entity immediately (deferral is only via Commands)

**Component management**:
- `addComponent(Entity, T) !void` - Add component (immediate)
- `removeComponent(Entity, type) void` - Remove component immediately
- `addTag(Entity, type) !void` - Add tag (immediate)
- `removeTag(Entity, type) void` - Remove tag immediately

**Resource management**:
- `setResource(type, T) !void` - Set resource value
- `getResource(type) T` - Get resource value (unchecked)
- `getResourcePtr(type) *const T` - Get resource pointer
- `getResourcePtrMut(type) *T` - Get mutable resource pointer
- `tryGetResource(type) !*const T` - Get resource with validation
- `tryGetResourceMut(type) !*T` - Get mutable resource with validation
- `initResources(anytype) !void` - Bulk initialize resources
- `isResourceInitialized(type) bool` - Check initialization status

**Group management**:
- `createGroup(type) !void` - Create entity group (immediate)
- `validateGroups(anytype) void` - Compile-time group validation

**Frame management**:
- `beginFrame() void` - Swap event buffers
- `endFrame() !void` - Flush command buffer
- `runSystem(fn) !void` - Execute system function

**IMPORTANT**: World cannot be directly accessed in system functions. Use parameter injection (Query, Resource, Commands, etc.) instead.

## Memory Layout Philosophy

Sparze optimizes for cache efficiency through three mechanisms:

1. **Pagination**: 4KB pages (CPU cache line friendly)
2. **Groups**: Hot components co-located in memory
3. **Sparse sets**: Dense packing, minimal fragmentation

## CommandBuffer Internals

**Purpose**: Queue component/entity operations for safe deferred execution.

**Storage**: InlineStorage ([World.max_component_size]u8 buffer) stores components ≤ World.max_component_size inline.

**Execution timing**:
- Immediate: `createEntity()`, `createGroup()`, resource operations, `removeComponent/removeTag`, `destroyEntity()`
- Deferred: Component add/remove and destruction when invoked via Commands

**Safety guarantees**:
- Entity liveness validation during flush
- Zombie entity prevention (skip operations on destroyed entities)
- Version checking for recycled entities

See also:
- @docs/ENTITY_LIFECYCLE.md for entity creation/deletion flows
- @docs/STORAGE_INTERNALS.md for detailed storage mechanics
- @docs/SYSTEM_PATTERNS.md for CommandBuffer usage patterns
