const std = @import("std");

const FilterModule = @import("filter.zig");
const Query = FilterModule.Query;
const SingleTag = FilterModule.SingleTag;

const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;

test "CrossProductIterator - Query × Query basic usage" {
    const Projectile = struct {};
    const Enemy = struct {};
    const Transform = struct { x: f32, y: f32 };
    const Collider = struct { radius: f32 };

    const TestWorld = @import("../world.zig").World(
        .{ Projectile, Enemy, Transform, Collider },
        .{},
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create projectiles
    const p1 = world.createEntity();
    try world.addTag(p1, Projectile);
    try world.addComponent(p1, Transform, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(p1, Collider, .{ .radius = 5.0 });

    const p2 = world.createEntity();
    try world.addTag(p2, Projectile);
    try world.addComponent(p2, Transform, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(p2, Collider, .{ .radius = 5.0 });

    // Create enemies
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);
    try world.addComponent(e1, Transform, .{ .x = 15.0, .y = 25.0 });
    try world.addComponent(e1, Collider, .{ .radius = 10.0 });

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);
    try world.addComponent(e2, Transform, .{ .x = 35.0, .y = 45.0 });
    try world.addComponent(e2, Collider, .{ .radius = 10.0 });

    const e3 = world.createEntity();
    try world.addTag(e3, Enemy);
    try world.addComponent(e3, Transform, .{ .x = 100.0, .y = 100.0 });
    try world.addComponent(e3, Collider, .{ .radius = 10.0 });

    // Create queries
    var projectile_query = Query(struct { Projectile, Transform, Collider }).init(&world);
    var enemy_query = Query(struct { Enemy, Transform, Collider }).init(&world);

    // Iterate cross product
    var cross = projectile_query.crossProduct(&enemy_query);
    var pair_count: usize = 0;

    while (cross.next()) |pair| {
        pair_count += 1;
        const proj_entity, const enemy_entity = pair;

        // Verify entities are valid
        try std.testing.expect(proj_entity == p1 or proj_entity == p2);
        try std.testing.expect(enemy_entity == e1 or enemy_entity == e2 or enemy_entity == e3);
    }

    // Should have 2 projectiles × 3 enemies = 6 pairs
    try std.testing.expectEqual(@as(usize, 6), pair_count);
}

test "CrossProductIterator - Query × Query with filtering" {
    const Projectile = struct {};
    const Enemy = struct {};
    const Active = struct {};
    const Transform = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(
        .{ Projectile, Enemy, Active, Transform },
        .{},
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create active projectiles
    const p1 = world.createEntity();
    try world.addTag(p1, Projectile);
    try world.addTag(p1, Active);
    try world.addComponent(p1, Transform, .{ .x = 10.0, .y = 20.0 });

    const p2 = world.createEntity();
    try world.addTag(p2, Projectile);
    try world.addTag(p2, Active);
    try world.addComponent(p2, Transform, .{ .x = 30.0, .y = 40.0 });

    // Create inactive projectile (should be filtered out)
    const p_inactive = world.createEntity();
    try world.addTag(p_inactive, Projectile);
    try world.addComponent(p_inactive, Transform, .{ .x = 50.0, .y = 60.0 });

    // Create active enemies
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);
    try world.addTag(e1, Active);
    try world.addComponent(e1, Transform, .{ .x = 15.0, .y = 25.0 });

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);
    try world.addTag(e2, Active);
    try world.addComponent(e2, Transform, .{ .x = 35.0, .y = 45.0 });

    // Create inactive enemy (should be filtered out)
    const e_inactive = world.createEntity();
    try world.addTag(e_inactive, Enemy);
    try world.addComponent(e_inactive, Transform, .{ .x = 100.0, .y = 100.0 });

    // Create queries that require Active tag
    var projectile_query = Query(struct { Projectile, Active, Transform }).init(&world);
    var enemy_query = Query(struct { Enemy, Active, Transform }).init(&world);

    // Iterate cross product
    var cross = projectile_query.crossProduct(&enemy_query);
    var pair_count: usize = 0;

    while (cross.next()) |pair| {
        pair_count += 1;
        const proj_entity, const enemy_entity = pair;

        // Verify only active entities are included
        try std.testing.expect(proj_entity == p1 or proj_entity == p2);
        try std.testing.expect(proj_entity != p_inactive);
        try std.testing.expect(enemy_entity == e1 or enemy_entity == e2);
        try std.testing.expect(enemy_entity != e_inactive);
    }

    // Should have 2 active projectiles × 2 active enemies = 4 pairs
    try std.testing.expectEqual(@as(usize, 4), pair_count);
}

test "CrossProductIterator - SimpleCrossProductIterator with SingleTag" {
    const Projectile = struct {};
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(
        .{ Projectile, Enemy },
        .{},
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create projectiles
    const p1 = world.createEntity();
    try world.addTag(p1, Projectile);

    const p2 = world.createEntity();
    try world.addTag(p2, Projectile);

    const p3 = world.createEntity();
    try world.addTag(p3, Projectile);

    // Create enemies
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    // Create queries
    var projectile_query = SingleTag(Projectile).init(world.getTagStoragePtr(Projectile));
    var enemy_query = SingleTag(Enemy).init(world.getTagStoragePtr(Enemy));

    // Iterate cross product
    var cross = projectile_query.crossProduct(&enemy_query);
    var pair_count: usize = 0;

    while (cross.next()) |_| {
        pair_count += 1;
    }

    // Should have 3 projectiles × 2 enemies = 6 pairs
    try std.testing.expectEqual(@as(usize, 6), pair_count);
}

test "CrossProductIterator - empty queries" {
    const Projectile = struct {};
    const Enemy = struct {};
    const Transform = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(
        .{ Projectile, Enemy, Transform },
        .{},
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Don't create any entities

    // Create queries
    var projectile_query = Query(struct { Projectile, Transform }).init(&world);
    var enemy_query = Query(struct { Enemy, Transform }).init(&world);

    // Iterate cross product
    var cross = projectile_query.crossProduct(&enemy_query);

    // Should have no pairs
    try std.testing.expect(cross.next() == null);
}

test "CrossProductIterator - asymmetric sizes" {
    const Projectile = struct {};
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(
        .{ Projectile, Enemy },
        .{},
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create many projectiles
    var projectiles: [10]Entity = undefined;
    for (&projectiles) |*proj| {
        proj.* = world.createEntity();
        try world.addTag(proj.*, Projectile);
    }

    // Create few enemies
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    // Create queries
    var projectile_query = SingleTag(Projectile).init(world.getTagStoragePtr(Projectile));
    var enemy_query = SingleTag(Enemy).init(world.getTagStoragePtr(Enemy));

    // Iterate cross product
    var cross = projectile_query.crossProduct(&enemy_query);
    var pair_count: usize = 0;

    while (cross.next()) |_| {
        pair_count += 1;
    }

    // Should have 10 projectiles × 2 enemies = 20 pairs
    try std.testing.expectEqual(@as(usize, 20), pair_count);
}
