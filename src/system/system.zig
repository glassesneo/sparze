const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;

const sparse_set_module = @import("../storage/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const tag_storage_module = @import("../storage/tag_storage.zig");
const TagStorage = tag_storage_module.TagStorage;

const component_storage_module = @import("../storage/component_storage.zig");
const ComponentStorage = component_storage_module.ComponentStorage;
const isTagComponent = component_storage_module.isTagComponent;

const filter_module = @import("../query/filter.zig");
pub const FilterType = filter_module.FilterType;
const SingleQuery = filter_module.SingleQuery;
const SingleTag = filter_module.SingleTag;
const Query = filter_module.Query;
const TagQuery = filter_module.TagQuery;
const Group = filter_module.Group;
const Exclude = filter_module.Exclude;

/// Command types for deferred entity/component operations
const CommandType = enum {
    add_component,
    remove_component,
    destroy_entity,
};

/// Type-erased component payload stored inline (no heap allocation); used by CommandBuffer to record component additions/removals with up to `max_size` bytes.
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

/// A single deferred command (add/remove component, destroy entity) with type-erased payload; stored in CommandBuffer and replayed at `endFrame()`.
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

        /// Initialize an empty command buffer with no pre-allocated capacity; commands will be recorded during system execution.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .commands = .{},
            };
        }

        /// Deinitialize the command buffer, freeing all recorded commands and the command array.
        pub fn deinit(self: *Self) void {
            for (self.commands.items) |*cmd| {
                cmd.deinit(self.allocator);
            }
            self.commands.deinit(self.allocator);
        }

        /// Clear all recorded commands while retaining allocated capacity; called after flush() to prepare for the next frame.
        pub fn clear(self: *Self) void {
            for (self.commands.items) |*cmd| {
                cmd.deinit(self.allocator);
            }
            self.commands.clearRetainingCapacity();
        }

        /// Append a component addition command with type-erased payload copied into inline storage (no heap allocation); returns error if component exceeds `max_component_size`.
        pub fn recordAddComponent(self: *Self, entity: Entity, type_id: u16, data: []const u8) !void {
            if (data.len > max_comp_size) return error.ComponentTooLarge;

            var comp_data: ComponentDataType = undefined;
            comp_data.type_id = type_id;
            comp_data.len = @intCast(data.len);
            // Copy bytes with explicit bounds check; use std.mem.copyForwards for consistency
            std.mem.copyForwards(u8, comp_data.data[0..data.len], data);

            try self.commands.append(self.allocator, .{
                .type = .add_component,
                .entity = entity,
                .component_data = comp_data,
            });
        }

        /// Append a component removal command; the component will be removed when flush() is called if the entity is still alive.
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

        /// Append an entity destruction command; the entity and all its components will be removed when flush() is called if the entity is still alive.
        pub fn recordDestroyEntity(self: *Self, entity: Entity) !void {
            try self.commands.append(self.allocator, .{
                .type = .destroy_entity,
                .entity = entity,
                .component_data = null,
            });
        }

        /// Replay buffered commands in recording order, skipping dead entities, then clear the buffer; used by `world.endFrame()` to execute all deferred operations.
        pub fn flush(self: *Self, world: *World) !void {
            for (self.commands.items) |*cmd| {
                switch (cmd.type) {
                    .add_component => {
                        // Skip if entity is not alive (prevents zombie entities)
                        if (!world.isAlive(cmd.entity)) continue;
                        const comp_data = cmd.component_data.?;
                        try world.addComponentFromBytes(cmd.entity, comp_data.type_id, comp_data.data[0..comp_data.len]);
                    },
                    .remove_component => {
                        // Skip if entity is not alive (prevents operations on dead entities)
                        if (!world.isAlive(cmd.entity)) continue;
                        const comp_data = cmd.component_data.?;
                        world.removeComponentById(cmd.entity, comp_data.type_id);
                    },
                    .destroy_entity => {
                        if (world.isAlive(cmd.entity)) {
                            world.destroyEntity(cmd.entity);
                        }
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

        /// Queue a zero-sized tag addition for deferred execution; compile-time errors if `C` is not a tag component (zero-sized struct).
        pub fn addTag(self: Self, entity: Entity, comptime C: type) !void {
            try self.addComponent(entity, C, C{});
        }

        /// Queue removal of a tag component; no-op if the entity lacks the tag when commands flush (deferred execution).
        pub fn removeTag(self: Self, entity: Entity, comptime C: type) !void {
            if (!isTagComponent(C)) @compileError("removeTag can only be used with tag components");
            try self.removeComponent(entity, C);
        }

        /// Access the const sparse-set pointer for a component type; allows direct read access to component storage (immediate execution).
        pub fn getSparseSetPtr(self: Self, comptime C: type) *const SparseSet(C) {
            return self.world.getSparseSetPtr(C);
        }

        /// Access the mutable sparse-set pointer for a component type; allows direct modification of component storage (immediate execution, use with caution during iteration).
        pub fn getSparseSetPtrMut(self: Self, comptime C: type) *SparseSet(C) {
            return self.world.getSparseSetPtrMut(C);
        }

        /// Destroy entity (deferred execution)
        pub fn destroyEntity(self: Self, entity: Entity) !void {
            try self.command_buffer.recordDestroyEntity(entity);
        }

        /// Serialize World state to writer
        ///
        /// Note: Pending commands in the command buffer are NOT serialized.
        /// Best practice: serialize between frames (after endFrame(), before beginFrame()).
        /// Groups must be recreated after deserialization.
        pub fn serialize(self: Self, writer: anytype) !void {
            return self.world.serialize(writer);
        }

        /// Deserialize World state from reader
        ///
        /// Note: This replaces the current World state. Any pending commands are cleared.
        /// Groups must be recreated after deserialization using world.createGroup().
        pub fn deserialize(self: Self, reader: anytype) !void {
            return self.world.deserialize(reader);
        }

        /// Serialize World state to file (convenience wrapper)
        ///
        /// Note: Pending commands in the command buffer are NOT serialized.
        /// Best practice: serialize between frames (after endFrame(), before beginFrame()).
        /// Groups must be recreated after deserialization.
        pub fn serializeToFile(self: Self, path: []const u8) !void {
            return self.world.serializeToFile(path);
        }

        /// Deserialize World state from file (convenience wrapper)
        ///
        /// Note: This replaces the current World state. Any pending commands are cleared.
        /// Groups must be recreated after deserialization using commands.createGroup().
        pub fn deserializeFromFile(self: Self, path: []const u8) !void {
            return self.world.deserializeFromFile(path);
        }

        /// Create a full-owning group for the given component types (immediate execution)
        ///
        /// Groups optimize multi-component iteration by organizing entities with all
        /// specified components at the start of packed arrays for cache-friendly access.
        ///
        /// Note: This operation executes immediately (not deferred like other Commands).
        /// Safe to call multiple times - returns early if group already exists.
        ///
        /// Example:
        /// ```zig
        /// fn setupSystem(commands: anytype) !void {
        ///     try commands.createGroup(struct { Position, Velocity });
        /// }
        /// ```
        pub fn createGroup(self: Self, comptime GroupComponents: type) !void {
            return self.world.createGroup(GroupComponents);
        }

        // ====================================================================
        // Resource Methods (immediate execution, delegate to World)
        // ====================================================================

        /// Set a resource value and mark it as initialized (immediate execution).
        ///
        /// Example:
        /// ```zig
        /// fn setupSystem(commands: anytype) !void {
        ///     commands.setResource(DeltaTime, .{ .dt = 0.016 });
        /// }
        /// ```
        pub fn setResource(self: Self, comptime R: type, resource: R) void {
            self.world.setResource(R, resource);
        }

        /// Get a copy of a resource value (immediate execution).
        /// Asserts in Debug/ReleaseSafe builds if resource is uninitialized.
        ///
        /// Example:
        /// ```zig
        /// fn readSystem(commands: anytype) !void {
        ///     const delta = commands.getResource(DeltaTime);
        ///     std.debug.print("dt: {}\n", .{delta.dt});
        /// }
        /// ```
        pub fn getResource(self: Self, comptime R: type) R {
            return self.world.getResource(R);
        }

        /// Get a const pointer to a resource (immediate execution).
        /// Asserts in Debug/ReleaseSafe builds if resource is uninitialized.
        ///
        /// Example:
        /// ```zig
        /// fn readSystem(commands: anytype) !void {
        ///     const config_ptr = commands.getResourcePtr(GameConfig);
        ///     std.debug.print("gravity: {}\n", .{config_ptr.gravity});
        /// }
        /// ```
        pub fn getResourcePtr(self: Self, comptime R: type) *const R {
            return self.world.getResourcePtr(R);
        }

        /// Get a mutable pointer to a resource (immediate execution).
        /// Asserts in Debug/ReleaseSafe builds if resource is uninitialized.
        ///
        /// Example:
        /// ```zig
        /// fn updateSystem(commands: anytype) !void {
        ///     const score_ptr = commands.getResourcePtrMut(Score);
        ///     score_ptr.points += 100;
        /// }
        /// ```
        pub fn getResourcePtrMut(self: Self, comptime R: type) *R {
            return self.world.getResourcePtrMut(R);
        }

        /// Try to get a const pointer to a resource, returning an error if uninitialized.
        /// This is a safe alternative to getResourcePtr() that provides runtime checking.
        ///
        /// Example:
        /// ```zig
        /// fn safeReadSystem(commands: anytype) !void {
        ///     const config_ptr = try commands.tryGetResource(GameConfig);
        ///     std.debug.print("gravity: {}\n", .{config_ptr.gravity});
        /// }
        /// ```
        pub fn tryGetResource(self: Self, comptime R: type) !*const R {
            return self.world.tryGetResource(R);
        }

        /// Try to get a mutable pointer to a resource, returning an error if uninitialized.
        /// This is a safe alternative to getResourcePtrMut() that provides runtime checking.
        ///
        /// Example:
        /// ```zig
        /// fn safeUpdateSystem(commands: anytype) !void {
        ///     const score_ptr = try commands.tryGetResourceMut(Score);
        ///     score_ptr.points += 100;
        /// }
        /// ```
        pub fn tryGetResourceMut(self: Self, comptime R: type) !*R {
            return self.world.tryGetResourceMut(R);
        }

        /// Initialize multiple resources at once using struct literal syntax (immediate execution).
        /// This is a convenience method for bulk initialization at startup.
        ///
        /// Example:
        /// ```zig
        /// fn initSystem(commands: anytype) !void {
        ///     try commands.initResources(.{
        ///         .delta_time = DeltaTime{ .dt = 0.016 },
        ///         .score = Score{ .points = 0 },
        ///         .config = GameConfig{ .gravity = 9.8 },
        ///     });
        /// }
        /// ```
        pub fn initResources(self: Self, resources: anytype) !void {
            return self.world.initResources(resources);
        }

        /// Check if a resource has been initialized (immediate execution).
        ///
        /// Example:
        /// ```zig
        /// fn checkSystem(commands: anytype) !void {
        ///     if (commands.isResourceInitialized(GameConfig)) {
        ///         const config = commands.getResource(GameConfig);
        ///         // Use config...
        ///     }
        /// }
        /// ```
        pub fn isResourceInitialized(self: Self, comptime R: type) bool {
            return self.world.isResourceInitialized(R);
        }
    };
}

/// Build a tuple type from a system function's parameter list at compile time; converts `anytype` parameters to Commands(World) and preserves all other types for parameter injection.
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
/// - Allocator: Use `std.mem.Allocator` to receive the World's allocator for dynamic allocations.
///
/// Example:
/// ```zig
/// fn mySystem(
///     allocator: std.mem.Allocator,
///     movement: Group(struct { Position, Velocity }),
///     health: SingleQuery(Health),
///     commands: anytype,
/// ) !void {
///     // Use allocator for temporary data structures
///     var list: std.ArrayList(Entity) = .{};
///     defer list.deinit(allocator);
///
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

                    // Check if it's Allocator type
                    if (ArgType == std.mem.Allocator) {
                        args[i] = world.allocator;
                    } else if (ArgType == CommandsType) {
                        // Check if it's Commands type (either explicit or anytype)
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
                            .resource => {
                                args[i] = ArgType.init(world.getResourcePtr(ArgType.ResourceType));
                            },
                            .resource_mut => {
                                args[i] = ArgType.init(world.getResourcePtrMut(ArgType.ResourceType));
                            },
                            .event_reader => {
                                args[i] = ArgType.init(world.getEventStoragePtr(ArgType.EventType));
                            },
                            .event_writer => {
                                args[i] = ArgType.init(world.getEventStoragePtrMut(ArgType.EventType));
                            },
                        }
                    } else {
                        @compileError("System parameter must be a query filter type, Commands, or Allocator. Got: " ++ @typeName(ArgType));
                    }
                }
                break :construct_args args;
            };

            if (system_type_info.return_type.? == void) {
                @call(.auto, system_fn, system_args);
            } else {
                try @call(.auto, system_fn, system_args);
            }
        }
    }.run;
}
