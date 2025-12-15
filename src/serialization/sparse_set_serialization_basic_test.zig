const std = @import("std");
const entity_mod = @import("../entity/entity.zig");
const serializer = @import("sparse_set.zig");

const Entity = entity_mod.Entity;
const serialize = serializer.serialize;
const deserialize = serializer.deserialize;

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
    const entity1 = Entity.init(0, 0); // index 0, version 0
    const entity2 = Entity.init(5, 0); // index 5, version 0
    const entity3 = Entity.init(10, 1); // index 10, version 1

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
    const entity1 = Entity.init(0, 0);
    const entity2 = Entity.init(1, 0);
    const entity3 = Entity.init(2, 0);

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
    const entity1 = Entity.init(0, 0);
    const entity2 = Entity.init(4096, 0);
    const entity3 = Entity.init(8192, 0);

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
