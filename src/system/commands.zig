const std = @import("std");

const entity_module = @import("../entity/entity.zig");
const Entity = entity_module.Entity;

const sparse_set_module = @import("../storage/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const component_storage_module = @import("../storage/component_storage.zig");
const isTagComponent = component_storage_module.isTagComponent;

/// Command types for deferred entity/component operations.
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
                    .data = undefined,
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
                        if (!world.isAlive(cmd.entity)) continue;
                        const comp_data = cmd.component_data.?;
                        try world.addComponentFromBytes(cmd.entity, comp_data.type_id, comp_data.data[0..comp_data.len]);
                    },
                    .remove_component => {
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

        pub fn createEntity(self: Self) Entity {
            return self.world.createEntity();
        }

        pub fn createEntityWith(self: Self, comptime components: anytype) !Entity {
            const entity = self.createEntity();
            inline for (components) |component| {
                const C = @TypeOf(component);
                try self.addComponent(entity, C, component);
            }
            return entity;
        }

        pub fn addComponent(self: Self, entity: Entity, comptime C: type, component: C) !void {
            const type_id = comptime World.getComponentId(C);
            const bytes = std.mem.asBytes(&component);
            try self.command_buffer.recordAddComponent(entity, type_id, bytes);
        }

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

        pub fn destroyEntity(self: Self, entity: Entity) !void {
            try self.command_buffer.recordDestroyEntity(entity);
        }

        pub fn serialize(self: Self, writer: anytype) !void {
            return self.world.serialize(writer);
        }

        pub fn deserialize(self: Self, reader: anytype) !void {
            return self.world.deserialize(reader);
        }

        pub fn serializeToFile(self: Self, path: []const u8) !void {
            return self.world.serializeToFile(path);
        }

        pub fn deserializeFromFile(self: Self, path: []const u8) !void {
            return self.world.deserializeFromFile(path);
        }

        pub fn setResource(self: Self, comptime R: type, resource: R) void {
            self.world.setResource(R, resource);
        }

        pub fn getResource(self: Self, comptime R: type) R {
            return self.world.getResource(R);
        }

        pub fn getResourcePtr(self: Self, comptime R: type) *const R {
            return self.world.getResourcePtr(R);
        }

        pub fn getResourcePtrMut(self: Self, comptime R: type) *R {
            return self.world.getResourcePtrMut(R);
        }

        pub fn tryGetResource(self: Self, comptime R: type) !*const R {
            return self.world.tryGetResource(R);
        }

        pub fn tryGetResourceMut(self: Self, comptime R: type) !*R {
            return self.world.tryGetResourceMut(R);
        }

        pub fn initResources(self: Self, resources: anytype) !void {
            return self.world.initResources(resources);
        }

        pub fn isResourceInitialized(self: Self, comptime R: type) bool {
            return self.world.isResourceInitialized(R);
        }
    };
}
