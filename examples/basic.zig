const std = @import("std");
const sparze = @import("sparze");
const SingleQuery = sparze.SingleQuery;

// Define a component type
const Position = struct {
    x: f32,
    y: f32,
};

const World = sparze.World(struct { Position }, struct {});

// Spawn a couple of entities using Commands (deferred component ops)
fn spawnSystem(commands: anytype) !void {
    const e1 = commands.createEntity();
    try commands.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });

    const e2 = commands.createEntity();
    try commands.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Record spawn operations and apply them at end of frame
    world.beginFrame();
    try world.runSystem(spawnSystem);
    try world.endFrame();

    // Query and print positions
    const query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    for (query.entities, query.components) |entity, pos| {
        std.debug.print("entity: {any}, position: ({d}, {d})\n", .{ entity, pos.x, pos.y });
    }
}
