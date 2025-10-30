const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Armor = struct { value: i32 };

const World = sparze.World(struct { Position, Velocity, Health, Armor }, struct {}, struct {});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Reserve() Performance Benchmark ===\n\n", .{});
    std.debug.print("This benchmark demonstrates the performance impact of using reserve()\n", .{});
    std.debug.print("before bulk insertions to eliminate reallocation overhead.\n\n", .{});

    const entity_counts = [_]usize{ 1_000, 5_000, 10_000, 50_000 };

    for (entity_counts) |count| {
        std.debug.print("--- Bulk Insert: {d} entities ---\n", .{count});

        // Benchmark 1: Without reserve (allows dynamic reallocation)
        const time_without = try benchmarkWithoutReserve(allocator, count);

        // Benchmark 2: With reserve (pre-allocate capacity)
        const time_with = try benchmarkWithReserve(allocator, count);

        // Calculate speedup
        const speedup = @as(f64, @floatFromInt(time_without)) / @as(f64, @floatFromInt(time_with));
        const improvement = (1.0 - (1.0 / speedup)) * 100.0;

        std.debug.print("  Without reserve: {d:.2}ms\n", .{@as(f64, @floatFromInt(time_without)) / 1_000_000.0});
        std.debug.print("  With reserve:    {d:.2}ms\n", .{@as(f64, @floatFromInt(time_with)) / 1_000_000.0});
        std.debug.print("  Speedup:         {d:.2}x ({d:.1}% faster)\n\n", .{ speedup, improvement });
    }

    // Additional benchmark: Multiple component types
    std.debug.print("--- Mixed Components: 10,000 entities with 4 component types ---\n", .{});
    const time_without_mixed = try benchmarkMixedComponentsWithoutReserve(allocator, 10_000);
    const time_with_mixed = try benchmarkMixedComponentsWithReserve(allocator, 10_000);

    const speedup_mixed = @as(f64, @floatFromInt(time_without_mixed)) / @as(f64, @floatFromInt(time_with_mixed));
    const improvement_mixed = (1.0 - (1.0 / speedup_mixed)) * 100.0;

    std.debug.print("  Without reserve: {d:.2}ms\n", .{@as(f64, @floatFromInt(time_without_mixed)) / 1_000_000.0});
    std.debug.print("  With reserve:    {d:.2}ms\n", .{@as(f64, @floatFromInt(time_with_mixed)) / 1_000_000.0});
    std.debug.print("  Speedup:         {d:.2}x ({d:.1}% faster)\n\n", .{ speedup_mixed, improvement_mixed });

    std.debug.print("=== Benchmark Complete ===\n", .{});
    std.debug.print("\nConclusion: reserve() eliminates reallocation overhead during bulk\n", .{});
    std.debug.print("insertions, providing significant performance improvements especially\n", .{});
    std.debug.print("for larger entity counts and when inserting multiple component types.\n", .{});
}

/// Benchmark: bulk insert single component type without reserve
fn benchmarkWithoutReserve(allocator: std.mem.Allocator, count: usize) !i128 {
    var world = World.init(allocator);
    defer world.deinit();

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entity = world.createEntity();
        try world.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
    }
    const end = std.time.nanoTimestamp();

    return end - start;
}

/// Benchmark: bulk insert single component type with reserve
fn benchmarkWithReserve(allocator: std.mem.Allocator, count: usize) !i128 {
    var world = World.init(allocator);
    defer world.deinit();

    // Pre-allocate capacity
    try world.getSparseSetPtrMut(Position).reserve(count);

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entity = world.createEntity();
        try world.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
    }
    const end = std.time.nanoTimestamp();

    return end - start;
}

/// Benchmark: bulk insert multiple component types without reserve
fn benchmarkMixedComponentsWithoutReserve(allocator: std.mem.Allocator, count: usize) !i128 {
    var world = World.init(allocator);
    defer world.deinit();

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entity = world.createEntity();
        try world.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
        try world.addComponent(entity, Velocity, .{ .dx = 0.5, .dy = 0.5 });
        try world.addComponent(entity, Health, .{ .hp = 100 });
        try world.addComponent(entity, Armor, .{ .value = 50 });
    }
    const end = std.time.nanoTimestamp();

    return end - start;
}

/// Benchmark: bulk insert multiple component types with reserve
fn benchmarkMixedComponentsWithReserve(allocator: std.mem.Allocator, count: usize) !i128 {
    var world = World.init(allocator);
    defer world.deinit();

    // Pre-allocate capacity for all component types
    try world.getSparseSetPtrMut(Position).reserve(count);
    try world.getSparseSetPtrMut(Velocity).reserve(count);
    try world.getSparseSetPtrMut(Health).reserve(count);
    try world.getSparseSetPtrMut(Armor).reserve(count);

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entity = world.createEntity();
        try world.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
        try world.addComponent(entity, Velocity, .{ .dx = 0.5, .dy = 0.5 });
        try world.addComponent(entity, Health, .{ .hp = 100 });
        try world.addComponent(entity, Armor, .{ .value = 50 });
    }
    const end = std.time.nanoTimestamp();

    return end - start;
}
