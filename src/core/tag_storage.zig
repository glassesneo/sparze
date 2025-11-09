const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const DynamicBitSet = std.DynamicBitSetUnmanaged;
const entity_module = @import("entity.zig");
pub const max_entities = entity_module.max_entities;
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;
const EntityIndex = entity_module.EntityIndex;
const EntityVersion = entity_module.EntityVersion;
const getIndex = entity_module.getIndex;
const getVersion = entity_module.getVersion;

/// Storage for tag components (zero-sized marker components).
///
/// TagStorage is optimized for components with no data (empty structs).
/// It uses a bit set for O(1) presence checking and a packed entity array
/// for efficient iteration. Unlike SparseSet, it stores no component data,
/// only tracking which entities have the tag.
///
/// Memory layout:
/// - DynamicBitSet: One bit per entity index for fast contains() checks
/// - ArrayList(Entity): Packed array of entities with this tag for iteration
/// - ArrayList(u32): Reverse index mapping entity index -> packed array index for O(1) removal
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
        tag_bit_set: DynamicBitSet,
        sparse_to_dense: ArrayList(u32), // Reverse index: entity index -> packed array index

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
                .tag_bit_set = .{},
                .sparse_to_dense = .{},
            };
        }

        /// Deinitialize TagStorage, freeing internal buffers.
        /// All entities and bit set data will be deallocated.
        pub fn deinit(self: *Self) void {
            self.packed_array.deinit(self.allocator);
            self.tag_bit_set.deinit(self.allocator);
            self.sparse_to_dense.deinit(self.allocator);
        }

        /// Reserve capacity for the specified number of tags to reduce reallocations.
        /// Useful before bulk inserts (e.g., when loading a scene).
        /// Reserves both packed entity array and reverse index.
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
            try self.sparse_to_dense.ensureTotalCapacity(self.allocator, capacity);
        }

        fn castEntityIndex(entity: Entity) usize {
            return @intCast(getIndex(entity));
        }

        /// Mark an entity as having this tag component.
        /// If the entity already has the tag, this is a no-op.
        ///
        /// Complexity: O(1) amortized (may resize bit set or packed array)
        ///
        /// Example:
        /// ```zig
        /// const entity = world.createEntity();
        /// try storage.set(entity); // Entity now has tag
        /// ```
        pub fn set(self: *Self, entity: Entity) !void {
            const index = castEntityIndex(entity);

            // Ensure bit set capacity first
            if (index >= self.tag_bit_set.capacity()) {
                try self.tag_bit_set.resize(self.allocator, index + 1, false);
            }

            // Ensure reverse index capacity matches bit set capacity
            if (index >= self.sparse_to_dense.capacity) {
                try self.sparse_to_dense.ensureTotalCapacity(self.allocator, index + 1);
                // Initialize new slots to max u32 (sentinel for unset)
                const old_len = self.sparse_to_dense.items.len;
                try self.sparse_to_dense.resize(self.allocator, index + 1);
                @memset(self.sparse_to_dense.items[old_len..], std.math.maxInt(u32));
            } else if (index >= self.sparse_to_dense.items.len) {
                // Capacity sufficient but length too short; extend length to index+1
                const old_len = self.sparse_to_dense.items.len;
                try self.sparse_to_dense.resize(self.allocator, index + 1);
                @memset(self.sparse_to_dense.items[old_len..], std.math.maxInt(u32));
            }

            // Check if already set
            if (self.tag_bit_set.isSet(index)) return;

            const packed_index = @as(u32, @intCast(self.packed_array.items.len));
            try self.packed_array.append(self.allocator, entity);
            self.tag_bit_set.set(index);
            self.sparse_to_dense.items[index] = packed_index;
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
            const index = castEntityIndex(entity);

            // Check bounds and if already unset
            if (index >= self.tag_bit_set.capacity()) return;
            if (!self.tag_bit_set.isSet(index)) return;

            const packed_index = self.sparse_to_dense.items[index];

            // Read the last element BEFORE swapRemove (which will move it)
            const last_element_index = self.packed_array.items.len - 1;
            const will_swap = packed_index < last_element_index;
            const last_entity = if (will_swap) self.packed_array.items[last_element_index] else undefined;

            _ = self.packed_array.swapRemove(packed_index);
            self.tag_bit_set.unset(index);
            self.sparse_to_dense.items[index] = std.math.maxInt(u32); // Invalidate reverse index

            // Update the reverse index for the swapped entity
            if (will_swap) {
                const last_entity_index = castEntityIndex(last_entity);
                self.sparse_to_dense.items[last_entity_index] = packed_index;
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
            const index = castEntityIndex(entity);
            if (index >= self.tag_bit_set.capacity()) return false;
            return self.tag_bit_set.isSet(index);
        }
    };
}

