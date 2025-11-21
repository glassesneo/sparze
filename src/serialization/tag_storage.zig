const std = @import("std");
const entity_mod = @import("../entity/entity.zig");
const Entity = entity_mod.Entity;
const tag_storage_mod = @import("../storage/tag_storage.zig");

/// Serialize TagStorage to writer
pub fn serialize(
    comptime Tag: type,
    tag_storage: anytype,
    writer: anytype,
) !void {
    _ = Tag; // Tag type is zero-sized, no data to serialize

    // Write number of allocated pages
    var allocated_page_count: u32 = 0;
    for (tag_storage.tag_pages) |maybe_page| {
        if (maybe_page != null) allocated_page_count += 1;
    }
    try writer.writeInt(u32, allocated_page_count, .little);

    // Write each allocated page with its index
    for (tag_storage.tag_pages, 0..) |maybe_page, page_idx| {
        const page = maybe_page orelse continue;

        // Write page index
        try writer.writeInt(u16, @intCast(page_idx), .little);

        // Write tag bits (64 u64 words)
        for (page.tag_bits) |word| {
            try writer.writeInt(u64, word, .little);
        }

        // Write sparse_to_dense indices (4096 u32 values)
        for (page.sparse_to_dense) |index| {
            try writer.writeInt(u32, index, .little);
        }
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
) !tag_storage_mod.TagStorage(Tag) {
    const TagStorageType = tag_storage_mod.TagStorage(Tag);
    const TagPage = tag_storage_mod.TagPage;

    var tag_storage = TagStorageType.init(allocator);
    errdefer tag_storage.deinit();

    // Read number of allocated pages
    const allocated_page_count = try reader.readInt(u32, .little);

    // Read each page
    for (0..allocated_page_count) |_| {
        // Read page index
        const page_idx = try reader.readInt(u16, .little);

        // Allocate page
        const page = try allocator.create(TagPage);
        errdefer allocator.destroy(page);

        // Read tag bits
        for (&page.tag_bits) |*word| {
            word.* = try reader.readInt(u64, .little);
        }

        // Read sparse_to_dense indices
        for (&page.sparse_to_dense) |*index| {
            index.* = try reader.readInt(u32, .little);
        }

        tag_storage.tag_pages[page_idx] = page;
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
    const TagStorageType = tag_storage_mod.TagStorage(Tag);

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

    // Verify no pages allocated
    var page_count: usize = 0;
    for (loaded.tag_pages) |maybe_page| {
        if (maybe_page != null) page_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), page_count);
    try testing.expectEqual(@as(usize, 0), loaded.packed_array.items.len);
}

test "TagStorage serialization with entities" {
    const Tag = struct {};
    const TagStorageType = tag_storage_mod.TagStorage(Tag);

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
    const TagStorageType = tag_storage_mod.TagStorage(Tag);

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
    const TagStorageType = tag_storage_mod.TagStorage(Tag);

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
