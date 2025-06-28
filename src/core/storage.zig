const std = @import("std");

const Entity = @import("entity.zig").Entity;

const sparse_set = @import("sparse_set.zig");
const SparseSet = sparse_set.SparseSet;
const AbstractSparseSet = sparse_set.AbstractSparseSet;

pub const SparseSetStorage = struct {
    sparseSets: std.StringHashMap(AbstractSparseSet),
    componentStorage: std.StringHashMap(StorageInfo),
    allocator: std.mem.Allocator,

    const StorageInfo = struct {
        ptr: *anyopaque,
        destroyFn: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn destroyTypedStorage(comptime T: type) *const fn (*anyopaque, std.mem.Allocator) void {
        return struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const typedPtr = @as(*T, @ptrCast(@alignCast(ptr)));
                allocator.destroy(typedPtr);
            }
        }.destroy;
    }

    pub fn init(allocator: std.mem.Allocator) SparseSetStorage {
        return SparseSetStorage{
            .sparseSets = .init(allocator),
            .componentStorage = .init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *SparseSetStorage) void {
        var iter = self.componentStorage.iterator();
        while (iter.next()) |entry| {
            const typeName = entry.key_ptr.*;
            const storageInfo = entry.value_ptr.*;

            if (self.sparseSets.get(typeName)) |sparseSet| {
                sparseSet.deinit();

                storageInfo.destroyFn(storageInfo.ptr, self.allocator);
            }
        }

        self.sparseSets.deinit();
        self.componentStorage.deinit();
    }

    pub fn attachComponent(self: *SparseSetStorage, entity: Entity, comptime C: type, component: C) !void {
        const typeName = @typeName(C);
        if (!self.sparseSets.contains(typeName)) {
            var sparseSet = try self.allocator.create(SparseSet(C));
            sparseSet.* = SparseSet(C).init(self.allocator);

            const storageInfo = StorageInfo{
                .ptr = @ptrCast(sparseSet),
                .destroyFn = destroyTypedStorage(SparseSet(C)),
            };
            try self.componentStorage.put(typeName, storageInfo);

            const abstractSparseSet = sparseSet.abstract();
            try self.sparseSets.put(typeName, abstractSparseSet);
        }

        var componentCopy = component;
        try self.sparseSets.get(typeName).?.insert(entity, &componentCopy);
    }

    pub fn hasComponent(self: SparseSetStorage, entity: Entity, comptime C: type) bool {
        const typeName = @typeName(C);
        if (!self.sparseSets.contains(typeName))
            return false;

        if (self.sparseSets.get(typeName)) |sparseSet|
            return sparseSet.contains(entity);
        return false;
    }

    pub fn getComponent(self: SparseSetStorage, entity: Entity, comptime C: type) ?C {
        const typeName = @typeName(C);
        if (self.sparseSets.get(typeName)) |sparseSet|
            return sparseSet.get(entity, C);
        return null;
    }
};
