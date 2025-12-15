const std = @import("std");
const stream = @import("world_stream.zig");

pub fn serializeToFile(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    path: []const u8,
) !void {
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(world.allocator);

    try stream.serialize(world, ComponentTypes, ResourceTypes, EventTypes, buffer.writer(world.allocator));

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buffer.items);
}

pub fn deserializeFromFile(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    path: []const u8,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const file_size_usize = std.math.cast(usize, file_size) orelse return error.FileTooLarge;
    if (file_size_usize < 4) return error.FileTooSmall;

    const buffer = try world.allocator.alloc(u8, file_size_usize);
    defer world.allocator.free(buffer);
    _ = try file.readAll(buffer);

    const data_size = file_size_usize - 4;
    const expected_crc = std.mem.readInt(u32, buffer[data_size..][0..4], .little);
    var crc = std.hash.Crc32.init();
    crc.update(buffer[0..data_size]);
    if (crc.final() != expected_crc) return error.ChecksumMismatch;

    var fbs = std.io.fixedBufferStream(buffer[0..data_size]);
    try stream.deserializeWithoutCRC(world, ComponentTypes, ResourceTypes, EventTypes, fbs.reader());
}
