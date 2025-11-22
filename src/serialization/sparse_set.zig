const std = @import("std");
const entity_mod = @import("../entity/entity.zig");
const sparse_set_mod = @import("../storage/sparse_set.zig");
const traits = @import("traits.zig");
const compat = @import("compat.zig");

const Entity = entity_mod.Entity;
const EntityIndex = entity_mod.EntityIndex;
const SparsePage = sparse_set_mod.SparsePage;
const page_size = sparse_set_mod.page_size;
const max_pages = sparse_set_mod.max_pages;

/// Serialize a SparseSet to writer
/// Uses component-specific serializer (POD or custom)
pub fn serialize(
    comptime Component: type,
    sparse_set: anytype,
    writer: anytype,
) !void {
    const Serializer = traits.getSerializer(Component);

    // Write group boundary
    try writer.writeInt(u32, sparse_set.group_info.size, .little);

    // Write dense array count
    const dense_count: u32 = @intCast(sparse_set.packed_array.items.len);
    try writer.writeInt(u32, dense_count, .little);

    // Count allocated pages
    var allocated_page_count: u16 = 0;
    for (sparse_set.sparse_pages) |maybe_page| {
        if (maybe_page != null) allocated_page_count += 1;
    }

    // Write allocated page count
    try writer.writeInt(u16, allocated_page_count, .little);

    // Write sparse pages (only allocated ones) - v2 format
    for (sparse_set.sparse_pages, 0..) |maybe_page, page_idx| {
        const page = maybe_page orelse continue;

        // Write page index
        try writer.writeInt(u16, @intCast(page_idx), .little);

        // Count filled slots
        var filled_count: u16 = 0;
        for (page.slots) |maybe_slot| {
            if (maybe_slot != null) filled_count += 1;
        }

        // Write filled slot count
        try writer.writeInt(u16, filled_count, .little);

        // Write only filled slots (slot_index, dense_index pairs)
        for (page.slots, 0..) |maybe_slot, slot_idx| {
            if (maybe_slot) |dense_index| {
                try writer.writeInt(u16, @intCast(slot_idx), .little);
                try writer.writeInt(u16, dense_index, .little);
            }
        }
    }

    // Write packed entity array
    for (sparse_set.packed_array.items) |entity| {
        try writer.writeInt(u32, entity, .little);
    }

    // Write component data using appropriate serializer
    for (sparse_set.components.items) |component| {
        try Serializer.serialize(component, writer);
    }
}

/// Deserialize a SparseSet from reader
/// Uses component-specific deserializer (POD or custom)
/// WIP format: only filled slots are serialized
pub fn deserialize(
    comptime Component: type,
    allocator: std.mem.Allocator,
    reader: anytype,
    format_version: [5]u8,
) !@import("../storage/sparse_set.zig").SparseSet(Component) {
    _ = format_version; // Format is 0.1.0 (WIP), no versioning needed yet

    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);
    const Serializer = traits.getSerializer(Component);

    var sparse_set = SparseSetType.init(allocator);
    errdefer sparse_set.deinit();

    // Read group boundary
    sparse_set.group_info.size = try compat.readInt(reader, u32, .little);

    // Read dense array count
    const dense_count = try compat.readInt(reader, u32, .little);

    // Read allocated page count
    const allocated_page_count = try compat.readInt(reader, u16, .little);

    // Read sparse pages (WIP format: only filled slots)
    for (0..allocated_page_count) |_| {
        // Read page index
        const page_idx = try compat.readInt(reader, u16, .little);

        // Validate page_idx is within bounds
        if (page_idx >= max_pages) {
            return error.InvalidPageIndex;
        }

        // Allocate page
        const page = try allocator.create(SparsePage);
        errdefer allocator.destroy(page);

        // Initialize all slots to null
        for (&page.slots) |*maybe_slot| {
            maybe_slot.* = null;
        }

        // Read filled count
        const filled_count = try compat.readInt(reader, u16, .little);

        // Validate filled_count is within bounds
        if (filled_count > page_size) {
            return error.InvalidFilledCount;
        }
        if (filled_count > dense_count) {
            return error.InvalidFilledCount;
        }

        // Read filled slots (slot_index, dense_index pairs)
        for (0..filled_count) |_| {
            const slot_idx = try compat.readInt(reader, u16, .little);
            const dense_index = try compat.readInt(reader, u16, .little);

            // Validate slot_idx is within page bounds
            if (slot_idx >= page_size) {
                return error.InvalidSlotIndex;
            }

            // Validate dense_index is within dense array bounds
            if (dense_index >= dense_count) {
                return error.InvalidDenseIndex;
            }

            page.slots[slot_idx] = dense_index;
        }

        sparse_set.sparse_pages[page_idx] = page;
    }

    // Reserve capacity for dense arrays
    try sparse_set.packed_array.ensureTotalCapacity(allocator, dense_count);
    try sparse_set.components.ensureTotalCapacity(allocator, dense_count);

    // Read packed entity array
    for (0..dense_count) |_| {
        const entity = try compat.readInt(reader, u32, .little);
        sparse_set.packed_array.appendAssumeCapacity(entity);
    }

    // Read component data using appropriate deserializer
    for (0..dense_count) |_| {
        const component = try Serializer.deserialize(reader);
        sparse_set.components.appendAssumeCapacity(component);
    }

    return sparse_set;
}

// Tests
const testing = std.testing;

test "SparseSet serialization empty" {
    const Component = struct { x: f32, y: f32 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());

    // Deserialize (v2 format)
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    try testing.expectEqual(@as(u32, 0), loaded.group_info.size);
    try testing.expectEqual(@as(usize, 0), loaded.packed_array.items.len);
    try testing.expectEqual(@as(usize, 0), loaded.components.items.len);
}

test "SparseSet serialization with components" {
    const Component = struct { x: f32, y: f32 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add components for various entities
    const entity1: Entity = 0 | (0 << 16); // index 0, version 0
    const entity2: Entity = 5 | (0 << 16); // index 5, version 0
    const entity3: Entity = 10 | (1 << 16); // index 10, version 1

    try sparse_set.insert(entity1, .{ .x = 1.0, .y = 2.0 });
    try sparse_set.insert(entity2, .{ .x = 3.0, .y = 4.0 });
    try sparse_set.insert(entity3, .{ .x = 5.0, .y = 6.0 });

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());

    // Deserialize (v2 format)
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    // Verify dense arrays
    try testing.expectEqual(@as(usize, 3), loaded.packed_array.items.len);
    try testing.expectEqual(@as(usize, 3), loaded.components.items.len);

    // Verify components can be retrieved
    const comp1 = loaded.get(entity1).?;
    try testing.expectEqual(@as(f32, 1.0), comp1.x);
    try testing.expectEqual(@as(f32, 2.0), comp1.y);

    const comp2 = loaded.get(entity2).?;
    try testing.expectEqual(@as(f32, 3.0), comp2.x);
    try testing.expectEqual(@as(f32, 4.0), comp2.y);

    const comp3 = loaded.get(entity3).?;
    try testing.expectEqual(@as(f32, 5.0), comp3.x);
    try testing.expectEqual(@as(f32, 6.0), comp3.y);
}

test "SparseSet serialization with group" {
    const Component = struct { value: u32 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add components
    const entity1: Entity = 0 | (0 << 16);
    const entity2: Entity = 1 | (0 << 16);
    const entity3: Entity = 2 | (0 << 16);

    try sparse_set.insert(entity1, .{ .value = 10 });
    try sparse_set.insert(entity2, .{ .value = 20 });
    try sparse_set.insert(entity3, .{ .value = 30 });

    // Set group boundary (first 2 entities are in group)
    sparse_set.group_info.size = 2;

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());

    // Deserialize (v2 format)
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    // Verify group boundary preserved
    try testing.expectEqual(@as(u32, 2), loaded.group_info.size);
    try testing.expectEqual(@as(usize, 3), loaded.packed_array.items.len);
}

test "SparseSet serialization multiple pages" {
    const Component = struct { id: u16 };
    const SparseSetType = @import("../storage/sparse_set.zig").SparseSet(Component);

    var buffer: [1024 * 128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Add components across multiple pages
    // Page 0: entity 0, Page 1: entity 4096, Page 2: entity 8192
    const entity1: Entity = 0 | (0 << 16);
    const entity2: Entity = 4096 | (0 << 16);
    const entity3: Entity = 8192 | (0 << 16);

    try sparse_set.insert(entity1, .{ .id = 1 });
    try sparse_set.insert(entity2, .{ .id = 2 });
    try sparse_set.insert(entity3, .{ .id = 3 });

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());

    // Deserialize (v2 format)
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader(), "0.1.0".*);
    defer loaded.deinit();

    // Verify all components are accessible
    try testing.expectEqual(@as(u16, 1), loaded.get(entity1).?.id);
    try testing.expectEqual(@as(u16, 2), loaded.get(entity2).?.id);
    try testing.expectEqual(@as(u16, 3), loaded.get(entity3).?.id);
}

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
    const entity1: Entity = 0 | (0 << 16); // Page 0, slot 0
    const entity2: Entity = 4096 | (0 << 16); // Page 1, slot 0
    const entity3: Entity = 8192 | (0 << 16); // Page 2, slot 0

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
        const entity: Entity = entity_index | (0 << 16);
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
    const first_entity: Entity = 0 | (0 << 16);
    const last_entity: Entity = (9 * 400) | (0 << 16);

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
        const entity: Entity = i | (0 << 16);
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
    try testing.expectEqual(@as(u16, 0), loaded.get(0 | (0 << 16)).?.value);
    try testing.expectEqual(@as(u16, 250), loaded.get(250 | (0 << 16)).?.value);
    try testing.expectEqual(@as(u16, 499), loaded.get(499 | (0 << 16)).?.value);

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
        const entity: Entity = i | (0 << 16);
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
    try testing.expectEqual(@as(u16, 0), loaded.get(0 | (0 << 16)).?.id);
    try testing.expectEqual(@as(u16, 1999), loaded.get(1999 | (0 << 16)).?.id);
    try testing.expectEqual(@as(u16, 3999), loaded.get(3999 | (0 << 16)).?.id);

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
    try sparse_set.insert(0 | (0 << 16), .{ .val = 1 });
    try sparse_set.insert(4096 | (0 << 16), .{ .val = 2 });
    try sparse_set.insert(8192 | (0 << 16), .{ .val = 3 });

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
