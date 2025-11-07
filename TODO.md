# Sparze Implementation TODO

This document contains a comprehensive checklist for implementing three high-priority features for game developers:

1. **Serialization/Deserialization** - Save/load scenes and game state
2. **Entity Prefabs** - Templates for creating entities with predefined components
3. **Reactive Systems** - Component lifecycle events for triggering logic

---

## Feature 2: Entity Prefabs

### Context

Game developers need to:
- Spawn enemies with consistent stats and components
- Create UI elements from templates
- Instantiate entities from data files (level loading)
- Support modding (define entities in external files)
- Ensure consistency across entity creation

### Design Decisions

- **Approach**: Factory function pattern (compile-time, zero overhead)
- **Runtime Support**: Optional prefab registry for data-driven workflows
- **Integration**: Leverage serialization system (prefabs as scene files)

### Implementation Checklist

#### Factory Function Pattern (Compile-Time)

- [ ] **Document pattern in examples**
  - [ ] Create `examples/prefabs.zig`
  - [ ] Show factory function for enemy spawning
  - [ ] Show factory function for UI elements
  - [ ] Demonstrate parameter customization

Example pattern:
```zig
fn spawnEnemy(world: *World, position: Position, enemy_type: EnemyType) !Entity {
    const entity = try world.createEntity();

    try world.addComponent(entity, Position, position);
    try world.addComponent(entity, Health, .{
        .hp = enemy_type.maxHp(),
        .max_hp = enemy_type.maxHp()
    });
    try world.addComponent(entity, AIComponent, .{ .state = .idle });

    // Add enemy-specific components
    switch (enemy_type) {
        .goblin => try world.addComponent(entity, MeleeAttack, .{ .damage = 10 }),
        .archer => try world.addComponent(entity, RangedAttack, .{ .damage = 15, .range = 50 }),
    }

    return entity;
}
```

#### Runtime Prefab System (Optional)

- [ ] **Create `src/prefab.zig`**
  - [ ] Define `Prefab` struct (serialized component data)
  - [ ] Define `PrefabRegistry` for storing prefabs by name/ID

- [ ] **Add `World` prefab methods**
  - [ ] `registerPrefab(name: []const u8, scene_path: []const u8)` - Load prefab from file
  - [ ] `registerPrefabInline(name: []const u8, components: anytype)` - Register from struct
  - [ ] `spawnPrefab(name: []const u8)` - Instantiate prefab as entity
  - [ ] `spawnPrefabAt(name: []const u8, position: Position)` - Spawn with override

- [ ] **Prefab storage**
  - [ ] Store prefab component data as JSON or binary
  - [ ] Cache deserialized prefabs for performance
  - [ ] Support prefab variants (base prefab + overrides)

#### Integration with Serialization

- [ ] **Prefab file format**
  - [ ] Reuse scene JSON format
  - [ ] Single-entity scene = prefab
  - [ ] Support component overrides in spawning call

- [ ] **Prefab loading**
  - [ ] Load prefab JSON file
  - [ ] Deserialize into temporary entity
  - [ ] Clone components to new entity on spawn
  - [ ] Handle entity references (remap to spawned entities)

#### Testing

- [ ] **Unit tests**
  - [ ] Test factory function pattern
  - [ ] Test prefab registration
  - [ ] Test prefab spawning
  - [ ] Test component overrides
  - [ ] Test prefab with entity references

- [ ] **Integration tests**
  - [ ] Spawn 100 entities from same prefab (performance)
  - [ ] Load prefab from file
  - [ ] Modify spawned entities independently

#### Examples

- [ ] **Create `examples/prefabs.zig`**
  - [ ] Enemy spawning with factory functions
  - [ ] UI element creation (buttons, panels)
  - [ ] Prefab loading from JSON file
  - [ ] Demonstrate parameter overrides

- [ ] **Create prefab files**
  - [ ] `examples/prefabs/enemy_goblin.json`
  - [ ] `examples/prefabs/enemy_archer.json`
  - [ ] `examples/prefabs/ui_button.json`

#### Documentation

- [ ] Update `CLAUDE.md` with prefab patterns
- [ ] Create `docs/prefabs.md`:
  - [ ] Factory function best practices
  - [ ] Runtime prefab system API
  - [ ] File format specification
  - [ ] Performance considerations

---

## Feature 3: Reactive Systems (Component Lifecycle Events)

### Context

Game developers need to:
- Trigger animations when state changes
- Update UI when health/score changes
- Play sound effects on collision
- Spawn particle effects on entity death
- Maintain derived data (indexes, caches)
- Initialize/cleanup resources when components added/removed

### Design Decisions

- **Approach**: Extend existing event system with component lifecycle events
- **Event Types**: `ComponentAdded<T>`, `ComponentRemoved<T>`
- **Timing**: Events emitted during `addComponent`/`removeComponent` calls
- **Frame Delay**: Consistent with existing events (emitted in frame N, read in frame N+1)
- **Change Detection**: Not built-in (users implement with tracking pattern)

### Implementation Checklist

#### Event Type Definitions

- [ ] **Create lifecycle event types in `src/system.zig`**
  - [ ] Define `ComponentAdded(comptime ComponentType: type)` struct:
    ```zig
    pub fn ComponentAdded(comptime T: type) type {
        return struct {
            entity: Entity,
            // component data available via query
        };
    }
    ```
  - [ ] Define `ComponentRemoved(comptime ComponentType: type)` struct:
    ```zig
    pub fn ComponentRemoved(comptime T: type) type {
        return struct {
            entity: Entity,
            // component data not available (already removed)
        };
    }
    ```

- [ ] **Register lifecycle events in World**
  - [ ] Events tuple must include lifecycle events for all components
  - [ ] Auto-generate at `comptime` based on component types
  - [ ] For component tuple `struct { Position, Health }`, generate:
    - `ComponentAdded(Position)`
    - `ComponentRemoved(Position)`
    - `ComponentAdded(Health)`
    - `ComponentRemoved(Health)`

#### Event Emission

- [ ] **Modify `World.addComponent()`**
  - [ ] After component successfully added, emit `ComponentAdded` event
  - [ ] Get EventWriter for `ComponentAdded(T)`
  - [ ] Enqueue event with entity ID
  - [ ] Ensure emission happens even with `addComponents()` batch operation

- [ ] **Modify `World.removeComponent()`**
  - [ ] Before component removed, emit `ComponentRemoved` event
  - [ ] Get EventWriter for `ComponentRemoved(T)`
  - [ ] Enqueue event with entity ID
  - [ ] Ensure emission happens even with `removeComponents()` batch operation

- [ ] **Modify `World.addTag()`**
  - [ ] Emit `ComponentAdded` event for tag components

- [ ] **Modify `World.removeTag()`**
  - [ ] Emit `ComponentRemoved` event for tag components

- [ ] **Handle `Commands` buffer**
  - [ ] When commands executed in `endFrame()`, emit events
  - [ ] Deferred add/remove must also trigger events

#### System Parameter Support

Systems already support `EventReader(EventType)`, so lifecycle events work automatically:

```zig
fn onHealthAdded(
    reader: EventReader(ComponentAdded(Health)),
    query: SingleQuery(Health),
) !void {
    for (reader.queue) |event| {
        const health = query.get(event.entity);
        std.debug.print("Entity {} gained health: {}\n", .{event.entity, health.hp});
        // Initialize health UI, etc.
    }
}
```

- [ ] **Verify existing `EventReader` works with lifecycle events**
- [ ] No changes needed (events are just regular events)

#### Testing

- [ ] **Unit tests for event emission**
  - [ ] Test `ComponentAdded` emitted on `addComponent()`
  - [ ] Test `ComponentRemoved` emitted on `removeComponent()`
  - [ ] Test events for tag components
  - [ ] Test events emitted from `Commands` buffer
  - [ ] Test batch operations emit events for each component

- [ ] **Integration tests**
  - [ ] Create entity, add component, verify event in next frame
  - [ ] Remove component, verify event in next frame
  - [ ] Multiple components added/removed in same frame
  - [ ] Events don't fire for entities destroyed

- [ ] **System tests**
  - [ ] Write reactive system that responds to `ComponentAdded`
  - [ ] Write reactive system that responds to `ComponentRemoved`
  - [ ] Verify systems execute in correct frame (N+1)

#### Change Detection Pattern (Documentation Only)

Document pattern for detecting component value changes:

```zig
const HealthTracker = struct {
    previous: std.AutoHashMap(Entity, Health),

    pub fn detectChanges(
        self: *Self,
        allocator: std.mem.Allocator,
        query: SingleQuery(Health),
    ) !std.ArrayList(Entity) {
        var changed = std.ArrayList(Entity).init(allocator);

        for (query.entities, query.components) |entity, health| {
            if (self.previous.get(entity)) |prev| {
                if (prev.hp != health.hp) {
                    try changed.append(entity);
                }
            }
            try self.previous.put(entity, health);
        }

        return changed;
    }
};
```

- [ ] Document in `docs/reactive_systems.md`
- [ ] Include in examples

#### Examples

- [ ] **Create `examples/reactive_systems.zig`**
  - [ ] System reacting to `ComponentAdded(Health)` - initialize health bar
  - [ ] System reacting to `ComponentRemoved(Health)` - cleanup health bar
  - [ ] System reacting to component changes (change detection pattern)
  - [ ] Demonstrate audio system triggering on collision event
  - [ ] Demonstrate particle spawning on entity death

- [ ] **Practical use cases**
  - [ ] Health UI synchronization
  - [ ] Animation state changes
  - [ ] Sound effect triggers
  - [ ] Particle effect spawning
  - [ ] Achievement unlocking

#### Documentation

- [ ] Update `CLAUDE.md` with reactive systems section:
  - [ ] Component lifecycle events
  - [ ] Event timing (frame N+1)
  - [ ] Change detection pattern
  - [ ] Common use cases

- [ ] Create `docs/reactive_systems.md`:
  - [ ] Lifecycle event types
  - [ ] How to write reactive systems
  - [ ] Change detection strategies
  - [ ] Performance considerations
  - [ ] Best practices

---

## Implementation Order

### Phase 1: Serialization Foundation (Week 1-2)
1. Create serialization infrastructure (`src/serialization.zig`)
2. Implement `World.serialize()` and `World.deserialize()`
3. Add comptime component serializer generation
4. Implement entity reference remapping
5. Write unit tests
6. Create basic example

### Phase 2: Serialization Polish (Week 2-3)
1. Add partial serialization (specific entities)
2. Write comprehensive tests (edge cases, large worlds)
3. Create example scene files
4. Document serialization system

### Phase 3: Entity Prefabs (Week 3-4)
1. Document factory function pattern in examples
2. Create `src/prefab.zig` with runtime prefab registry
3. Add World prefab methods
4. Integrate with serialization (load prefabs from files)
5. Write tests
6. Create prefab examples and files

### Phase 4: Reactive Systems (Week 4-5)
1. Define `ComponentAdded` and `ComponentRemoved` event types
2. Modify World methods to emit lifecycle events
3. Handle events in Commands buffer
4. Write unit and integration tests
5. Create reactive systems examples
6. Document change detection patterns

### Phase 5: Polish & Documentation (Week 5-6)
1. Update all documentation (CLAUDE.md, docs/)
2. Review and refine examples
3. Add benchmarks (if performance concerns)
4. Create comprehensive integration tests
5. Write migration guide (if breaking changes)

---

## Acceptance Criteria

### Serialization/Deserialization
- ✅ Can serialize World to JSON file
- ✅ Can deserialize JSON file to new World
- ✅ Entity references preserved across save/load
- ✅ All primitive types, structs, arrays supported
- ✅ Performance: Serialize 10k entities in < 100ms
- ✅ Comprehensive test coverage (>90%)
- ✅ Documentation and examples complete

### Entity Prefabs
- ✅ Factory function pattern documented with examples
- ✅ Can register prefabs from JSON files
- ✅ Can spawn entities from prefabs
- ✅ Can override prefab components on spawn
- ✅ Performance: Spawn 1k entities from prefab in < 10ms
- ✅ Test coverage for all prefab operations
- ✅ Documentation complete

### Reactive Systems
- ✅ `ComponentAdded` events emitted on component addition
- ✅ `ComponentRemoved` events emitted on component removal
- ✅ Events work with tag components
- ✅ Events work with deferred Commands
- ✅ Systems can read lifecycle events via `EventReader`
- ✅ Change detection pattern documented
- ✅ Examples demonstrate practical use cases
- ✅ Documentation complete

---

## Notes for Implementation

### Performance Considerations
- Serialization: Use buffered I/O for large worlds
- Prefabs: Cache deserialized prefabs to avoid repeated parsing
- Lifecycle events: Minimal overhead (just event queue append)

### Compatibility
- Maintain compile-time type safety throughout
- No breaking changes to existing API
- New features are opt-in (don't affect existing code)

### Testing Strategy
- Unit tests for individual functions
- Integration tests for feature workflows
- Performance benchmarks for critical paths
- Example programs serve as acceptance tests

### Documentation
- Update CLAUDE.md as primary reference
- Create dedicated docs/ files for each feature
- Ensure examples are well-commented and practical
- Include performance characteristics and limitations
