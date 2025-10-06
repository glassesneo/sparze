const std = @import("std");
const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;
const sparze = @import("sparze");

comptime plugin_types: [1024]type = undefined,
comptime plugin_count: u10 = 0,

const App = struct {
    fn buildWorld(plugins: anytype) type {
        var length: usize = 0;
        inline for (plugins) |P| {
            inline for (P.Components) |_| {
                length += 1;
            }
        }

        var components: [length]type = undefined;
        var count: usize = 0;
        inline for (plugins) |Plugin| {
            inline for (Plugin.Components) |C| {
                components[count] = C;
                count += 1;
            }
        }
        const Components = std.meta.Tuple(&components);
        return sparze.FixedWorld(Components);
    }
};

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Acceleration = struct {
    x: f32,
    y: f32,
};

const Health = struct { hp: i32 };
const Armor = struct { defense: i32 };

const MovementPlugin = struct {
    const Components = .{ Position, Velocity };
};

const PhysicsPlugin = struct {
    const Components = .{Acceleration};
};

const CombatPlugin = struct {
    const Components = .{ Health, Armor };
};

pub fn main() !void {
    const World = comptime build_world: {
        break :build_world App.buildWorld(.{ MovementPlugin, PhysicsPlugin, CombatPlugin });
    };

    // Validate groups at compile time - errors if components overlap
    World.validateGroups(.{
        struct { Position, Velocity }, // Movement group
        struct { Health, Armor }, // Combat group
    });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var world = World.init(allocator);
    defer world.deinit();

    // Create groups for fast iteration
    try world.createGroup(struct { Position, Velocity });
    try world.createGroup(struct { Health, Armor });

    // Create entities with different component combinations
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .x = 1.0, .y = 0.5 });
    try world.addComponent(player, Health, .{ .hp = 100 });
    try world.addComponent(player, Armor, .{ .defense = 50 });

    const enemy = world.createEntity();
    try world.addComponent(enemy, Position, .{ .x = 10.0, .y = 5.0 });
    try world.addComponent(enemy, Velocity, .{ .x = -0.5, .y = 0.0 });
    try world.addComponent(enemy, Health, .{ .hp = 50 });

    // Fast iteration over movement group (cache-friendly)
    const movement_entities = world.getGroupEntities(struct { Position, Velocity }) orelse &[_]sparze.Entity{};
    if (world.getGroupComponentsMut(struct { Position, Velocity }, Position)) |positions| {
        const velocities = world.getGroupComponents(struct { Position, Velocity }, Velocity).?;

        std.debug.print("Movement system - processing {} entities\n", .{movement_entities.len});
        for (positions, velocities) |*pos, vel| {
            pos.x += vel.x;
            pos.y += vel.y;
        }
    }

    // Fast iteration over combat group
    const combat_entities = world.getGroupEntities(struct { Health, Armor }) orelse &[_]sparze.Entity{};
    std.debug.print("Combat system - processing {} entities\n", .{combat_entities.len});

    std.debug.print("Player position after update: ({d}, {d})\n", .{
        world.getComponent(player, Position).?.x,
        world.getComponent(player, Position).?.y,
    });
}
