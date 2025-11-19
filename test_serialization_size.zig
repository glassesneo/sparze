const std = @import("std");
const sparse_set_mod = @import("src/storage/sparse_set.zig");
const serialize_mod = @import("src/serialization/sparse_set.zig");
const Entity = @import("src/entity/entity.zig").Entity;

const Component = struct { x: f32, y: f32 };
const SparseSetType = sparse_set_mod.SparseSet(Component);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sparse_set = SparseSetType.init(allocator);
    defer sparse_set.deinit();

    // Test case 1: Sparse entities across multiple pages (worst case)
    std.debug.print("\n=== Test Case 1: Sparse Distribution ===\n", .{});
    std.debug.print("Adding 10 entities spread across 3 pages (page 0, 1, 2)\n", .{});

    // Add entities sparsely across pages
    const sparse_entities = [_]Entity{
        0 | (0 << 16),      // Page 0
        1 | (0 << 16),      // Page 0
        2 | (0 << 16),      // Page 0
        4096 | (0 << 16),   // Page 1
        4097 | (0 << 16),   // Page 1
        4098 | (0 << 16),   // Page 1
        8192 | (0 << 16),   // Page 2
        8193 | (0 << 16),   // Page 2
        8194 | (0 << 16),   // Page 2
        8195 | (0 << 16),   // Page 2
    };

    for (sparse_entities) |entity| {
        try sparse_set.insert(entity, .{ .x = 1.0, .y = 2.0 });
    }

    var buffer: [1024 * 1024]u8 = undefined; // 1MB buffer
    var fbs = std.io.fixedBufferStream(&buffer);

    try serialize_mod.serialize(Component, &sparse_set, fbs.writer());
    const bytes_written = fbs.pos;

    std.debug.print("Entities: {d}\n", .{sparse_entities.len});
    std.debug.print("Pages allocated: 3\n", .{});
    std.debug.print("Bytes written: {d}\n", .{bytes_written});
    std.debug.print("Bytes per page: {d}\n", .{bytes_written / 3});
    std.debug.print("Average occupancy per page: {d:.2}%\n", .{@as(f32, @floatFromInt(sparse_entities.len)) / 3.0 / 4096.0 * 100.0});

    // Calculate theoretical minimum (without current implementation overhead)
    const theoretical_min =
        4 + // group boundary (u32)
        4 + // dense count (u32)
        2 + // allocated page count (u16)
        3 * (2 + sparse_entities.len / 3 * 3) + // per page: page_idx (u16) + occupied slots (1 byte flag + 2 byte value)
        sparse_entities.len * 4 + // packed entity array
        sparse_entities.len * 8; // components (2 * f32)

    std.debug.print("Theoretical minimum: ~{d} bytes\n", .{theoretical_min});
    std.debug.print("Overhead: {d} bytes ({d:.1f}x larger)\n", .{bytes_written - theoretical_min, @as(f32, @floatFromInt(bytes_written)) / @as(f32, @floatFromInt(theoretical_min))});

    // Test case 2: Dense packing (best case for current implementation)
    std.debug.print("\n=== Test Case 2: Dense Packing ===\n", .{});
    sparse_set.deinit();
    sparse_set = SparseSetType.init(allocator);

    std.debug.print("Adding 4096 consecutive entities (fully populated page)\n", .{});
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        try sparse_set.insert(i | (0 << 16), .{ .x = @floatFromInt(i), .y = @floatFromInt(i) });
    }

    fbs.pos = 0;
    try serialize_mod.serialize(Component, &sparse_set, fbs.writer());
    const bytes_dense = fbs.pos;

    std.debug.print("Entities: {d}\n", .{4096});
    std.debug.print("Pages allocated: 1\n", .{});
    std.debug.print("Bytes written: {d}\n", .{bytes_dense});
    std.debug.print("Bytes per entity: {d:.2}\n", .{@as(f32, @floatFromInt(bytes_dense)) / 4096.0});

    const dense_min =
        4 + // group boundary
        4 + // dense count
        2 + // allocated page count
        2 + // page index
        4096 * 3 + // all slots filled (1 byte flag + 2 byte value)
        4096 * 4 + // packed entity array
        4096 * 8; // components

    std.debug.print("Expected bytes (fully packed): ~{d}\n", .{dense_min});
    std.debug.print("Average occupancy per page: 100.00%\n", .{});
}
