const std = @import("std");
const entity_mod = @import("../entity/entity.zig");
const sparse_set_mod = @import("../storage/sparse_set.zig");
const traits = @import("traits.zig");
const compat = @import("compat.zig");

const Entity = entity_mod.Entity;
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
        try writer.writeInt(u32, entity.toInt(), .little);
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
        const entity = Entity.fromInt(try compat.readInt(reader, u32, .little));
        sparse_set.packed_array.appendAssumeCapacity(entity);
    }

    // Read component data using appropriate deserializer
    for (0..dense_count) |_| {
        const component = try Serializer.deserialize(reader);
        sparse_set.components.appendAssumeCapacity(component);
    }

    return sparse_set;
}

// (no local tests in this module)
