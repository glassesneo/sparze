// resources_init.zig - Resource Initialization and Access
//
// This example demonstrates global resources in Sparze:
// - Declaring resource types in World definition
// - CRITICAL: Resources MUST be initialized before use
// - Using initResources() for bulk initialization
// - Resource(T) for read-only access in systems
// - ResourceMut(T) for mutable access in systems
// - isResourceInitialized() for runtime checks
//
// Run with: zig build run-resources_init

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Component Definitions
// =============================================================================
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

// =============================================================================
// Resource Definitions
// =============================================================================
// Resources are singleton data - only one instance per type exists in the World.
// Use them for global state that many systems need to access.

/// Time elapsed since last frame (set by game loop)
const DeltaTime = struct {
    dt: f32,
};

/// Accumulated game time
const GameTime = struct {
    elapsed: f32,
    frame_count: u64,
};

/// Game configuration (read-only after init)
const GameConfig = struct {
    world_width: f32,
    world_height: f32,
    gravity: f32,
};

/// Mutable game state
const GameState = struct {
    score: i32,
    is_paused: bool,
};

// =============================================================================
// World Definition with Resources
// =============================================================================
const World = sparze.World(
    .{ Position, Velocity }, // Components
    .{ DeltaTime, GameTime, GameConfig, GameState }, // Resources
    .{}, // Events
    .{}, // Groups
);

// =============================================================================
// Systems Using Resources
// =============================================================================

/// Movement system uses DeltaTime (read-only) to scale velocity
fn movementSystem(
    delta: sparze.Resource(DeltaTime),
    query: sparze.SingleQuery(Position),
    vel_query: sparze.SingleQuery(Velocity),
) !void {
    const dt = delta.dt;

    for (query.entities, query.components) |entity, *pos| {
        for (vel_query.entities, vel_query.components) |vel_entity, vel| {
            if (entity == vel_entity) {
                pos.x += vel.dx * dt;
                pos.y += vel.dy * dt;
                break;
            }
        }
    }
}

/// Physics system applies gravity using config
fn gravitySystem(
    config: sparze.Resource(GameConfig),
    delta: sparze.Resource(DeltaTime),
    vel_query: sparze.SingleQuery(Velocity),
) !void {
    const gravity = config.gravity;
    const dt = delta.dt;

    for (vel_query.components) |*vel| {
        vel.dy += gravity * dt;
    }
}

/// Time tracking system mutates GameTime
fn timeSystem(
    delta: sparze.Resource(DeltaTime),
    time: sparze.ResourceMut(GameTime),
) !void {
    time.elapsed += delta.dt;
    time.frame_count += 1;
}

/// Scoring system - adds points each frame (for demo)
fn scoreSystem(
    state: sparze.ResourceMut(GameState),
    query: sparze.SingleQuery(Position),
) !void {
    // Skip if paused
    if (state.is_paused) return;

    // Award points for each entity
    state.score += @intCast(query.entities.len);
}

/// Boundary check system
fn boundarySystem(
    config: sparze.Resource(GameConfig),
    query: sparze.SingleQuery(Position),
) !void {
    for (query.components) |*pos| {
        // Wrap around world boundaries
        if (pos.x < 0) pos.x += config.world_width;
        if (pos.x > config.world_width) pos.x -= config.world_width;
        if (pos.y < 0) pos.y = 0; // Floor
        if (pos.y > config.world_height) pos.y = config.world_height;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("=== Sparze ECS: Resource Initialization ===\n\n", .{});

    // ==========================================================================
    // CRITICAL: Initialize Resources Before Use
    // ==========================================================================
    // Accessing uninitialized resources triggers a panic in Debug/ReleaseSafe.
    // Always initialize resources at startup!

    std.debug.print("--- Checking initialization status ---\n", .{});
    std.debug.print("  DeltaTime initialized: {}\n", .{world.isResourceInitialized(DeltaTime)});
    std.debug.print("  GameConfig initialized: {}\n", .{world.isResourceInitialized(GameConfig)});

    // Method 1: initResources() for bulk initialization (recommended)
    std.debug.print("\n--- Using initResources() ---\n", .{});
    try world.initResources(.{
        .delta_time = DeltaTime{ .dt = 0.016 }, // ~60 FPS
        .game_time = GameTime{ .elapsed = 0.0, .frame_count = 0 },
        .game_config = GameConfig{
            .world_width = 800.0,
            .world_height = 600.0,
            .gravity = 9.8,
        },
        .game_state = GameState{
            .score = 0,
            .is_paused = false,
        },
    });

    std.debug.print("  All resources initialized!\n", .{});
    std.debug.print("  DeltaTime initialized: {}\n", .{world.isResourceInitialized(DeltaTime)});

    // Method 2: setResource() for individual resources
    // world.setResource(DeltaTime, .{ .dt = 0.016 });

    // ==========================================================================
    // Create Some Entities
    // ==========================================================================
    std.debug.print("\n--- Creating entities ---\n", .{});

    world.beginFrame();
    const spawn = struct {
        fn system(commands: anytype) !void {
            _ = try commands.createEntityWith(.{
                Position{ .x = 100.0, .y = 300.0 },
                Velocity{ .dx = 50.0, .dy = -100.0 },
            });
            _ = try commands.createEntityWith(.{
                Position{ .x = 400.0, .y = 200.0 },
                Velocity{ .dx = -30.0, .dy = 50.0 },
            });
        }
    }.system;
    try world.runSystem(spawn);
    try world.endFrame();
    std.debug.print("  Created 2 entities with Position and Velocity\n", .{});

    // ==========================================================================
    // Run Simulation
    // ==========================================================================
    std.debug.print("\n--- Running simulation (10 frames) ---\n", .{});

    var frame: u32 = 0;
    while (frame < 10) : (frame += 1) {
        world.beginFrame();

        // Update delta time (normally from real elapsed time)
        world.setResource(DeltaTime, .{ .dt = 0.016 });

        // Run systems - they access resources automatically
        try world.runSystem(timeSystem);
        try world.runSystem(gravitySystem);
        try world.runSystem(movementSystem);
        try world.runSystem(boundarySystem);
        try world.runSystem(scoreSystem);

        try world.endFrame();

        // Report every 3 frames
        if (frame % 3 == 0) {
            const time = world.getResource(GameTime);
            const state = world.getResource(GameState);
            std.debug.print("  Frame {}: elapsed={d:.2}s, score={}\n", .{
                time.frame_count,
                time.elapsed,
                state.score,
            });
        }
    }

    // ==========================================================================
    // Direct Resource Access
    // ==========================================================================
    std.debug.print("\n--- Direct resource access ---\n", .{});

    // Read-only access
    const config = world.getResource(GameConfig);
    std.debug.print("  World size: {d:.0}x{d:.0}\n", .{ config.world_width, config.world_height });

    // Mutable pointer access
    const state_ptr = world.getResourcePtrMut(GameState);
    std.debug.print("  Final score: {}\n", .{state_ptr.score});
    state_ptr.is_paused = true;
    std.debug.print("  Game paused: {}\n", .{state_ptr.is_paused});

    // Safe access with error handling
    if (world.tryGetResource(GameTime)) |time_ptr| {
        std.debug.print("  Total frames: {}\n", .{time_ptr.frame_count});
    } else |_| {
        std.debug.print("  GameTime not initialized!\n", .{});
    }

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("\n=== Key Takeaways ===\n", .{});
    std.debug.print("1. Resources MUST be initialized before use (panic in Debug)\n", .{});
    std.debug.print("2. Use initResources() at startup for bulk initialization\n", .{});
    std.debug.print("3. Resource(T) = read-only access in systems\n", .{});
    std.debug.print("4. ResourceMut(T) = mutable access in systems\n", .{});
    std.debug.print("5. Use isResourceInitialized() for runtime checks\n", .{});
    std.debug.print("6. Resources are global singletons - use sparingly\n", .{});
}
