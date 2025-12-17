// serialization_and_replay.zig - Serialization and Replay
//
// Demonstrates:
// - Saving world state to binary format (.spze)
// - Loading world state back
// - POD vs custom serialization
// - Excluding components from serialization
// - Integrity validation (CRC32 checksums, type hashing)
//
// Key concepts:
// - POD types (Plain Old Data) are auto-serialized via memcpy
// - Non-POD types require a custom Serializer
// - Components can opt-out via `pub const serialized = false`
// - Groups must be recreated after deserialization

const std = @import("std");
const sparze = @import("sparze");

const print = std.debug.print;

// =============================================================================
// Component Definitions
// =============================================================================

/// POD component - automatically serialized via memcpy
/// All fields are primitive types, so it's automatically detected as POD
const Position = struct {
    x: f32,
    y: f32,
};

/// POD component - nested POD structs are also automatically handled
const Velocity = struct {
    dx: f32,
    dy: f32,
};

/// POD component with array field
const Health = struct {
    current: i32,
    max: i32,
    history: [4]i32 = .{ 0, 0, 0, 0 }, // Recent damage history (POD array)
};

/// Non-POD component with CUSTOM SERIALIZER
/// We demonstrate custom serialization here even though this could be POD
const Name = struct {
    buffer: [32]u8 = undefined,
    len: u8 = 0, // Using u8 instead of usize for simplicity

    pub fn init(str: []const u8) Name {
        var name = Name{};
        const copy_len: u8 = @intCast(@min(str.len, name.buffer.len));
        @memcpy(name.buffer[0..copy_len], str[0..copy_len]);
        name.len = copy_len;
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Custom serializer for Name - demonstrates the pattern even for POD types
    pub const Serializer = struct {
        pub fn serialize(name: Name, writer: anytype) !void {
            // Write length as u8
            try writer.writeInt(u8, name.len, .little);
            // Write actual string data (only used bytes)
            try writer.writeAll(name.buffer[0..name.len]);
        }

        pub fn deserialize(reader: anytype) !Name {
            var name = Name{};
            // Read length using compat helper for Zig 0.15 API
            name.len = try sparze.serialization.compat.readInt(reader, u8, .little);
            // Read string data
            var buf: [32]u8 = undefined;
            try reader.readSliceAll(buf[0..name.len]);
            @memcpy(name.buffer[0..name.len], buf[0..name.len]);
            return name;
        }
    };
};

/// Component that opts OUT of serialization
/// Use for runtime-only state (e.g., render handles, frame counters)
const RuntimeState = struct {
    frame_count: u32 = 0,
    is_visible: bool = true,

    /// This component will NOT be saved or loaded
    pub const serialized = false;
};

/// Tag component (zero-sized) - uses bitset serialization
const Player = struct {};
const Enemy = struct {};

// =============================================================================
// Resource Definitions
// =============================================================================

/// POD resource - automatically serialized
const GameConfig = struct {
    difficulty: u8 = 1,
    max_enemies: u32 = 100,
    spawn_rate: f32 = 1.0,
};

/// Resource with custom serializer
const GameState = struct {
    level: u32 = 1,
    score: u64 = 0,
    time_played: f64 = 0.0,

    pub const Serializer = struct {
        pub fn serialize(state: GameState, writer: anytype) !void {
            try writer.writeInt(u32, state.level, .little);
            try writer.writeInt(u64, state.score, .little);
            // Serialize f64 as raw bytes
            const time_bytes = std.mem.asBytes(&state.time_played);
            try writer.writeAll(time_bytes);
        }

        pub fn deserialize(reader: anytype) !GameState {
            var state = GameState{};
            state.level = try sparze.serialization.compat.readInt(reader, u32, .little);
            state.score = try sparze.serialization.compat.readInt(reader, u64, .little);
            var time_bytes: [8]u8 = undefined;
            try reader.readSliceAll(&time_bytes);
            state.time_played = std.mem.bytesToValue(f64, &time_bytes);
            return state;
        }
    };
};

// =============================================================================
// Event Definitions
// =============================================================================

/// Events in the read buffer are serialized (events from previous frame)
const DamageEvent = struct {
    target: sparze.Entity,
    amount: i32,
};

// =============================================================================
// World Type Definition
// =============================================================================

const World = sparze.World(
    // Components
    .{
        Position,
        Velocity,
        Health,
        Name,
        RuntimeState,
        Player,
        Enemy,
    },
    // Resources
    .{
        GameConfig,
        GameState,
    },
    // Events
    .{
        DamageEvent,
    },
    // Groups
    .{},
);

// =============================================================================
// Helper Functions
// =============================================================================

fn printWorldState(world: *World, label: []const u8) void {
    print("\n--- {s} ---\n", .{label});

    // Print entities with Position using direct component storage access
    const pos_storage = world.getComponentStoragePtr(Position);
    for (pos_storage.packed_array.items, pos_storage.components.items) |entity, pos| {
        // Get optional name
        const name_opt = world.getComponent(entity, Name);

        // Check tags (tags are zero-sized components, so use hasComponent)
        const is_player = world.hasComponent(entity, Player);
        const is_enemy = world.hasComponent(entity, Enemy);
        const tag = if (is_player) "Player" else if (is_enemy) "Enemy" else "Entity";

        if (name_opt) |name| {
            print("  {s} {any}: \"{s}\" at ({d:.1}, {d:.1})\n", .{ tag, entity, name.slice(), pos.x, pos.y });
        } else {
            print("  {s} {any}: at ({d:.1}, {d:.1})\n", .{ tag, entity, pos.x, pos.y });
        }
    }

    // Print resources
    const config = world.getResource(GameConfig);
    const state = world.getResource(GameState);
    print("  Resources: difficulty={d}, level={d}, score={d}\n", .{ config.difficulty, state.level, state.score });
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Sparze ECS: Serialization and Replay ===\n", .{});

    // -------------------------------------------------------------------------
    // Phase 1: Create and populate world
    // -------------------------------------------------------------------------
    print("\n--- Phase 1: Creating world ---\n", .{});

    var world = World.init(allocator);
    defer world.deinit();

    // Initialize resources
    try world.initResources(.{
        .GameConfig = GameConfig{ .difficulty = 2, .max_enemies = 50, .spawn_rate = 1.5 },
        .GameState = GameState{ .level = 3, .score = 12500, .time_played = 542.7 },
    });

    // Create player entity
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 100.0, .y = 200.0 });
    try world.addComponent(player, Velocity, .{ .dx = 5.0, .dy = 0.0 });
    try world.addComponent(player, Health, .{ .current = 80, .max = 100, .history = .{ -10, -5, -5, 0 } });
    try world.addComponent(player, Name, Name.init("Hero"));
    try world.addComponent(player, RuntimeState, .{ .frame_count = 1000, .is_visible = true });
    try world.addTag(player, Player);
    print("  Created player: {any}\n", .{player});

    // Create enemy entities
    const enemy1 = world.createEntity();
    try world.addComponent(enemy1, Position, .{ .x = 300.0, .y = 150.0 });
    try world.addComponent(enemy1, Velocity, .{ .dx = -2.0, .dy = 1.0 });
    try world.addComponent(enemy1, Health, .{ .current = 50, .max = 50 });
    try world.addComponent(enemy1, Name, Name.init("Goblin"));
    try world.addTag(enemy1, Enemy);
    print("  Created enemy1: {any}\n", .{enemy1});

    const enemy2 = world.createEntity();
    try world.addComponent(enemy2, Position, .{ .x = 400.0, .y = 250.0 });
    try world.addComponent(enemy2, Health, .{ .current = 100, .max = 100 });
    try world.addTag(enemy2, Enemy);
    print("  Created enemy2 (no name): {any}\n", .{enemy2});

    // Add some events to the write buffer, then swap to read buffer
    world.beginFrame();
    const event_storage = world.getEventStoragePtrMut(DamageEvent);
    try event_storage.enqueue(.{ .target = player, .amount = 10 });
    try event_storage.enqueue(.{ .target = enemy1, .amount = 25 });
    try world.endFrame(); // Events now in read buffer

    printWorldState(&world, "Original World State");

    // -------------------------------------------------------------------------
    // Phase 2: Serialize world to memory buffer
    // -------------------------------------------------------------------------
    print("\n--- Phase 2: Serializing world ---\n", .{});

    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    // Serialize world to buffer using World's built-in method
    try world.serialize(buffer.writer(allocator));

    print("  Serialized {d} bytes\n", .{buffer.items.len});
    print("  Header: magic=\"{s}\"\n", .{buffer.items[0..4]});

    // -------------------------------------------------------------------------
    // Phase 3: Create new world and deserialize
    // -------------------------------------------------------------------------
    print("\n--- Phase 3: Deserializing into new world ---\n", .{});

    var world2 = World.init(allocator);
    defer world2.deinit();

    // Initialize resources first (required before deserialize)
    try world2.initResources(.{
        .GameConfig = GameConfig{},
        .GameState = GameState{},
    });

    // Deserialize from buffer using World's built-in method
    var fbs = std.io.fixedBufferStream(buffer.items);
    try world2.deserialize(fbs.reader());

    print("  Deserialization complete!\n", .{});
    printWorldState(&world2, "Loaded World State");

    // -------------------------------------------------------------------------
    // Phase 4: Verify deserialized state
    // -------------------------------------------------------------------------
    print("\n--- Phase 4: Verifying state ---\n", .{});

    // Verify player position
    const loaded_pos = world2.getComponent(player, Position);
    if (loaded_pos) |pos| {
        const matches = pos.x == 100.0 and pos.y == 200.0;
        print("  Player position: ({d:.1}, {d:.1}) - {s}\n", .{
            pos.x,
            pos.y,
            if (matches) "MATCH" else "MISMATCH",
        });
    }

    // Verify player name (custom serializer)
    const loaded_name = world2.getComponent(player, Name);
    if (loaded_name) |name| {
        const matches = std.mem.eql(u8, name.slice(), "Hero");
        print("  Player name: \"{s}\" - {s}\n", .{
            name.slice(),
            if (matches) "MATCH" else "MISMATCH",
        });
    }

    // Verify RuntimeState was NOT loaded (opted out)
    const loaded_runtime = world2.getComponent(player, RuntimeState);
    print("  RuntimeState: {s} (expected: null due to serialized=false)\n", .{
        if (loaded_runtime == null) "null" else "present",
    });

    // Verify resources
    const loaded_config = world2.getResource(GameConfig);
    const loaded_state = world2.getResource(GameState);
    print("  GameConfig.difficulty: {d} (expected: 2)\n", .{loaded_config.difficulty});
    print("  GameState.level: {d} (expected: 3)\n", .{loaded_state.level});
    print("  GameState.score: {d} (expected: 12500)\n", .{loaded_state.score});

    // Verify events in read buffer
    const event_storage2 = world2.getEventStoragePtr(DamageEvent);
    var event_count: usize = 0;
    for (event_storage2.read_buffer.items) |event| {
        print("  Event: target={any}, amount={d}\n", .{ event.target, event.amount });
        event_count += 1;
    }
    print("  Total events loaded: {d} (expected: 2)\n", .{event_count});

    // Verify tags
    const has_player_tag = world2.hasComponent(player, Player);
    const has_enemy_tag = world2.hasComponent(enemy1, Enemy);
    print("  Player tag: {s}\n", .{if (has_player_tag) "present" else "missing"});
    print("  Enemy1 tag: {s}\n", .{if (has_enemy_tag) "present" else "missing"});

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------
    print("\n=== Key Takeaways ===\n", .{});
    print("1. POD types (Position, Velocity, Health) auto-serialize via memcpy\n", .{});
    print("2. Custom serializers handle complex types (Name with length prefix)\n", .{});
    print("3. `pub const serialized = false` excludes components (RuntimeState)\n", .{});
    print("4. Resources and events are also serialized\n", .{});
    print("5. CRC32 checksum validates data integrity\n", .{});
    print("6. Type hash ensures component/resource types match between save/load\n", .{});
    print("7. Groups must be recreated after deserialization (not serialized)\n", .{});
}
