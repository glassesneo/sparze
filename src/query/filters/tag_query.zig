const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("../../entity/entity.zig");
const Entity = entity_module.Entity;
const EntityRegistry = entity_module.EntityRegistry;

const tag_storage_module = @import("../../storage/tag_storage.zig");
const TagStorage = tag_storage_module.TagStorage;

const common = @import("common.zig");
const FilterType = common.FilterType;
const extractType = common.extractType;
const filterWithModifiers = common.filterWithModifiers;

const iterators = @import("iterators.zig");
const SimpleCrossProductIterator = iterators.SimpleCrossProductIterator;

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

        pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator(Self, @TypeOf(other.*)) {
            return SimpleCrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }
    };
}

pub fn TagQuery(comptime QueryTags: type) type {
    const info = @typeInfo(QueryTags);
    if (info != .@"struct") @compileError("Invalid form of tags");
    const tag_fields = info.@"struct".fields;
    if (tag_fields.len == 0) @compileError("TagQuery must have at least one tag");
    const length = tag_fields.len;

    const TagStoragePoolType = construct_tag_pool: {
        var tag_fields_storage: [length]StructField = undefined;
        inline for (tag_fields, 0..) |field, i| {
            const TagType, _ = extractType(field.type);

            const TagStorageType = TagStorage(TagType);
            tag_fields_storage[i] = StructField{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = *const TagStorageType,
                .is_comptime = false,
                .alignment = @alignOf(*const TagStorageType),
                .default_value_ptr = null,
            };
        }
        break :construct_tag_pool @Type(.{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .decls = &.{},
            .fields = &tag_fields_storage,
        } });
    };

    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .tag_query;
        pub const TagTypes = QueryTags;

        tag_storage_pool: TagStoragePoolType,
        entities: []const Entity,
        entity_registry: *const EntityRegistry,

        pub fn init(world: anytype) Self {
            var min_size: usize = std.math.maxInt(usize);
            var candidate_entities: []const Entity = &[_]Entity{};
            var tag_pool: TagStoragePoolType = undefined;

            inline for (tag_fields, 0..) |field, i| {
                const Tag, const modifier_type = extractType(field.type);
                const tag_storage: *const TagStorage(Tag) = world.getTagStoragePtr(Tag);
                tag_pool[i] = tag_storage;

                if (modifier_type) |_| continue;
                const size = tag_storage.packed_array.items.len;
                if (size < min_size) {
                    min_size = size;
                    candidate_entities = tag_storage.packed_array.items;
                }
            }

            return .{
                .tag_storage_pool = tag_pool,
                .entities = candidate_entities,
                .entity_registry = &world.entity_registry,
            };
        }

        pub fn getTagId(comptime T: type) u16 {
            return inline for (tag_fields, 0..) |field, i| {
                const Tag, _ = extractType(field.type);
                if (T == Tag) break i;
            } else @compileError("Unknown tag type: " ++ @typeName(T));
        }

        fn getTagStoragePtr(self: *const Self, comptime T: type) *const TagStorage(T) {
            const id = comptime getTagId(T);
            return self.tag_storage_pool[id];
        }

        pub fn filter(self: *const Self, entity: Entity) bool {
            if (!self.entity_registry.isAlive(entity)) return false;
            return filterWithModifiers(tag_fields, entity, self, getTagStoragePtr);
        }

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{
                .index = 0,
                .query = self,
            };
        }

        pub fn combinations(self: *const Self) CombinationIterator {
            return .{ .query = self };
        }

        pub fn hasOptional(self: *const Self, entity: Entity, comptime T: type) bool {
            const storage = self.getTagStoragePtr(T);
            return storage.*.contains(entity);
        }

        pub const Iterator = struct {
            index: usize,
            query: *const TagQuery(QueryTags),

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
            query: *const TagQuery(QueryTags),

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

        pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator(Self, @TypeOf(other.*)) {
            return SimpleCrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }
    };
}
