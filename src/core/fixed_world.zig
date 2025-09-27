const std = @import("std");
const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;
const Allocator = std.mem.Allocator;
pub const ArrayList = std.ArrayList;

const entity_module = @import("entity.zig");
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;

const sparse_set_module = @import("sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const system_module = @import("system.zig");
// const SystemScheduler = system_module.SystemScheduler;
const Stage = system_module.Stage;
const FilterType = system_module.FilterType;
const SingleQuery = system_module.SingleQuery;

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
            };
        }

        pub fn deinit(self: *Self) void {
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
            self.getSparseSetPtr(C).remove(entity);
        }

        pub fn createEntityWith(self: *Self, comptime components: anytype) !Entity {
            const entity = self.createEntity();
            try self.addComponents(entity, components);
            return entity;
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
