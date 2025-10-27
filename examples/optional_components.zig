const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Shield = struct { value: i32 };

const World = sparze.World(struct { Position, Velocity, Health, Shield }, struct {});
const Query = sparze.Query;

/// Movement system processes all entities with Position and Velocity,
/// optionally considering Health for damage-based slowdown
fn movementSystem(query: Query(struct { Position, Velocity, ?Health })) !void {
    std.debug.print("\n=== Movement System ===\n", .{});
    
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponentMut(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            
            // Apply movement
            pos.x += vel.dx;
            pos.y += vel.dy;
            
            // Optional: reduce speed if entity is low on health
            if (query.getOptional(entity, Health)) |health| {
                if (health.hp < 30) {
                    std.debug.print("Entity {} is injured (HP: {}), moving slower\n", .{ entity, health.hp });
                    pos.x -= vel.dx * 0.5;  // Move at half speed
                    pos.y -= vel.dy * 0.5;
                }
            }
            
            std.debug.print("Entity {}: moved to ({d:.2}, {d:.2})\n", .{ entity, pos.x, pos.y });
        }
    }
}

/// Combat system processes entities with Health,
/// optionally considering Shield for damage reduction
fn combatSystem(query: Query(struct { Health, ?Shield })) !void {
    std.debug.print("\n=== Combat System (applying damage) ===\n", .{});
    
    const damage = 15;
    
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const health = query.getComponentMut(entity, Health);
            
            var actual_damage = damage;
            
            // Optional: shield absorbs some damage
            if (query.getOptionalMut(entity, Shield)) |shield| {
                const absorbed = @min(shield.value, actual_damage);
                shield.value -= absorbed;
                actual_damage -= absorbed;
                std.debug.print("Entity {}: shield absorbed {} damage ({} remaining)\n", .{ entity, absorbed, shield.value });
            }
            
            health.hp -= actual_damage;
            std.debug.print("Entity {}: took {} damage, HP: {}\n", .{ entity, actual_damage, health.hp });
        }
    }
}

/// Status display system shows all entities with Position,
/// optionally displaying Health and Shield if present
fn statusDisplaySystem(query: Query(struct { Position, ?Health, ?Shield })) !void {
    std.debug.print("\n=== Entity Status ===\n", .{});
    
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            
            std.debug.print("Entity {} at ({d:.2}, {d:.2})", .{ entity, pos.x, pos.y });
            
            if (query.getOptional(entity, Health)) |health| {
                std.debug.print(" | HP: {}", .{health.hp});
            }
            
            if (query.getOptional(entity, Shield)) |shield| {
                std.debug.print(" | Shield: {}", .{shield.value});
            }
            
            std.debug.print("\n", .{});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Optional Components Example                      ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\nDemonstrates Query with optional components (?Component)\n", .{});
    std.debug.print("to handle entities with varying component combinations.\n", .{});

    // Create diverse entities
    std.debug.print("\n--- Creating Entities ---\n", .{});
    
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .dx = 2.0, .dy = 1.0 });
    try world.addComponent(player, Health, .{ .hp = 100 });
    try world.addComponent(player, Shield, .{ .value = 50 });
    std.debug.print("Player: Position, Velocity, Health, Shield\n", .{});

    const enemy = world.createEntity();
    try world.addComponent(enemy, Position, .{ .x = 10.0, .y = 10.0 });
    try world.addComponent(enemy, Velocity, .{ .dx = -1.0, .dy = -0.5 });
    try world.addComponent(enemy, Health, .{ .hp = 50 });
    std.debug.print("Enemy: Position, Velocity, Health (no shield)\n", .{});

    const projectile = world.createEntity();
    try world.addComponent(projectile, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addComponent(projectile, Velocity, .{ .dx = 3.0, .dy = 3.0 });
    std.debug.print("Projectile: Position, Velocity (no health/shield)\n", .{});

    const obstacle = world.createEntity();
    try world.addComponent(obstacle, Position, .{ .x = 15.0, .y = 15.0 });
    try world.addComponent(obstacle, Health, .{ .hp = 20 });
    std.debug.print("Obstacle: Position, Health (no velocity/shield)\n", .{});

    // Run game loop
    for (0..3) |frame| {
        std.debug.print("\n\n╔═══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║                    Frame {}                               ║\n", .{frame + 1});
        std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
        
        try world.runSystem(statusDisplaySystem);
        try world.runSystem(movementSystem);
        
        if (frame == 1) {
            try world.runSystem(combatSystem);
        }
    }

    std.debug.print("\n\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                      Summary                              ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\nOptional components allow flexible queries:\n", .{});
    std.debug.print("• Movement system works on entities with/without Health\n", .{});
    std.debug.print("• Combat system works on entities with/without Shield\n", .{});
    std.debug.print("• Status system shows all info when available\n", .{});
    std.debug.print("\nUse getOptional() to safely access optional components!\n", .{});
}
