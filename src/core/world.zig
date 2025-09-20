const std = @import("std");
const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const entity_module = @import("entity.zig");
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;

const sparse_set_module = @import("sparse_set.zig");
const AbstractSparseSet = sparse_set_module.AbstractSparseSet;
const SparseSet = sparse_set_module.SparseSet;

const system_module = @import("system.zig");
const SystemScheduler = system_module.SystemScheduler;
const Stage = system_module.Stage;
const FilterType = system_module.FilterType;
const SingleQuery = system_module.SingleQuery;

const TypeId = u16;
const max_type_id = std.math.maxInt(TypeId);

fn typeId(comptime T: type) TypeId {
    return @intFromError(@field(anyerror, @typeName(T)));
}

/// Information about a full-owning group
pub const GroupInfo = struct {
    group_type_id: TypeId, // Unique identifier based on component types tuple
    component_types: []TypeId,

    pub fn deinit(self: *GroupInfo, allocator: Allocator) void {
        allocator.free(self.component_types);
    }
};

/// World manages entities and their components in an Entity Component System.
/// Uses sparse sets for efficient component storage and iteration.
pub const World = struct {
    allocator: Allocator,
    entity_registry: EntityRegistry,
    sparse_type_ids: [max_type_id]?TypeId,
    dense_type_ids: ArrayList(TypeId),
    component_pool: ArrayList(AbstractSparseSet),
    system_scheduler: SystemScheduler,
    startup_system_scheduler: SystemScheduler,
    terminate_system_scheduler: SystemScheduler,

    groups: ArrayList(GroupInfo),

    /// Initializes a new empty World with the given allocator.
    pub fn init(allocator: Allocator) World {
        return .{
            .allocator = allocator,
            .entity_registry = .init(),
            .sparse_type_ids = [_]?TypeId{null} ** max_type_id,
            .dense_type_ids = .{},
            .component_pool = .{},
            .system_scheduler = .init(),
            .startup_system_scheduler = .init(),
            .terminate_system_scheduler = .init(),
            .groups = .{},
        };
    }

    /// Deinitializes the World, freeing internal dynamic arrays.
    /// Component sparse sets must be deinitialized separately by their owners.
    pub fn deinit(self: *World) void {
        for (self.groups.items) |*group| {
            group.deinit(self.allocator);
        }
        self.groups.deinit(self.allocator);
        self.dense_type_ids.deinit(self.allocator);
        self.component_pool.deinit(self.allocator);
    }

    /// Creates a new Entity identifier, recycling destroyed entities when available.
    /// Complexity: O(1).
    pub fn createEntity(self: *World) Entity {
        return self.entity_registry.create();
    }

    /// Destroys an Entity and removes it from all registered component pools.
    /// The entity identifier becomes invalid and may be recycled for future entities.
    /// Complexity: O(c) where c = number of registered component types.
    pub fn destroyEntity(self: *World, entity: Entity) void {
        self.entity_registry.destroy(entity);
        for (self.component_pool.items) |component| {
            component.remove(entity);
        }
    }

    /// Registers a component type with the World using the provided sparse set.
    /// Re-registering the same type replaces the previous sparse set.
    /// The sparse set lifetime must exceed the World's lifetime.
    /// Complexity: O(1) amortized (ArrayList may reallocate).
    pub fn registerComponent(self: *World, comptime C: type, component_sparse_set: *SparseSet(C)) !void {
        const sparse_index = comptime typeId(C);
        const abstract_sparse_set = component_sparse_set.abstract();
        if (self.sparse_type_ids[sparse_index]) |dense_index| {
            self.component_pool.items[dense_index] = abstract_sparse_set;
            self.dense_type_ids.items[dense_index] = sparse_index;
            return;
        }

        const dense_index: u16 = @intCast(self.component_pool.items.len);
        try self.component_pool.append(self.allocator, abstract_sparse_set);
        try self.dense_type_ids.append(self.allocator, sparse_index);
        self.sparse_type_ids[sparse_index] = dense_index;
    }

    /// Adds or replaces a component for the given entity.
    /// Returns ComponentNotRegistered if the component type is not registered.
    /// Complexity: O(1) amortized (SparseSet may reallocate).
    pub fn addComponent(self: *World, entity: Entity, comptime C: type, component: C) !void {
        const type_id = self.getTypeId(C) orelse return error.ComponentNotRegistered;
        var component_copy = component;
        try self.component_pool.items[type_id].insert(entity, &component_copy);

        // Update groups when component is added
        try self.updateGroupsOnAdd(entity, type_id);
    }

    /// Adds multiple components to an entity in a single call.
    /// Each component type must be registered before calling this function.
    /// Complexity: O(n) where n = number of components in the tuple.
    pub fn addComponents(self: *World, entity: Entity, comptime types: anytype) !void {
        inline for (types) |component| {
            const C = @TypeOf(component);
            try self.addComponent(entity, C, component);
        }
    }

    /// Retrieves a component for the given entity, if present.
    /// Returns null if the entity doesn't have the component or the type is not registered.
    /// Complexity: O(1).
    pub fn getComponent(self: *World, entity: Entity, comptime C: type) ?C {
        const type_id = self.getTypeId(C) orelse return null;
        return self.component_pool.items[type_id].get(entity, C);
    }

    /// Checks if an entity is currently alive and valid.
    /// Returns false for destroyed or never-allocated entities.
    /// Complexity: O(1).
    pub fn isAlive(self: *const World, entity: Entity) bool {
        return self.entity_registry.isAlive(entity);
    }

    /// Checks if an entity has a specific component type.
    /// Returns false if the entity doesn't have the component or the type is not registered.
    /// Complexity: O(1).
    pub fn hasComponent(self: *const World, entity: Entity, comptime C: type) bool {
        const type_id = self.getTypeId(C) orelse return false;
        return self.component_pool.items[type_id].contains(entity);
    }

    /// Removes a component from an entity if it exists.
    /// Does nothing if the entity doesn't have the component or the type is not registered.
    /// Complexity: O(1).
    pub fn removeComponent(self: *World, entity: Entity, comptime C: type) void {
        const type_id = self.getTypeId(C) orelse return;

        // Update groups before removing component
        self.updateGroupsOnRemove(entity, type_id);

        self.component_pool.items[type_id].remove(entity);
    }

    /// Creates an entity and adds multiple components in one call.
    /// Each component type must be registered before calling this function.
    /// Complexity: O(n) where n = number of components in the tuple.
    pub fn createEntityWith(self: *World, comptime components: anytype) !Entity {
        const entity = self.createEntity();
        try self.addComponents(entity, components);
        return entity;
    }

    pub fn getSparseSet(self: *World, comptime C: type) !*SparseSet(C) {
        const type_id = self.getTypeId(C) orelse return error.ComponentNotRegistered;
        return self.component_pool.items[type_id].incarnate(C);
    }

    pub fn getTypeId(self: *const World, comptime C: type) ?TypeId {
        return self.sparse_type_ids[typeId(C)];
    }

    fn constructSystemArgsType(comptime info: std.builtin.Type.Fn) type {
        var fields: [info.params.len]StructField = undefined;
        for (info.params, 0..) |param, i| {
            const ArgType = param.type orelse @compileError("Unsupported argument");
            fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = ArgType,
                .is_comptime = false,
                .alignment = @alignOf(ArgType),
                .default_value_ptr = null,
            };
        }
        return @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &fields,
        } });
    }

    fn createSystemFunction(comptime system_fn: anytype) (fn (*World) anyerror!void) {
        const SystemType = @TypeOf(system_fn);
        const system_type_info = switch (@typeInfo(SystemType)) {
            .@"fn" => |f| f,
            else => @compileError("Not a function"),
        };

        const SystemArgsType = constructSystemArgsType(system_type_info);

        return struct {
            fn run(world: *World) !void {
                const system_args = construct_system_args: {
                    var system_args: SystemArgsType = undefined;
                    inline for (system_type_info.params, 0..) |param, i| {
                        const ArgType = param.type.?;
                        if (!@hasDecl(ArgType, "filter_type")) @compileError("Unsupported argument");

                        const filter_type: FilterType = ArgType.filter_type;

                        switch (filter_type) {
                            .single_query => {
                                system_args[i] = try ArgType.init(world);
                            },
                            .group => {
                                system_args[i] = ArgType.init(world);
                            },
                        }
                    }

                    break :construct_system_args system_args;
                };

                try @call(.auto, system_fn, system_args);
            }
        }.run;
    }

    pub fn registerSystem(self: *World, comptime system_fn: anytype, stage: Stage) void {
        const system = createSystemFunction(system_fn);
        self.system_scheduler.register(system, stage);
    }

    pub fn registerStartupSystem(self: *World, comptime system_fn: anytype, stage: Stage) void {
        const system = createSystemFunction(system_fn);
        self.startup_system_scheduler.register(system, stage);
    }

    pub fn registerTerminateSystem(self: *World, comptime system_fn: anytype, stage: Stage) void {
        const system = createSystemFunction(system_fn);
        self.terminate_system_scheduler.register(system, stage);
    }

    /// Create a full-owning group for the given component types
    pub fn createGroup(self: *World, comptime ComponentTypes: type) !void {
        const component_fields = std.meta.fields(ComponentTypes);
        if (component_fields.len == 0) return error.EmptyGroup;

        const group_type_id = comptime typeId(ComponentTypes);

        // Check if group already exists
        if (self.getGroupByTypeId(group_type_id) != null) {
            return; // Group already exists
        }

        var component_types = try self.allocator.alloc(TypeId, component_fields.len);

        inline for (component_fields, 0..) |field, i| {
            const ComponentType = field.type;
            const type_id = self.getTypeId(ComponentType) orelse return error.ComponentNotRegistered;
            component_types[i] = type_id;
        }

        try self.groups.append(self.allocator, GroupInfo{
            .group_type_id = group_type_id,
            .component_types = component_types,
        });

        // Populate the group with existing entities that have all components
        try self.populateGroup(ComponentTypes);
    }

    /// Get group information by component types
    fn getGroupByTypeId(self: *const World, group_type_id: TypeId) ?*const GroupInfo {
        for (self.groups.items) |*group| {
            if (group.group_type_id == group_type_id) return group;
        }
        return null;
    }

    /// Get group information by component types
    pub fn getGroup(self: *const World, comptime ComponentTypes: type) ?*const GroupInfo {
        const group_type_id = comptime typeId(ComponentTypes);
        return self.getGroupByTypeId(group_type_id);
    }

    /// Get entities in a group (fast iteration)
    pub fn getGroupEntities(self: *const World, comptime ComponentTypes: type) ?[]const Entity {
        const group = self.getGroup(ComponentTypes) orelse return null;

        const first_type_id = group.component_types[0];
        return self.component_pool.items[first_type_id].getGroupEntities();
    }

    /// Get components of a specific type in a group (fast iteration)
    pub fn getGroupComponents(self: *const World, comptime ComponentTypes: type, comptime C: type) ?[]const C {
        const group = self.getGroup(ComponentTypes) orelse return null;
        const type_id = self.getTypeId(C) orelse return null;

        // Check if this component type is part of the group
        for (group.component_types) |group_type_id| {
            if (group_type_id == type_id) {
                const sparse_set = self.component_pool.items[type_id].incarnate(C);
                return sparse_set.getGroupComponents();
            }
        }
        return null;
    }

    pub fn getGroupComponentsMut(self: *const World, comptime ComponentTypes: type, comptime C: type) ?[]C {
        const group = self.getGroup(ComponentTypes) orelse return null;
        const type_id = self.getTypeId(C) orelse return null;

        // Check if this component type is part of the group
        for (group.component_types) |group_type_id| {
            if (group_type_id == type_id) {
                const sparse_set = self.component_pool.items[type_id].incarnate(C);
                return sparse_set.getGroupComponentsMut();
            }
        }
        return null;
    }

    /// Populate group with existing entities that have all required components
    fn populateGroup(self: *World, comptime ComponentTypes: type) !void {
        const group = self.getGroup(ComponentTypes) orelse return;
        if (group.component_types.len == 0) return;

        // Find the shortest sparse set to minimize iterations
        var min_size: usize = std.math.maxInt(usize);
        var shortest_type_id: TypeId = group.component_types[0];

        for (group.component_types) |type_id| {
            const sparse_set = &self.component_pool.items[type_id];
            const entities = sparse_set.getEntities();
            if (entities.len < min_size) {
                min_size = entities.len;
                shortest_type_id = type_id;
            }
        }

        // Iterate through shortest set and check if entities have all components
        const shortest_set = &self.component_pool.items[shortest_type_id];
        const entities = shortest_set.getEntities();

        for (entities) |entity| {
            if (self.entityHasAllComponents(entity, group.component_types)) {
                self.addEntityToGroup(entity, group);
            }
        }
    }

    /// Check if entity has all required components for a group
    fn entityHasAllComponents(self: *const World, entity: Entity, component_types: []const TypeId) bool {
        for (component_types) |type_id| {
            if (!self.component_pool.items[type_id].contains(entity)) {
                return false;
            }
        }
        return true;
    }

    /// Update groups when component is added to entity
    fn updateGroupsOnAdd(self: *World, entity: Entity, component_type_id: TypeId) !void {
        for (self.groups.items) |*group| {
            // Check if this component type is part of the group
            var is_group_component = false;
            for (group.component_types) |type_id| {
                if (type_id == component_type_id) {
                    is_group_component = true;
                    break;
                }
            }

            if (is_group_component and self.entityHasAllComponents(entity, group.component_types)) {
                self.addEntityToGroup(entity, group);
            }
        }
    }

    /// Update groups when component is removed from entity
    fn updateGroupsOnRemove(self: *World, entity: Entity, component_type_id: TypeId) void {
        for (self.groups.items) |*group| {
            // Check if this component type is part of the group
            var is_group_component = false;
            for (group.component_types) |type_id| {
                if (type_id == component_type_id) {
                    is_group_component = true;
                    break;
                }
            }

            if (is_group_component) {
                self.removeEntityFromGroup(entity, group);
            }
        }
    }

    /// Add entity to a group (move to group area in all component sparse sets)
    fn addEntityToGroup(self: *World, entity: Entity, group: *const GroupInfo) void {
        for (group.component_types) |type_id| {
            self.component_pool.items[type_id].moveToGroup(entity);
        }
    }

    /// Remove entity from a group (move from group area in all component sparse sets)
    fn removeEntityFromGroup(self: *World, entity: Entity, group: *const GroupInfo) void {
        for (group.component_types) |type_id| {
            self.component_pool.items[type_id].moveFromGroup(entity);
        }
    }

    pub fn runSystems(self: *World) !void {
        try self.system_scheduler.run(self);
    }

    pub fn runStartupSystems(self: *World) !void {
        try self.startup_system_scheduler.run(self);
    }

    pub fn runTerminateSystems(self: *World) !void {
        try self.terminate_system_scheduler.run(self);
    }
};

test "World entity creation and destruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    const e1 = world.createEntity();
    const e2 = world.createEntity();

    try std.testing.expect(world.entity_registry.isAlive(e1));
    try std.testing.expect(world.entity_registry.isAlive(e2));
    try std.testing.expectEqual(@as(usize, 2), world.entity_registry.aliveCount());

    world.destroyEntity(e1);
    try std.testing.expect(!world.entity_registry.isAlive(e1));
    try std.testing.expect(world.entity_registry.isAlive(e2));
    try std.testing.expectEqual(@as(usize, 1), world.entity_registry.aliveCount());
}

test "World component registration and operations" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    var comp_set = SparseSet(TestComp).init(allocator);
    defer comp_set.deinit();

    try world.registerComponent(TestComp, &comp_set);

    const entity = world.createEntity();
    try world.addComponent(entity, TestComp, .{ .value = 42 });

    const retrieved = world.getComponent(entity, TestComp);
    try std.testing.expectEqual(@as(i32, 42), retrieved.?.value);

    // Test component not found after entity destruction
    world.destroyEntity(entity);
    try std.testing.expect(world.getComponent(entity, TestComp) == null);
}

test "World multiple components and batch operations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    var pos_set = SparseSet(Position).init(allocator);
    defer pos_set.deinit();
    var vel_set = SparseSet(Velocity).init(allocator);
    defer vel_set.deinit();

    try world.registerComponent(Position, &pos_set);
    try world.registerComponent(Velocity, &vel_set);

    const entity = world.createEntity();
    try world.addComponents(entity, .{
        Position{ .x = 10.0, .y = 20.0 },
        Velocity{ .dx = 1.0, .dy = -1.0 },
    });

    const pos = world.getComponent(entity, Position).?;
    const vel = world.getComponent(entity, Velocity).?;

    try std.testing.expectEqual(@as(f32, 10.0), pos.x);
    try std.testing.expectEqual(@as(f32, 20.0), pos.y);
    try std.testing.expectEqual(@as(f32, 1.0), vel.dx);
    try std.testing.expectEqual(@as(f32, -1.0), vel.dy);
}

test "World unregistered component error" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();

    // Should return ComponentNotRegistered error
    const result = world.addComponent(entity, TestComp, .{ .value = 42 });
    try std.testing.expectError(error.ComponentNotRegistered, result);

    // Should return null for unregistered component
    try std.testing.expect(world.getComponent(entity, TestComp) == null);
}

test "World component re-registration" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    var comp_set1 = SparseSet(TestComp).init(allocator);
    defer comp_set1.deinit();
    var comp_set2 = SparseSet(TestComp).init(allocator);
    defer comp_set2.deinit();

    // Register first set
    try world.registerComponent(TestComp, &comp_set1);
    const entity = world.createEntity();
    try world.addComponent(entity, TestComp, .{ .value = 100 });

    // Re-register with different set should replace
    try world.registerComponent(TestComp, &comp_set2);

    // Previous data should be lost (new sparse set)
    try std.testing.expect(world.getComponent(entity, TestComp) == null);

    // Should work with new set
    try world.addComponent(entity, TestComp, .{ .value = 200 });
    try std.testing.expectEqual(@as(i32, 200), world.getComponent(entity, TestComp).?.value);
}

test "World isAlive entity validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try std.testing.expect(world.isAlive(entity));

    world.destroyEntity(entity);
    try std.testing.expect(!world.isAlive(entity));

    // Test with never-allocated entity
    const fake_entity: Entity = 999999;
    try std.testing.expect(!world.isAlive(fake_entity));
}

test "World hasComponent queries" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    var comp_set = SparseSet(TestComp).init(allocator);
    defer comp_set.deinit();

    try world.registerComponent(TestComp, &comp_set);

    const entity = world.createEntity();

    // Initially no component
    try std.testing.expect(!world.hasComponent(entity, TestComp));

    // Add component
    try world.addComponent(entity, TestComp, .{ .value = 42 });
    try std.testing.expect(world.hasComponent(entity, TestComp));

    // Destroy entity - should no longer have component
    world.destroyEntity(entity);
    try std.testing.expect(!world.hasComponent(entity, TestComp));
}

test "World removeComponent operation" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    var comp_set = SparseSet(TestComp).init(allocator);
    defer comp_set.deinit();

    try world.registerComponent(TestComp, &comp_set);

    const entity = world.createEntity();
    try world.addComponent(entity, TestComp, .{ .value = 42 });

    // Verify component exists
    try std.testing.expect(world.hasComponent(entity, TestComp));
    try std.testing.expectEqual(@as(i32, 42), world.getComponent(entity, TestComp).?.value);

    // Remove component
    world.removeComponent(entity, TestComp);
    try std.testing.expect(!world.hasComponent(entity, TestComp));
    try std.testing.expect(world.getComponent(entity, TestComp) == null);

    // Removing non-existent component should not crash
    world.removeComponent(entity, TestComp);
    try std.testing.expect(world.isAlive(entity)); // Entity should still be alive
}

test "World createEntityWith batch creation" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    var pos_set = SparseSet(Position).init(allocator);
    defer pos_set.deinit();
    var vel_set = SparseSet(Velocity).init(allocator);
    defer vel_set.deinit();

    try world.registerComponent(Position, &pos_set);
    try world.registerComponent(Velocity, &vel_set);

    // Create entity with multiple components
    const entity = try world.createEntityWith(.{
        Position{ .x = 5.0, .y = 10.0 },
        Velocity{ .dx = 2.0, .dy = -1.0 },
    });

    // Verify entity is alive and has both components
    try std.testing.expect(world.isAlive(entity));
    try std.testing.expect(world.hasComponent(entity, Position));
    try std.testing.expect(world.hasComponent(entity, Velocity));

    const pos = world.getComponent(entity, Position).?;
    const vel = world.getComponent(entity, Velocity).?;

    try std.testing.expectEqual(@as(f32, 5.0), pos.x);
    try std.testing.expectEqual(@as(f32, 10.0), pos.y);
    try std.testing.expectEqual(@as(f32, 2.0), vel.dx);
    try std.testing.expectEqual(@as(f32, -1.0), vel.dy);
}
