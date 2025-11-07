const std = @import("std");

/// Buffered writer with CRC32 checksum computation
pub fn BufferedChecksumWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        const buffer_size = 64 * 1024; // 64 KB buffer

        underlying_writer: WriterType,
        buffer: [buffer_size]u8 = undefined,
        pos: usize = 0,
        crc: std.hash.Crc32 = std.hash.Crc32.init(),

        pub const Writer = std.io.GenericWriter(*Self, WriterType.Error, write);
        pub const Error = WriterType.Error;

        pub fn init(underlying_writer: WriterType) Self {
            return .{
                .underlying_writer = underlying_writer,
            };
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        /// Write bytes to the buffered writer
        fn write(self: *Self, bytes: []const u8) Error!usize {
            // Update CRC
            self.crc.update(bytes);

            var bytes_written: usize = 0;

            while (bytes_written < bytes.len) {
                const remaining_in_buffer = buffer_size - self.pos;
                const to_copy = @min(remaining_in_buffer, bytes.len - bytes_written);

                @memcpy(
                    self.buffer[self.pos .. self.pos + to_copy],
                    bytes[bytes_written .. bytes_written + to_copy],
                );

                self.pos += to_copy;
                bytes_written += to_copy;

                if (self.pos == buffer_size) {
                    try self.flushBuffer();
                }
            }

            return bytes.len;
        }

        /// Flush the buffer to the underlying writer
        fn flushBuffer(self: *Self) Error!void {
            if (self.pos > 0) {
                try self.underlying_writer.writeAll(self.buffer[0..self.pos]);
                self.pos = 0;
            }
        }

        /// Flush and return the computed CRC32 checksum
        pub fn finish(self: *Self) Error!u32 {
            try self.flushBuffer();
            return self.crc.final();
        }

        /// Get the current CRC32 value without finishing
        pub fn getCurrentCrc(self: *const Self) u32 {
            return self.crc.final();
        }
    };
}

/// Create a buffered checksum writer
pub fn bufferedChecksumWriter(writer: anytype) BufferedChecksumWriter(@TypeOf(writer)) {
    return BufferedChecksumWriter(@TypeOf(writer)).init(writer);
}

test "BufferedChecksumWriter basic" {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = bufferedChecksumWriter(fbs.writer());

    const data = "Hello, World!";
    try writer.writer().writeAll(data);

    const crc = try writer.finish();
    try std.testing.expect(crc != 0);
    try std.testing.expectEqualStrings(data, buffer[0..data.len]);
}

test "BufferedChecksumWriter large data" {
    var buffer: [128 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = bufferedChecksumWriter(fbs.writer());

    // Write more than buffer size to test flushing
    const data = [_]u8{42} ** (70 * 1024);
    try writer.writer().writeAll(&data);

    const crc = try writer.finish();
    try std.testing.expect(crc != 0);
    try std.testing.expectEqualSlices(u8, &data, buffer[0..data.len]);
}
