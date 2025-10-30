const std = @import("std");
const sparze = @import("sparze");

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Health = struct {
    hp: i32,
};

const World = sparze.World(struct { Position, Velocity, Health }, struct {}, struct {});
const Group = sparze.Group;
const SingleQuery = sparze.SingleQuery;
const Query = sparze.Query;
const Commands = sparze.Commands;

// Declare group type constant for better readability and maintainability
const MovementGroup = struct { Position, Velocity };

// Define systems as regular functions
fn startupSystem() !void {
    std.debug.print("Startup system called!\n", .{});
}

fn terminationSystem() !void {
    std.debug.print("Termination system called!\n", .{});
}

fn movementSystem(group: Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    for (group.getEntities(), positions, velocities) |entity, *pos, vel| {
        pos.x += vel.x * 0.02;
        pos.y += vel.y * 0.02;
        std.debug.print("entity: {any}, pos: .{{ .x = {d}, .y = {d} }}, vel: {any}\n", .{ entity, pos.x, pos.y, vel });
    }
}

fn healthSystem(query: SingleQuery(Health)) !void {
    for (query.entities, query.components) |entity, health| {
        std.debug.print("entity: {any}, health: {d} hp\n", .{ entity, health.hp });
    }
}

fn positionSystem(query: SingleQuery(Position)) !void {
    for (query.entities, query.components) |entity, *pos| {
        std.debug.print("entity: {any}, pos: .{{ .x = {d}, .y = {d} }}\n", .{ entity, pos.x, pos.y });
        pos.y -= 1;
    }
}

fn noQuerySystem() !void {
    std.debug.print("This system has no queries!\n", .{});
}

fn multiQuerySystem(
    movement_group: Group(MovementGroup),
    health_query: SingleQuery(Health),
) !void {
    std.debug.print("Multi-query system:\n", .{});
    std.debug.print("  Movement entities: {}\n", .{movement_group.getEntities().len});
    std.debug.print("  Health entities: {}\n", .{health_query.entities.len});
}

// Query example: Multi-component query without requiring a group
fn combatQuerySystem(query: Query(struct { Position, Health })) !void {
    std.debug.print("Combat query (no group needed):\n", .{});
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            const health = query.getComponentMut(entity, Health);
            {
                // Apply damage if far from origin
                const dist_sq = pos.x * pos.x + pos.y * pos.y;
                if (dist_sq > 2500.0) {
                    health.hp -= 5;
                    std.debug.print("  Entity {} taking damage! HP: {} (distance: {d:.1})\n", .{ entity, health.hp, @sqrt(dist_sq) });
                }
                count += 1;
            }
        }
    }
    std.debug.print("  Processed {} entities with Position+Health\n", .{count});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Validate and create groups at compile time
    World.validateGroups(.{
        MovementGroup,
    });
    try world.createGroup(MovementGroup);

    // Spawn initial entities with Commands
    const spawn = struct {
        fn system(commands: anytype) !void {
            const e1 = try commands.createEntityWith(.{
                Position{ .x = 10.0, .y = 20.0 },
                Velocity{ .x = 1.0, .y = 2.0 },
                Health{ .hp = 100 },
            });
            _ = e1;

            const e2 = try commands.createEntityWith(.{
                Position{ .x = 30.0, .y = 40.0 },
                Velocity{ .x = -1.0, .y = 0.5 },
            });
            _ = e2;

            const e3 = try commands.createEntityWith(.{
                Position{ .x = 50.0, .y = 60.0 },
            });
            _ = e3;
        }
    }.system;

    world.beginFrame();
    try world.runSystem(spawn);
    try world.endFrame();

    // Run startup systems
    try world.runSystem(startupSystem);

    // Run main game loop
    for (0..3) |frame| {
        std.debug.print("\n--- Running frame {} ---\n", .{frame + 1});
        try world.runSystem(movementSystem);
        try world.runSystem(positionSystem);
        try world.runSystem(healthSystem);
        try world.runSystem(noQuerySystem);
        try world.runSystem(multiQuerySystem);
        try world.runSystem(combatQuerySystem);
    }

    // Run termination systems
    try world.runSystem(terminationSystem);
}
