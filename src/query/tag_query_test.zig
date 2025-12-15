const std = @import("std");

const FilterModule = @import("filter.zig");
const TagQuery = FilterModule.TagQuery;

test "TagQuery basic iteration with two tags" {
    const Player = struct {};
    const Active = struct {};
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(struct { Player, Active, Enemy }, struct {}, struct {}, .{});

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

    const TestWorld = @import("../world.zig").World(struct { Player, Active, Boss, Enemy }, struct {}, struct {}, .{});

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

    const TestWorld = @import("../world.zig").World(struct { Player, Enemy, Boss }, struct {}, struct {}, .{});

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

    const TestWorld = @import("../world.zig").World(struct { Player, Enemy, Boss }, struct {}, struct {}, .{});

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
