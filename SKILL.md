---
name: sparze
description: Expert guidance for building ECS apps with Sparze: systems, queries, components, resources, events, and performance trade-offs.
---

# Sparze ECS Skill

Expert guidance for building high-performance ECS applications with Sparze.

## Core Concepts

**World**: ECS coordinator with compile-time component, resource, event, and group types.

```zig
const World = sparze.World(
    .{ Position, Velocity, Health },     // Components
    .{ DeltaTime, Score },               // Resources
    .{ CollisionEvent },                 // Events
    .{ struct { Position, Velocity } },  // Groups
);
```

**Entity**: 32-bit handle `[version:16 | index:16]`. `index` selects dense slot; `version` invalidates stale handles. Use `.index`, `.version`, or `getIndex()` / `getVersion()`. Create via `Entity.init()`, serialize with `toInt()` / `fromInt(u32)`.

**Components**: Data attached to entities. Tag components (empty structs) use 1 bit per entity.

**Resources**: Global singletons injected via `Resource(T)` / `ResourceMut(T)`. Can implement `init()` / `deinit()`, or opt out with `pub const auto_init = false` (manual initialization required). POD resources are zero-initialized for compatibility.

**Events**: 1-frame delayed, double-buffered communication. Events written in frame N are read in frame N+1.

Docs: @docs/ARCHITECTURE.md, @docs/ENTITY_LIFECYCLE.md

## System Functions

System functions use injected parameters and **must use `commands: anytype`** for world mutation. Return `void` or `!void`.

```zig
fn mySystem(
    allocator: std.mem.Allocator,
    movement: Group(struct { Position, Velocity }),
    health: SingleQuery(Health),
    delta: Resource(DeltaTime),
    score: ResourceMut(Score),
    reader: EventReader(CollisionEvent),
    writer: EventWriter(DamageEvent),
    commands: anytype,
) !void {
    // Implementation
}
```

### Commands API

Immediate (returns now):
- `commands.createEntity()`
- `try commands.createEntityWith(.{ Position{...}, Velocity{...} })`
- `commands.setResource(T, value)` / `commands.getResource(T)` / `commands.getResourcePtrMut(T)`
- `try commands.initResources(.{ ... })`
- `try commands.serializeToFile(path)` / `try commands.deserializeFromFile(path)`

Deferred (applied at `world.endFrame()`):
- `try commands.addComponent(e, T, value)` / `try commands.removeComponent(e, T)`
- `try commands.addTag(e, T)` / `try commands.removeTag(e, T)`
- `try commands.destroyEntity(e)`

Why deferred: avoids invalidating iterators or shifting dense arrays mid-iteration.

Docs: @docs/SYSTEM_PATTERNS.md

## Queries

Decision guide:
- **SingleQuery**: single component, any frequency
- **Query**: multi-component, occasional use
- **Group**: multi-component, hot path

### SingleQuery(Component)

```zig
fn healthSystem(query: SingleQuery(Health)) !void {
    for (query.entities, query.components) |entity, *health| {
        health.hp = @max(0, health.hp);
    }
}
```

### Query(struct { ... })

```zig
fn combatSystem(query: Query(struct { Position, Health, ?Shield })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            const health = query.getComponentMut(entity, Health);
            const shield = query.getOptional(entity, Shield);
            _ = pos; _ = health; _ = shield;
        }
    }
}
```

### Group(struct { ... })

```zig
const MovementGroup = struct { Position, Velocity };
const World = sparze.World(.{ Position, Velocity }, .{}, .{}, .{ MovementGroup });

fn movementSystem(group: Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}
```

**Free(Component)**: use in groups that do not own a component. Access via `group.getComponent(entity, T)` instead of array access.

### Tag Queries

```zig
fn enemySystem(query: TagQuery(struct { Enemy, ?Boss, Exclude(Dead) })) !void {
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            _ = entity;
        }
    }
}
```

Docs: @docs/QUERY_PATTERNS.md

## Query Modifiers

- **Optional (?T)**: entity may or may not have component
- **Exclude(T)**: filter out entities with component
- **Free(T)**: group does not own component; access by lookup

## System Organization

Principles:
- One system, one responsibility
- Writers run before readers
- Use events for loose coupling (1-frame delay)
- Group systems by domain (physics, combat, rendering)

Frame lifecycle:

```zig
world.beginFrame();
try world.runSystem(inputSystem);
try world.runSystem(physicsSystem);
try world.runSystem(renderSystem);
try world.endFrame();
```

**Critical**: Always call `endFrame()` to flush deferred commands.

## Resources

Initialization options:
- `init()` / `deinit()` for auto-lifecycle
- `pub const auto_init = false` for manual setup
- POD resources are zero-initialized

Safety helpers:
- `isResourceInitialized(T)`
- `tryGetResource(T)`
- `initResources(.{ ... })` for bulk init

## Performance

Fastest to slowest:
1. Group owned components (`getMutArrayOf`)
2. SingleQuery
3. Group free components (`getComponent`)
4. Query

Best practices:
- Use Group for hot-path systems
- Use Query for ad-hoc/dynamic access
- Validate group ownership with `World.validateGroups()`

Storage notes:
- Tag components use 1 bit per entity
- Reserve with `getSparseSetPtrMut(T).reserve(capacity)`
- Pagination: 4096 entities per page

Docs: @docs/PERFORMANCE.md, @docs/STORAGE_INTERNALS.md

## Quick Reference

| Task | API |
|------|-----|
| Create entity | `commands.createEntity()` |
| Add component | `try commands.addComponent(e, T, value)` |
| Query single | `SingleQuery(Health)` |
| Query multi | `Query(struct { Position, Velocity })` |
| Fastest iteration | `Group(struct { Position, Velocity })` |
| Optional component | `Query(struct { Position, ?Sprite })` |
| Exclude entities | `Query(struct { Enemy, Exclude(Dead) })` |
| Read resource | `Resource(DeltaTime)` |
| Write resource | `ResourceMut(Score)` |
| Read events | `EventReader(CollisionEvent)` |
| Write events | `EventWriter(DamageEvent)` |
| Tag iteration | `SingleTag(Enemy)` |

## Documentation Index

- @docs/ARCHITECTURE.md
- @docs/QUERY_PATTERNS.md
- @docs/ENTITY_LIFECYCLE.md
- @docs/STORAGE_INTERNALS.md
- @docs/SYSTEM_PATTERNS.md
- @docs/PERFORMANCE.md
