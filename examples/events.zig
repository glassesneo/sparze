const std = @import("std");
const sparze = @import("sparze");

// Component types
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };

// Event types
const Collision = struct {
    entity_a: sparze.Entity,
    entity_b: sparze.Entity,
};

const Damage = struct {
    entity: sparze.Entity,
    amount: i32,
};

const Death = struct {
    entity: sparze.Entity,
};

// Define World with components, resources, and events
const World = sparze.World(
    struct { Position, Velocity, Health },
    struct {},
    struct { Collision, Damage, Death },
);

/// System that detects collisions and sends Collision events
fn collisionDetection(
    positions: sparze.Query(struct { Position }),
    writer: sparze.EventWriter(Collision),
    allocator: std.mem.Allocator,
) !void {
    var entities: std.ArrayList(sparze.Entity) = .{};
    defer entities.deinit(allocator);

    // Collect all entities with positions
    for (positions.entities) |entity| {
        if (positions.filter(entity)) {
            try entities.append(allocator, entity);
        }
    }

    // Simple collision detection (all entities within distance 10)
    for (entities.items, 0..) |entity_a, i| {
        const pos_a = positions.getComponent(entity_a, Position);

        for (entities.items[i + 1 ..]) |entity_b| {
            const pos_b = positions.getComponent(entity_b, Position);

            const dx = pos_a.x - pos_b.x;
            const dy = pos_a.y - pos_b.y;
            const dist_sq = dx * dx + dy * dy;

            if (dist_sq < 100.0) { // Distance less than 10
                try writer.enqueue(.{ .entity_a = entity_a, .entity_b = entity_b });
                std.debug.print("Collision detected between entities!\n", .{});
            }
        }
    }
}

/// System that reads Collision events and sends Damage events
fn collisionResponse(
    reader: sparze.EventReader(Collision),
    writer: sparze.EventWriter(Damage),
) !void {
    for (reader.queue) |collision| {
        // Both entities take damage
        try writer.enqueue(.{ .entity = collision.entity_a, .amount = 10 });
        try writer.enqueue(.{ .entity = collision.entity_b, .amount = 10 });
        std.debug.print("Collision response: damage sent to both entities\n", .{});
    }
}

/// System that reads Damage events and applies them to Health components
fn damageSystem(
    reader: sparze.EventReader(Damage),
    health_query: sparze.Query(struct { Health }),
    death_writer: sparze.EventWriter(Death),
) !void {
    for (reader.queue) |damage| {
        if (health_query.getOptionalMut(damage.entity, Health)) |health| {
            health.hp -= damage.amount;
            std.debug.print("Entity {any} took {d} damage, remaining HP: {d}\n", .{ damage.entity, damage.amount, health.hp });

            if (health.hp <= 0) {
                try death_writer.enqueue(.{ .entity = damage.entity });
                std.debug.print("Entity {any} died!\n", .{damage.entity});
            }
        }
    }
}

/// System that reads Death events and removes entities
fn deathSystem(
    reader: sparze.EventReader(Death),
    commands: anytype,
) !void {
    for (reader.queue) |death| {
        try commands.destroyEntity(death.entity);
        std.debug.print("Entity {any} destroyed\n", .{death.entity});
    }
}

/// System that updates positions based on velocity
fn movementSystem(movement: sparze.Group(struct { Position, Velocity })) !void {
    const positions = movement.getMutArrayOf(Position);
    const velocities = movement.getArrayOf(Velocity);

    for (positions, velocities) |*pos, vel| {
        pos.x += vel.dx;
        pos.y += vel.dy;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create movement group
    try world.createGroup(struct { Position, Velocity });

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 2.0, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -1.0 });
    try world.addComponent(e2, Health, .{ .hp = 100 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 20.0, .y = 20.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.0, .dy = 0.0 });
    try world.addComponent(e3, Health, .{ .hp = 100 });

    std.debug.print("=== Sparze Event System Example ===\n\n", .{});

    // Run simulation for 10 frames
    var frame: u32 = 0;
    while (frame < 20) : (frame += 1) {
        std.debug.print("--- Frame {d} ---\n", .{frame});

        // Begin frame: swap event buffers
        world.beginFrame();

        // Run systems
        try world.runSystem(movementSystem);
        try world.runSystem(collisionDetection);
        try world.runSystem(collisionResponse);
        try world.runSystem(damageSystem);
        try world.runSystem(deathSystem);

        // End frame: flush commands
        try world.endFrame();

        std.debug.print("\n", .{});
    }

    std.debug.print("=== Simulation Complete ===\n", .{});
}
