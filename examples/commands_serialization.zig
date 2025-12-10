const std = @import("std");
const sparze = @import("sparze");

// Components
const Position = struct {
    x: f32,
    y: f32,
};

const Health = struct {
    current: i32,
    max: i32,
};

const Inventory = struct {
    items: [8]u8 = [_]u8{0} ** 8,
    count: usize = 0,

    pub fn addItem(self: *Inventory, item_id: u8) void {
        if (self.count < 8) {
            self.items[self.count] = item_id;
            self.count += 1;
        }
    }
};

// Tags
const Player = struct {};
const Enemy = struct {};

// Resources
const Score = struct {
    points: i32,
    level: i32,
};

const GameTime = struct {
    seconds: f32,
};

// Define World type
const World = sparze.World(
    struct { Position, Health, Inventory, Player, Enemy },
    struct { Score, GameTime },
    struct {},
);

// Define Group for optimization (not serialized, must be recreated after load)
const MovementGroup = struct { Position, Health };

/// Gameplay system that modifies game state
fn gameplaySystem(
    positions: sparze.SingleQuery(Position),
    healths: sparze.SingleQuery(Health),
    score: sparze.ResourceMut(Score),
    time: sparze.ResourceMut(GameTime),
) !void {
    // Update positions
    for (positions.components) |*pos| {
        pos.x += 10.0;
        pos.y += 5.0;
    }

    // Damage all entities
    for (healths.components) |*health| {
        health.current = @max(0, health.current - 5);
    }

    // Update game state
    score.value.points += 100;
    time.value.seconds += 1.0;
}

/// Save game system - saves using Commands API only
fn saveGameSystem(commands: anytype, save_path: []const u8) !void {
    std.debug.print("💾 Saving game via Commands API...\n", .{});
    try commands.serializeToFile(save_path);
    std.debug.print("✅ Game saved to '{s}'\n", .{save_path});
}

/// Load game system - loads using Commands API only
fn loadGameSystem(commands: anytype, save_path: []const u8) !void {
    std.debug.print("📂 Loading game via Commands API...\n", .{});
    try commands.deserializeFromFile(save_path);
    std.debug.print("✅ Game loaded from '{s}'\n", .{save_path});
}

/// Spawn player system
fn spawnPlayerSystem(commands: anytype) !void {
    const player = commands.createEntity();
    try commands.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try commands.addComponent(player, Health, .{ .current = 100, .max = 100 });
    try commands.addComponent(player, Inventory, .{});
    try commands.addTag(player, Player);
}

/// Spawn enemies system
fn spawnEnemiesSystem(commands: anytype) !void {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const enemy = commands.createEntity();
        const x: f32 = @floatFromInt(i * 50);
        try commands.addComponent(enemy, Position, .{ .x = x, .y = 100.0 });
        try commands.addComponent(enemy, Health, .{ .current = 50, .max = 50 });
        try commands.addTag(enemy, Enemy);
    }
}

/// Setup group system (called after world creation)
fn setupGroupSystem(commands: anytype) !void {
    try commands.createGroup(MovementGroup);
    std.debug.print("✅ MovementGroup created for optimized iteration\n", .{});
}

/// Group-based movement system (fast iteration)
fn groupMovementSystem(group: sparze.Group(MovementGroup)) void {
    // Optimize: group provides direct array access, no per-entity queries
    const positions = group.getMutArrayOf(Position);
    const healths = group.getArrayOf(Health);

    // Move all entities with Position+Health efficiently
    for (positions, healths) |*pos, health| {
        // Only move entities with health > 0
        if (health.current > 0) {
            pos.x += 2.0; // Smaller movement for group demo
            pos.y += 1.0;
        }
    }
}

/// Recreate group after deserialization
fn recreateGroupSystem(commands: anytype) !void {
    try commands.createGroup(MovementGroup);
    std.debug.print("✅ MovementGroup recreated after deserialization\n", .{});
}

/// Print game state (enhanced with group info)
fn printGameState(world: *World) !void {
    const positions = world.getSparseSetPtr(Position);
    const healths = world.getSparseSetPtr(Health);
    const inventories = world.getSparseSetPtr(Inventory);
    const players = world.getTagStoragePtr(Player);
    const enemies = world.getTagStoragePtr(Enemy);
    const score = world.getResource(Score);
    const time = world.getResource(GameTime);

    std.debug.print("\n=== Game State ===\n", .{});
    std.debug.print("Entities: {d}\n", .{world.entity_registry.aliveCount()});
    std.debug.print("Score: {d} points (level {d})\n", .{ score.points, score.level });
    std.debug.print("Game time: {d:.1}s\n", .{time.seconds});
    std.debug.print("Positions: {d}\n", .{positions.packed_array.items.len});
    std.debug.print("Health components: {d}\n", .{healths.packed_array.items.len});
    std.debug.print("Inventories: {d}\n", .{inventories.packed_array.items.len});
    std.debug.print("Players: {d}\n", .{players.packed_array.items.len});
    std.debug.print("Enemies: {d}\n", .{enemies.packed_array.items.len});

    // Show group membership
    if (world.getGroup(MovementGroup) != null) {
        const group_entities = world.getGroupEntities(MovementGroup).?;
        const group_positions = world.getGroupComponents(MovementGroup, Position).?;
        const group_healths = world.getGroupComponents(MovementGroup, Health).?;
        std.debug.print("MovementGroup: {d} entities (Position+Health)\n", .{group_entities.len});
        if (group_positions.len > 0) {
            std.debug.print("  - First group position: ({d:.1}, {d:.1})\n", .{ group_positions[0].x, group_positions[0].y });
        }
        if (group_healths.len > 0) {
            std.debug.print("  - First group health: {d}/{d}\n", .{ group_healths[0].current, group_healths[0].max });
        }
    } else {
        std.debug.print("MovementGroup: Not created\n", .{});
    }

    // Print first position if exists
    if (positions.packed_array.items.len > 0) {
        const first_entity = positions.packed_array.items[0];
        const pos = positions.get(first_entity).?;
        std.debug.print("First entity position: ({d:.1}, {d:.1})\n", .{ pos.x, pos.y });
    }

    // Print first health if exists
    if (healths.packed_array.items.len > 0) {
        const first_entity = healths.packed_array.items[0];
        const health = healths.get(first_entity).?;
        std.debug.print("First entity health: {d}/{d}\n", .{ health.current, health.max });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎮 Sparze Commands Serialization Example\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Create world
    var world = World.init(allocator);
    defer world.deinit();

    // Initialize resources
    world.setResource(Score, .{ .points = 0, .level = 1 });
    world.setResource(GameTime, .{ .seconds = 0.0 });

    const save_path = "examples/commands_save.spze";

    // Phase 1: Initial game setup
    std.debug.print("📦 Phase 1: Initial Setup\n", .{});
    std.debug.print("-------------------------\n", .{});

    try world.runSystem(spawnPlayerSystem);
    try world.runSystem(spawnEnemiesSystem);
    try world.endFrame(); // Flush commands

    // Setup group for optimized iteration
    try world.runSystem(setupGroupSystem);
    try world.endFrame(); // Flush commands

    // Give player some items
    {
        const inventories = world.getSparseSetPtrMut(Inventory);
        const entities = inventories.packed_array.items;
        if (entities.len > 0) {
            const inv = inventories.getPtrMut(entities[0]).?;
            inv.addItem(1); // Sword
            inv.addItem(2); // Shield
            inv.addItem(3); // Potion
        }
    }

    try printGameState(&world);

    // Phase 2: Run gameplay (using Group for optimization)
    std.debug.print("\n⚔️  Phase 2: Run Gameplay (with Group)\n", .{});
    std.debug.print("------------------------------------\n", .{});

    try world.runSystem(groupMovementSystem);
    try world.endFrame();

    try printGameState(&world);

    // Phase 3: Save game using Commands
    std.debug.print("\n💾 Phase 3: Save Game\n", .{});
    std.debug.print("-------------------------\n", .{});

    // Create a system that saves the game
    const SaveSystem = struct {
        fn save(commands: anytype) !void {
            try saveGameSystem(commands, save_path);
        }
    };

    try world.runSystem(SaveSystem.save);
    try world.endFrame();

    // Phase 4: Continue gameplay (more modifications)
    std.debug.print("\n⚔️  Phase 4: Continue Gameplay (with Group)\n", .{});
    std.debug.print("---------------------------------------\n", .{});

    try world.runSystem(groupMovementSystem);
    try world.runSystem(groupMovementSystem); // Run twice to make significant changes
    try world.endFrame();

    // Modify score significantly
    {
        const score = world.getResourcePtrMut(Score);
        score.points += 500;
        score.level = 5;
    }

    try printGameState(&world);

    // Phase 5: Load saved game using Commands
    std.debug.print("\n📂 Phase 5: Load Saved Game\n", .{});
    std.debug.print("-------------------------\n", .{});

    // Create a system that loads the game
    const LoadSystem = struct {
        fn load(commands: anytype) !void {
            try loadGameSystem(commands, save_path);
        }
    };

    try world.runSystem(LoadSystem.load);
    try world.endFrame();

    // Recreate group after deserialization (groups are not serialized)
    try world.runSystem(recreateGroupSystem);
    try world.endFrame();

    try printGameState(&world);

    // Phase 6: Verification
    std.debug.print("\n🔍 Phase 6: Verification\n", .{});
    std.debug.print("-------------------------\n", .{});

    const score = world.getResource(Score);
    const time = world.getResource(GameTime);
    const positions = world.getSparseSetPtr(Position);
    const healths = world.getSparseSetPtr(Health);
    const inventories = world.getSparseSetPtr(Inventory);

    // Verify game state matches saved state
    std.debug.print("Checking saved state...\n", .{});

    if (score.points == 100) {
        std.debug.print("✅ Score restored correctly (100 points)\n", .{});
    } else {
        std.debug.print("❌ Score mismatch! Expected 100, got {d}\n", .{score.points});
    }

    if (score.level == 1) {
        std.debug.print("✅ Level restored correctly (level 1)\n", .{});
    } else {
        std.debug.print("❌ Level mismatch! Expected 1, got {d}\n", .{score.level});
    }

    if (time.seconds > 0.9 and time.seconds < 1.1) {
        std.debug.print("✅ Game time restored correctly (~1.0s)\n", .{});
    } else {
        std.debug.print("❌ Time mismatch! Expected ~1.0, got {d:.1}\n", .{time.seconds});
    }

    if (positions.packed_array.items.len == 4) {
        std.debug.print("✅ Position count correct (4 entities)\n", .{});
    } else {
        std.debug.print("❌ Position count mismatch! Expected 4, got {d}\n", .{positions.packed_array.items.len});
    }

    if (healths.packed_array.items.len == 4) {
        std.debug.print("✅ Health count correct (4 entities)\n", .{});
    } else {
        std.debug.print("❌ Health count mismatch! Expected 4, got {d}\n", .{healths.packed_array.items.len});
    }

    if (inventories.packed_array.items.len == 1) {
        std.debug.print("✅ Inventory count correct (1 player)\n", .{});
    } else {
        std.debug.print("❌ Inventory count mismatch! Expected 1, got {d}\n", .{inventories.packed_array.items.len});
    }

    // Verify first position
    if (positions.packed_array.items.len > 0) {
        const first_entity = positions.packed_array.items[0];
        const pos = positions.get(first_entity).?;
        if (pos.x > 9.0 and pos.x < 11.0 and pos.y > 4.0 and pos.y < 6.0) {
            std.debug.print("✅ First position restored correctly (~10, ~5)\n", .{});
        } else {
            std.debug.print("❌ Position mismatch! Expected (~10, ~5), got ({d:.1}, {d:.1})\n", .{ pos.x, pos.y });
        }
    }

    // Verify inventory items
    if (inventories.packed_array.items.len > 0) {
        const entities = inventories.packed_array.items;
        const inv = inventories.get(entities[0]).?;
        if (inv.count == 3 and inv.items[0] == 1 and inv.items[1] == 2 and inv.items[2] == 3) {
            std.debug.print("✅ Inventory items restored correctly (3 items)\n", .{});
        } else {
            std.debug.print("❌ Inventory mismatch! Expected 3 items, got {d}\n", .{inv.count});
        }
    }

    std.debug.print("\n✨ Commands serialization example completed!\n", .{});
    std.debug.print("\nKey Points:\n", .{});
    std.debug.print("- All save/load operations done via Commands API\n", .{});
    std.debug.print("- No direct world.serialize() or world.deserialize() calls\n", .{});
    std.debug.print("- Systems only receive Commands parameter (anytype)\n", .{});
    std.debug.print("- Perfect for architectures where World is abstracted away\n", .{});
}
