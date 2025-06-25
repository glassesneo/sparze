const std = @import("std");
const testing = std.testing;

const Entity = struct {
    id: usize,
    pub fn init(id: usize) Entity {
        return Entity{ .id = id };
    }
};

const EntityList = std.ArrayList(Entity);

const IndexTable = std.AutoArrayHashMap(usize, u32);

pub const AbstractSparseSet = struct {
    // entities: EntityList,
    // components: std.ArrayList(anyopaque),
    vtable: *const VTable,
    instance: *anyopaque,
    entities: EntityList,
    const VTable = struct {
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
    };

    pub fn insert(self: *const AbstractSparseSet, entity: Entity, component: anytype) !void {
        return self.vtable.insertFn(self.instance, entity, @constCast(@ptrCast(@alignCast(&component))));
    }

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime T: type) ?T {
        if (self.vtable.getFn(self.instance, entity)) |component| {
            return AbstractSparseSet.castTo(T, component).*;
        }
        return null;
    }

    fn castTo(comptime T: type, ptr: *anyopaque) *T {
        return @as(*T, @ptrCast(@alignCast(ptr)));
    }

    pub fn init(comptime T: type, instance: *T) AbstractSparseSet {
        const vtable = comptime VTable{
            .insertFn = struct {
                fn insert(ptr: *anyopaque, entity: Entity, cPtr: *anyopaque) !void {
                    const self = AbstractSparseSet.castTo(T, ptr);
                    const component = AbstractSparseSet.castTo(T.Component, cPtr);
                    return self.insert(entity, component.*);
                }
            }.insert,
            .getFn = struct {
                fn get(ptr: *anyopaque, entity: Entity) ?*anyopaque {
                    const self = AbstractSparseSet.castTo(T, ptr);
                    if (self.indexTable.get(entity.id)) |index| {
                        return @ptrCast(&self.components.items[index]);
                    }
                    // if (self.get(entity)) |component| {
                    // return @constCast(@ptrCast(@alignCast(&component)));
                    // }
                    return null;
                }
            }.get,
        };
        return .{
            .vtable = &vtable,
            .instance = instance,
            .entities = instance.entities,
        };
    }
};

pub fn SparseSet(comptime C: type) type {
    const ComponentList = std.ArrayList(C);
    return struct {
        entities: EntityList,
        components: ComponentList,
        indexTable: IndexTable,
        const Self = @This();
        pub const Component = C;

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .entities = EntityList.init(allocator),
                .components = ComponentList.init(allocator),
                .indexTable = IndexTable.init(allocator),
            };
        }

        pub fn insert(self: *Self, entity: Entity, component: C) !void {
            if (self.indexTable.get(entity.id)) |index| {
                self.components.items[index] = component;
            } else {
                try self.entities.append(entity);
                try self.components.append(component);

                const newIndex: u32 = @intCast(self.entities.items.len - 1);
                try self.indexTable.put(entity.id, newIndex);
            }
        }

        pub fn abstract(self: *Self) AbstractSparseSet {
            return AbstractSparseSet.init(Self, self);
        }
    };
}

pub const World = struct {
    const SparseSetContainer = std.StringHashMap(AbstractSparseSet);
    sparseSetContainer: SparseSetContainer,
    pub fn init(allocator: std.mem.Allocator) World {
        return World{ .sparseSetContainer = SparseSetContainer.init(allocator) };
    }
    pub fn put(self: *World, typeName: []const u8, sparseSet: AbstractSparseSet) !void {
        try self.sparseSetContainer.put(typeName, sparseSet);
    }
};

const Position = struct { x: i32, y: i32 };
const Size = struct { x: i16, y: i16 };

const PositionList = SparseSet(Position);
const SizeList = SparseSet(Size);

pub fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const entity1 = Entity.init(0);
    var positionList = PositionList.init(allocator);
    try positionList.insert(entity1, Position{ .x = 5, .y = 100 });

    // std.debug.print("{any}\n", .{positionList.get(entity1)});

    const abstractPositionList = positionList.abstract();
    try abstractPositionList.insert(entity1, Position{ .x = 5, .y = 105 });
    std.debug.print("{any}\n", .{abstractPositionList.get(entity1, Position)});

    // var sizeList = SizeList.init(allocator);
    // const abstractSizeList = sizeList.abstract();

    // var world = World.init(allocator);
    // try world.put("Position", abstractPositionList);
    // try world.put("Size", abstractSizeList);
    // std.debug.print("{any}\n", .{world});
}

test "ECS running test" {
    try run();
}
