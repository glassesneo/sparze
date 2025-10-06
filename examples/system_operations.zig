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

const SystemScheduler = std.ArrayList(sparze.SystemPointerType);

fn run(scheduler: SystemScheduler, world: *sparze.DynamicWorld) !void {
    for (scheduler.items) |system| {
        try system(world);
    }
}

const MyGroup = struct { Position, Velocity };

const PositionQuery = sparze.SingleQuery(Position);

fn startupSystem() !void {
    std.debug.print("Startup system called!\n", .{});
}

fn terminationSystem() !void {
    std.debug.print("Termination system called!\n", .{});
}

fn systemWithNormalQueries(query1: sparze.SingleQuery(Position), query2: sparze.SingleQuery(Velocity)) !void {
    _ = query2;
    for (query1.entities, query1.components) |entity, *pos| {
        std.debug.print("entity: {any}, pos: .{{ .x = {d}, .y = {d} }}\n", .{ entity, pos.x, pos.y });
        pos.y -= 1;
    }
}

fn systemWithGroup(group: sparze.Group(MyGroup)) !void {
    for (group.getEntities(), group.getMutArrayOf(Position), group.getArrayOf(Velocity)) |e, *pos, vel| {
        pos.x += vel.x * 0.02;
        std.debug.print("entity: {any}, pos: .{{ .x = {d}, .y = {d} }}, vel: {any}\n", .{ e, pos.x, pos.y, vel });
    }
}

fn systemWithNoQuery() !void {
    std.debug.print("This system has no queries!\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = sparze.DynamicWorld.init(allocator);
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
    try world.addComponent(e3, Velocity, .{ .x = 50.0, .y = 60.0 });

    try world.createGroup(MyGroup);

    var systems: SystemScheduler = .{};
    defer systems.deinit(allocator);

    var startup_systems: SystemScheduler = .{};
    defer startup_systems.deinit(allocator);
    var terminate_systems: SystemScheduler = .{};
    defer terminate_systems.deinit(allocator);

    try startup_systems.append(allocator, sparze.createSystemFunction(startupSystem));
    try systems.append(allocator, sparze.createSystemFunction(systemWithGroup));
    try systems.append(allocator, sparze.createSystemFunction(systemWithNormalQueries));
    try systems.append(allocator, sparze.createSystemFunction(systemWithNoQuery));
    try terminate_systems.append(allocator, sparze.createSystemFunction(terminationSystem));

    try run(startup_systems, &world);
    for (0..10) |_| {
        try run(systems, &world);
    }
    try run(terminate_systems, &world);
}
