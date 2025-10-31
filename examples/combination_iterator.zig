const std = @import("std");
const sparze = @import("sparze");

// Components
const Position = struct { x: f32, y: f32 };
const Radius = struct { value: f32 };

// World definition
const World = sparze.World(
    struct { Position, Radius },
    struct {},
    struct {},
);

// Collision detection using CombinationIterator
// This demonstrates checking all unique pairs of entities for collisions
fn collisionDetectionSystem(mut_query: sparze.Query(struct { Position, Radius })) !void {
    std.debug.print("\n=== Collision Detection (All Pairs) ===\n", .{});

    var query = mut_query;
    var iter = query.combinations();

    var collision_count: usize = 0;
    while (iter.next()) |pair| {
        const entity_a, const entity_b = pair;

        const pos_a = query.getComponent(entity_a, Position);
        const pos_b = query.getComponent(entity_b, Position);
        const radius_a = query.getComponent(entity_a, Radius);
        const radius_b = query.getComponent(entity_b, Radius);

        // Calculate distance between entities
        const dx = pos_b.x - pos_a.x;
        const dy = pos_b.y - pos_a.y;
        const distance = @sqrt(dx * dx + dy * dy);

        // Check for collision
        const collision_distance = radius_a.value + radius_b.value;
        if (distance < collision_distance) {
            std.debug.print("Collision detected between Entity({d}) and Entity({d})\n", .{
                entity_a,
                entity_b,
            });
            std.debug.print("  Position A: ({d:.2}, {d:.2}) Radius: {d:.2}\n", .{
                pos_a.x,
                pos_a.y,
                radius_a.value,
            });
            std.debug.print("  Position B: ({d:.2}, {d:.2}) Radius: {d:.2}\n", .{
                pos_b.x,
                pos_b.y,
                radius_b.value,
            });
            std.debug.print("  Distance: {d:.2} (collision if < {d:.2})\n", .{
                distance,
                collision_distance,
            });
            collision_count += 1;
        }
    }

    std.debug.print("\nTotal collisions detected: {d}\n", .{collision_count});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("Sparze CombinationIterator Example\n", .{});
    std.debug.print("===================================\n\n", .{});
    std.debug.print("This example demonstrates using CombinationIterator to check all unique\n", .{});
    std.debug.print("pairs of entities for collisions. Each pair is checked exactly once.\n", .{});

    // Create entities with positions and collision radii
    std.debug.print("\nCreating entities:\n", .{});

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Radius, .{ .value = 5.0 });
    std.debug.print("  Entity 1: Position(0.0, 0.0), Radius(5.0)\n", .{});

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 7.0, .y = 0.0 });
    try world.addComponent(e2, Radius, .{ .value = 3.0 });
    std.debug.print("  Entity 2: Position(7.0, 0.0), Radius(3.0)\n", .{});

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 1.0, .y = 1.0 });
    try world.addComponent(e3, Radius, .{ .value = 2.0 });
    std.debug.print("  Entity 3: Position(1.0, 1.0), Radius(2.0)\n", .{});

    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 20.0, .y = 20.0 });
    try world.addComponent(e4, Radius, .{ .value = 1.0 });
    std.debug.print("  Entity 4: Position(20.0, 20.0), Radius(1.0)\n", .{});

    const e5 = world.createEntity();
    try world.addComponent(e5, Position, .{ .x = 21.0, .y = 21.0 });
    try world.addComponent(e5, Radius, .{ .value = 1.5 });
    std.debug.print("  Entity 5: Position(21.0, 21.0), Radius(1.5)\n", .{});

    // Run collision detection
    try world.runSystem(collisionDetectionSystem);

    // Show the pairs that were checked
    std.debug.print("\n=== Explanation ===\n", .{});
    std.debug.print("The CombinationIterator checked the following unique pairs:\n", .{});
    std.debug.print("  (e1, e2), (e1, e3), (e1, e4), (e1, e5)\n", .{});
    std.debug.print("  (e2, e3), (e2, e4), (e2, e5)\n", .{});
    std.debug.print("  (e3, e4), (e3, e5)\n", .{});
    std.debug.print("  (e4, e5)\n", .{});
    std.debug.print("\nTotal pairs checked: C(5,2) = 10 pairs\n", .{});
    std.debug.print("\nAdvantages:\n", .{});
    std.debug.print("  - Each pair checked exactly once (no duplicates)\n", .{});
    std.debug.print("  - No need to skip self-comparisons\n", .{});
    std.debug.print("  - Clean, iterator-based API\n", .{});
}
