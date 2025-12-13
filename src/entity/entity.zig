const std = @import("std");

/// 32-bit entity handle encoded as [version:16 | index:16].
/// The lower 16 bits select the dense index in the registry; the upper 16 bits are a generation/version guard that invalidates stale handles after destroy().
pub const Entity = u32;
pub const EntityIndex = u16;
pub const EntityVersion = u16;
pub const max_entities = std.math.maxInt(EntityIndex);

pub const index_bits: u5 = 16;
pub const version_bits: u5 = 16;
pub const index_mask: u32 = (1 << index_bits) - 1;
pub const version_mask: u32 = (1 << version_bits) - 1;

/// Extracts the 16-bit index from an Entity identifier.
/// Complexity: O(1).
pub fn getIndex(entity: Entity) EntityIndex {
    return @intCast(entity & index_mask);
}

/// Extracts the 16-bit version from an Entity identifier.
/// Complexity: O(1).
pub fn getVersion(entity: Entity) EntityVersion {
    return @intCast((entity >> index_bits) & version_mask);
}

/// Fixed-capacity entity registry (max_entities) that hands out recyclable entity handles.
/// Maintains an implicit LIFO free list encoded inside the dense slot (next_index_to_recycle) and bumps the version guard on destroy() to detect stale handles.
pub const EntityRegistry = struct {
    entities: [max_entities]Entity,
    next_index: EntityIndex,
    available: EntityIndex,
    next_index_to_recycle: Entity,

    /// Initializes an empty entity registry backed by a fixed-size array.
    pub fn init() EntityRegistry {
        return .{
            .entities = undefined,
            .next_index = 0,
            .available = 0,
            .next_index_to_recycle = undefined,
        };
    }

    /// Allocates a new entity handle.
    /// Reuses a recycled dense index when available; otherwise grows sequentially until max_entities.
    /// Writes the current version into the slot so future isAlive() checks can reject stale generation numbers.
    /// Panics in Debug/ReleaseSafe if allocation would exceed max_entities; in ReleaseFast, exceeding capacity causes out-of-bounds write (undefined behavior).
    pub fn create(self: *EntityRegistry) Entity {
        const index, const version = if (self.available > 0) recycle: {
            // Recycle from the implicit free list.
            const head_index = getIndex(self.next_index_to_recycle);
            const head_value = self.entities[head_index];
            const version = getVersion(head_value);
            const next_index = getIndex(head_value);

            // Advance the head and decrease available count.
            self.next_index_to_recycle = next_index;
            self.available -= 1;
            break :recycle .{ head_index, version };
        } else new: {
            // Create a new identifier with version 0.
            std.debug.assert(self.next_index < max_entities);
            const index: EntityIndex = @intCast(self.next_index);
            const version: EntityVersion = 0;
            self.next_index += 1;
            break :new .{ index, version };
        };

        const entity = makeEntity(index, version);
        self.entities[index] = entity;
        return entity;
    }

    /// Retires an entity and pushes its dense index onto the free list.
    /// Increments the 16-bit version guard so previously issued handles for the same index fail isAlive().
    /// CRITICAL: Must only be called on live entities; calling destroy() twice on the same handle will corrupt the free list (duplicates index, double-increments available counter).
    pub fn destroy(self: *EntityRegistry, entity: Entity) void {
        const index = getIndex(entity);
        const current = self.entities[index];
        const new_version: EntityVersion = getVersion(current) + 1;

        // Link this index to the previous head of the free list.
        const prev_head_index = if (self.available == 0)
            index
        else
            getIndex(self.next_index_to_recycle);

        // Store mixed identifier: upper bits = new version, lower bits = next index in free list.
        self.entities[index] = makeEntity(prev_head_index, new_version);

        // Update head and counters.
        self.next_index_to_recycle = index;
        self.available += 1;
    }

    /// Checks both bounds and version guard for a handle.
    /// Returns false for never-allocated indices or stale generations whose version no longer matches the registry slot.
    pub fn isAlive(self: EntityRegistry, entity: Entity) bool {
        const index = getIndex(entity);
        // If index was never allocated, it's not alive.
        if (index >= self.next_index) return false;
        const i: usize = index;
        const current = self.entities[i];
        // Alive iff the stored slot matches its own index and the version matches.
        return getIndex(current) == index and getVersion(current) == getVersion(entity);
    }

    /// Returns the number of currently alive entities.
    /// Complexity: O(1).
    pub fn aliveCount(self: *const EntityRegistry) usize {
        return @as(usize, self.next_index - self.available);
    }

    fn makeEntity(index: EntityIndex, version: EntityVersion) Entity {
        return (@as(u32, version) << index_bits) | (@as(u32, index) & index_mask);
    }

    test "makeEntity packs index and version correctly" {
        const index: EntityIndex = 12345;
        const version: EntityVersion = 42;
        const e = makeEntity(index, version);
        try std.testing.expect(getIndex(e) == index);
        try std.testing.expect(getVersion(e) == version);
    }

    test "getId and getVersion extract correct values" {
        const e = makeEntity(65535, 65535);
        try std.testing.expect(getIndex(e) == 65535);
        try std.testing.expect(getVersion(e) == 65535);

        const e2 = makeEntity(0, 0);
        try std.testing.expect(getIndex(e2) == 0);
        try std.testing.expect(getVersion(e2) == 0);
    }
};

test "Entity basic operations" {
    var registry = EntityRegistry.init();

    const e1 = registry.create();
    const e2 = registry.create();
    const e3 = registry.create();
    try std.testing.expect(getIndex(e1) == 0 and getVersion(e1) == 0);
    try std.testing.expect(getIndex(e2) == 1 and getVersion(e2) == 0);
    try std.testing.expect(getIndex(e3) == 2 and getVersion(e3) == 0);
    try std.testing.expect(registry.aliveCount() == 3);
    try std.testing.expect(registry.isAlive(e1));
    try std.testing.expect(registry.isAlive(e2));
    try std.testing.expect(registry.isAlive(e3));

    registry.destroy(e2);
    const e4 = registry.create();
    try std.testing.expect(getIndex(e4) == 1);
    try std.testing.expect(getVersion(e4) == getVersion(e2) + 1);
    try std.testing.expect(!registry.isAlive(e2));
    try std.testing.expect(registry.isAlive(e4));
    try std.testing.expect(registry.aliveCount() == 3);

    registry.destroy(e1);
    registry.destroy(e3);
    const e5 = registry.create();
    try std.testing.expect(getIndex(e5) == 2 and getVersion(e5) == getVersion(e3) + 1);

    const e6 = registry.create();
    try std.testing.expect(getIndex(e6) == 0 and getVersion(e6) == getVersion(e1) + 1);
    try std.testing.expect(registry.isAlive(e5));
    try std.testing.expect(registry.isAlive(e6));
    try std.testing.expect(registry.aliveCount() == 3);
}

test "Entity recycle twice bumps version twice" {
    var registry = EntityRegistry.init();
    const e0 = registry.create();
    const idx = getIndex(e0);
    const v0 = getVersion(e0);
    registry.destroy(e0);
    const e1 = registry.create();
    try std.testing.expect(getIndex(e1) == idx);
    try std.testing.expect(getVersion(e1) == v0 + 1);
    registry.destroy(e1);
    const e2 = registry.create();
    try std.testing.expect(getIndex(e2) == idx);
    try std.testing.expect(getVersion(e2) == v0 + 2);
}

test "Destroy all then reuse LIFO then grow" {
    var registry = EntityRegistry.init();
    const a = registry.create(); // 0|0
    const b = registry.create(); // 1|0
    const c = registry.create(); // 2|0
    const d = registry.create(); // 3|0
    registry.destroy(a);
    registry.destroy(b);
    registry.destroy(c);
    registry.destroy(d);
    const r0 = registry.create();
    const r1 = registry.create();
    const r2 = registry.create();
    const r3 = registry.create();
    try std.testing.expect(getIndex(r0) == 3 and getVersion(r0) == 1);
    try std.testing.expect(getIndex(r1) == 2 and getVersion(r1) == 1);
    try std.testing.expect(getIndex(r2) == 1 and getVersion(r2) == 1);
    try std.testing.expect(getIndex(r3) == 0 and getVersion(r3) == 1);
    const e4 = registry.create();
    try std.testing.expect(getIndex(e4) == 4 and getVersion(e4) == 0);
}
