const std = @import("std");

const world_module = @import("world.zig");
const World = world_module.World;


test "Groups: order-insensitive matching" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Health = struct { hp: i32 };

    // Define groups with different component ordering
    const GroupAB = struct { Position, Velocity };
    const GroupBA = struct { Velocity, Position };

    const TestWorld = World(
        struct { Position, Velocity, Health },
        struct {},
        struct {},
        .{GroupAB}, // Register with A, B order
    );

    // Verify that both orderings resolve to the same group index
    const idx1 = comptime TestWorld.getGroupIndex(GroupAB);
    const idx2 = comptime TestWorld.getGroupIndex(GroupBA);

    try std.testing.expectEqual(idx1, idx2);
}

test "Groups: deserialization repopulates groups" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    const MovementGroup = struct { Position, Velocity };

    const TestWorld = World(
        struct { Position, Velocity },
        struct {},
        struct {},
        .{MovementGroup},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create world and add entities with components
    var world1 = TestWorld.init(allocator);
    defer world1.deinit();

    const e1 = world1.createEntity();
    const e2 = world1.createEntity();
    const e3 = world1.createEntity();

    try world1.addComponent(e1, Position, .{ .x = 1, .y = 2 });
    try world1.addComponent(e1, Velocity, .{ .x = 0.5, .y = 0.5 });

    try world1.addComponent(e2, Position, .{ .x = 3, .y = 4 });
    try world1.addComponent(e2, Velocity, .{ .x = 1.0, .y = 1.0 });

    try world1.addComponent(e3, Position, .{ .x = 5, .y = 6 });
    // e3 has no Velocity, so it shouldn't be in the group

    // Verify group has 2 entities before serialization
    const pos_id = comptime TestWorld.getComponentId(Position);
    const group_entities_before = world1.component_pool[pos_id].getGroupEntities();
    try std.testing.expectEqual(@as(usize, 2), group_entities_before.len);

    // Serialize to buffer
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);
    try world1.serialize(buffer.writer(allocator));

    // Deserialize to new world
    var world2 = TestWorld.init(allocator);
    defer world2.deinit();

    var stream = std.io.fixedBufferStream(buffer.items);
    try world2.deserialize(stream.reader());

    // Verify groups were repopulated correctly
    const group_entities_after = world2.component_pool[pos_id].getGroupEntities();
    try std.testing.expectEqual(@as(usize, 2), group_entities_after.len);

    // Verify the correct entities are in the group (those with both Position and Velocity)
    var found_e1 = false;
    var found_e2 = false;
    for (group_entities_after) |entity| {
        if (entity.index == e1.index and entity.version == e1.version) found_e1 = true;
        if (entity.index == e2.index and entity.version == e2.version) found_e2 = true;
    }
    try std.testing.expect(found_e1);
    try std.testing.expect(found_e2);
}
