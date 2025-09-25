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

pub const SystemType = fn (*World) anyerror!void;
pub const SystemPointerType = *const SystemType;

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

pub fn createSystemFunction(comptime system_fn: anytype) SystemType {
    const system_type_info = switch (@typeInfo(@TypeOf(system_fn))) {
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
