const std = @import("std");

const root = @import("../root.zig");
const Query = root.Query;
const SingleQuery = root.SingleQuery;
const Group = root.Group;
const SingleTag = root.SingleTag;

// Note: Query/filter tests are consolidated in src/query/filter_test.zig
// This file contains only system-specific tests (Commands, Allocator parameter injection, etc.)

test "System function with Allocator parameter" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(struct { Position }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

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
    const TestWorld = @import("../world.zig").World(struct {}, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Enemy }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Health, Dead }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Health }, struct {}, struct {});

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
        var target: ?@import("../entity/entity.zig").Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    const DestroySystem2 = struct {
        var target: ?@import("../entity/entity.zig").Entity = null;

        fn system(commands: anytype) !void {
            if (target) |e| {
                try commands.destroyEntity(e);
            }
        }
    };

    const DestroySystem3 = struct {
        var target: ?@import("../entity/entity.zig").Entity = null;

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
