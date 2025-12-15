const event_storage_module = @import("../../storage/event_storage.zig");
const EventStorage = event_storage_module.EventStorage;

const common = @import("common.zig");
const FilterType = common.FilterType;

pub fn EventReader(comptime E: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .event_reader;
        pub const EventType = E;

        storage: *const EventStorage(E),

        pub fn init(storage: *const EventStorage(E)) Self {
            return .{
                .storage = storage,
            };
        }

        pub fn read(self: Self) []const E {
            return self.storage.read_buffer.items;
        }
    };
}

pub fn EventWriter(comptime E: type) type {
    return struct {
        const Self = @This();

        pub const filter_type: FilterType = .event_writer;
        pub const EventType = E;

        storage: *EventStorage(E),

        pub fn init(storage: *EventStorage(E)) Self {
            return .{
                .storage = storage,
            };
        }

        pub fn enqueue(self: Self, event: E) !void {
            return try self.storage.enqueue(event);
        }
    };
}
