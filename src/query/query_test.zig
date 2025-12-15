test {
    _ = @import("exclude_test.zig");
    _ = @import("basic_query_group_test.zig");
    _ = @import("tag_query_test.zig");
    _ = @import("iteration_cross_combinations_test.zig");
    _ = @import("iteration_cross_product_test.zig");
    _ = @import("liveness_test.zig");
    _ = @import("group_free_test.zig");
}
