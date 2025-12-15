const common = @import("common.zig");
const FilterType = common.FilterType;

pub fn Resource(comptime T: type) type {
    return struct {
        pub const filter_type: FilterType = .resource;
        pub const ResourceType = T;

        value: *const T,

        pub fn init(resource_ptr: *const T) @This() {
            return .{ .value = resource_ptr };
        }
    };
}

pub fn ResourceMut(comptime T: type) type {
    return struct {
        pub const filter_type: FilterType = .resource_mut;
        pub const ResourceType = T;

        value: *T,

        pub fn init(resource_ptr: *T) @This() {
            return .{ .value = resource_ptr };
        }
    };
}
