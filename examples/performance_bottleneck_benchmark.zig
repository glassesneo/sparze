const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Armor = struct { value: i32 };
const Radius = struct { value: f32 };
const Projectile = struct {};
const Enemy = struct {};

const World = sparze.World(struct { Position, Velocity, Health, Armor, Radius, Projectile, Enemy }, struct {}, struct {});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Sparze Performance Bottleneck Benchmark ===\n\n", .{});

    // Benchmark 1: SparseSet insert - component replacement (double lookup issue)
    {
        std.debug.print("Benchmark 1: SparseSet Component Replacement\n", .{});
        const iterations = 10000;

        var world = World.init(allocator);
        defer world.deinit();

        // Create entities with initial components
        var entities: [1000]sparze.Entity = undefined;
        for (&entities) |*entity| {
            entity.* = world.createEntity();
            try world.addComponent(entity.*, Position, .{ .x = 1.0, .y = 2.0 });
            try world.addComponent(entity.*, Velocity, .{ .dx = 0.5, .dy = 0.5 });
        }

        // Benchmark: repeatedly replace components (triggers double lookup in insert)
        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const entity = entities[i % entities.len];
            try world.addComponent(entity, Position, .{ .x = 2.0, .y = 3.0 });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Replace existing components", iterations, end - start);
    }

    // Benchmark 2: CombinationIterator - various entity counts
    {
        std.debug.print("\nBenchmark 2: CombinationIterator (double filter call overhead)\n", .{});

        const entity_counts = [_]usize{ 100, 500, 1000 };

        for (entity_counts) |entity_count| {
            var world = World.init(allocator);
            defer world.deinit();

            // Create entities with components
            var i: usize = 0;
            while (i < entity_count) : (i += 1) {
                const entity = world.createEntity();
                try world.addComponent(entity, Position, .{ .x = @floatFromInt(i), .y = @floatFromInt(i) });
                try world.addComponent(entity, Radius, .{ .value = 10.0 });
            }

            // Benchmark: iterate all unique pairs
            const CollisionSystem = struct {
                fn run(query: sparze.Query(struct { Position, Radius })) !void {
                    var iter = query.combinations();
                    var pair_count: usize = 0;

                    while (iter.next()) |pair| {
                        const entity_a, const entity_b = pair;
                        const pos_a = query.getComponent(entity_a, Position);
                        const pos_b = query.getComponent(entity_b, Position);
                        const radius_a = query.getComponent(entity_a, Radius);
                        const radius_b = query.getComponent(entity_b, Radius);

                        // Simple collision check
                        const dx = pos_b.x - pos_a.x;
                        const dy = pos_b.y - pos_a.y;
                        const dist_sq = dx * dx + dy * dy;
                        const radius_sum = radius_a.value + radius_b.value;
                        _ = dist_sq < radius_sum * radius_sum;
                        pair_count += 1;
                    }
                    std.mem.doNotOptimizeAway(&pair_count);
                }
            }.run;

            const start = std.time.nanoTimestamp();
            try world.runSystem(CollisionSystem);
            const end = std.time.nanoTimestamp();

            const expected_pairs = entity_count * (entity_count - 1) / 2;
            const elapsed_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
            std.debug.print("  {d} entities ({d} pairs): {d:.2}ms total\n", .{ entity_count, expected_pairs, elapsed_ms });
        }
    }

    // Benchmark 3: CrossProductIterator - projectiles vs enemies
    {
        std.debug.print("\nBenchmark 3: CrossProductIterator (N×M filter overhead)\n", .{});

        const scenarios = [_]struct { projectiles: usize, enemies: usize }{
            .{ .projectiles = 50, .enemies = 200 },
            .{ .projectiles = 100, .enemies = 500 },
            .{ .projectiles = 200, .enemies = 1000 },
        };

        for (scenarios) |scenario| {
            var world = World.init(allocator);
            defer world.deinit();

            // Create projectile entities
            var i: usize = 0;
            while (i < scenario.projectiles) : (i += 1) {
                const entity = world.createEntity();
                try world.addComponent(entity, Projectile, .{});
                try world.addComponent(entity, Position, .{ .x = @floatFromInt(i), .y = 0.0 });
                try world.addComponent(entity, Radius, .{ .value = 5.0 });
            }

            // Create enemy entities
            i = 0;
            while (i < scenario.enemies) : (i += 1) {
                const entity = world.createEntity();
                try world.addComponent(entity, Enemy, .{});
                try world.addComponent(entity, Position, .{ .x = @floatFromInt(i), .y = 100.0 });
                try world.addComponent(entity, Radius, .{ .value = 15.0 });
            }

            // Benchmark: cross product collision detection
            const CollisionSystem = struct {
                fn run(
                    projectiles: sparze.Query(struct { Projectile, Position, Radius }),
                    enemies: sparze.Query(struct { Enemy, Position, Radius }),
                ) !void {
                    var cross = projectiles.crossProduct(&enemies);
                    var collision_count: usize = 0;

                    while (cross.next()) |pair| {
                        const proj_entity, const enemy_entity = pair;
                        const proj_pos = projectiles.getComponent(proj_entity, Position);
                        const proj_radius = projectiles.getComponent(proj_entity, Radius);
                        const enemy_pos = enemies.getComponent(enemy_entity, Position);
                        const enemy_radius = enemies.getComponent(enemy_entity, Radius);

                        // Collision check
                        const dx = proj_pos.x - enemy_pos.x;
                        const dy = proj_pos.y - enemy_pos.y;
                        const dist_sq = dx * dx + dy * dy;
                        const radius_sum = proj_radius.value + enemy_radius.value;

                        if (dist_sq < radius_sum * radius_sum) {
                            collision_count += 1;
                        }
                    }
                    std.mem.doNotOptimizeAway(&collision_count);
                }
            }.run;

            const start = std.time.nanoTimestamp();
            try world.runSystem(CollisionSystem);
            const end = std.time.nanoTimestamp();

            const total_checks = scenario.projectiles * scenario.enemies;
            const elapsed_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
            std.debug.print("  {d} projectiles × {d} enemies = {d} checks: {d:.2}ms total\n", .{ scenario.projectiles, scenario.enemies, total_checks, elapsed_ms });
        }
    }

    // Benchmark 4: Command buffer flush - mixed operations
    {
        std.debug.print("\nBenchmark 4: Command Buffer Flush (mixed operation types)\n", .{});
        const iterations = 1000;

        var world = World.init(allocator);
        defer world.deinit();

        // System that performs mixed operations
        const MixedOpsSystem = struct {
            fn run(commands: anytype) !void {
                // Create entities
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    const entity = commands.createEntity();
                    try commands.addComponent(entity, Position, .{ .x = 1.0, .y = 2.0 });
                }

                // Add components to existing entities (requires entity list, simplified here)
                i = 0;
                while (i < 3) : (i += 1) {
                    const entity = commands.createEntity();
                    try commands.addComponent(entity, Velocity, .{ .dx = 0.5, .dy = 0.5 });
                    try commands.addComponent(entity, Health, .{ .hp = 100 });
                }

                // Remove components (simplified - would need entity tracking)
                i = 0;
                while (i < 2) : (i += 1) {
                    const entity = commands.createEntity();
                    try commands.addComponent(entity, Position, .{ .x = 1.0, .y = 1.0 });
                }

                // Destroy entities (simplified)
                const entity = commands.createEntity();
                try commands.destroyEntity(entity);
            }
        }.run;

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            world.beginFrame();
            try world.runSystem(MixedOpsSystem);
            try world.endFrame();
        }
        const end = std.time.nanoTimestamp();
        printBenchmark("  Mixed command types flush", iterations, end - start);
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

fn printBenchmark(name: []const u8, iterations: usize, elapsed_ns: i128) void {
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const per_iter_us = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;

    std.debug.print("{s}: {d:.2}ms total, {d:.3}µs per iteration ({d} iterations)\n", .{ name, elapsed_ms, per_iter_us, iterations });
}
