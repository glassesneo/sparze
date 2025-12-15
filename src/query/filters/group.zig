const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("../../entity/entity.zig");
const Entity = entity_module.Entity;

const sparse_set_module = @import("../../storage/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const common = @import("common.zig");
const FilterType = common.FilterType;
const extractFree = common.extractFree;
const isFree = common.isFree;

const iterators = @import("iterators.zig");
const SimpleCrossProductIterator = iterators.SimpleCrossProductIterator;

pub fn Free(comptime C: type) type {
    return struct {
        pub const Component = C;
        pub const is_free = true;
    };
}

pub fn Group(comptime GroupComponents: type) type {
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

        pub fn init(world: anytype) Self {
            const WorldType = @TypeOf(world.*);
            const group_idx = comptime WorldType.getGroupIndex(GroupComponents);
            _ = group_idx;

            var component_pool: GroupComponentPoolType = undefined;

            inline for (component_fields, 0..) |field, i| {
                const ComponentType = extractFree(field.type);
                const sparse_set: *const SparseSet(ComponentType) = world.getSparseSetPtr(ComponentType);
                component_pool[i] = sparse_set;
            }

            return .{
                .group_component_pool = component_pool,
            };
        }

        pub fn getComponentId(comptime C: type) u16 {
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

        pub fn getEntities(self: Self) []const Entity {
            return inline for (component_fields, 0..) |field, i| {
                if (!isFree(field.type)) break self.group_component_pool[i].getGroupEntities();
            } else unreachable;
        }

        pub fn getArrayOf(self: Self, comptime C: type) []const C {
            if (!comptime isOwned(C)) {
                @compileError("Cannot use getArrayOf() on free component '" ++ @typeName(C) ++ "'. " ++
                    "Free components must be accessed via getComponent(entity, " ++ @typeName(C) ++ ") for each entity. " ++
                    "This is because free components are not organized in the group region and require sparse set lookup.");
            }
            return self.getSparseSetPtr(C).getGroupComponents();
        }

        pub fn getMutArrayOf(self: Self, comptime C: type) []C {
            if (!comptime isOwned(C)) {
                @compileError("Cannot use getMutArrayOf() on free component '" ++ @typeName(C) ++ "'. " ++
                    "Free components must be accessed via getComponentMut(entity, " ++ @typeName(C) ++ ") for each entity. " ++
                    "This is because free components are not organized in the group region and require sparse set lookup.");
            }
            return self.getSparseSetPtr(C).getGroupComponentsMut();
        }

        pub fn getComponent(self: Self, entity: Entity, comptime C: type) C {
            const sparse_set = self.getSparseSetPtr(C);
            return sparse_set.get(entity).?;
        }

        pub fn getComponentMut(self: Self, entity: Entity, comptime C: type) *C {
            const sparse_set = @constCast(self.getSparseSetPtr(C));
            return sparse_set.getPtrMut(entity).?;
        }

        pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator(Self, @TypeOf(other.*)) {
            return SimpleCrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }
    };
}
