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

const world_module = @import("world.zig");
const World = world_module.World;

pub fn SingleQuery(comptime Component: type) type {
    // const component_info = @typeInfo(Component).@"struct";

    const Iterator = struct {
        const Self = @This();
        sparse_set: *SparseSet(Component),
        current_index: Entity,

        pub fn next(self: *Self) ?struct { Entity, Component } {
            while (self.current_index < self.sparse_set.components.items.len) {
                const entity = self.sparse_set.packed_array.items[self.current_index];
                const component = self.sparse_set.components.items[self.current_index];
                self.current_index += 1;
                return .{ entity, component };
            }
            return null;
        }
    };

    return struct {
        const Self = @This();
        world: *World,

        pub fn init(world: *World) Self {
            return .{
                .world = world,
            };
        }

        pub fn iterator(self: Self) !Iterator {
            const sparse_set = try self.world.getSparseSet(Component);
            return .{
                .sparse_set = sparse_set,
                .current_index = 0,
            };
        }
    };
}

test "SingleQuery" {
    const Position = struct {
        x: f32,
        y: f32,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();
    const e1 = world.createEntity();
    const e2 = world.createEntity();

    var position_sparse_set = SparseSet(Position).init(allocator);
    defer position_sparse_set.deinit();

    try world.registerComponent(Position, &position_sparse_set);
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });

    const MyQuery = SingleQuery(Position);
    const query = MyQuery.init(&world);
    var iter = try query.iterator();

    var count: usize = 0;
    while (iter.next()) |entry| {
        count += 1;
        const entity, _ = entry;
        try std.testing.expect(world.entity_registry.isAlive(entity));
    }
    try std.testing.expect(count == 2);
}

// pub fn Query(comptime Params: type) type {
// const params_info = @typeInfo(Params).@"struct";

// const Iterator = struct {
// const Self = @This();
// const ReturnParams = Struct{
// .layout = .auto,
// .fields = &([_]StructField{.{
// .name = "entity",
// .type = Entity,
// .is_comptime = false,
// .alignment = @alignOf(Entity),
// }} ++ params_info.fields),
// .is_tuple = true,
// .backing_integer = params_info.backing_integer,
// .decls = params_info.decls,
// };

// world: *World,

// pub fn next(self: *Self) ?ReturnParams {
// _ = self;
// }
// };

// return struct {
// const Self = @This();
// world: *World,

// pub fn init(world: *World) Self {
// return .{
// .world = world,
// };
// }

// pub fn iter(self: Self) Iterator {
// return .{
// .world = self.world,
// };
// }
// };
// }
