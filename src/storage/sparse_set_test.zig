const std = @import("std");
const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;
const EntityRegistry = entity_module.EntityRegistry;
const getIndex = entity_module.getIndex;
const getVersion = entity_module.getVersion;

const SparseSet = @import("sparse_set.zig").SparseSet;

test "SparseSet basic operations" {
    const TestComponent = struct {
        value: i32,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = EntityRegistry.init();

    var sparseSet = SparseSet(TestComponent).init(allocator);
    defer sparseSet.deinit();

    const e1 = registry.create();
    const e2 = registry.create();
    const e3 = registry.create();

    try std.testing.expect(!sparseSet.contains(e1));

    try sparseSet.insert(e1, .{ .value = 10 });
    try sparseSet.insert(e2, .{ .value = 20 });
    try std.testing.expect(sparseSet.contains(e1));
    try std.testing.expect(sparseSet.contains(e2));
    try std.testing.expect(!sparseSet.contains(e3));

    if (sparseSet.get(e1)) |component| {
        try std.testing.expectEqual(@as(i32, 10), component.value);
    } else {
        try std.testing.expect(false);
    }

    try sparseSet.insert(e1, .{ .value = 15 });
    if (sparseSet.get(e1)) |component| {
        try std.testing.expectEqual(@as(i32, 15), component.value);
    } else {
        try std.testing.expect(false);
    }

    sparseSet.remove(e1);
    try std.testing.expect(!sparseSet.contains(e1));
    try std.testing.expect(sparseSet.contains(e2));

    sparseSet.remove(e3);
}

test "SparseSet removal consistency" {
    const TestComp = struct { v: usize };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();
    const total = 10;
    var ids = [_]Entity{undefined} ** total;
    for (0..total) |i| {
        ids[i] = registry.create();
        try set.insert(ids[i], .{ .v = i });
    }

    const mid = ids[5];
    set.remove(mid);
    try std.testing.expect(!set.contains(mid));

    for (0..total) |i| {
        if (i == 5) continue;
        const comp = set.get(ids[i]).?;
        try std.testing.expectEqual(@as(usize, i), comp.v);
    }

    try std.testing.expectEqual(@as(usize, total - 1), set.components.items.len);
}

test "SparseSet pagination with sparse entities" {
    const TestComp = struct { v: usize };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();

    var entities: [3]Entity = undefined;

    entities[0] = registry.create();

    for (0..4096) |_| _ = registry.create();
    entities[1] = registry.create();

    for (0..4095) |_| _ = registry.create();
    entities[2] = registry.create();

    try set.insert(entities[0], .{ .v = 100 });
    try set.insert(entities[1], .{ .v = 200 });
    try set.insert(entities[2], .{ .v = 300 });

    try std.testing.expect(set.contains(entities[0]));
    try std.testing.expect(set.contains(entities[1]));
    try std.testing.expect(set.contains(entities[2]));

    try std.testing.expectEqual(@as(usize, 100), set.get(entities[0]).?.v);
    try std.testing.expectEqual(@as(usize, 200), set.get(entities[1]).?.v);
    try std.testing.expectEqual(@as(usize, 300), set.get(entities[2]).?.v);

    set.remove(entities[1]);
    try std.testing.expect(set.contains(entities[0]));
    try std.testing.expect(!set.contains(entities[1]));
    try std.testing.expect(set.contains(entities[2]));

    try std.testing.expectEqual(@as(usize, 100), set.get(entities[0]).?.v);
    try std.testing.expectEqual(@as(usize, 300), set.get(entities[2]).?.v);
}

test "SparseSet entity version validation" {
    const TestComp = struct { v: usize };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();

    const e1 = registry.create();
    registry.destroy(e1);
    const e2 = registry.create();

    try std.testing.expectEqual(getIndex(e1), getIndex(e2));
    try std.testing.expect(getVersion(e2) > getVersion(e1));

    try set.insert(e2, .{ .v = 42 });
    try std.testing.expect(set.contains(e2));

    try std.testing.expect(!set.contains(e1));
    try std.testing.expect(set.get(e1) == null);

    try std.testing.expectEqual(@as(usize, 42), set.get(e2).?.v);
}

test "SparseSet pointer access methods" {
    const TestComp = struct { value: i32, count: u32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();
    const entity = registry.create();

    try std.testing.expect(set.getPtr(entity) == null);
    try std.testing.expect(set.getPtrMut(entity) == null);

    try set.insert(entity, .{ .value = 100, .count = 5 });

    const const_ptr = set.getPtr(entity).?;
    try std.testing.expectEqual(@as(i32, 100), const_ptr.value);
    try std.testing.expectEqual(@as(u32, 5), const_ptr.count);

    const mut_ptr = set.getPtrMut(entity).?;
    mut_ptr.value = 200;
    mut_ptr.count = 10;

    const component = set.get(entity).?;
    try std.testing.expectEqual(@as(i32, 200), component.value);
    try std.testing.expectEqual(@as(u32, 10), component.count);

    const verify_ptr = set.getPtr(entity).?;
    try std.testing.expectEqual(@as(i32, 200), verify_ptr.value);
    try std.testing.expectEqual(@as(u32, 10), verify_ptr.count);
}

test "SparseSet pointer consistency across operations" {
    const TestComp = struct { id: u64 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();
    const entity1 = registry.create();
    const entity2 = registry.create();
    const entity3 = registry.create();

    try set.insert(entity1, .{ .id = 111 });
    try set.insert(entity2, .{ .id = 222 });
    try set.insert(entity3, .{ .id = 333 });

    const ptr1_before = set.getPtr(entity1).?;
    const ptr3_before = set.getPtr(entity3).?;

    try std.testing.expectEqual(@as(u64, 111), ptr1_before.id);
    try std.testing.expectEqual(@as(u64, 333), ptr3_before.id);

    set.remove(entity2);

    const ptr1_after = set.getPtr(entity1).?;
    const ptr3_after = set.getPtr(entity3).?;

    try std.testing.expectEqual(@as(u64, 111), ptr1_after.id);
    try std.testing.expectEqual(@as(u64, 333), ptr3_after.id);

    try std.testing.expect(set.getPtr(entity2) == null);
    try std.testing.expect(set.getPtrMut(entity2) == null);
}
