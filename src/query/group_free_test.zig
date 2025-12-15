const std = @import("std");

const FilterModule = @import("filter.zig");
const Group = FilterModule.Group;

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
        .{struct { Position, Velocity, Free(Health) }},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create partial-owning group: owns Position, Velocity; uses Health as free
    // Groups now compile-time - moved to World signature: // try world.createGroup(struct { Position, Velocity, Free(Health) });

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
        .{ struct { Position, Velocity, Free(Health) }, struct { Health, Shield } },
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Group 1: owns Position, Velocity; uses Health as free
    // Groups now compile-time - moved to World signature: // try world.createGroup(struct { Position, Velocity, Free(Health) });

    // Group 2: owns Health, Shield (Health is owned here, free in Group 1)
    // Groups now compile-time - moved to World signature: // try world.createGroup(struct { Health, Shield });

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
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Group 1 owns Position and Velocity
    // Groups now compile-time - moved to World signature: // try world.createGroup(struct { Position, Velocity });

    // Group 2 tries to own Position - should fail (Position already owned by Group 1)
    // Groups now compile-time: // const result = world.createGroup(struct { Position, Health });
    // try std.testing.expectError(error.ComponentAlreadyOwned, result);
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
        .{struct { Position, Velocity, Free(Health) }},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Partial-owning group
    // Groups now compile-time - moved to World signature: // try world.createGroup(struct { Position, Velocity, Free(Health) });

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
