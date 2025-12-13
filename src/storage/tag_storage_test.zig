const std = @import("std");
const testing = std.testing;
const TagStorage = @import("tag_storage.zig").TagStorage;
const Entity = @import("../entity/entity.zig").Entity;

const TestTag = struct {};

// Helper to create entity with given index and version
fn makeEntity(index: u16, version: u16) Entity {
    return Entity.init(index, version);
}

test "TagStorage - basic set and contains" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    const e1 = makeEntity(0, 0);
    const e2 = makeEntity(1, 0);
    const e3 = makeEntity(2, 0);

    // Initially no entities have the tag
    try testing.expect(!storage.contains(e1));
    try testing.expect(!storage.contains(e2));
    try testing.expect(!storage.contains(e3));

    // Set tags
    try storage.set(e1);
    try storage.set(e2);

    try testing.expect(storage.contains(e1));
    try testing.expect(storage.contains(e2));
    try testing.expect(!storage.contains(e3));

    // Setting again is a no-op
    try storage.set(e1);
    try testing.expect(storage.contains(e1));
}

test "TagStorage - unset removes tag" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    const e1 = makeEntity(5, 0);
    const e2 = makeEntity(10, 0);

    try storage.set(e1);
    try storage.set(e2);

    try testing.expect(storage.contains(e1));
    try testing.expect(storage.contains(e2));

    storage.unset(e1);

    try testing.expect(!storage.contains(e1));
    try testing.expect(storage.contains(e2));

    // Unsetting again is a no-op
    storage.unset(e1);
    try testing.expect(!storage.contains(e1));
}

test "TagStorage - pagination across multiple pages" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    // Test entities in different pages (page_size = 4096)
    const e_page0 = makeEntity(100, 0); // Page 0: index 100
    const e_page1 = makeEntity(5000, 0); // Page 1: index 5000 (5000 / 4096 = 1)
    const e_page2 = makeEntity(10000, 0); // Page 2: index 10000 (10000 / 4096 = 2)

    // All should be unset initially
    try testing.expect(!storage.contains(e_page0));
    try testing.expect(!storage.contains(e_page1));
    try testing.expect(!storage.contains(e_page2));

    // Set entities in different pages
    try storage.set(e_page0);
    try storage.set(e_page1);
    try storage.set(e_page2);

    // All should be set now
    try testing.expect(storage.contains(e_page0));
    try testing.expect(storage.contains(e_page1));
    try testing.expect(storage.contains(e_page2));

    // Verify packed array has all 3 entities
    try testing.expectEqual(@as(usize, 3), storage.packed_array.items.len);

    // Unset from middle page
    storage.unset(e_page1);
    try testing.expect(storage.contains(e_page0));
    try testing.expect(!storage.contains(e_page1));
    try testing.expect(storage.contains(e_page2));
}

test "TagStorage - swapRemove correctness" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    const e1 = makeEntity(100, 0);
    const e2 = makeEntity(200, 0);
    const e3 = makeEntity(5000, 0); // Different page

    try storage.set(e1);
    try storage.set(e2);
    try storage.set(e3);

    try testing.expectEqual(@as(usize, 3), storage.packed_array.items.len);

    // Remove first entity (should swap with e3, the last one)
    storage.unset(e1);

    try testing.expectEqual(@as(usize, 2), storage.packed_array.items.len);
    try testing.expect(!storage.contains(e1));
    try testing.expect(storage.contains(e2));
    try testing.expect(storage.contains(e3));

    // After swap, e3 should still be accessible
    try testing.expect(storage.contains(e3));
}

test "TagStorage - memory efficiency with high entity IDs" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    // Test with very high entity index - the old implementation would allocate
    // O(max_entity_index) memory, causing catastrophic spikes for sparse IDs.
    // The paged implementation only allocates pages as needed.

    // Use a high index within u16 range that's in a different page
    const high_index: u16 = 50_000; // Page 12 (50000 / 4096 = 12.2)
    const high_entity = makeEntity(high_index, 0);

    try storage.set(high_entity);
    try testing.expect(storage.contains(high_entity));

    // Should only allocate 1 page (16.5KB) not 50K entries
    // We can't directly measure memory, but we can verify it works
    try testing.expectEqual(@as(usize, 1), storage.packed_array.items.len);
}

test "TagStorage - empty storage operations" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    const e1 = makeEntity(0, 0);

    // Operations on empty storage
    try testing.expect(!storage.contains(e1));
    storage.unset(e1); // Should not crash

    try testing.expectEqual(@as(usize, 0), storage.packed_array.items.len);
}

test "TagStorage - iteration over tagged entities" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    const e1 = makeEntity(10, 0);
    const e2 = makeEntity(5000, 0);
    const e3 = makeEntity(10000, 0);

    try storage.set(e1);
    try storage.set(e2);
    try storage.set(e3);

    // Verify we can iterate through packed array
    var found_count: usize = 0;
    var found_e1 = false;
    var found_e2 = false;
    var found_e3 = false;

    for (storage.packed_array.items) |entity| {
        found_count += 1;
        if (entity == e1) found_e1 = true;
        if (entity == e2) found_e2 = true;
        if (entity == e3) found_e3 = true;
    }

    try testing.expectEqual(@as(usize, 3), found_count);
    try testing.expect(found_e1);
    try testing.expect(found_e2);
    try testing.expect(found_e3);
}

test "TagStorage - sequential removal maintains consistency" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    // This test catches the swapRemove bug from filter_test.zig:1494
    const e1 = makeEntity(0, 0);
    const e2 = makeEntity(1, 0);
    const e3 = makeEntity(2, 0);

    try storage.set(e1);
    try storage.set(e2);
    try storage.set(e3);

    // Remove in sequence
    storage.unset(e1);
    try testing.expect(!storage.contains(e1));
    try testing.expect(storage.contains(e2));
    try testing.expect(storage.contains(e3));

    storage.unset(e2);
    try testing.expect(!storage.contains(e1));
    try testing.expect(!storage.contains(e2));
    try testing.expect(storage.contains(e3));

    storage.unset(e3);
    try testing.expect(!storage.contains(e1));
    try testing.expect(!storage.contains(e2));
    try testing.expect(!storage.contains(e3));

    try testing.expectEqual(@as(usize, 0), storage.packed_array.items.len);
}

test "TagStorage - page boundary conditions" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    // Test entities at page boundaries (page_size = 4096)
    const e_boundary0 = makeEntity(4095, 0); // Last entity in page 0
    const e_boundary1 = makeEntity(4096, 0); // First entity in page 1
    const e_boundary2 = makeEntity(8191, 0); // Last entity in page 1
    const e_boundary3 = makeEntity(8192, 0); // First entity in page 2

    try storage.set(e_boundary0);
    try storage.set(e_boundary1);
    try storage.set(e_boundary2);
    try storage.set(e_boundary3);

    try testing.expect(storage.contains(e_boundary0));
    try testing.expect(storage.contains(e_boundary1));
    try testing.expect(storage.contains(e_boundary2));
    try testing.expect(storage.contains(e_boundary3));

    storage.unset(e_boundary1);
    try testing.expect(storage.contains(e_boundary0));
    try testing.expect(!storage.contains(e_boundary1));
    try testing.expect(storage.contains(e_boundary2));
    try testing.expect(storage.contains(e_boundary3));
}

test "TagStorage - reserve and clear" {
    const allocator = testing.allocator;
    var storage = TagStorage(TestTag).init(allocator);
    defer storage.deinit();

    // Reserve capacity
    try storage.reserve(100);

    const e1 = makeEntity(0, 0);
    const e2 = makeEntity(1, 0);

    try storage.set(e1);
    try storage.set(e2);

    try testing.expectEqual(@as(usize, 2), storage.packed_array.items.len);

    // Clear should remove all tags and deallocate pages
    storage.clear();
    try testing.expectEqual(@as(usize, 0), storage.packed_array.items.len);
    try testing.expect(!storage.contains(e1));
    try testing.expect(!storage.contains(e2));
}
