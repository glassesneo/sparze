const std = @import("std");

const FilterModule = @import("filter.zig");
const Query = FilterModule.Query;
const Group = FilterModule.Group;
const SingleQuery = FilterModule.SingleQuery;
const SingleTag = FilterModule.SingleTag;
const TagQuery = FilterModule.TagQuery;
const Exclude = FilterModule.Exclude;

const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Disabled }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Armor }, struct {}, struct {});

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

test "SingleQuery basic iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with positions
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    // Query all positions
    const PositionQuery = SingleQuery(Position);
    const query = PositionQuery.init(world.getComponentStoragePtr(Position));

    try std.testing.expectEqual(@as(usize, 2), query.entities.len);
    try std.testing.expectEqual(@as(usize, 2), query.components.len);

    var count: usize = 0;
    for (query.entities, query.components) |entity, pos| {
        try std.testing.expect(world.isAlive(entity));
        try std.testing.expect(pos.x >= 10.0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Group query basic usage" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create group first
    try world.createGroup(struct { Position, Velocity });

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    // e2 has no velocity - not in group

    // Use Group query
    const MovementGroup = Group(struct { Position, Velocity });
    const group = MovementGroup.init(&world);

    const entities = group.getEntities();
    const positions = group.getArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    try std.testing.expectEqual(@as(usize, 1), entities.len);
    try std.testing.expectEqual(@as(usize, 1), positions.len);
    try std.testing.expectEqual(@as(usize, 1), velocities.len);

    try std.testing.expectEqual(@as(f32, 1.0), positions[0].x);
    try std.testing.expectEqual(@as(f32, 0.5), velocities[0].dx);
}

test "World system function with SingleQuery" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("../world.zig").World(struct { Position }, struct {}, struct {});

    const UpdatePositions = struct {
        fn system(query: SingleQuery(Position)) void {
            for (query.components) |*pos| {
                pos.x += 1.0;
                pos.y += 1.0;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 5.0, .y = 15.0 });

    // Run the system
    try world.runSystem(UpdatePositions.system);

    // Verify updates
    try std.testing.expectEqual(@as(f32, 11.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 21.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 6.0), world.getComponent(e2, Position).?.x);
}

test "World system function with Group" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

    const MovementSystem = struct {
        fn system(group: Group(struct { Position, Velocity })) void {
            const positions = group.getMutArrayOf(Position);
            const velocities = group.getArrayOf(Velocity);

            for (positions, velocities) |*pos, vel| {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    // Create moving entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Run the system
    try world.runSystem(MovementSystem.system);

    // Verify positions updated
    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 2.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 9.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 18.0), world.getComponent(e2, Position).?.y);
}

test "World system with multiple queries" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Health }, struct {}, struct {});

    const ComplexSystem = struct {
        fn system(
            movement: Group(struct { Position, Velocity }),
            health_query: SingleQuery(Health),
        ) !void {
            // Update movement
            const positions = movement.getMutArrayOf(Position);
            const velocities = movement.getArrayOf(Velocity);
            for (positions, velocities) |*pos, vel| {
                pos.x += vel.dx;
            }

            // Process health (just count for this test)
            var health_count: usize = 0;
            for (health_query.components) |_| {
                health_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 2), health_count);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Health, .{ .hp = 50 });

    try world.runSystem(ComplexSystem.system);

    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
}

test "Query basic iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Health }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with different component combinations
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    // e2 has no health

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 30.0, .y = 40.0 });
    // e3 has only position

    // Query entities with Position and Velocity (no group setup required)
    const MovementQuery = Query(struct { Position, Velocity });
    const query = MovementQuery.init(&world);

    // Should find e1 and e2 (both have Position and Velocity)
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            const pos = query.getComponent(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            try std.testing.expect(pos.x > 0.0);
            try std.testing.expect(vel.dx > 0.0);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Query with mutable component access" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Use query to mutate components
    const MovementQuery = Query(struct { Position, Velocity });
    const query = MovementQuery.init(&world);

    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const vel = query.getComponent(entity, Velocity);
            const pos = query.getComponentMut(entity, Position);
            {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
    }

    // Verify mutations
    try std.testing.expectEqual(@as(f32, 11.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 22.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 29.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 38.0), world.getComponent(e2, Position).?.y);
}

test "World system function with Query" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Health }, struct {}, struct {});

    const CombatSystem = struct {
        fn system(query: Query(struct { Position, Health })) void {
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponent(entity, Position);
                    const health = query.getComponentMut(entity, Health);
                    {
                        // Reduce health if too far from origin
                        if (pos.x * pos.x + pos.y * pos.y > 100.0) {
                            health.hp -= 10;
                        }
                    }
                }
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 15.0, .y = 15.0 });
    try world.addComponent(e2, Health, .{ .hp = 100 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 1.0 });

    // Run the system
    try world.runSystem(CombatSystem.system);

    // e1 should be unaffected (close to origin)
    try std.testing.expectEqual(@as(i32, 100), world.getComponent(e1, Health).?.hp);
    // e2 should take damage (far from origin)
    try std.testing.expectEqual(@as(i32, 90), world.getComponent(e2, Health).?.hp);
}

test "Query three components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Health }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Health, .{ .hp = 50 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    // Query for all three components
    const FullEntityQuery = Query(struct { Position, Velocity, Health });
    const query = FullEntityQuery.init(&world);

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

test "TagQuery basic iteration with two tags" {
    const Player = struct {};
    const Active = struct {};
    const Enemy = struct {};

    const TestWorld = @import("../world.zig").World(struct { Player, Active, Enemy }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Player, Active, Boss, Enemy }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Player, Enemy, Boss }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Player, Enemy, Boss }, struct {}, struct {});

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

test "Query with optional components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity, Health }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Health }, struct {}, struct {});

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

test "CrossProductIterator - Query × Query basic usage" {
    const Projectile = struct {};
    const Enemy = struct {};
    const Transform = struct { x: f32, y: f32 };
    const Collider = struct { radius: f32 };

    const TestWorld = @import("../world.zig").World(
        struct { Projectile, Enemy, Transform, Collider },
        struct {},
        struct {},
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
        struct { Projectile, Enemy, Active, Transform },
        struct {},
        struct {},
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
        struct { Projectile, Enemy },
        struct {},
        struct {},
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
        struct { Projectile, Enemy, Transform },
        struct {},
        struct {},
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
        struct { Projectile, Enemy },
        struct {},
        struct {},
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
        struct { Position, Enemy },
        struct {},
        struct {},
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

// ============================================================================
// Partial-Owning and Non-Owning Groups Tests
// ============================================================================

test "Free() wrapper type compilation" {
    // Test that Free() wrapper compiles and has correct declarations
    const Position = struct { x: f32, y: f32 };
    const Free = FilterModule.Free;
    const FreePosition = Free(Position);

    // Verify the wrapper has the correct fields
    try std.testing.expect(@hasDecl(FreePosition, "Component"));
    try std.testing.expect(@hasDecl(FreePosition, "is_free"));
    try std.testing.expect(FreePosition.Component == Position);
    try std.testing.expect(FreePosition.is_free == true);
}

test "Partial-owning group - basic functionality" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };
    const Free = FilterModule.Free;

    const TestWorld = @import("../world.zig").World(
        struct { Position, Velocity, Health },
        struct {},
        struct {},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create partial-owning group: owns Position, Velocity; uses Health as free
    try world.createGroup(struct { Position, Velocity, Free(Health) });

    // Create entity with all components
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    // Create another entity with all components
    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    try world.addComponent(e2, Health, .{ .hp = 75 });

    // Create entity with only owned components (should NOT be in group - missing free component Health)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 100.0, .y = 200.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 10.0, .dy = 20.0 });

    // Use Group filter
    const PartialGroup = Group(struct { Position, Velocity, Free(Health) });
    const group = PartialGroup.init(&world);

    const entities = group.getEntities();

    // Only e1 and e2 should be in the group (e3 missing Health)
    // Free components are still REQUIRED, just not owned/organized
    try std.testing.expectEqual(@as(usize, 2), entities.len);

    // Owned components should have direct array access
    const positions = group.getArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    try std.testing.expectEqual(@as(usize, 2), positions.len);
    try std.testing.expectEqual(@as(usize, 2), velocities.len);
}

test "Partial-owning group - shared free component" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };
    const Shield = struct { value: i32 };
    const Free = FilterModule.Free;

    const TestWorld = @import("../world.zig").World(
        struct { Position, Velocity, Health, Shield },
        struct {},
        struct {},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Group 1: owns Position, Velocity; uses Health as free
    try world.createGroup(struct { Position, Velocity, Free(Health) });

    // Group 2: owns Health, Shield (Health is owned here, free in Group 1)
    try world.createGroup(struct { Health, Shield });

    // This should succeed - Health is owned by Group 2, free in Group 1
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });
    try world.addComponent(e1, Shield, .{ .value = 50 });

    // Verify entity is in both groups
    const group1 = Group(struct { Position, Velocity, Free(Health) }).init(&world);
    const group2 = Group(struct { Health, Shield }).init(&world);

    try std.testing.expectEqual(@as(usize, 1), group1.getEntities().len);
    try std.testing.expectEqual(@as(usize, 1), group2.getEntities().len);
}

test "Ownership conflict detection" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("../world.zig").World(
        struct { Position, Velocity, Health },
        struct {},
        struct {},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Group 1 owns Position and Velocity
    try world.createGroup(struct { Position, Velocity });

    // Group 2 tries to own Position - should fail (Position already owned by Group 1)
    const result = world.createGroup(struct { Position, Health });
    try std.testing.expectError(error.ComponentAlreadyOwned, result);
}

test "Partial-owning group - getComponent for free components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };
    const Free = FilterModule.Free;

    const TestWorld = @import("../world.zig").World(
        struct { Position, Velocity, Health },
        struct {},
        struct {},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Partial-owning group
    try world.createGroup(struct { Position, Velocity, Free(Health) });

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const PartialGroup = Group(struct { Position, Velocity, Free(Health) });
    const group = PartialGroup.init(&world);

    const entities = group.getEntities();
    for (entities) |entity| {
        // Access owned components via array or getComponent
        const pos = group.getComponent(entity, Position);
        try std.testing.expectEqual(@as(f32, 10.0), pos.x);

        // Access free component via getComponent
        const health = group.getComponent(entity, Health);
        try std.testing.expectEqual(@as(i32, 100), health.hp);
    }
}

test "Query filters out destroyed entities in Debug/ReleaseSafe" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("../world.zig").World(struct { Position, Velocity }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Enemy, Active }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Collider }, struct {}, struct {});

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

    const TestWorld = @import("../world.zig").World(struct { Position, Projectile, Enemy }, struct {}, struct {});

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
