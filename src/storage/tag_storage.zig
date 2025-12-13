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

// Bit manipulation constants for tag bitset
const bits_per_word: u16 = 64; // u64 word size
const words_per_page: u16 = page_size / bits_per_word; // 4096 / 64 = 64 words

/// A single page in the tag storage
/// Contains a bitset for tag presence and reverse indices
pub const TagPage = struct {
    // Bitset: 4096 bits = 64 u64 words = 512 bytes
    tag_bits: [words_per_page]u64,
    // Reverse indices: 4096 × u32 = 16KB
    sparse_to_dense: [page_size]u32,

    fn init() TagPage {
        return .{
            .tag_bits = [_]u64{0} ** words_per_page,
            .sparse_to_dense = [_]u32{std.math.maxInt(u32)} ** page_size,
        };
    }

    /// Check if a bit is set at the given slot index
    fn isSet(self: *const TagPage, slot_idx: u16) bool {
        const word_idx = slot_idx / bits_per_word;
        const bit_idx: u6 = @intCast(slot_idx % bits_per_word);
        return (self.tag_bits[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    /// Set a bit at the given slot index
    fn setBit(self: *TagPage, slot_idx: u16) void {
        const word_idx = slot_idx / bits_per_word;
        const bit_idx: u6 = @intCast(slot_idx % bits_per_word);
        self.tag_bits[word_idx] |= @as(u64, 1) << bit_idx;
    }

    /// Clear a bit at the given slot index
    fn clearBit(self: *TagPage, slot_idx: u16) void {
        const word_idx = slot_idx / bits_per_word;
        const bit_idx: u6 = @intCast(slot_idx % bits_per_word);
        self.tag_bits[word_idx] &= ~(@as(u64, 1) << bit_idx);
    }
};

/// Storage for tag components (zero-sized marker components).
///
/// TagStorage is optimized for components with no data (empty structs).
/// It uses a paged sparse layout for O(1) presence checking and a packed entity array
/// for efficient iteration. Unlike SparseSet, it stores no component data,
/// only tracking which entities have the tag.
///
/// Memory layout:
/// - Paged sparse array: Pages allocated on-demand (16.5KB per page)
/// - ArrayList(Entity): Packed array of entities with this tag for iteration
///
/// Each page contains:
/// - Bitset: 512 bytes (4096 bits, one per entity in page)
/// - Reverse indices: 16KB (4096 u32 values mapping entity index -> packed array index)
///
/// Use cases:
/// - Marker components (e.g., `const Player = struct {};`)
/// - State flags (e.g., `const Disabled = struct {};`)
/// - Group membership (e.g., `const Enemy = struct {};`)
///
/// TagStorage specializes zero-sized marker components; `C` must be an empty struct or tag.
/// Uses a paged bitset plus packed entity array (swap-remove) so iteration order is unstable.
/// Stores no component payload—only presence bits and reverse indices.
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
        tag_pages: [max_pages]?*TagPage, // Paged sparse array

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
        /// All entities and pages will be deallocated.
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
        /// Reserves both packed entity array and sparse pages.
        ///
        /// Complexity: O(1) if capacity is already sufficient, otherwise O(n) where n = new capacity.
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

            // Pre-allocate sparse pages
            const required_pages = (capacity + page_size - 1) / page_size;
            const max_page = @min(required_pages, max_pages);
            for (0..max_page) |page_idx| {
                if (self.tag_pages[page_idx] == null) {
                    const new_page = try self.allocator.create(TagPage);
                    new_page.* = TagPage.init();
                    self.tag_pages[page_idx] = new_page;
                }
            }
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
            const page_idx = getIndex(entity) >> page_shift;
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

            // Get or create page
            const page = try self.getOrCreatePage(entity);

            // Check if already set
            if (page.isSet(slot_idx)) return;

            // Add to packed array
            const packed_index = @as(u32, @intCast(self.packed_array.items.len));
            try self.packed_array.append(self.allocator, entity);

            // Set bit and reverse index
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

            // Get page (return if not allocated or bit not set)
            const page = self.tag_pages[page_idx] orelse return;
            if (!page.isSet(slot_idx)) return;

            const packed_index = page.sparse_to_dense[slot_idx];

            // Read the last element BEFORE swapRemove (which will move it)
            const last_element_index = self.packed_array.items.len - 1;
            const will_swap = packed_index < last_element_index;
            const last_entity = if (will_swap) self.packed_array.items[last_element_index] else undefined;

            // Remove from packed array
            _ = self.packed_array.swapRemove(packed_index);

            // Clear bit and invalidate reverse index
            page.clearBit(slot_idx);
            page.sparse_to_dense[slot_idx] = std.math.maxInt(u32);

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

        /// Clear all tags and deallocate all pages.
        /// Complexity: O(num_pages)
        pub fn clear(self: *Self) void {
            // Free all allocated pages
            for (self.tag_pages) |maybe_page| {
                const page = maybe_page orelse continue;
                self.allocator.destroy(page);
            }
            self.tag_pages = [_]?*TagPage{null} ** max_pages;
            self.packed_array.clearRetainingCapacity();
        }
    };
}
