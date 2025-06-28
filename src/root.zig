pub const Entity = @import("core/entity.zig").Entity;
pub const World = @import("core/world.zig").World;

comptime {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
