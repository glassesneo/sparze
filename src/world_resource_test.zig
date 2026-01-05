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
//     const TestWorld = World(.{}, .{ GameConfig }, .{}, .{});
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
//     const TestWorld = World(.{}, .{ GameConfig }, .{}, .{});
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
//     const TestWorld = World(.{}, .{ GameConfig }, .{}, .{});
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
        pub const auto_init = false;
    };

    const TestWorld = World(.{}, .{GameConfig}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Opt-out resource should return error
    try std.testing.expectError(error.UninitializedResource, world.tryGetResource(GameConfig));
}

// Test: tryGetResource succeeds when initialized
test "tryGetResource succeeds when initialized" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(.{}, .{GameConfig}, .{}, .{});

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
        pub const auto_init = false;
    };

    const TestWorld = World(.{}, .{GameConfig}, .{}, .{});

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

    const TestWorld = World(.{}, .{GameState}, .{}, .{});

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
        pub const auto_init = false;
    };

    const TestWorld = World(.{}, .{GameConfig}, .{}, .{});

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
        pub const auto_init = false;
    };

    const TestWorld = World(.{}, .{GameConfig}, .{}, .{});

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
    const DeltaTime = struct {
        dt: f32,
        pub const auto_init = false;
    };
    const Score = struct {
        points: i32,
        pub const auto_init = false;
    };
    const GameConfig = struct {
        gravity: f32,
        pub const auto_init = false;
    };

    const TestWorld = World(.{}, .{ DeltaTime, Score, GameConfig }, .{}, .{});

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
    const DeltaTime = struct {
        dt: f32,
        pub const auto_init = false;
    };
    const Score = struct {
        points: i32,
        pub const auto_init = false;
    };
    const GameConfig = struct {
        gravity: f32,
        pub const auto_init = false;
    };

    const TestWorld = World(.{}, .{ DeltaTime, Score, GameConfig }, .{}, .{});

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

    const TestWorld = World(.{}, .{ GameConfig, GameState }, .{}, .{});

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

// ============================================================================
// Integration Tests: Smart Resource Initialization
// ============================================================================

// Test: Resource with custom init() is auto-initialized
test "Resource with init() is auto-initialized" {
    const Cache = struct {
        items: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) @This() {
            _ = allocator;
            return .{ .items = .{} };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
    };

    const TestWorld = World(.{}, .{Cache}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Resource should be auto-initialized
    try std.testing.expect(world.isResourceInitialized(Cache));

    // Should be usable immediately
    const cache = world.getResourcePtrMut(Cache);
    try cache.items.append(allocator, 42);
    try std.testing.expectEqual(@as(usize, 1), cache.items.items.len);
    try std.testing.expectEqual(@as(u8, 42), cache.items.items[0]);
}

// Test: Resource with auto_init=false remains uninitialized
test "Resource with auto_init=false remains uninitialized" {
    const AudioEngine = struct {
        device_id: u32,
        pub const auto_init = false;
    };

    const TestWorld = World(.{}, .{AudioEngine}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Resource should NOT be auto-initialized
    try std.testing.expect(!world.isResourceInitialized(AudioEngine));

    // Manual initialization required
    world.setResource(AudioEngine, .{ .device_id = 42 });
    try std.testing.expect(world.isResourceInitialized(AudioEngine));
    try std.testing.expectEqual(@as(u32, 42), world.getResource(AudioEngine).device_id);
}

// Test: POD Resource is zero-initialized (backward compatibility)
test "POD Resource is zero-initialized" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(.{}, .{GameConfig}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // POD Resource should be auto-initialized with zeroes
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    const config = world.getResource(GameConfig);
    try std.testing.expectEqual(@as(f32, 0.0), config.gravity);
    try std.testing.expectEqual(@as(f32, 0.0), config.max_speed);
}

// Test: Mixed Resource types initialize correctly
test "Mixed Resource types initialize correctly" {
    const Database = struct {
        items: std.ArrayList(u32),

        pub fn init(allocator: std.mem.Allocator) @This() {
            _ = allocator;
            return .{ .items = .{} };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
    };

    const AudioEngine = struct {
        device_id: u32,
        pub const auto_init = false;
    };

    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(.{}, .{ Database, AudioEngine, GameConfig }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Database: custom init - should be initialized
    try std.testing.expect(world.isResourceInitialized(Database));
    const db = world.getResourcePtrMut(Database);
    try db.items.append(allocator, 123);
    try std.testing.expectEqual(@as(usize, 1), db.items.items.len);

    // AudioEngine: opt-out - should NOT be initialized
    try std.testing.expect(!world.isResourceInitialized(AudioEngine));
    world.setResource(AudioEngine, .{ .device_id = 42 });
    try std.testing.expect(world.isResourceInitialized(AudioEngine));

    // GameConfig: POD - should be zero-initialized
    try std.testing.expect(world.isResourceInitialized(GameConfig));
    try std.testing.expectEqual(@as(f32, 0.0), world.getResource(GameConfig).gravity);
}

// Test: Resource deinit() is called on World.deinit()
test "Resource deinit() is called on World.deinit()" {
    const ResourceWithDeinit = struct {
        buffer: std.ArrayList(u8),
        deinit_called: *bool,

        pub fn init(allocator: std.mem.Allocator) @This() {
            _ = allocator;
            // Note: We can't pass deinit_called here in init, so we'll set it via setResource
            return .{
                .buffer = .{},
                .deinit_called = undefined,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.deinit_called.* = true;
            self.buffer.deinit(allocator);
        }
    };

    const TestWorld = World(.{}, .{ResourceWithDeinit}, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var deinit_called = false;

    {
        var world = TestWorld.init(allocator);

        // Set the deinit_called pointer
        const res = world.getResourcePtrMut(ResourceWithDeinit);
        res.deinit_called = &deinit_called;

        // deinit() should be called when world is destroyed
        world.deinit();
    }

    try std.testing.expect(deinit_called);
}

// Test: Multiple Resources with init/deinit work correctly
test "Multiple Resources with init/deinit work correctly" {
    const ResourceA = struct {
        data: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) @This() {
            _ = allocator;
            return .{ .data = .{} };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
        }
    };

    const ResourceB = struct {
        items: std.ArrayList(u32),

        pub fn init(allocator: std.mem.Allocator) @This() {
            _ = allocator;
            return .{ .items = .{} };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
    };

    const TestWorld = World(.{}, .{ ResourceA, ResourceB }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Both should be initialized
    try std.testing.expect(world.isResourceInitialized(ResourceA));
    try std.testing.expect(world.isResourceInitialized(ResourceB));

    // Both should be usable
    const res_a = world.getResourcePtrMut(ResourceA);
    try res_a.data.append(allocator, 1);
    try std.testing.expectEqual(@as(usize, 1), res_a.data.items.len);

    const res_b = world.getResourcePtrMut(ResourceB);
    try res_b.items.append(allocator, 42);
    try std.testing.expectEqual(@as(usize, 1), res_b.items.items.len);
}
