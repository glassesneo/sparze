const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("core/entity.zig");
const Entity = entity_module.Entity;

const sparse_set_module = @import("core/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const tag_storage_module = @import("core/tag_storage.zig");
const TagStorage = tag_storage_module.TagStorage;

const component_storage_module = @import("core/component_storage.zig");
const ComponentStorage = component_storage_module.ComponentStorage;
const isTagComponent = component_storage_module.isTagComponent;

/// FilterType identifies the type of query filter used in system parameters.
///
/// Query filters are types that filter entities based on component composition,
/// used as parameters in system functions to specify which entities the system operates on.
/// Each filter type provides different performance characteristics and usage patterns.
pub const FilterType = enum {
    /// SingleQuery filter: iterates over entities with a single component
    single_query,
    /// Query filter: performs runtime intersection for multiple components
    query,
    /// Group filter: optimized multi-component iteration with pre-organized layout
    group,
    /// SingleTag filter: iterates over entities with a single tag component
    single_tag,
    /// TagQuery filter: performs runtime intersection for multiple tag components
    tag_query,
    /// Resource filter: provides access to a global resource
    resource,
};

pub const ModifierType = enum {
    optional,
    exclude,
};
pub fn SingleQuery(comptime QueryComponent: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .single_query;
        pub const Component = QueryComponent;

        entities: []const Entity,
        components: []Component,

        pub fn init(sparse_set: *const SparseSet(Component)) Self {
            return .{
                .entities = sparse_set.packed_array.items,
                .components = sparse_set.components.items,
            };
        }
    };
}

/// Query is a query filter that provides runtime intersection over entities with multiple components.
///
/// Unlike Group, Query doesn't require any setup but performs intersection at query time
/// by iterating through the smallest component set and checking for the presence of other
/// components. This makes it flexible for ad-hoc queries or varying component combinations.
///
/// Use Query when:
/// - You need multi-component queries without setup overhead
/// - Query patterns are dynamic or one-off
/// - Flexibility is more important than raw performance
///
/// Example:
/// ```zig
/// fn combatSystem(query: Query(struct { Position, Health })) !void {
///     for (query.entities) |entity| {
///         if (query.filter(entity)) {
///             const pos = query.getComponent(entity, Position);
///             const health = query.getComponentMut(entity, Health);
///             {
///                 // Apply damage based on position
///             }
///         }
///     }
/// }
/// ```
pub fn Query(comptime QueryComponents: type) type {
    // The same way World define its component_pool
    const info = @typeInfo(QueryComponents);
    if (info != .@"struct") @compileError("Invalid form of components");
    const component_fields = info.@"struct".fields;
    if (component_fields.len == 0) @compileError("Query must have at least one component");
    const length = info.@"struct".fields.len;

    const QueryComponentPoolType = construct_component_pool: {
        var query_fields: [length]StructField = undefined;
        inline for (component_fields, 0..) |field, i| {
            // const T = field.type;
            const Component, _ = extractType(field.type);

            const StorageType = ComponentStorage(Component);
            query_fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = *StorageType,
                .is_comptime = false,
                .alignment = @alignOf(*StorageType),
                .default_value_ptr = null,
            };
        }
        break :construct_component_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &query_fields,
        } });
    };

    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .query;
        pub const ComponentTypes = QueryComponents;

        query_component_pool: QueryComponentPoolType,
        entities: []const Entity,

        pub fn init(world: anytype) Self {
            // Find the smallest sparse set to minimize iterations
            // We need to find this at runtime, but we can iterate all component types at comptime
            var min_size: usize = std.math.maxInt(usize);
            var candidate_entities: []const Entity = &[_]Entity{};
            var component_pool: QueryComponentPoolType = undefined;

            // Try each component type and find the one with smallest sparse set
            inline for (component_fields, 0..) |field, i| {
                const Component, const modifier_type = extractType(field.type);
                const component_storage: *ComponentStorage(Component) = world.getComponentStoragePtr(Component);
                component_pool[i] = component_storage;
                if (modifier_type) |_| continue;
                const size = component_storage.packed_array.items.len;
                if (size < min_size) {
                    min_size = size;
                    candidate_entities = component_storage.packed_array.items;
                }
            }

            // Return a query that will iterate through the smallest set
            // Users must call filter() to filter for entities with all required components
            return .{
                .query_component_pool = component_pool,
                .entities = candidate_entities,
            };
        }

        pub fn getComponentId(comptime C: type) u16 {
            // The order of components become the id
            return inline for (component_fields, 0..) |field, i| {
                const T, _ = extractType(field.type);
                if (C == T) break i;
            } else @compileError("Unknown component type: " ++ @typeName(C));
        }

        fn getComponentStoragePtr(self: *const Self, comptime C: type) *const ComponentStorage(C) {
            const id = comptime getComponentId(C);
            return self.query_component_pool[id];
        }

        fn getComponentStoragePtrMut(self: *const Self, comptime C: type) *ComponentStorage(C) {
            const id = comptime getComponentId(C);
            // This is safe because we're only mutating through the pointer chain
            return @constCast(self.query_component_pool[id]);
        }

        /// Get immutable component for an entity
        /// Note: Cannot be used with tag components (zero-sized components)
        pub fn getComponent(self: Self, entity: Entity, comptime C: type) C {
            const storage = self.getComponentStoragePtr(C);
            return storage.*.get(entity).?;
        }

        /// Get mutable component pointer for an entity
        /// Note: Cannot be used with tag components (zero-sized components)
        pub fn getComponentMut(self: Self, entity: Entity, comptime C: type) *C {
            const sparse_set = self.getComponentStoragePtrMut(C);
            return sparse_set.*.getPtrMut(entity).?;
        }

        pub fn getOptional(self: Self, entity: Entity, comptime C: type) ?C {
            const storage = self.getComponentStoragePtr(C);
            return storage.*.get(entity);
        }

        pub fn getOptionalMut(self: Self, entity: Entity, comptime C: type) ?*C {
            const sparse_set = self.getComponentStoragePtrMut(C);
            return sparse_set.*.getPtrMut(entity);
        }

        /// Filter entities based on required components
        pub fn filter(self: Self, entity: Entity) bool {
            return inline for (component_fields) |field| {
                const T, const modifier_type = extractType(field.type);
                if (modifier_type) |modifier| switch (modifier) {
                    .optional => continue,
                    .exclude => {
                        if (self.getComponentStoragePtr(T).*.contains(entity))
                            break false;
                        continue;
                    },
                };
                if (!self.getComponentStoragePtr(T).*.contains(entity))
                    break false;
            } else true;
        }
    };
}

/// Group is a query filter that provides optimized iteration over entities with multiple components.
///
/// Groups require upfront setup via `world.createGroup()` but provide the fastest iteration
/// for multi-component queries. Entities in a group are stored at the beginning of all
/// component arrays, enabling cache-friendly sequential access.
///
/// Use Group for hot-path queries that run frequently (e.g., every frame) where
/// maximum performance is critical.
///
/// Example:
/// ```zig
/// const MovementGroup = struct { Position, Velocity };
///
/// // Setup (once)
/// try world.createGroup(MovementGroup);
///
/// // System function
/// fn movementSystem(group: Group(MovementGroup)) !void {
///     const positions = group.getMutArrayOf(Position);
///     const velocities = group.getArrayOf(Velocity);
///     for (positions, velocities) |*pos, vel| {
///         pos.x += vel.x;
///         pos.y += vel.y;
///     }
/// }
/// ```
pub fn Group(comptime GroupComponents: type) type {
    // The same way World and Query define their component_pool
    const info = @typeInfo(GroupComponents);
    if (info != .@"struct") @compileError("Invalid form of components");
    const component_fields = info.@"struct".fields;
    if (component_fields.len == 0) @compileError("Group must have at least one component");
    const length = component_fields.len;

    const GroupComponentPoolType = construct_component_pool: {
        var sparse_set_fields: [length]StructField = undefined;
        inline for (component_fields, 0..) |field, i| {
            if (isTagComponent(field.type)) @compileError("Group cannot consist of tag components");
            const SparseSetType = SparseSet(field.type);
            sparse_set_fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = *const SparseSetType,
                .is_comptime = false,
                .alignment = @alignOf(*const SparseSetType),
                .default_value_ptr = null,
            };
        }
        break :construct_component_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &sparse_set_fields,
        } });
    };

    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .group;
        pub const ComponentTypes = GroupComponents;

        group_component_pool: GroupComponentPoolType,

        pub fn init(world: anytype) Self {
            var component_pool: GroupComponentPoolType = undefined;

            // Extract sparse set pointers for all group components
            inline for (component_fields, 0..) |field, i| {
                const Component = field.type;
                const sparse_set: *const SparseSet(Component) = world.getSparseSetPtr(Component);
                component_pool[i] = sparse_set;
            }

            return .{
                .group_component_pool = component_pool,
            };
        }

        pub fn getComponentId(comptime C: type) u16 {
            // The order of components become the id
            return inline for (component_fields, 0..) |field, i| {
                if (C == field.type) break i;
            } else @compileError("Unknown component type: " ++ @typeName(C));
        }

        fn getSparseSetPtr(self: Self, comptime C: type) *const SparseSet(C) {
            const id = comptime getComponentId(C);
            return self.group_component_pool[id];
        }

        pub fn getEntities(self: Self) []const Entity {
            // Use the first component's sparse set to get group entities
            return self.group_component_pool[0].getGroupEntities();
        }

        pub fn getArrayOf(self: Self, comptime C: type) []const C {
            return self.getSparseSetPtr(C).getGroupComponents();
        }

        pub fn getMutArrayOf(self: Self, comptime C: type) []C {
            return self.getSparseSetPtr(C).getGroupComponentsMut();
        }
    };
}

pub fn SingleTag(comptime TagComponent: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .single_tag;
        pub const Component = TagComponent;

        entities: []const Entity,

        pub fn init(tag_storage: *TagStorage(Component)) Self {
            return .{
                .entities = tag_storage.packed_array.items,
            };
        }
    };
}

/// TagQuery is a query filter that provides runtime intersection over entities with multiple tag components.
///
/// Unlike Query, TagQuery only accepts tag components (zero-sized structs) and provides a
/// tag-specific API without component accessors. It performs intersection at query time by
/// iterating through the smallest tag set and checking for the presence of other tags.
///
/// TagQuery now supports optional tags using the ?Tag syntax, allowing queries to match
/// entities regardless of whether they have the optional tag.
///
/// Use TagQuery when:
/// - You need multi-tag queries (e.g., entities with both Enemy and Boss tags)
/// - All components are tags (zero-sized markers)
/// - You want explicit type safety for tag-only queries
/// - You need to optionally check for certain tags
///
/// Example:
/// ```zig
/// fn bossEnemySystem(query: TagQuery(struct { Enemy, ?Boss })) !void {
///     for (query.entities) |entity| {
///         if (query.filter(entity)) {
///             // Process all enemies, check if they're bosses
///             if (query.hasTag(entity, Boss)) {
///                 // This enemy is a boss
///             }
///         }
///     }
/// }
/// ```
pub fn TagQuery(comptime QueryTags: type) type {
    // Validate that QueryTags is a struct
    const info = @typeInfo(QueryTags);
    if (info != .@"struct") @compileError("Invalid form of tags");
    const tag_fields = info.@"struct".fields;
    if (tag_fields.len == 0) @compileError("TagQuery must have at least one tag");

    // Validate that all fields are tag components (zero-sized)
    inline for (tag_fields) |field| {
        const Tag, _ = extractType(field.type);
        if (!isTagComponent(Tag)) {
            @compileError("TagQuery can only contain tag components (empty structs). Found non-tag: " ++ @typeName(Tag));
        }
    }

    const length = tag_fields.len;

    const TagPoolType = construct_tag_pool: {
        var query_fields: [length]StructField = undefined;
        inline for (tag_fields, 0..) |field, i| {
            const Tag, _ = extractType(field.type);
            const StorageType = TagStorage(Tag);
            query_fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = *StorageType,
                .is_comptime = false,
                .alignment = @alignOf(*StorageType),
                .default_value_ptr = null,
            };
        }
        break :construct_tag_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &query_fields,
        } });
    };

    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .tag_query;
        pub const TagTypes = QueryTags;

        tag_pool: TagPoolType,
        entities: []const Entity,

        pub fn init(world: anytype) Self {
            // Find the smallest tag storage to minimize iterations
            var min_size: usize = std.math.maxInt(usize);
            var candidate_entities: []const Entity = &[_]Entity{};
            var tag_pool: TagPoolType = undefined;

            // Try each tag type and find the one with smallest storage
            inline for (tag_fields, 0..) |field, i| {
                const Tag, const modifier_type = extractType(field.type);
                const tag_storage: *TagStorage(Tag) = world.getTagStoragePtr(Tag);
                tag_pool[i] = tag_storage;
                if (modifier_type) |_| continue;
                const size = tag_storage.packed_array.items.len;
                if (size < min_size) {
                    min_size = size;
                    candidate_entities = tag_storage.packed_array.items;
                }
            }

            // Return a query that will iterate through the smallest set
            // Users must call filter() to filter for entities with all required tags
            return .{
                .tag_pool = tag_pool,
                .entities = candidate_entities,
            };
        }

        pub fn getTagId(comptime T: type) u16 {
            // The order of tags become the id
            return inline for (tag_fields, 0..) |field, i| {
                const Tag, _ = extractType(field.type);
                if (T == Tag) break i;
            } else @compileError("Unknown tag type: " ++ @typeName(T));
        }

        fn getTagStoragePtr(self: *const Self, comptime T: type) *const TagStorage(T) {
            const id = comptime getTagId(T);
            return self.tag_pool[id];
        }

        /// Filter entities based on required tags
        pub fn filter(self: Self, entity: Entity) bool {
            return inline for (tag_fields) |field| {
                const T, const modifier_type = extractType(field.type);
                if (modifier_type) |modifier| switch (modifier) {
                    .optional => continue,
                    .exclude => {
                        if (self.getTagStoragePtr(T).*.contains(entity))
                            break false;
                        continue;
                    },
                };
                if (!self.getTagStoragePtr(T).*.contains(entity))
                    break false;
            } else true;
        }

        /// Check if entity has a specific tag (for optional tags)
        pub fn hasTag(self: Self, entity: Entity, comptime T: type) bool {
            return self.getTagStoragePtr(T).*.contains(entity);
        }
    };
}

pub fn Resource(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const filter_type: FilterType = .resource;
        pub const ResourceType = T;
        value: *T,

        pub fn init(value: *T) Self {
            return .{
                .value = value,
            };
        }
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn extractOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |Optional| Optional.child,
        else => T,
    };
}

pub fn Exclude(comptime C: type) type {
    return struct {
        pub const Component = C;
        pub const modifier_type: ModifierType = .exclude;
    };
}

fn extractType(comptime T: type) struct { type, ?ModifierType } {
    if (isOptional(T))
        return .{ extractOptional(T), .optional };
    if (@hasDecl(T, "modifier_type"))
        return .{ T.Component, T.modifier_type };
    return .{ T, null };
}

test "Query with Exclude modifier - basic usage" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Dead = struct {};
    const Static = struct {};

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Dead, Static }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create living movable entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Create dead entity (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.0, .dy = 0.0 });
    try world.addTag(e3, Dead);

    // Create static entity (should be excluded)
    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 70.0, .y = 80.0 });
    try world.addComponent(e4, Velocity, .{ .dx = 0.0, .dy = 0.0 });
    try world.addTag(e4, Static);

    // Query for living entities with position and velocity (exclude Dead)
    const LivingMovementQuery = Query(struct { Position, Velocity, Exclude(Dead) });
    const query = LivingMovementQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1, e2, and e4 (not e3 which is Dead)
            try std.testing.expect(entity == e1 or entity == e2 or entity == e4);
            try std.testing.expect(entity != e3);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "Query with multiple Exclude modifiers" {
    const Position = struct { x: f32, y: f32 };
    const Enemy = struct {};
    const Dead = struct {};
    const Frozen = struct {};
    const Disabled = struct {};

    const TestWorld = @import("world.zig").World(struct { Position, Enemy, Dead, Frozen, Disabled }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create active enemy (should be included)
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addTag(e1, Enemy);

    // Create another active enemy (should be included)
    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addTag(e2, Enemy);

    // Create frozen enemy (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addTag(e3, Enemy);
    try world.addTag(e3, Frozen);

    // Create disabled enemy (should be excluded)
    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 70.0, .y = 80.0 });
    try world.addTag(e4, Enemy);
    try world.addTag(e4, Disabled);

    // Create dead enemy (should be excluded)
    const e5 = world.createEntity();
    try world.addComponent(e5, Position, .{ .x = 90.0, .y = 100.0 });
    try world.addTag(e5, Enemy);
    try world.addTag(e5, Dead);

    // Create enemy with multiple exclusion tags (should be excluded)
    const e6 = world.createEntity();
    try world.addComponent(e6, Position, .{ .x = 110.0, .y = 120.0 });
    try world.addTag(e6, Enemy);
    try world.addTag(e6, Frozen);
    try world.addTag(e6, Disabled);

    // Query for active enemies (exclude Frozen, Disabled, Dead)
    const ActiveEnemyQuery = Query(struct { Position, Enemy, Exclude(Frozen), Exclude(Disabled), Exclude(Dead) });
    const query = ActiveEnemyQuery.init(&world);

    var count: usize = 0;
    var found_e1 = false;
    var found_e2 = false;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3 and entity != e4 and entity != e5 and entity != e6);
            if (entity == e1) found_e1 = true;
            if (entity == e2) found_e2 = true;
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(found_e1);
    try std.testing.expect(found_e2);
}

test "Query with Exclude and optional components combined" {
    const Position = struct { x: f32, y: f32 };
    const Health = struct { hp: i32 };
    const Shield = struct { value: i32 };
    const Dead = struct {};
    const Invulnerable = struct {};

    const TestWorld = @import("world.zig").World(struct { Position, Health, Shield, Dead, Invulnerable }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Living entity with health and shield
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });
    try world.addComponent(e1, Shield, .{ .value = 50 });

    // Living entity with health but no shield
    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Health, .{ .hp = 75 });

    // Dead entity (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(e3, Health, .{ .hp = 0 });
    try world.addTag(e3, Dead);

    // Invulnerable entity (should be excluded)
    const e4 = world.createEntity();
    try world.addComponent(e4, Position, .{ .x = 70.0, .y = 80.0 });
    try world.addComponent(e4, Health, .{ .hp = 100 });
    try world.addTag(e4, Invulnerable);

    // Query for damageable entities (living, not invulnerable, optional shield)
    const DamageableQuery = Query(struct { Position, Health, ?Shield, Exclude(Dead), Exclude(Invulnerable) });
    const query = DamageableQuery.init(&world);

    var count: usize = 0;
    var shielded_count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3 and entity != e4);

            const health = query.getComponent(entity, Health);
            try std.testing.expect(health.hp > 0);

            if (query.getOptional(entity, Shield)) |shield| {
                try std.testing.expect(shield.value > 0);
                shielded_count += 1;
            }
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 1), shielded_count);
}

test "Query with Exclude in system function" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Static = struct {};

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Static }, struct {});

    const MovementSystem = struct {
        var updated_count: usize = 0;

        fn system(query: Query(struct { Position, Velocity, Exclude(Static) })) !void {
            updated_count = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponentMut(entity, Position);
                    const vel = query.getComponent(entity, Velocity);
                    pos.x += vel.dx;
                    pos.y += vel.dy;
                    updated_count += 1;
                }
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Movable entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Static entity (should not move)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 100.0, .y = 200.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 5.0, .dy = 10.0 });
    try world.addTag(e3, Static);

    // Run system
    try world.runSystem(MovementSystem.system);

    // Verify only non-static entities were updated
    try std.testing.expectEqual(@as(usize, 2), MovementSystem.updated_count);

    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 2.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 9.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 18.0), world.getComponent(e2, Position).?.y);
    // Static entity should not have moved
    try std.testing.expectEqual(@as(f32, 100.0), world.getComponent(e3, Position).?.x);
    try std.testing.expectEqual(@as(f32, 200.0), world.getComponent(e3, Position).?.y);
}

test "TagQuery with Exclude modifier" {
    const Player = struct {};
    const Enemy = struct {};
    const Dead = struct {};
    const Frozen = struct {};

    const TestWorld = @import("world.zig").World(struct { Player, Enemy, Dead, Frozen }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Active enemy
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);

    // Another active enemy
    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    // Dead enemy (should be excluded)
    const e3 = world.createEntity();
    try world.addTag(e3, Enemy);
    try world.addTag(e3, Dead);

    // Frozen enemy (should be excluded)
    const e4 = world.createEntity();
    try world.addTag(e4, Enemy);
    try world.addTag(e4, Frozen);

    // Player (not an enemy, should not be in results)
    const e5 = world.createEntity();
    try world.addTag(e5, Player);

    // Query for living, unfrozen enemies
    const ActiveEnemyQuery = TagQuery(struct { Enemy, Exclude(Dead), Exclude(Frozen) });
    const query = ActiveEnemyQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3 and entity != e4 and entity != e5);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Query with Exclude - no matches" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Disabled = struct {};

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Disabled }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // All entities are disabled
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    try world.addTag(e1, Disabled);

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });
    try world.addTag(e2, Disabled);

    // Query for enabled entities (should find none)
    const EnabledQuery = Query(struct { Position, Velocity, Exclude(Disabled) });
    const query = EnabledQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "Query with Exclude - regular component exclusion" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Armor = struct { value: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Armor }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Unarmored entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Armored entity (should be excluded)
    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e3, Armor, .{ .value = 100 });

    // Query for unarmored entities (exclude regular component)
    const UnarmoredQuery = Query(struct { Position, Velocity, Exclude(Armor) });
    const query = UnarmoredQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            // Should only find e1 and e2
            try std.testing.expect(entity == e1 or entity == e2);
            try std.testing.expect(entity != e3);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "SingleQuery basic iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with positions
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    // Query all positions
    const PositionQuery = SingleQuery(Position);
    const query = PositionQuery.init(world.getComponentStoragePtr(Position));

    try std.testing.expectEqual(@as(usize, 2), query.entities.len);
    try std.testing.expectEqual(@as(usize, 2), query.components.len);

    var count: usize = 0;
    for (query.entities, query.components) |entity, pos| {
        try std.testing.expect(world.isAlive(entity));
        try std.testing.expect(pos.x >= 10.0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Group query basic usage" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create group first
    try world.createGroup(struct { Position, Velocity });

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    // e2 has no velocity - not in group

    // Use Group query
    const MovementGroup = Group(struct { Position, Velocity });
    const group = MovementGroup.init(&world);

    const entities = group.getEntities();
    const positions = group.getArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    try std.testing.expectEqual(@as(usize, 1), entities.len);
    try std.testing.expectEqual(@as(usize, 1), positions.len);
    try std.testing.expectEqual(@as(usize, 1), velocities.len);

    try std.testing.expectEqual(@as(f32, 1.0), positions[0].x);
    try std.testing.expectEqual(@as(f32, 0.5), velocities[0].dx);
}

test "World system function with SingleQuery" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position }, struct {});

    const UpdatePositions = struct {
        fn system(query: SingleQuery(Position)) !void {
            for (query.components) |*pos| {
                pos.x += 1.0;
                pos.y += 1.0;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 5.0, .y = 15.0 });

    // Run the system
    try world.runSystem(UpdatePositions.system);

    // Verify updates
    try std.testing.expectEqual(@as(f32, 11.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 21.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 6.0), world.getComponent(e2, Position).?.x);
}

test "World system function with Group" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity }, struct {});

    const MovementSystem = struct {
        fn system(group: Group(struct { Position, Velocity })) !void {
            const positions = group.getMutArrayOf(Position);
            const velocities = group.getArrayOf(Velocity);

            for (positions, velocities) |*pos, vel| {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    // Create moving entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Run the system
    try world.runSystem(MovementSystem.system);

    // Verify positions updated
    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 2.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 9.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 18.0), world.getComponent(e2, Position).?.y);
}

test "World system with multiple queries" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health }, struct {});

    const ComplexSystem = struct {
        fn system(
            movement: Group(struct { Position, Velocity }),
            health_query: SingleQuery(Health),
        ) !void {
            // Update movement
            const positions = movement.getMutArrayOf(Position);
            const velocities = movement.getArrayOf(Velocity);
            for (positions, velocities) |*pos, vel| {
                pos.x += vel.dx;
            }

            // Process health (just count for this test)
            var health_count: usize = 0;
            for (health_query.components) |_| {
                health_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 2), health_count);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Health, .{ .hp = 50 });

    try world.runSystem(ComplexSystem.system);

    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
}

test "Query basic iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with different component combinations
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    // e2 has no health

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 30.0, .y = 40.0 });
    // e3 has only position

    // Query entities with Position and Velocity (no group setup required)
    const MovementQuery = Query(struct { Position, Velocity });
    const query = MovementQuery.init(&world);

    // Should find e1 and e2 (both have Position and Velocity)
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            const pos = query.getComponent(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            try std.testing.expect(pos.x > 0.0);
            try std.testing.expect(vel.dx > 0.0);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Query with mutable component access" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });

    // Use query to mutate components
    const MovementQuery = Query(struct { Position, Velocity });
    const query = MovementQuery.init(&world);

    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const vel = query.getComponent(entity, Velocity);
            const pos = query.getComponentMut(entity, Position);
            {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
    }

    // Verify mutations
    try std.testing.expectEqual(@as(f32, 11.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 22.0), world.getComponent(e1, Position).?.y);
    try std.testing.expectEqual(@as(f32, 29.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 38.0), world.getComponent(e2, Position).?.y);
}

test "World system function with Query" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health }, struct {});

    const CombatSystem = struct {
        fn system(query: Query(struct { Position, Health })) !void {
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    const pos = query.getComponent(entity, Position);
                    const health = query.getComponentMut(entity, Health);
                    {
                        // Reduce health if too far from origin
                        if (pos.x * pos.x + pos.y * pos.y > 100.0) {
                            health.hp -= 10;
                        }
                    }
                }
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 15.0, .y = 15.0 });
    try world.addComponent(e2, Health, .{ .hp = 100 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 1.0 });

    // Run the system
    try world.runSystem(CombatSystem.system);

    // e1 should be unaffected (close to origin)
    try std.testing.expectEqual(@as(i32, 100), world.getComponent(e1, Health).?.hp);
    // e2 should take damage (far from origin)
    try std.testing.expectEqual(@as(i32, 90), world.getComponent(e2, Health).?.hp);
}

test "Query three components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Health, .{ .hp = 50 });

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    // Query for all three components
    const FullEntityQuery = Query(struct { Position, Velocity, Health });
    const query = FullEntityQuery.init(&world);

    // Should only find e1
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            try std.testing.expectEqual(e1, entity);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TagQuery basic iteration with two tags" {
    const Player = struct {};
    const Active = struct {};
    const Enemy = struct {};

    const TestWorld = @import("world.zig").World(struct { Player, Active, Enemy }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with different tag combinations
    const e1 = world.createEntity();
    try world.addTag(e1, Player);
    try world.addTag(e1, Active);

    const e2 = world.createEntity();
    try world.addTag(e2, Player);

    const e3 = world.createEntity();
    try world.addTag(e3, Player);
    try world.addTag(e3, Active);

    const e4 = world.createEntity();
    try world.addTag(e4, Enemy);

    // Query for Player + Active tags
    const ActivePlayerQuery = TagQuery(struct { Player, Active });
    const query = ActivePlayerQuery.init(&world);

    // Should find e1 and e3 (both have Player and Active)
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            try std.testing.expect(entity == e1 or entity == e3);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "TagQuery with three tags" {
    const Player = struct {};
    const Active = struct {};
    const Boss = struct {};
    const Enemy = struct {};

    const TestWorld = @import("world.zig").World(struct { Player, Active, Boss, Enemy }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addTag(e1, Player);
    try world.addTag(e1, Active);
    try world.addTag(e1, Boss);

    const e2 = world.createEntity();
    try world.addTag(e2, Player);
    try world.addTag(e2, Active);

    const e3 = world.createEntity();
    try world.addTag(e3, Player);
    try world.addTag(e3, Boss);

    const e4 = world.createEntity();
    try world.addTag(e4, Enemy);

    // Query for Player + Active + Boss tags
    const BossPlayerQuery = TagQuery(struct { Player, Active, Boss });
    const query = BossPlayerQuery.init(&world);

    // Should only find e1
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            try std.testing.expectEqual(e1, entity);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TagQuery system function" {
    const Player = struct {};
    const Enemy = struct {};
    const Boss = struct {};

    const TestWorld = @import("world.zig").World(struct { Player, Enemy, Boss }, struct {});

    const BossEnemySystem = struct {
        fn system(query: TagQuery(struct { Enemy, Boss })) !void {
            var count: usize = 0;
            for (query.entities) |entity| {
                if (query.filter(entity)) {
                    count += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 2), count);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create boss enemies
    const boss1 = world.createEntity();
    try world.addTag(boss1, Enemy);
    try world.addTag(boss1, Boss);

    const boss2 = world.createEntity();
    try world.addTag(boss2, Enemy);
    try world.addTag(boss2, Boss);

    // Create regular enemy (not a boss)
    const enemy = world.createEntity();
    try world.addTag(enemy, Enemy);

    // Create player (not in query)
    const player = world.createEntity();
    try world.addTag(player, Player);

    // Run system
    try world.runSystem(BossEnemySystem.system);
}

test "TagQuery with empty result set" {
    const Player = struct {};
    const Enemy = struct {};
    const Boss = struct {};

    const TestWorld = @import("world.zig").World(struct { Player, Enemy, Boss }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities without Boss tag
    const e1 = world.createEntity();
    try world.addTag(e1, Player);

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    // Query for Enemy + Boss (no matches)
    const BossEnemyQuery = TagQuery(struct { Enemy, Boss });
    const query = BossEnemyQuery.init(&world);

    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "System function with Allocator parameter" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position }, struct {});

    const AllocatorSystem = struct {
        fn system(allocator: std.mem.Allocator) !void {
            // Test that we can use the allocator
            var list: std.ArrayList(i32) = .{};
            try list.ensureTotalCapacity(allocator, 1);
            defer list.deinit(allocator);

            try list.append(allocator, 42);
            try std.testing.expectEqual(@as(i32, 42), list.items[0]);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Run system with allocator
    try world.runSystem(AllocatorSystem.system);
}

test "System function with Allocator and query filter parameters" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position }, struct {});

    const MixedSystem = struct {
        fn system(allocator: std.mem.Allocator, query: SingleQuery(Position)) !void {
            // Use allocator to create a dynamic list
            var list: std.ArrayList(f32) = .{};
            defer list.deinit(allocator);

            // Collect all x positions
            for (query.components) |pos| {
                try list.append(allocator, pos.x);
            }

            // Verify we collected positions
            try std.testing.expectEqual(@as(usize, 2), list.items.len);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create test entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });

    // Run system with allocator and query
    try world.runSystem(MixedSystem.system);
}

test "System function with Allocator and Commands parameters" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position }, struct {});

    const SpawnSystem = struct {
        fn system(allocator: std.mem.Allocator, commands: anytype) !void {
            // Use allocator to determine spawn count
            var list: std.ArrayList(i32) = .{};
            defer list.deinit(allocator);

            try list.append(allocator, 1);
            try list.append(allocator, 2);
            try list.append(allocator, 3);

            // Spawn entities based on list
            for (list.items, 0..) |_, i| {
                const entity = commands.createEntity();
                try commands.addComponent(entity, Position, .{
                    .x = @as(f32, @floatFromInt(i)) * 10.0,
                    .y = 0.0,
                });
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    world.beginFrame();
    try world.runSystem(SpawnSystem.system);
    try world.endFrame();

    // Verify entities were spawned
    const query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), query.entities.len);
}

test "System function with Allocator, query filter, and Commands parameters" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity }, struct {});

    const ComplexSystem = struct {
        fn system(
            allocator: std.mem.Allocator,
            movement: Group(struct { Position, Velocity }),
            commands: anytype,
        ) !void {
            // Use allocator to track entities that need duplication
            var to_duplicate: std.ArrayList(std.meta.Tuple(&[_]type{ Position, Velocity })) = .{};
            defer to_duplicate.deinit(allocator);

            const positions = movement.getArrayOf(Position);
            const velocities = movement.getArrayOf(Velocity);

            for (positions, velocities) |pos, vel| {
                if (pos.x > 50.0) {
                    try to_duplicate.append(allocator, .{ pos, vel });
                }
            }

            // Spawn duplicates
            for (to_duplicate.items) |item| {
                const entity = commands.createEntity();
                try commands.addComponent(entity, Position, item[0]);
                try commands.addComponent(entity, Velocity, item[1]);
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    // Create test entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 100.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 0.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 10.0, .y = 0.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 2.0, .dy = 0.0 });

    world.beginFrame();
    try world.runSystem(ComplexSystem.system);
    try world.endFrame();

    // Should have 3 entities: 2 original + 1 duplicate (only e1 has x > 50)
    const query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 3), query.entities.len);
}

test "System function verifies allocator is world allocator" {
    const TestWorld = @import("world.zig").World(struct {}, struct {});

    const CheckAllocatorSystem = struct {
        var captured_allocator: ?std.mem.Allocator = null;

        fn system(allocator: std.mem.Allocator) !void {
            captured_allocator = allocator;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.runSystem(CheckAllocatorSystem.system);

    // Verify the allocator passed to the system is the world's allocator
    // Note: We can't directly compare allocators, but we can verify it was set
    try std.testing.expect(CheckAllocatorSystem.captured_allocator != null);
}

test "Query with optional components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities with different component combinations
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e2, Velocity, .{ .dx = -1.0, .dy = -2.0 });
    // e2 has no health

    const e3 = world.createEntity();
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });
    // e3 has only position

    // Query with optional Health - should match all entities with Position and Velocity,
    // regardless of whether they have Health
    const MovementQuery = Query(struct { Position, Velocity, ?Health });
    const query = MovementQuery.init(&world);

    var count: usize = 0;
    var health_count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            const pos = query.getComponent(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            try std.testing.expect(pos.x >= 10.0);
            try std.testing.expect(vel.dx != 0.0);

            // Use getOptional for optional components
            if (query.getOptional(entity, Health)) |health| {
                try std.testing.expect(health.hp > 0);
                health_count += 1;
            }
        }
    }

    // Should find e1 and e2 (both have Position and Velocity)
    try std.testing.expectEqual(@as(usize, 2), count);
    // Only e1 has health
    try std.testing.expectEqual(@as(usize, 1), health_count);
}

test "Query optional components with mutation" {
    const Position = struct { x: f32, y: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Health }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e1, Health, .{ .hp = 100 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    // e2 has no health

    // Query with optional Health
    const PosHealthQuery = Query(struct { Position, ?Health });
    const query = PosHealthQuery.init(&world);

    // Apply damage to entities with health, move all entities
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponentMut(entity, Position);
            pos.x += 1.0; // Move entity

            // Apply damage only if health exists
            if (query.getOptionalMut(entity, Health)) |health| {
                health.hp -= 10;
            }
        }
    }

    // Verify both entities moved
    try std.testing.expectEqual(@as(f32, 11.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 31.0), world.getComponent(e2, Position).?.x);

    // Verify only e1 took damage
    try std.testing.expectEqual(@as(i32, 90), world.getComponent(e1, Health).?.hp);
    try std.testing.expect(world.getComponent(e2, Health) == null);
}
