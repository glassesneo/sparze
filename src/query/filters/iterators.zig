const entity_module = @import("../../entity/entity.zig");
const Entity = entity_module.Entity;

/// CrossProductIterator provides iteration over the Cartesian product of two queries while applying filters.
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

        pub fn next(self: *Self) ?struct { Entity, Entity } {
            while (self.i < self.query1.entities.len) {
                const entity1 = self.query1.entities[self.i];

                const entity1_passes = self.query1.filter(entity1);

                if (!entity1_passes) {
                    self.i += 1;
                    self.j = 0;
                    continue;
                }

                while (self.j < self.query2.entities.len) {
                    const entity2 = self.query2.entities[self.j];
                    self.j += 1;

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

/// SimpleCrossProductIterator iterates the cartesian product of two pre-filtered queries without calling filter().
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

        pub fn next(self: *Self) ?struct { Entity, Entity } {
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
