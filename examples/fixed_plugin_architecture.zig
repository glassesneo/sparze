const std = @import("std");
const Struct = std.builtin.Type.Struct;
const StructField = std.builtin.Type.StructField;
const sparze = @import("sparze");

comptime plugin_types: [1024]type = undefined,
comptime plugin_count: u10 = 0,

const App = struct {
    fn buildWorld(plugins: anytype) type {
        // const ComponentsType = construct_components_type: {
        // var length: usize = 0;
        // inline for (plugins) |P| {
        // inline for (P.Components) |_| {
        // length += 1;
        // }
        // }

        // var components_type_fields: [length]StructField = undefined;
        // var count: usize = 0;
        // inline for (plugins) |P| {
        // inline for (P.Components) |C| {
        // components_type_fields[count] = StructField{
        // .name = std.fmt.comptimePrint("{d}", .{count}),
        // .type = C,
        // .is_comptime = false,
        // .alignment = @alignOf(C),
        // .default_value_ptr = null,
        // };
        // count += 1;
        // }
        // }

        // break :construct_components_type @Type(.{ .@"struct" = .{
        // .layout = .auto,
        // .is_tuple = true,
        // .decls = &.{},
        // .fields = &components_type_fields,
        // }});
        // };
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

const ExamplePlugin = struct {
    const Components = .{ Position, Velocity };
};

const ExamplePlugin2 = struct {
    const Components = .{Acceleration};
};

pub fn main() !void {
    const World = comptime build_world: {
        break :build_world App.buildWorld(.{ ExamplePlugin, ExamplePlugin2 });
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("world: {any}\n", .{world.component_pool});
}
