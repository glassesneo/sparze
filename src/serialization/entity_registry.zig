const std = @import("std");
const entity_mod = @import("../core/entity.zig");
const Entity = entity_mod.Entity;
const EntityIndex = entity_mod.EntityIndex;
const EntityRegistry = entity_mod.EntityRegistry;

/// Serialize EntityRegistry to writer
/// Writes complete registry state including free list for full reproducibility
pub fn serialize(registry: *const EntityRegistry, writer: anytype) !void {
    // Write metadata
    try writer.writeInt(u16, registry.next_index, .little);
    try writer.writeInt(u16, registry.available, .little);
    try writer.writeInt(u32, registry.next_index_to_recycle, .little);

    // Write entire entities array to preserve free list structure
    // This is critical for maintaining entity versioning and recycling state
    for (registry.entities) |entity_value| {
        try writer.writeInt(u32, entity_value, .little);
    }
}

/// Deserialize EntityRegistry from reader
/// Reconstructs complete registry state including free list
pub fn deserialize(reader: anytype) !EntityRegistry {
    var registry = EntityRegistry.init();

    // Read metadata
    registry.next_index = try reader.readInt(u16, .little);
    registry.available = try reader.readInt(u16, .little);
    registry.next_index_to_recycle = try reader.readInt(u32, .little);

    // Read entire entities array
    for (&registry.entities) |*entity_value| {
        entity_value.* = try reader.readInt(u32, .little);
    }

    return registry;
}

test "EntityRegistry serialization round-trip empty" {
    var buffer: [1024 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var registry = EntityRegistry.init();

    // Serialize
    try serialize(&registry, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    const loaded = try deserialize(fbs.reader());

    // Verify metadata
    try std.testing.expectEqual(registry.next_index, loaded.next_index);
    try std.testing.expectEqual(registry.available, loaded.available);
    try std.testing.expectEqual(@as(usize, 0), loaded.aliveCount());
}

test "EntityRegistry serialization round-trip with entities" {
    var buffer: [1024 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var registry = EntityRegistry.init();

    // Create some entities
    const e1 = registry.create();
    const e2 = registry.create();
    const e3 = registry.create();

    try std.testing.expectEqual(@as(usize, 3), registry.aliveCount());

    // Serialize
    try serialize(&registry, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    const loaded = try deserialize(fbs.reader());

    // Verify metadata
    try std.testing.expectEqual(registry.next_index, loaded.next_index);
    try std.testing.expectEqual(registry.available, loaded.available);
    try std.testing.expectEqual(@as(usize, 3), loaded.aliveCount());

    // Verify entities are alive
    try std.testing.expect(loaded.isAlive(e1));
    try std.testing.expect(loaded.isAlive(e2));
    try std.testing.expect(loaded.isAlive(e3));
}

test "EntityRegistry serialization preserves recycling state" {
    var buffer: [1024 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var registry = EntityRegistry.init();

    // Create and destroy entities to build free list
    const e1 = registry.create(); // 0|0
    const e2 = registry.create(); // 1|0
    const e3 = registry.create(); // 2|0
    const e4 = registry.create(); // 3|0

    registry.destroy(e2); // Free: 1
    registry.destroy(e4); // Free: 3 -> 1

    try std.testing.expectEqual(@as(usize, 2), registry.aliveCount());
    try std.testing.expectEqual(@as(u16, 2), registry.available);

    // Serialize
    try serialize(&registry, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(fbs.reader());

    // Verify recycling state
    try std.testing.expectEqual(registry.next_index, loaded.next_index);
    try std.testing.expectEqual(registry.available, loaded.available);
    try std.testing.expectEqual(registry.next_index_to_recycle, loaded.next_index_to_recycle);

    // Verify alive entities
    try std.testing.expect(loaded.isAlive(e1));
    try std.testing.expect(!loaded.isAlive(e2));
    try std.testing.expect(loaded.isAlive(e3));
    try std.testing.expect(!loaded.isAlive(e4));

    // Verify recycling works correctly (LIFO order)
    const r1 = loaded.create(); // Should recycle index 3 with version 1
    try std.testing.expectEqual(entity_mod.getIndex(e4), entity_mod.getIndex(r1));
    try std.testing.expectEqual(entity_mod.getVersion(e4) + 1, entity_mod.getVersion(r1));

    const r2 = loaded.create(); // Should recycle index 1 with version 1
    try std.testing.expectEqual(entity_mod.getIndex(e2), entity_mod.getIndex(r2));
    try std.testing.expectEqual(entity_mod.getVersion(e2) + 1, entity_mod.getVersion(r2));

    const r3 = loaded.create(); // Should create new index 4 with version 0
    try std.testing.expectEqual(@as(u16, 4), entity_mod.getIndex(r3));
    try std.testing.expectEqual(@as(u16, 0), entity_mod.getVersion(r3));
}

test "EntityRegistry serialization full lifecycle" {
    var buffer: [1024 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var registry = EntityRegistry.init();

    // Create many entities
    var entities: [100]Entity = undefined;
    for (&entities) |*e| {
        e.* = registry.create();
    }

    // Destroy every other entity
    for (entities, 0..) |e, i| {
        if (i % 2 == 0) {
            registry.destroy(e);
        }
    }

    const original_alive = registry.aliveCount();
    try std.testing.expectEqual(@as(usize, 50), original_alive);

    // Serialize
    try serialize(&registry, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    const loaded = try deserialize(fbs.reader());

    // Verify state
    try std.testing.expectEqual(original_alive, loaded.aliveCount());
    try std.testing.expectEqual(registry.next_index, loaded.next_index);
    try std.testing.expectEqual(registry.available, loaded.available);

    // Verify each entity's alive state
    for (entities, 0..) |e, i| {
        if (i % 2 == 0) {
            try std.testing.expect(!loaded.isAlive(e));
        } else {
            try std.testing.expect(loaded.isAlive(e));
        }
    }
}
