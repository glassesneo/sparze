const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("core/entity.zig");
const Entity = entity_module.Entity;

pub const FilterType = enum {
    single_query,
    query,
    group,
};

/// SingleQuery provides iteration over entities with a specific component for a given World type
pub fn SingleQuery(comptime World: type, comptime QueryComponent: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .single_query;
        pub const Component = QueryComponent;

        entities: []const Entity,
        components: []Component,

        pub fn init(world: *World) Self {
            const sparse_set = world.getSparseSetPtr(Component);
            return .{
                .entities = sparse_set.packed_array.items,
                .components = sparse_set.components.items,
            };
        }
    };
}

/// Group provides fast iteration over entities with multiple components for a given World type
pub fn Group(comptime World: type, comptime GroupComponents: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .group;
        pub const ComponentTypes = GroupComponents;

        world: *World,

        pub fn init(world: *World) Self {
            return .{ .world = world };
        }

        pub fn getEntities(self: Self) []const Entity {
            return self.world.getGroupEntities(ComponentTypes) orelse &[_]Entity{};
        }

        pub fn getArrayOf(self: Self, comptime C: type) []const C {
            return self.world.getGroupComponents(ComponentTypes, C) orelse &[_]C{};
        }

        pub fn getMutArrayOf(self: Self, comptime C: type) []C {
            return self.world.getGroupComponentsMut(ComponentTypes, C) orelse &[_]C{};
        }
    };
}

/// Query provides runtime intersection query over entities with multiple components
/// Unlike Group, this doesn't require group setup but performs intersection at query time
pub fn Query(comptime World: type, comptime QueryComponents: type) type {
    const component_fields = comptime std.meta.fields(QueryComponents);
    if (component_fields.len == 0) @compileError("Query must have at least one component");

    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .query;
        pub const ComponentTypes = QueryComponents;

        world: *World,
        entities: []const Entity,

        pub fn init(world: *World) Self {
            // Find the smallest sparse set to minimize iterations
            // We need to find this at runtime, but we can iterate all component types at comptime
            var min_size: usize = std.math.maxInt(usize);
            var candidate_entities: []const Entity = &[_]Entity{};

            // Try each component type and find the one with smallest sparse set
            inline for (component_fields) |field| {
                const sparse_set = world.getSparseSetPtr(field.type);
                const size = sparse_set.packed_array.items.len;
                if (size < min_size) {
                    min_size = size;
                    candidate_entities = sparse_set.packed_array.items;
                }
            }

            // Return a query that will iterate through the smallest set
            // Users must call hasAllComponents() to filter for entities with all components
            return .{
                .world = world,
                .entities = candidate_entities,
            };
        }

        /// Get immutable component for an entity
        pub fn getComponent(self: Self, entity: Entity, comptime C: type) ?C {
            return self.world.getComponent(entity, C);
        }

        /// Get mutable component pointer for an entity
        pub fn getComponentMut(self: Self, entity: Entity, comptime C: type) ?*C {
            const sparse_set = self.world.getSparseSetPtr(C);
            return sparse_set.getPtrMut(entity);
        }

        /// Check if entity has all required components
        pub fn hasAllComponents(self: Self, entity: Entity) bool {
            inline for (component_fields) |field| {
                if (!self.world.hasComponent(entity, field.type)) {
                    return false;
                }
            }
            return true;
        }
    };
}

fn constructSystemArgsType(comptime fn_info: std.builtin.Type.Fn) type {
    var fields: [fn_info.params.len]StructField = undefined;
    for (fn_info.params, 0..) |param, i| {
        const ArgType = param.type orelse @compileError("System function must have typed parameters");
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

/// Create a system function for a specific World type that can be called with world.runSystem(system_fn)
pub fn createSystemFunction(comptime World: type, comptime system_fn: anytype) fn (*World) anyerror!void {
    const system_type_info = switch (@typeInfo(@TypeOf(system_fn))) {
        .@"fn" => |f| f,
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(system_fn))),
    };

    const SystemArgsType = constructSystemArgsType(system_type_info);

    return struct {
        fn run(world: *World) !void {
            const system_args = construct_args: {
                var args: SystemArgsType = undefined;
                inline for (system_type_info.params, 0..) |param, i| {
                    const ArgType = param.type.?;
                    if (!@hasDecl(ArgType, "filter_type")) {
                        @compileError("System parameter must be a Query or Group type. Got: " ++ @typeName(ArgType));
                    }

                    const filter_type: FilterType = ArgType.filter_type;
                    switch (filter_type) {
                        .single_query => {
                            args[i] = ArgType.init(world);
                        },
                        .query => {
                            args[i] = ArgType.init(world);
                        },
                        .group => {
                            args[i] = ArgType.init(world);
                        },
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
    const PositionQuery = SingleQuery(TestWorld, Position);
    const query = PositionQuery.init(&world);

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
    const MovementGroup = Group(TestWorld, struct { Position, Velocity });
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
        fn system(query: SingleQuery(TestWorld, Position)) !void {
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
        fn system(group: Group(TestWorld, struct { Position, Velocity })) !void {
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
            movement: Group(TestWorld, struct { Position, Velocity }),
            health_query: SingleQuery(TestWorld, Health),
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
    const MovementQuery = Query(TestWorld, struct { Position, Velocity });
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
    const MovementQuery = Query(TestWorld, struct { Position, Velocity });
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
        fn system(query: Query(TestWorld, struct { Position, Health })) !void {
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
    const FullEntityQuery = Query(TestWorld, struct { Position, Velocity, Health });
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
