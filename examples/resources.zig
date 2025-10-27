const std = @import("std");
const sparze = @import("sparze");

// Resources - Global singleton data
const DeltaTime = struct { dt: f32 };
const Score = struct {
    points: i32,
    combo: i32,
    high_score: i32,
};
const GameConfig = struct {
    gravity: f32,
    max_speed: f32,
    friction: f32,
};
const GameState = struct {
    level: i32,
    paused: bool,
};

// Components
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };

// Tags
const Player = struct {};
const Enemy = struct {};
const Collectible = struct {};
const Dead = struct {};

// Create World with components and resources
const World = sparze.World(
    struct { Position, Velocity, Health, Player, Enemy, Collectible, Dead },
    struct { DeltaTime, Score, GameConfig, GameState },
);

// Physics system using multiple resources
fn physicsSystem(
    delta: sparze.Resource(DeltaTime),
    config: sparze.Resource(GameConfig),
    state: sparze.Resource(GameState),
    movement: sparze.Query(struct { Position, Velocity, sparze.Exclude(Dead) }),
) !void {
    if (state.value.paused) return; // Skip physics when paused

    const dt = delta.value.dt;
    const gravity = config.value.gravity;
    const friction = config.value.friction;
    const max_speed = config.value.max_speed;

    for (movement.entities) |entity| {
        if (movement.filter(entity)) {
            const pos = movement.getComponentMut(entity, Position);
            const vel = movement.getComponentMut(entity, Velocity);

            // Apply gravity
            vel.dy -= gravity * dt;

            // Apply friction
            vel.dx *= 1.0 - (friction * dt);

            // Clamp to max speed
            const speed = @sqrt(vel.dx * vel.dx + vel.dy * vel.dy);
            if (speed > max_speed) {
                const scale = max_speed / speed;
                vel.dx *= scale;
                vel.dy *= scale;
            }

            // Update position
            pos.x += vel.dx * dt;
            pos.y += vel.dy * dt;
        }
    }
}

// Combat system that updates score resource
fn combatSystem(
    score: sparze.Resource(Score),
    enemies: sparze.Query(struct { Enemy, Health, sparze.Exclude(Dead) }),
    commands: anytype,
) !void {
    for (enemies.entities) |entity| {
        if (enemies.filter(entity)) {
            const health = enemies.getComponent(entity, Health);

            // Enemy defeated - update score
            if (health.hp <= 0) {
                score.value.points += 100;
                score.value.combo += 1;

                // Update high score
                if (score.value.points > score.value.high_score) {
                    score.value.high_score = score.value.points;
                }

                // Mark as dead
                try commands.addTag(entity, Dead);
            }
        }
    }
}

// Collectible system that updates score
fn collectibleSystem(
    score: sparze.Resource(Score),
    player: sparze.Query(struct { Player, Position }),
    collectibles: sparze.Query(struct { Collectible, Position }),
    commands: anytype,
) !void {
    for (player.entities) |player_entity| {
        if (player.filter(player_entity)) {
            const player_pos = player.getComponent(player_entity, Position);

            for (collectibles.entities) |collectible_entity| {
                if (collectibles.filter(collectible_entity)) {
                    const collectible_pos = collectibles.getComponent(collectible_entity, Position);

                    // Check collision (simple distance check)
                    const dx = player_pos.x - collectible_pos.x;
                    const dy = player_pos.y - collectible_pos.y;
                    const distance = @sqrt(dx * dx + dy * dy);

                    if (distance < 10.0) {
                        // Collect the item
                        score.value.points += 50;
                        try commands.destroyEntity(collectible_entity);
                    }
                }
            }
        }
    }
}

// Level progression system using multiple resources
fn levelSystem(
    score: sparze.Resource(Score),
    state: sparze.Resource(GameState),
    config: sparze.Resource(GameConfig),
) !void {
    // Level up every 1000 points
    const new_level = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(score.value.points)) / 1000.0))) + 1;

    if (new_level > state.value.level) {
        state.value.level = new_level;

        // Increase difficulty
        config.value.gravity += 1.0;
        config.value.max_speed += 5.0;

        std.debug.print("\n🎉 Level Up! Now on level {d}\n", .{state.value.level});
        std.debug.print("   Gravity: {d:.1}, Max Speed: {d:.1}\n", .{ config.value.gravity, config.value.max_speed });
    }
}

// Stats display system
fn statsSystem(
    score: sparze.Resource(Score),
    state: sparze.Resource(GameState),
) !void {
    std.debug.print("\n📊 Game Stats:\n", .{});
    std.debug.print("   Score: {d} (High: {d})\n", .{ score.value.points, score.value.high_score });
    std.debug.print("   Combo: x{d}\n", .{score.value.combo});
    std.debug.print("   Level: {d}\n", .{state.value.level});
    std.debug.print("   Paused: {}\n", .{state.value.paused});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Initialize all resources - REQUIRED before use
    try world.setResource(DeltaTime, .{ .dt = 0.016 }); // 60 FPS
    try world.setResource(Score, .{
        .points = 0,
        .combo = 0,
        .high_score = 0,
    });
    try world.setResource(GameConfig, .{
        .gravity = 9.8,
        .max_speed = 100.0,
        .friction = 0.1,
    });
    try world.setResource(GameState, .{
        .level = 1,
        .paused = false,
    });

    std.debug.print("=== Resources Example ===\n", .{});
    std.debug.print("Demonstrating global resources in Sparze ECS\n\n", .{});

    // Create player
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .dx = 50.0, .dy = 0.0 });
    try world.addTag(player, Player);

    // Create enemies with health
    for (0..5) |i| {
        const enemy = world.createEntity();
        try world.addComponent(enemy, Position, .{
            .x = @as(f32, @floatFromInt(i)) * 20.0,
            .y = 10.0,
        });
        try world.addComponent(enemy, Velocity, .{ .dx = 0.0, .dy = 0.0 });
        try world.addComponent(enemy, Health, .{ .hp = @as(i32, @intCast(i)) + 1 }); // Varying health
        try world.addTag(enemy, Enemy);
    }

    // Create collectibles
    for (0..3) |i| {
        const collectible = world.createEntity();
        try world.addComponent(collectible, Position, .{
            .x = @as(f32, @floatFromInt(i)) * 15.0 + 5.0,
            .y = 0.0,
        });
        try world.addTag(collectible, Collectible);
    }

    std.debug.print("Initial state:\n", .{});
    try world.runSystem(statsSystem);

    // Simulate game loop
    std.debug.print("\n--- Simulating 3 frames ---\n", .{});

    for (0..3) |frame| {
        world.beginFrame();

        std.debug.print("\nFrame {d}:\n", .{frame + 1});

        // Run systems
        try world.runSystem(physicsSystem);
        try world.runSystem(collectibleSystem);

        // Damage enemies to demonstrate score updates
        if (frame == 1) {
            const damage_enemies_query = sparze.Query(struct { Enemy, Health }).init(&world);
            for (damage_enemies_query.entities) |entity| {
                if (damage_enemies_query.filter(entity)) {
                    const health = damage_enemies_query.getComponentMut(entity, Health);
                    health.hp -= 10; // Damage all enemies
                }
            }
            std.debug.print("  💥 Damaged all enemies!\n", .{});
        }

        try world.runSystem(combatSystem);
        try world.runSystem(levelSystem);

        try world.endFrame();
    }

    // Toggle pause and show stats
    std.debug.print("\n--- Pausing game ---\n", .{});
    const state_ptr = world.getResourcePtrMut(GameState);
    state_ptr.paused = true;

    try world.runSystem(statsSystem);

    // Run physics while paused (should skip updates)
    world.beginFrame();
    try world.runSystem(physicsSystem);
    try world.endFrame();
    std.debug.print("\n✓ Physics skipped while paused\n", .{});

    // Unpause and continue
    state_ptr.paused = false;
    std.debug.print("\n--- Resuming game ---\n", .{});

    // Demonstrate resource mutation outside systems
    const score_ptr = world.getResourcePtrMut(Score);
    score_ptr.points += 500; // Bonus points
    std.debug.print("🎁 Bonus points awarded!\n", .{});

    try world.runSystem(levelSystem);
    try world.runSystem(statsSystem);

    // Access resources for final report
    const final_score = world.getResource(Score);
    const final_state = world.getResource(GameState);
    const final_config = world.getResource(GameConfig);

    std.debug.print("\n=== Final Summary ===\n", .{});
    std.debug.print("Score: {d}/{d} (combo: x{d})\n", .{
        final_score.points,
        final_score.high_score,
        final_score.combo,
    });
    std.debug.print("Level: {d}\n", .{final_state.level});
    std.debug.print("Game Config: gravity={d:.1}, max_speed={d:.1}, friction={d:.2}\n", .{
        final_config.gravity,
        final_config.max_speed,
        final_config.friction,
    });

    std.debug.print("\n✅ Resources example completed!\n", .{});
}
