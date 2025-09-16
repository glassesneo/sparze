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

pub const SystemScheduler = struct {
    systemsByStages: EnumArray(Stage, [max_systems_per_stage]SystemType),
    systemCounts: EnumArray(Stage, u5),

    pub fn init() SystemScheduler {
        return .{
            .systemsByStages = .initFill([_]SystemType{undefined} ** max_systems_per_stage),
            .systemCounts = .initFill(0),
        };
    }

    pub fn register(self: *SystemScheduler, system: SystemType, stage: Stage) void {
        const count_ptr = self.systemCounts.getPtr(stage);
        self.systemsByStages.getPtr(stage)[count_ptr.*] = system;
        count_ptr.* += 1;
    }

    pub fn run(self: *SystemScheduler, world: *World) !void {
        for (self.systemsByStages.values, self.systemCounts.values) |systems, count| {
            for (0..count) |i| {
                try systems[i](world);
            }
        }
    }
};

pub const Stage = enum {
    first,
    pre_update,
    update,
    post_update,
    pre_render,
    render,
    post_render,
    last,
    post_process,
};

// pub const System = struct {

// vtable: *const VTable,
// const VTable = struct {
// runFn: SystemType,
// };

// pub fn run(self: System, world: *World) !void {
// try self.vtable.runFn(world);
// }

// pub fn init(f: SystemType) System {
// const vtable = VTable{
// .runFn = f,
// };

// return .{
// .vtable = &vtable,
// };
// }
// };

pub const FilterType = enum {
    single_query,
    group,
};

pub fn SingleQuery(comptime QueryParam: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .single_query;

        pub const Iterator = struct {
            sparse_set: *SparseSet(QueryParam),
            current_index: Entity,

            pub fn next(self: *Iterator) ?struct { Entity, QueryParam } {
                while (self.current_index < self.sparse_set.components.items.len) {
                    const entity = self.sparse_set.packed_array.items[self.current_index];
                    const component = self.sparse_set.components.items[self.current_index];

                    self.current_index += 1;
                    return .{ entity, component };
                }
                return null;
            }
        };

        pub const Component = QueryParam;
        world: *World,

        pub fn init(world: *World) Self {
            return .{
                .world = world,
            };
        }

        pub fn iterator(self: Self) !Iterator {
            const sparse_set = try self.world.getSparseSet(QueryParam);
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

pub fn Query(comptime QueryParams: type) type {
    // const Components = @TypeOf(types);
    const query_fields: []const StructField = std.meta.fields(QueryParams);
    // @TypeOf(types) makes a comptime type, so create another one for runtime
    // const Components = runtime_query_types: {
    // var runtime_type_fields: [query_fields.len]StructField = undefined;
    // inline for (types, 0..) |Component, i| {
    // runtime_type_fields[i] = StructField{
    // .name = std.fmt.comptimePrint("{d}", .{i}),
    // .type = Component,
    // .is_comptime = false,
    // .alignment = @alignOf(Component),
    // .default_value_ptr = null,
    // };
    // }
    // break :runtime_query_types @Type(.{ .@"struct" = .{
    // .layout = .auto,
    // .is_tuple = true,
    // .decls = &.{},
    // .fields = &runtime_type_fields,
    // } });
    // };
    // @compileLog(Components);

    return struct {
        const Self = @This();
        pub const Components = QueryParams;
        pub const Iterator = struct {
            // const ReturnParams = @Type(.{ .@"struct" = Struct{
            // .layout = .auto,
            // .fields = (&[_]StructField{.{
            // .name = "0",
            // .type = Entity,
            // .is_comptime = false,
            // .alignment = @alignOf(Entity),
            // .default_value_ptr = null,
            // }} ++ params_info.fields),
            // .is_tuple = true,
            // .backing_integer = params_info.backing_integer,
            // .decls = params_info.decls,
            // } });
            const SparseSetsType = construct_type: {
                var fields: [query_fields.len]StructField = undefined;
                for (query_fields, 0..) |component_struct_field, i| {
                    const Component = component_struct_field.type;
                    const SparseSetType = SparseSet(Component);
                    fields[i] = StructField{
                        .name = std.fmt.comptimePrint("{d}", .{i}),
                        .type = *SparseSetType,
                        .is_comptime = false,
                        .alignment = @alignOf(*SparseSetType),
                        .default_value_ptr = null,
                    };
                }
                break :construct_type @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .is_tuple = true,
                    .decls = &.{},
                    .fields = &fields,
                } });
            };

            sparse_sets: SparseSetsType,
            max_index: Entity,
            current_index: Entity,

            pub fn next(self: *Iterator) ?struct { entity: Entity, components: Components } {
                while (self.current_index < self.max_index) {
                    defer self.current_index += 1;
                    const entity: Entity = 0;
                    var components: QueryParams = undefined;
                    inline for (0..query_fields.len) |i| {
                        components[i] = self.sparse_sets[i].get(entity).?;
                    }
                    return .{ .entity = entity, .components = components };
                }
                return null;
            }
        };
        world: *World,

        pub fn init(world: *World) Self {
            return .{
                .world = world,
            };
        }

        pub fn iter(self: Self) !Iterator {
            var sparse_sets: Iterator.SparseSetsType = undefined;
            var min_len: usize = entity_module.max_entities;
            inline for (query_fields, 0..) |component_struct_field, i| {
                const Component = component_struct_field.type;
                const sparse_set = try self.world.getSparseSet(Component);
                sparse_sets[i] = sparse_set;
                if (sparse_set.components.items.len < min_len) min_len = sparse_set.components.items.len;
            }
            return .{
                .sparse_sets = sparse_sets,
                .max_index = @intCast(min_len),
                .current_index = 0,
            };
        }
    };
}
