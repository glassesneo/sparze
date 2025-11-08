const std = @import("std");
const sparze = @import("src/root.zig");

// Test types with different serialization settings
const PersistentComponent = struct { value: i32 };
const ExcludedComponent = struct {
    temp_data: [100]u8,
    pub const serialized = false; // This should be excluded
};

const PersistentResource = struct { config: i32 };
const ExcludedResource = struct {
    session_id: u64,
    pub const serialized = false; // This should be excluded
};

const PersistentEvent = struct { data: i32 };
const ExcludedEvent = struct {
    ephemeral: bool,
    pub const serialized = false; // This should be excluded
};

const TestWorld = sparze.World(
    struct { PersistentComponent, ExcludedComponent },
    struct { PersistentResource, ExcludedResource },
    struct { PersistentEvent, ExcludedEvent },
);

test "serialization exclusion basic test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Set resources
    try world.setResource(PersistentResource, .{ .config = 42 });
    try world.setResource(ExcludedResource, .{ .session_id = 12345 });

    // Create entity with both component types
    const entity = world.createEntity();
    try world.addComponent(entity, PersistentComponent, .{ .value = 100 });
    try world.addComponent(entity, ExcludedComponent, .{ .temp_data = undefined });

    // Verify trait function works
    try std.testing.expect(sparze.serialization.shouldSerialize(PersistentComponent));
    try std.testing.expect(!sparze.serialization.shouldSerialize(ExcludedComponent));
    try std.testing.expect(sparze.serialization.shouldSerialize(PersistentResource));
    try std.testing.expect(!sparze.serialization.shouldSerialize(ExcludedResource));
    try std.testing.expect(sparze.serialization.shouldSerialize(PersistentEvent));
    try std.testing.expect(!sparze.serialization.shouldSerialize(ExcludedEvent));

    std.debug.print("✅ All shouldSerialize() checks passed\n", .{});

    // Test actual serialization to ensure excluded types are skipped
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    try world.serialize(buffer.writer(allocator));
    std.debug.print("✅ Serialization completed (excluded types should be skipped)\n", .{});

    // Reset resources to different values
    try world.setResource(PersistentResource, .{ .config = 999 });
    try world.setResource(ExcludedResource, .{ .session_id = 99999 });

    // Deserialize
    var fbs = std.io.fixedBufferStream(buffer.items);
    try world.deserialize(fbs.reader());

    // Verify that persistent data was restored but excluded data was reset
    const restored_persistent = world.getResource(PersistentResource);
    try std.testing.expectEqual(@as(i32, 42), restored_persistent.config);

    const restored_excluded = world.getResource(ExcludedResource);
    // Excluded resources should have their default/zero values after deserialization
    try std.testing.expectEqual(@as(u64, 0), restored_excluded.session_id);

    std.debug.print("✅ Deserialization correctly excluded transient data\n", .{});
}

pub fn main() !void {
    std.debug.print("Running serialization exclusion test...\n", .{});
}
