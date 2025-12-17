const std = @import("std");
const World = @import("../world.zig").World;
const Resource = @import("../query/filter.zig").Resource;
const ResourceMut = @import("../query/filter.zig").ResourceMut;

// Test: Commands.setResource() marks resource as initialized
test "Commands.setResource marks resource as initialized" {
    const GameConfig = struct { gravity: f32 };
    const TestWorld = World(.{}, .{ GameConfig }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const SetResourceSystem = struct {
        fn system(commands: anytype) void {
            commands.setResource(GameConfig, .{ .gravity = 9.8 });
        }
    };

    // Resource not initialized yet
    try std.testing.expect(!world.isResourceInitialized(GameConfig));

    // Run system that sets resource
    try world.runSystem(SetResourceSystem.system);

    // Should be initialized now
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    // Verify value
    try std.testing.expectEqual(@as(f32, 9.8), world.getResource(GameConfig).gravity);
}

// Test: Commands.getResource() with initialized resource
test "Commands.getResource with initialized resource" {
    const Score = struct { points: i32 };
    const TestWorld = World(.{}, .{ Score }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.setResource(Score, .{ .points = 100 });

    const ReadResourceSystem = struct {
        fn system(commands: anytype) !void {
            const score = commands.getResource(Score);
            try std.testing.expectEqual(@as(i32, 100), score.points);
        }
    };

    // Run system that reads resource
    try world.runSystem(ReadResourceSystem.system);
}

// Test: Commands.getResourcePtr() and Commands.getResourcePtrMut()
test "Commands.getResourcePtr and getResourcePtrMut" {
    const GameState = struct { level: i32, score: i32 };
    const TestWorld = World(.{}, .{ GameState }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.setResource(GameState, .{ .level = 1, .score = 0 });

    const MutateResourceSystem = struct {
        fn system(commands: anytype) !void {
            // Read via const pointer
            const state_const = commands.getResourcePtr(GameState);
            try std.testing.expectEqual(@as(i32, 1), state_const.level);

            // Mutate via mutable pointer
            const state_mut = commands.getResourcePtrMut(GameState);
            state_mut.score = 500;
            state_mut.level = 2;
        }
    };

    try world.runSystem(MutateResourceSystem.system);

    // Verify mutations
    const final_state = world.getResource(GameState);
    try std.testing.expectEqual(@as(i32, 2), final_state.level);
    try std.testing.expectEqual(@as(i32, 500), final_state.score);
}

// Test: Commands.tryGetResource() returns error when uninitialized
test "Commands.tryGetResource returns error when uninitialized" {
    const GameConfig = struct { gravity: f32 };
    const TestWorld = World(.{}, .{ GameConfig }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const TryGetSystem = struct {
        fn system(commands: anytype) !void {
            // Should return error
            try std.testing.expectError(error.UninitializedResource, commands.tryGetResource(GameConfig));
        }
    };

    try world.runSystem(TryGetSystem.system);
}

// Test: Commands.tryGetResource() succeeds when initialized
test "Commands.tryGetResource succeeds when initialized" {
    const GameConfig = struct { gravity: f32 };
    const TestWorld = World(.{}, .{ GameConfig }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.setResource(GameConfig, .{ .gravity = 9.8 });

    const TryGetSystem = struct {
        fn system(commands: anytype) !void {
            const config_ptr = try commands.tryGetResource(GameConfig);
            try std.testing.expectEqual(@as(f32, 9.8), config_ptr.gravity);
        }
    };

    try world.runSystem(TryGetSystem.system);
}

// Test: Commands.tryGetResourceMut() error handling
test "Commands.tryGetResourceMut error handling" {
    const Score = struct { points: i32 };
    const TestWorld = World(.{}, .{ Score }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const TryGetMutUninitializedSystem = struct {
        fn system(commands: anytype) !void {
            try std.testing.expectError(error.UninitializedResource, commands.tryGetResourceMut(Score));
        }
    };

    // Should error when uninitialized
    try world.runSystem(TryGetMutUninitializedSystem.system);

    // Initialize resource
    world.setResource(Score, .{ .points = 0 });

    const TryGetMutSuccessSystem = struct {
        fn system(commands: anytype) !void {
            const score_ptr = try commands.tryGetResourceMut(Score);
            score_ptr.points = 200;
        }
    };

    // Should succeed when initialized
    try world.runSystem(TryGetMutSuccessSystem.system);

    // Verify mutation
    try std.testing.expectEqual(@as(i32, 200), world.getResource(Score).points);
}

// Test: Commands.initResources() bulk initialization
test "Commands.initResources bulk initialization" {
    const DeltaTime = struct { dt: f32 };
    const Score = struct { points: i32 };
    const GameConfig = struct { gravity: f32 };

    const TestWorld = World(.{}, .{ DeltaTime, Score, GameConfig }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const InitResourcesSystem = struct {
        fn system(commands: anytype) !void {
            try commands.initResources(.{
                .delta_time = DeltaTime{ .dt = 0.016 },
                .score = Score{ .points = 0 },
                .game_config = GameConfig{ .gravity = 9.8 },
            });
        }
    };

    // None initialized yet
    try std.testing.expect(!world.isResourceInitialized(DeltaTime));
    try std.testing.expect(!world.isResourceInitialized(Score));
    try std.testing.expect(!world.isResourceInitialized(GameConfig));

    // Run system that initializes all resources
    try world.runSystem(InitResourcesSystem.system);

    // All should be initialized now
    try std.testing.expect(world.isResourceInitialized(DeltaTime));
    try std.testing.expect(world.isResourceInitialized(Score));
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    // Verify values
    try std.testing.expectEqual(@as(f32, 0.016), world.getResource(DeltaTime).dt);
    try std.testing.expectEqual(@as(i32, 0), world.getResource(Score).points);
    try std.testing.expectEqual(@as(f32, 9.8), world.getResource(GameConfig).gravity);
}

// Test: Commands.isResourceInitialized()
test "Commands.isResourceInitialized check" {
    const GameConfig = struct { gravity: f32 };
    const TestWorld = World(.{}, .{ GameConfig }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const CheckInitSystem = struct {
        fn system(commands: anytype) !void {
            // Should not be initialized yet
            try std.testing.expect(!commands.isResourceInitialized(GameConfig));

            // Initialize it
            commands.setResource(GameConfig, .{ .gravity = 9.8 });

            // Should be initialized now
            try std.testing.expect(commands.isResourceInitialized(GameConfig));
        }
    };

    try world.runSystem(CheckInitSystem.system);
}

// Test: Integration - Commands resource methods + Resource parameters
test "Commands and Resource parameters work together" {
    const DeltaTime = struct { dt: f32 };
    const Score = struct { points: i32 };
    const TestWorld = World(.{}, .{ DeltaTime, Score }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resources using Commands
    const InitSystem = struct {
        fn system(commands: anytype) !void {
            try commands.initResources(.{
                .delta_time = DeltaTime{ .dt = 0.016 },
                .score = Score{ .points = 0 },
            });
        }
    };

    try world.runSystem(InitSystem.system);

    // Access resources via Resource parameters and Commands together
    const UpdateSystem = struct {
        fn system(delta: Resource(DeltaTime), score_mut: ResourceMut(Score), commands: anytype) !void {
            // Access via Resource parameter
            const dt = delta.value.dt;
            try std.testing.expectEqual(@as(f32, 0.016), dt);

            // Mutate via ResourceMut parameter
            score_mut.value.points = 100;

            // Also access via Commands
            const delta_via_commands = commands.getResource(DeltaTime);
            try std.testing.expectEqual(@as(f32, 0.016), delta_via_commands.dt);

            // Mutate via Commands
            const score_ptr = commands.getResourcePtrMut(Score);
            score_ptr.points += 50;
        }
    };

    try world.runSystem(UpdateSystem.system);

    // Verify final score (100 + 50 = 150)
    try std.testing.expectEqual(@as(i32, 150), world.getResource(Score).points);
}

// Test: Commands resource operations are immediate (not deferred)
test "Commands resource operations are immediate" {
    const Score = struct { points: i32 };
    const TestWorld = World(.{}, .{ Score }, .{}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const ImmediateSystem = struct {
        fn system(commands: anytype) !void {
            // Set resource
            commands.setResource(Score, .{ .points = 100 });

            // Immediately readable (not deferred like component operations)
            const score = commands.getResource(Score);
            try std.testing.expectEqual(@as(i32, 100), score.points);

            // Mutate it
            const score_ptr = commands.getResourcePtrMut(Score);
            score_ptr.points = 200;

            // Immediately reflects change
            const updated_score = commands.getResource(Score);
            try std.testing.expectEqual(@as(i32, 200), updated_score.points);
        }
    };

    try world.runSystem(ImmediateSystem.system);

    // No need to call endFrame() - resource is already set
    try std.testing.expectEqual(@as(i32, 200), world.getResource(Score).points);
}
