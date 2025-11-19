const std = @import("std");
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

/// Information about a group
const GroupInfo = struct {
    owned_component_ids: []const u16, // Components owned by this group
    free_component_ids: []const u16, // Components used but not owned by this group
};

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

pub fn World(Components: anytype, Resources: anytype, Events: anytype) type {
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
        groups: ArrayList(GroupInfo),
        command_buffer: CommandBuffer(Self),

        pub fn init(allocator: Allocator) Self {
            return .{
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
                .groups = .{},
                .command_buffer = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.command_buffer.deinit();
            for (self.groups.items) |*group| {
                self.allocator.free(group.owned_component_ids);
                self.allocator.free(group.free_component_ids);
            }
            self.groups.deinit(self.allocator);
            inline for (component_fields) |field| {
                self.getComponentStoragePtr(field.type).deinit();
            }
            inline for (event_fields, 0..) |_, i| {
                self.event_pool[i].deinit();
            }
        }

        pub fn getComponentId(comptime C: type) u16 {
            // The order of components become the id
            return inline for (component_fields, 0..) |field, i| {
                if (C == field.type) break i;
            } else @compileError("Unknown component type: " ++ @typeName(C));
        }

        pub fn getResourceId(comptime R: type) u16 {
            // The order of resources become the id
            return inline for (resource_fields, 0..) |field, i| {
                if (R == field.type) break i;
            } else @compileError("Unknown resource type: " ++ @typeName(R));
        }

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
                const group_fields = comptime std.meta.fields(GroupType);
                inline for (group_fields) |field| {
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
                const group_fields = std.meta.fields(GroupComponents);
                var count: usize = 0;
                for (group_fields) |field| {
                    if (!isFree(field.type)) count += 1;
                }
                break :blk count;
            },
            blk: {
                const group_fields = std.meta.fields(GroupComponents);
                var count: usize = 0;
                for (group_fields) |field| {
                    if (isFree(field.type)) count += 1;
                }
                break :blk count;
            },
        ) {
            const group_fields = comptime std.meta.fields(GroupComponents);

            // Count owned and free components
            const owned_count = comptime blk: {
                var count: usize = 0;
                for (group_fields) |field| {
                    if (!isFree(field.type)) count += 1;
                }
                break :blk count;
            };

            const free_count = comptime blk: {
                var count: usize = 0;
                for (group_fields) |field| {
                    if (isFree(field.type)) count += 1;
                }
                break :blk count;
            };

            // Build owned component ID array
            const owned_ids = comptime blk: {
                var ids: [owned_count]u16 = undefined;
                var idx: usize = 0;
                for (group_fields) |field| {
                    if (!isFree(field.type)) {
                        const ComponentType = extractComponent(field.type);
                        ids[idx] = getComponentId(ComponentType);
                        idx += 1;
                    }
                }
                break :blk ids;
            };

            // Build free component ID array
            const free_ids = comptime blk: {
                var ids: [free_count]u16 = undefined;
                var idx: usize = 0;
                for (group_fields) |field| {
                    if (isFree(field.type)) {
                        const ComponentType = extractComponent(field.type);
                        ids[idx] = getComponentId(ComponentType);
                        idx += 1;
                    }
                }
                break :blk ids;
            };

            return .{
                .owned_ids = owned_ids,
                .free_ids = free_ids,
            };
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

        pub fn getResource(self: Self, comptime R: type) R {
            const id = comptime getResourceId(R);
            return self.resource_pool[id];
        }

        pub fn getResourcePtr(self: *Self, comptime R: type) *const R {
            const id = comptime getResourceId(R);
            return &self.resource_pool[id];
        }

        pub fn getResourcePtrMut(self: *Self, comptime R: type) *R {
            const id = comptime getResourceId(R);
            // Mark resource as initialized when getting mutable pointer
            // This handles the case where users mutate resources in-place
            if (comptime resource_pool_length > 0) {
                self.resource_initialized.set(id);
            }
            return &self.resource_pool[id];
        }

        pub fn setResource(self: *Self, comptime R: type, resource: R) !void {
            const id = comptime getResourceId(R);
            self.resource_pool[id] = resource;
            if (comptime resource_pool_length > 0) {
                self.resource_initialized.set(id);
            }
        }

        /// Mark a resource as initialized.
        /// This should be called after directly mutating resource_pool[i] to ensure
        /// the resource can be serialized. Prefer using setResource() or getResourcePtrMut()
        /// which automatically mark resources as initialized.
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

        pub fn getEventStoragePtrMut(self: *Self, comptime E: type) *EventStorage(E) {
            const id = comptime getEventId(E);
            return &self.event_pool[id];
        }

        pub fn getEventStoragePtr(self: *const Self, comptime E: type) *const EventStorage(E) {
            const id = comptime getEventId(E);
            return &self.event_pool[id];
        }

        /// Complexity: O(1).
        pub fn createEntity(self: *Self) Entity {
            return self.entity_registry.create();
        }

        /// Destroys an Entity and removes it from all registered component pools.
        /// The entity identifier becomes invalid and may be recycled for future entities.
        /// Complexity: O(c) where c = number of registered component types.
        pub fn destroyEntity(self: *Self, entity: Entity) void {
            self.entity_registry.destroy(entity);
            inline for (component_fields) |field| {
                self.removeComponent(entity, field.type);
            }
        }

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

        /// Add component from raw bytes (used by CommandBuffer)
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

        pub fn getComponent(self: *Self, entity: Entity, comptime C: type) ?C {
            if (comptime isTagComponent(C)) @compileError("Cannot get tag component value, use hasComponent to check for tag presence");
            return self.getSparseSetPtr(C).get(entity);
        }

        pub fn isAlive(self: Self, entity: Entity) bool {
            return self.entity_registry.isAlive(entity);
        }

        pub fn hasComponent(self: Self, entity: Entity, comptime C: type) bool {
            return self.getComponentStorage(C).contains(entity);
        }

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

        pub fn createEntityWith(self: *Self, comptime components: anytype) !Entity {
            const entity = self.createEntity();
            try self.addComponents(entity, components);
            return entity;
        }

        /// Create a group for the given component types (supports full-owning and partial-owning groups)
        pub fn createGroup(self: *Self, comptime GroupComponents: type) !void {
            const group_fields = comptime std.meta.fields(GroupComponents);
            if (group_fields.len == 0) @compileError("Cannot create group with zero components");

            // Parse group signature using helper function
            const group_key = comptime parseGroupSignature(GroupComponents);
            const owned_ids = group_key.owned_ids;
            const free_ids = group_key.free_ids;
            const owned_count = owned_ids.len;
            const free_count = free_ids.len;

            // Compile-time validation: ensure at least one component is owned
            if (owned_count == 0) {
                @compileError("Groups must have at least one owned component. All components are marked as Free(T). " ++
                    "Remove Free() from at least one component to create a valid group.");
            }

            // Compile-time validation: ensure all component types are valid for this world
            comptime {
                for (group_fields) |field| {
                    const ComponentType = extractComponent(field.type);
                    _ = getComponentId(ComponentType); // Will compile error if type not in world
                }
            }

            // Check if group already exists (same owned and free components)
            // This must be done BEFORE ownership conflict check to allow creating the same group twice
            for (self.groups.items) |*group| {
                if (group.owned_component_ids.len == owned_ids.len and
                    group.free_component_ids.len == free_ids.len)
                {
                    var owned_matches = true;
                    if (owned_ids.len > 0) {
                        for (group.owned_component_ids, 0..) |id, i| {
                            if (id != owned_ids[i]) {
                                owned_matches = false;
                                break;
                            }
                        }
                    }

                    var free_matches = true;
                    if (free_ids.len > 0) {
                        for (group.free_component_ids, 0..) |id, i| {
                            if (id != free_ids[i]) {
                                free_matches = false;
                                break;
                            }
                        }
                    }

                    if (owned_matches and free_matches) return; // Group already exists
                }
            }

            // Check for ownership conflicts: owned components cannot be owned by multiple groups
            for (self.groups.items) |*existing_group| {
                for (owned_ids) |new_owned_id| {
                    for (existing_group.owned_component_ids) |existing_owned_id| {
                        if (new_owned_id == existing_owned_id) {
                            return error.ComponentAlreadyOwned;
                        }
                    }
                }
            }

            // Allocate and copy component IDs
            var owned_component_ids = try self.allocator.alloc(u16, owned_count);
            errdefer self.allocator.free(owned_component_ids);

            var free_component_ids = try self.allocator.alloc(u16, free_count);
            errdefer self.allocator.free(free_component_ids);

            inline for (owned_ids, 0..) |id, i| {
                owned_component_ids[i] = id;
            }
            inline for (free_ids, 0..) |id, i| {
                free_component_ids[i] = id;
            }

            try self.groups.append(self.allocator, GroupInfo{
                .owned_component_ids = owned_component_ids,
                .free_component_ids = free_component_ids,
            });

            // Populate the group with existing entities that have all required components
            self.populateGroup(GroupComponents);
        }

        /// Get group information by component types
        pub fn getGroup(self: *const Self, comptime GroupComponents: type) ?*const GroupInfo {
            // Parse group signature using helper function
            const group_key = comptime parseGroupSignature(GroupComponents);
            const target_owned_ids = group_key.owned_ids;
            const target_free_ids = group_key.free_ids;

            for (self.groups.items) |*group| {
                if (group.owned_component_ids.len == target_owned_ids.len and
                    group.free_component_ids.len == target_free_ids.len)
                {
                    var owned_matches = true;
                    if (target_owned_ids.len > 0) {
                        for (group.owned_component_ids, 0..) |id, i| {
                            if (id != target_owned_ids[i]) {
                                owned_matches = false;
                                break;
                            }
                        }
                    }

                    var free_matches = true;
                    if (target_free_ids.len > 0) {
                        for (group.free_component_ids, 0..) |id, i| {
                            if (id != target_free_ids[i]) {
                                free_matches = false;
                                break;
                            }
                        }
                    }

                    if (owned_matches and free_matches) return group;
                }
            }
            return null;
        }

        /// Get entities in a group (fast iteration)
        pub fn getGroupEntities(self: *const Self, comptime GroupComponents: type) ?[]const Entity {
            const group = self.getGroup(GroupComponents) orelse return null;

            // Use the first owned component (guaranteed to exist by createGroup validation)
            const first_id = group.owned_component_ids[0];

            // Use inline for to access tuple element at runtime
            inline for (component_fields, 0..) |field, i| {
                if (comptime isTagComponent(field.type)) continue;
                if (first_id == i) {
                    return self.component_pool[i].getGroupEntities();
                }
            }
            return null;
        }

        /// Get components of a specific type in a group (fast iteration)
        /// Only works for owned components
        pub fn getGroupComponents(self: *const Self, comptime GroupComponents: type, comptime C: type) ?[]const C {
            const group = self.getGroup(GroupComponents) orelse return null;
            const component_id = comptime getComponentId(C);

            // Check if this component type is owned by the group
            for (group.owned_component_ids) |group_id| {
                if (group_id == component_id) {
                    // Use inline for to access tuple element at runtime
                    inline for (component_fields, 0..) |field, i| {
                        if (comptime isTagComponent(field.type)) continue;
                        if (component_id == i) {
                            return self.component_pool[i].getGroupComponents();
                        }
                    }
                }
            }
            return null;
        }

        pub fn getGroupComponentsMut(self: *Self, comptime GroupComponents: type, comptime C: type) ?[]C {
            const group = self.getGroup(GroupComponents) orelse return null;
            const component_id = comptime getComponentId(C);

            // Check if this component type is owned by the group
            for (group.owned_component_ids) |group_id| {
                if (group_id == component_id) {
                    // Use inline for to access tuple element at runtime
                    inline for (component_fields, 0..) |field, i| {
                        if (comptime isTagComponent(field.type)) continue;
                        if (component_id == i) {
                            return self.component_pool[i].getGroupComponentsMut();
                        }
                    }
                }
            }
            return null;
        }

        /// Populate group with existing entities that have all required components (owned + free)
        fn populateGroup(self: *Self, comptime GroupComponents: type) void {
            const group = self.getGroup(GroupComponents) orelse return;

            // Need at least one component (owned or free)
            const total_components = group.owned_component_ids.len + group.free_component_ids.len;
            if (total_components == 0) return;

            // Find the shortest sparse set to minimize iterations (check both owned and free)
            var min_size: usize = std.math.maxInt(usize);
            var shortest_id: u16 = if (group.owned_component_ids.len > 0)
                group.owned_component_ids[0]
            else
                group.free_component_ids[0];

            // Check owned components
            for (group.owned_component_ids) |id| {
                inline for (component_fields, 0..) |field, i| {
                    if (comptime isTagComponent(field.type)) continue;
                    if (id == i) {
                        const entities = self.component_pool[i].packed_array.items;
                        if (entities.len < min_size) {
                            min_size = entities.len;
                            shortest_id = id;
                        }
                    }
                }
            }

            // Check free components
            for (group.free_component_ids) |id| {
                inline for (component_fields, 0..) |field, i| {
                    if (comptime isTagComponent(field.type)) continue;
                    if (id == i) {
                        const entities = self.component_pool[i].packed_array.items;
                        if (entities.len < min_size) {
                            min_size = entities.len;
                            shortest_id = id;
                        }
                    }
                }
            }

            // Iterate through shortest set and check if entities have all components (owned + free)
            inline for (component_fields, 0..) |field, i| {
                if (comptime isTagComponent(field.type)) continue;
                if (shortest_id == i) {
                    const entities = self.component_pool[i].packed_array.items;
                    for (entities) |entity| {
                        if (self.entityHasAllGroupComponents(entity, group)) {
                            self.addEntityToGroup(entity, group);
                        }
                    }
                }
            }
        }

        /// Check if entity has all required components for a group (owned + free)
        fn entityHasAllGroupComponents(self: *const Self, entity: Entity, group: *const GroupInfo) bool {
            // Check owned components
            for (group.owned_component_ids) |id| {
                var has_component = false;
                inline for (component_fields, 0..) |field, i| {
                    if (comptime isTagComponent(field.type)) continue;
                    if (id == i) {
                        if (self.component_pool[i].contains(entity)) {
                            has_component = true;
                        }
                    }
                }
                if (!has_component) return false;
            }

            // Check free components
            for (group.free_component_ids) |id| {
                var has_component = false;
                inline for (component_fields, 0..) |field, i| {
                    if (comptime isTagComponent(field.type)) continue;
                    if (id == i) {
                        if (self.component_pool[i].contains(entity)) {
                            has_component = true;
                        }
                    }
                }
                if (!has_component) return false;
            }

            return true;
        }

        /// Update groups when component is added to entity
        fn updateGroupsOnAdd(self: *Self, entity: Entity, component_id: u16) void {
            for (self.groups.items) |*group| {
                // Check if this component type is part of the group (owned or free)
                var is_group_component = false;
                for (group.owned_component_ids) |id| {
                    if (id == component_id) {
                        is_group_component = true;
                        break;
                    }
                }
                if (!is_group_component) {
                    for (group.free_component_ids) |id| {
                        if (id == component_id) {
                            is_group_component = true;
                            break;
                        }
                    }
                }

                if (is_group_component and self.entityHasAllGroupComponents(entity, group)) {
                    self.addEntityToGroup(entity, group);
                }
            }
        }

        /// Update groups when component is removed from entity
        fn updateGroupsOnRemove(self: *Self, entity: Entity, component_id: u16) void {
            for (self.groups.items) |*group| {
                // Check if this component type is part of the group (owned or free)
                var is_group_component = false;
                for (group.owned_component_ids) |id| {
                    if (id == component_id) {
                        is_group_component = true;
                        break;
                    }
                }
                if (!is_group_component) {
                    for (group.free_component_ids) |id| {
                        if (id == component_id) {
                            is_group_component = true;
                            break;
                        }
                    }
                }

                if (is_group_component) {
                    self.removeEntityFromGroup(entity, group);
                }
            }
        }

        /// Add entity to a group (move to group area ONLY for owned components)
        fn addEntityToGroup(self: *Self, entity: Entity, group: *const GroupInfo) void {
            // Only move owned components to group area
            // Free components remain in their standard positions
            for (group.owned_component_ids) |id| {
                inline for (component_fields, 0..) |field, i| {
                    if (comptime isTagComponent(field.type)) continue;
                    if (id == i) {
                        self.component_pool[i].moveToGroup(entity);
                    }
                }
            }
        }

        /// Remove entity from a group (move from group area ONLY for owned components)
        fn removeEntityFromGroup(self: *Self, entity: Entity, group: *const GroupInfo) void {
            // Only move owned components from group area
            // Free components are not organized, so no need to move them
            for (group.owned_component_ids) |id| {
                inline for (component_fields, 0..) |field, i| {
                    if (comptime isTagComponent(field.type)) continue;
                    if (id == i) {
                        self.component_pool[i].moveFromGroup(entity);
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
        /// Note: Groups must be recreated after deserialization via createGroup()
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
        /// Example:
        /// ```zig
        /// try world.deserializeFromFile("save.spze");
        /// ```
        pub fn deserializeFromFile(self: *Self, path: []const u8) !void {
            const world_ser = @import("serialization/world.zig");
            try world_ser.deserializeFromFile(self, Components, Resources, Events, path);
        }
    };
}

test "Resource basic access" {
    const GameConfig = struct {
        gravity: f32,
        max_speed: f32,
    };

    const TestWorld = World(struct {}, struct { GameConfig }, struct {});

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

    const TestWorld = World(struct {}, struct { GameState }, struct {});

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

    const TestWorld = World(struct {}, struct { GameConfig, GameState, AudioSettings }, struct {});

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

    const TestWorld = World(struct { Position }, struct { DeltaTime }, struct {});

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

    const TestWorld = World(struct { Enemy }, struct { Score }, struct {});

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

    const TestWorld = World(struct { Position }, struct { DeltaTime, GameConfig }, struct {});

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

    const TestWorld = World(struct { Enemy, Position }, struct { Score }, struct {});

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
                score.value.value += 10;
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
    try std.testing.expectEqual(@as(i32, 20), world.getResource(Score).value);

    // Verify entities were spawned with positions
    const pos_query = SingleQuery(Position).init(world.getSparseSetPtr(Position));
    try std.testing.expectEqual(@as(usize, 2), pos_query.entities.len);
    try std.testing.expectEqual(@as(f32, 10.0), pos_query.components[0].x);
    try std.testing.expectEqual(@as(f32, 20.0), pos_query.components[1].x);
}

test "World with components and resources together" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const DeltaTime = struct { dt: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct { DeltaTime }, struct {});

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

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {});

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

    const TestWorld = World(struct {}, struct {}, struct {});

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

    const TestWorld = World(struct { TestComp }, struct {}, struct {});

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

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {});

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

    const TestWorld = World(struct {}, struct {}, struct {});

    var world = TestWorld.init(allocator);
    defer world.deinit();

    const entity = world.createEntity();
    try std.testing.expect(world.isAlive(entity));

    world.destroyEntity(entity);
    try std.testing.expect(!world.isAlive(entity));

    // Test with never-allocated entity
    const fake_entity: Entity = 999999;
    try std.testing.expect(!world.isAlive(fake_entity));
}

test "World hasComponent queries" {
    const TestComp = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestWorld = World(struct { TestComp }, struct {}, struct {});

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

    const TestWorld = World(struct { TestComp }, struct {}, struct {});

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

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {});

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

test "World group creation and basic operations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    const TestWorld = World(struct { Position, Velocity, Health }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create group for Position and Velocity
    try world.createGroup(struct { Position, Velocity });

    // Verify group was created
    const group = world.getGroup(struct { Position, Velocity });
    try std.testing.expect(group != null);
    try std.testing.expectEqual(@as(usize, 2), group.?.owned_component_ids.len);
    try std.testing.expectEqual(@as(usize, 0), group.?.free_component_ids.len);

    // Create entities with different component combinations
    const e1 = world.createEntity();
    const e2 = world.createEntity();
    const e3 = world.createEntity();

    // e1 has both Position and Velocity (in group)
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });

    // e2 has only Position (not in group)
    try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });

    // e3 has both Position and Velocity (in group)
    try world.addComponent(e3, Position, .{ .x = 5.0, .y = 6.0 });
    try world.addComponent(e3, Velocity, .{ .dx = 1.5, .dy = 2.0 });

    // Verify group entities
    const group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 2), group_entities.len);

    // Verify we can get group components
    const positions = world.getGroupComponents(struct { Position, Velocity }, Position).?;
    const velocities = world.getGroupComponents(struct { Position, Velocity }, Velocity).?;

    try std.testing.expectEqual(@as(usize, 2), positions.len);
    try std.testing.expectEqual(@as(usize, 2), velocities.len);
}

test "World group dynamic membership" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create entities first
    const e1 = world.createEntity();
    const e2 = world.createEntity();

    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.0, .dy = 1.0 });

    // Create group - should include e2 only
    try world.createGroup(struct { Position, Velocity });

    var group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 1), group_entities.len);

    // Add Velocity to e1 - should join group
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 0.5 });

    group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 2), group_entities.len);

    // Remove Velocity from e1 - should leave group
    world.removeComponent(e1, Velocity);

    group_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    try std.testing.expectEqual(@as(usize, 1), group_entities.len);
}

test "World group mutable component access" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e1, Velocity, .{ .dx = 0.5, .dy = 1.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 3.0, .y = 4.0 });
    try world.addComponent(e2, Velocity, .{ .dx = 1.5, .dy = 2.0 });

    // Get mutable access to group components
    const positions = world.getGroupComponentsMut(struct { Position, Velocity }, Position).?;
    const velocities = world.getGroupComponentsMut(struct { Position, Velocity }, Velocity).?;

    try std.testing.expectEqual(@as(usize, 2), positions.len);
    try std.testing.expectEqual(@as(usize, 2), velocities.len);

    // Modify components
    for (positions) |*pos| {
        pos.x += 10.0;
        pos.y += 10.0;
    }

    for (velocities) |*vel| {
        vel.dx *= 2.0;
        vel.dy *= 2.0;
    }

    // Verify modifications
    const pos1 = world.getComponent(e1, Position).?;
    try std.testing.expectEqual(@as(f32, 11.0), pos1.x);
    try std.testing.expectEqual(@as(f32, 12.0), pos1.y);

    const vel1 = world.getComponent(e1, Velocity).?;
    try std.testing.expectEqual(@as(f32, 1.0), vel1.dx);
    try std.testing.expectEqual(@as(f32, 2.0), vel1.dy);
}

test "World multiple groups with non-overlapping components" {
    const A = struct { value: i32 };
    const B = struct { value: i32 };
    const C = struct { value: i32 };
    const D = struct { value: i32 };

    const TestWorld = World(struct { A, B, C, D }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create two different groups with non-overlapping components
    try world.createGroup(struct { A, B });
    try world.createGroup(struct { C, D });

    // Create entities with different component combinations
    const e1 = world.createEntity();
    try world.addComponent(e1, A, .{ .value = 1 });
    try world.addComponent(e1, B, .{ .value = 2 });

    const e2 = world.createEntity();
    try world.addComponent(e2, C, .{ .value = 3 });
    try world.addComponent(e2, D, .{ .value = 4 });

    const e3 = world.createEntity();
    try world.addComponent(e3, A, .{ .value = 5 });
    try world.addComponent(e3, B, .{ .value = 6 });

    // Verify first group (A, B) contains e1 and e3
    const group1_entities = world.getGroupEntities(struct { A, B }).?;
    try std.testing.expectEqual(@as(usize, 2), group1_entities.len);

    // Verify second group (C, D) contains only e2
    const group2_entities = world.getGroupEntities(struct { C, D }).?;
    try std.testing.expectEqual(@as(usize, 1), group2_entities.len);
}

test "World group with component not in group" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    try world.createGroup(struct { Position, Velocity });

    // Try to get Velocity components from Position group (should return null)
    const velocities = world.getGroupComponents(struct { Position }, Velocity);
    try std.testing.expect(velocities == null);
}

test "World can create identical group twice without error" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestWorld = World(struct { Position, Velocity }, struct {}, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create group
    try world.createGroup(struct { Position, Velocity });

    // Try to create same group again - should succeed (idempotent)
    try world.createGroup(struct { Position, Velocity });

    // Verify only one group exists
    try std.testing.expectEqual(@as(usize, 1), world.groups.items.len);
}

test "World compile-time group validation - non-overlapping" {
    const A = struct { value: i32 };
    const B = struct { value: i32 };
    const C = struct { value: i32 };
    const D = struct { value: i32 };

    const TestWorld = World(struct { A, B, C, D }, struct {}, struct {});

    // Compile-time validation of non-overlapping groups - should compile fine
    TestWorld.validateGroups(.{
        struct { A, B },
        struct { C, D },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Runtime creation should work
    try world.createGroup(struct { A, B });
    try world.createGroup(struct { C, D });

    try std.testing.expectEqual(@as(usize, 2), world.groups.items.len);
}

test "World recommended usage pattern - validate groups upfront" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };
    const Armor = struct { value: i32 };

    const TestWorld = World(struct { Position, Velocity, Health, Armor }, struct {}, struct {});

    // Recommended: Validate all groups at compile time before creating them
    TestWorld.validateGroups(.{
        struct { Position, Velocity }, // Movement entities
        struct { Health, Armor }, // Combat entities
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Now create the groups - we know they're valid
    try world.createGroup(struct { Position, Velocity });
    try world.createGroup(struct { Health, Armor });

    // Create test entities
    const moving_entity = world.createEntity();
    try world.addComponent(moving_entity, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(moving_entity, Velocity, .{ .dx = 1.0, .dy = 2.0 });

    const combat_entity = world.createEntity();
    try world.addComponent(combat_entity, Health, .{ .hp = 100 });
    try world.addComponent(combat_entity, Armor, .{ .value = 50 });

    // Verify groups work correctly
    const movement_entities = world.getGroupEntities(struct { Position, Velocity }).?;
    const combat_entities = world.getGroupEntities(struct { Health, Armor }).?;

    try std.testing.expectEqual(@as(usize, 1), movement_entities.len);
    try std.testing.expectEqual(@as(usize, 1), combat_entities.len);

    // Fast iteration over group components
    const positions = world.getGroupComponents(struct { Position, Velocity }, Position).?;
    try std.testing.expectEqual(@as(f32, 10.0), positions[0].x);
}

test "Serialization fails for uninitialized resources" {
    const Position = struct { x: f32, y: f32 };
    const GameConfig = struct { gravity: f32 };
    const Score = struct { points: i32 };

    const TestWorld = World(struct { Position }, struct { GameConfig, Score }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create an entity
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 10.0, .y = 20.0 });

    // Initialize only one resource, leaving the other uninitialized
    try world.setResource(GameConfig, .{ .gravity = 9.8 });

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

    const TestWorld = World(struct { Position }, struct { GameConfig, Score }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Create an entity
    const entity = world.createEntity();
    try world.addComponent(entity, Position, .{ .x = 10.0, .y = 20.0 });

    // Initialize all resources
    try world.setResource(GameConfig, .{ .gravity = 9.8 });
    try world.setResource(Score, .{ .points = 100 });

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

    const TestWorld = World(struct {}, struct { GameConfig, Score }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initially, no resources should be initialized
    try std.testing.expect(!world.isResourceInitialized(GameConfig));
    try std.testing.expect(!world.isResourceInitialized(Score));

    // Set GameConfig
    try world.setResource(GameConfig, .{ .gravity = 9.8 });
    try std.testing.expect(world.isResourceInitialized(GameConfig));
    try std.testing.expect(!world.isResourceInitialized(Score));

    // Set Score
    try world.setResource(Score, .{ .points = 100 });
    try std.testing.expect(world.isResourceInitialized(GameConfig));
    try std.testing.expect(world.isResourceInitialized(Score));
}

test "getResourcePtrMut marks resource as initialized" {
    const GameConfig = struct { gravity: f32 };
    const Score = struct { points: i32 };

    const TestWorld = World(struct {}, struct { GameConfig, Score }, struct {});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = TestWorld.init(allocator);
    defer world.deinit();

    // Initially, resources are not initialized
    try std.testing.expect(!world.isResourceInitialized(GameConfig));
    try std.testing.expect(!world.isResourceInitialized(Score));

    // Get mutable pointer and modify - this should mark as initialized
    const config = world.getResourcePtrMut(GameConfig);
    config.gravity = 9.8;
    try std.testing.expect(world.isResourceInitialized(GameConfig));

    // Verify serialization succeeds after using getResourcePtrMut
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

    const TestWorld = World(struct {}, struct { GameConfig }, struct {});

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

    const TestWorld = World(struct {}, struct { GameConfig, Score }, struct {});

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
