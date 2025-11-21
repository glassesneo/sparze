const std = @import("std");

/// Buffered reader with CRC32 checksum validation
pub fn BufferedChecksumReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const buffer_size = 64 * 1024; // 64 KB buffer

        underlying_reader: ReaderType,
        buffer: [buffer_size]u8 = undefined,
        start: usize = 0,
        end: usize = 0,
        crc: std.hash.Crc32 = std.hash.Crc32.init(),

        pub const Reader = std.io.GenericReader(*Self, ReaderType.Error, read);
        pub const Error = ReaderType.Error;

        pub fn init(underlying_reader: ReaderType) Self {
            return .{
                .underlying_reader = underlying_reader,
            };
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        /// Read bytes from the buffered reader
        fn read(self: *Self, dest: []u8) Error!usize {
            if (dest.len == 0) return 0;

            var bytes_read: usize = 0;

            while (bytes_read < dest.len) {
                // Refill buffer if empty
                if (self.start == self.end) {
                    self.start = 0;
                    self.end = try self.underlying_reader.read(&self.buffer);
                    if (self.end == 0) break; // EOF
                }

                const available = self.end - self.start;
                const to_copy = @min(available, dest.len - bytes_read);

                @memcpy(
                    dest[bytes_read .. bytes_read + to_copy],
                    self.buffer[self.start .. self.start + to_copy],
                );

                // Update CRC
                self.crc.update(dest[bytes_read .. bytes_read + to_copy]);

                self.start += to_copy;
                bytes_read += to_copy;
            }

            return bytes_read;
        }

        /// Read bytes without updating CRC (for reading checksum itself)
        fn readWithoutCrc(self: *Self, dest: []u8) Error!usize {
            if (dest.len == 0) return 0;

            var bytes_read: usize = 0;

            while (bytes_read < dest.len) {
                // Refill buffer if empty
                if (self.start == self.end) {
                    self.start = 0;
                    self.end = try self.underlying_reader.read(&self.buffer);
                    if (self.end == 0) break; // EOF
                }

                const available = self.end - self.start;
                const to_copy = @min(available, dest.len - bytes_read);

                @memcpy(
                    dest[bytes_read .. bytes_read + to_copy],
                    self.buffer[self.start .. self.start + to_copy],
                );

                // NOTE: Do NOT update CRC here

                self.start += to_copy;
                bytes_read += to_copy;
            }

            return bytes_read;
        }

        /// Get the current CRC32 value
        pub fn getCurrentCrc(self: *const Self) u32 {
            return self.crc.final();
        }

        /// Validate checksum against expected value
        pub fn validateChecksum(self: *const Self, expected: u32) !void {
            const actual = self.getCurrentCrc();
            if (actual != expected) {
                return error.ChecksumMismatch;
            }
        }

        /// Read a u32 value without updating CRC (for reading checksum footer)
        pub fn readChecksumFooter(self: *Self) (Error || error{EndOfStream})!u32 {
            var bytes: [4]u8 = undefined;
            const n = try self.readWithoutCrc(&bytes);
            if (n < 4) return error.EndOfStream;
            return std.mem.readInt(u32, &bytes, .little);
        }
    };
}

/// Create a buffered checksum reader
pub fn bufferedChecksumReader(reader: anytype) BufferedChecksumReader(@TypeOf(reader)) {
    return BufferedChecksumReader(@TypeOf(reader)).init(reader);
}

test "BufferedChecksumReader basic" {
    const data = "Hello, World!";
    var fbs = std.io.fixedBufferStream(data);
    var reader = bufferedChecksumReader(fbs.reader());

    var buffer: [data.len]u8 = undefined;
    const bytes_read = try reader.reader().readAll(&buffer);

    try std.testing.expectEqual(data.len, bytes_read);
    try std.testing.expectEqualStrings(data, &buffer);

    const crc = reader.getCurrentCrc();
    try std.testing.expect(crc != 0);
}

test "BufferedChecksumReader large data" {
    const data = [_]u8{42} ** (70 * 1024);
    var fbs = std.io.fixedBufferStream(&data);
    var reader = bufferedChecksumReader(fbs.reader());

    var buffer: [data.len]u8 = undefined;
    const bytes_read = try reader.reader().readAll(&buffer);

    try std.testing.expectEqual(data.len, bytes_read);
    try std.testing.expectEqualSlices(u8, &data, &buffer);

    const crc = reader.getCurrentCrc();
    try std.testing.expect(crc != 0);
}

test "BufferedChecksumReader checksum validation" {
    const data = "Test data for checksum";
    var fbs = std.io.fixedBufferStream(data);
    var reader = bufferedChecksumReader(fbs.reader());

    var buffer: [data.len]u8 = undefined;
    _ = try reader.reader().readAll(&buffer);

    const correct_crc = reader.getCurrentCrc();

    // Validate with correct checksum
    try reader.validateChecksum(correct_crc);

    // Validate with incorrect checksum should fail
    const result = reader.validateChecksum(correct_crc + 1);
    try std.testing.expectError(error.ChecksumMismatch, result);
}
