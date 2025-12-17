const std = @import("std");

const FilterModule = @import("filter.zig");
const Query = FilterModule.Query;
const TagQuery = FilterModule.TagQuery;

test "Tag storage - sequential entity destruction edge case" {
    // This test reproduces a bug where destroying entities with tags in sequence
    // would cause an index out of bounds error due to stale sparse_to_dense indices.
    // The bug occurred when:
    // 1. Two entities have the same tag
    // 2. First entity destroyed → swapRemove in packed array
    // 3. Second entity destroyed → access to stale sparse_to_dense index

    const Enemy = struct {};
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(
.{ Position, Enemy },
.{},
.{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create two entities with the Enemy tag
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addTag(e1, Enemy);

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addTag(e2, Enemy);

    // Verify both entities have the tag
    try std.testing.expect(world.getTagStorage(Enemy).contains(e1));
    try std.testing.expect(world.getTagStorage(Enemy).contains(e2));

    // Destroy first entity - this triggers swapRemove in tag storage
    world.destroyEntity(e1);

    // Destroy second entity - before the fix, this would cause index out of bounds
    // because the sparse_to_dense reverse index wasn't properly maintained
    world.destroyEntity(e2);

    // Test passes if we reach here without panicking
    try std.testing.expect(true);
}

test "Query filters out destroyed entities in Debug/ReleaseSafe" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with both components
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.5, .dy = 0.5 });

    // Destroy e2
    world.destroyEntity(e2);

    // Query should NOT return e2 (destroyed entity)
    const MovementQuery = Query(struct { Position, Velocity });
    var query = MovementQuery.init(&world);

    var count: usize = 0;
    var it = query.iterator();
    while (it.next()) |entity| {
        // Should only find e1 and e3
        try std.testing.expect(entity == e1 or entity == e3);
        try std.testing.expect(entity != e2); // e2 is destroyed
        count += 1;
    }

    // Should only count 2 entities (e1 and e3), not e2
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "TagQuery filters out destroyed entities in Debug/ReleaseSafe" {
    const Enemy = struct {};
    const Active = struct {};

    const TestWorld = @import("../world.zig").World(.{ Enemy, Active }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with both tags
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);
    try world.addTag(e1, Active);

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);
    try world.addTag(e2, Active);

    const e3 = world.createEntity();
    try world.addTag(e3, Enemy);
    try world.addTag(e3, Active);

    // Destroy e2
    world.destroyEntity(e2);

    // TagQuery should NOT return e2 (destroyed entity)
    const ActiveEnemyQuery = TagQuery(struct { Enemy, Active });
    const query = ActiveEnemyQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e3
            try std.testing.expect(entity == e1 or entity == e3);
            try std.testing.expect(entity != e2); // e2 is destroyed
            count += 1;
        }
    }

    // Should only count 2 entities (e1 and e3), not e2
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Query combinations() skips destroyed entities" {
    const Position = struct { x: f32, y: f32 };
    const Collider = struct { radius: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Collider }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create 4 entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Collider, .{ .radius = 10.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addComponent(e2, Collider, .{ .radius = 10.0 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 10.0, .y = 10.0 });
    try world.addComponent(e3, Collider, .{ .radius = 10.0 });

    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 15.0, .y = 15.0 });
    try world.addComponent(e4, Collider, .{ .radius = 10.0 });

    // Destroy e2
    world.destroyEntity(e2);

    // Combinations should skip e2
    const CollisionQuery = Query(struct { Position, Collider });
    var query = CollisionQuery.init(&world);

    var pair_count: usize = 0;
    var pairs = query.combinations();
    while (pairs.next()) |pair| {
        // Neither entity in the pair should be e2
        try std.testing.expect(pair[0] != e2);
        try std.testing.expect(pair[1] != e2);
        pair_count += 1;
    }

    // With 3 alive entities (e1, e3, e4), we should have 3 pairs:
    // (e1, e3), (e1, e4), (e3, e4)
    try std.testing.expectEqual(@as(usize, 3), pair_count);
}

test "Query crossProduct() skips destroyed entities" {
    const Position = struct { x: f32, y: f32 };
    const Projectile = struct {};
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(.{ Position, Projectile, Enemy }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create 2 projectiles
    const p1 = world.createEntity();
    try world.addComponent(p1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addTag(p1, Projectile);

    const p2 = world.createEntity();
    try world.addComponent(p2, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addTag(p2, Projectile);

    // Create 3 enemies
    const en1 = world.createEntity();
    try world.addComponent(en1, Position, .{ .x = 10.0, .y = 10.0 });
    try world.addTag(en1, Enemy);

    const en2 = world.createEntity();
    try world.addComponent(en2, Position, .{ .x = 15.0, .y = 15.0 });
    try world.addTag(en2, Enemy);

    const en3 = world.createEntity();
    try world.addComponent(en3, Position, .{ .x = 20.0, .y = 20.0 });
    try world.addTag(en3, Enemy);

    // Destroy p2 and en2
    world.destroyEntity(p2);
    world.destroyEntity(en2);

    // Cross product should skip p2 and en2
    const ProjectileQuery = Query(struct { Position, Projectile });
    const EnemyQuery = Query(struct { Position, Enemy });

    var projectiles = ProjectileQuery.init(&world);
    var enemies = EnemyQuery.init(&world);

    var pair_count: usize = 0;
    var cross = projectiles.crossProduct(&enemies);
    while (cross.next()) |pair| {
        // First entity should be projectile, not p2
        try std.testing.expect(pair[0] == p1);
        try std.testing.expect(pair[0] != p2);

        // Second entity should be enemy, not en2
        try std.testing.expect(pair[1] == en1 or pair[1] == en3);
        try std.testing.expect(pair[1] != en2);

        pair_count += 1;
    }

    // With 1 alive projectile (p1) and 2 alive enemies (en1, en3), we should have 2 pairs:
    // (p1, en1), (p1, en3)
    try std.testing.expectEqual(@as(usize, 2), pair_count);
}
