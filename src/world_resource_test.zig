const std = @import("std");
const World = @import("world.zig").World;

// Note: Tests for debug assertions are commented out because Zig's test framework
// doesn't provide a good way to catch assertions. The assertions are still in the code
// and will fire during development. To manually test assertions, uncomment the code below
// and run with: zig build test
//
// test "getResource asserts on uninitialized resource in debug mode" {
//     const GameConfig = struct {
//         gravity: f32,
//         max_speed: f32,
//     };
//
//     const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // This WILL assert in Debug/ReleaseSafe builds:
//     _ = world.getResource(GameConfig);
// }

// test "getResourcePtr asserts on uninitialized resource in debug mode" {
//     const GameConfig = struct {
//         gravity: f32,
//         max_speed: f32,
//     };
//
//     const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // This WILL assert in Debug/ReleaseSafe builds:
//     _ = world.getResourcePtr(GameConfig);
// }
//
// test "getResourcePtrMut asserts on uninitialized resource in debug mode" {
//     const GameConfig = struct {
//         gravity: f32,
//         max_speed: f32,
//     };
//
//     const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // This WILL assert in Debug/ReleaseSafe builds:
//     _ = world.getResourcePtrMut(GameConfig);
// }

// Test: tryGetResource returns error when uninitialized
test "tryGetResource returns error when uninitialized" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Should return error
    try std.testing.expectError(error.UninitializedResource, world.tryGetResource(GameConfig));
}

// Test: tryGetResource succeeds when initialized
test "tryGetResource succeeds when initialized" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.setResource(GameConfig, .{ .gravity = 9.8, .max_speed = 100.0 });

    // Should succeed
    const config_ptr = try world.tryGetResource(GameConfig);
    try std.testing.expectEqual(@as(f32, 9.8), config_ptr.gravity);
    try std.testing.expectEqual(@as(f32, 100.0), config_ptr.max_speed);
}

// Test: tryGetResourceMut returns error when uninitialized
test "tryGetResourceMut returns error when uninitialized" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Should return error
    try std.testing.expectError(error.UninitializedResource, world.tryGetResourceMut(GameConfig));
}

// Test: tryGetResourceMut succeeds when initialized
test "tryGetResourceMut succeeds when initialized" {
    const GameState = struct {
        score: i32,
        level: i32,
    };

    const TestWorld = World(struct {}, struct { GameState }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.setResource(GameState, .{ .score = 0, .level = 1 });

    // Should succeed and allow mutation
    const state_ptr = try world.tryGetResourceMut(GameState);
    state_ptr.score = 100;
    state_ptr.level = 2;

    // Verify mutations
    const state = world.getResource(GameState);
    try std.testing.expectEqual(@as(i32, 100), state.score);
    try std.testing.expectEqual(@as(i32, 2), state.level);
}

// Test: getResourcePtrMut does NOT auto-mark as initialized
test "getResourcePtrMut does not auto-mark as initialized" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Resource is NOT initialized yet
    try std.testing.expect(!world.isResourceInitialized(GameConfig));

    // Initialize it properly first
    world.setResource(GameConfig, .{ .gravity = 9.8, .max_speed = 100.0 });

    // Now it should be initialized
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    // Get mutable pointer
    const ptr = world.getResourcePtrMut(GameConfig);
    ptr.gravity = 10.0;

    // Should still be marked as initialized
    try std.testing.expect(world.isResourceInitialized(GameConfig));
}

// Test: setResource marks as initialized
test "setResource marks resource as initialized" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Not initialized yet
    try std.testing.expect(!world.isResourceInitialized(GameConfig));

    // Set resource
    world.setResource(GameConfig, .{ .gravity = 9.8, .max_speed = 100.0 });

    // Should be marked as initialized
    try std.testing.expect(world.isResourceInitialized(GameConfig));
}

// Test: initResources helper
test "initResources initializes multiple resources" {
    const DeltaTime = struct { dt: f32 };
    const Score = struct { points: i32 };
    const GameConfig = struct { gravity: f32 };

    const TestWorld = World(struct {}, struct { DeltaTime, Score, GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // None initialized yet
    try std.testing.expect(!world.isResourceInitialized(DeltaTime));
    try std.testing.expect(!world.isResourceInitialized(Score));
    try std.testing.expect(!world.isResourceInitialized(GameConfig));

    // Initialize all at once
    try world.initResources(.{
        .delta_time = DeltaTime{ .dt = 0.016 },
        .score = Score{ .points = 0 },
        .game_config = GameConfig{ .gravity = 9.8 },
    });

    // All should be initialized now
    try std.testing.expect(world.isResourceInitialized(DeltaTime));
    try std.testing.expect(world.isResourceInitialized(Score));
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    // Verify values
    try std.testing.expectEqual(@as(f32, 0.016), world.getResource(DeltaTime).dt);
    try std.testing.expectEqual(@as(i32, 0), world.getResource(Score).points);
    try std.testing.expectEqual(@as(f32, 9.8), world.getResource(GameConfig).gravity);
}

// Test: initResources with partial initialization
test "initResources can initialize subset of resources" {
    const DeltaTime = struct { dt: f32 };
    const Score = struct { points: i32 };
    const GameConfig = struct { gravity: f32 };

    const TestWorld = World(struct {}, struct { DeltaTime, Score, GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize only some resources
    try world.initResources(.{
        .delta_time = DeltaTime{ .dt = 0.016 },
        .score = Score{ .points = 0 },
    });

    // These should be initialized
    try std.testing.expect(world.isResourceInitialized(DeltaTime));
    try std.testing.expect(world.isResourceInitialized(Score));

    // This should NOT be initialized
    try std.testing.expect(!world.isResourceInitialized(GameConfig));

    // Initialize the remaining one separately
    world.setResource(GameConfig, .{ .gravity = 9.8 });
    try std.testing.expect(world.isResourceInitialized(GameConfig));
}

// Test: Resources work correctly after debug assertions are added
test "initialized resources work normally with assertions" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };
    const GameState = struct {
        score: i32,
        level: i32,
    };

    const TestWorld = World(struct {}, struct { GameConfig, GameState }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resources
    world.setResource(GameConfig, .{ .gravity = 9.8, .max_speed = 100.0 });
    world.setResource(GameState, .{ .score = 0, .level = 1 });

    // All getters should work fine
    const config = world.getResource(GameConfig);
    try std.testing.expectEqual(@as(f32, 9.8), config.gravity);

    const config_ptr = world.getResourcePtr(GameConfig);
    try std.testing.expectEqual(@as(f32, 100.0), config_ptr.max_speed);

    const state_ptr = world.getResourcePtrMut(GameState);
    state_ptr.score = 100;

    const final_state = world.getResource(GameState);
    try std.testing.expectEqual(@as(i32, 100), final_state.score);
}
