// Demonstrates partial-owning groups where some components are owned (organized)
// and others are free (accessed via indirection).
//
// Use partial-owning groups when:
// - You have hot-path components that need direct array access (make them owned)
// - Other components are needed occasionally (make them free)
// - You want to share components between multiple groups
//
// Run with: zig build run-partial_owning_groups

const std = @import("std");
const sparze = @import("sparze");

// Component definitions
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32, max_hp: i32 };
const Shield = struct { value: i32 };
const Sprite = struct { texture_id: u32 };

// Define World type
const World = sparze.World(
    struct { Position, Velocity, Health, Shield, Sprite },
    struct {},
    struct {},
);

// Physics group: owns Position and Velocity for direct array access (hot path)
// Uses Health as free component (needed for damage on collision, but not in hot loop)
const PhysicsGroup = struct { Position, Velocity, sparze.Free(Health) };

// Render group: owns Sprite, uses Position and Health as free
// Position is free here because it's owned by PhysicsGroup
const RenderGroup = struct { Sprite, sparze.Free(Position), sparze.Free(Health) };

// Combat group: owns Health and Shield
// This is allowed because Health is FREE in PhysicsGroup and RenderGroup
const CombatGroup = struct { Health, Shield };

fn physicsSystem(physics: sparze.Group(PhysicsGroup)) !void {
    const entities = physics.getEntities();

    // Owned components: direct array access (fast, cache-friendly)
    const positions = physics.getMutArrayOf(Position);
    const velocities = physics.getArrayOf(Velocity);

    for (entities, positions, velocities) |entity, *pos, vel| {
        // Update position based on velocity
        pos.x += vel.dx;
        pos.y += vel.dy;

        // Simulate collision damage - access free component via getComponent()
        if (pos.x < 0 or pos.x > 100 or pos.y < 0 or pos.y > 100) {
            // Free component access: one indirection via sparse set
            const health = physics.getComponentMut(entity, Health);
            health.hp -= 10;
            std.debug.print("Entity hit boundary! Health: {d}/{d}\n", .{
                health.hp, health.max_hp
            });
        }
    }
}

fn renderSystem(render: sparze.Group(RenderGroup)) !void {
    const entities = render.getEntities();

    // Owned component: direct array access
    const sprites = render.getArrayOf(Sprite);

    for (entities, sprites) |entity, sprite| {
        // Free components: sparse set lookup
        const pos = render.getComponent(entity, Position);
        const health = render.getComponent(entity, Health);
        const health_pct = @as(f32, @floatFromInt(health.hp)) / @as(f32, @floatFromInt(health.max_hp));

        std.debug.print("Render sprite {d} at ({d:.1}, {d:.1}) with {d}% health\n", .{
            sprite.texture_id, pos.x, pos.y, health_pct * 100
        });
    }
}

fn combatSystem(combat: sparze.Group(CombatGroup)) !void {
    const healths = combat.getArrayOf(Health);
    const shields = combat.getMutArrayOf(Shield);

    for (healths, shields) |health, *shield| {
        // Regenerate shield if health is above 50%
        if (health.hp > @divFloor(health.max_hp, 2)) {
            shield.value = @min(shield.value + 5, 100);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compile-time validation: ensures owned components don't overlap
    // Health is free in PhysicsGroup and RenderGroup, so it CAN be owned by CombatGroup
    comptime World.validateGroups(.{
        PhysicsGroup,
        RenderGroup,
        CombatGroup,
    });

    var world = World.init(allocator);
    defer world.deinit();

    // Create groups
    try world.createGroup(PhysicsGroup);
    try world.createGroup(RenderGroup);
    try world.createGroup(CombatGroup);

    std.debug.print("\n=== Creating Entities ===\n", .{});

    // Create entity with all components (will be in all three groups)
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 50.0, .y = 50.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 15.0, .dy = 20.0 });
    try world.addComponent(e1, Health, .{ .hp = 100, .max_hp = 100 });
    try world.addComponent(e1, Shield, .{ .value = 50 });
    try world.addComponent(e1, Sprite, .{ .texture_id = 42 });

    // Create another entity
    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 80.0, .y = 30.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -25.0, .dy = 15.0 });
    try world.addComponent(e2, Health, .{ .hp = 80, .max_hp = 100 });
    try world.addComponent(e2, Shield, .{ .value = 75 });
    try world.addComponent(e2, Sprite, .{ .texture_id = 43 });

    // Run simulation for a few frames
    for (0..5) |frame| {
        std.debug.print("\n=== Frame {d} ===\n", .{frame});

        try world.runSystem(physicsSystem);
        try world.runSystem(combatSystem);
        try world.runSystem(renderSystem);
    }

    std.debug.print("\n=== Performance Characteristics ===\n", .{});
    std.debug.print("PhysicsGroup (partial-owning):\n", .{});
    std.debug.print("  - Position, Velocity: O(1) direct array access (OWNED)\n", .{});
    std.debug.print("  - Health: O(1) sparse set lookup (FREE)\n", .{});
    std.debug.print("\nRenderGroup (partial-owning):\n", .{});
    std.debug.print("  - Sprite: O(1) direct array access (OWNED)\n", .{});
    std.debug.print("  - Position, Health: O(1) sparse set lookup (FREE)\n", .{});
    std.debug.print("\nCombatGroup (full-owning):\n", .{});
    std.debug.print("  - Health, Shield: O(1) direct array access (OWNED)\n", .{});
    std.debug.print("\nKey benefits:\n", .{});
    std.debug.print("  - Position is owned by PhysicsGroup, free in RenderGroup\n", .{});
    std.debug.print("  - Health is owned by CombatGroup, free in PhysicsGroup and RenderGroup\n", .{});
    std.debug.print("  - Component sharing enabled while maintaining performance!\n", .{});
}
