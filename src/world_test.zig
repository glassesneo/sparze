test {
    // These tests cover behavior not already exercised by the inline `test` blocks in `world.zig`.
    _ = @import("world_group_test.zig");
    _ = @import("world_resource_test.zig");
}
