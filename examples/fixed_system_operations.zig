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

const World = sparze.FixedWorld(struct { Position, Velocity, Health });

// Define systems as regular functions
fn startupSystem() !void {
    std.debug.print("Startup system called!\n", .{});
}

fn terminationSystem() !void {
    std.debug.print("Termination system called!\n", .{});
}

fn movementSystem(group: World.Group(struct { Position, Velocity })) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    for (group.getEntities(), positions, velocities) |entity, *pos, vel| {
        pos.x += vel.x * 0.02;
        pos.y += vel.y * 0.02;
        std.debug.print("entity: {any}, pos: .{{ .x = {d}, .y = {d} }}, vel: {any}\n", .{ entity, pos.x, pos.y, vel });
    }
}

fn healthSystem(query: World.SingleQuery(Health)) !void {
    for (query.entities, query.components) |entity, health| {
        std.debug.print("entity: {any}, health: {d} hp\n", .{ entity, health.hp });
    }
}

fn positionSystem(query: World.SingleQuery(Position)) !void {
    for (query.entities, query.components) |entity, *pos| {
        std.debug.print("entity: {any}, pos: .{{ .x = {d}, .y = {d} }}\n", .{ entity, pos.x, pos.y });
        pos.y -= 1;
    }
}

fn noQuerySystem() !void {
    std.debug.print("This system has no queries!\n", .{});
}

fn multiQuerySystem(
    movement_group: World.Group(struct { Position, Velocity }),
    health_query: World.SingleQuery(Health),
) !void {
    std.debug.print("Multi-query system:\n", .{});
    std.debug.print("  Movement entities: {}\n", .{movement_group.getEntities().len});
    std.debug.print("  Health entities: {}\n", .{health_query.entities.len});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Validate and create groups at compile time
    World.validateGroups(.{
        struct { Position, Velocity },
    });
    try world.createGroup(struct { Position, Velocity });

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .x = -1.0, .y = 0.5 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });

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
    }

    // Run termination systems
    try world.runSystem(terminationSystem);
}
