const std = @import("std");
const sparze = @import("sparze");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Armor = struct { value: i32 };

const World = sparze.World(struct { Position, Velocity, Health, Armor }, struct {}, struct {});

const MovementGroup = struct { Position, Velocity };
const CombatGroup = struct { Health, Armor };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔═══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Query vs Group Performance Comparison Benchmark        ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Scenario 1: Single-frame query vs group iteration (no setup)
    try benchmarkSingleFrameQuery(allocator);

    // Scenario 2: Repeated group iteration (with setup cost amortized)
    try benchmarkRepeatedIteration(allocator);

    // Scenario 3: Dynamic vs pre-allocated group queries
    try benchmarkDynamicQuery(allocator);

    // Scenario 4: Multi-query system with Query vs multiple Groups
    try benchmarkMultiQuery(allocator);

    // Scenario 5: Memory access pattern comparison
    try benchmarkMemoryPattern(allocator);

    std.debug.print("\n╔═══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                   Benchmark Summary                           ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ Query:  Flexible, zero setup overhead, moderate iteration     ║\n", .{});
    std.debug.print("║ Group:  Pre-organized, setup cost, optimized iteration        ║\n", .{});
    std.debug.print("║                                                               ║\n", .{});
    std.debug.print("║ Choose Query for:                                             ║\n", .{});
    std.debug.print("║   - One-off queries or varying component combinations         ║\n", .{});
    std.debug.print("║   - When setup cost matters relative to iteration count       ║\n", .{});
    std.debug.print("║   - Mixed tag and regular component queries                   ║\n", .{});
    std.debug.print("║                                                               ║\n", .{});
    std.debug.print("║ Choose Group for:                                             ║\n", .{});
    std.debug.print("║   - Hot-path queries (every frame)                            ║\n", .{});
    std.debug.print("║   - When iteration happens 10+ times per frame                ║\n", .{});
    std.debug.print("║   - Maximum performance-critical sections                     ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════╝\n\n", .{});
}

// Scenario 1: Single-Frame Query (No Setup Cost)
fn benchmarkSingleFrameQuery(allocator: std.mem.Allocator) !void {
    std.debug.print("Scenario 1: Single-Frame Query (No Setup Cost)\n", .{});
    std.debug.print("─────────────────────────────────────────────────\n", .{});

    const entity_count = 10000;
    const iterations = 100;

    // Setup phase for Query benchmark (no group creation)
    {
        var world = World.init(allocator);
        defer world.deinit();

        // Reserve capacity for 10000 entities to avoid reallocation
        try world.getSparseSetPtrMut(Position).reserve(entity_count);
        try world.getSparseSetPtrMut(Velocity).reserve(entity_count);
        try world.getSparseSetPtrMut(Health).reserve(entity_count / 3);
        try world.getSparseSetPtrMut(Armor).reserve(entity_count / 5);

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            if (i % 3 == 0) {
                try world.addComponent(entity, Health, .{ .hp = 100 });
            }
            if (i % 5 == 0) {
                try world.addComponent(entity, Armor, .{ .value = 50 });
            }
        }

        // Benchmark: Query iteration (no setup)
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const query = sparze.Query(struct { Position, Velocity }).init(&world);
            var count: usize = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponent(entity, Position);
                    std.mem.doNotOptimizeAway(&pos);
                    count += 1;
                }
            }
            std.mem.doNotOptimizeAway(&count);
        }
        const query_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Query (no setup)", iterations, query_time);
    }

    // Setup phase for Group benchmark (includes group creation)
    {
        var world = World.init(allocator);
        defer world.deinit();

        // Create group BEFORE entities
        try world.createGroup(MovementGroup);

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            if (i % 3 == 0) {
                try world.addComponent(entity, Health, .{ .hp = 100 });
            }
            if (i % 5 == 0) {
                try world.addComponent(entity, Armor, .{ .value = 50 });
            }
        }

        // Benchmark: Group iteration (setup already done)
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const group = sparze.Group(MovementGroup).init(&world);
            const positions = group.getArrayOf(Position);
            var count: usize = 0;
            for (positions) |_| {
                count += 1;
            }
            std.mem.doNotOptimizeAway(&count);
        }
        const group_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Group (setup done)", iterations, group_time);
    }

    std.debug.print("  → Query: Better for one-off queries\n\n", .{});
}

// Scenario 2: Repeated Iteration (Hot Path)
fn benchmarkRepeatedIteration(allocator: std.mem.Allocator) !void {
    std.debug.print("Scenario 2: Repeated Iteration (Hot Path)\n", .{});
    std.debug.print("────────────────────────────────────────\n", .{});

    const entity_count = 10000;
    const iterations = 1000; // Many iterations to amortize setup cost

    // Benchmark: Query iteration (recreated each time)
    {
        var world = World.init(allocator);
        defer world.deinit();

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
        }

        // Benchmark: Query iteration
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const query = sparze.Query(struct { Position, Velocity }).init(&world);
            var sum: f32 = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponent(entity, Position);
                    sum += pos.x + pos.y;
                }
            }
            std.mem.doNotOptimizeAway(&sum);
        }
        const query_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Query (hot path)", iterations, query_time);
    }

    // Benchmark: Group iteration (pre-organized)
    {
        var world = World.init(allocator);
        defer world.deinit();

        try world.createGroup(MovementGroup);

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
        }

        // Benchmark: Group iteration
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const group = sparze.Group(MovementGroup).init(&world);
            const positions = group.getArrayOf(Position);
            var sum: f32 = 0;
            for (positions) |pos| {
                sum += pos.x + pos.y;
            }
            std.mem.doNotOptimizeAway(&sum);
        }
        const group_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Group (hot path)", iterations, group_time);
    }

    std.debug.print("  → Group: Better for frequently-called systems\n\n", .{});
}

// Scenario 3: Dynamic Query Patterns
fn benchmarkDynamicQuery(allocator: std.mem.Allocator) !void {
    std.debug.print("Scenario 3: Dynamic Query Patterns\n", .{});
    std.debug.print("──────────────────────────────────\n", .{});

    const entity_count = 5000;
    const iterations = 500;

    // Benchmark: Query with varying filters (simulating different query types)
    {
        var world = World.init(allocator);
        defer world.deinit();

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            try world.addComponent(entity, Health, .{ .hp = 100 });
            try world.addComponent(entity, Armor, .{ .value = 50 });
        }

        // Benchmark: Different Query patterns each iteration
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            // Query 1: Position + Velocity
            {
                const query = sparze.Query(struct { Position, Velocity }).init(&world);
                var count: usize = 0;
                for (query.entities) |entity| {
                    if (query.filter(entity)) {
                        count += 1;
                    }
                }
                std.mem.doNotOptimizeAway(&count);
            }

            // Query 2: Health + Armor
            {
                const query = sparze.Query(struct { Health, Armor }).init(&world);
                var count: usize = 0;
                for (query.entities) |entity| {
                    if (query.filter(entity)) {
                        count += 1;
                    }
                }
                std.mem.doNotOptimizeAway(&count);
            }
        }
        const query_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Query (multiple patterns)", iterations * 2, query_time);
    }

    // Benchmark: Multiple pre-organized groups
    {
        var world = World.init(allocator);
        defer world.deinit();

        try world.createGroup(MovementGroup);
        try world.createGroup(CombatGroup);

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            try world.addComponent(entity, Health, .{ .hp = 100 });
            try world.addComponent(entity, Armor, .{ .value = 50 });
        }

        // Benchmark: Use pre-organized groups
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            // Group 1: Movement
            {
                const group = sparze.Group(MovementGroup).init(&world);
                const positions = group.getArrayOf(Position);
                var count: usize = 0;
                for (positions) |_| {
                    count += 1;
                }
                std.mem.doNotOptimizeAway(&count);
            }

            // Group 2: Combat
            {
                const group = sparze.Group(CombatGroup).init(&world);
                const healths = group.getArrayOf(Health);
                var count: usize = 0;
                for (healths) |_| {
                    count += 1;
                }
                std.mem.doNotOptimizeAway(&count);
            }
        }
        const group_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Group (multiple pre-organized)", iterations * 2, group_time);
    }

    std.debug.print("  → Query: Better for ad-hoc or varying query patterns\n\n", .{});
}

// Scenario 4: Multi-Component System
fn benchmarkMultiQuery(allocator: std.mem.Allocator) !void {
    std.debug.print("Scenario 4: Multi-Component System\n", .{});
    std.debug.print("───────────────────────────────────\n", .{});

    const entity_count = 5000;
    const iterations = 500;

    // Benchmark: Single Query for all 4 components
    {
        var world = World.init(allocator);
        defer world.deinit();

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            try world.addComponent(entity, Health, .{ .hp = 100 });
            try world.addComponent(entity, Armor, .{ .value = 50 });
        }

        // Benchmark: Single Query
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const query = sparze.Query(struct { Position, Velocity, Health, Armor }).init(&world);
            var sum: f32 = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponent(entity, Position);
                    sum += pos.x;
                }
            }
            std.mem.doNotOptimizeAway(&sum);
        }
        const query_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Query (4 components)", iterations, query_time);
    }

    // Benchmark: Single Group for all 4 components
    {
        var world = World.init(allocator);
        defer world.deinit();

        const AllGroup = struct { Position, Velocity, Health, Armor };
        try world.createGroup(AllGroup);

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            try world.addComponent(entity, Health, .{ .hp = 100 });
            try world.addComponent(entity, Armor, .{ .value = 50 });
        }

        // Benchmark: Single Group
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const group = sparze.Group(AllGroup).init(&world);
            const positions = group.getArrayOf(Position);
            var sum: f32 = 0;
            for (positions) |pos| {
                sum += pos.x;
            }
            std.mem.doNotOptimizeAway(&sum);
        }
        const group_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Group (4 components)", iterations, group_time);
    }

    std.debug.print("  → Group: Better for complex multi-component systems\n\n", .{});
}

// Scenario 5: Memory Access Pattern Analysis
fn benchmarkMemoryPattern(allocator: std.mem.Allocator) !void {
    std.debug.print("Scenario 5: Memory Access Pattern Analysis\n", .{});
    std.debug.print("──────────────────────────────────────────\n", .{});

    const entity_count = 20000;
    const iterations = 100;

    // Benchmark: Query memory pattern (components may be scattered)
    {
        var world = World.init(allocator);
        defer world.deinit();

        // Create entities with variable composition
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            // Only 50% have Health
            if (i % 2 == 0) {
                try world.addComponent(entity, Health, .{ .hp = 100 });
            }
        }

        // Benchmark: Query iteration with scattered data
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const query = sparze.Query(struct { Position, Velocity }).init(&world);
            var sum: f32 = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponentMut(entity, Position);
                    pos.x += 1.0;
                    sum += pos.x;
                }
            }
            std.mem.doNotOptimizeAway(&sum);
        }
        const query_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Query (scattered)", iterations, query_time);
    }

    // Benchmark: Group memory pattern (components are pre-organized)
    {
        var world = World.init(allocator);
        defer world.deinit();

        try world.createGroup(MovementGroup);

        // Create entities
        var i: usize = 0;
        while (i < entity_count) : (i += 1) {
            const entity = world.createEntity();
            try world.addComponent(entity, Position, .{ .x = @floatFromInt(i % 100), .y = @floatFromInt(i / 100) });
            try world.addComponent(entity, Velocity, .{ .dx = 1.0, .dy = 1.0 });
            // Only 50% have Health (not in group)
            if (i % 2 == 0) {
                try world.addComponent(entity, Health, .{ .hp = 100 });
            }
        }

        // Benchmark: Group iteration with cache-friendly layout
        const start = std.time.nanoTimestamp();
        var j: usize = 0;
        while (j < iterations) : (j += 1) {
            const group = sparze.Group(MovementGroup).init(&world);
            const positions = group.getMutArrayOf(Position);
            var sum: f32 = 0;
            for (positions) |*pos| {
                pos.x += 1.0;
                sum += pos.x;
            }
            std.mem.doNotOptimizeAway(&sum);
        }
        const group_time = std.time.nanoTimestamp() - start;

        printBenchmarkResult("Group (optimized)", iterations, group_time);
    }

    std.debug.print("  → Group: Better cache locality and predictable memory access\n\n", .{});
}

fn printBenchmarkResult(name: []const u8, iterations: usize, elapsed_ns: i128) void {
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const per_iter_us = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;

    std.debug.print("  {s:<30} {d:>10.3}µs per iteration ({d:>6} total iterations, {d:.2}ms)\n", .{ name, per_iter_us, iterations, elapsed_ms });
}

