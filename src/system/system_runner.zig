const std = @import("std");
const StructField = std.builtin.Type.StructField;

const filter_module = @import("../query/filter.zig");
pub const FilterType = filter_module.FilterType;

const Commands = @import("commands.zig").Commands;

/// Build a tuple type from a system function's parameter list at compile time; converts `anytype` parameters to Commands(World) and preserves all other types for parameter injection.
fn constructSystemArgsType(comptime fn_info: std.builtin.Type.Fn, comptime World: type) type {
    const CommandsType = Commands(World);
    var fields: [fn_info.params.len]StructField = undefined;
    for (fn_info.params, 0..) |param, i| {
        const ArgType = if (param.type) |t|
            t
        else
            CommandsType;

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

/// Create a system function for a specific World type that can be called with world.runSystem(system_fn).
pub fn createSystemFunction(comptime World: type, comptime system_fn: anytype) fn (*World) anyerror!void {
    const system_type_info = switch (@typeInfo(@TypeOf(system_fn))) {
        .@"fn" => |f| f,
        else => @compileError("Expected a function, got " ++ @typeName(@TypeOf(system_fn))),
    };

    const SystemArgsType = constructSystemArgsType(system_type_info, World);
    const CommandsType = Commands(World);

    return struct {
        fn run(world: *World) !void {
            const system_args = construct_args: {
                var args: SystemArgsType = undefined;
                inline for (system_type_info.params, 0..) |param, i| {
                    const ArgType = param.type orelse CommandsType;

                    if (ArgType == std.mem.Allocator) {
                        args[i] = world.allocator;
                    } else if (ArgType == CommandsType) {
                        args[i] = CommandsType.init(world, &world.command_buffer);
                    } else if (@typeInfo(ArgType) == .pointer) {
                        // Handle resource pointer types: *const T for Resource(T), *T for ResourceMut(T)
                        const ptr_info = @typeInfo(ArgType).pointer;
                        if (ptr_info.size != .one) {
                            @compileError("System parameter pointer must be single-item pointer, got slice or multi-pointer: " ++ @typeName(ArgType));
                        }
                        const ChildType = ptr_info.child;
                        // Validate this is a registered resource type (triggers compile error if not)
                        _ = World.getResourceId(ChildType);

                        if (ptr_info.is_const) {
                            args[i] = world.getResourcePtr(ChildType);
                        } else {
                            args[i] = world.getResourcePtrMut(ChildType);
                        }
                    } else if (@hasDecl(ArgType, "filter_type")) {
                        const filter_type: FilterType = ArgType.filter_type;
                        switch (filter_type) {
                            .single_query => {
                                args[i] = ArgType.init(world.getSparseSetPtr(ArgType.Component));
                            },
                            .query => {
                                args[i] = ArgType.init(world);
                            },
                            .group => {
                                args[i] = ArgType.init(world);
                            },
                            .single_tag => {
                                args[i] = ArgType.init(world.getTagStoragePtr(ArgType.Component));
                            },
                            .tag_query => {
                                args[i] = ArgType.init(world);
                            },
                            .event_reader => {
                                args[i] = ArgType.init(world.getEventStoragePtr(ArgType.EventType));
                            },
                            .event_writer => {
                                args[i] = ArgType.init(world.getEventStoragePtrMut(ArgType.EventType));
                            },
                        }
                    } else {
                        @compileError("System parameter must be a query filter type, Commands, or Allocator. Got: " ++ @typeName(ArgType));
                    }
                }
                break :construct_args args;
            };

            if (system_type_info.return_type.? == void) {
                @call(.auto, system_fn, system_args);
            } else {
                try @call(.auto, system_fn, system_args);
            }
        }
    }.run;
}
