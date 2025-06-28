const std = @import("std");
const Entity = @import("entity.zig").Entity;

pub const AbstractSparseSet = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        deinitFn: *const fn (*anyopaque) void,
    };

    pub fn insert(self: *const AbstractSparseSet, entity: Entity, component: *anyopaque) !void {
        return self.vtable.insertFn(self.instance, entity, component);
    }

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime T: type) ?T {
        if (self.vtable.getFn(self.instance, entity)) |component| {
            const typedPtr = castTo(T, component);
            return typedPtr.*;
        }
        return null;
    }

    pub fn deinit(self: *const AbstractSparseSet) void {
        return self.vtable.deinitFn(self.instance);
    }

    fn castTo(comptime T: type, ptr: *anyopaque) *T {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn init(comptime T: type, instance: *T) AbstractSparseSet {
        const vtable = comptime VTable{
            .insertFn = struct {
                fn insert(ptr: *anyopaque, entity: Entity, cPtr: *anyopaque) !void {
                    const self = castTo(T, ptr);
                    const component = castTo(T.Component, cPtr);
                    return self.insert(entity, component.*);
                }
            }.insert,
            .getFn = struct {
                fn get(ptr: *anyopaque, entity: Entity) ?*anyopaque {
                    const self = castTo(T, ptr);
                    if (self.indexTable.get(entity.id)) |index| {
                        return @ptrCast(&self.components.items[index]);
                    }
                    return null;
                }
            }.get,
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

pub fn SparseSet(comptime C: type) type {
    return struct {
        components: std.ArrayList(C),
        indexTable: std.AutoHashMap(usize, u32),
        const Self = @This();
        pub const Component = C;

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .components = .init(allocator),
                .indexTable = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.components.deinit();
            self.indexTable.deinit();
        }

        fn contains(self: Self, entity: Entity) bool {
            return self.indexTable.contains(entity.id);
        }

        fn insert(self: *Self, entity: Entity, component: C) !void {
            if (self.indexTable.get(entity.id)) |index| {
                self.components.items[index] = component;
            } else {
                try self.components.append(component);

                const newIndex: u32 = self.indexTable.count();
                try self.indexTable.put(entity.id, newIndex);
            }
        }

        pub fn abstract(self: *Self) AbstractSparseSet {
            return AbstractSparseSet.init(Self, self);
        }
    };
}
