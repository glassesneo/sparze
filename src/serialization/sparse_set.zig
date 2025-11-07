const std = @import("std");
const entity_mod = @import("../core/entity.zig");
const sparse_set_mod = @import("../core/sparse_set.zig");
const traits = @import("traits.zig");

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

    // Write sparse pages (only allocated ones)
    for (sparse_set.sparse_pages, 0..) |maybe_page, page_idx| {
        const page = maybe_page orelse continue;

        // Write page index
        try writer.writeInt(u16, @intCast(page_idx), .little);

        // Write page slots
        for (page.slots) |maybe_slot| {
            // Write slot presence flag (1 byte) + value (2 bytes if present)
            if (maybe_slot) |slot| {
                try writer.writeInt(u8, 1, .little);
                try writer.writeInt(u16, slot, .little);
            } else {
                try writer.writeInt(u8, 0, .little);
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
pub fn deserialize(
    comptime Component: type,
    allocator: std.mem.Allocator,
    reader: anytype,
) !@import("../core/sparse_set.zig").SparseSet(Component) {
    const SparseSetType = @import("../core/sparse_set.zig").SparseSet(Component);
    const Serializer = traits.getSerializer(Component);

    var sparse_set = SparseSetType.init(allocator);
    errdefer sparse_set.deinit();

    // Read group boundary
    sparse_set.group_info.size = try reader.readInt(u32, .little);

    // Read dense array count
    const dense_count = try reader.readInt(u32, .little);

    // Read allocated page count
    const allocated_page_count = try reader.readInt(u16, .little);

    // Read sparse pages
    for (0..allocated_page_count) |_| {
        // Read page index
        const page_idx = try reader.readInt(u16, .little);

        // Allocate page
        const page = try allocator.create(SparsePage);
        errdefer allocator.destroy(page);

        // Read page slots
        for (&page.slots) |*maybe_slot| {
            const has_value = try reader.readInt(u8, .little);
            if (has_value == 1) {
                const slot = try reader.readInt(u16, .little);
                maybe_slot.* = slot;
            } else {
                maybe_slot.* = null;
            }
        }

        sparse_set.sparse_pages[page_idx] = page;
    }

    // Reserve capacity for dense arrays
    try sparse_set.packed_array.ensureTotalCapacity(allocator, dense_count);
    try sparse_set.components.ensureTotalCapacity(allocator, dense_count);

    // Read packed entity array
    for (0..dense_count) |_| {
        const entity = try reader.readInt(u32, .little);
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
    const SparseSetType = @import("../core/sparse_set.zig").SparseSet(Component);

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    var sparse_set = SparseSetType.init(testing.allocator);
    defer sparse_set.deinit();

    // Serialize
    try serialize(Component, &sparse_set, fbs.writer());

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader());
    defer loaded.deinit();

    try testing.expectEqual(@as(u32, 0), loaded.group_info.size);
    try testing.expectEqual(@as(usize, 0), loaded.packed_array.items.len);
    try testing.expectEqual(@as(usize, 0), loaded.components.items.len);
}

test "SparseSet serialization with components" {
    const Component = struct { x: f32, y: f32 };
    const SparseSetType = @import("../core/sparse_set.zig").SparseSet(Component);

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

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader());
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
    const SparseSetType = @import("../core/sparse_set.zig").SparseSet(Component);

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

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader());
    defer loaded.deinit();

    // Verify group boundary preserved
    try testing.expectEqual(@as(u32, 2), loaded.group_info.size);
    try testing.expectEqual(@as(usize, 3), loaded.packed_array.items.len);
}

test "SparseSet serialization multiple pages" {
    const Component = struct { id: u16 };
    const SparseSetType = @import("../core/sparse_set.zig").SparseSet(Component);

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

    // Deserialize
    fbs.pos = 0;
    var loaded = try deserialize(Component, testing.allocator, fbs.reader());
    defer loaded.deinit();

    // Verify all components are accessible
    try testing.expectEqual(@as(u16, 1), loaded.get(entity1).?.id);
    try testing.expectEqual(@as(u16, 2), loaded.get(entity2).?.id);
    try testing.expectEqual(@as(u16, 3), loaded.get(entity3).?.id);
}
