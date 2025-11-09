const std = @import("std");
const entity_mod = @import("../core/entity.zig");
const Entity = entity_mod.Entity;

/// Serialize TagStorage to writer
pub fn serialize(
    comptime Tag: type,
    tag_storage: anytype,
    writer: anytype,
) !void {
    _ = Tag; // Tag type is zero-sized, no data to serialize

    // Write bitset capacity
    const capacity: u32 = @intCast(tag_storage.tag_bit_set.capacity());
    try writer.writeInt(u32, capacity, .little);

    // Write bitset data (u64 words)
    if (capacity > 0) {
        const mask_count = (capacity + 63) / 64; // Number of u64 masks in wire format
        try writer.writeInt(u32, @intCast(mask_count), .little);

        // Access bitset masks directly
        const masks = tag_storage.tag_bit_set.masks;
        
        if (@bitSizeOf(usize) == 64) {
            // 64-bit platform: masks are already u64
            for (masks[0..mask_count]) |mask| {
                try writer.writeInt(u64, mask, .little);
            }
        } else {
            // 32-bit platform: combine pairs of u32 masks into u64
            // Calculate actual number of usize masks present
            const usize_mask_count = (capacity + 31) / 32;
            for (0..mask_count) |i| {
                const low_idx = i * 2;
                const high_idx = low_idx + 1;
                const low: u64 = if (low_idx < usize_mask_count) masks[low_idx] else 0;
                const high: u64 = if (high_idx < usize_mask_count) masks[high_idx] else 0;
                const combined: u64 = low | (high << 32);
                try writer.writeInt(u64, combined, .little);
            }
        }
    } else {
        try writer.writeInt(u32, 0, .little);
    }

    // Write packed entity array count
    const entity_count: u32 = @intCast(tag_storage.packed_array.items.len);
    try writer.writeInt(u32, entity_count, .little);

    // Write packed entity array
    for (tag_storage.packed_array.items) |entity| {
        try writer.writeInt(u32, entity, .little);
    }
}

/// Deserialize TagStorage from reader
pub fn deserialize(
    comptime Tag: type,
    allocator: std.mem.Allocator,
    reader: anytype,
) !@import("../core/tag_storage.zig").TagStorage(Tag) {
    const TagStorageType = @import("../core/tag_storage.zig").TagStorage(Tag);

    var tag_storage = TagStorageType.init(allocator);
    errdefer tag_storage.deinit();

    // Read bitset capacity
    const capacity = try reader.readInt(u32, .little);

    // Read bitset data
    const mask_count = try reader.readInt(u32, .little);

    if (mask_count > 0) {
        // Resize bitset to capacity
        try tag_storage.tag_bit_set.resize(allocator, capacity, false);

        // Read masks
        const masks = tag_storage.tag_bit_set.masks;
        
        if (@bitSizeOf(usize) == 64) {
            // 64-bit platform: read u64 directly into usize masks
            for (masks[0..mask_count]) |*mask| {
                mask.* = try reader.readInt(u64, .little);
            }
        } else {
            // 32-bit platform: split u64 into pairs of u32 masks
            // Calculate actual number of usize masks present
            const usize_mask_count = (capacity + 31) / 32;
            for (0..mask_count) |i| {
                const combined = try reader.readInt(u64, .little);
                const low_idx = i * 2;
                const high_idx = low_idx + 1;
                
                if (low_idx < usize_mask_count) {
                    masks[low_idx] = @intCast(combined & 0xFFFFFFFF);
                }
                if (high_idx < usize_mask_count) {
                    masks[high_idx] = @intCast((combined >> 32) & 0xFFFFFFFF);
                }
            }
        }
    }

    // Read packed entity array count
    const entity_count = try reader.readInt(u32, .little);

    // Reserve capacity
    try tag_storage.packed_array.ensureTotalCapacity(allocator, entity_count);

    // Read packed entity array
    for (0..entity_count) |_| {
        const entity = try reader.readInt(u32, .little);
        tag_storage.packed_array.appendAssumeCapacity(entity);
    }

    return tag_storage;
}

// Tests
const testing = std.testing;

test "TagStorage serialization empty" {
    const Tag = struct {};
    const TagStorageType = @import("../core/tag_storage.zig").TagStorage(Tag);

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var tag_storage = TagStorageType.init(testing.allocator);
    defer tag_storage.deinit();

    // Serialize
    try serialize(Tag, &tag_storage, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Tag, testing.allocator, fbs.reader());
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 0), loaded.tag_bit_set.capacity());
    try testing.expectEqual(@as(usize, 0), loaded.packed_array.items.len);
}

test "TagStorage serialization with entities" {
    const Tag = struct {};
    const TagStorageType = @import("../core/tag_storage.zig").TagStorage(Tag);

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var tag_storage = TagStorageType.init(testing.allocator);
    defer tag_storage.deinit();

    // Add tags for various entities
    const entity1: Entity = 0 | (0 << 16); // index 0, version 0
    const entity2: Entity = 5 | (0 << 16); // index 5, version 0
    const entity3: Entity = 10 | (1 << 16); // index 10, version 1

    try tag_storage.set(entity1);
    try tag_storage.set(entity2);
    try tag_storage.set(entity3);

    // Serialize
    try serialize(Tag, &tag_storage, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Tag, testing.allocator, fbs.reader());
    defer loaded.deinit();

    // Verify packed array
    try testing.expectEqual(@as(usize, 3), loaded.packed_array.items.len);

    // Verify entities have tags
    try testing.expect(loaded.contains(entity1));
    try testing.expect(loaded.contains(entity2));
    try testing.expect(loaded.contains(entity3));

    // Verify non-tagged entities don't have tags
    const entity4: Entity = 7 | (0 << 16);
    try testing.expect(!loaded.contains(entity4));
}

test "TagStorage serialization many entities" {
    const Tag = struct {};
    const TagStorageType = @import("../core/tag_storage.zig").TagStorage(Tag);

    var buffer: [1024 * 64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var tag_storage = TagStorageType.init(testing.allocator);
    defer tag_storage.deinit();

    // Add many tags
    const count = 1000;
    for (0..count) |i| {
        const entity: Entity = @intCast(i | (0 << 16));
        try tag_storage.set(entity);
    }

    try testing.expectEqual(@as(usize, count), tag_storage.packed_array.items.len);

    // Serialize
    try serialize(Tag, &tag_storage, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Tag, testing.allocator, fbs.reader());
    defer loaded.deinit();

    // Verify all entities have tags
    try testing.expectEqual(@as(usize, count), loaded.packed_array.items.len);

    for (0..count) |i| {
        const entity: Entity = @intCast(i | (0 << 16));
        try testing.expect(loaded.contains(entity));
    }
}

test "TagStorage serialization sparse indices" {
    const Tag = struct {};
    const TagStorageType = @import("../core/tag_storage.zig").TagStorage(Tag);

    var buffer: [1024 * 64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var tag_storage = TagStorageType.init(testing.allocator);
    defer tag_storage.deinit();

    // Add tags at sparse indices
    const sparse_indices = [_]u16{ 0, 100, 500, 1000, 5000, 10000 };
    for (sparse_indices) |index| {
        const entity: Entity = @as(u32, index) | (0 << 16);
        try tag_storage.set(entity);
    }

    try testing.expectEqual(@as(usize, sparse_indices.len), tag_storage.packed_array.items.len);

    // Serialize
    try serialize(Tag, &tag_storage, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Tag, testing.allocator, fbs.reader());
    defer loaded.deinit();

    // Verify all sparse entities have tags
    try testing.expectEqual(@as(usize, sparse_indices.len), loaded.packed_array.items.len);

    for (sparse_indices) |index| {
        const entity: Entity = @as(u32, index) | (0 << 16);
        try testing.expect(loaded.contains(entity));
    }

    // Verify intermediate indices don't have tags
    const entity_50: Entity = 50 | (0 << 16);
    try testing.expect(!loaded.contains(entity_50));
}