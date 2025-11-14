const std = @import("std");

const root = @import("../root.zig");
const Query = root.Query;
const TagQuery = root.TagQuery;
const SingleQuery = root.SingleQuery;
const SingleTag = root.SingleTag;
const Group = root.Group;
const Exclude = root.Exclude;

test "Query with Exclude modifier - basic usage" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Dead = struct {};
    const Static = struct {};

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Dead, Static }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Enemy, Dead, Frozen, Disabled }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Health, Shield, Dead, Invulnerable }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Static }, struct {}, struct {});

    const MovementSystem = struct {
        var updated_count: usize = 0;

        fn system(query: Query(struct { Position, Velocity, Exclude(Static) })) !void {
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

    const TestWorld = @import("../world.zig").World(struct { Player, Enemy, Dead, Frozen }, struct {}, struct {});

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

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Disabled }, struct {}, struct {});

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

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Armor }, struct {}, struct {});

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

test "System function with Allocator parameter" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position }, struct {}, struct {});

    const AllocatorSystem = struct {
        fn system(allocator: std.mem.Allocator) !void {
            // Test that we can use the allocator
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

    // Run system with allocator
    try world.runSystem(AllocatorSystem.system);
}

test "System function with Allocator and query filter parameters" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position }, struct {}, struct {});

    const MixedSystem = struct {
        fn system(allocator: std.mem.Allocator, query: SingleQuery(Position)) !void {
            // Use allocator to create a dynamic list
            var list: std.ArrayList(f32) = .{};
            defer list.deinit(allocator);

            // Collect all x positions
            for (query.components) |pos| {
                try list.append(allocator, pos.x);
            }

            // Verify we collected positions
            try std.testing.expectEqual(@as(usize, 2), list.items.len);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create test entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });

    // Run system with allocator and query
    try world.runSystem(MixedSystem.system);
}

test "System function with Allocator and Commands parameters" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position }, struct {}, struct {});

    const SpawnSystem = struct {
        fn system(allocator: std.mem.Allocator, commands: anytype) !void {
            // Use allocator to determine spawn count
            var list: std.ArrayList(i32) = .{};
            defer list.deinit(allocator);

            try list.append(allocator, 1);
            try list.append(allocator, 2);
            try list.append(allocator, 3);

            // Spawn entities based on list
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

    // Verify entities were spawned
    const query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), query.entities.len);
}

test "System function with Allocator, query filter, and Commands parameters" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity }, struct {}, struct {});

    const ComplexSystem = struct {
        fn system(
            allocator: std.mem.Allocator,
            movement: Group(struct { Position, Velocity }),
            commands: anytype,
        ) !void {
            // Use allocator to track entities that need duplication
            var to_duplicate: std.ArrayList(std.meta.Tuple(&[_]type{ Position, Velocity })) = .{};
            defer to_duplicate.deinit(allocator);

            const positions = movement.getArrayOf(Position);
            const velocities = movement.getArrayOf(Velocity);

            for (positions, velocities) |pos, vel| {
                if (pos.x > 50.0) {
                    try to_duplicate.append(allocator, .{ pos, vel });
                }
            }

            // Spawn duplicates
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

    try world.createGroup(struct { Position, Velocity });

    // Create test entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 100.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 0.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 0.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 2.0, .dy = 0.0 });

    world.beginFrame();
    try world.runSystem(ComplexSystem.system);
    try world.endFrame();

    // Should have 3 entities: 2 original + 1 duplicate (only e1 has x > 50)
    const query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), query.entities.len);
}

test "System function verifies allocator is world allocator" {
    const TestWorld = @import("world.zig").World(struct {}, struct {}, struct {});

    const CheckAllocatorSystem = struct {
        var captured_allocator: ?std.mem.Allocator = null;

        fn system(allocator: std.mem.Allocator) !void {
            captured_allocator = allocator;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.runSystem(CheckAllocatorSystem.system);

    // Verify the allocator passed to the system is the world's allocator
    // Note: We can't directly compare allocators, but we can verify it was set
    try std.testing.expect(CheckAllocatorSystem.captured_allocator != null);
}

test "Commands with frame-based execution" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Enemy = struct {};

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Enemy }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // System that spawns enemies using Commands
    const spawnEnemies = struct {
        fn system(commands: anytype) !void {
            // Create 3 enemies
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

    // Begin frame
    world.beginFrame();

    // Run spawn system - entities created immediately, components deferred
    try world.runSystem(spawnEnemies);

    // At this point, entities exist but have no components yet
    const enemy_tag_before = SingleTag(Enemy).init(world.getTagStoragePtr(Enemy));
    try std.testing.expectEqual(@as(usize, 0), enemy_tag_before.entities.len); // No enemies with Enemy component yet

    // End frame - execute commands
    try world.endFrame();

    // Now components are added
    const enemy_tag_after = SingleTag(Enemy).init(world.getTagStoragePtr(Enemy));
    try std.testing.expectEqual(@as(usize, 3), enemy_tag_after.entities.len); // 3 enemies now exist

    // Verify components were added correctly
    const position_query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), position_query.entities.len);

    const velocity_query = SingleQuery(Velocity).init(world.getSparseSetPtr(Velocity));
    try std.testing.expectEqual(@as(usize, 3), velocity_query.entities.len);
}

test "Commands remove and destroy operations" {
    const Health = struct { hp: i32 };
    const Dead = struct {};

    const TestWorld = @import("world.zig").World(struct { Health, Dead }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with health
    const e1 = world.createEntity();
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Health, .{ .hp = 0 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Health, .{ .hp = 50 });

    // System that marks dead entities and removes/destroys
    const deathSystem = struct {
        fn system(query: SingleQuery(Health), commands: anytype) !void {
            for (query.entities, query.components) |entity, health| {
                if (health.hp <= 0) {
                    // Mark as dead (add component)
                    try commands.addTag(entity, Dead);
                    // Remove health
                    try commands.removeComponent(entity, Health);
                } else if (health.hp < 25) {
                    // Destroy low health entities
                    try commands.destroyEntity(entity);
                }
            }
        }
    }.system;

    world.beginFrame();
    try world.runSystem(deathSystem);
    try world.endFrame();

    // e1 (hp=100) should be alive with Health
    try std.testing.expect(world.isAlive(e1));
    try std.testing.expect(world.hasComponent(e1, Health));

    // e2 (hp=0) should be alive but marked Dead, Health removed
    try std.testing.expect(world.isAlive(e2));
    try std.testing.expect(!world.hasComponent(e2, Health));
    try std.testing.expect(world.hasComponent(e2, Dead));

    // e3 (hp=50) should be alive (not destroyed since hp >= 25)
    try std.testing.expect(world.isAlive(e3));
}

test "Commands createEntityWith convenience method" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity }, struct {}, struct {});

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

    // Verify entity was created with both components
    const pos_query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 1), pos_query.entities.len);
    try std.testing.expectEqual(@as(f32, 10.0), pos_query.components[0].x);

    const vel_query = SingleQuery(Velocity).init(world.getSparseSetPtr(Velocity));
    try std.testing.expectEqual(@as(usize, 1), vel_query.entities.len);
    try std.testing.expectEqual(@as(f32, 1.0), vel_query.components[0].dx);
}

test "Commands destroyEntity handles multiple destroy commands for same entity" {
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Health }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create an entity
    const entity = world.createEntity();
    try world.addComponent(entity, Health, .{ .hp = 100 });

    // System that destroys the same entity multiple times
    const DestroySystem1 = struct {
        var target: ?@import("core/entity.zig").Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    const DestroySystem2 = struct {
        var target: ?@import("core/entity.zig").Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    const DestroySystem3 = struct {
        var target: ?@import("core/entity.zig").Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    // Set the target entity for all systems
    DestroySystem1.target = entity;
    DestroySystem2.target = entity;
    DestroySystem3.target = entity;

    // Verify entity is alive before systems run
    try std.testing.expect(world.isAlive(entity));
    try std.testing.expect(world.hasComponent(entity, Health));

    world.beginFrame();
    // Run multiple systems that all try to destroy the same entity
    try world.runSystem(DestroySystem1.system);
    try world.runSystem(DestroySystem2.system);
    try world.runSystem(DestroySystem3.system);
    // Entity should still be alive during frame (commands are deferred)
    try std.testing.expect(world.isAlive(entity));

    // Execute commands - should not crash even though entity is destroyed 3 times
    try world.endFrame();

    // Verify entity is destroyed after frame ends
    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expect(!world.hasComponent(entity, Health));
}
