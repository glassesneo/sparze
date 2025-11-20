const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const entity_module = @import("../entity/entity.zig");
pub const max_entities = entity_module.max_entities;
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;
const EntityIndex = entity_module.EntityIndex;
const EntityVersion = entity_module.EntityVersion;
const getIndex = entity_module.getIndex;
const getVersion = entity_module.getVersion;

// Pagination configuration (same as SparseSet)
pub const page_size: u16 = 4096; // Entities per page (2^12)
pub const page_shift: u5 = 12; // log2(page_size)
pub const page_mask: u16 = page_size - 1; // 0xFFF
pub const max_pages: u16 = @intCast((@as(u32, max_entities) + @as(u32, page_size) - 1) / @as(u32, page_size));

// Number of u64 words needed to store page_size bits
const bits_per_word = 64;
const words_per_page = page_size / bits_per_word; // 4096 / 64 = 64 words

/// A single page in the tag storage
pub const TagPage = struct {
    // Bitset for tag presence (4096 bits = 64 u64 words = 512 bytes)
    tag_bits: [words_per_page]u64,
    // Reverse indices mapping entity index within page -> packed array index
    // u32 max value used as sentinel for "not set"
    sparse_to_dense: [page_size]u32,

    fn init() TagPage {
        return .{
            .tag_bits = [_]u64{0} ** words_per_page,
            .sparse_to_dense = [_]u32{std.math.maxInt(u32)} ** page_size,
        };
    }

    fn isSet(self: *const TagPage, slot_idx: u16) bool {
        const word_idx = slot_idx / bits_per_word;
        const bit_idx: u6 = @intCast(slot_idx % bits_per_word);
        return (self.tag_bits[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    fn setBit(self: *TagPage, slot_idx: u16) void {
        const word_idx = slot_idx / bits_per_word;
        const bit_idx: u6 = @intCast(slot_idx % bits_per_word);
        self.tag_bits[word_idx] |= (@as(u64, 1) << bit_idx);
    }

    fn unsetBit(self: *TagPage, slot_idx: u16) void {
        const word_idx = slot_idx / bits_per_word;
        const bit_idx: u6 = @intCast(slot_idx % bits_per_word);
        self.tag_bits[word_idx] &= ~(@as(u64, 1) << bit_idx);
    }
};

/// Storage for tag components (zero-sized marker components).
///
/// TagStorage is optimized for components with no data (empty structs).
/// It uses a paged sparse layout for memory efficiency and a packed entity array
/// for efficient iteration. Unlike SparseSet, it stores no component data,
/// only tracking which entities have the tag.
///
/// Memory layout:
/// - Paged sparse array: Only allocates pages (4096 entities each) as needed
///   - Each page contains a bitset (512 bytes) and reverse indices (16KB)
///   - Memory usage: O(max_entity_index / page_size) instead of O(max_entity_index)
/// - ArrayList(Entity): Packed array of entities with this tag for iteration
///
/// Use cases:
/// - Marker components (e.g., `const Player = struct {};`)
/// - State flags (e.g., `const Disabled = struct {};`)
/// - Group membership (e.g., `const Enemy = struct {};`)
///
/// Complexity:
/// - set(): O(1) amortized
/// - unset(): O(1)
/// - contains(): O(1)
/// - iteration: O(n) where n = number of tagged entities
pub fn TagStorage(comptime C: type) type {
    // Assume C is empty struct
    return struct {
        const Self = @This();
        pub const Component = C;
        allocator: Allocator,
        packed_array: ArrayList(Entity),
        tag_pages: [max_pages]?*TagPage, // Paginated sparse array

        /// Initialize a new TagStorage with the given allocator.
        /// The storage starts empty with no allocated capacity.
        ///
        /// Example:
        /// ```zig
        /// const PlayerTag = struct {};
        /// var storage = TagStorage(PlayerTag).init(allocator);
        /// defer storage.deinit();
        /// ```
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .packed_array = .{},
                .tag_pages = [_]?*TagPage{null} ** max_pages,
            };
        }

        /// Deinitialize TagStorage, freeing internal buffers.
        /// All entities and page data will be deallocated.
        pub fn deinit(self: *Self) void {
            // Free all allocated pages
            for (self.tag_pages) |maybe_page| {
                const page = maybe_page orelse continue;
                self.allocator.destroy(page);
            }
            self.packed_array.deinit(self.allocator);
        }

        /// Reserve capacity for the specified number of tags to reduce reallocations.
        /// Useful before bulk inserts (e.g., when loading a scene).
        /// Reserves packed entity array and pre-allocates sparse pages.
        ///
        /// Complexity: O(page_count) where page_count = capacity / page_size.
        ///
        /// Example:
        /// ```zig
        /// try storage.reserve(1000); // Pre-allocate for 1000 tagged entities
        /// for (entities) |entity| {
        ///     try storage.set(entity); // No reallocation up to 1000 entities
        /// }
        /// ```
        pub fn reserve(self: *Self, capacity: usize) !void {
            try self.packed_array.ensureTotalCapacity(self.allocator, capacity);

            // Pre-allocate sparse pages to avoid allocation spikes during bulk inserts
            // Calculate required pages: ceiling(capacity / page_size)
            const required_pages = (capacity + page_size - 1) / page_size;
            try self.reservePages(required_pages);
        }

        /// Reserve sparse pages to reduce on-demand page allocation overhead.
        /// Pre-allocates the specified number of pages (starting from page 0).
        /// Useful for bulk entity creation scenarios to avoid allocation spikes.
        /// Complexity: O(page_count) where page_count = number of pages to allocate.
        pub fn reservePages(self: *Self, page_count: usize) !void {
            const max_page = @min(page_count, max_pages);
            for (0..max_page) |page_idx| {
                if (self.tag_pages[page_idx] == null) {
                    const new_page = try self.allocator.create(TagPage);
                    new_page.* = TagPage.init();
                    self.tag_pages[page_idx] = new_page;
                }
            }
        }

        fn castEntityIndex(entity: Entity) usize {
            return @intCast(getIndex(entity));
        }

        /// Get or create a tag page for the given entity
        fn getOrCreatePage(self: *Self, entity: Entity) !*TagPage {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index >> page_shift;

            if (self.tag_pages[page_idx]) |page| {
                return page;
            }

            // Allocate new page
            const new_page = try self.allocator.create(TagPage);
            new_page.* = TagPage.init();
            self.tag_pages[page_idx] = new_page;
            return new_page;
        }

        /// Get tag page if it exists
        fn getPage(self: *const Self, entity: Entity) ?*TagPage {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index >> page_shift;
            return self.tag_pages[page_idx];
        }

        /// Mark an entity as having this tag component.
        /// If the entity already has the tag, this is a no-op.
        ///
        /// Complexity: O(1) amortized (may allocate page or resize packed array)
        ///
        /// Example:
        /// ```zig
        /// const entity = world.createEntity();
        /// try storage.set(entity); // Entity now has tag
        /// ```
        pub fn set(self: *Self, entity: Entity) !void {
            const sparse_index = getIndex(entity);
            const slot_idx: u16 = @intCast(sparse_index & page_mask);

            // Get or create the page for this entity
            const page = try self.getOrCreatePage(entity);

            // Check if already set
            if (page.isSet(slot_idx)) return;

            // Add to packed array and set the tag bit
            const packed_index = @as(u32, @intCast(self.packed_array.items.len));
            try self.packed_array.append(self.allocator, entity);
            page.setBit(slot_idx);
            page.sparse_to_dense[slot_idx] = packed_index;
        }

        /// Remove the tag from an entity.
        /// If the entity doesn't have the tag, this is a no-op.
        ///
        /// Complexity: O(1)
        ///
        /// Note: Uses swap-remove on the packed array, so entity order is not preserved.
        ///
        /// Example:
        /// ```zig
        /// storage.unset(entity); // Entity no longer has tag
        /// ```
        pub fn unset(self: *Self, entity: Entity) void {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index >> page_shift;
            const slot_idx: u16 = @intCast(sparse_index & page_mask);

            // Check if page exists and tag is set
            const page = self.tag_pages[page_idx] orelse return;
            if (!page.isSet(slot_idx)) return;

            const packed_index = page.sparse_to_dense[slot_idx];

            // Read the last element BEFORE swapRemove (which will move it)
            const last_element_index = self.packed_array.items.len - 1;
            const will_swap = packed_index < last_element_index;
            const last_entity = if (will_swap) self.packed_array.items[last_element_index] else undefined;

            _ = self.packed_array.swapRemove(packed_index);
            page.unsetBit(slot_idx);
            page.sparse_to_dense[slot_idx] = std.math.maxInt(u32); // Invalidate reverse index

            // Update the reverse index for the swapped entity
            if (will_swap) {
                const last_sparse_index = getIndex(last_entity);
                const last_page_idx = last_sparse_index >> page_shift;
                const last_slot_idx: u16 = @intCast(last_sparse_index & page_mask);
                const last_page = self.tag_pages[last_page_idx].?;
                last_page.sparse_to_dense[last_slot_idx] = packed_index;
            }
        }

        /// Check whether an entity has this tag.
        ///
        /// Complexity: O(1)
        ///
        /// Example:
        /// ```zig
        /// if (storage.contains(entity)) {
        ///     // Entity has the tag
        /// }
        /// ```
        pub fn contains(self: Self, entity: Entity) bool {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index >> page_shift;
            const slot_idx: u16 = @intCast(sparse_index & page_mask);

            const page = self.tag_pages[page_idx] orelse return false;
            return page.isSet(slot_idx);
        }
    };
}

test "TagStorage basic operations" {
    const TestTag = struct {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = EntityRegistry.init();

    var tagStorage = TagStorage(TestTag).init(allocator);
    defer tagStorage.deinit();

    const e1 = registry.create();
    const e2 = registry.create();
    const e3 = registry.create();

    // Test initial state
    try std.testing.expect(!tagStorage.contains(e1));

    // Test set
    try tagStorage.set(e1);
    try tagStorage.set(e2);
    try std.testing.expect(tagStorage.contains(e1));
    try std.testing.expect(tagStorage.contains(e2));
    try std.testing.expect(!tagStorage.contains(e3));

    // Test set on already tagged entity (no-op)
    try tagStorage.set(e1);
    try std.testing.expect(tagStorage.contains(e1));

    // Test unset
    tagStorage.unset(e1);
    try std.testing.expect(!tagStorage.contains(e1));
    try std.testing.expect(tagStorage.contains(e2));

    // Test unsetting non-tagged entity (should not crash)
    tagStorage.unset(e3);
}

test "TagStorage pagination with sparse entities" {
    const TestTag = struct {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tagStorage = TagStorage(TestTag).init(allocator);
    defer tagStorage.deinit();

    var registry = EntityRegistry.init();

    // Create entities in different pages to verify pagination works correctly
    // This test verifies that we DON'T allocate O(max_entity_index) memory
    var entities: [3]Entity = undefined;

    // Entity 0 (page 0)
    entities[0] = registry.create();

    // Skip to get entity in different page (around entity 4096)
    for (0..4096) |_| _ = registry.create();
    entities[1] = registry.create(); // This should be in page 1

    // Skip to get entity in another page (around entity 8192)
    for (0..4095) |_| _ = registry.create();
    entities[2] = registry.create(); // This should be in page 2

    // Tag the entities
    try tagStorage.set(entities[0]);
    try tagStorage.set(entities[1]);
    try tagStorage.set(entities[2]);

    // Verify all entities are tagged
    try std.testing.expect(tagStorage.contains(entities[0]));
    try std.testing.expect(tagStorage.contains(entities[1]));
    try std.testing.expect(tagStorage.contains(entities[2]));

    // Verify packed array has exactly 3 entities
    try std.testing.expectEqual(@as(usize, 3), tagStorage.packed_array.items.len);

    // Untag middle entity and verify others remain
    tagStorage.unset(entities[1]);
    try std.testing.expect(tagStorage.contains(entities[0]));
    try std.testing.expect(!tagStorage.contains(entities[1]));
    try std.testing.expect(tagStorage.contains(entities[2]));

    // Verify packed array has 2 entities after removal
    try std.testing.expectEqual(@as(usize, 2), tagStorage.packed_array.items.len);
}

test "TagStorage removal consistency" {
    const TestTag = struct {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tagStorage = TagStorage(TestTag).init(allocator);
    defer tagStorage.deinit();

    var registry = EntityRegistry.init();
    const total = 10;
    var ids = [_]Entity{undefined} ** total;
    for (0..total) |i| {
        ids[i] = registry.create();
        try tagStorage.set(ids[i]);
    }

    // Verify all entities are tagged
    for (0..total) |i| {
        try std.testing.expect(tagStorage.contains(ids[i]));
    }

    // Remove middle entity
    const mid = ids[5];
    tagStorage.unset(mid);
    try std.testing.expect(!tagStorage.contains(mid));

    // Verify all other entities are still tagged
    for (0..total) |i| {
        if (i == 5) continue;
        try std.testing.expect(tagStorage.contains(ids[i]));
    }

    try std.testing.expectEqual(@as(usize, total - 1), tagStorage.packed_array.items.len);
}

test "TagStorage memory efficiency with high entity IDs" {
    const TestTag = struct {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tagStorage = TagStorage(TestTag).init(allocator);
    defer tagStorage.deinit();

    // Create a high-index entity without allocating all intermediate entities
    const high_index: EntityIndex = 60000; // Well beyond a single page (4096)
    const high_entity: Entity = high_index; // version = 0

    // Tag the high-index entity
    try tagStorage.set(high_entity);

    // Verify it's tagged
    try std.testing.expect(tagStorage.contains(high_entity));
    try std.testing.expectEqual(@as(usize, 1), tagStorage.packed_array.items.len);

    // With the paged implementation, only the page for this high index should be allocated
    var allocated_pages: usize = 0;
    for (tagStorage.tag_pages) |maybe_page| {
        if (maybe_page != null) allocated_pages += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), allocated_pages);

    const expected_page = high_index >> page_shift;
    try std.testing.expect(tagStorage.tag_pages[expected_page] != null);

    // Untag and verify
    tagStorage.unset(high_entity);
    try std.testing.expect(!tagStorage.contains(high_entity));
    try std.testing.expectEqual(@as(usize, 0), tagStorage.packed_array.items.len);
}

