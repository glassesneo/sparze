const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("../core/entity.zig");
const Entity = entity_module.Entity;

pub const FilterType = enum {
    single_query,
    group,
};

/// SingleQuery provides iteration over entities with a specific component for a given FixedWorld type
pub fn SingleQuery(comptime World: type, comptime QueryComponent: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .single_query;
        pub const Component = QueryComponent;

        entities: []const Entity,
        components: []Component,

        pub fn init(world: *World) Self {
            const sparse_set = world.getSparseSetPtr(Component);
            return .{
                .entities = sparse_set.packed_array.items,
                .components = sparse_set.components.items,
            };
        }
    };
}

/// Group provides fast iteration over entities with multiple components for a given FixedWorld type
pub fn Group(comptime World: type, comptime GroupComponents: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .group;
        pub const ComponentTypes = GroupComponents;

        world: *World,

        pub fn init(world: *World) Self {
            return .{ .world = world };
        }

        pub fn getEntities(self: Self) []const Entity {
            return self.world.getGroupEntities(ComponentTypes) orelse &[_]Entity{};
        }

        pub fn getArrayOf(self: Self, comptime C: type) []const C {
            return self.world.getGroupComponents(ComponentTypes, C) orelse &[_]C{};
        }

        pub fn getMutArrayOf(self: Self, comptime C: type) []C {
            return self.world.getGroupComponentsMut(ComponentTypes, C) orelse &[_]C{};
        }
    };
}

fn constructSystemArgsType(comptime fn_info: std.builtin.Type.Fn) type {
    var fields: [fn_info.params.len]StructField = undefined;
    for (fn_info.params, 0..) |param, i| {
        const ArgType = param.type orelse @compileError("System function must have typed parameters");
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

/// Create a system function for a specific FixedWorld type that can be called with world.runSystem(system_fn)
pub fn createSystemFunction(comptime World: type, comptime system_fn: anytype) fn (*World) anyerror!void {
    const system_type_info = switch (@typeInfo(@TypeOf(system_fn))) {
        .@"fn" => |f| f,
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(system_fn))),
    };

    const SystemArgsType = constructSystemArgsType(system_type_info);

    return struct {
        fn run(world: *World) !void {
            const system_args = construct_args: {
                var args: SystemArgsType = undefined;
                inline for (system_type_info.params, 0..) |param, i| {
                    const ArgType = param.type.?;
                    if (!@hasDecl(ArgType, "filter_type")) {
                        @compileError("System parameter must be a Query or Group type. Got: " ++ @typeName(ArgType));
                    }

                    const filter_type: FilterType = ArgType.filter_type;
                    switch (filter_type) {
                        .single_query => {
                            args[i] = ArgType.init(world);
                        },
                        .group => {
                            args[i] = ArgType.init(world);
                        },
                    }
                }
                break :construct_args args;
            };

            try @call(.auto, system_fn, system_args);
        }
    }.run;
}

test "FixedSingleQuery basic iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = @import("world.zig").FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create entities with positions
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    // Query all positions
    const PositionQuery = SingleQuery(Position);
    const query = PositionQuery.init(&world);

    try std.testing.expectEqual(@as(usize, 2), query.entities.len);
    try std.testing.expectEqual(@as(usize, 2), query.components.len);

    var count: usize = 0;
    for (query.entities, query.components) |entity, pos| {
        try std.testing.expect(world.isAlive(entity));
        try std.testing.expect(pos.x >= 10.0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "FixedGroup query basic usage" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = @import("world.zig").FixedWorld(struct { Position, Velocity });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create group first
    try world.createGroup(World, struct { Position, Velocity });

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    // e2 has no velocity - not in group

    // Use Group query
    const MovementGroup = Group(World, struct { Position, Velocity });
    const group = MovementGroup.init(&world);

    const entities = group.getEntities();
    const positions = group.getArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    try std.testing.expectEqual(@as(usize, 1), entities.len);
    try std.testing.expectEqual(@as(usize, 1), positions.len);
    try std.testing.expectEqual(@as(usize, 1), velocities.len);

    try std.testing.expectEqual(@as(f32, 1.0), positions[0].x);
    try std.testing.expectEqual(@as(f32, 0.5), velocities[0].dx);
}

test "FixedWorld system function with SingleQuery" {
    const Position = struct { x: f32, y: f32 };

    const World = @import("world.zig").FixedWorld(struct { Position });

    const UpdatePositions = struct {
        fn system(query: SingleQuery(Position)) !void {
            for (query.components) |*pos| {
                pos.x += 1.0;
                pos.y += 1.0;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 5.0, .y = 15.0 });

    // Run the system
    try world.runSystem(UpdatePositions.system);

    // Verify updates
    try std.testing.expectEqual(@as(f32, 11.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 21.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 6.0), world.getComponent(e2, Position).?.x);
}

test "FixedWorld system function with Group" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const World = @import("world.zig").FixedWorld(struct { Position, Velocity });

    const MovementSystem = struct {
        fn system(group: Group(World, struct { Position, Velocity })) !void {
            const positions = group.getMutArrayOf(Position);
            const velocities = group.getArrayOf(Velocity);

            for (positions, velocities) |*pos, vel| {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    try world.createGroup(World, struct { Position, Velocity });

    // Create moving entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Run the system
    try world.runSystem(MovementSystem.system);

    // Verify positions updated
    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 2.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 9.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 18.0), world.getComponent(e2, Position).?.y);
}

test "FixedWorld system with multiple queries" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const World = @import("world.zig").FixedWorld(struct { Position, Velocity, Health });

    const ComplexSystem = struct {
        fn system(
            movement: Group(World, struct { Position, Velocity }),
            health_query: SingleQuery(Health),
        ) !void {
            // Update movement
            const positions = movement.getMutArrayOf(Position);
            const velocities = movement.getArrayOf(Velocity);
            for (positions, velocities) |*pos, vel| {
                pos.x += vel.dx;
            }

            // Process health (just count for this test)
            var health_count: usize = 0;
            for (health_query.components) |_| {
                health_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 2), health_count);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    try world.createGroup(World, struct { Position, Velocity });

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Health, .{ .hp = 50 });

    try world.runSystem(ComplexSystem.system);

    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
}
