const std = @import("std");
const sparze = @import("sparze");

const Position = struct {
    x: f32,
    y: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = sparze.World.init(allocator);
    defer world.deinit();
    const e1 = world.createEntity();

    var position_sparse_set = sparze.SparseSet(Position).init(allocator);
    defer position_sparse_set.deinit();

    try world.registerComponent(Position, &position_sparse_set);
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    std.debug.print("position: {any}\n", .{world.getComponent(e1, Position)});
    world.destroyEntity(e1);
    std.debug.print("position: {any}\n", .{world.getComponent(e1, Position)});
}
