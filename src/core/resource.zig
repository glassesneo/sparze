const std = @import("std");
const Entity = @import("entity.zig").Entity;

pub const AbstractResource = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        getFn: *const fn (*anyopaque) *anyopaque,
        setFn: *const fn (*anyopaque, *anyopaque) void,
        deinitFn: *const fn (*anyopaque) void,
    };

    pub fn get(self: *const AbstractResource, comptime T: type) T {
        const typed_ptr = castTo(T, self.vtable.getFn(self.instance));
        return typed_ptr.*;
    }

    pub fn getPtr(self: *AbstractResource, comptime T: type) *T {
        return castTo(T, self.vtable.getFn(self.instance));
    }

    pub fn set(self: *const AbstractResource, value: *anyopaque) void {
        self.vtable.setFn(self.instance, value);
    }

    pub fn deinit(self: *const AbstractResource) void {
        return self.vtable.deinitFn(self.instance);
    }

    fn castTo(comptime T: type, ptr: *anyopaque) *T {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn init(comptime T: type, instance: *T) !AbstractResource {
        const vtable = comptime VTable{
            .getFn = struct {
                fn get(ptr: *anyopaque) *anyopaque {
                    const self = castTo(T, ptr);
                    return @ptrCast(&self.value);
                }
            }.get,
            .setFn = struct {
                fn set(ptr: *anyopaque, resource_ptr: *anyopaque) void {
                    const self = castTo(T, ptr);
                    const value = castTo(T.ResourceType, resource_ptr);
                    self.value = value.*;
                }
            }.set,
            .deinitFn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const self = castTo(T, ptr);
                    return self.deinit();
                }
            }.deinit,
        };
        return .{
            .vtable = &vtable,
            .instance = instance,
        };
    }
};

pub fn Resource(comptime T: type) type {
    return struct {
        value: T,
        allocator: std.mem.Allocator,
        const Self = @This();
        pub const ResourceType = T;

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .value = undefined,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn abstract(self: *Self) !AbstractResource {
            return try AbstractResource.init(Self, self);
        }
    };
}

test "Resource basic get/set/deinit" {
    const MyType = struct { value: i32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = try Resource(MyType).init(arena.allocator());
    defer res.deinit();

    res.value = MyType{ .value = 42 };
    try std.testing.expectEqual(@as(i32, 42), res.value.value);
}

test "AbstractResource get/set" {
    const MyType = struct {
        const Self = @This();
        value: i32,
        pub fn deinit(self: *Self) void {
            _ = self;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = try Resource(MyType).init(arena.allocator());
    defer res.deinit();
    var abs = try res.abstract();

    var my = (MyType{ .value = 10 });
    abs.set(&my);

    try std.testing.expectEqual(@as(i32, 10), abs.get(MyType).value);

    var new_val = MyType{ .value = 99 };
    abs.set(&new_val);
    try std.testing.expectEqual(@as(i32, 99), abs.get(MyType).value);

    // Test getPtr through abstract interface
    const resource_ptr = abs.getPtr(MyType);
    try std.testing.expectEqual(@as(i32, 99), resource_ptr.value);

    // Test in-place modification through pointer
    resource_ptr.value = 200;

    // Verify the modification persisted
    try std.testing.expectEqual(@as(i32, 200), abs.get(MyType).value);
}
