const std = @import("std");
const Allocator = std.mem.Allocator;

/// Event storage with double-buffering for frame-based event handling.
///
/// Events are written to write_buffer during the current frame, then swapped
/// to read_buffer at frame boundaries. This allows events from frame N to be
/// consumed in frame N+1.
pub fn EventStorage(comptime E: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        write_buffer: std.ArrayList(E),
        read_buffer: std.ArrayList(E),

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .write_buffer = .{},
                .read_buffer = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.write_buffer.deinit(self.allocator);
            self.read_buffer.deinit(self.allocator);
        }

        /// Send an event to the write buffer (current frame)
        pub fn enqueue(self: *Self, event: E) !void {
            try self.write_buffer.append(self.allocator, event);
        }

        /// Clear the write buffer
        pub fn clear(self: *Self) void {
            self.write_buffer.clearRetainingCapacity();
        }

        /// Swap buffers: write_buffer becomes read_buffer
        pub fn swap(self: *Self) void {
            // Swap the buffers
            const temp = self.write_buffer;
            self.write_buffer = self.read_buffer;
            self.read_buffer = temp;
        }
    };
}

test "EventStorage basic send and read" {
    const Event = struct { value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var storage = EventStorage(Event).init(allocator);
    defer storage.deinit();

    // Write events to current frame
    try storage.enqueue(.{ .value = 1 });
    try storage.enqueue(.{ .value = 2 });
    try storage.enqueue(.{ .value = 3 });

    // Read buffer should be empty (no events from previous frame)
    try std.testing.expectEqual(@as(usize, 0), storage.read_buffer.items.len);

    // Swap buffers (simulate frame boundary)
    storage.swap();

    // Now read buffer should have events
    const events = storage.read_buffer.items;
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(i32, 1), events[0].value);
    try std.testing.expectEqual(@as(i32, 2), events[1].value);
    try std.testing.expectEqual(@as(i32, 3), events[2].value);

    // Clear write buffer for next frame
    storage.clear();

    // Write new events
    try storage.enqueue(.{ .value = 10 });

    // Old events still readable
    const old_events = storage.read_buffer.items;
    try std.testing.expectEqual(@as(usize, 3), old_events.len);

    // Swap again
    storage.swap();
    storage.clear();

    // Now should have new event
    const new_events = storage.read_buffer.items;
    try std.testing.expectEqual(@as(usize, 1), new_events.len);
    try std.testing.expectEqual(@as(i32, 10), new_events[0].value);
}

test "EventStorage multiple frames" {
    const Event = struct { frame: u32, value: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var storage = EventStorage(Event).init(allocator);
    defer storage.deinit();

    // Simulate 3 frames
    var frame: u32 = 0;
    while (frame < 3) : (frame += 1) {
        // Write events for current frame
        var i: i32 = 0;
        while (i < 5) : (i += 1) {
            try storage.enqueue(.{ .frame = frame, .value = i });
        }

        // Swap buffers
        storage.swap();

        // After swap, read buffer contains events from current frame
        const events = storage.read_buffer.items;
        try std.testing.expectEqual(@as(usize, 5), events.len);
        for (events, 0..) |event, idx| {
            try std.testing.expectEqual(frame, event.frame);
            try std.testing.expectEqual(@as(i32, @intCast(idx)), event.value);
        }

        // Clear write buffer for next frame
        storage.clear();
    }
}
