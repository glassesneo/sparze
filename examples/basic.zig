const std = @import("std");
const sparze = @import("sparze");

// Define some example components
const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Health = struct {
    current: i32,
    max: i32,
};

const Name = struct {
    value: []const u8,
};

// Define a resource
const GameConfig = struct {
    gravity: f32,
    max_entities: u32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var world = sparze.World.init(allocator);
    defer world.deinit();

    std.debug.print("=== Basic ECS Operations Demo ===\n\n", .{});

    // 1. Create entities and attach components
    std.debug.print("1. Creating entities with components...\n", .{});

    const player = try world.createEntityWith(.{
        Position{ .x = 0.0, .y = 0.0 },
        Velocity{ .x = 5.0, .y = 0.0 },
        Health{ .current = 100, .max = 100 },
        Name{ .value = "Player" },
    });
    std.debug.print("   Created player entity: {any}\n", .{player});

    const enemy = try world.createEntity();
    try world.attachComponent(enemy, Position, .{ .x = 10.0, .y = 5.0 });
    try world.attachComponent(enemy, Health, .{ .current = 50, .max = 50 });
    try world.attachComponent(enemy, Name, .{ .value = "Goblin" });
    std.debug.print("   Created enemy entity: {any}\n", .{enemy});

    const projectile = try world.createEntity();
    try world.attachComponents(projectile, .{
        Position{ .x = 1.0, .y = 1.0 },
        Velocity{ .x = 15.0, .y = 0.0 },
    });
    std.debug.print("   Created projectile entity: {any}\n", .{projectile});

    // 2. Add global resources
    std.debug.print("\n2. Adding global resources...\n", .{});
    try world.putResource(GameConfig, .{ .gravity = -9.8, .max_entities = 1000 });
    std.debug.print("   Added game configuration resource\n", .{});

    // 3. Query and display component data
    std.debug.print("\n3. Querying component data...\n", .{});

    if (world.getComponent(player, Position)) |pos| {
        std.debug.print("   Player position: ({d:.1}, {d:.1})\n", .{ pos.x, pos.y });
    }

    if (world.getComponent(player, Health)) |health| {
        std.debug.print("   Player health: {d}/{d}\n", .{ health.current, health.max });
    }

    if (world.getComponent(enemy, Name)) |name| {
        std.debug.print("   Enemy name: {s}\n", .{name.value});
    }

    // 4. Modify components using pointers
    std.debug.print("\n4. Modifying components...\n", .{});

    if (world.getComponentPtr(player, Position)) |pos_ptr| {
        pos_ptr.x += 2.5;
        pos_ptr.y += 1.0;
        std.debug.print("   Moved player to: ({d:.1}, {d:.1})\n", .{ pos_ptr.x, pos_ptr.y });
    }

    if (world.getComponentPtr(enemy, Health)) |health_ptr| {
        health_ptr.current -= 10;
        std.debug.print("   Enemy took damage! Health: {d}/{d}\n", .{ health_ptr.current, health_ptr.max });
    }

    // 5. Check component existence
    std.debug.print("\n5. Component existence checks...\n", .{});
    std.debug.print("   Player has Position: {}\n", .{world.hasComponent(player, Position)});
    std.debug.print("   Player has Velocity: {}\n", .{world.hasComponent(player, Velocity)});
    std.debug.print("   Enemy has Velocity: {}\n", .{world.hasComponent(enemy, Velocity)});
    std.debug.print("   Projectile has Health: {}\n", .{world.hasComponent(projectile, Health)});

    // 6. Access resources
    std.debug.print("\n6. Accessing resources...\n", .{});
    if (world.getResource(GameConfig)) |config| {
        std.debug.print("   Gravity: {d}\n", .{config.gravity});
        std.debug.print("   Max entities: {d}\n", .{config.max_entities});
    }

    // 7. List all entities
    std.debug.print("\n7. All entities in world:\n", .{});
    const all_entities = world.getAllEntities();
    for (all_entities, 0..) |entity, i| {
        std.debug.print("   Entity {d}: {any}\n", .{ i, entity });
    }

    // 8. Remove components
    std.debug.print("\n8. Removing components...\n", .{});
    try world.removeComponent(projectile, Velocity);
    std.debug.print("   Removed Velocity from projectile\n", .{});
    std.debug.print("   Projectile has Velocity: {}\n", .{world.hasComponent(projectile, Velocity)});

    // 9. Destroy entities
    std.debug.print("\n9. Destroying entities...\n", .{});
    try world.destroyEntity(enemy);
    std.debug.print("   Destroyed enemy entity\n", .{});
    std.debug.print("   Enemy still exists: {}\n", .{world.containsEntity(enemy)});

    const remaining_entities = world.getAllEntities();
    std.debug.print("   Remaining entities: {d}\n", .{remaining_entities.len});

    std.debug.print("Basic example completed successfully!\n", .{});
}

