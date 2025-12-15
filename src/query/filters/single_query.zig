const entity_module = @import("../../entity/entity.zig");
const Entity = entity_module.Entity;

const sparse_set_module = @import("../../storage/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;

const common = @import("common.zig");
const FilterType = common.FilterType;

const iterators = @import("iterators.zig");
const SimpleCrossProductIterator = iterators.SimpleCrossProductIterator;

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

        pub fn crossProduct(self: *const Self, other: anytype) SimpleCrossProductIterator(Self, @TypeOf(other.*)) {
            return SimpleCrossProductIterator(Self, @TypeOf(other.*)).init(self, other);
        }
    };
}
