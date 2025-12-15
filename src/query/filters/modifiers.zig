const common = @import("common.zig");
const ModifierType = common.ModifierType;

pub fn Exclude(comptime C: type) type {
    return struct {
        pub const Component = C;
        pub const modifier_type: ModifierType = .exclude;
    };
}
