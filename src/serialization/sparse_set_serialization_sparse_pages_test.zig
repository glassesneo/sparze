const std = @import("std");
const entity_mod = @import("../entity/entity.zig");
const serializer = @import("sparse_set.zig");

const Entity = entity_mod.Entity;
const EntityIndex = entity_mod.EntityIndex;
const serialize = serializer.serialize;
const deserialize = serializer.deserialize;

// Tests
const testing = std.testing;
test "SparseSet serialization v2 very sparse pages" {
    // Test with minimal entities per page (1 entity per page across 3 pages)
    // This tests the worst-case scenario for v1 format bloat
    const Component = struct { value: u32 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add 1 entity to page 0, 1 to page 1, 1 to page 2
    const entity1 = Entity.init(0, 0); // Page 0, slot 0
    const entity2 = Entity.init(4096, 0); // Page 1, slot 0
    const entity3 = Entity.init(8192, 0); // Page 2, slot 0

    try sparse_set.insert(entity1, .{ .value = 100 });
    try sparse_set.insert(entity2, .{ .value = 200 });
    try sparse_set.insert(entity3, .{ .value = 300 });

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());
    const bytes_written = fbs.pos;

    // Verify components are retrievable after round-trip
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    try testing.expectEqual(@as(u32, 100), loaded.get(entity1).?.value);
    try testing.expectEqual(@as(u32, 200), loaded.get(entity2).?.value);
    try testing.expectEqual(@as(u32, 300), loaded.get(entity3).?.value);

    // With v2 format, this should be significantly smaller than v1
    // v1: ~3 pages × 4100 bytes = ~12,300 bytes
    // v2: header + 3 × (4 + 4 + 4) = ~50 bytes
    // For now, just verify serialization works
    try testing.expect(bytes_written > 0);
}

test "SparseSet serialization v2 sparse pages (10 entities per page)" {
    // Test with low density (10 entities per page)
    const Component = struct { id: u16, data: u32 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add 10 entities to page 0 (scattered throughout the page)
    var i: u16 = 0;
    while (i < 10) : (i += 1) {
        const entity_index: EntityIndex = i * 400; // Spread across page
        const entity = Entity.init(entity_index, 0);
        try sparse_set.insert(entity, .{ .id = i, .data = @as(u32, i) * 1000 });
    }

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());
    const bytes_written = fbs.pos;

    // Deserialize and verify
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 10), loaded.components.items.len);

    // Verify first and last entities
    const first_entity = Entity.init(0, 0);
    const last_entity = Entity.init(9 * 400, 0);

    try testing.expectEqual(@as(u16, 0), loaded.get(first_entity).?.id);
    try testing.expectEqual(@as(u16, 9), loaded.get(last_entity).?.id);
    try testing.expectEqual(@as(u32, 9000), loaded.get(last_entity).?.data);

    try testing.expect(bytes_written > 0);
}

test "SparseSet serialization v2 medium density pages" {
    // Test with medium density (~500 entities per page)
    const Component = struct { value: u16 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add 500 entities to page 0
    var i: u16 = 0;
    while (i < 500) : (i += 1) {
        const entity = Entity.init(i, 0);
        try sparse_set.insert(entity, .{ .value = i });
    }

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());
    const bytes_written = fbs.pos;

    // Deserialize and verify
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 500), loaded.components.items.len);

    // Spot check some entities
    try testing.expectEqual(@as(u16, 0), loaded.get(Entity.init(0, 0)).?.value);
    try testing.expectEqual(@as(u16, 250), loaded.get(Entity.init(250, 0)).?.value);
    try testing.expectEqual(@as(u16, 499), loaded.get(Entity.init(499, 0)).?.value);

    // v2 should be moderately efficient
    // v1: 4100 bytes per page, v2: ~(500 * 4) + overhead = ~2KB
    try testing.expect(bytes_written > 0);
}

test "SparseSet serialization v2 dense pages" {
    // Test with high density (~4000 entities in one page)
    const Component = struct { id: u16 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add 4000 entities to page 0 (almost full page)
    var i: u16 = 0;
    while (i < 4000) : (i += 1) {
        const entity = Entity.init(i, 0);
        try sparse_set.insert(entity, .{ .id = i });
    }

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());
    const bytes_written = fbs.pos;

    // Deserialize and verify
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 4000), loaded.components.items.len);

    // Verify boundary entities
    try testing.expectEqual(@as(u16, 0), loaded.get(Entity.init(0, 0)).?.id);
    try testing.expectEqual(@as(u16, 1999), loaded.get(Entity.init(1999, 0)).?.id);
    try testing.expectEqual(@as(u16, 3999), loaded.get(Entity.init(3999, 0)).?.id);

    // For dense pages, v2 will be larger than v1, but that's acceptable
    // v1: ~12,290 bytes, v2: ~16,386 bytes
    // This is the trade-off for optimizing sparse cases
    try testing.expect(bytes_written > 0);
}

test "SparseSet serialization v2 file size verification sparse" {
    // Explicitly verify file size reduction for sparse case
    const Component = struct { val: u8 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add 3 entities across 3 pages (worst case for v1)
    try sparse_set.insert(Entity.init(0, 0), .{ .val = 1 });
    try sparse_set.insert(Entity.init(4096, 0), .{ .val = 2 });
    try sparse_set.insert(Entity.init(8192, 0), .{ .val = 3 });

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());
    const bytes_written = fbs.pos;

    // With v2 optimized format:
    // - group_info.size: 4 bytes
    // - dense_count: 4 bytes
    // - allocated_page_count: 2 bytes
    // - 3 pages × (page_idx: 2 + filled_count: 2 + 1 × (slot_idx: 2 + dense_idx: 2)) = 3 × 8 = 24 bytes
    // - packed_array: 3 × 4 = 12 bytes
    // - components: 3 × 1 = 3 bytes
    // Total: ~49 bytes
    //
    // With v1 format it would be:
    // - Same header: 10 bytes
    // - 3 pages × (page_idx: 2 + 4096 slots × (1 or 3 bytes)) ≈ 3 × 4100 = ~12,300 bytes
    //
    // So v2 should be under 100 bytes, v1 would be over 12KB

    // Verify v2 optimization: should be under 100 bytes (much less than v1's ~12KB)
    try testing.expect(bytes_written > 0);
    try testing.expect(bytes_written < 100); // v2: ~50 bytes vs v1: ~12,300 bytes
}
