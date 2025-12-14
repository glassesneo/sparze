const std = @import("std");
const builtin = @import("builtin");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;
const EntityRegistry = entity_module.EntityRegistry;

const sparse_set_module = @import("../storage/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const tag_storage_module = @import("../storage/tag_storage.zig");
const TagStorage = tag_storage_module.TagStorage;

const component_storage_module = @import("../storage/component_storage.zig");
const ComponentStorage = component_storage_module.ComponentStorage;
const isTagComponent = component_storage_module.isTagComponent;

const event_storage_module = @import("../storage/event_storage.zig");
const EventStorage = event_storage_module.EventStorage;

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
    /// Resource filter: provides read-only access to a global resource
    resource,
    /// ResourceMut filter: provides mutable access to a global resource
    resource_mut,
    /// EventReader filter: reads events from the previous frame
    event_reader,
    /// EventWriter filter: writes events to the current frame
    event_writer,
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

        /// Bind directly to a component's sparse set; exposes every entity/component pair in packed order without additional filtering.
        pub fn init(sparse_set: *const SparseSet(Component)) Self {
            return .{
                .entities = sparse_set.packed_array.items,
                .components = sparse_set.components.items,
            };
        }

        /// Returns a cross-product iterator with another query
        pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator(Self, @TypeOf(other.*)) {
            return SimpleCrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
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
        entity_registry: *const EntityRegistry,

        /// Builds a runtime query anchored to the smallest component set to minimize iterations; callers must still invoke `filter(entity)` before accessing components.
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
                .entity_registry = &world.entity_registry,
            };
        }

        /// Maps a component type to its compile-time index within this query's component tuple; the position in the struct field list becomes the stable ID.
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

        /// Retrieve a component value copy for an entity via sparse-set lookup; panics if entity lacks the component (use after `filter()` to ensure presence).
        /// Cannot be used with tag components (zero-sized components).
        pub fn getComponent(self: Self, entity: Entity, comptime C: type) C {
            const storage = self.getComponentStoragePtr(C);
            return storage.*.get(entity).?;
        }

        /// Retrieve a mutable component pointer for an entity via sparse-set lookup; panics if entity lacks the component (use after `filter()` to ensure presence).
        /// Cannot be used with tag components (zero-sized components).
        pub fn getComponentMut(self: Self, entity: Entity, comptime C: type) *C {
            const sparse_set = self.getComponentStoragePtrMut(C);
            return sparse_set.*.getPtrMut(entity).?;
        }

        /// Retrieve a component value copy if present; returns null if the entity lacks the component (safe accessor for optional components marked with `?T`).
        pub fn getOptional(self: Self, entity: Entity, comptime C: type) ?C {
            const storage = self.getComponentStoragePtr(C);
            return storage.*.get(entity);
        }

        /// Retrieve a mutable component pointer if present; returns null if the entity lacks the component (safe accessor for optional components marked with `?T`).
        pub fn getOptionalMut(self: Self, entity: Entity, comptime C: type) ?*C {
            const sparse_set = self.getComponentStoragePtrMut(C);
            return sparse_set.*.getPtrMut(entity);
        }

        /// Check whether an entity satisfies all required components (respecting Optional/Exclude modifiers); returns false for destroyed entities in Debug/ReleaseSafe builds.
        pub fn filter(self: Self, entity: Entity) bool {
            // Early exit for destroyed entities (Debug/ReleaseSafe only)
            if (comptime builtin.mode != .ReleaseFast) {
                if (!self.entity_registry.isAlive(entity)) return false;
            }

            const GetStorage = struct {
                fn call(s: Self, comptime T: type) *const ComponentStorage(T) {
                    return s.getComponentStoragePtr(T);
                }
            };
            return filterWithModifiers(component_fields, entity, self, GetStorage.call);
        }

        /// Construct a stateful iterator that yields entities passing the filter one-by-one; manually advances position via `next()`.
        pub fn iterator(self: *Self) Iterator {
            return Iterator{
                .query = self,
            };
        }

        /// Construct a stateful iterator that yields all unique entity pairs (i < j) from this query; ideal for collision detection among entities of the same type.
        pub fn combinations(self: *const Self) CombinationIterator {
            return CombinationIterator{
                .query = self,
            };
        }

        pub const Iterator = struct {
            index: usize = 0,
            query: *const Query(QueryComponents),

            pub fn next(self: *Iterator) ?Entity {
                const index = self.index;
                for (self.query.entities[index..]) |entity| {
                    self.index += 1;
                    if (!self.query.filter(entity)) continue;
                    return entity;
                } else return null;
            }
        };

        pub const CombinationIterator = struct {
            i: usize = 0,
            j: usize = 1,
            query: *const Query(QueryComponents),

            pub fn next(self: *CombinationIterator) ?struct { Entity, Entity } {
                const entities = self.query.entities;

                // Continue searching for the next valid pair
                while (self.i < entities.len) {
                    const entity_i = entities[self.i];

                    // Optimized: check entity_i filter once before inner loop
                    const i_passes_filter = self.query.filter(entity_i);

                    // Skip inner loop if entity_i doesn't pass filter
                    if (!i_passes_filter) {
                        self.i += 1;
                        self.j = self.i + 1;
                        continue;
                    }

                    while (self.j < entities.len) {
                        const entity_j = entities[self.j];

                        // Move to next pair for subsequent call
                        self.j += 1;

                        // Only need to check entity_j since entity_i already passed
                        if (self.query.filter(entity_j)) {
                            return .{ entity_i, entity_j };
                        }
                    }

                    // Move to next i and reset j
                    self.i += 1;
                    self.j = self.i + 1;
                }

                return null;
            }
        };

        /// Returns a cross-product iterator with another query
        pub fn crossProduct(self: *const Self, other: anytype) CrossProductIterator(Self, @TypeOf(other.*)) {
            return CrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }
    };
}

/// CrossProductIterator provides iteration over the Cartesian product of two queries.
///
/// This iterator enables checking all pairs of entities between two different queries,
/// which is particularly useful for collision detection, interaction systems, or any
/// scenario where you need to check all entities from one query against all entities
/// from another query.
///
/// This version applies filters from both queries during iteration, used with Query and TagQuery types.
///
/// Example:
/// ```zig
/// fn collisionSystem(
///     projectile_query: Query(struct { Projectile, Transform, Collider }),
///     enemy_query: Query(struct { Enemy, Transform, Collider }),
/// ) !void {
///     var cross = projectile_query.crossProduct(&enemy_query);
///     while (cross.next()) |pair| {
///         const proj_entity, const enemy_entity = pair;
///         // Check collision between proj_entity and enemy_entity
///     }
/// }
/// ```
pub fn CrossProductIterator(comptime Query1: type, comptime Query2: type) type {
    return struct {
        const Self = @This();

        query1: *const Query1,
        query2: *const Query2,
        i: usize = 0,
        j: usize = 0,

        pub fn init(query1: *const Query1, query2: *const Query2) Self {
            return .{
                .query1 = query1,
                .query2 = query2,
            };
        }

        /// Returns the next pair of entities from the cross product.
        /// Returns null when all pairs have been exhausted.
        pub fn next(self: *Self) ?struct { Entity, Entity } {
            // Nested iteration: for each entity in query1, iterate all entities in query2
            while (self.i < self.query1.entities.len) {
                const entity1 = self.query1.entities[self.i];

                // Optimized: check entity1 filter once before inner loop
                const entity1_passes = self.query1.filter(entity1);

                // Skip inner loop if entity1 doesn't pass filter
                if (!entity1_passes) {
                    self.i += 1;
                    self.j = 0;
                    continue;
                }

                while (self.j < self.query2.entities.len) {
                    const entity2 = self.query2.entities[self.j];
                    self.j += 1;

                    // Only need to check entity2 since entity1 already passed
                    if (self.query2.filter(entity2)) {
                        return .{ entity1, entity2 };
                    }
                }
                self.i += 1;
                self.j = 0;
            }
            return null;
        }
    };
}

/// SimpleCrossProductIterator provides iteration over the Cartesian product of two queries
/// without filter application. Used with SingleQuery, SingleTag, and Group types.
///
/// Unlike CrossProductIterator, this version assumes all entities in both queries are valid
/// and doesn't call filter() methods. This is appropriate for SingleQuery and SingleTag
/// which represent pre-filtered sets of entities.
///
/// Example:
/// ```zig
/// fn collisionSystem(
///     projectile_tags: SingleTag(Projectile),
///     enemy_tags: SingleTag(Enemy),
/// ) !void {
///     var cross = projectile_tags.crossProduct(&enemy_tags);
///     while (cross.next()) |pair| {
///         const proj_entity, const enemy_entity = pair;
///         // Check collision between proj_entity and enemy_entity
///     }
/// }
/// ```
pub fn SimpleCrossProductIterator(comptime Query1: type, comptime Query2: type) type {
    return struct {
        const Self = @This();

        query1: *const Query1,
        query2: *const Query2,
        i: usize = 0,
        j: usize = 0,

        pub fn init(query1: *const Query1, query2: *const Query2) Self {
            return .{
                .query1 = query1,
                .query2 = query2,
            };
        }

        /// Returns the next pair of entities from the cross product.
        /// Returns null when all pairs have been exhausted.
        pub fn next(self: *Self) ?struct { Entity, Entity } {
            // Nested iteration: for each entity in query1, iterate all entities in query2
            while (self.i < self.query1.entities.len) {
                while (self.j < self.query2.entities.len) {
                    const entity1 = self.query1.entities[self.i];
                    const entity2 = self.query2.entities[self.j];
                    self.j += 1;

                    return .{ entity1, entity2 };
                }
                self.i += 1;
                self.j = 0;
            }
            return null;
        }
    };
}

/// Group is a query filter that provides optimized iteration over entities with multiple components.
///
/// Groups are defined at compile-time in the World signature and provide the fastest iteration
/// for multi-component queries. Entities in a group are stored at the beginning of all
/// component arrays, enabling cache-friendly sequential access.
///
/// Use Group for hot-path queries that run frequently (e.g., every frame) where
/// maximum performance is critical.
///
/// Example:
/// ```zig
/// const MovementGroup = struct { Position, Velocity };
/// const World = sparze.World(
///     Components,
///     Resources,
///     Events,
///     .{ MovementGroup },  // Groups defined at compile-time
/// );
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
            const ComponentType = extractFree(field.type);
            const SparseSetType = SparseSet(ComponentType);
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

        /// Captures sparse-set pointers for all group components; validates that the group is registered in the World definition (compile-time check).
        pub fn init(world: anytype) Self {
            // Compile-time validation: group must be registered in World
            const WorldType = @TypeOf(world.*);
            const group_idx = comptime WorldType.getGroupIndex(GroupComponents);
            _ = group_idx; // Group index validated at compile time

            var component_pool: GroupComponentPoolType = undefined;

            // Extract sparse set pointers for all group components (owned + free)
            inline for (component_fields, 0..) |field, i| {
                const ComponentType = extractFree(field.type);
                const sparse_set: *const SparseSet(ComponentType) = world.getSparseSetPtr(ComponentType);
                component_pool[i] = sparse_set;
            }

            return .{
                .group_component_pool = component_pool,
            };
        }

        /// Maps a component type to its compile-time index within this group's component tuple; the position in the struct field list becomes the stable ID.
        pub fn getComponentId(comptime C: type) u16 {
            // The order of components become the id
            return inline for (component_fields, 0..) |field, i| {
                const ComponentType = extractFree(field.type);
                if (C == ComponentType) break i;
            } else @compileError("Unknown component type: " ++ @typeName(C));
        }

        fn getSparseSetPtr(self: Self, comptime C: type) *const SparseSet(C) {
            const id = comptime getComponentId(C);
            return self.group_component_pool[id];
        }

        fn isOwned(comptime C: type) bool {
            return inline for (component_fields) |field| {
                const ComponentType = extractFree(field.type);
                if (C == ComponentType and !isFree(field.type)) break true;
            } else false;
        }

        /// Returns the slice of entities in the group-owned prefix; all entities in this slice are guaranteed to possess all owned components contiguously.
        pub fn getEntities(self: Self) []const Entity {
            // Use the first owned component's sparse set to get group entities
            // (At least one owned component is guaranteed by compile-time validation)
            return inline for (component_fields, 0..) |field, i| {
                if (!isFree(field.type)) break self.group_component_pool[i].getGroupEntities();
            } else unreachable;
        }

        /// Access the group-owned component array directly (cache-friendly sequential iteration); compile error if the component is marked Free.
        pub fn getArrayOf(self: Self, comptime C: type) []const C {
            if (!comptime isOwned(C)) {
                @compileError("Cannot use getArrayOf() on free component '" ++ @typeName(C) ++ "'. " ++
                    "Free components must be accessed via getComponent(entity, " ++ @typeName(C) ++ ") for each entity. " ++
                    "This is because free components are not organized in the group region and require sparse set lookup.");
            }
            return self.getSparseSetPtr(C).getGroupComponents();
        }

        /// Access the mutable group-owned component array for direct in-place updates; compile error if the component is marked Free.
        pub fn getMutArrayOf(self: Self, comptime C: type) []C {
            if (!comptime isOwned(C)) {
                @compileError("Cannot use getMutArrayOf() on free component '" ++ @typeName(C) ++ "'. " ++
                    "Free components must be accessed via getComponentMut(entity, " ++ @typeName(C) ++ ") for each entity. " ++
                    "This is because free components are not organized in the group region and require sparse set lookup.");
            }
            return self.getSparseSetPtr(C).getGroupComponentsMut();
        }

        /// Retrieve a component value copy for an entity; works for both owned (direct index) and free (sparse lookup) components; panics if entity lacks the component.
        pub fn getComponent(self: Self, entity: Entity, comptime C: type) C {
            const sparse_set = self.getSparseSetPtr(C);
            return sparse_set.get(entity).?;
        }

        /// Retrieve a mutable component pointer for an entity; works for both owned (direct index) and free (sparse lookup) components; panics if entity lacks the component.
        pub fn getComponentMut(self: Self, entity: Entity, comptime C: type) *C {
            const sparse_set = @constCast(self.getSparseSetPtr(C));
            return sparse_set.getPtrMut(entity).?;
        }

        /// Returns a cross-product iterator with another query
        pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator(Self, @TypeOf(other.*)) {
            return SimpleCrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }
    };
}

/// Tag-only iterator over entities that carry `TagComponent`; order follows the tag storage's swap-remove packed array and carries no component payload.
pub fn SingleTag(comptime TagComponent: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .single_tag;
        pub const Component = TagComponent;

        entities: []const Entity,

        /// Bind directly to a tag storage's packed entity array; exposes every entity carrying the tag in swap-remove order without additional filtering.
        pub fn init(tag_storage: *TagStorage(Component)) Self {
            return .{
                .entities = tag_storage.packed_array.items,
            };
        }

        /// Returns a cross-product iterator with another query
        pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator(Self, @TypeOf(other.*)) {
            return SimpleCrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
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
        entity_registry: *const EntityRegistry,

        /// Builds a runtime tag query anchored to the smallest tag storage to minimize iterations; callers must still invoke `filter(entity)` before processing.
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
                .entity_registry = &world.entity_registry,
            };
        }

        /// Maps a tag type to its compile-time index within this tag query's tag tuple; the position in the struct field list becomes the stable ID.
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

        /// Check whether an entity satisfies all required tags (respecting Optional/Exclude modifiers); returns false for destroyed entities in Debug/ReleaseSafe builds.
        pub fn filter(self: Self, entity: Entity) bool {
            // Early exit for destroyed entities (Debug/ReleaseSafe only)
            if (comptime builtin.mode != .ReleaseFast) {
                if (!self.entity_registry.isAlive(entity)) return false;
            }

            const GetStorage = struct {
                fn call(s: Self, comptime T: type) *const TagStorage(T) {
                    return s.getTagStoragePtr(T);
                }
            };
            return filterWithModifiers(tag_fields, entity, self, GetStorage.call);
        }

        /// Check whether an entity carries a specific tag (useful for optional tags marked with `?Tag` to query presence after matching).
        pub fn hasTag(self: Self, entity: Entity, comptime T: type) bool {
            return self.getTagStoragePtr(T).*.contains(entity);
        }

        /// Returns a cross-product iterator with another query
        pub fn crossProduct(self: *const Self, other: anytype) CrossProductIterator(Self, @TypeOf(other.*)) {
            return CrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }
    };
}

/// Resource provides read-only access to a global resource.
///
/// Resources are singleton data that can be accessed from any system.
/// Use Resource(T) for read-only access to enable potential parallel execution
/// of systems that only read from the same resource.
///
/// For mutable access, use ResourceMut(T) instead.
///
/// Example:
/// ```zig
/// fn renderSystem(config: Resource(RenderConfig)) !void {
///     // Read-only access to render configuration
///     const width = config.value.width;
///     const height = config.value.height;
/// }
/// ```
pub fn Resource(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const filter_type: FilterType = .resource;
        pub const ResourceType = T;
        value: *const T,

        pub fn init(value: *const T) Self {
            return .{
                .value = value,
            };
        }
    };
}

/// ResourceMut provides mutable access to a global resource.
///
/// Resources are singleton data that can be accessed from any system.
/// Use ResourceMut(T) when you need to modify the resource state.
///
/// For read-only access, use Resource(T) instead to enable better parallelization.
///
/// Example:
/// ```zig
/// fn scoreSystem(score: ResourceMut(Score)) !void {
///     // Mutable access to score resource
///     score.value.points += 100;
/// }
/// ```
pub fn ResourceMut(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const filter_type: FilterType = .resource_mut;
        pub const ResourceType = T;
        value: *T,

        pub fn init(value: *T) Self {
            return .{
                .value = value,
            };
        }
    };
}

/// EventReader provides read-only access to events from the previous frame.
///
/// Events are gathered in frame N and become available for reading in frame N+1.
/// This ensures stable event processing with no mid-frame mutations.
///
/// Example:
/// ```zig
/// fn collisionResponse(reader: EventReader(Collision)) !void {
///     for (reader.queue) |collision| {
///         // Process collision from previous frame
///     }
/// }
/// ```
pub fn EventReader(comptime E: type) type {
    return struct {
        const Self = @This();
        pub const filter_type: FilterType = .event_reader;
        pub const EventType = E;

        queue: []const E,

        pub fn init(storage: *const EventStorage(E)) Self {
            return .{
                .queue = storage.read_buffer.items,
            };
        }
    };
}

/// EventWriter provides write-only access to send events to the current frame.
///
/// Events written via EventWriter will become available for reading in the next frame.
/// Multiple systems can write to the same event type in a single frame.
///
/// Example:
/// ```zig
/// fn collisionDetection(
///     positions: Query(struct { Position }),
///     writer: EventWriter(Collision),
/// ) !void {
///     // Detect collisions
///     try writer.enqueue(.{ .entityA = e1, .entityB = e2 });
/// }
/// ```
pub fn EventWriter(comptime E: type) type {
    return struct {
        const Self = @This();
        pub const filter_type: FilterType = .event_writer;
        pub const EventType = E;

        storage: *EventStorage(E),

        pub fn init(storage: *EventStorage(E)) Self {
            return .{
                .storage = storage,
            };
        }

        /// Enqueue an event to the current frame's write buffer
        pub fn enqueue(self: Self, event: E) !void {
            return try self.storage.enqueue(event);
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

/// Exclude wraps a component type to mark it as an exclusion filter in queries; entities possessing the excluded component will be filtered out.
pub fn Exclude(comptime C: type) type {
    return struct {
        pub const Component = C;
        pub const modifier_type: ModifierType = .exclude;
    };
}

/// Free marks a component as "free" (not owned) in a partial-owning group.
/// Free components are accessed via indirection (sparse set lookup) rather than direct array access.
/// This allows components to be owned by one group while being used as free in other groups.
///
/// Example:
/// ```zig
/// const PhysicsGroup = struct { Position, Velocity, Free(Health) };
/// const CombatGroup = struct { Health, Shield };
/// const FullFreeGroup = struct { Free(Position), Free(Velocity) };
///
/// const World = sparze.World(
///     Components,
///     Resources,
///     Events,
///     .{ PhysicsGroup, CombatGroup, FullFreeGroup },
/// );
/// ```
pub fn Free(comptime C: type) type {
    return struct {
        pub const Component = C;
        pub const is_free = true;
    };
}

fn extractType(comptime T: type) struct { type, ?ModifierType } {
    if (isOptional(T))
        return .{ extractOptional(T), .optional };
    if (@hasDecl(T, "modifier_type"))
        return .{ T.Component, T.modifier_type };
    return .{ T, null };
}

fn isFree(comptime T: type) bool {
    return @hasDecl(T, "is_free") and T.is_free;
}

fn extractFree(comptime T: type) type {
    if (isFree(T)) return T.Component;
    return T;
}

/// Shared filter logic for Query and TagQuery that processes Optional/Exclude modifiers; iterates all required components/tags and returns true only if the entity satisfies all constraints.
///
/// Parameters:
///   - fields: The comptime field array to iterate over
///   - entity: The entity to check
///   - self: The query instance (Query or TagQuery)
///   - getStorageFn: A comptime function that returns storage pointer for a given type
inline fn filterWithModifiers(
    comptime fields: []const StructField,
    entity: Entity,
    self: anytype,
    comptime getStorageFn: anytype,
) bool {
    return inline for (fields) |field| {
        const T, const modifier_type = extractType(field.type);
        if (modifier_type) |modifier| switch (modifier) {
            .optional => continue,
            .exclude => {
                if (getStorageFn(self, T).*.contains(entity))
                    break false;
                continue;
            },
        };
        if (!getStorageFn(self, T).*.contains(entity))
            break false;
    } else true;
}
