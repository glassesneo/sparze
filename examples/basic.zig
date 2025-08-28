const std = @import("std");
const sparze = @import("sparze");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var registry = sparze.EntityRegistry.init();

    // Create entities
    const e1 = registry.create();
    const e2 = registry.create();
    std.debug.print("Created entities: e1={any} e2={any}\n", .{ e1, e2 });

    // Define a component type
    const Position = struct {
        x: f32,
        y: f32,
    };

    // Create a sparse set for Position components
    var positions = sparze.SparseSet(Position).init(allocator);
    defer positions.deinit();

    // Attach components
    try positions.insert(e1, Position{ .x = 1.0, .y = 2.0 });
    try positions.insert(e2, Position{ .x = 3.0, .y = 4.0 });

    // Query components
    if (positions.get(e1)) |pos| {
        std.debug.print("e1 position: ({any}, {any})\n", .{ pos.x, pos.y });
    }
    if (positions.get(e2)) |pos| {
        std.debug.print("e2 position: ({any}, {any})\n", .{ pos.x, pos.y });
    }

    // Remove a component
    positions.remove(e1);
    std.debug.print("e1 position after removal: {?}\n", .{positions.get(e1)});

    // Destroy an entity
    registry.destroy(e2);
    std.debug.print("e2 alive after destroy: {any}\n", .{registry.isAlive(e2)});
}
