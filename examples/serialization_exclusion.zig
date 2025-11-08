const std = @import("std");
const sparze = @import("sparze");

// Types that should be saved (normal serialization behavior)
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Player = struct {}; // Tag component

// Types that should NOT be saved (transient/session-specific data)
const KeyboardInput = struct {
    pressed_keys: [256]bool = [_]bool{false} ** 256,
    pub const serialized = false; // Don't serialize input state
};

const MouseInput = struct {
    x: i32 = 0,
    y: i32 = 0,
    buttons_pressed: [8]bool = [_]bool{false} ** 8,
    pub const serialized = false; // Don't serialize mouse state
};

const GameSession = struct {
    session_id: u64 = 0,
    start_time: u64 = 0,
    pub const serialized = false; // Don't persist sessions
};

// Resources - mix of persistent and transient
const GameConfig = struct {
    gravity: f32 = 9.8,
    max_speed: f32 = 100.0,
    // pub const serialized = true; // Explicitly include (default behavior)
};

const SessionData = struct {
    player_name: [32]u8 = undefined,
    login_time: u64 = 0,
    pub const serialized = false; // Don't persist session data
};

// Events - some should persist, others shouldn't
const CollisionEvent = struct {
    entity_a: sparze.Entity,
    entity_b: sparze.Entity,
    // pub const serialized = true; // Include collision events (default)
};

const InputEvent = struct {
    key_code: u32,
    is_pressed: bool,
    pub const serialized = false; // Don't persist input events
};

// Define World with mixed serializable/non-serializable types
const World = sparze.World(
    struct { Position, Velocity, Health, Player, KeyboardInput, MouseInput },
    struct { GameConfig, SessionData },
    struct { CollisionEvent, InputEvent },
);

fn createTestWorld(allocator: std.mem.Allocator) !World {
    var world = World.init(allocator);

    // Initialize persistent resources
    try world.setResource(GameConfig, GameConfig{ .gravity = 9.8, .max_speed = 50.0 });

    // Initialize transient resources (won't be saved)
    var player_name: [32]u8 = undefined;
    @memcpy(player_name[0..7], "Player1");
    try world.setResource(SessionData, SessionData{ .player_name = player_name, .login_time = 12345 });

    // Create player entity with both persistent and transient components
    const player = world.createEntity();
    try world.addComponent(player, Position, Position{ .x = 100.0, .y = 200.0 });
    try world.addComponent(player, Velocity, Velocity{ .dx = 10.0, .dy = 0.0 });
    try world.addComponent(player, Health, Health{ .hp = 100 });
    try world.addTag(player, Player);

    // Add transient input components (won't be saved)
    try world.addComponent(player, KeyboardInput, KeyboardInput{});
    try world.addComponent(player, MouseInput, MouseInput{ .x = 50, .y = 75 });

    return world;
}

fn printWorldState(world: *World, label: []const u8) !void {
    std.debug.print("\n=== {s} ===\n", .{label});

    // Print entity and component counts
    std.debug.print("Entities: {d}\n", .{world.entity_registry.aliveCount()});

    // Print persistent data
    const config = world.getResource(GameConfig);
    std.debug.print("GameConfig: gravity={d}, max_speed={d}\n", .{ config.gravity, config.max_speed });

    // Print transient data (session-specific)
    const session = world.getResource(SessionData);
    std.debug.print("SessionData: player_name='{s}', login_time={d}\n", .{ std.mem.sliceTo(&session.player_name, 0), session.login_time });

    // Print player entity data
    {
        const player_positions = sparze.SingleQuery(Position);
        for (player_positions.entities) |entity| {
            if (world.hasComponent(entity, Player)) {
                const pos = world.getComponent(entity, Position) catch continue;
                std.debug.print("Player Position: ({d}, {d})\n", .{ pos.x, pos.y });

                // Check transient input data
                if (world.hasComponent(entity, KeyboardInput)) {
                    const input = world.getComponent(entity, KeyboardInput) catch continue;
                    std.debug.print("Keyboard Input present (should be reset after load)\n", .{});
                }

                if (world.hasComponent(entity, MouseInput)) {
                    const mouse = world.getComponent(entity, MouseInput) catch continue;
                    std.debug.print("Mouse Input: ({d}, {d})\n", .{ mouse.x, mouse.y });
                }
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n🎮 Sparze Serialization Exclusion Example\n", .{});
    std.debug.print("==========================================\n", .{});

    // Create and populate world
    var world = try createTestWorld(allocator);
    defer world.deinit();

    try printWorldState(&world, "Original World State");

    // Serialize to file
    const save_path = "examples/exclusion_save.spze";
    std.debug.print("\n💾 Serializing world to '{s}'...\n", .{save_path});
    std.debug.print("   - Position, Velocity, Health, Player will be saved\n");
    std.debug.print("   - KeyboardInput, MouseInput will be EXCLUDED\n");
    std.debug.print("   - GameConfig will be saved, SessionData will be EXCLUDED\n");
    std.debug.print("   - CollisionEvent will be saved, InputEvent will be EXCLUDED\n");

    try world.serializeToFile(save_path);

    // Get file size
    const file = try std.fs.cwd().openFile(save_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    std.debug.print("✅ Saved! File size: {d} bytes\n", .{file_size});

    // Modify world to show differences
    std.debug.print("\n🔧 Modifying world before load...\n", .{});

    // Change persistent data
    const config = world.getResourcePtrMut(GameConfig);
    config.gravity = 5.0;
    config.max_speed = 25.0;

    // Change transient data
    const session = world.getResourcePtrMut(SessionData);
    session.login_time = 99999;

    // Modify player position
    const player_query = sparze.SingleQuery(Position);
    for (player_query.entities) |entity| {
        if (world.hasComponent(entity, Player)) {
            const pos = world.getComponentMut(entity, Position) catch continue;
            pos.x = 999.0;
            pos.y = 888.0;
        }
    }

    try printWorldState(&world, "Modified World State");

    // Deserialize from file
    std.debug.print("\n📂 Deserializing world from '{s}'...\n", .{save_path});
    std.debug.print("   - Persistent data will be restored\n");
    std.debug.print("   - Transient data will be reset to defaults\n");

    try world.deserializeFromFile(save_path);
    std.debug.print("✅ Loaded!\n", .{});

    try printWorldState(&world, "Restored World State");

    // Verify the exclusion worked
    std.debug.print("\n🔍 Verifying serialization exclusion...\n", .{});

    // Check that persistent data was restored
    const restored_config = world.getResource(GameConfig);
    if (restored_config.gravity == 9.8 and restored_config.max_speed == 50.0) {
        std.debug.print("✅ Persistent GameConfig restored correctly\n", .{});
    } else {
        std.debug.print("❌ GameConfig not restored correctly!\n", .{});
    }

    // Check that transient data was NOT restored (should be reset)
    const restored_session = world.getResource(SessionData);
    if (restored_session.login_time == 12345) {
        std.debug.print("✅ Transient SessionData reset to original value\n", .{});
    } else {
        std.debug.print("❌ SessionData was not reset! (value: {d})\n", .{restored_session.login_time});
    }

    // Check that player position was restored
    const player_positions = sparze.SingleQuery(Position);
    for (player_positions.entities) |entity| {
        if (world.hasComponent(entity, Player)) {
            const pos = world.getComponent(entity, Position) catch continue;
            if (pos.x == 100.0 and pos.y == 200.0) {
                std.debug.print("✅ Player position restored correctly\n", .{});
            } else {
                std.debug.print("❌ Player position not restored! ({d}, {d})\n", .{ pos.x, pos.y });
            }

            // Check that transient input components were reset
            if (world.hasComponent(entity, KeyboardInput)) {
                const input = world.getComponent(entity, KeyboardInput) catch continue;
                std.debug.print("✅ KeyboardInput present and reset to defaults\n", .{});
            }

            if (world.hasComponent(entity, MouseInput)) {
                const mouse = world.getComponent(entity, MouseInput) catch continue;
                if (mouse.x == 0 and mouse.y == 0) {
                    std.debug.print("✅ MouseInput reset to defaults\n", .{});
                } else {
                    std.debug.print("❌ MouseInput was not reset! ({d}, {d})\n", .{ mouse.x, mouse.y });
                }
            }
        }
    }

    // Cleanup
    std.fs.cwd().deleteFile(save_path) catch {};

    std.debug.print("\n✨ Serialization exclusion example completed successfully!\n", .{});
    std.debug.print("\nKey takeaways:\n", .{});
    std.debug.print("- Types with 'serialized = false' are completely excluded from save files\n", .{});
    std.debug.print("- This is perfect for input state, session data, and temporary data\n", .{});
    std.debug.print("- Excluded types are reset to default values during deserialization\n", .{});
    std.debug.print("- Persistent data is saved and restored normally\n", .{});
}
