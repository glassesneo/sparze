const std = @import("std");
const sparze = @import("sparze");
const World = sparze.dynamic.DynamicWorld;

const App = struct {
    allocator: std.mem.Allocator,
    component_arena: std.heap.ArenaAllocator,
    plugins: std.ArrayList(Plugin),
    world: World,

    fn init(allocator: std.mem.Allocator) App {
        return .{
            .allocator = allocator,
            .component_arena = .init(allocator),
            .world = .init(allocator),
            .plugins = .{},
        };
    }

    fn registerPlugin(self: *App, comptime P: type) !void {
        const arena_allocator = self.component_arena.allocator();
        try self.plugins.append(self.allocator, Plugin.init(P, arena_allocator));
    }

    fn start(self: *App) !void {
        for (self.plugins.items) |plugin| {
            try plugin.build(&self.world);
        }
    }

    fn deinit(self: *App) void {
        for (self.plugins.items) |plugin| {
            plugin.deinit();
        }
        self.plugins.deinit(self.allocator);
        self.world.deinit();
        self.component_arena.deinit();
    }
};

const Plugin = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    allocator: std.mem.Allocator,
    const VTable = struct {
        buildFn: *const fn (*anyopaque, *World) anyerror!void,
        deinitFn: *const fn (*anyopaque) void,
    };

    fn build(self: Plugin, world: *World) !void {
        try self.vtable.buildFn(self.instance, world);
    }

    fn deinit(self: Plugin) void {
        self.vtable.deinitFn(self.instance);
    }

    fn init(comptime T: type, allocator: std.mem.Allocator) Plugin {
        const vtable = comptime VTable{
            .buildFn = struct {
                fn build(ptr: *anyopaque, world: *World) anyerror!void {
                    const self = castTo(T, ptr);
                    try self.build(world);
                }
            }.build,
            .deinitFn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const self = castTo(T, ptr);
                    self.deinit();
                    self.allocator.destroy(self);
                }
            }.deinit,
        };
        const instance = allocator.create(T) catch @panic("Failed to allocate plugin instance");
        instance.* = T.init(allocator);

        return .{
            .vtable = &vtable,
            .instance = instance,
            .allocator = allocator,
        };
    }

    fn castTo(comptime T: type, ptr: *anyopaque) *T {
        return @ptrCast(@alignCast(ptr));
    }
};

const Position = struct {
    x: f32,
    y: f32,
};

const ExamplePlugin = struct {
    const PositionSet = sparze.SparseSet(Position);
    allocator: std.mem.Allocator,
    position_set: PositionSet,

    fn init(allocator: std.mem.Allocator) ExamplePlugin {
        return .{
            .allocator = allocator,
            .position_set = .init(allocator),
        };
    }

    fn deinit(self: *ExamplePlugin) void {
        self.position_set.deinit();
    }

    fn build(self: *ExamplePlugin, world: *World) !void {
        try world.registerComponent(Position, &self.position_set);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App.init(allocator);
    defer app.deinit();

    try app.registerPlugin(ExamplePlugin);
    try app.start();

    std.debug.print("world: {any}\n", .{app.world.component_pool});
}
