const std = @import("std");

const FilterModule = @import("filter.zig");
const TagQuery = FilterModule.TagQuery;
const Exclude = FilterModule.Exclude;

test "TagQuery basic iteration with two tags" {
    const Player = struct {};
    const Active = struct {};
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(.{ Player, Active, Enemy }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with different tag combinations
    const e1 = world.createEntity();
    try world.addTag(e1, Player);
    try world.addTag(e1, Active);

    const e2 = world.createEntity();
    try world.addTag(e2, Player);

    const e3 = world.createEntity();
    try world.addTag(e3, Player);
    try world.addTag(e3, Active);

    const e4 = world.createEntity();
    try world.addTag(e4, Enemy);

    // Query for Player + Active tags
    const ActivePlayerQuery = TagQuery(struct { Player, Active });
    const query = ActivePlayerQuery.init(&world);

    // Should find e1 and e3 (both have Player and Active)
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            try std.testing.expect(entity == e1 or entity == e3);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "TagQuery with three tags" {
    const Player = struct {};
    const Active = struct {};
    const Boss = struct {};
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(.{ Player, Active, Boss, Enemy }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addTag(e1, Player);
    try world.addTag(e1, Active);
    try world.addTag(e1, Boss);

    const e2 = world.createEntity();
    try world.addTag(e2, Player);
    try world.addTag(e2, Active);

    const e3 = world.createEntity();
    try world.addTag(e3, Player);
    try world.addTag(e3, Boss);

    const e4 = world.createEntity();
    try world.addTag(e4, Enemy);

    // Query for Player + Active + Boss tags
    const BossPlayerQuery = TagQuery(struct { Player, Active, Boss });
    const query = BossPlayerQuery.init(&world);

    // Should only find e1
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            try std.testing.expectEqual(e1, entity);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TagQuery system function" {
    const Player = struct {};
    const Enemy = struct {};
    const Boss = struct {};

    const TestWorld = @import("../world.zig").World(.{ Player, Enemy, Boss }, .{}, .{}, .{});

    const BossEnemySystem = struct {
        fn system(query: TagQuery(struct { Enemy, Boss })) !void {
            var count: usize = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    count += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 2), count);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create boss enemies
    const boss1 = world.createEntity();
    try world.addTag(boss1, Enemy);
    try world.addTag(boss1, Boss);

    const boss2 = world.createEntity();
    try world.addTag(boss2, Enemy);
    try world.addTag(boss2, Boss);

    // Create regular enemy (not a boss)
    const enemy = world.createEntity();
    try world.addTag(enemy, Enemy);

    // Create player (not in query)
    const player = world.createEntity();
    try world.addTag(player, Player);

    // Run system
    try world.runSystem(BossEnemySystem.system);
}

test "TagQuery with empty result set" {
    const Player = struct {};
    const Enemy = struct {};
    const Boss = struct {};

    const TestWorld = @import("../world.zig").World(.{ Player, Enemy, Boss }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities without Boss tag
    const e1 = world.createEntity();
    try world.addTag(e1, Player);

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    // Query for Enemy + Boss (no matches)
    const BossEnemyQuery = TagQuery(struct { Enemy, Boss });
    const query = BossEnemyQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "TagQuery with optional tags using hasOptional" {
    const Enemy = struct {};
    const Flying = struct {};
    const Boss = struct {};
    const PowerUp = struct {};

    const TestWorld = @import("../world.zig").World(.{ Enemy, Flying, Boss, PowerUp }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Regular flying enemy (no power-up)
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);
    try world.addTag(e1, Flying);

    // Flying enemy with power-up
    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);
    try world.addTag(e2, Flying);
    try world.addTag(e2, PowerUp);

    // Boss flying enemy (no power-up)
    const e3 = world.createEntity();
    try world.addTag(e3, Enemy);
    try world.addTag(e3, Flying);
    try world.addTag(e3, Boss);

    // Boss flying enemy with power-up
    const e4 = world.createEntity();
    try world.addTag(e4, Enemy);
    try world.addTag(e4, Flying);
    try world.addTag(e4, Boss);
    try world.addTag(e4, PowerUp);

    // Ground enemy (not flying, should not match)
    const e5 = world.createEntity();
    try world.addTag(e5, Enemy);
    try world.addTag(e5, PowerUp);

    // Query for flying enemies with optional PowerUp and optional Boss
    const FlyingEnemyQuery = TagQuery(struct { Enemy, Flying, ?PowerUp, ?Boss });
    const query = FlyingEnemyQuery.init(&world);

    var total_count: usize = 0;
    var powered_up_count: usize = 0;
    var boss_count: usize = 0;
    var powered_up_boss_count: usize = 0;

    var it = query.iterator();
    while (it.next()) |entity| {
        total_count += 1;

        const has_power_up = query.hasOptional(entity, PowerUp);
        const has_boss = query.hasOptional(entity, Boss);

        if (has_power_up) powered_up_count += 1;
        if (has_boss) boss_count += 1;
        if (has_power_up and has_boss) powered_up_boss_count += 1;

        // Verify each entity
        if (entity == e1) {
            try std.testing.expect(!has_power_up);
            try std.testing.expect(!has_boss);
        } else if (entity == e2) {
            try std.testing.expect(has_power_up);
            try std.testing.expect(!has_boss);
        } else if (entity == e3) {
            try std.testing.expect(!has_power_up);
            try std.testing.expect(has_boss);
        } else if (entity == e4) {
            try std.testing.expect(has_power_up);
            try std.testing.expect(has_boss);
        } else {
            // Should not reach here - e5 doesn't have Flying tag
            try std.testing.expect(false);
        }
    }

    // Verify counts
    try std.testing.expectEqual(@as(usize, 4), total_count); // e1, e2, e3, e4
    try std.testing.expectEqual(@as(usize, 2), powered_up_count); // e2, e4
    try std.testing.expectEqual(@as(usize, 2), boss_count); // e3, e4
    try std.testing.expectEqual(@as(usize, 1), powered_up_boss_count); // e4
}

test "TagQuery hasOptional with Exclude modifier" {
    const Enemy = struct {};
    const Flying = struct {};
    const Dead = struct {};
    const Shielded = struct {};

    const TestWorld = @import("../world.zig").World(.{ Enemy, Flying, Dead, Shielded }, .{}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Living flying enemy without shield
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);
    try world.addTag(e1, Flying);

    // Living flying enemy with shield
    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);
    try world.addTag(e2, Flying);
    try world.addTag(e2, Shielded);

    // Dead flying enemy (should be excluded)
    const e3 = world.createEntity();
    try world.addTag(e3, Enemy);
    try world.addTag(e3, Flying);
    try world.addTag(e3, Dead);

    // Query for living flying enemies with optional shield
    const LivingFlyingQuery = TagQuery(struct { Enemy, Flying, ?Shielded, Exclude(Dead) });
    const query = LivingFlyingQuery.init(&world);

    var total_count: usize = 0;
    var shielded_count: usize = 0;

    var it = query.iterator();
    while (it.next()) |entity| {
        total_count += 1;

        if (query.hasOptional(entity, Shielded)) {
            shielded_count += 1;
        }

        // Verify entity is not dead
        try std.testing.expect(entity != e3);
    }

    // Should find e1 and e2 only (e3 is dead)
    try std.testing.expectEqual(@as(usize, 2), total_count);
    try std.testing.expectEqual(@as(usize, 1), shielded_count); // only e2
}
