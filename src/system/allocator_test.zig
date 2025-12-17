const std = @import("std");

const root = @import("../root.zig");
const SingleQuery = root.SingleQuery;
const Group = root.Group;

// Systems focused on allocator and parameter injection.

test "System function with Allocator parameter" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position }, .{}, .{}, .{});

    const AllocatorSystem = struct {
        fn system(allocator: std.mem.Allocator) !void {
            var list: std.ArrayList(i32) = .{};
            try list.ensureTotalCapacity(allocator, 1);
            defer list.deinit(allocator);

            try list.append(allocator, 42);
            try std.testing.expectEqual(@as(i32, 42), list.items[0]);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.runSystem(AllocatorSystem.system);
}

test "System function with Allocator and query filter parameters" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position }, .{}, .{}, .{});

    const MixedSystem = struct {
        fn system(allocator: std.mem.Allocator, query: SingleQuery(Position)) !void {
            var list: std.ArrayList(f32) = .{};
            defer list.deinit(allocator);

            for (query.components) |pos| {
                try list.append(allocator, pos.x);
            }

            try std.testing.expectEqual(@as(usize, 2), list.items.len);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });

    try world.runSystem(MixedSystem.system);
}

test "System function with Allocator and Commands parameters" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position }, .{}, .{}, .{});

    const SpawnSystem = struct {
        fn system(allocator: std.mem.Allocator, commands: anytype) !void {
            var list: std.ArrayList(i32) = .{};
            defer list.deinit(allocator);

            try list.append(allocator, 1);
            try list.append(allocator, 2);
            try list.append(allocator, 3);

            for (list.items, 0..) |_, i| {
                const entity = commands.createEntity();
                try commands.addComponent(entity, Position, .{
                    .x = @as(f32, @floatFromInt(i)) * 10.0,
                    .y = 0.0,
                });
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    world.beginFrame();
    try world.runSystem(SpawnSystem.system);
    try world.endFrame();

    const query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), query.entities.len);
}

test "System function with Allocator, query filter, and Commands parameters" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(
.{ Position, Velocity },
.{},
.{},
        .{struct { Position, Velocity }},
    );

    const ComplexSystem = struct {
        fn system(
            allocator: std.mem.Allocator,
            movement: Group(struct { Position, Velocity }),
            commands: anytype,
        ) !void {
            var to_duplicate: std.ArrayList(std.meta.Tuple(&[_]type{ Position, Velocity })) = .{};
            defer to_duplicate.deinit(allocator);

            const positions = movement.getArrayOf(Position);
            const velocities = movement.getArrayOf(Velocity);

            for (positions, velocities) |pos, vel| {
                if (pos.x > 50.0) {
                    try to_duplicate.append(allocator, .{ pos, vel });
                }
            }

            for (to_duplicate.items) |item| {
                const entity = commands.createEntity();
                try commands.addComponent(entity, Position, item[0]);
                try commands.addComponent(entity, Velocity, item[1]);
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 100.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 0.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 0.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 2.0, .dy = 0.0 });

    world.beginFrame();
    try world.runSystem(ComplexSystem.system);
    try world.endFrame();

    const query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), query.entities.len);
}

test "System function verifies allocator is world allocator" {
    const TestWorld = @import("../world.zig").World(.{}, .{}, .{}, .{});

    const CheckAllocatorSystem = struct {
        var captured_allocator: ?std.mem.Allocator = null;

        fn system(allocator: std.mem.Allocator) void {
            captured_allocator = allocator;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.runSystem(CheckAllocatorSystem.system);

    try std.testing.expect(CheckAllocatorSystem.captured_allocator != null);
}
