const std = @import("std");
const Io = std.Io;

/// Buffered writer with CRC32 checksum computation
pub fn BufferedChecksumWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        const buffer_size = 64 * 1024; // 64 KB buffer

        underlying_writer: WriterType,
        scratch: [buffer_size]u8 = undefined,
        fill: usize = 0,
        crc: std.hash.Crc32 = std.hash.Crc32.init(),
        interface: Io.Writer,

        pub const Error = WriterType.Error || Io.Writer.Error;

        const vtable = Io.Writer.VTable{
            .drain = drain,
            .flush = flush,
            .rebase = Io.Writer.failingRebase,
        };

        pub fn init(underlying_writer: WriterType) Self {
            var self: Self = .{
                .underlying_writer = underlying_writer,
                .interface = undefined,
            };
            self.interface = .{
                .vtable = &vtable,
                .buffer = &.{}, // force all writes through drain()
            };
            return self;
        }

        pub fn writer(self: *Self) *Io.Writer {
            return &self.interface;
        }

        /// Flush the buffer to the underlying writer
        fn flushBuffer(self: *Self) !void {
            if (self.fill == 0) return;
            try self.underlying_writer.writeAll(self.scratch[0..self.fill]);
            self.fill = 0;
        }

        /// Helper to write bytes to buffer with CRC tracking
        fn push(self: *Self, bytes: []const u8) !usize {
            var offset: usize = 0;
            while (offset < bytes.len) {
                if (self.fill == self.scratch.len) {
                    try self.flushBuffer();
                }
                const space = self.scratch.len - self.fill;
                const to_copy = @min(space, bytes.len - offset);
                @memcpy(self.scratch[self.fill .. self.fill + to_copy], bytes[offset .. offset + to_copy]);
                self.crc.update(bytes[offset .. offset + to_copy]);
                self.fill += to_copy;
                offset += to_copy;
            }
            return bytes.len;
        }

        /// VTable implementation for drain - must convert errors to Io.Writer.Error
        fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_w));
            var written: usize = 0;

            // Write all chunks except the last
            for (data[0 .. data.len - 1]) |chunk| {
                // Must catch and convert to WriteFailed for VTable contract
                written += self.push(chunk) catch return error.WriteFailed;
            }

            // Handle the last chunk with splatting
            const pattern = data[data.len - 1];
            if (pattern.len == 0 or splat == 0) return written;

            for (0..splat) |_| {
                written += self.push(pattern) catch return error.WriteFailed;
            }

            return written;
        }

        /// VTable implementation for flush - must convert errors to Io.Writer.Error
        fn flush(io_w: *Io.Writer) Io.Writer.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_w));
            // Must catch and convert to WriteFailed for VTable contract
            self.flushBuffer() catch return error.WriteFailed;
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
    var checksumWriter = bufferedChecksumWriter(fbs.writer());

    const data = "Hello, World!";
    try checksumWriter.writer().writeAll(data);

    const crc = try checksumWriter.finish();
    try std.testing.expect(crc != 0);
    try std.testing.expectEqualStrings(data, buffer[0..data.len]);
}

test "BufferedChecksumWriter large data" {
    var buffer: [128 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var checksumWriter = bufferedChecksumWriter(fbs.writer());

    // Write more than buffer size to test flushing
    const data = [_]u8{42} ** (70 * 1024);
    try checksumWriter.writer().writeAll(&data);

    const crc = try checksumWriter.finish();
    try std.testing.expect(crc != 0);
    try std.testing.expectEqualSlices(u8, &data, buffer[0..data.len]);
}
