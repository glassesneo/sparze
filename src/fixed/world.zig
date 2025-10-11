const std = @import("std");
const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;
const Allocator = std.mem.Allocator;
pub const ArrayList = std.ArrayList;

const entity_module = @import("../core/entity.zig");
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;

const sparse_set_module = @import("../core/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const system_module = @import("system.zig");
pub const FilterType = system_module.FilterType;
pub const SingleQuery = system_module.SingleQuery;
pub const Query = system_module.Query;
pub const Group = system_module.Group;
pub const createSystemFunction = system_module.createSystemFunction;

/// Information about a full-owning group
const GroupInfo = struct {
    component_ids: []const u16, // Component IDs in this world
};

pub fn FixedWorld(Components: anytype) type {
    const info = @typeInfo(Components);
    if (info != .@"struct") @compileError("Invalid form of components");
    const component_fields = info.@"struct".fields;
    const length = info.@"struct".fields.len;

    const ComponentPoolType = construct_component_pool: {
        if (length == 0) break :construct_component_pool @TypeOf(.{});
        var sparse_set_fields: [length]StructField = undefined;
        inline for (component_fields, 0..) |field, i| {
            const SparseSetType = SparseSet(field.type);
            sparse_set_fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = SparseSetType,
                .is_comptime = false,
                .alignment = @alignOf(SparseSetType),
                .default_value_ptr = null,
            };
        }
        break :construct_component_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &sparse_set_fields,
        } });
    };

    return struct {
        const Self = @This();

        allocator: Allocator,
        entity_registry: EntityRegistry,
        component_pool: ComponentPoolType,
        groups: ArrayList(GroupInfo),

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .entity_registry = .init(),
                .component_pool = init: {
                    var pool: ComponentPoolType = undefined;
                    inline for (component_fields, 0..) |field, i| {
                        pool[i] = SparseSet(field.type).init(allocator);
                    }
                    break :init pool;
                },
                .groups = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.groups.items) |*group| {
                self.allocator.free(group.component_ids);
            }
            self.groups.deinit(self.allocator);
            inline for (component_fields) |field| {
                const sparse_set = self.getSparseSetPtr(field.type);
                sparse_set.deinit();
            }
        }

        pub fn getComponentId(comptime C: type) u16 {
            // The order of components become the id
            return inline for (component_fields, 0..) |field, i| {
                if (C == field.type) break i;
            } else @compileError("Unknown component type: " ++ @typeName(C));
        }

        /// Compile-time validation for multiple groups to detect overlaps.
        ///
        /// This validates that:
        /// 1. All component types exist in this world
        /// 2. No component appears in multiple groups (which would break the full-owning group model)
        ///
        /// Usage:
        /// ```zig
        /// const World = FixedWorld(struct { A, B, C, D });
        ///
        /// // Validate all groups upfront - compile error if overlapping
        /// World.validateGroups(.{
        ///     struct { A, B },
        ///     struct { C, D },
        /// });
        /// ```
        ///
        /// This is the recommended approach - declare all groups upfront for compile-time safety.
        pub fn validateGroups(comptime groups: anytype) void {
            const groups_info = @typeInfo(@TypeOf(groups));
            if (groups_info != .@"struct" or !groups_info.@"struct".is_tuple) {
                @compileError("validateGroups expects a tuple of group types");
            }

            const group_list = groups_info.@"struct".fields;

            // Validate each group's components are in this world
            inline for (group_list) |group_field| {
                const GroupType = @field(groups, group_field.name);
                const group_fields = comptime std.meta.fields(GroupType);
                inline for (group_fields) |field| {
                    _ = getComponentId(field.type);
                }
            }

            // Check each pair of groups for overlap
            inline for (group_list, 0..) |group1_field, i| {
                const Group1Type = @field(groups, group1_field.name);
                const group1_fields = comptime std.meta.fields(Group1Type);

                inline for (group_list, 0..) |group2_field, j| {
                    if (i >= j) continue;

                    const Group2Type = @field(groups, group2_field.name);
                    const group2_fields = comptime std.meta.fields(Group2Type);

                    inline for (group1_fields) |field1| {
                        inline for (group2_fields) |field2| {
                            if (field1.type == field2.type) {
                                @compileError("Groups have overlapping component: " ++ @typeName(field1.type) ++
                                    " appears in both " ++ @typeName(Group1Type) ++ " and " ++ @typeName(Group2Type));
                            }
                        }
                    }
                }
            }
        }

        pub fn getSparseSet(self: Self, comptime C: type) SparseSet(C) {
            const id = comptime getComponentId(C);
            return self.component_pool[id];
        }

        pub fn getSparseSetPtr(self: *Self, comptime C: type) *SparseSet(C) {
            const id = comptime getComponentId(C);
            return &self.component_pool[id];
        }

        /// Complexity: O(1).
        pub fn createEntity(self: *Self) Entity {
            return self.entity_registry.create();
        }

        /// Destroys an Entity and removes it from all registered component pools.
        /// The entity identifier becomes invalid and may be recycled for future entities.
        /// Complexity: O(c) where c = number of registered component types.
        pub fn destroyEntity(self: *Self, entity: Entity) void {
            self.entity_registry.destroy(entity);
            inline for (component_fields) |field| {
                self.removeComponent(entity, field.type);
            }
        }

        pub fn addComponent(self: *Self, entity: Entity, comptime C: type, component: C) !void {
            try self.getSparseSetPtr(C).insert(entity, component);

            // Update groups when component is added
            const component_id = comptime getComponentId(C);
            self.updateGroupsOnAdd(entity, component_id);
        }

        pub fn addComponents(self: *Self, entity: Entity, comptime components: anytype) !void {
            inline for (components) |component| {
                const C = @TypeOf(component);
                try self.addComponent(entity, C, component);
            }
        }

        pub fn getComponent(self: *Self, entity: Entity, comptime C: type) ?C {
            return self.getSparseSetPtr(C).get(entity);
        }

        pub fn isAlive(self: Self, entity: Entity) bool {
            return self.entity_registry.isAlive(entity);
        }

        pub fn hasComponent(self: Self, entity: Entity, comptime C: type) bool {
            return self.getSparseSet(C).contains(entity);
        }

        pub fn removeComponent(self: *Self, entity: Entity, comptime C: type) void {
            // Update groups before removing component
            const component_id = comptime getComponentId(C);
            self.updateGroupsOnRemove(entity, component_id);

            self.getSparseSetPtr(C).remove(entity);
        }

        pub fn createEntityWith(self: *Self, comptime components: anytype) !Entity {
            const entity = self.createEntity();
            try self.addComponents(entity, components);
            return entity;
        }

        /// Create a full-owning group for the given component types
        pub fn createGroup(self: *Self, comptime GroupComponents: type) !void {
            const group_fields = comptime std.meta.fields(GroupComponents);
            if (group_fields.len == 0) @compileError("Cannot create group with zero components");

            // Compile-time validation: ensure all component types are valid for this world
            comptime {
                for (group_fields) |field| {
                    _ = getComponentId(field.type); // Will compile error if type not in world
                }
            }

            // Check if group already exists by comparing component IDs
            const new_ids = comptime blk: {
                var ids: [group_fields.len]u16 = undefined;
                for (group_fields, 0..) |field, i| {
                    ids[i] = getComponentId(field.type);
                }
                break :blk ids;
            };

            for (self.groups.items) |*group| {
                if (group.component_ids.len == new_ids.len) {
                    var matches = true;
                    for (group.component_ids, 0..) |id, i| {
                        if (id != new_ids[i]) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) return; // Group already exists
                }
            }

            var component_ids = try self.allocator.alloc(u16, group_fields.len);
            inline for (group_fields, 0..) |field, i| {
                component_ids[i] = comptime getComponentId(field.type);
            }

            try self.groups.append(self.allocator, GroupInfo{
                .component_ids = component_ids,
            });

            // Populate the group with existing entities that have all components
            self.populateGroup(GroupComponents);
        }

        /// Get group information by component types
        pub fn getGroup(self: *const Self, comptime GroupComponents: type) ?*const GroupInfo {
            const group_fields = comptime std.meta.fields(GroupComponents);
            const target_ids = comptime blk: {
                var ids: [group_fields.len]u16 = undefined;
                for (group_fields, 0..) |field, i| {
                    ids[i] = getComponentId(field.type);
                }
                break :blk ids;
            };

            for (self.groups.items) |*group| {
                if (group.component_ids.len == target_ids.len) {
                    var matches = true;
                    for (group.component_ids, 0..) |id, i| {
                        if (id != target_ids[i]) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) return group;
                }
            }
            return null;
        }

        /// Get entities in a group (fast iteration)
        pub fn getGroupEntities(self: *const Self, comptime GroupComponents: type) ?[]const Entity {
            const group = self.getGroup(GroupComponents) orelse return null;
            const first_id = group.component_ids[0];

            // Use inline for to access tuple element at runtime
            inline for (component_fields, 0..) |_, i| {
                if (first_id == i) {
                    return self.component_pool[i].getGroupEntities();
                }
            }
            return null;
        }

        /// Get components of a specific type in a group (fast iteration)
        pub fn getGroupComponents(self: *const Self, comptime GroupComponents: type, comptime C: type) ?[]const C {
            const group = self.getGroup(GroupComponents) orelse return null;
            const component_id = comptime getComponentId(C);

            // Check if this component type is part of the group
            for (group.component_ids) |group_id| {
                if (group_id == component_id) {
                    // Use inline for to access tuple element at runtime
                    inline for (component_fields, 0..) |_, i| {
                        if (component_id == i) {
                            return self.component_pool[i].getGroupComponents();
                        }
                    }
                }
            }
            return null;
        }

        pub fn getGroupComponentsMut(self: *Self, comptime GroupComponents: type, comptime C: type) ?[]C {
            const group = self.getGroup(GroupComponents) orelse return null;
            const component_id = comptime getComponentId(C);

            // Check if this component type is part of the group
            for (group.component_ids) |group_id| {
                if (group_id == component_id) {
                    // Use inline for to access tuple element at runtime
                    inline for (component_fields, 0..) |_, i| {
                        if (component_id == i) {
                            return self.component_pool[i].getGroupComponentsMut();
                        }
                    }
                }
            }
            return null;
        }

        /// Populate group with existing entities that have all required components
        fn populateGroup(self: *Self, comptime GroupComponents: type) void {
            const group = self.getGroup(GroupComponents) orelse return;
            if (group.component_ids.len == 0) return;

            // Find the shortest sparse set to minimize iterations
            var min_size: usize = std.math.maxInt(usize);
            var shortest_id: u16 = group.component_ids[0];

            for (group.component_ids) |id| {
                inline for (component_fields, 0..) |_, i| {
                    if (id == i) {
                        const entities = self.component_pool[i].packed_array.items;
                        if (entities.len < min_size) {
                            min_size = entities.len;
                            shortest_id = id;
                        }
                    }
                }
            }

            // Iterate through shortest set and check if entities have all components
            inline for (component_fields, 0..) |_, i| {
                if (shortest_id == i) {
                    const entities = self.component_pool[i].packed_array.items;
                    for (entities) |entity| {
                        if (self.entityHasAllGroupComponents(entity, group.component_ids)) {
                            self.addEntityToGroup(entity, group);
                        }
                    }
                }
            }
        }

        /// Check if entity has all required components for a group
        fn entityHasAllGroupComponents(self: *const Self, entity: Entity, component_ids: []const u16) bool {
            for (component_ids) |id| {
                var has_component = false;
                inline for (component_fields, 0..) |_, i| {
                    if (id == i) {
                        if (self.component_pool[i].contains(entity)) {
                            has_component = true;
                        }
                    }
                }
                if (!has_component) return false;
            }
            return true;
        }

        /// Update groups when component is added to entity
        fn updateGroupsOnAdd(self: *Self, entity: Entity, component_id: u16) void {
            for (self.groups.items) |*group| {
                // Check if this component type is part of the group
                var is_group_component = false;
                for (group.component_ids) |id| {
                    if (id == component_id) {
                        is_group_component = true;
                        break;
                    }
                }

                if (is_group_component and self.entityHasAllGroupComponents(entity, group.component_ids)) {
                    self.addEntityToGroup(entity, group);
                }
            }
        }

        /// Update groups when component is removed from entity
        fn updateGroupsOnRemove(self: *Self, entity: Entity, component_id: u16) void {
            for (self.groups.items) |*group| {
                // Check if this component type is part of the group
                var is_group_component = false;
                for (group.component_ids) |id| {
                    if (id == component_id) {
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
        fn addEntityToGroup(self: *Self, entity: Entity, group: *const GroupInfo) void {
            for (group.component_ids) |id| {
                inline for (component_fields, 0..) |_, i| {
                    if (id == i) {
                        self.component_pool[i].moveToGroup(entity);
                    }
                }
            }
        }

        /// Remove entity from a group (move from group area in all component sparse sets)
        fn removeEntityFromGroup(self: *Self, entity: Entity, group: *const GroupInfo) void {
            for (group.component_ids) |id| {
                inline for (component_fields, 0..) |_, i| {
                    if (id == i) {
                        self.component_pool[i].moveFromGroup(entity);
                    }
                }
            }
        }

        /// Convenience method to run a system directly
        pub fn runSystem(self: *Self, comptime system_fn: anytype) !void {
            const system = comptime system_module.createSystemFunction(Self, system_fn);
            try system(self);
        }
    };
}

test "Create FixedWorld" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    try std.testing.expectEqual(0, World.getComponentId(Position));
    try std.testing.expectEqual(1, World.getComponentId(Velocity));
}

test "World entity creation and destruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const World = FixedWorld(struct {});

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

    const World = FixedWorld(struct { TestComp });

    var world = World.init(allocator);
    defer world.deinit();

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

    const World = FixedWorld(struct { Position, Velocity });

    var world = World.init(allocator);
    defer world.deinit();

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

test "World isAlive entity validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const World = FixedWorld(struct {});

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

    const World = FixedWorld(struct { TestComp });

    var world = World.init(allocator);
    defer world.deinit();

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

    const World = FixedWorld(struct { TestComp });

    var world = World.init(allocator);
    defer world.deinit();

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

    const World = FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

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

test "FixedWorld group creation and basic operations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const World = FixedWorld(struct { Position, Velocity, Health });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create group for Position and Velocity
    try world.createGroup(struct { Position, Velocity });

    // Verify group was created
    const group = world.getGroup(struct { Position, Velocity });
    try std.testing.expect(group != null);
    try std.testing.expectEqual(@as(usize, 2), group.?.component_ids.len);

    // Create entities with different component combinations
    const e1 = world.createEntity();
    const e2 = world.createEntity();
    const e3 = world.createEntity();

    // e1 has both Position and Velocity (in group)
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });

    // e2 has only Position (not in group)
    try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });

    // e3 has both Position and Velocity (in group)
    try world.addComponent(e3, Position, .{ .x = 5.0, .y = 6.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 1.5, .dy = 2.0 });

    // Verify group entities
    const group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 2), group_entities.len);

    // Verify we can get group components
    const positions = world.getGroupComponents(struct { Position, Velocity }, Position).?;
    const velocities = world.getGroupComponents(struct { Position, Velocity }, Velocity).?;

    try std.testing.expectEqual(@as(usize, 2), positions.len);
    try std.testing.expectEqual(@as(usize, 2), velocities.len);
}

test "FixedWorld group dynamic membership" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create entities first
    const e1 = world.createEntity();
    const e2 = world.createEntity();

    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 1.0 });

    // Create group - should include e2 only
    try world.createGroup(struct { Position, Velocity });

    var group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 1), group_entities.len);

    // Add Velocity to e1 - should join group
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 0.5 });

    group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 2), group_entities.len);

    // Remove Velocity from e1 - should leave group
    world.removeComponent(e1, Velocity);

    group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 1), group_entities.len);
}

test "FixedWorld group mutable component access" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.5, .dy = 2.0 });

    // Get mutable access to group components
    const positions = world.getGroupComponentsMut(struct { Position, Velocity }, Position).?;
    const velocities = world.getGroupComponentsMut(struct { Position, Velocity }, Velocity).?;

    try std.testing.expectEqual(@as(usize, 2), positions.len);
    try std.testing.expectEqual(@as(usize, 2), velocities.len);

    // Modify components
    for (positions) |*pos| {
        pos.x += 10.0;
        pos.y += 10.0;
    }

    for (velocities) |*vel| {
        vel.dx *= 2.0;
        vel.dy *= 2.0;
    }

    // Verify modifications
    const pos1 = world.getComponent(e1, Position).?;
    try std.testing.expectEqual(@as(f32, 11.0), pos1.x);
    try std.testing.expectEqual(@as(f32, 12.0), pos1.y);

    const vel1 = world.getComponent(e1, Velocity).?;
    try std.testing.expectEqual(@as(f32, 1.0), vel1.dx);
    try std.testing.expectEqual(@as(f32, 2.0), vel1.dy);
}

test "FixedWorld multiple groups with non-overlapping components" {
    const A = struct { value: i32 };
    const B = struct { value: i32 };
    const C = struct { value: i32 };
    const D = struct { value: i32 };

    const World = FixedWorld(struct { A, B, C, D });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create two different groups with non-overlapping components
    try world.createGroup(struct { A, B });
    try world.createGroup(struct { C, D });

    // Create entities with different component combinations
    const e1 = world.createEntity();
    try world.addComponent(e1, A, .{ .value = 1 });
    try world.addComponent(e1, B, .{ .value = 2 });

    const e2 = world.createEntity();
    try world.addComponent(e2, C, .{ .value = 3 });
    try world.addComponent(e2, D, .{ .value = 4 });

    const e3 = world.createEntity();
    try world.addComponent(e3, A, .{ .value = 5 });
    try world.addComponent(e3, B, .{ .value = 6 });

    // Verify first group (A, B) contains e1 and e3
    const group1_entities = world.getGroupEntities(struct { A, B }).?;
    try std.testing.expectEqual(@as(usize, 2), group1_entities.len);

    // Verify second group (C, D) contains only e2
    const group2_entities = world.getGroupEntities(struct { C, D }).?;
    try std.testing.expectEqual(@as(usize, 1), group2_entities.len);
}

test "FixedWorld group with component not in group" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    // Try to get Velocity components from Position group (should return null)
    const velocities = world.getGroupComponents(struct { Position }, Velocity);
    try std.testing.expect(velocities == null);
}

test "FixedWorld can create identical group twice without error" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create group
    try world.createGroup(struct { Position, Velocity });

    // Try to create same group again - should succeed (idempotent)
    try world.createGroup(struct { Position, Velocity });

    // Verify only one group exists
    try std.testing.expectEqual(@as(usize, 1), world.groups.items.len);
}

test "FixedWorld compile-time group validation - non-overlapping" {
    const A = struct { value: i32 };
    const B = struct { value: i32 };
    const C = struct { value: i32 };
    const D = struct { value: i32 };

    const World = FixedWorld(struct { A, B, C, D });

    // Compile-time validation of non-overlapping groups - should compile fine
    World.validateGroups(.{
        struct { A, B },
        struct { C, D },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Runtime creation should work
    try world.createGroup(struct { A, B });
    try world.createGroup(struct { C, D });

    try std.testing.expectEqual(@as(usize, 2), world.groups.items.len);
}

test "FixedWorld recommended usage pattern - validate groups upfront" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };
    const Armor = struct { value: i32 };

    const World = FixedWorld(struct { Position, Velocity, Health, Armor });

    // Recommended: Validate all groups at compile time before creating them
    World.validateGroups(.{
        struct { Position, Velocity }, // Movement entities
        struct { Health, Armor }, // Combat entities
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Now create the groups - we know they're valid
    try world.createGroup(struct { Position, Velocity });
    try world.createGroup(struct { Health, Armor });

    // Create test entities
    const moving_entity = world.createEntity();
    try world.addComponent(moving_entity, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(moving_entity, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const combat_entity = world.createEntity();
    try world.addComponent(combat_entity, Health, .{ .hp = 100 });
    try world.addComponent(combat_entity, Armor, .{ .value = 50 });

    // Verify groups work correctly
    const movement_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    const combat_entities = world.getGroupEntities(struct { Health, Armor }).?;

    try std.testing.expectEqual(@as(usize, 1), movement_entities.len);
    try std.testing.expectEqual(@as(usize, 1), combat_entities.len);

    // Fast iteration over group components
    const positions = world.getGroupComponents(struct { Position, Velocity }, Position).?;
    try std.testing.expectEqual(@as(f32, 10.0), positions[0].x);
}

// Uncomment this test to see compile-time error for overlapping groups
// test "FixedWorld compile-time group validation - overlapping (should fail)" {
//     const A = struct { value: i32 };
//     const B = struct { value: i32 };
//     const C = struct { value: i32 };
//
//     const World = FixedWorld(struct { A, B, C });
//
//     // This will cause a compile error: B appears in both groups
//     World.validateGroups(.{
//         struct { A, B },
//         struct { B, C },
//     });
// }
