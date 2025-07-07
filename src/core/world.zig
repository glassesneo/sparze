const std = @import("std");

const entity_module = @import("entity.zig");
const Entity = entity_module.Entity;
const EntityManager = entity_module.EntityManager;

const sparse_set_module = @import("sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;
const AbstractSparseSet = sparse_set_module.AbstractSparseSet;

const storage_module = @import("storage.zig");
const SparseSetStorage = storage_module.SparseSetStorage;
const ResourceStorage = storage_module.ResourceStorage;

pub const World = struct {
    entity_manager: EntityManager,
    sparse_set_storage: SparseSetStorage,
    resource_storage: ResourceStorage,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) World {
        return World{
            .entity_manager = .init(allocator),
            .sparse_set_storage = .init(allocator),
            .resource_storage = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *World) void {
        self.entity_manager.deinit();
        self.sparse_set_storage.deinit();
    }

    pub fn createEntity(self: *World) !Entity {
        return try self.entity_manager.create();
    }

    pub fn createEntityWith(self: *World, comptime types: anytype) !Entity {
        const entity = try self.entity_manager.create();
        try self.attachComponents(entity, types);
        return entity;
    }

    pub fn destroyEntity(self: *World, entity: Entity) !void {
        try self.entity_manager.destroy(entity.id);
        try self.sparse_set_storage.removeAllComponents(entity);
    }

    pub fn containsEntity(self: *const World, entity: Entity) bool {
        return self.entity_manager.exists(entity);
    }

    pub fn getAllEntities(self: *const World) []const Entity {
        return self.entity_manager.getAllEntities();
    }

    /// Attaches a component to an entity.
    /// Note: The component is copied into the ECS storage.
    pub fn attachComponent(self: *World, entity: Entity, comptime C: type, component: C) !void {
        try self.sparse_set_storage.attachComponent(entity, C, component);
    }

    /// Attaches multiple component to an entity
    /// Note: The components must be compiletime-known.
    pub fn attachComponents(self: *World, entity: Entity, comptime types: anytype) !void {
        inline for (types) |component| {
            const C = @TypeOf(component);
            try self.attachComponent(entity, C, component);
        }
    }

    pub fn hasComponent(self: World, entity: Entity, comptime C: type) bool {
        return self.sparse_set_storage.hasComponent(entity, C);
    }

    pub fn getComponent(self: World, entity: Entity, comptime C: type) ?C {
        return self.sparse_set_storage.getComponent(entity, C);
    }

    pub fn getComponentPtr(self: *World, entity: Entity, comptime C: type) ?*C {
        return self.sparse_set_storage.getComponentPtr(entity, C);
    }

    pub fn removeComponent(self: *World, entity: Entity, comptime C: type) !void {
        try self.sparse_set_storage.removeComponent(entity, C);
    }

    pub fn putResource(self: *World, comptime T: type, value: T) !void {
        try self.resource_storage.put(T, value);
    }

    pub fn getResource(self: *const World, comptime T: type) ?T {
        return self.resource_storage.get(T);
    }

    pub fn getResourcePtr(self: *World, comptime T: type) ?*T {
        return self.resource_storage.getPtr(T);
    }
};

test "World createEntityWith attaches all components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = World.init(arena.allocator());
    defer world.deinit();

    const Position = struct { x: i32, y: i32 };
    const Health = struct { value: i32 };
    const entity = try world.createEntityWith(.{
        Position{ .x = 5, .y = 7 },
        Health{ .value = 42 },
    });
    try std.testing.expect(world.hasComponent(entity, Position));
    try std.testing.expect(world.hasComponent(entity, Health));
    try std.testing.expectEqual(@as(i32, 5), world.getComponent(entity, Position).?.x);
    try std.testing.expectEqual(@as(i32, 42), world.getComponent(entity, Health).?.value);
}

test "World removeComponent detaches only the specified component" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = World.init(arena.allocator());
    defer world.deinit();

    const Position = struct { x: i32 };
    const Health = struct { value: i32 };
    const entity = try world.createEntityWith(.{
        Position{ .x = 1 },
        Health{ .value = 99 },
    });
    try world.removeComponent(entity, Position);
    try std.testing.expect(!world.hasComponent(entity, Position));
    try std.testing.expect(world.hasComponent(entity, Health));
    try std.testing.expectEqual(@as(i32, 99), world.getComponent(entity, Health).?.value);
}
test "World entity operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var world = World.init(arena.allocator());
    defer world.deinit();

    // Test entity creation
    const e1 = try world.createEntity();
    const e2 = try world.createEntity();

    // Test entity existence
    try std.testing.expect(world.containsEntity(e1));
    try std.testing.expect(world.containsEntity(e2));
    try std.testing.expect(!world.containsEntity(Entity.init(999, 0)));

    // Test getAllEntities
    const entities = world.getAllEntities();
    try std.testing.expectEqual(@as(usize, 2), entities.len);
    try std.testing.expectEqual(e1.id, entities[0].id);
    try std.testing.expectEqual(e2.id, entities[1].id);

    // Test entity destruction
    try world.destroyEntity(e1);
    try std.testing.expect(!world.containsEntity(e1));
    try std.testing.expect(world.containsEntity(e2));
}

test "World component operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var world = World.init(arena.allocator());
    defer world.deinit();

    const e1 = try world.createEntity();

    const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    const Velocity = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    const Acceleration = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    // Test initial state
    try std.testing.expect(!world.hasComponent(e1, Position));
    try std.testing.expect(world.getComponent(e1, Position) == null);

    // Test attaching a single component
    try world.attachComponent(e1, Position, .{ .x = 10, .y = 20 });
    try std.testing.expect(world.hasComponent(e1, Position));

    if (world.getComponent(e1, Position)) |pos| {
        try std.testing.expectEqual(@as(f32, 10), pos.x);
        try std.testing.expectEqual(@as(f32, 20), pos.y);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test attaching multiple components
    try world.attachComponents(e1, .{
        Velocity{ .x = 1, .y = 2 },
        Acceleration{ .x = 0.1, .y = 0.2 },
    });

    try std.testing.expect(world.hasComponent(e1, Velocity));

    if (world.getComponent(e1, Velocity)) |vel| {
        try std.testing.expectEqual(@as(f32, 1), vel.x);
        try std.testing.expectEqual(@as(f32, 2), vel.y);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    if (world.getComponent(e1, Acceleration)) |acc| {
        try std.testing.expectEqual(@as(f32, 0.1), acc.x);
        try std.testing.expectEqual(@as(f32, 0.2), acc.y);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test getComponentPtr for mutable access
    if (world.getComponentPtr(e1, Position)) |pos_ptr| {
        try std.testing.expectEqual(@as(f32, 10), pos_ptr.x);
        try std.testing.expectEqual(@as(f32, 20), pos_ptr.y);

        // Test in-place modification through pointer
        pos_ptr.x = 100;
        pos_ptr.y = 200;

        // Verify the modification persisted
        if (world.getComponent(e1, Position)) |modified_pos| {
            try std.testing.expectEqual(@as(f32, 100), modified_pos.x);
            try std.testing.expectEqual(@as(f32, 200), modified_pos.y);
        } else {
            try std.testing.expect(false); // Should not reach here
        }
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test getComponentPtr for non-existent component
    const e2 = try world.createEntity();
    try std.testing.expect(world.getComponentPtr(e2, Position) == null);

    // Test entity destruction removes components
    try world.destroyEntity(e1);
    try std.testing.expect(!world.hasComponent(e1, Position));
    try std.testing.expect(!world.hasComponent(e1, Velocity));
    try std.testing.expect(!world.hasComponent(e1, Acceleration));
}

test "World multiple entities with components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var world = World.init(arena.allocator());
    defer world.deinit();

    const Tag = struct {};
    const Health = struct { value: i32 };

    const e1 = try world.createEntity();
    const e2 = try world.createEntity();
    const e3 = try world.createEntity();

    // Create different component configurations
    try world.attachComponent(e1, Tag, .{});
    try world.attachComponent(e1, Health, .{ .value = 100 });

    try world.attachComponent(e2, Health, .{ .value = 50 });

    try world.attachComponent(e3, Tag, .{});

    // Verify component configurations
    try std.testing.expect(world.hasComponent(e1, Tag));
    try std.testing.expect(world.hasComponent(e1, Health));

    try std.testing.expect(!world.hasComponent(e2, Tag));
    try std.testing.expect(world.hasComponent(e2, Health));

    try std.testing.expect(world.hasComponent(e3, Tag));
    try std.testing.expect(!world.hasComponent(e3, Health));

    // Test component values
    try std.testing.expectEqual(@as(i32, 100), world.getComponent(e1, Health).?.value);
    try std.testing.expectEqual(@as(i32, 50), world.getComponent(e2, Health).?.value);
}

test "World resource put/get/update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = World.init(arena.allocator());
    defer world.deinit();

    const Config = struct {
        value: i32,
        pub fn deinit(_: *@This()) void {}
    };

    // Put and get resource
    try world.putResource(Config, Config{ .value = 42 });
    if (world.getResource(Config)) |got| {
        try std.testing.expectEqual(@as(i32, 42), got.value);
    } else {
        try std.testing.expect(false);
    }

    // Update resource
    try world.putResource(Config, Config{ .value = 99 });
    if (world.getResource(Config)) |got| {
        try std.testing.expectEqual(@as(i32, 99), got.value);
    } else {
        try std.testing.expect(false);
    }

    // Test getResourcePtr for mutable access
    if (world.getResourcePtr(Config)) |config_ptr| {
        try std.testing.expectEqual(@as(i32, 99), config_ptr.value);

        // Test in-place modification through pointer
        config_ptr.value = 123;

        // Verify the modification persisted
        if (world.getResource(Config)) |modified_config| {
            try std.testing.expectEqual(@as(i32, 123), modified_config.value);
        } else {
            try std.testing.expect(false);
        }
    } else {
        try std.testing.expect(false);
    }

    // Non-existent resource returns null
    const Dummy = struct { x: u8 };
    try std.testing.expect(world.getResource(Dummy) == null);
    try std.testing.expect(world.getResourcePtr(Dummy) == null);
}
