const std = @import("std");

const FilterModule = @import("filter.zig");
const Query = FilterModule.Query;

const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;

test "Query with optional components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity, Health }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with different component combinations
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });
    // e2 has no health

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    // e3 has only position

    // Query with optional Health - should match all entities with Position and Velocity,
    // regardless of whether they have Health
    const MovementQuery = Query(struct { Position, Velocity, ?Health });
    const query = MovementQuery.init(&world);

    var count: usize = 0;
    var health_count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            const pos = query.getComponent(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            try std.testing.expect(pos.x >= 10.0);
            try std.testing.expect(vel.dx != 0.0);

            // Use getOptional for optional components
            if (query.getOptional(entity, Health)) |health| {
                try std.testing.expect(health.hp > 0);
                health_count += 1;
            }
        }
    }

    // Should find e1 and e2 (both have Position and Velocity)
    try std.testing.expectEqual(@as(usize, 2), count);
    // Only e1 has health
    try std.testing.expectEqual(@as(usize, 1), health_count);
}

test "Query CombinationIterator - all unique pairs" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create 4 entities with Position and Velocity
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 1.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.1, .dy = 0.1 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 2.0, .y = 2.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 0.2, .dy = 0.2 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 3.0, .y = 3.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.3, .dy = 0.3 });

    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 4.0, .y = 4.0 });
    try world.addComponent(e4, Velocity, .{ .dx = 0.4, .dy = 0.4 });

    // Create query and iterator
    var query = Query(struct { Position, Velocity }).init(&world);
    var iter = Query(struct { Position, Velocity }).CombinationIterator{
        .query = &query,
    };

    // Expected pairs (all unique combinations): (e1,e2), (e1,e3), (e1,e4), (e2,e3), (e2,e4), (e3,e4)
    // That's C(4,2) = 6 pairs
    var pairs: std.ArrayList(struct { Entity, Entity }) = .{};
    defer pairs.deinit(allocator);

    while (iter.next()) |pair| {
        try pairs.append(allocator, pair);
    }

    // Should have exactly 6 pairs
    try std.testing.expectEqual(@as(usize, 6), pairs.items.len);

    // Verify expected pairs (order matters based on entity indices)
    const expected_pairs = [_]struct { Entity, Entity }{
        .{ e1, e2 }, .{ e1, e3 }, .{ e1, e4 },
        .{ e2, e3 }, .{ e2, e4 }, .{ e3, e4 },
    };

    for (expected_pairs, 0..) |expected, i| {
        try std.testing.expectEqual(expected[0], pairs.items[i][0]);
        try std.testing.expectEqual(expected[1], pairs.items[i][1]);
    }
}

test "Query CombinationIterator - with filtering" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities - some with both components, some with only Position
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 1.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.1, .dy = 0.1 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 2.0, .y = 2.0 });
    // No velocity - should be filtered out

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 3.0, .y = 3.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.3, .dy = 0.3 });

    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 4.0, .y = 4.0 });
    try world.addComponent(e4, Velocity, .{ .dx = 0.4, .dy = 0.4 });

    // Create query and iterator
    var query = Query(struct { Position, Velocity }).init(&world);
    var iter = Query(struct { Position, Velocity }).CombinationIterator{
        .query = &query,
    };

    // Collect pairs
    var pairs: std.ArrayList(struct { Entity, Entity }) = .{};
    defer pairs.deinit(allocator);

    while (iter.next()) |pair| {
        try pairs.append(allocator, pair);
    }

    // Should have 3 pairs: (e1,e3), (e1,e4), (e3,e4)
    // e2 is excluded because it doesn't have Velocity
    try std.testing.expectEqual(@as(usize, 3), pairs.items.len);

    // Verify e2 is not in any pair
    for (pairs.items) |pair| {
        try std.testing.expect(pair[0] != e2 and pair[1] != e2);
    }
}

test "Query CombinationIterator - empty and single entity" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Test with no entities
    {
        var query = Query(struct { Position, Velocity }).init(&world);
        var iter = Query(struct { Position, Velocity }).CombinationIterator{
            .query = &query,
        };

        try std.testing.expect(iter.next() == null);
    }

    // Test with single entity (no pairs possible)
    {
        const e1 = world.createEntity();
        try world.addComponent(e1, Position, .{ .x = 1.0, .y = 1.0 });
        try world.addComponent(e1, Velocity, .{ .dx = 0.1, .dy = 0.1 });

        var query = Query(struct { Position, Velocity }).init(&world);
        var iter = Query(struct { Position, Velocity }).CombinationIterator{
            .query = &query,
        };

        try std.testing.expect(iter.next() == null);
    }
}

test "Query optional components with mutation" {
    const Position = struct { x: f32, y: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Health }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    // e2 has no health

    // Query with optional Health
    const PosHealthQuery = Query(struct { Position, ?Health });
    const query = PosHealthQuery.init(&world);

    // Apply damage to entities with health, move all entities
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponentMut(entity, Position);
            pos.x += 1.0; // Move entity

            // Apply damage only if health exists
            if (query.getOptionalMut(entity, Health)) |health| {
                health.hp -= 10;
            }
        }
    }

    // Verify both entities moved
    try std.testing.expectEqual(@as(f32, 11.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 31.0), world.getComponent(e2, Position).?.x);

    // Verify only e1 took damage
    try std.testing.expectEqual(@as(i32, 90), world.getComponent(e1, Health).?.hp);
    try std.testing.expect(world.getComponent(e2, Health) == null);
}
