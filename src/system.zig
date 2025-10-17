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
};

/// Command types for deferred entity/component operations
const CommandType = enum {
    add_component,
    remove_component,
    destroy_entity,
};

/// Type-erased component data for command buffer with inline storage
fn ComponentData(comptime max_size: comptime_int) type {
    return struct {
        type_id: u16,
        data: [max_size]u8,
        len: u16,

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            // No-op: inline storage, nothing to free
        }
    };
}

/// A single command in the command buffer
fn Command(comptime max_size: comptime_int) type {
    return struct {
        type: CommandType,
        entity: Entity,
        component_data: ?ComponentData(max_size),

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.component_data) |*data| {
                data.deinit(allocator);
            }
        }
    };
}

/// CommandBuffer records entity and component operations for deferred execution.
///
/// Commands are executed at the end of a frame via `world.endFrame()`, ensuring
/// that the world state remains stable during system execution.
pub fn CommandBuffer(comptime World: type) type {
    const max_comp_size = World.max_component_size;
    const CommandStruct = Command(max_comp_size);
    const ComponentDataType = ComponentData(max_comp_size);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        commands: std.ArrayList(CommandStruct),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .commands = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.commands.items) |*cmd| {
                cmd.deinit(self.allocator);
            }
            self.commands.deinit(self.allocator);
        }

        pub fn clear(self: *Self) void {
            for (self.commands.items) |*cmd| {
                cmd.deinit(self.allocator);
            }
            self.commands.clearRetainingCapacity();
        }

        /// Record a component addition (inline storage, no heap allocation)
        pub fn recordAddComponent(self: *Self, entity: Entity, type_id: u16, data: []const u8) !void {
            if (data.len > max_comp_size) return error.ComponentTooLarge;

            var comp_data: ComponentDataType = undefined;
            comp_data.type_id = type_id;
            comp_data.len = @intCast(data.len);
            @memcpy(comp_data.data[0..data.len], data);

            try self.commands.append(self.allocator, .{
                .type = .add_component,
                .entity = entity,
                .component_data = comp_data,
            });
        }

        /// Record a component removal
        pub fn recordRemoveComponent(self: *Self, entity: Entity, type_id: u16) !void {
            try self.commands.append(self.allocator, .{
                .type = .remove_component,
                .entity = entity,
                .component_data = .{
                    .type_id = type_id,
                    .data = undefined, // not used for remove
                    .len = 0,
                },
            });
        }

        /// Record an entity destruction
        pub fn recordDestroyEntity(self: *Self, entity: Entity) !void {
            try self.commands.append(self.allocator, .{
                .type = .destroy_entity,
                .entity = entity,
                .component_data = null,
            });
        }

        /// Execute all recorded commands
        pub fn flush(self: *Self, world: *World) !void {
            for (self.commands.items) |*cmd| {
                switch (cmd.type) {
                    .add_component => {
                        const comp_data = cmd.component_data.?;
                        try world.addComponentFromBytes(cmd.entity, comp_data.type_id, comp_data.data[0..comp_data.len]);
                    },
                    .remove_component => {
                        const comp_data = cmd.component_data.?;
                        world.removeComponentById(cmd.entity, comp_data.type_id);
                    },
                    .destroy_entity => {
                        world.destroyEntity(cmd.entity);
                    },
                }
            }
            self.clear();
        }
    };
}

/// Commands provides a restricted API for entity/component manipulation within systems.
///
/// Unlike direct World access, Commands ensures safe, deferred execution of operations.
/// With Option C implementation: entities are created immediately, but component operations
/// are deferred until `world.endFrame()`.
///
/// Allowed operations:
/// - `createEntity()` - Create new entity (immediate)
/// - `createEntityWith(components)` - Create entity with components (immediate entity, deferred components)
/// - `addComponent(entity, C, component)` - Add component (deferred)
/// - `removeComponent(entity, C)` - Remove component (deferred)
/// - `destroyEntity(entity)` - Destroy entity (deferred)
///
/// Note: System functions should use `anytype` for commands parameters. Any `anytype` parameter
/// will receive Commands(World) at runtime. By convention, name the parameter `commands`.
///
/// Example:
/// ```zig
/// fn spawnEnemies(commands: anytype) !void {
///     const enemy = commands.createEntity();
///     try commands.addComponent(enemy, Position, .{ .x = 100, .y = 100 });
///     try commands.addComponent(enemy, Enemy, .{});
/// }
/// ```
pub fn Commands(comptime World: type) type {
    const CommandBufferType = CommandBuffer(World);

    return struct {
        const Self = @This();

        world: *World,
        command_buffer: *CommandBufferType,

        pub fn init(world: *World, command_buffer: *CommandBufferType) Self {
            return .{
                .world = world,
                .command_buffer = command_buffer,
            };
        }

        /// Create a new empty entity (immediate execution)
        pub fn createEntity(self: Self) Entity {
            return self.world.createEntity();
        }

        /// Create entity with components (immediate entity creation, deferred component addition)
        pub fn createEntityWith(self: Self, comptime components: anytype) !Entity {
            const entity = self.createEntity();
            inline for (components) |component| {
                const C = @TypeOf(component);
                try self.addComponent(entity, C, component);
            }
            return entity;
        }

        /// Add component to entity (deferred execution)
        pub fn addComponent(self: Self, entity: Entity, comptime C: type, component: C) !void {
            const type_id = comptime World.getComponentId(C);
            const bytes = std.mem.asBytes(&component);
            try self.command_buffer.recordAddComponent(entity, type_id, bytes);
        }

        /// Remove component from entity (deferred execution)
        pub fn removeComponent(self: Self, entity: Entity, comptime C: type) !void {
            const type_id = comptime World.getComponentId(C);
            try self.command_buffer.recordRemoveComponent(entity, type_id);
        }

        pub fn addTag(self: Self, entity: Entity, comptime C: type) !void {
            try self.addComponent(entity, C, C{});
        }

        pub fn removeTag(self: Self, entity: Entity, comptime C: type) !void {
            if (!isTagComponent(C)) @compileError("removeTag can only be used with tag components");
            try self.removeComponent(entity, C);
        }

        pub fn getSparseSetPtr(self: Self, comptime C: type) *const SparseSet(C) {
            return self.world.getSparseSetPtr(C);
        }

        pub fn getSparseSetPtrMut(self: Self, comptime C: type) *SparseSet(C) {
            return self.world.getSparseSetPtrMut(C);
        }

        /// Destroy entity (deferred execution)
        pub fn destroyEntity(self: Self, entity: Entity) !void {
            try self.command_buffer.recordDestroyEntity(entity);
        }
    };
}

/// SingleQuery is a query filter that provides iteration over entities with a single component.
///
/// This is the simplest and most efficient query filter for accessing entities with
/// a single component type. It provides direct access to packed component arrays for
/// cache-friendly iteration.
///
/// Example:
/// ```zig
/// fn healthSystem(query: SingleQuery(Health)) !void {
///     for (query.entities, query.components) |entity, health| {
///         // Process each entity with Health component
///     }
/// }
/// ```
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
///         if (query.hasAllComponents(entity)) {
///             const pos = query.getComponent(entity, Position).?;
///             if (query.getComponentMut(entity, Health)) |health| {
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
            const StorageType = ComponentStorage(field.type);
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
                const Component = field.type;
                const component_storage: *ComponentStorage(Component) = world.getComponentStoragePtr(Component);
                component_pool[i] = component_storage;
                const size = component_storage.packed_array.items.len;
                if (size < min_size) {
                    min_size = size;
                    candidate_entities = component_storage.packed_array.items;
                }
            }

            // Return a query that will iterate through the smallest set
            // Users must call hasAllComponents() to filter for entities with all components
            return .{
                .query_component_pool = component_pool,
                .entities = candidate_entities,
            };
        }

        pub fn getComponentId(comptime C: type) u16 {
            // The order of components become the id
            return inline for (component_fields, 0..) |field, i| {
                if (C == field.type) break i;
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
        pub fn getComponent(self: Self, entity: Entity, comptime C: type) ?C {
            const storage = self.getComponentStoragePtr(C);
            return storage.*.get(entity);
        }

        /// Get mutable component pointer for an entity
        /// Note: Cannot be used with tag components (zero-sized components)
        pub fn getComponentMut(self: Self, entity: Entity, comptime C: type) ?*C {
            const sparse_set = self.getComponentStoragePtrMut(C);
            return sparse_set.*.getPtrMut(entity);
        }

        /// Check if entity has all required components
        pub fn hasAllComponents(self: Self, entity: Entity) bool {
            return inline for (component_fields) |field| {
                if (!self.getComponentStoragePtr(field.type).*.contains(entity))
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
/// Use TagQuery when:
/// - You need multi-tag queries (e.g., entities with both Enemy and Boss tags)
/// - All components are tags (zero-sized markers)
/// - You want explicit type safety for tag-only queries
///
/// Example:
/// ```zig
/// fn bossEnemySystem(query: TagQuery(struct { Enemy, Boss })) !void {
///     for (query.entities) |entity| {
///         if (query.hasAllTags(entity)) {
///             // Process entities that are both enemies and bosses
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
        if (!isTagComponent(field.type)) {
            @compileError("TagQuery can only contain tag components (empty structs). Found non-tag: " ++ @typeName(field.type));
        }
    }

    const length = tag_fields.len;

    const TagPoolType = construct_tag_pool: {
        var query_fields: [length]StructField = undefined;
        inline for (tag_fields, 0..) |field, i| {
            const StorageType = TagStorage(field.type);
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
                const Tag = field.type;
                const tag_storage: *TagStorage(Tag) = world.getTagStoragePtr(Tag);
                tag_pool[i] = tag_storage;
                const size = tag_storage.packed_array.items.len;
                if (size < min_size) {
                    min_size = size;
                    candidate_entities = tag_storage.packed_array.items;
                }
            }

            // Return a query that will iterate through the smallest set
            // Users must call hasAllTags() to filter for entities with all tags
            return .{
                .tag_pool = tag_pool,
                .entities = candidate_entities,
            };
        }

        pub fn getTagId(comptime T: type) u16 {
            // The order of tags become the id
            return inline for (tag_fields, 0..) |field, i| {
                if (T == field.type) break i;
            } else @compileError("Unknown tag type: " ++ @typeName(T));
        }

        fn getTagStoragePtr(self: *const Self, comptime T: type) *const TagStorage(T) {
            const id = comptime getTagId(T);
            return self.tag_pool[id];
        }

        /// Check if entity has all required tags
        pub fn hasAllTags(self: Self, entity: Entity) bool {
            return inline for (tag_fields) |field| {
                if (!self.getTagStoragePtr(field.type).*.contains(entity))
                    break false;
            } else true;
        }
    };
}

fn constructSystemArgsType(comptime fn_info: std.builtin.Type.Fn, comptime World: type) type {
    const CommandsType = Commands(World);
    var fields: [fn_info.params.len]StructField = undefined;
    for (fn_info.params, 0..) |param, i| {
        const ArgType = if (param.type) |t|
            t
        else
            // anytype parameter - treat as Commands(World)
            CommandsType;

        fields[i] = StructField{
            .name = std.fmt.comptimePrint("{d}", .{i}),
            .type = ArgType,
            .is_comptime = false,
            .alignment = @alignOf(ArgType),
            .default_value_ptr = null,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .is_tuple = true,
        .decls = &.{},
        .fields = &fields,
    } });
}

/// Create a system function for a specific World type that can be called with world.runSystem(system_fn).
///
/// This function converts a user-defined system function (which accepts query filter parameters)
/// into a function that can be executed by the World. It automatically resolves and injects
/// the appropriate query filters based on the system function's parameter types.
///
/// System functions can accept multiple parameter types:
/// - Query filters: SingleQuery(Component), Query(struct { A, B, ... }), Group(struct { A, B })
/// - Commands: Use `anytype` for parameters that should receive Commands(World). By convention,
///   name such parameters `commands`.
///
/// Example:
/// ```zig
/// fn mySystem(
///     movement: Group(struct { Position, Velocity }),
///     health: SingleQuery(Health),
///     commands: anytype,
/// ) !void {
///     // Query data and spawn entities
///     const enemy = commands.createEntity();
///     try commands.addComponent(enemy, Position, .{ .x = 100, .y = 100 });
/// }
///
/// const system = createSystemFunction(World, mySystem);
/// try system(&world);
/// ```
pub fn createSystemFunction(comptime World: type, comptime system_fn: anytype) fn (*World) anyerror!void {
    const system_type_info = switch (@typeInfo(@TypeOf(system_fn))) {
        .@"fn" => |f| f,
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(system_fn))),
    };

    const SystemArgsType = constructSystemArgsType(system_type_info, World);
    const CommandsType = Commands(World);

    return struct {
        fn run(world: *World) !void {
            const system_args = construct_args: {
                var args: SystemArgsType = undefined;
                inline for (system_type_info.params, 0..) |param, i| {
                    // If param.type is null (anytype), treat it as Commands
                    const ArgType = param.type orelse CommandsType;

                    // Check if it's Commands type (either explicit or anytype)
                    if (ArgType == CommandsType) {
                        args[i] = CommandsType.init(world, &world.command_buffer);
                    } else if (@hasDecl(ArgType, "filter_type")) {
                        // It's a query filter
                        const filter_type: FilterType = ArgType.filter_type;
                        switch (filter_type) {
                            .single_query => {
                                args[i] = ArgType.init(world.getSparseSetPtr(ArgType.Component));
                            },
                            .query => {
                                args[i] = ArgType.init(world);
                            },
                            .group => {
                                args[i] = ArgType.init(world);
                            },
                            .single_tag => {
                                args[i] = ArgType.init(world.getTagStoragePtr(ArgType.Component));
                            },
                            .tag_query => {
                                args[i] = ArgType.init(world);
                            },
                        }
                    } else {
                        @compileError("System parameter must be a query filter type or Commands. Got: " ++ @typeName(ArgType));
                    }
                }
                break :construct_args args;
            };

            try @call(.auto, system_fn, system_args);
        }
    }.run;
}

test "FixedSingleQuery basic iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity });

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

test "FixedGroup query basic usage" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity });

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

test "FixedWorld system function with SingleQuery" {
    const Position = struct { x: f32, y: f32 };

    const TestWorld = @import("world.zig").World(struct { Position });

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

test "FixedWorld system function with Group" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity });

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

test "FixedWorld system with multiple queries" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health });

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

test "FixedQuery basic iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health });

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
        if (query.hasAllComponents(entity)) {
            count += 1;
            const pos = query.getComponent(entity, Position).?;
            const vel = query.getComponent(entity, Velocity).?;
            try std.testing.expect(pos.x > 0.0);
            try std.testing.expect(vel.dx > 0.0);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "FixedQuery with mutable component access" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity });

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
        if (query.hasAllComponents(entity)) {
            const vel = query.getComponent(entity, Velocity).?;
            if (query.getComponentMut(entity, Position)) |pos| {
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

test "FixedWorld system function with Query" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health });

    const CombatSystem = struct {
        fn system(query: Query(struct { Position, Health })) !void {
            for (query.entities) |entity| {
                if (query.hasAllComponents(entity)) {
                    const pos = query.getComponent(entity, Position).?;
                    if (query.getComponentMut(entity, Health)) |health| {
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

test "FixedQuery three components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = @import("world.zig").World(struct { Position, Velocity, Health });

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
        if (query.hasAllComponents(entity)) {
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

    const TestWorld = @import("world.zig").World(struct { Player, Active, Enemy });

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
        if (query.hasAllTags(entity)) {
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

    const TestWorld = @import("world.zig").World(struct { Player, Active, Boss, Enemy });

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
        if (query.hasAllTags(entity)) {
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

    const TestWorld = @import("world.zig").World(struct { Player, Enemy, Boss });

    const BossEnemySystem = struct {
        fn system(query: TagQuery(struct { Enemy, Boss })) !void {
            var count: usize = 0;
            for (query.entities) |entity| {
                if (query.hasAllTags(entity)) {
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

    const TestWorld = @import("world.zig").World(struct { Player, Enemy, Boss });

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
        if (query.hasAllTags(entity)) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), count);
}
