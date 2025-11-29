const std = @import("std");
const sparze = @import("sparze");
const compat = @import("sparze").serialization.compat;

// POD components (automatically serializable)
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };

// Tag components (marker components)
const Player = struct {};
const Enemy = struct {};

// Component with custom serializer (variable-length name)
const Name = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    pub fn fromSlice(name: []const u8) Name {
        var result = Name{};
        const copy_len = @min(name.len, 64);
        @memcpy(result.buffer[0..copy_len], name[0..copy_len]);
        result.len = copy_len;
        return result;
    }

    pub fn slice(self: Name) []const u8 {
        return self.buffer[0..self.len];
    }

    // Custom serializer - only writes actual name length, not full buffer
    pub const Serializer = struct {
        pub fn serialize(name: Name, writer: anytype) !void {
            try writer.writeInt(u16, @intCast(name.len), .little);
            try writer.writeAll(name.buffer[0..name.len]);
        }

        pub fn deserialize(reader: anytype) !Name {
            // Use compat helper for reading integers
            const len = try compat.readInt(reader, u16, .little);
            var name = Name{};
            name.len = len;
            
            // Support both old and new I/O APIs for reading bytes
            const ReaderType = if (@typeInfo(@TypeOf(reader)) == .pointer)
                std.meta.Child(@TypeOf(reader))
            else
                @TypeOf(reader);
            
            if (@hasDecl(ReaderType, "readSliceAll")) {
                try reader.readSliceAll(name.buffer[0..len]);
            } else {
                try reader.readNoEof(name.buffer[0..len]);
            }
            return name;
        }
    };
};

// Resource types
const DeltaTime = struct { dt: f32 };
const Score = struct { points: i32, combo: i32 };

// Event types
const Collision = struct { entityA: sparze.Entity, entityB: sparze.Entity };

// Define World with components, resources, and events
const World = sparze.World(
    struct { Position, Velocity, Health, Name, Player, Enemy },
    struct { DeltaTime, Score },
    struct { Collision },
);

fn createTestWorld(allocator: std.mem.Allocator) !World {
    var world = World.init(allocator);

    // Initialize resources
    world.setResource(DeltaTime, .{ .dt = 0.016 });
    world.setResource(Score, .{ .points = 1000, .combo = 5 });

    // Create player entity
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(player, Velocity, .{ .dx = 1.0, .dy = 0.5 });
    try world.addComponent(player, Health, .{ .hp = 100 });
    try world.addComponent(player, Name, Name.fromSlice("Hero"));
    try world.addTag(player, Player);

    // Create enemy entities
    for (0..3) |i| {
        const enemy = world.createEntity();
        const x: f32 = @floatFromInt(i * 50);
        try world.addComponent(enemy, Position, .{ .x = x, .y = 100.0 });
        try world.addComponent(enemy, Velocity, .{ .dx = -0.5, .dy = 0.0 });
        try world.addComponent(enemy, Health, .{ .hp = 50 });
        const enemy_name = try std.fmt.allocPrint(allocator, "Enemy{d}", .{i});
        defer allocator.free(enemy_name);
        try world.addComponent(enemy, Name, Name.fromSlice(enemy_name));
        try world.addTag(enemy, Enemy);
    }

    // Create some entities without all components
    const static_entity = world.createEntity();
    try world.addComponent(static_entity, Position, .{ .x = 500.0, .y = 500.0 });

    return world;
}

fn printWorldStateSystem(
    positions: sparze.SingleQuery(Position),
    players: sparze.SingleTag(Player),
    enemies: sparze.SingleTag(Enemy),
    names: sparze.Query(struct { Position, Name }),
    delta: sparze.Resource(DeltaTime),
    score: sparze.Resource(Score),
) !void {
    // Print resources
    std.debug.print("DeltaTime: {d:.4}\n", .{delta.value.dt});
    std.debug.print("Score: {d} (combo: {d})\n", .{ score.value.points, score.value.combo });

    // Print counts
    std.debug.print("Position count: {d}\n", .{positions.entities.len});
    std.debug.print("Players: {d}\n", .{players.entities.len});
    std.debug.print("Enemies: {d}\n", .{enemies.entities.len});

    // Print named entities with positions
    var count: usize = 0;
    for (names.entities) |entity| {
        if (names.filter(entity)) {
            count += 1;
        }
    }
    std.debug.print("Named entities: {d}\n", .{count});
}

fn printWorldState(world: *World, label: []const u8) !void {
    std.debug.print("\n=== {s} ===\n", .{label});
    std.debug.print("Entities: {d}\n", .{world.entity_registry.aliveCount()});
    try world.runSystem(printWorldStateSystem);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n🎮 Sparze Serialization Example\n", .{});
    std.debug.print("================================\n", .{});

    // Create and populate world
    var world = try createTestWorld(allocator);
    defer world.deinit();

    try printWorldState(&world, "Original World State");

    // Create and validate a Group for hot-path iteration (not serialized)
    const MovementGroup = struct { Position, Velocity };
    try world.createGroup(MovementGroup);

    // Serialize to file
    const save_path = "examples/world_save.spze";
    std.debug.print("\n💾 Serializing world to '{s}'...\n", .{save_path});
    try world.serializeToFile(save_path);

    // Get file size
    const file = try std.fs.cwd().openFile(save_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    std.debug.print("✅ Saved! File size: {d} bytes\n", .{file_size});

    // Modify world to show differences
    std.debug.print("\n🔧 Modifying world...\n", .{});
    const resource_score = world.getResourcePtrMut(Score);
    resource_score.points += 500;
    resource_score.combo += 2;

    // Create additional entity
    const bonus_entity = world.createEntity();
    try world.addComponent(bonus_entity, Position, .{ .x = 999.0, .y = 999.0 });
    try world.addComponent(bonus_entity, Name, Name.fromSlice("BonusItem"));

    try printWorldState(&world, "Modified World State");

    // Deserialize from file
    std.debug.print("\n📂 Deserializing world from '{s}'...\n", .{save_path});
    try world.deserializeFromFile(save_path);
    std.debug.print("✅ Loaded!\n", .{});

    // After deserialization, groups must be recreated. Recreate MovementGroup.
    try world.createGroup(MovementGroup);
    std.debug.print("ℹ️ Recreated MovementGroup after deserialization.\n", .{});

    try printWorldState(&world, "Restored World State");

    // Verify data integrity
    std.debug.print("\n🔍 Verifying data integrity...\n", .{});

    // Additionally verify that the MovementGroup was repopulated correctly
    const movement_entities = world.getGroupEntities(MovementGroup).?;
    const movement_positions = world.getGroupComponents(MovementGroup, Position).?;
    const movement_velocities = world.getGroupComponents(MovementGroup, Velocity).?;
    std.debug.print("MovementGroup entities: {d}, positions: {d}, velocities: {d}\n", .{ movement_entities.len, movement_positions.len, movement_velocities.len });

    const restored_score = world.getResource(Score);
    if (restored_score.points == 1000 and restored_score.combo == 5) {
        std.debug.print("✅ Resources restored correctly\n", .{});
    } else {
        std.debug.print("❌ Resource mismatch!\n", .{});
    }

    // Verify entity counts via system
    const VerificationSystem = struct {
        fn verify(
            players: sparze.SingleTag(Player),
            enemies: sparze.SingleTag(Enemy),
        ) !void {
            if (players.entities.len == 1) {
                std.debug.print("✅ Player count correct\n", .{});
            } else {
                std.debug.print("❌ Player count mismatch! (got {d})\n", .{players.entities.len});
            }

            if (enemies.entities.len == 3) {
                std.debug.print("✅ Enemy count correct\n", .{});
            } else {
                std.debug.print("❌ Enemy count mismatch! (got {d})\n", .{enemies.entities.len});
            }
        }
    };
    try world.runSystem(VerificationSystem.verify);

    // Check if bonus entity was removed (should not exist after restore)
    const has_bonus = world.hasComponent(bonus_entity, Position);
    if (!has_bonus) {
        std.debug.print("✅ Bonus entity correctly removed\n", .{});
    } else {
        std.debug.print("❌ Bonus entity still exists!\n", .{});
    }

    // Cleanup
    std.fs.cwd().deleteFile(save_path) catch {};

    std.debug.print("\n✨ Serialization example completed successfully!\n", .{});
}