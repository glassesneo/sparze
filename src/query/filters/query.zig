const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("../../entity/entity.zig");
const Entity = entity_module.Entity;
const EntityRegistry = entity_module.EntityRegistry;

const component_storage_module = @import("../../storage/component_storage.zig");
const ComponentStorage = component_storage_module.ComponentStorage;

const common = @import("common.zig");
const FilterType = common.FilterType;
const extractType = common.extractType;
const filterWithModifiers = common.filterWithModifiers;

const iterators = @import("iterators.zig");
const CrossProductIterator = iterators.CrossProductIterator;

pub fn Query(comptime QueryComponents: type) type {
    const info = @typeInfo(QueryComponents);
    if (info != .@"struct") @compileError("Invalid form of components");
    const component_fields = info.@"struct".fields;
    if (component_fields.len == 0) @compileError("Query must have at least one component");
    const length = info.@"struct".fields.len;

    const QueryComponentPoolType = construct_component_pool: {
        var query_fields: [length]StructField = undefined;
        inline for (component_fields, 0..) |field, i| {
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

        pub fn init(world: anytype) Self {
            var min_size: usize = std.math.maxInt(usize);
            var candidate_entities: []const Entity = &[_]Entity{};
            var component_pool: QueryComponentPoolType = undefined;

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

            return .{
                .query_component_pool = component_pool,
                .entities = candidate_entities,
                .entity_registry = &world.entity_registry,
            };
        }

        pub fn getComponentId(comptime C: type) u16 {
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
            return @constCast(self.query_component_pool[id]);
        }

        pub fn getComponent(self: Self, entity: Entity, comptime C: type) C {
            const storage = self.getComponentStoragePtr(C);
            return storage.*.get(entity).?;
        }

        pub fn getComponentMut(self: Self, entity: Entity, comptime C: type) *C {
            const storage = self.getComponentStoragePtrMut(C);
            return storage.*.getPtrMut(entity).?;
        }

        pub fn filter(self: *const Self, entity: Entity) bool {
            if (!self.entity_registry.isAlive(entity)) return false;
            return filterWithModifiers(component_fields, entity, self, getComponentStoragePtr);
        }

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{
                .index = 0,
                .query = self,
            };
        }

        pub const Iterator = struct {
            index: usize,
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

        pub fn combinations(self: *const Self) CombinationIterator {
            return .{ .query = self };
        }

        pub const CombinationIterator = struct {
            i: usize = 0,
            j: usize = 1,
            query: *const Query(QueryComponents),

            pub fn next(self: *CombinationIterator) ?struct { Entity, Entity } {
                const entities = self.query.entities;

                while (self.i < entities.len) {
                    const entity_i = entities[self.i];

                    const i_passes_filter = self.query.filter(entity_i);

                    if (!i_passes_filter) {
                        self.i += 1;
                        self.j = self.i + 1;
                        continue;
                    }

                    while (self.j < entities.len) {
                        const entity_j = entities[self.j];

                        self.j += 1;

                        if (self.query.filter(entity_j)) {
                            return .{ entity_i, entity_j };
                        }
                    }

                    self.i += 1;
                    self.j = self.i + 1;
                }

                return null;
            }
        };

        pub fn crossProduct(self: *const Self, other: anytype) CrossProductIterator(Self, @TypeOf(other.*)) {
            return CrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }

        pub fn getOptional(self: *const Self, entity: Entity, comptime C: type) ?C {
            const storage = self.getComponentStoragePtr(C);
            if (storage.*.contains(entity)) {
                return storage.*.get(entity);
            }
            return null;
        }

        pub fn getOptionalMut(self: *const Self, entity: Entity, comptime C: type) ?*C {
            const storage = self.getComponentStoragePtrMut(C);
            if (storage.*.contains(entity)) {
                return storage.*.getPtrMut(entity);
            }
            return null;
        }
    };
}
