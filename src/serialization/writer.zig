const std = @import("std");
const Io = std.Io;

/// Buffered writer with CRC32 checksum computation
pub fn BufferedChecksumWriter(comptime _: type) type {
    return struct {
        const Self = @This();
        const buffer_size = 64 * 1024; // 64 KB buffer

        underlying_writer: *Io.Writer,
        scratch: [buffer_size]u8 = undefined,
        fill: usize = 0,
        crc: std.hash.Crc32 = std.hash.Crc32.init(),
        interface: Io.Writer,

        pub const Error = Io.Writer.Error;

        const vtable = Io.Writer.VTable{
            .drain = drain,
            .flush = flush,
            .rebase = Io.Writer.failingRebase,
        };

        pub fn init(underlying_writer: *Io.Writer) Self {
            return .{
                .underlying_writer = underlying_writer,
                .interface = .{
                    .vtable = &vtable,
                    .buffer = &.{}, // force all writes through drain()
                },
            };
        }

        pub fn writer(self: *Self) *Io.Writer {
            return &self.interface;
        }

        /// Helper to write all bytes using Io.Writer.write() primitive
        fn writeAll(io_w: *Io.Writer, data: []const u8) Io.Writer.Error!void {
            var off: usize = 0;
            while (off < data.len) {
                const n = try io_w.write(data[off..]);
                if (n == 0) return error.WriteFailed;
                off += n;
            }
        }

        /// Flush the buffer to the underlying writer
        fn flushBuffer(self: *Self) !void {
            if (self.fill == 0) return;
            try writeAll(self.underlying_writer, self.scratch[0..self.fill]);
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
pub fn bufferedChecksumWriter(writer: *Io.Writer) BufferedChecksumWriter(void) {
    return BufferedChecksumWriter(void).init(writer);
}

pub fn OldWriterAdapter(comptime WriterType: type) type {
    const TargetType = WriterTarget(WriterType);

    return struct {
        const Self = @This();
        const Error = Io.Writer.Error;

        target: WriterType,
        interface: Io.Writer,

        const vtable = Io.Writer.VTable{
            .drain = drain,
            .flush = flush,
            .rebase = Io.Writer.failingRebase,
        };

        pub fn init(target: WriterType) Self {
            return .{ .target = target, .interface = .{ .vtable = &vtable, .buffer = &.{} } };
        }

        pub fn writer(self: *Self) *Io.Writer {
            return &self.interface;
        }

        fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_w));
            var written: usize = 0;

            if (data.len == 0) return written;

            for (data[0 .. data.len - 1]) |chunk| {
                written += try self.writeChunk(chunk);
            }

            const pattern = data[data.len - 1];
            if (pattern.len == 0 or splat == 0) return written;

            for (0..splat) |_| {
                written += try self.writeChunk(pattern);
            }

            return written;
        }

        fn flush(io_w: *Io.Writer) Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_w));

            if (comptime @hasDecl(TargetType, "flush")) {
                const target_ptr = self.targetPtr();
                target_ptr.flush() catch return error.WriteFailed;
            }
        }

        fn writeChunk(self: *Self, chunk: []const u8) Error!usize {
            const target_ptr = self.targetPtr();
            return target_ptr.write(chunk) catch return error.WriteFailed;
        }

        fn targetPtr(self: *Self) WriterPointer(WriterType) {
            return switch (@typeInfo(WriterType)) {
                .pointer => self.target,
                else => &self.target,
            };
        }
    };
}

pub fn WriterPointer(comptime WriterType: type) type {
    return switch (@typeInfo(WriterType)) {
        .pointer => WriterType,
        else => *WriterType,
    };
}

pub fn WriterTarget(comptime WriterType: type) type {
    return switch (@typeInfo(WriterType)) {
        .pointer => |ptr| ptr.child,
        else => WriterType,
    };
}

pub fn hasOldWriterApi(comptime WriterType: type) bool {
    const TargetType = WriterTarget(WriterType);
    return @hasDecl(TargetType, "write");
}

pub fn initOldWriterAdapter(writer: anytype) OldWriterAdapter(@TypeOf(writer)) {
    const WriterType = @TypeOf(writer);
    return OldWriterAdapter(WriterType).init(writer);
}

fn FixedBufferWriter() type {
    return struct {
        const Self = @This();
        const Error = Io.Writer.Error;

        buffer: []u8,
        len: usize = 0,
        interface: Io.Writer,

        const vtable = Io.Writer.VTable{
            .drain = drain,
            .flush = flush,
            .rebase = Io.Writer.failingRebase,
        };

        pub fn init(buf: []u8) Self {
            return .{ .buffer = buf, .interface = .{ .vtable = &vtable, .buffer = &.{} } };
        }

        pub fn writer(self: *Self) *Io.Writer {
            return &self.interface;
        }

        fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_w));
            var written: usize = 0;

            if (data.len == 0) return written;

            for (data[0 .. data.len - 1]) |chunk| {
                written += try self.writeChunk(chunk);
            }

            const pattern = data[data.len - 1];
            if (pattern.len == 0 or splat == 0) return written;

            for (0..splat) |_| {
                written += try self.writeChunk(pattern);
            }

            return written;
        }

        fn flush(_: *Io.Writer) Error!void {
            return;
        }

        fn writeChunk(self: *Self, chunk: []const u8) Error!usize {
            const end = self.len + chunk.len;
            if (end > self.buffer.len) return error.WriteFailed;

            @memcpy(self.buffer[self.len..end], chunk);
            self.len = end;
            return chunk.len;
        }
    };
}

test "BufferedChecksumWriter basic" {
    var buffer: [1024]u8 = undefined;
    var writer = FixedBufferWriter().init(&buffer);
    var checksumWriter = bufferedChecksumWriter(writer.writer());

    const data = "Hello, World!";
    try checksumWriter.writer().writeAll(data);

    const crc = try checksumWriter.finish();
    try std.testing.expect(crc != 0);
    try std.testing.expectEqualStrings(data, buffer[0..data.len]);
}

test "BufferedChecksumWriter large data" {
    var buffer: [128 * 1024]u8 = undefined;
    var writer = FixedBufferWriter().init(&buffer);
    var checksumWriter = bufferedChecksumWriter(writer.writer());

    // Write more than buffer size to test flushing
    const data = [_]u8{42} ** (70 * 1024);
    try checksumWriter.writer().writeAll(&data);

    const crc = try checksumWriter.finish();
    try std.testing.expect(crc != 0);
    try std.testing.expectEqualSlices(u8, &data, buffer[0..data.len]);
}
