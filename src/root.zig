const std = @import("std");
const testing = std.testing;

const Entity = struct {
    id: usize,
    pub fn init(id: usize) Entity {
        return Entity{ .id = id };
    }
};

const EntityList = std.ArrayList(Entity);

const IndexTable = std.AutoHashMap(usize, u32);

pub const AbstractSparseSet = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
    };

    pub fn insert(self: *const AbstractSparseSet, entity: Entity, component: *anyopaque) !void {
        return self.vtable.insertFn(self.instance, entity, component);
    }

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime T: type) ?T {
        if (self.vtable.getFn(self.instance, entity)) |component| {
            const typedPtr = AbstractSparseSet.castTo(T, component);
            return typedPtr.*;
        }
        return null;
    }

    fn castTo(comptime T: type, ptr: *anyopaque) *T {
        return @ptrCast(@alignCast(ptr));
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
                    return null;
                }
            }.get,
        };
        return .{
            .vtable = &vtable,
            .instance = instance,
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

        fn contains(self: Self, entity: Entity) bool {
            return self.indexTable.contains(entity.id);
        }

        fn insert(self: *Self, entity: Entity, component: C) !void {
            if (self.indexTable.get(entity.id)) |index| {
                self.components.items[index] = component;
            } else {
                try self.entities.append(entity);
                try self.components.append(component);

                const newIndex: u32 = @intCast(self.entities.items.len - 1);
                try self.indexTable.put(entity.id, newIndex);
            }
            // std.debug.print("Current index table: {any}\n", .{self.indexTable.count()});
        }

        pub fn abstract(self: *Self) AbstractSparseSet {
            return AbstractSparseSet.init(Self, self);
        }
    };
}

pub const World = struct {
    const SparseSetStorage = std.StringHashMap(AbstractSparseSet);
    const ComponentStorage = std.StringHashMap(*anyopaque);

    sparseSetStorage: SparseSetStorage,
    componentStorage: ComponentStorage,

    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) World {
        return World{
            .sparseSetStorage = SparseSetStorage.init(allocator),
            .componentStorage = ComponentStorage.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *World) void {
        // var iter = self.componentStorage.iterator();
        // while (iter.next()) |entry| {
        // self.allocator.destroy(@ptrCast(entry.value_ptr.*));
        // }

        self.sparseSetStorage.deinit();
        self.componentStorage.deinit();
    }

    /// Attaches a component to an entity.
    /// Note: The component is copied into the ECS storage.
    pub fn attachComponent(self: *World, entity: Entity, comptime Component: type, component: Component) !void {
        const typeName = @typeName(Component);
        if (!self.sparseSetStorage.contains(typeName)) {
            var sparseSet = try self.allocator.create(SparseSet(Component));
            sparseSet.* = SparseSet(Component).init(self.allocator);
            try self.componentStorage.put(typeName, @ptrCast(sparseSet));

            const abstractSparseSet = sparseSet.abstract();
            try self.sparseSetStorage.put(typeName, abstractSparseSet);
        }

        var componentCopy = component;
        try self.sparseSetStorage.get(typeName).?.insert(entity, &componentCopy);
    }

    /// Attaches multiple component to an entity
    /// Note: The components must be compiletime-known.
    pub fn attachComponents(self: *World, entity: Entity, comptime types: anytype) !void {
        inline for (types) |component| {
            const C = @TypeOf(component);
            try self.attachComponent(entity, C, component);
        }
    }

    pub fn hasComponent(self: World, entity: Entity, comptime Component: type) bool {
        const typeName = @typeName(Component);
        if (!self.sparseSetStorage.contains(typeName))
            return false;

        if (self.sparseSetStorage.get(typeName)) |sparseSet|
            return sparseSet.contains(entity);
        return false;
    }

    pub fn getComponent(self: World, entity: Entity, comptime Component: type) ?Component {
        const typeName = @typeName(Component);
        if (self.sparseSetStorage.get(typeName)) |sparseSet|
            return sparseSet.get(entity, Component);
        return null;
    }
};

test "ECS running test" {
    const Position = struct { x: i32, y: i32 };
    const Size = struct { h: i16, w: i16 };
    const Player = struct { hp: i32, mp: i16 };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const entity1 = Entity.init(0);
    const entity2 = Entity.init(1);

    var world = World.init(allocator);
    defer world.deinit();

    try world.attachComponent(entity1, Position, Position{ .x = 10, .y = 20 });

    try world.attachComponents(entity2, .{
        Size{ .h = 10, .w = 10 },
        Player{ .hp = 100, .mp = 50 },
    });

    std.debug.print("{any}\n", .{world});
    if (world.getComponent(entity1, Position)) |component| {
        std.debug.print("Position: {any}\n", .{component});
    } else {
        std.debug.print("None!\n", .{});
    }
    if (world.getComponent(entity2, Size)) |component| {
        std.debug.print("Size: {any}\n", .{component});
    } else {
        std.debug.print("None!\n", .{});
    }
}
