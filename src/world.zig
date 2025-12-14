const std = @import("std");
const builtin = @import("builtin");
const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;
const Allocator = std.mem.Allocator;
pub const ArrayList = std.ArrayList;

const entity_module = @import("entity/entity.zig");
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;

const sparse_set_module = @import("storage/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const tag_storage_module = @import("storage/tag_storage.zig");
const TagStorage = tag_storage_module.TagStorage;

const component_storage_module = @import("storage/component_storage.zig");
const ComponentStorage = component_storage_module.ComponentStorage;
const isTagComponent = component_storage_module.isTagComponent;

const filter_module = @import("query/filter.zig");
pub const SingleQuery = filter_module.SingleQuery;
pub const Query = filter_module.Query;
pub const Group = filter_module.Group;
pub const SingleTag = filter_module.SingleTag;
pub const TagQuery = filter_module.TagQuery;
pub const Resource = filter_module.Resource;
pub const ResourceMut = filter_module.ResourceMut;
pub const EventReader = filter_module.EventReader;
pub const EventWriter = filter_module.EventWriter;
pub const Free = filter_module.Free;
pub const Exclude = filter_module.Exclude;

const event_storage_module = @import("storage/event_storage.zig");
pub const EventStorage = event_storage_module.EventStorage;

const system_module = @import("system/system.zig");
pub const Commands = system_module.Commands;
pub const CommandBuffer = system_module.CommandBuffer;
pub const createSystemFunction = system_module.createSystemFunction;

// Helper to check if a type is wrapped in Free()
fn isFree(comptime T: type) bool {
    return @hasDecl(T, "is_free") and T.is_free;
}

// Helper to extract component type from Free() wrapper
fn extractComponent(comptime T: type) type {
    if (isFree(T)) return T.Component;
    return T;
}

/// Helper structure to hold parsed group signature information
fn GroupKey(comptime owned_count: usize, comptime free_count: usize) type {
    return struct {
        owned_ids: [owned_count]u16,
        free_ids: [free_count]u16,
    };
}

/// Construct a compile-time ECS World factory from component/resource/event/group type tuples; returns a type that can be instantiated with `init(allocator)`.
pub fn World(Components: anytype, Resources: anytype, Events: anytype, Groups: anytype) type {
    const component_info = @typeInfo(Components);
    if (component_info != .@"struct") @compileError("Invalid form of components");
    const component_fields = component_info.@"struct".fields;
    const component_pool_length = component_fields.len;
    const resource_info = @typeInfo(Resources);
    if (resource_info != .@"struct") @compileError("Invalid form of resources");
    const resource_fields = resource_info.@"struct".fields;
    const resource_pool_length = resource_fields.len;
    const event_info = @typeInfo(Events);
    if (event_info != .@"struct") @compileError("Invalid form of events");
    const event_fields = event_info.@"struct".fields;
    const event_pool_length = event_fields.len;

    // Validate Groups is a tuple
    const groups_type_info = @typeInfo(@TypeOf(Groups));
    if (groups_type_info != .@"struct" or !groups_type_info.@"struct".is_tuple) {
        @compileError("Groups must be a tuple, e.g., .{ struct { A, B }, struct { C, D } }");
    }

    const group_fields = std.meta.fields(@TypeOf(Groups));
    const groups_count = group_fields.len;

    const ComponentPoolType = if (component_pool_length == 0) @TypeOf(.{}) else construct_component_pool: {
        var pool_fields: [component_pool_length]StructField = undefined;
        inline for (component_fields, 0..) |field, i| {
            const FieldType = ComponentStorage(field.type);

            pool_fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = FieldType,
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
                .default_value_ptr = null,
            };
        }
        break :construct_component_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &pool_fields,
        } });
    };

    const ResourcePoolType = if (resource_pool_length == 0) @TypeOf(.{}) else construct_resource_pool: {
        var pool_fields: [resource_pool_length]StructField = undefined;
        inline for (resource_fields, 0..) |field, i| {
            const FieldType = field.type;

            pool_fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = FieldType,
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
                .default_value_ptr = null,
            };
        }
        break :construct_resource_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &pool_fields,
        } });
    };

    const EventPoolType = if (event_pool_length == 0) @TypeOf(.{}) else construct_event_pool: {
        var pool_fields: [event_pool_length]StructField = undefined;
        inline for (event_fields, 0..) |field, i| {
            const FieldType = EventStorage(field.type);

            pool_fields[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = FieldType,
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
                .default_value_ptr = null,
            };
        }
        break :construct_event_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &pool_fields,
        } });
    };

    return struct {
        const Self = @This();

        /// Maximum component size in this world (computed at comptime)
        pub const max_component_size: comptime_int = blk: {
            if (component_pool_length == 0) break :blk 1;
            var max_size: comptime_int = 1;
            for (component_fields) |field| {
                const size = @sizeOf(field.type);
                if (size > max_size) max_size = size;
            }
            break :blk max_size;
        };

        pub const max_resource_size: comptime_int = blk: {
            if (resource_pool_length == 0) break :blk 1;
            var max_size: comptime_int = 1;
            for (resource_fields) |field| {
                const size = @sizeOf(field.type);
                if (size > max_size) max_size = size;
            }
            break :blk max_size;
        };

        allocator: Allocator,
        entity_registry: EntityRegistry,
        component_pool: ComponentPoolType,
        resource_pool: ResourcePoolType,
        resource_initialized: if (resource_pool_length == 0) void else std.StaticBitSet(resource_pool_length),
        event_pool: EventPoolType,
        command_buffer: CommandBuffer(Self),

        /// Initialize an empty World with zeroed resources (uninitialized), empty component/event storages, and groups populated with existing entities; resources must be initialized with `setResource()` or `initResources()` before use.
        pub fn init(allocator: Allocator) Self {
            var self = Self{
                .allocator = allocator,
                .entity_registry = .init(),
                .component_pool = init: {
                    var pool: ComponentPoolType = undefined;
                    inline for (component_fields, 0..) |field, i| {
                        pool[i] = ComponentStorage(field.type).init(allocator);
                    }
                    break :init pool;
                },
                .resource_pool = if (resource_pool_length == 0) .{} else std.mem.zeroes(ResourcePoolType),
                .resource_initialized = if (resource_pool_length == 0) {} else std.StaticBitSet(resource_pool_length).initEmpty(),
                .event_pool = init: {
                    var pool: EventPoolType = undefined;
                    inline for (event_fields, 0..) |field, i| {
                        pool[i] = EventStorage(field.type).init(allocator);
                    }
                    break :init pool;
                },
                .command_buffer = .init(allocator),
            };

            // Populate all groups with existing entities
            if (groups_count > 0) {
                self.populateAllGroups();
            }

            return self;
        }

        /// Deinitialize the World, freeing all component storages, event storages, and the command buffer.
        pub fn deinit(self: *Self) void {
            self.command_buffer.deinit();
            // Group metadata is compile-time data, no deallocation needed
            inline for (component_fields) |field| {
                self.getComponentStoragePtr(field.type).deinit();
            }
            inline for (event_fields, 0..) |_, i| {
                self.event_pool[i].deinit();
            }
        }

        /// Populate all compile-time groups with existing entities
        fn populateAllGroups(self: *Self) void {
            if (groups_count == 0) return;

            inline for (group_fields) |field| {
                const GroupType = @field(Groups, field.name);
                const sig = comptime parseGroupSignature(GroupType);

                // Need at least one owned component to iterate
                if (sig.owned_ids.len == 0) continue;

                // Iterate first owned component's storage (comptime-known index)
                // Note: Could optimize by finding shortest set, but tuple indexing requires comptime
                const first_owned_id = sig.owned_ids[0];
                const storage = &self.component_pool[first_owned_id];
                for (storage.packed_array.items) |entity| {
                    // Check if entity has all required components (owned + free)
                    var has_all = true;
                    inline for (sig.owned_ids) |id| {
                        if (!self.component_pool[id].contains(entity)) {
                            has_all = false;
                            break;
                        }
                    }
                    if (has_all) {
                        inline for (sig.free_ids) |id| {
                            if (!self.component_pool[id].contains(entity)) {
                                has_all = false;
                                break;
                            }
                        }
                    }

                    if (has_all) {
                        // Add to group by moving owned components to group region
                        inline for (sig.owned_ids) |id| {
                            self.component_pool[id].moveToGroup(entity);
                        }
                    }
                }
            }
        }

        /// Map a component type to its compile-time index in the component pool; the position in the Components struct field list becomes the stable ID.
        pub fn getComponentId(comptime C: type) u16 {
            // The order of components become the id
            return inline for (component_fields, 0..) |field, i| {
                if (C == field.type) break i;
            } else @compileError("Unknown component type: " ++ @typeName(C));
        }

        /// Map a resource type to its compile-time index in the resource pool; the position in the Resources struct field list becomes the stable ID.
        pub fn getResourceId(comptime R: type) u16 {
            // The order of resources become the id
            return inline for (resource_fields, 0..) |field, i| {
                if (R == field.type) break i;
            } else @compileError("Unknown resource type: " ++ @typeName(R));
        }

        /// Map an event type to its compile-time index in the event pool; the position in the Events struct field list becomes the stable ID.
        pub fn getEventId(comptime E: type) u16 {
            // The order of events become the id
            return inline for (event_fields, 0..) |field, i| {
                if (E == field.type) break i;
            } else @compileError("Unknown event type: " ++ @typeName(E));
        }

        /// Compile-time validation for multiple groups to detect overlaps.
        ///
        /// This validates that:
        /// 1. All component types exist in this world
        /// 2. No component appears in multiple groups (which would break the full-owning group model)
        ///
        /// Usage:
        /// ```zig
        /// const World = FixedWorld(struct { A, B, C, D });
        ///
        /// // Validate all groups upfront - compile error if overlapping
        /// World.validateGroups(.{
        ///     struct { A, B },
        ///     struct { C, D },
        /// });
        /// ```
        ///
        /// This is the recommended approach - declare all groups upfront for compile-time safety.
        pub fn validateGroups(comptime groups: anytype) void {
            const groups_info = @typeInfo(@TypeOf(groups));
            if (groups_info != .@"struct" or !groups_info.@"struct".is_tuple) {
                @compileError("validateGroups expects a tuple of group types");
            }

            const group_list = groups_info.@"struct".fields;

            // Validate each group's components are in this world
            inline for (group_list) |group_field| {
                const GroupType = @field(groups, group_field.name);
                const group_comp_fields = comptime std.meta.fields(GroupType);
                inline for (group_comp_fields) |field| {
                    // Extract actual component type (unwrap Free())
                    const ComponentType = extractComponent(field.type);
                    _ = getComponentId(ComponentType);
                }
            }

            // Check each pair of groups for OWNED component overlap
            // Free components can be shared between groups
            inline for (group_list, 0..) |group1_field, i| {
                const Group1Type = @field(groups, group1_field.name);
                const group1_fields = comptime std.meta.fields(Group1Type);

                inline for (group_list, 0..) |group2_field, j| {
                    if (i >= j) continue;

                    const Group2Type = @field(groups, group2_field.name);
                    const group2_fields = comptime std.meta.fields(Group2Type);

                    inline for (group1_fields) |field1| {
                        // Only check owned components
                        if (comptime isFree(field1.type)) continue;

                        inline for (group2_fields) |field2| {
                            // Only check owned components
                            if (comptime isFree(field2.type)) continue;

                            const comp1 = extractComponent(field1.type);
                            const comp2 = extractComponent(field2.type);

                            if (comp1 == comp2) {
                                @compileError("Groups have overlapping OWNED component: " ++ @typeName(comp1) ++
                                    " appears as owned in both " ++ @typeName(Group1Type) ++ " and " ++ @typeName(Group2Type) ++
                                    ". Use Free(" ++ @typeName(comp1) ++ ") in one of the groups to mark it as free (not owned).");
                            }
                        }
                    }
                }
            }
        }

        /// Parse a group signature to extract owned and free component IDs
        /// This helper deduplicates the logic used by both createGroup and getGroup
        fn parseGroupSignature(comptime GroupComponents: type) GroupKey(
            blk: {
                const group_comp_fields = std.meta.fields(GroupComponents);
                var count: usize = 0;
                for (group_comp_fields) |field| {
                    if (!isFree(field.type)) count += 1;
                }
                break :blk count;
            },
            blk: {
                const group_comp_fields = std.meta.fields(GroupComponents);
                var count: usize = 0;
                for (group_comp_fields) |field| {
                    if (isFree(field.type)) count += 1;
                }
                break :blk count;
            },
        ) {
            const group_comp_fields = comptime std.meta.fields(GroupComponents);

            // Validate: reject tag components in groups
            inline for (group_comp_fields) |field| {
                const ComponentType = extractComponent(field.type);
                if (component_storage_module.isTagComponent(ComponentType)) {
                    @compileError("Tag components cannot be used in groups: " ++ @typeName(ComponentType) ++
                        ". Groups require regular (non-zero-sized) components for SparseSet storage. " ++
                        "Use TagQuery or Query with tag components instead.");
                }
            }

            // Validate: detect duplicate components
            inline for (group_comp_fields, 0..) |field1, i| {
                const ComponentType1 = extractComponent(field1.type);
                const is_free1 = isFree(field1.type);
                inline for (group_comp_fields[i + 1 ..]) |field2| {
                    const ComponentType2 = extractComponent(field2.type);
                    const is_free2 = isFree(field2.type);
                    if (ComponentType1 == ComponentType2) {
                        if (is_free1 == is_free2) {
                            @compileError("Duplicate component in group: " ++ @typeName(ComponentType1) ++
                                " appears multiple times. Each component can only appear once.");
                        } else {
                            @compileError("Component appears as both owned and Free in group: " ++ @typeName(ComponentType1) ++
                                ". A component must be either owned or Free, not both.");
                        }
                    }
                }
            }

            // Count owned and free components
            const owned_count = comptime blk: {
                var count: usize = 0;
                for (group_comp_fields) |field| {
                    if (!isFree(field.type)) count += 1;
                }
                break :blk count;
            };

            const free_count = comptime blk: {
                var count: usize = 0;
                for (group_comp_fields) |field| {
                    if (isFree(field.type)) count += 1;
                }
                break :blk count;
            };

            // Build owned component ID array (sorted for order-insensitive matching)
            const owned_ids = comptime blk: {
                var ids: [owned_count]u16 = undefined;
                var idx: usize = 0;
                for (group_comp_fields) |field| {
                    if (!isFree(field.type)) {
                        const ComponentType = extractComponent(field.type);
                        ids[idx] = getComponentId(ComponentType);
                        idx += 1;
                    }
                }
                // Sort for canonical ordering
                std.mem.sort(u16, &ids, {}, std.sort.asc(u16));
                break :blk ids;
            };

            // Build free component ID array (sorted for order-insensitive matching)
            const free_ids = comptime blk: {
                var ids: [free_count]u16 = undefined;
                var idx: usize = 0;
                for (group_comp_fields) |field| {
                    if (isFree(field.type)) {
                        const ComponentType = extractComponent(field.type);
                        ids[idx] = getComponentId(ComponentType);
                        idx += 1;
                    }
                }
                // Sort for canonical ordering
                std.mem.sort(u16, &ids, {}, std.sort.asc(u16));
                break :blk ids;
            };

            return .{
                .owned_ids = owned_ids,
                .free_ids = free_ids,
            };
        }

        /// Helper to check if two group signatures match
        fn signaturesMatch(comptime sig1: anytype, comptime sig2: anytype) bool {
            if (sig1.owned_ids.len != sig2.owned_ids.len) return false;
            if (sig1.free_ids.len != sig2.free_ids.len) return false;

            for (sig1.owned_ids, sig2.owned_ids) |id1, id2| {
                if (id1 != id2) return false;
            }
            for (sig1.free_ids, sig2.free_ids) |id1, id2| {
                if (id1 != id2) return false;
            }
            return true;
        }

        /// Validate groups at compile time (automatic validation - no need to call manually)
        const _group_validation = if (groups_count > 0) blk: {
            // Validate each group has at least one owned component
            for (group_fields) |field| {
                const GroupType = @field(Groups, field.name);
                const sig = parseGroupSignature(GroupType);
                if (sig.owned_ids.len == 0) {
                    @compileError("Group " ++ @typeName(GroupType) ++ " must have at least one owned component. All components are marked as Free().");
                }
            }

            // Check for duplicate groups
            for (group_fields, 0..) |field, i| {
                const GroupType = @field(Groups, field.name);
                for (group_fields[i + 1 ..]) |other_field| {
                    const OtherType = @field(Groups, other_field.name);
                    if (signaturesMatch(parseGroupSignature(GroupType), parseGroupSignature(OtherType))) {
                        @compileError("Duplicate group detected: " ++ @typeName(GroupType) ++ " and " ++ @typeName(OtherType) ++ " have the same signature");
                    }
                }
            }

            // Check for ownership conflicts
            for (group_fields, 0..) |field1, i| {
                const Group1Type = @field(Groups, field1.name);
                const sig1 = parseGroupSignature(Group1Type);

                for (group_fields, 0..) |field2, j| {
                    if (i >= j) continue;

                    const Group2Type = @field(Groups, field2.name);
                    const sig2 = parseGroupSignature(Group2Type);

                    for (sig1.owned_ids) |id1| {
                        for (sig2.owned_ids) |id2| {
                            if (id1 == id2) {
                                // Get component names for better error message
                                for (component_fields, 0..) |comp_field, comp_i| {
                                    if (comp_i == id1) {
                                        @compileError("Groups have overlapping OWNED component: " ++ @typeName(comp_field.type) ++
                                            " appears as owned in both " ++ @typeName(Group1Type) ++ " and " ++ @typeName(Group2Type) ++
                                            ". Use Free(" ++ @typeName(comp_field.type) ++ ") in one of the groups to mark it as free (not owned).");
                                    }
                                }
                            }
                        }
                    }
                }
            }

            break :blk {};
        } else {};

        /// Get the compile-time index of a group by its type signature
        pub fn getGroupIndex(comptime GroupType: type) usize {
            if (groups_count == 0) {
                @compileError("No groups registered in World. Add groups to the Groups tuple in World definition.");
            }

            return inline for (group_fields, 0..) |field, i| {
                const RegisteredType = @field(Groups, field.name);
                const query_sig = comptime parseGroupSignature(GroupType);
                const reg_sig = comptime parseGroupSignature(RegisteredType);

                if (signaturesMatch(query_sig, reg_sig)) {
                    break i;
                }
            } else @compileError(
                "Group " ++ @typeName(GroupType) ++ " not registered in World. " ++
                    "Add it to the Groups tuple in World definition.",
            );
        }

        pub fn getComponentStorage(self: Self, comptime C: type) ComponentStorage(C) {
            const id = comptime getComponentId(C);
            return self.component_pool[id];
        }

        pub fn getComponentStoragePtr(self: *Self, comptime C: type) *ComponentStorage(C) {
            const id = comptime getComponentId(C);
            return &self.component_pool[id];
        }

        /// Get SparseSet storage for non-tag components
        /// Note: Only works for non-tag components (components with fields)
        pub fn getSparseSet(self: Self, comptime C: type) SparseSet(C) {
            return self.getComponentStorage(C);
        }

        /// Get SparseSet pointer for non-tag components
        /// Note: Only works for non-tag components (components with fields)
        pub fn getSparseSetPtr(self: *Self, comptime C: type) *const SparseSet(C) {
            // ComponentStorage(C) is SparseSet(C) for non-tag components
            return @ptrCast(self.getComponentStoragePtr(C));
        }

        /// Get mutable SparseSet pointer for non-tag components
        /// Note: Only works for non-tag components (components with fields)
        pub fn getSparseSetPtrMut(self: *Self, comptime C: type) *SparseSet(C) {
            // ComponentStorage(C) is SparseSet(C) for non-tag components
            return @ptrCast(self.getComponentStoragePtr(C));
        }

        /// Get TagStorage for tag components
        /// Note: Only works for tag components (empty structs)
        pub fn getTagStorage(self: Self, comptime C: type) TagStorage(C) {
            return self.getComponentStorage(C);
        }

        /// Get TagStorage pointer for tag components
        /// Note: Only works for tag components (empty structs)
        pub fn getTagStoragePtr(self: *Self, comptime C: type) *TagStorage(C) {
            // ComponentStorage(C) is TagStorage(C) for tag components
            return @ptrCast(self.getComponentStoragePtr(C));
        }

        /// Retrieve a copy of a resource value; panics in Debug/ReleaseSafe if the resource is uninitialized (zero-cost in ReleaseFast).
        pub fn getResource(self: Self, comptime R: type) R {
            const id = comptime getResourceId(R);
            // Debug-mode assertion to catch uninitialized resource access
            if (comptime resource_pool_length > 0 and builtin.mode != .ReleaseFast) {
                std.debug.assert(self.resource_initialized.isSet(id));
            }
            return self.resource_pool[id];
        }

        /// Retrieve a const pointer to a resource; panics in Debug/ReleaseSafe if the resource is uninitialized (zero-cost in ReleaseFast).
        pub fn getResourcePtr(self: *Self, comptime R: type) *const R {
            const id = comptime getResourceId(R);
            // Debug-mode assertion to catch uninitialized resource access
            if (comptime resource_pool_length > 0 and builtin.mode != .ReleaseFast) {
                std.debug.assert(self.resource_initialized.isSet(id));
            }
            return &self.resource_pool[id];
        }

        /// Retrieve a mutable pointer to a resource; panics in Debug/ReleaseSafe if the resource is uninitialized (zero-cost in ReleaseFast).
        pub fn getResourcePtrMut(self: *Self, comptime R: type) *R {
            const id = comptime getResourceId(R);
            // Debug-mode assertion to ensure resource is initialized before mutation
            if (comptime resource_pool_length > 0 and builtin.mode != .ReleaseFast) {
                std.debug.assert(self.resource_initialized.isSet(id));
            }
            return &self.resource_pool[id];
        }

        /// Try to get a const pointer to a resource, returning an error if uninitialized.
        /// This is a safe alternative to getResourcePtr() that provides runtime checking.
        ///
        /// Example:
        /// ```zig
        /// const config_ptr = try world.tryGetResource(GameConfig);
        /// std.debug.print("Gravity: {}\n", .{config_ptr.gravity});
        /// ```
        pub fn tryGetResource(self: *Self, comptime R: type) !*const R {
            const id = comptime getResourceId(R);
            if (comptime resource_pool_length > 0) {
                if (!self.resource_initialized.isSet(id)) {
                    return error.UninitializedResource;
                }
            }
            return &self.resource_pool[id];
        }

        /// Try to get a mutable pointer to a resource, returning an error if uninitialized.
        /// This is a safe alternative to getResourcePtrMut() that provides runtime checking.
        ///
        /// Example:
        /// ```zig
        /// const state_ptr = try world.tryGetResourceMut(GameState);
        /// state_ptr.score += 100;
        /// ```
        pub fn tryGetResourceMut(self: *Self, comptime R: type) !*R {
            const id = comptime getResourceId(R);
            if (comptime resource_pool_length > 0) {
                if (!self.resource_initialized.isSet(id)) {
                    return error.UninitializedResource;
                }
            }
            return &self.resource_pool[id];
        }

        /// Store a resource value and mark it as initialized; subsequent calls to `getResource()` will succeed without panic.
        pub fn setResource(self: *Self, comptime R: type, resource: R) void {
            const id = comptime getResourceId(R);
            self.resource_pool[id] = resource;
            if (comptime resource_pool_length > 0) {
                self.resource_initialized.set(id);
            }
        }

        /// Initialize multiple resources at once using struct literal syntax.
        /// This is a convenience method for bulk initialization at startup.
        ///
        /// Example:
        /// ```zig
        /// try world.initResources(.{
        ///     .delta_time = DeltaTime{ .dt = 0.016 },
        ///     .score = Score{ .points = 0 },
        ///     .config = GameConfig{ .gravity = 9.8 },
        /// });
        /// ```
        pub fn initResources(self: *Self, resources: anytype) !void {
            const info = @typeInfo(@TypeOf(resources));
            switch (info) {
                .@"struct" => |struct_info| {
                    inline for (struct_info.fields) |field| {
                        const ResourceType = @TypeOf(@field(resources, field.name));
                        self.setResource(ResourceType, @field(resources, field.name));
                    }
                },
                else => @compileError("initResources expects a struct literal"),
            }
        }

        /// Mark a resource as initialized.
        /// This should be called after directly mutating resource_pool[i] to ensure
        /// the resource can be serialized. Prefer using setResource()
        /// which automatically marks resources as initialized.
        pub fn markResourceInitialized(self: *Self, comptime R: type) void {
            if (comptime resource_pool_length > 0) {
                const id = comptime getResourceId(R);
                self.resource_initialized.set(id);
            }
        }

        pub fn isResourceInitialized(self: *const Self, comptime R: type) bool {
            if (comptime resource_pool_length == 0) {
                return false;
            } else {
                const id = comptime getResourceId(R);
                return self.resource_initialized.isSet(id);
            }
        }

        /// Access the mutable event storage for an event type; enables direct writes to the current frame's write buffer via EventWriter.
        pub fn getEventStoragePtrMut(self: *Self, comptime E: type) *EventStorage(E) {
            const id = comptime getEventId(E);
            return &self.event_pool[id];
        }

        /// Access the const event storage for an event type; enables direct reads from the previous frame's read buffer via EventReader.
        pub fn getEventStoragePtr(self: *const Self, comptime E: type) *const EventStorage(E) {
            const id = comptime getEventId(E);
            return &self.event_pool[id];
        }

        /// Allocate a new entity handle; reuses recycled indices when available. Panics in Debug/ReleaseSafe if exceeding max_entities; in ReleaseFast causes out-of-bounds write (undefined behavior). Complexity: O(1).
        pub fn createEntity(self: *Self) Entity {
            return self.entity_registry.create();
        }

        /// Destroys an Entity and removes it from all registered component pools. The entity identifier becomes invalid and may be recycled for future entities. CRITICAL: Must only be called on live entities; double-destroy corrupts the free list. Complexity: O(c) where c = number of registered component types.
        pub fn destroyEntity(self: *Self, entity: Entity) void {
            self.entity_registry.destroy(entity);
            inline for (component_fields) |field| {
                self.removeComponent(entity, field.type);
            }
        }

        /// Add a component to an entity (immediate execution); dispatches to addTag for zero-sized components (no group update) or sparse-set insert for regular components (with group membership update).
        pub fn addComponent(self: *Self, entity: Entity, comptime C: type, component: C) !void {
            if (comptime isTagComponent(C)) {
                try self.addTag(entity, C);
            } else {
                try self.getSparseSetPtrMut(C).insert(entity, component);

                // Update groups when component is added
                const component_id = comptime getComponentId(C);
                self.updateGroupsOnAdd(entity, component_id);
            }
        }

        /// Add multiple components to an entity from a tuple (immediate execution); iterates the tuple and calls addComponent() for each component.
        pub fn addComponents(self: *Self, entity: Entity, comptime components: anytype) !void {
            inline for (components) |component| {
                const C = @TypeOf(component);
                try self.addComponent(entity, C, component);
            }
        }

        /// Add a tag component to an entity
        /// Note: Only works for tag components (empty structs)
        pub fn addTag(self: *Self, entity: Entity, comptime C: type) !void {
            try self.getTagStoragePtr(C).set(entity);
        }

        /// Add multiple tag components to an entity
        pub fn addTags(self: *Self, entity: Entity, comptime tags: anytype) !void {
            inline for (tags) |tag| {
                const C = @TypeOf(tag);
                try self.addTag(entity, C);
            }
        }

        /// Deserialize a component from type-erased bytes and add it to an entity (used by CommandBuffer to replay deferred commands); validates size and dispatches to `addComponent()`.
        pub fn addComponentFromBytes(self: *Self, entity: Entity, type_id: u16, bytes: []const u8) !void {
            inline for (component_fields, 0..) |field, i| {
                if (i == type_id) {
                    const C = field.type;
                    if (isTagComponent(C)) {
                        try self.addTag(entity, C);
                        return;
                    }
                    if (bytes.len != @sizeOf(C)) return error.InvalidComponentSize;
                    // Copy into properly aligned storage to avoid unaligned access (e.g., on wasm)
                    var component: C = undefined;
                    const dst = std.mem.asBytes(&component);
                    std.mem.copyForwards(u8, dst, bytes[0..@sizeOf(C)]);
                    try self.addComponent(entity, C, component);
                    return;
                }
            }
            return error.InvalidComponentId;
        }

        /// Retrieve a component value copy if the entity possesses it; returns null if absent (compile error for tag components—use `hasComponent()` instead).
        pub fn getComponent(self: *Self, entity: Entity, comptime C: type) ?C {
            if (comptime isTagComponent(C)) @compileError("Cannot get tag component value, use hasComponent to check for tag presence");
            return self.getSparseSetPtr(C).get(entity);
        }

        /// Check whether an entity handle is still valid (index allocated and version matches); returns false for recycled/destroyed entities.
        pub fn isAlive(self: Self, entity: Entity) bool {
            return self.entity_registry.isAlive(entity);
        }

        /// Check whether an entity possesses a specific component (works for both regular and tag components).
        pub fn hasComponent(self: Self, entity: Entity, comptime C: type) bool {
            return self.getComponentStorage(C).contains(entity);
        }

        /// Remove a component from an entity (immediate execution); dispatches to removeTag for zero-sized components or sparse-set remove for regular components, updating groups if needed.
        pub fn removeComponent(self: *Self, entity: Entity, comptime C: type) void {
            if (comptime isTagComponent(C)) {
                self.removeTag(entity, C);
            } else {
                // Update groups before removing component
                const component_id = comptime getComponentId(C);
                self.updateGroupsOnRemove(entity, component_id);

                self.getSparseSetPtrMut(C).remove(entity);
            }
        }

        /// Remove a tag component from an entity
        /// Note: Only works for tag components (empty structs)
        pub fn removeTag(self: *Self, entity: Entity, comptime C: type) void {
            self.getTagStoragePtr(C).unset(entity);
        }

        /// Remove component by ID (used by CommandBuffer)
        pub fn removeComponentById(self: *Self, entity: Entity, type_id: u16) void {
            inline for (component_fields, 0..) |field, i| {
                if (i == type_id) {
                    self.removeComponent(entity, field.type);
                    return;
                }
            }
        }

        /// Create an entity and immediately attach all components from a tuple (immediate execution); equivalent to `createEntity()` followed by `addComponents()`.
        pub fn createEntityWith(self: *Self, comptime components: anytype) !Entity {
            const entity = self.createEntity();
            try self.addComponents(entity, components);
            return entity;
        }

        /// NOTE: createGroup() has been removed. Groups are now defined at compile-time in the World signature.
        /// Old: try world.createGroup(struct { A, B });
        /// New: const World = sparze.World(Components, Resources, Events, .{ struct { A, B } });
        /// Update groups when component is added to entity (compile-time dispatch)
        fn updateGroupsOnAdd(self: *Self, entity: Entity, component_id: u16) void {
            if (groups_count == 0) return;

            inline for (group_fields) |field| {
                const GroupType = @field(Groups, field.name);
                const sig = comptime parseGroupSignature(GroupType);

                // Check if component is in this group (inline for generates code for each ID)
                const is_in_group = blk: {
                    inline for (sig.owned_ids ++ sig.free_ids) |id| {
                        if (id == component_id) break :blk true;
                    }
                    break :blk false;
                };

                if (is_in_group) {
                    var has_all = true;

                    // Check owned components
                    inline for (sig.owned_ids) |id| {
                        if (!self.component_pool[id].contains(entity)) {
                            has_all = false;
                            break;
                        }
                    }

                    // Check free components
                    if (has_all) {
                        inline for (sig.free_ids) |id| {
                            if (!self.component_pool[id].contains(entity)) {
                                has_all = false;
                                break;
                            }
                        }
                    }

                    // Add to group by moving owned components to group region
                    if (has_all) {
                        inline for (sig.owned_ids) |id| {
                            self.component_pool[id].moveToGroup(entity);
                        }
                    }
                }
            }
        }

        /// Update groups when component is removed from entity (compile-time dispatch)
        fn updateGroupsOnRemove(self: *Self, entity: Entity, component_id: u16) void {
            if (groups_count == 0) return;

            inline for (group_fields) |field| {
                const GroupType = @field(Groups, field.name);
                const sig = comptime parseGroupSignature(GroupType);

                // Check if component is in this group (inline for generates code for each ID)
                const is_in_group = blk: {
                    inline for (sig.owned_ids ++ sig.free_ids) |id| {
                        if (id == component_id) break :blk true;
                    }
                    break :blk false;
                };

                if (is_in_group) {
                    // Only move owned components from group region
                    inline for (sig.owned_ids) |id| {
                        self.component_pool[id].moveFromGroup(entity);
                    }
                }
            }
        }

        /// Begin a new frame - swaps event buffers and clears command buffer
        ///
        /// This makes events from frame N-1 available for reading in frame N,
        /// and prepares a clean write buffer for new events in frame N.
        pub fn beginFrame(self: *Self) void {
            // Swap and clear event buffers for all event types
            inline for (event_fields, 0..) |_, i| {
                self.event_pool[i].swap();
                self.event_pool[i].clear();
            }
            self.command_buffer.clear();
        }

        /// End frame - executes all recorded commands
        pub fn endFrame(self: *Self) !void {
            try self.command_buffer.flush(self);
        }

        /// Convenience method to run a system directly
        pub fn runSystem(self: *Self, comptime system_fn: anytype) !void {
            const system = comptime system_module.createSystemFunction(Self, system_fn);
            try system(self);
        }

        /// Serialize the World to a writer
        /// Writes complete world state including entities, components, resources, and events (read buffer only)
        ///
        /// Example:
        /// ```zig
        /// const file = try std.fs.cwd().createFile("save.spze", .{});
        /// defer file.close();
        /// try world.serialize(file.writer());
        /// ```
        pub fn serialize(self: *const Self, writer: anytype) !void {
            const world_ser = @import("serialization/world.zig");
            try world_ser.serialize(self, Components, Resources, Events, writer);
        }

        /// Deserialize the World from a reader
        /// Loads complete world state including entities, components, resources, and events
        /// Validates type metadata hash to ensure compatibility
        ///
        /// Note: Groups are compile-time defined and automatically repopulated after deserialization
        ///
        /// Example:
        /// ```zig
        /// const file = try std.fs.cwd().openFile("save.spze", .{});
        /// defer file.close();
        /// try world.deserialize(file.reader());
        /// ```
        pub fn deserialize(self: *Self, reader: anytype) !void {
            const world_ser = @import("serialization/world.zig");
            try world_ser.deserialize(self, Components, Resources, Events, reader);

            // Repopulate all groups with loaded entities
            self.populateAllGroups();
        }

        /// Serialize the World to a file
        /// Convenience method that handles file I/O
        ///
        /// Example:
        /// ```zig
        /// try world.serializeToFile("save.spze");
        /// ```
        pub fn serializeToFile(self: *const Self, path: []const u8) !void {
            const world_ser = @import("serialization/world.zig");
            try world_ser.serializeToFile(self, Components, Resources, Events, path);
        }

        /// Deserialize the World from a file
        /// Convenience method that handles file I/O
        ///
        /// Note: Groups are automatically repopulated after deserialization
        ///
        /// Example:
        /// ```zig
        /// try world.deserializeFromFile("save.spze");
        /// ```
        pub fn deserializeFromFile(self: *Self, path: []const u8) !void {
            const world_ser = @import("serialization/world.zig");
            try world_ser.deserializeFromFile(self, Components, Resources, Events, path);

            // Repopulate all groups with loaded entities
            self.populateAllGroups();
        }
    };
}

test "Resource basic access" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.resource_pool[0] = .{ .gravity = 9.8, .max_speed = 100.0 };
    world.markResourceInitialized(GameConfig);

    // Get resource via ID
    try std.testing.expectEqual(@as(u16, 0), TestWorld.getResourceId(GameConfig));

    // Get resource value
    const config = world.getResource(GameConfig);
    try std.testing.expectEqual(@as(f32, 9.8), config.gravity);
    try std.testing.expectEqual(@as(f32, 100.0), config.max_speed);
}

test "Resource mutation via pointer" {
    const GameState = struct {
        score: i32,
        level: i32,
    };

    const TestWorld = World(struct {}, struct { GameState }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.resource_pool[0] = .{ .score = 0, .level = 1 };
    world.markResourceInitialized(GameState);

    // Get mutable pointer and modify
    const state = world.getResourcePtrMut(GameState);
    state.score += 100;
    state.level += 1;

    // Verify mutations
    try std.testing.expectEqual(@as(i32, 100), world.getResource(GameState).score);
    try std.testing.expectEqual(@as(i32, 2), world.getResource(GameState).level);

    // Get const pointer
    const const_state = world.getResourcePtr(GameState);
    try std.testing.expectEqual(@as(i32, 100), const_state.score);
}

test "Multiple resources" {
    const GameConfig = struct {
        gravity: f32,
    };
    const GameState = struct {
        score: i32,
    };
    const AudioSettings = struct {
        volume: f32,
        muted: bool,
    };

    const TestWorld = World(struct {}, struct { GameConfig, GameState, AudioSettings }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resources
    world.resource_pool[0] = .{ .gravity = 9.8 };
    world.resource_pool[1] = .{ .score = 0 };
    world.resource_pool[2] = .{ .volume = 0.8, .muted = false };
    world.markResourceInitialized(GameConfig);
    world.markResourceInitialized(GameState);
    world.markResourceInitialized(AudioSettings);

    // Verify resource IDs
    try std.testing.expectEqual(@as(u16, 0), TestWorld.getResourceId(GameConfig));
    try std.testing.expectEqual(@as(u16, 1), TestWorld.getResourceId(GameState));
    try std.testing.expectEqual(@as(u16, 2), TestWorld.getResourceId(AudioSettings));

    // Verify all resources are accessible
    try std.testing.expectEqual(@as(f32, 9.8), world.getResource(GameConfig).gravity);
    try std.testing.expectEqual(@as(i32, 0), world.getResource(GameState).score);
    try std.testing.expectEqual(@as(f32, 0.8), world.getResource(AudioSettings).volume);
    try std.testing.expect(!world.getResource(AudioSettings).muted);
}

test "Resource in system function" {
    const DeltaTime = struct {
        dt: f32,
    };
    const Position = struct { x: f32, y: f32 };

    const TestWorld = World(struct { Position }, struct { DeltaTime }, struct {}, .{});

    const UpdateSystem = struct {
        fn system(delta: Resource(DeltaTime), query: SingleQuery(Position)) !void {
            const dt = delta.value.dt;
            for (query.components) |*pos| {
                pos.x += 10.0 * dt;
                pos.y += 5.0 * dt;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.resource_pool[0] = .{ .dt = 0.016 }; // 60 FPS
    world.markResourceInitialized(DeltaTime);

    // Create entities
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 100.0, .y = 200.0 });

    // Run system
    try world.runSystem(UpdateSystem.system);

    // Verify positions updated based on delta time
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), world.getComponent(e1, Position).?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.08), world.getComponent(e1, Position).?.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.16), world.getComponent(e2, Position).?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200.08), world.getComponent(e2, Position).?.y, 0.001);
}

test "Resource mutation in system function" {
    const Score = struct {
        points: i32,
        combo: i32,
    };
    const Enemy = struct {};

    const TestWorld = World(struct { Enemy }, struct { Score }, struct {}, .{});

    const ScoreSystem = struct {
        fn system(score: ResourceMut(Score), query: SingleTag(Enemy)) !void {
            for (query.entities) |_| {
                score.value.points += 100;
                score.value.combo += 1;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.resource_pool[0] = .{ .points = 0, .combo = 0 };
    world.markResourceInitialized(Score);

    // Create enemies
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    const e3 = world.createEntity();
    try world.addTag(e3, Enemy);

    // Run system
    try world.runSystem(ScoreSystem.system);

    // Verify score was updated for each enemy
    try std.testing.expectEqual(@as(i32, 300), world.getResource(Score).points);
    try std.testing.expectEqual(@as(i32, 3), world.getResource(Score).combo);
}

test "System with multiple resources" {
    const DeltaTime = struct { dt: f32 };
    const GameConfig = struct { speed_multiplier: f32 };
    const Position = struct { x: f32, y: f32 };

    const TestWorld = World(struct { Position }, struct { DeltaTime, GameConfig }, struct {}, .{});

    const MoveSystem = struct {
        fn system(
            delta: Resource(DeltaTime),
            config: Resource(GameConfig),
            query: SingleQuery(Position),
        ) !void {
            const dt = delta.value.dt;
            const multiplier = config.value.speed_multiplier;

            for (query.components) |*pos| {
                pos.x += 100.0 * dt * multiplier;
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resources
    world.resource_pool[0] = .{ .dt = 0.016 };
    world.resource_pool[1] = .{ .speed_multiplier = 2.0 };
    world.markResourceInitialized(DeltaTime);
    world.markResourceInitialized(GameConfig);

    // Create entity
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });

    // Run system
    try world.runSystem(MoveSystem.system);

    // Verify position updated with both delta time and multiplier
    // 100.0 * 0.016 * 2.0 = 3.2
    try std.testing.expectApproxEqAbs(@as(f32, 3.2), world.getComponent(e1, Position).?.x, 0.001);
}

test "System with resource, allocator, query, and commands" {
    const Score = struct { value: i32 };
    const Enemy = struct {};
    const Position = struct { x: f32, y: f32 };

    const TestWorld = World(struct { Enemy, Position }, struct { Score }, struct {}, .{});

    const ComplexSystem = struct {
        fn system(
            allocator: std.mem.Allocator,
            score: ResourceMut(Score),
            enemies: SingleTag(Enemy),
            commands: anytype,
        ) !void {
            // Use allocator to track spawn positions
            var spawn_positions: std.ArrayList(f32) = .{};
            defer spawn_positions.deinit(allocator);

            // Process each enemy, tracking score
            for (enemies.entities) |_| {
                score.value.value += 100;
                try spawn_positions.append(allocator, @as(f32, @floatFromInt(score.value.value)));
            }

            // Spawn new entities at calculated positions
            for (spawn_positions.items) |x| {
                const entity = commands.createEntity();
                try commands.addComponent(entity, Position, .{ .x = x, .y = 0.0 });
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.resource_pool[0] = .{ .value = 0 };
    world.markResourceInitialized(Score);

    // Create enemies
    const e1 = world.createEntity();
    try world.addTag(e1, Enemy);

    const e2 = world.createEntity();
    try world.addTag(e2, Enemy);

    // Run system with commands
    world.beginFrame();
    try world.runSystem(ComplexSystem.system);
    try world.endFrame();

    // Verify score was updated
    try std.testing.expectEqual(@as(i32, 200), world.getResource(Score).value);

    // Verify entities were spawned with positions
    const pos_query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 2), pos_query.entities.len);
    try std.testing.expectEqual(@as(f32, 100.0), pos_query.components[0].x);
    try std.testing.expectEqual(@as(f32, 200.0), pos_query.components[1].x);
}

test "World with components and resources together" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const DeltaTime = struct { dt: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct { DeltaTime }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resource
    world.resource_pool[0] = .{ .dt = 0.016 };
    world.markResourceInitialized(DeltaTime);

    // Create entity with components
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(entity, Velocity, .{ .dx = 10.0, .dy = 5.0 });

    // Verify both component and resource work together
    try std.testing.expect(world.hasComponent(entity, Position));
    try std.testing.expect(world.hasComponent(entity, Velocity));
    try std.testing.expectEqual(@as(f32, 0.016), world.getResource(DeltaTime).dt);
}
test "Create World" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try std.testing.expectEqual(0, TestWorld.getComponentId(Position));
    try std.testing.expectEqual(1, TestWorld.getComponentId(Velocity));
}

test "World entity creation and destruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestWorld = World(struct {}, struct {}, struct {}, .{});

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const e1 = world.createEntity();
    const e2 = world.createEntity();

    try std.testing.expect(world.entity_registry.isAlive(e1));
    try std.testing.expect(world.entity_registry.isAlive(e2));
    try std.testing.expectEqual(@as(usize, 2), world.entity_registry.aliveCount());

    world.destroyEntity(e1);
    try std.testing.expect(!world.entity_registry.isAlive(e1));
    try std.testing.expect(world.entity_registry.isAlive(e2));
    try std.testing.expectEqual(@as(usize, 1), world.entity_registry.aliveCount());
}

test "World component registration and operations" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestWorld = World(struct { TestComp }, struct {}, struct {}, .{});

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try world.addComponent(entity, TestComp, .{ .value = 42 });

    const retrieved = world.getComponent(entity, TestComp);
    try std.testing.expectEqual(@as(i32, 42), retrieved.?.value);

    // Test component not found after entity destruction
    world.destroyEntity(entity);
    try std.testing.expect(world.getComponent(entity, TestComp) == null);
}

test "World multiple components and batch operations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {}, .{});

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try world.addComponents(entity, .{
        Position{ .x = 10.0, .y = 20.0 },
        Velocity{ .dx = 1.0, .dy = -1.0 },
    });

    const pos = world.getComponent(entity, Position).?;
    const vel = world.getComponent(entity, Velocity).?;

    try std.testing.expectEqual(@as(f32, 10.0), pos.x);
    try std.testing.expectEqual(@as(f32, 20.0), pos.y);
    try std.testing.expectEqual(@as(f32, 1.0), vel.dx);
    try std.testing.expectEqual(@as(f32, -1.0), vel.dy);
}

test "World isAlive entity validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestWorld = World(struct {}, struct {}, struct {}, .{});

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try std.testing.expect(world.isAlive(entity));

    world.destroyEntity(entity);
    try std.testing.expect(!world.isAlive(entity));

    // Test with never-allocated entity
    const fake_entity = Entity.fromInt(999999);
    try std.testing.expect(!world.isAlive(fake_entity));
}

test "World hasComponent queries" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestWorld = World(struct { TestComp }, struct {}, struct {}, .{});

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();

    // Initially no component
    try std.testing.expect(!world.hasComponent(entity, TestComp));

    // Add component
    try world.addComponent(entity, TestComp, .{ .value = 42 });
    try std.testing.expect(world.hasComponent(entity, TestComp));

    // Destroy entity - should no longer have component
    world.destroyEntity(entity);
    try std.testing.expect(!world.hasComponent(entity, TestComp));
}

test "World removeComponent operation" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestWorld = World(struct { TestComp }, struct {}, struct {}, .{});

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try world.addComponent(entity, TestComp, .{ .value = 42 });

    // Verify component exists
    try std.testing.expect(world.hasComponent(entity, TestComp));
    try std.testing.expectEqual(@as(i32, 42), world.getComponent(entity, TestComp).?.value);

    // Remove component
    world.removeComponent(entity, TestComp);
    try std.testing.expect(!world.hasComponent(entity, TestComp));
    try std.testing.expect(world.getComponent(entity, TestComp) == null);

    // Removing non-existent component should not crash
    world.removeComponent(entity, TestComp);
    try std.testing.expect(world.isAlive(entity)); // Entity should still be alive
}

test "World createEntityWith batch creation" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entity with multiple components
    const entity = try world.createEntityWith(.{
        Position{ .x = 5.0, .y = 10.0 },
        Velocity{ .dx = 2.0, .dy = -1.0 },
    });

    // Verify entity is alive and has both components
    try std.testing.expect(world.isAlive(entity));
    try std.testing.expect(world.hasComponent(entity, Position));
    try std.testing.expect(world.hasComponent(entity, Velocity));

    const pos = world.getComponent(entity, Position).?;
    const vel = world.getComponent(entity, Velocity).?;

    try std.testing.expectEqual(@as(f32, 5.0), pos.x);
    try std.testing.expectEqual(@as(f32, 10.0), pos.y);
    try std.testing.expectEqual(@as(f32, 2.0), vel.dx);
    try std.testing.expectEqual(@as(f32, -1.0), vel.dy);
}

// Test obsolete - groups now compile-time
// test "World group creation and basic operations" {
//     const Position = struct { x: f32, y: f32 };
//     const Velocity = struct { dx: f32, dy: f32 };
//     const Health = struct { hp: i32 };
//
//     const TestWorld = World(struct { Position, Velocity, Health }, struct {}, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Create group for Position and Velocity
//     // Groups now compile-time: // try world.createGroup(struct { Position, Velocity });
//
//     // Verify group was created
//     const group = world.getGroup(struct { Position, Velocity });
//     try std.testing.expect(group != null);
//     try std.testing.expectEqual(@as(usize, 2), group.?.owned_component_ids.len);
//     try std.testing.expectEqual(@as(usize, 0), group.?.free_component_ids.len);
//
//     // Create entities with different component combinations
//     const e1 = world.createEntity();
//     const e2 = world.createEntity();
//     const e3 = world.createEntity();
//
//     // e1 has both Position and Velocity (in group)
//     try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
//     try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
//
//     // e2 has only Position (not in group)
//     try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
//
//     // e3 has both Position and Velocity (in group)
//     try world.addComponent(e3, Position, .{ .x = 5.0, .y = 6.0 });
//     try world.addComponent(e3, Velocity, .{ .dx = 1.5, .dy = 2.0 });
//
//     // Verify group entities
//     const group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
//     try std.testing.expectEqual(@as(usize, 2), group_entities.len);
//
//     // Verify we can get group components
//     const positions = world.getGroupComponents(struct { Position, Velocity }, Position).?;
//     const velocities = world.getGroupComponents(struct { Position, Velocity }, Velocity).?;
//
//     try std.testing.expectEqual(@as(usize, 2), positions.len);
//     try std.testing.expectEqual(@as(usize, 2), velocities.len);
// }

// Test obsolete - groups now compile-time
// test "World group dynamic membership" {
//     const Position = struct { x: f32, y: f32 };
//     const Velocity = struct { dx: f32, dy: f32 };
//
//     const TestWorld = World(struct { Position, Velocity }, struct {}, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Create entities first
//     const e1 = world.createEntity();
//     const e2 = world.createEntity();
//
//     try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
//     try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
//     try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 1.0 });
//
//     // Create group - should include e2 only
//     // Groups now compile-time: // try world.createGroup(struct { Position, Velocity });
//
//     var group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
//     try std.testing.expectEqual(@as(usize, 1), group_entities.len);
//
//     // Add Velocity to e1 - should join group
//     try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 0.5 });
//
//     group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
//     try std.testing.expectEqual(@as(usize, 2), group_entities.len);
//
//     // Remove Velocity from e1 - should leave group
//     world.removeComponent(e1, Velocity);
//
//     group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
//     try std.testing.expectEqual(@as(usize, 1), group_entities.len);
// }

// Test obsolete - groups now compile-time
// test "World group mutable component access" {
//     const Position = struct { x: f32, y: f32 };
//     const Velocity = struct { dx: f32, dy: f32 };
//
//     const TestWorld = World(struct { Position, Velocity }, struct {}, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Groups now compile-time: // try world.createGroup(struct { Position, Velocity });
//
//     const e1 = world.createEntity();
//     try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
//     try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });
//
//     const e2 = world.createEntity();
//     try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
//     try world.addComponent(e2, Velocity, .{ .dx = 1.5, .dy = 2.0 });
//
//     // Get mutable access to group components
//     const positions = world.getGroupComponentsMut(struct { Position, Velocity }, Position).?;
//     const velocities = world.getGroupComponentsMut(struct { Position, Velocity }, Velocity).?;
//
//     try std.testing.expectEqual(@as(usize, 2), positions.len);
//     try std.testing.expectEqual(@as(usize, 2), velocities.len);
//
//     // Modify components
//     for (positions) |*pos| {
//         pos.x += 10.0;
//         pos.y += 10.0;
//     }
//
//     for (velocities) |*vel| {
//         vel.dx *= 2.0;
//         vel.dy *= 2.0;
//     }
//
//     // Verify modifications
//     const pos1 = world.getComponent(e1, Position).?;
//     try std.testing.expectEqual(@as(f32, 11.0), pos1.x);
//     try std.testing.expectEqual(@as(f32, 12.0), pos1.y);
//
//     const vel1 = world.getComponent(e1, Velocity).?;
//     try std.testing.expectEqual(@as(f32, 1.0), vel1.dx);
//     try std.testing.expectEqual(@as(f32, 2.0), vel1.dy);
// }

// Test obsolete - groups now compile-time
// test "World multiple groups with non-overlapping components" {
//     const A = struct { value: i32 };
//     const B = struct { value: i32 };
//     const C = struct { value: i32 };
//     const D = struct { value: i32 };
//
//     const TestWorld = World(struct { A, B, C, D }, struct {}, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Create two different groups with non-overlapping components
//     // Groups now compile-time: // try world.createGroup(struct { A, B });
//     // Groups now compile-time: // try world.createGroup(struct { C, D });
//
//     // Create entities with different component combinations
//     const e1 = world.createEntity();
//     try world.addComponent(e1, A, .{ .value = 1 });
//     try world.addComponent(e1, B, .{ .value = 2 });
//
//     const e2 = world.createEntity();
//     try world.addComponent(e2, C, .{ .value = 3 });
//     try world.addComponent(e2, D, .{ .value = 4 });
//
//     const e3 = world.createEntity();
//     try world.addComponent(e3, A, .{ .value = 5 });
//     try world.addComponent(e3, B, .{ .value = 6 });
//
//     // Verify first group (A, B) contains e1 and e3
//     const group1_entities = world.getGroupEntities(struct { A, B }).?;
//     try std.testing.expectEqual(@as(usize, 2), group1_entities.len);
//
//     // Verify second group (C, D) contains only e2
//     const group2_entities = world.getGroupEntities(struct { C, D }).?;
//     try std.testing.expectEqual(@as(usize, 1), group2_entities.len);
// }

// Test obsolete - groups now compile-time
// test "World group with component not in group" {
//     const Position = struct { x: f32, y: f32 };
//     const Velocity = struct { dx: f32, dy: f32 };
//
//     const TestWorld = World(struct { Position, Velocity }, struct {}, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Groups now compile-time: // try world.createGroup(struct { Position, Velocity });
//
//     // Try to get Velocity components from Position group (should return null)
//     const velocities = world.getGroupComponents(struct { Position }, Velocity);
//     try std.testing.expect(velocities == null);
// }

// Test obsolete - groups now compile-time
// test "World can create identical group twice without error" {
//     const Position = struct { x: f32, y: f32 };
//     const Velocity = struct { dx: f32, dy: f32 };
//
//     const TestWorld = World(struct { Position, Velocity }, struct {}, struct {}, .{});
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Create group
//     // Groups now compile-time: // try world.createGroup(struct { Position, Velocity });
//
//     // Try to create same group again - should succeed (idempotent)
//     // Groups now compile-time: // try world.createGroup(struct { Position, Velocity });
//
//     // Verify only one group exists
//     try std.testing.expectEqual(@as(usize, 1), world.groups.items.len);
// }

// Test obsolete - groups now compile-time
// test "World compile-time group validation - non-overlapping" {
//     const A = struct { value: i32 };
//     const B = struct { value: i32 };
//     const C = struct { value: i32 };
//     const D = struct { value: i32 };
//
//     const TestWorld = World(struct { A, B, C, D }, struct {}, struct {}, .{});
//
//     // Compile-time validation of non-overlapping groups - should compile fine
//     TestWorld.validateGroups(.{
//         struct { A, B },
//         struct { C, D },
//     });
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Runtime creation should work
//     // Groups now compile-time: // try world.createGroup(struct { A, B });
//     // Groups now compile-time: // try world.createGroup(struct { C, D });
//
//     try std.testing.expectEqual(@as(usize, 2), world.groups.items.len);
// }

// Test obsolete - groups now compile-time
// test "World recommended usage pattern - validate groups upfront" {
//     const Position = struct { x: f32, y: f32 };
//     const Velocity = struct { dx: f32, dy: f32 };
//     const Health = struct { hp: i32 };
//     const Armor = struct { value: i32 };
//
//     const TestWorld = World(struct { Position, Velocity, Health, Armor }, struct {}, struct {}, .{});
//
//     // Recommended: Validate all groups at compile time before creating them
//     TestWorld.validateGroups(.{
//         struct { Position, Velocity }, // Movement entities
//         struct { Health, Armor }, // Combat entities
//     });
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     var world = TestWorld.init(allocator);
//     defer world.deinit();
//
//     // Now create the groups - we know they're valid
//     // Groups now compile-time: // try world.createGroup(struct { Position, Velocity });
//     // Groups now compile-time: // try world.createGroup(struct { Health, Armor });
//
//     // Create test entities
//     const moving_entity = world.createEntity();
//     try world.addComponent(moving_entity, Position, .{ .x = 10.0, .y = 20.0 });
//     try world.addComponent(moving_entity, Velocity, .{ .dx = 1.0, .dy = 2.0 });
//
//     const combat_entity = world.createEntity();
//     try world.addComponent(combat_entity, Health, .{ .hp = 100 });
//     try world.addComponent(combat_entity, Armor, .{ .value = 50 });
//
//     // Verify groups work correctly
//     const movement_entities = world.getGroupEntities(struct { Position, Velocity }).?;
//     const combat_entities = world.getGroupEntities(struct { Health, Armor }).?;
//
//     try std.testing.expectEqual(@as(usize, 1), movement_entities.len);
//     try std.testing.expectEqual(@as(usize, 1), combat_entities.len);
//
//     // Fast iteration over group components
//     const positions = world.getGroupComponents(struct { Position, Velocity }, Position).?;
//     try std.testing.expectEqual(@as(f32, 10.0), positions[0].x);
// }

test "Serialization fails for uninitialized resources" {
    const Position = struct { x: f32, y: f32 };
    const GameConfig = struct { gravity: f32 };
    const Score = struct { points: i32 };

    const TestWorld = World(struct { Position }, struct { GameConfig, Score }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create an entity
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 10.0, .y = 20.0 });

    // Initialize only one resource, leaving the other uninitialized
    world.setResource(GameConfig, .{ .gravity = 9.8 });

    // Try to serialize - should fail because Score is not initialized
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    const result = world.serialize(buffer.writer(allocator));
    try std.testing.expectError(error.UninitializedResource, result);
}

test "Serialization succeeds when all resources are initialized" {
    const Position = struct { x: f32, y: f32 };
    const GameConfig = struct { gravity: f32 };
    const Score = struct { points: i32 };

    const TestWorld = World(struct { Position }, struct { GameConfig, Score }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create an entity
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 10.0, .y = 20.0 });

    // Initialize all resources
    world.setResource(GameConfig, .{ .gravity = 9.8 });
    world.setResource(Score, .{ .points = 100 });

    // Serialize - should succeed
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    try world.serialize(buffer.writer(allocator));

    // Verify serialization produced data
    try std.testing.expect(buffer.items.len > 0);
}

test "Resource initialization tracking" {
    const GameConfig = struct { gravity: f32 };
    const Score = struct { points: i32 };

    const TestWorld = World(struct {}, struct { GameConfig, Score }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initially, no resources should be initialized
    try std.testing.expect(!world.isResourceInitialized(GameConfig));
    try std.testing.expect(!world.isResourceInitialized(Score));

    // Set GameConfig
    world.setResource(GameConfig, .{ .gravity = 9.8 });
    try std.testing.expect(world.isResourceInitialized(GameConfig));
    try std.testing.expect(!world.isResourceInitialized(Score));

    // Set Score
    world.setResource(Score, .{ .points = 100 });
    try std.testing.expect(world.isResourceInitialized(GameConfig));
    try std.testing.expect(world.isResourceInitialized(Score));
}

test "getResourcePtrMut allows mutation after initialization" {
    const GameConfig = struct { gravity: f32 };
    const Score = struct { points: i32 };

    const TestWorld = World(struct {}, struct { GameConfig, Score }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initially, resources are not initialized
    try std.testing.expect(!world.isResourceInitialized(GameConfig));
    try std.testing.expect(!world.isResourceInitialized(Score));

    // Initialize resources using setResource
    world.setResource(GameConfig, .{ .gravity = 0.0 });
    world.setResource(Score, .{ .points = 0 });
    try std.testing.expect(world.isResourceInitialized(GameConfig));
    try std.testing.expect(world.isResourceInitialized(Score));

    // Get mutable pointer and modify - resources should remain initialized
    const config = world.getResourcePtrMut(GameConfig);
    config.gravity = 9.8;
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    // Verify serialization succeeds
    const score = world.getResourcePtrMut(Score);
    score.points = 100;
    try std.testing.expect(world.isResourceInitialized(Score));

    // Both resources should now be serializable
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);
    try world.serialize(buffer.writer(allocator));
    try std.testing.expect(buffer.items.len > 0);
}

test "markResourceInitialized for direct resource_pool access" {
    const GameConfig = struct { gravity: f32 };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {}, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Directly assign to resource_pool (not recommended but supported)
    world.resource_pool[0] = .{ .gravity = 9.8 };

    // Resource is not yet marked as initialized
    try std.testing.expect(!world.isResourceInitialized(GameConfig));

    // Mark it initialized
    world.markResourceInitialized(GameConfig);
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    // Verify serialization succeeds
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);
    try world.serialize(buffer.writer(allocator));
    try std.testing.expect(buffer.items.len > 0);
}

test "Resource is read-only and ResourceMut is mutable" {
    const GameConfig = struct { speed: f32 };
    const Score = struct { points: i32 };

    const TestWorld = World(struct {}, struct { GameConfig, Score }, struct {}, .{});

    // Test read-only Resource system
    const ReadOnlySystem = struct {
        fn system(config: Resource(GameConfig)) !void {
            // Read access works
            _ = config.value.speed;
            // Mutation would fail at compile time:
            // config.value.speed = 100.0; // ERROR: cannot assign to constant
        }
    };

    // Test mutable ResourceMut system
    const MutableSystem = struct {
        fn system(score: ResourceMut(Score), config: ResourceMut(GameConfig)) !void {
            // Read and write access work
            score.value.points += 100;
            config.value.speed *= 1.5;
        }
    };

    // Test mixed read-only and mutable access
    const MixedSystem = struct {
        fn system(config: Resource(GameConfig), score: ResourceMut(Score)) !void {
            // Read from config, write to score
            score.value.points += @as(i32, @intFromFloat(config.value.speed * 10.0));
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initialize resources
    world.resource_pool[0] = .{ .speed = 10.0 };
    world.resource_pool[1] = .{ .points = 0 };
    world.markResourceInitialized(GameConfig);
    world.markResourceInitialized(Score);

    // Run read-only system
    try world.runSystem(ReadOnlySystem.system);

    // Verify config unchanged
    try std.testing.expectEqual(@as(f32, 10.0), world.getResource(GameConfig).speed);

    // Run mutable system
    try world.runSystem(MutableSystem.system);

    // Verify both resources were modified
    try std.testing.expectEqual(@as(f32, 15.0), world.getResource(GameConfig).speed);
    try std.testing.expectEqual(@as(i32, 100), world.getResource(Score).points);

    // Run mixed system
    try world.runSystem(MixedSystem.system);

    // Verify score was updated based on config value, but config unchanged
    try std.testing.expectEqual(@as(i32, 250), world.getResource(Score).points); // 100 + (15.0 * 10) = 250
    try std.testing.expectEqual(@as(f32, 15.0), world.getResource(GameConfig).speed);
}

test "Groups: order-insensitive matching" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };
    const Health = struct { hp: i32 };

    // Define groups with different component ordering
    const GroupAB = struct { Position, Velocity };
    const GroupBA = struct { Velocity, Position };

    const TestWorld = World(
        struct { Position, Velocity, Health },
        struct {},
        struct {},
        .{GroupAB}, // Register with A, B order
    );

    // Verify that both orderings resolve to the same group index
    const idx1 = comptime TestWorld.getGroupIndex(GroupAB);
    const idx2 = comptime TestWorld.getGroupIndex(GroupBA);

    try std.testing.expectEqual(idx1, idx2);
}

test "Groups: deserialization repopulates groups" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    const MovementGroup = struct { Position, Velocity };

    const TestWorld = World(
        struct { Position, Velocity },
        struct {},
        struct {},
        .{MovementGroup},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create world and add entities with components
    var world1 = TestWorld.init(allocator);
    defer world1.deinit();

    const e1 = world1.createEntity();
    const e2 = world1.createEntity();
    const e3 = world1.createEntity();

    try world1.addComponent(e1, Position, .{ .x = 1, .y = 2 });
    try world1.addComponent(e1, Velocity, .{ .x = 0.5, .y = 0.5 });

    try world1.addComponent(e2, Position, .{ .x = 3, .y = 4 });
    try world1.addComponent(e2, Velocity, .{ .x = 1.0, .y = 1.0 });

    try world1.addComponent(e3, Position, .{ .x = 5, .y = 6 });
    // e3 has no Velocity, so it shouldn't be in the group

    // Verify group has 2 entities before serialization
    const pos_id = comptime TestWorld.getComponentId(Position);
    const group_entities_before = world1.component_pool[pos_id].getGroupEntities();
    try std.testing.expectEqual(@as(usize, 2), group_entities_before.len);

    // Serialize to buffer
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);
    try world1.serialize(buffer.writer(allocator));

    // Deserialize to new world
    var world2 = TestWorld.init(allocator);
    defer world2.deinit();

    var stream = std.io.fixedBufferStream(buffer.items);
    try world2.deserialize(stream.reader());

    // Verify groups were repopulated correctly
    const group_entities_after = world2.component_pool[pos_id].getGroupEntities();
    try std.testing.expectEqual(@as(usize, 2), group_entities_after.len);

    // Verify the correct entities are in the group (those with both Position and Velocity)
    var found_e1 = false;
    var found_e2 = false;
    for (group_entities_after) |entity| {
        if (entity.index == e1.index and entity.version == e1.version) found_e1 = true;
        if (entity.index == e2.index and entity.version == e2.version) found_e2 = true;
    }
    try std.testing.expect(found_e1);
    try std.testing.expect(found_e2);
}

// Compile-time validation tests (these would fail at compile-time if uncommented):
//
// test "Groups: reject tag components (compile error)" {
//     const Position = struct { x: f32, y: f32 };
//     const Enemy = struct {}; // Tag component (zero-sized)
//
//     // This should fail with: "Tag components cannot be used in groups"
//     const TestWorld = World(
//         struct { Position, Enemy },
//         struct {},
//         struct {},
//         .{ struct { Position, Enemy } }, // ERROR: Enemy is a tag
//     );
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     var world = TestWorld.init(arena.allocator());
//     defer world.deinit();
// }
//
// test "Groups: reject duplicate components (compile error)" {
//     const Position = struct { x: f32, y: f32 };
//
//     // This should fail with: "Duplicate component in group"
//     const TestWorld = World(
//         struct { Position },
//         struct {},
//         struct {},
//         .{ struct { Position, Position } }, // ERROR: Position appears twice
//     );
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     var world = TestWorld.init(arena.allocator());
//     defer world.deinit();
// }
//
// test "Groups: reject owned+Free mix for same component (compile error)" {
//     const Position = struct { x: f32, y: f32 };
//     const Free = @import("query/filter.zig").Free;
//
//     // This should fail with: "Component appears as both owned and Free"
//     const TestWorld = World(
//         struct { Position },
//         struct {},
//         struct {},
//         .{ struct { Position, Free(Position) } }, // ERROR: Position both owned and Free
//     );
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     var world = TestWorld.init(arena.allocator());
//     defer world.deinit();
// }
