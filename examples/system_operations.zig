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

fn exampleSystem(query1: sparze.SingleQuery(Position), query2: sparze.SingleQuery(Velocity)) !void {
    _ = query2;
    for (query1.entities, query1.components) |entity, pos| {
        std.debug.print("entity: {any}, pos: {any}\n", .{ entity, pos });
    }
}

fn systemWithNoQuery() !void {
    std.debug.print("This system has no queries!\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = sparze.World.init(allocator);
    defer world.deinit();
    const e1 = world.createEntity();
    const e2 = world.createEntity();
    const e3 = world.createEntity();

    var position_sparse_set = sparze.SparseSet(Position).init(allocator);
    defer position_sparse_set.deinit();

    var velocity_sparse_set = sparze.SparseSet(Velocity).init(allocator);
    defer velocity_sparse_set.deinit();

    try world.registerComponent(Position, &position_sparse_set);
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });

    try world.registerComponent(Velocity, &velocity_sparse_set);
    try world.addComponent(e1, Velocity, .{ .x = 10.0, .y = 30.0 });

    world.registerSystem(exampleSystem, .update);
    world.registerSystem(systemWithNoQuery, .last);

    try world.runSystems();
}
