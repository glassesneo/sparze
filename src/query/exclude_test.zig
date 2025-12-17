const std = @import("std");

const FilterModule = @import("filter.zig");
const Query = FilterModule.Query;
const TagQuery = FilterModule.TagQuery;
const Exclude = FilterModule.Exclude;

test "Query with Exclude modifier - basic usage" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Dead = struct {};
    const Static = struct {};

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity, Dead, Static }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create living movable entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Create dead entity (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.0, .dy = 0.0 });
    try world.addTag(e3, Dead);

    // Create static entity (should be excluded)
    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 70.0, .y = 80.0 });
    try world.addComponent(e4, Velocity, .{ .dx = 0.0, .dy = 0.0 });
    try world.addTag(e4, Static);

    // Query for living entities with position and velocity (exclude Dead)
    const LivingMovementQuery = Query(struct { Position, Velocity, Exclude(Dead) });
    const query = LivingMovementQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1, e2, and e4 (not e3 which is Dead)
            try std.testing.expect(entity == e1 or entity == e2 or entity == e4);
            try std.testing.expect(entity != e3);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "Query with multiple Exclude modifiers" {
    const Position = struct { x: f32, y: f32 };
    const Enemy = struct {};
    const Dead = struct {};
    const Frozen = struct {};
    const Disabled = struct {};

    const TestWorld = @import("../world.zig").World(.{ Position, Enemy, Dead, Frozen, Disabled }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create active enemy (should be included)
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addTag(e1, Enemy);

    // Create another active enemy (should be included)
    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addTag(e2, Enemy);

    // Create frozen enemy (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addTag(e3, Enemy);
    try world.addTag(e3, Frozen);

    // Create disabled enemy (should be excluded)
    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 70.0, .y = 80.0 });
    try world.addTag(e4, Enemy);
    try world.addTag(e4, Disabled);

    // Create dead enemy (should be excluded)
    const e5 = world.createEntity();
    try world.addComponent(e5, Position, .{ .x = 90.0, .y = 100.0 });
    try world.addTag(e5, Enemy);
    try world.addTag(e5, Dead);

    // Create enemy with multiple exclusion tags (should be excluded)
    const e6 = world.createEntity();
    try world.addComponent(e6, Position, .{ .x = 110.0, .y = 120.0 });
    try world.addTag(e6, Enemy);
    try world.addTag(e6, Frozen);
    try world.addTag(e6, Disabled);

    // Query for active enemies (exclude Frozen, Disabled, Dead)
    const ActiveEnemyQuery = Query(struct { Position, Enemy, Exclude(Frozen), Exclude(Disabled), Exclude(Dead) });
    const query = ActiveEnemyQuery.init(&world);

    var count: usize = 0;
    var found_e1 = false;
    var found_e2 = false;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3 and entity != e4 and entity != e5 and entity != e6);
            if (entity == e1) found_e1 = true;
            if (entity == e2) found_e2 = true;
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(found_e1);
    try std.testing.expect(found_e2);
}

test "Query with Exclude and optional components combined" {
    const Position = struct { x: f32, y: f32 };
    const Health = struct { hp: i32 };
    const Shield = struct { value: i32 };
    const Dead = struct {};
    const Invulnerable = struct {};

    const TestWorld = @import("../world.zig").World(.{ Position, Health, Shield, Dead, Invulnerable }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Living entity with health and shield
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });
    try world.addComponent(e1, Shield, .{ .value = 50 });

    // Living entity with health but no shield
    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Health, .{ .hp = 75 });

    // Dead entity (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(e3, Health, .{ .hp = 0 });
    try world.addTag(e3, Dead);

    // Invulnerable entity (should be excluded)
    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 70.0, .y = 80.0 });
    try world.addComponent(e4, Health, .{ .hp = 100 });
    try world.addTag(e4, Invulnerable);

    // Query for damageable entities (living, not invulnerable, optional shield)
    const DamageableQuery = Query(struct { Position, Health, ?Shield, Exclude(Dead), Exclude(Invulnerable) });
    const query = DamageableQuery.init(&world);

    var count: usize = 0;
    var shielded_count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3 and entity != e4);

            const health = query.getComponent(entity, Health);
            try std.testing.expect(health.hp > 0);

            if (query.getOptional(entity, Shield)) |shield| {
                try std.testing.expect(shield.value > 0);
                shielded_count += 1;
            }
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 1), shielded_count);
}

test "Query with Exclude in system function" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Static = struct {};

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity, Static }, .{}, .{}, .{});

    const MovementSystem = struct {
        var updated_count: usize = 0;

        fn system(query: Query(struct { Position, Velocity, Exclude(Static) })) void {
            updated_count = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponentMut(entity, Position);
                    const vel = query.getComponent(entity, Velocity);
                    pos.x += vel.dx;
                    pos.y += vel.dy;
                    updated_count += 1;
                }
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Movable entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Static entity (should not move)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 100.0, .y = 200.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 5.0, .dy = 10.0 });
    try world.addTag(e3, Static);

    // Run system
    try world.runSystem(MovementSystem.system);

    // Verify only non-static entities were updated
    try std.testing.expectEqual(@as(usize, 2), MovementSystem.updated_count);

    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 2.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 9.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 18.0), world.getComponent(e2, Position).?.y);
    // Static entity should not have moved
    try std.testing.expectEqual(@as(f32, 100.0), world.getComponent(e3, Position).?.x);
    try std.testing.expectEqual(@as(f32, 200.0), world.getComponent(e3, Position).?.y);
}

test "TagQuery with Exclude modifier" {
    const Player = struct {};
    const Enemy = struct {};
    const Dead = struct {};
    const Frozen = struct {};

    const TestWorld = @import("../world.zig").World(.{ Player, Enemy, Dead, Frozen }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Active enemy
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);

    // Another active enemy
    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    // Dead enemy (should be excluded)
    const e3 = world.createEntity();
    try world.addTag(e3, Enemy);
    try world.addTag(e3, Dead);

    // Frozen enemy (should be excluded)
    const e4 = world.createEntity();
    try world.addTag(e4, Enemy);
    try world.addTag(e4, Frozen);

    // Player (not an enemy, should not be in results)
    const e5 = world.createEntity();
    try world.addTag(e5, Player);

    // Query for living, unfrozen enemies
    const ActiveEnemyQuery = TagQuery(struct { Enemy, Exclude(Dead), Exclude(Frozen) });
    const query = ActiveEnemyQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3 and entity != e4 and entity != e5);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Query with Exclude - no matches" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Disabled = struct {};

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity, Disabled }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // All entities are disabled
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    try world.addTag(e1, Disabled);

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });
    try world.addTag(e2, Disabled);

    // Query for enabled entities (should find none)
    const EnabledQuery = Query(struct { Position, Velocity, Exclude(Disabled) });
    const query = EnabledQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "Query with Exclude - regular component exclusion" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Armor = struct { value: i32 };

    const TestWorld = @import("../world.zig").World(.{ Position, Velocity, Armor }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Unarmored entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Armored entity (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e3, Armor, .{ .value = 100 });

    // Query for unarmored entities (exclude regular component)
    const UnarmoredQuery = Query(struct { Position, Velocity, Exclude(Armor) });
    const query = UnarmoredQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
