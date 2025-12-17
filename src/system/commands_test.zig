const std = @import("std");

const root = @import("../root.zig");
const SingleQuery = root.SingleQuery;
const SingleTag = root.SingleTag;

const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;
const getIndex = entity_module.getIndex;
const getVersion = entity_module.getVersion;

test "Commands with frame-based execution" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity, Enemy }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const spawnEnemies = struct {
        fn system(commands: anytype) !void {
            for (0..3) |i| {
                const enemy = commands.createEntity();
                try commands.addComponent(enemy, Position, .{
                    .x = @as(f32, @floatFromInt(i)) * 10.0,
                    .y = 100.0,
                });
                try commands.addComponent(enemy, Velocity, .{ .dx = 1.0, .dy = 0.0 });
                try commands.addTag(enemy, Enemy);
            }
        }
    }.system;

    world.beginFrame();
    try world.runSystem(spawnEnemies);

    const enemy_tag_before = SingleTag(Enemy).init(world.getTagStoragePtr(Enemy));
    try std.testing.expectEqual(@as(usize, 0), enemy_tag_before.entities.len);

    try world.endFrame();

    const enemy_tag_after = SingleTag(Enemy).init(world.getTagStoragePtr(Enemy));
    try std.testing.expectEqual(@as(usize, 3), enemy_tag_after.entities.len);

    const position_query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), position_query.entities.len);

    const velocity_query = SingleQuery(Velocity).init(world.getSparseSetPtr(Velocity));
    try std.testing.expectEqual(@as(usize, 3), velocity_query.entities.len);
}

test "Commands remove and destroy operations" {
    const Health = struct { hp: i32 };
    const Dead = struct {};

    const TestWorld = @import("../world.zig").World(.{ Health, Dead }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const e1 = world.createEntity();
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Health, .{ .hp = 0 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Health, .{ .hp = 50 });

    const deathSystem = struct {
        fn system(query: SingleQuery(Health), commands: anytype) !void {
            for (query.entities, query.components) |entity, health| {
                if (health.hp <= 0) {
                    try commands.addTag(entity, Dead);
                    try commands.removeComponent(entity, Health);
                } else if (health.hp < 25) {
                    try commands.destroyEntity(entity);
                }
            }
        }
    }.system;

    world.beginFrame();
    try world.runSystem(deathSystem);
    try world.endFrame();

    try std.testing.expect(world.isAlive(e1));
    try std.testing.expect(world.hasComponent(e1, Health));

    try std.testing.expect(world.isAlive(e2));
    try std.testing.expect(!world.hasComponent(e2, Health));
    try std.testing.expect(world.hasComponent(e2, Dead));

    try std.testing.expect(world.isAlive(e3));
}

test "Commands createEntityWith convenience method" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const spawnWithBatch = struct {
        fn system(commands: anytype) !void {
            _ = try commands.createEntityWith(.{
                Position{ .x = 10.0, .y = 20.0 },
                Velocity{ .dx = 1.0, .dy = 2.0 },
            });
        }
    }.system;

    world.beginFrame();
    try world.runSystem(spawnWithBatch);
    try world.endFrame();

    const pos_query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 1), pos_query.entities.len);
    try std.testing.expectEqual(@as(f32, 10.0), pos_query.components[0].x);

    const vel_query = SingleQuery(Velocity).init(world.getSparseSetPtr(Velocity));
    try std.testing.expectEqual(@as(usize, 1), vel_query.entities.len);
    try std.testing.expectEqual(@as(f32, 1.0), vel_query.components[0].dx);
}

test "Commands destroyEntity handles multiple destroy commands for same entity" {
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(.{Health}, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try world.addComponent(entity, Health, .{ .hp = 100 });

    const DestroySystem1 = struct {
        var target: ?Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    const DestroySystem2 = struct {
        var target: ?Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    const DestroySystem3 = struct {
        var target: ?Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    DestroySystem1.target = entity;
    DestroySystem2.target = entity;
    DestroySystem3.target = entity;

    try std.testing.expect(world.isAlive(entity));
    try std.testing.expect(world.hasComponent(entity, Health));

    world.beginFrame();
    try world.runSystem(DestroySystem1.system);
    try world.runSystem(DestroySystem2.system);
    try world.runSystem(DestroySystem3.system);
    try std.testing.expect(world.isAlive(entity));

    try world.endFrame();

    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expect(!world.hasComponent(entity, Health));
}

test "Commands prevent zombie entity: destroy then add component" {
    const Position = struct { x: f32, y: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Health }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 100.0, .y = 50.0 });

    const ZombieSystem = struct {
        var target: ?Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
                try commands.addComponent(e, Health, .{ .hp = 100 });
            }
        }
    };

    ZombieSystem.target = entity;

    try std.testing.expect(world.isAlive(entity));
    try std.testing.expect(world.hasComponent(entity, Position));

    world.beginFrame();
    try world.runSystem(ZombieSystem.system);
    try world.endFrame();

    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expect(!world.hasComponent(entity, Position));
    try std.testing.expect(!world.hasComponent(entity, Health));
}

test "Commands prevent zombie entity: destroy then remove component" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 100.0, .y = 50.0 });
    try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const ZombieSystem = struct {
        var target: ?Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
                try commands.removeComponent(e, Velocity);
            }
        }
    };

    ZombieSystem.target = entity;

    world.beginFrame();
    try world.runSystem(ZombieSystem.system);
    try world.endFrame();

    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expect(!world.hasComponent(entity, Position));
    try std.testing.expect(!world.hasComponent(entity, Velocity));
}

test "Commands handle entity recycling with version validation" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(.{Position}, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity_v0 = world.createEntity();
    try world.addComponent(entity_v0, Position, .{ .x = 100.0, .y = 50.0 });

    try std.testing.expect(world.isAlive(entity_v0));

    world.destroyEntity(entity_v0);
    try std.testing.expect(!world.isAlive(entity_v0));

    const entity_v1 = world.createEntity();

    try std.testing.expectEqual(getIndex(entity_v0), getIndex(entity_v1));
    try std.testing.expect(getVersion(entity_v0) != getVersion(entity_v1));

    const StaleCommandSystem = struct {
        var stale_entity: ?Entity = null;

        fn system(commands: anytype) !void {
            if (stale_entity) |e| {
                try commands.addComponent(e, Position, .{ .x = 999.0, .y = 999.0 });
            }
        }
    };

    StaleCommandSystem.stale_entity = entity_v0;

    world.beginFrame();
    try world.runSystem(StaleCommandSystem.system);
    try world.endFrame();

    try std.testing.expect(!world.hasComponent(entity_v1, Position));
    try std.testing.expect(!world.isAlive(entity_v0));
    try std.testing.expect(!world.hasComponent(entity_v0, Position));
    try std.testing.expect(world.isAlive(entity_v1));
}
