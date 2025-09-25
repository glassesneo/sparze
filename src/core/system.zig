const std = @import("std");
const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const EnumArray = std.EnumArray;

const entity_module = @import("entity.zig");
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;

const sparse_set_module = @import("sparse_set.zig");
const AbstractSparseSet = sparse_set_module.AbstractSparseSet;
const SparseSet = sparse_set_module.SparseSet;

const world_module = @import("world.zig");
const World = world_module.World;

const max_systems_per_stage = 1024;

const SystemType = *const fn (*World) anyerror!void;

// pub const SystemScheduler = struct {
// systemsByStages: EnumArray(Stage, [max_systems_per_stage]SystemType),
// systemCounts: EnumArray(Stage, u5),

// pub fn init() SystemScheduler {
// return .{
// .systemsByStages = .initFill([_]SystemType{undefined} ** max_systems_per_stage),
// .systemCounts = .initFill(0),
// };
// }

// pub fn register(self: *SystemScheduler, system: SystemType, stage: Stage) void {
// const count_ptr = self.systemCounts.getPtr(stage);
// self.systemsByStages.getPtr(stage)[count_ptr.*] = system;
// count_ptr.* += 1;
// }

// pub fn run(self: *SystemScheduler, world: *World) !void {
// for (self.systemsByStages.values, self.systemCounts.values) |systems, count| {
// for (0..count) |i| {
// try systems[i](world);
// }
// }
// }
// };

// pub const Stage = enum {
// first,
// pre_update,
// update,
// post_update,
// pre_render,
// render,
// post_render,
// last,
// post_process,
// };

pub const FilterType = enum {
    single_query,
    group,
};

pub fn SingleQuery(comptime QueryParam: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .single_query;

        pub const Component = QueryParam;
        entities: []const Entity,
        components: []Component,

        pub fn init(world: *World) !Self {
            const sparse_set = try world.getSparseSet(Component);
            return .{
                .entities = sparse_set.packed_array.items,
                .components = sparse_set.components.items,
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
    const query = try MyQuery.init(&world);

    var count: usize = 0;
    for (query.entities, query.components) |entity, component| {
        count += 1;
        _ = component;
        try std.testing.expect(world.entity_registry.isAlive(entity));
    }
    try std.testing.expect(count == 2);
}

pub fn Group(comptime GroupQueryParams: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .group;

        pub const Components = GroupQueryParams;

        world: *World,

        pub fn init(world: *World) Self {
            return .{
                .world = world,
            };
        }

        pub fn getEntities(self: Self) []const Entity {
            return self.world.getGroupEntities(Components).?;
        }

        pub fn getArrayOf(self: Self, comptime Component: type) []const Component {
            return self.world.getGroupComponents(Components, Component).?;
        }

        pub fn getMutArrayOf(self: Self, comptime Component: type) []Component {
            return self.world.getGroupComponentsMut(Components, Component).?;
        }
    };
}
