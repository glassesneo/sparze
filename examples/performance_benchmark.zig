const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Armor = struct { value: i32 };

const World = sparze.World(struct { Position, Velocity, Health, Armor }, struct {});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Sparze Performance Benchmark ===\n\n", .{});

    // Benchmark 1: Entity creation and component insertion (hot path)
    {
        std.debug.print("Benchmark 1: Entity Creation + Component Insertion\n", .{});
        const iterations = 10000;

        var world = World.init(allocator);
        defer world.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
            try world.addComponent(entity, Velocity, .{ .dx = 0.5, .dy = 0.5 });
            try world.addComponent(entity, Health, .{ .hp = 100 });
            try world.addComponent(entity, Armor, .{ .value = 50 });
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Create entities + add 4 components", iterations, end - start);
    }

    // Benchmark 2: Component lookups (bit shift optimization)
    {
        std.debug.print("\nBenchmark 2: Component Lookups (tests bit shift optimization)\n", .{});
        const iterations = 100000;

        var world = World.init(allocator);
        defer world.deinit();

        // Setup: create entities
        var entities: [1000]sparze.Entity = undefined;
        for (&entities) |*entity| {
            entity.* = world.createEntity();
            try world.addComponent(entity.*, Position, .{ .x = 1.0, .y = 2.0 });
            try world.addComponent(entity.*, Velocity, .{ .dx = 0.5, .dy = 0.5 });
        }

        // Benchmark: lookup components
        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const entity = entities[i % entities.len];
            const pos = world.getComponent(entity, Position);
            const vel = world.getComponent(entity, Velocity);
            std.mem.doNotOptimizeAway(&pos);
            std.mem.doNotOptimizeAway(&vel);
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Get component (hot path)", iterations, end - start);
    }

    // Benchmark 3: Component removal (optimized swapRemove)
    {
        std.debug.print("\nBenchmark 3: Component Removal (tests optimized remove)\n", .{});
        const iterations = 5000;

        var world = World.init(allocator);
        defer world.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
            try world.addComponent(entity, Velocity, .{ .dx = 0.5, .dy = 0.5 });
            world.removeComponent(entity, Position);
            world.removeComponent(entity, Velocity);
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Remove components", iterations, end - start);
    }

    // Benchmark 4: Group iteration (tests swapElements optimization)
    {
        std.debug.print("\nBenchmark 4: Group Iteration (tests swapElements optimization)\n", .{});
        const iterations = 1000;

        var world = World.init(allocator);
        defer world.deinit();

        try world.createGroup(struct { Position, Velocity });

        // Create entities
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i), .y = @floatFromInt(i) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
        }

        // Iterate through group multiple times
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const positions = world.getGroupComponentsMut(struct { Position, Velocity }, Position).?;
            const velocities = world.getGroupComponents(struct { Position, Velocity }, Velocity).?;

            for (positions, velocities) |*pos, vel| {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Create group + iterate", iterations, end - start);
    }

    // Benchmark 5: Command buffer (tests inline storage optimization)
    {
        std.debug.print("\nBenchmark 5: Command Buffer (tests inline storage optimization)\n", .{});
        const iterations = 5000;

        var world = World.init(allocator);
        defer world.deinit();

        const system = struct {
            fn spawn(commands: anytype) !void {
                const entity = commands.createEntity();
                try commands.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
                try commands.addComponent(entity, Velocity, .{ .dx = 0.5, .dy = 0.5 });
                try commands.addComponent(entity, Health, .{ .hp = 100 });
            }
        }.spawn;

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            world.beginFrame();
            try world.runSystem(system);
            try world.endFrame();
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Record and flush commands", iterations, end - start);
    }

    // Benchmark 6: Bulk insertion (without reserve)
    {
        std.debug.print("\nBenchmark 6: Bulk Insertion\n", .{});
        const bulk_size = 5000;

        var world = World.init(allocator);
        defer world.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < bulk_size) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
            try world.addComponent(entity, Velocity, .{ .dx = 0.5, .dy = 0.5 });
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Without reserve", bulk_size, end - start);
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

fn printBenchmark(name: []const u8, iterations: usize, elapsed_ns: i128) void {
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const per_iter_us = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;

    std.debug.print("{s}: {d:.2}ms total, {d:.3}µs per iteration ({d} iterations)\n",
        .{ name, elapsed_ms, per_iter_us, iterations });
}
