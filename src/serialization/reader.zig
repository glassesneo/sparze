const std = @import("std");
const Io = std.Io;

/// Buffered reader with CRC32 checksum validation
pub fn BufferedChecksumReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const buffer_size = 64 * 1024; // 64 KB buffer

        underlying_reader: ReaderType,
        storage: [buffer_size]u8 = undefined,
        crc: std.hash.Crc32 = std.hash.Crc32.init(),
        interface: Io.Reader,
        last_crc_seek: usize = 0, // Track what we've checksummed so far

        pub const Error = ReaderType.Error || Io.Reader.Error;

        const vtable = Io.Reader.VTable{
            .stream = stream,
            .readVec = readVec,
            .discard = discard,
            .rebase = rebase,
        };

        pub fn init(underlying_reader: ReaderType) Self {
            return .{
                .underlying_reader = underlying_reader,
                .interface = .{
                    .vtable = &vtable,
                    .buffer = &.{}, // we manage storage ourselves
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        pub fn reader(self: *Self) *Io.Reader {
            return &self.interface;
        }

        fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_r));

            // First, checksum any consumed data since last checkpoint
            if (io_r.seek > self.last_crc_seek) {
                const consumed = io_r.buffer[self.last_crc_seek..io_r.seek];
                self.crc.update(consumed);
                self.last_crc_seek = io_r.seek;
            }

            var written: usize = 0;
            var remaining = @intFromEnum(limit);

            while (remaining != 0) {
                if (io_r.seek == io_r.end) {
                    io_r.seek = 0;
                    io_r.end = try self.underlying_reader.read(&self.storage);
                    io_r.buffer = self.storage[0..io_r.end];
                    self.last_crc_seek = 0;
                    if (io_r.end == 0) return if (written == 0) error.EndOfStream else written;
                }
                const chunk = io_r.buffer[io_r.seek..@min(io_r.end, io_r.seek + remaining)];
                const n = try w.write(chunk);
                if (n == 0) break;
                self.crc.update(chunk[0..n]);
                io_r.seek += n;
                self.last_crc_seek = io_r.seek;
                written += n;
                remaining -= n;
                if (n < chunk.len) break;
            }
            return written;
        }

        fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_r));

            // First, checksum any consumed data since last checkpoint
            if (io_r.seek > self.last_crc_seek) {
                const consumed = io_r.buffer[self.last_crc_seek..io_r.seek];
                self.crc.update(consumed);
                self.last_crc_seek = io_r.seek;
            }

            var total_read: usize = 0;

            for (data) |dest| {
                if (dest.len == 0) continue;

                // Try to fill this destination buffer, but allow partial progress
                var filled: usize = 0;
                while (filled < dest.len) {
                    // Refill internal buffer if empty
                    if (io_r.seek == io_r.end) {
                        io_r.seek = 0;
                        io_r.end = try self.underlying_reader.read(&self.storage);
                        io_r.buffer = self.storage[0..io_r.end];
                        self.last_crc_seek = 0;

                        // If EOF and we've made some progress, return what we have
                        if (io_r.end == 0) {
                            if (total_read > 0 or filled > 0) {
                                return total_read + filled;
                            }
                            return error.EndOfStream;
                        }
                    }

                    // Copy what's available
                    const avail = io_r.buffer[io_r.seek..io_r.end];
                    const to_copy = @min(avail.len, dest.len - filled);
                    @memcpy(dest[filled .. filled + to_copy], avail[0..to_copy]);
                    self.crc.update(dest[filled .. filled + to_copy]);
                    io_r.seek += to_copy;
                    self.last_crc_seek = io_r.seek;
                    filled += to_copy;
                    total_read += to_copy;

                    // For non-blocking IO, we should return partial progress
                    // rather than spinning until the buffer is completely full
                    if (to_copy < avail.len) break;
                }

                // If we made any progress, return it even if we didn't fill all buffers
                if (total_read > 0 and filled < dest.len) {
                    return total_read;
                }
            }

            return total_read;
        }

        fn rebase(io_r: *Io.Reader, capacity: usize) error{EndOfStream}!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_r));

            // First, checksum any consumed data since last checkpoint
            // This handles reads via takeInt/peek/take that bypass readVec
            if (io_r.seek > self.last_crc_seek) {
                const consumed = io_r.buffer[self.last_crc_seek..io_r.seek];
                self.crc.update(consumed);
                self.last_crc_seek = io_r.seek;
            }

            // If we already have enough buffered data, no need to refill
            const available = io_r.end - io_r.seek;
            if (available >= capacity) {
                return;
            }

            // If capacity is larger than our buffer, we can't satisfy it
            if (capacity > buffer_size) {
                return error.EndOfStream;
            }

            // Move remaining data to start of buffer
            if (io_r.seek > 0 and io_r.seek < io_r.end) {
                const remaining = io_r.end - io_r.seek;
                std.mem.copyForwards(u8, self.storage[0..remaining], self.storage[io_r.seek..io_r.end]);
                io_r.end = remaining;
                io_r.seek = 0;
                self.last_crc_seek = 0; // Reset checkpoint after moving data
            } else if (io_r.seek == io_r.end) {
                io_r.seek = 0;
                io_r.end = 0;
                self.last_crc_seek = 0;
            }

            // Fill buffer to satisfy capacity requirement
            while (io_r.end < capacity) {
                const n = try self.underlying_reader.read(self.storage[io_r.end..]);
                if (n == 0) {
                    // EOF reached before satisfying capacity
                    return error.EndOfStream;
                }
                io_r.end += n;
            }

            io_r.buffer = self.storage[0..io_r.end];
        }

        fn discard(io_r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_r));

            // First, checksum any consumed data since last checkpoint
            if (io_r.seek > self.last_crc_seek) {
                const consumed = io_r.buffer[self.last_crc_seek..io_r.seek];
                self.crc.update(consumed);
                self.last_crc_seek = io_r.seek;
            }

            var dropped: usize = 0;
            var remaining = @intFromEnum(limit);
            while (remaining != 0) {
                if (io_r.seek == io_r.end) {
                    io_r.seek = 0;
                    io_r.end = try self.underlying_reader.read(&self.storage);
                    io_r.buffer = self.storage[0..io_r.end];
                    self.last_crc_seek = 0;
                    if (io_r.end == 0) break;
                }
                const to_eat = @min(io_r.end - io_r.seek, remaining);
                // Checksum the data before discarding it
                self.crc.update(io_r.buffer[io_r.seek .. io_r.seek + to_eat]);
                io_r.seek += to_eat;
                self.last_crc_seek = io_r.seek;
                dropped += to_eat;
                remaining -= to_eat;
            }
            return dropped;
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
        /// This reads bypassing the CRC calculation (footer is not checksummed)
        pub fn readChecksumFooter(self: *Self) (Error || error{EndOfStream})!u32 {
            const io_r = &self.interface;
            var bytes: [4]u8 = undefined;
            var bytes_read: usize = 0;

            // First, try to get bytes from the internal buffer (if rebase already loaded them)
            const buffered = io_r.buffer[io_r.seek..io_r.end];
            if (buffered.len >= 4) {
                // CRC footer is in the buffer, read it directly
                @memcpy(&bytes, buffered[0..4]);
                io_r.seek += 4;
                self.last_crc_seek = io_r.seek; // Important: update checkpoint to skip CRC bytes
                return std.mem.readInt(u32, &bytes, .little);
            }

            // Copy any remaining buffered bytes
            if (buffered.len > 0) {
                @memcpy(bytes[0..buffered.len], buffered);
                bytes_read = buffered.len;
                io_r.seek = io_r.end; // Consumed all buffered data
                self.last_crc_seek = io_r.seek; // Update checkpoint
            }

            // Read the rest from underlying reader
            while (bytes_read < 4) {
                const n = self.underlying_reader.read(bytes[bytes_read..]) catch |err| return err;
                if (n == 0) {
                    return error.EndOfStream;
                }
                bytes_read += n;
            }

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
    var checksumReader = bufferedChecksumReader(fbs.reader());

    var buffer: [data.len]u8 = undefined;
    const bytes_read = try checksumReader.reader().*.readSliceShort(&buffer);

    try std.testing.expectEqual(data.len, bytes_read);
    try std.testing.expectEqualStrings(data, &buffer);

    const crc = checksumReader.getCurrentCrc();
    try std.testing.expect(crc != 0);
}

test "BufferedChecksumReader large data" {
    const data = [_]u8{42} ** (70 * 1024);
    var fbs = std.io.fixedBufferStream(&data);
    var checksumReader = bufferedChecksumReader(fbs.reader());

    var buffer: [data.len]u8 = undefined;
    const bytes_read = try checksumReader.reader().*.readSliceShort(&buffer);

    try std.testing.expectEqual(data.len, bytes_read);
    try std.testing.expectEqualSlices(u8, &data, &buffer);

    const crc = checksumReader.getCurrentCrc();
    try std.testing.expect(crc != 0);
}

test "BufferedChecksumReader checksum validation" {
    const data = "Test data for checksum";
    var fbs = std.io.fixedBufferStream(data);
    var checksumReader = bufferedChecksumReader(fbs.reader());

    var buffer: [data.len]u8 = undefined;
    _ = try checksumReader.reader().*.readSliceShort(&buffer);

    const correct_crc = checksumReader.getCurrentCrc();

    // Validate with correct checksum
    try checksumReader.validateChecksum(correct_crc);

    // Validate with incorrect checksum should fail
    const result = checksumReader.validateChecksum(correct_crc + 1);
    try std.testing.expectError(error.ChecksumMismatch, result);
}
