const std = @import("std");
const format = @import("format.zig");
const writer_mod = @import("writer.zig");
const reader_mod = @import("reader.zig");
const entity_registry_ser = @import("entity_registry.zig");
const sparse_set_ser = @import("sparse_set.zig");
const tag_storage_ser = @import("tag_storage.zig");
const traits = @import("traits.zig");
const compat = @import("compat.zig");

const component_storage_module = @import("../storage/component_storage.zig");
const isTagComponent = component_storage_module.isTagComponent;
const ComponentStorage = component_storage_module.ComponentStorage;

/// Serialize World to writer
pub fn serialize(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    writer: anytype,
) !void {
    const component_info = @typeInfo(ComponentTypes);
    const component_fields = component_info.@"struct".fields;
    const resource_info = @typeInfo(ResourceTypes);
    const resource_fields = resource_info.@"struct".fields;
    const event_info = @typeInfo(EventTypes);
    const event_fields = event_info.@"struct".fields;

    // Create buffered checksum writer
    var checksum_writer = writer_mod.bufferedChecksumWriter(writer);
    const w = checksum_writer.writer();

    // Compute type metadata hash
    const type_hash = format.computeWorldHash(ComponentTypes, ResourceTypes, EventTypes);

    // Write header
    const header = format.Header{
        .magic = format.MAGIC,
        .format_version = format.FORMAT_VERSION,
        .type_metadata_hash = type_hash,
        .entity_count = @intCast(world.entity_registry.aliveCount()),
        .component_type_count = @intCast(component_fields.len),
        .resource_type_count = @intCast(resource_fields.len),
        .event_type_count = @intCast(event_fields.len),
    };
    try header.write(w);

    // Serialize EntityRegistry
    try entity_registry_ser.serialize(&world.entity_registry, w);

    // Serialize component pools
    inline for (component_fields, 0..) |field, i| {
        const Component = field.type;

        // Skip components that opt out of serialization at comptime
        if (comptime !traits.shouldSerialize(Component)) {
            continue;
        }

        const component_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Component);

        // Write component metadata
        try w.writeInt(u16, component_id, .little);
        try w.writeInt(u64, type_name_hash, .little);

        // Serialize component storage (tag or sparse set)
        if (comptime isTagComponent(Component)) {
            try tag_storage_ser.serialize(Component, &world.component_pool[i], w);
        } else {
            try sparse_set_ser.serialize(Component, &world.component_pool[i], w);
        }
    }

    // Serialize resources
    inline for (resource_fields, 0..) |field, i| {
        const Resource = field.type;

        // Skip resources that opt out of serialization at comptime
        if (comptime !traits.shouldSerialize(Resource)) {
            continue;
        }

        const resource_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Resource);

        // Write resource metadata
        try w.writeInt(u16, resource_id, .little);
        try w.writeInt(u64, type_name_hash, .little);

        // Check if resource is initialized
        const is_initialized = blk: {
            if (comptime resource_fields.len == 0) {
                break :blk false;
            } else {
                break :blk world.resource_initialized.isSet(i);
            }
        };
        if (!is_initialized) {
            return error.UninitializedResource;
        }

        // Serialize as initialized
        try w.writeInt(u8, 1, .little);

        // Serialize resource data
        const Serializer = traits.getSerializer(Resource);
        try Serializer.serialize(world.resource_pool[i], w);
    }

    // Serialize events (read buffer only)
    inline for (event_fields, 0..) |field, i| {
        const Event = field.type;

        // Skip events that opt out of serialization at comptime
        if (comptime !traits.shouldSerialize(Event)) {
            continue;
        }

        const event_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Event);

        // Write event metadata
        try w.writeInt(u16, event_id, .little);
        try w.writeInt(u64, type_name_hash, .little);

        // Write read buffer only
        const read_buffer = world.event_pool[i].read_buffer.items;
        const read_count: u32 = @intCast(read_buffer.len);
        try w.writeInt(u32, read_count, .little);

        // Serialize events
        const Serializer = traits.getSerializer(Event);
        for (read_buffer) |event| {
            try Serializer.serialize(event, w);
        }
    }

    // Write CRC32 checksum footer
    const crc = try checksum_writer.finish();
    try writer.writeInt(u32, crc, .little);
}

/// Deserialize World from reader
pub fn deserialize(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    reader: anytype,
) !void {
    const component_info = @typeInfo(ComponentTypes);
    const component_fields = component_info.@"struct".fields;
    const resource_info = @typeInfo(ResourceTypes);
    const resource_fields = resource_info.@"struct".fields;
    const event_info = @typeInfo(EventTypes);
    const event_fields = event_info.@"struct".fields;

    // Create buffered checksum reader (excluding footer)
    var checksum_reader = reader_mod.bufferedChecksumReader(reader);
    const r = checksum_reader.reader();

    // Read and validate header
    const header = try format.Header.read(r);

    // Validate type metadata hash
    const expected_hash = format.computeWorldHash(ComponentTypes, ResourceTypes, EventTypes);
    if (header.type_metadata_hash != expected_hash) {
        return error.TypeMismatch;
    }

    // Validate component/resource/event counts
    if (header.component_type_count != component_fields.len) {
        return error.ComponentCountMismatch;
    }
    if (header.resource_type_count != resource_fields.len) {
        return error.ResourceCountMismatch;
    }
    if (header.event_type_count != event_fields.len) {
        return error.EventCountMismatch;
    }

    // Deserialize EntityRegistry
    world.entity_registry = try entity_registry_ser.deserialize(r);

    // Deserialize component pools
    inline for (component_fields, 0..) |field, i| {
        const Component = field.type;

        // Skip components that opt out of deserialization at comptime
        if (comptime !traits.shouldSerialize(Component)) {
            // Initialize to default/empty state for excluded components
            world.component_pool[i].deinit();
            world.component_pool[i] = ComponentStorage(Component).init(world.allocator);
            continue;
        }

        // Read component metadata
        const component_id = try compat.readInt(r, u16, .little);
        if (component_id != i) return error.ComponentIdMismatch;

        const type_name_hash = try compat.readInt(r, u64, .little);
        const expected_type_hash = format.hashTypeName(Component);
        if (type_name_hash != expected_type_hash) {
            return error.ComponentTypeMismatch;
        }

        // Deinit existing storage
        world.component_pool[i].deinit();

        // Deserialize component storage
        if (comptime isTagComponent(Component)) {
            world.component_pool[i] = try tag_storage_ser.deserialize(
                Component,
                world.allocator,
                r,
            );
        } else {
            world.component_pool[i] = try sparse_set_ser.deserialize(
                Component,
                world.allocator,
                r,
                header.format_version,
            );
        }
    }

    // Deserialize resources
    inline for (resource_fields, 0..) |field, i| {
        const Resource = field.type;

        // Skip resources that opt out of deserialization at comptime
        if (comptime !traits.shouldSerialize(Resource)) {
            // Resources that opt out of serialization are left in their current state
            // or can be re-initialized by the user as needed
            continue;
        }

        // Read resource metadata
        const resource_id = try compat.readInt(r, u16, .little);
        if (resource_id != i) return error.ResourceIdMismatch;

        const type_name_hash = try compat.readInt(r, u64, .little);
        const expected_type_hash = format.hashTypeName(Resource);
        if (type_name_hash != expected_type_hash) {
            return error.ResourceTypeMismatch;
        }

        // Read initialized flag
        const is_initialized = try compat.readInt(r, u8, .little);
        if (is_initialized == 0) {
            return error.UninitializedResource;
        }

        // Deserialize resource data
        const Serializer = traits.getSerializer(Resource);
        world.resource_pool[i] = try Serializer.deserialize(r);

        // Mark resource as initialized
        if (comptime resource_fields.len > 0) {
            world.resource_initialized.set(i);
        }
    }

    // Deserialize events (read buffer only)
    inline for (event_fields, 0..) |field, i| {
        const Event = field.type;

        // Skip events that opt out of deserialization at comptime
        if (comptime !traits.shouldSerialize(Event)) {
            // Clear both buffers for excluded events
            world.event_pool[i].read_buffer.clearRetainingCapacity();
            world.event_pool[i].write_buffer.clearRetainingCapacity();
            continue;
        }

        // Read event metadata
        const event_id = try compat.readInt(r, u16, .little);
        if (event_id != i) return error.EventIdMismatch;

        const type_name_hash = try compat.readInt(r, u64, .little);
        const expected_type_hash = format.hashTypeName(Event);
        if (type_name_hash != expected_type_hash) {
            return error.EventTypeMismatch;
        }

        // Clear existing read buffer
        world.event_pool[i].read_buffer.clearRetainingCapacity();

        // Read read buffer count
        const read_count = try compat.readInt(r, u32, .little);

        // Reserve capacity
        try world.event_pool[i].read_buffer.ensureTotalCapacity(world.allocator, read_count);

        // Deserialize events
        const Serializer = traits.getSerializer(Event);
        for (0..read_count) |_| {
            const event = try Serializer.deserialize(r);
            world.event_pool[i].read_buffer.appendAssumeCapacity(event);
        }

        // Clear write buffer
        world.event_pool[i].write_buffer.clearRetainingCapacity();
    }

    // Read and validate CRC32 checksum
    const expected_crc = try checksum_reader.readChecksumFooter();
    try checksum_reader.validateChecksum(expected_crc);
}

/// Convenience method to serialize World to file
pub fn serializeToFile(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    path: []const u8,
) !void {
    // Write to a buffer first, then write to file atomically
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(world.allocator);

    try serialize(world, ComponentTypes, ResourceTypes, EventTypes, buffer.writer(world.allocator));

    // Write buffer to file
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buffer.items);
}

/// Convenience method to deserialize World from file
pub fn deserializeFromFile(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    path: []const u8,
) !void {
    // Read entire file into buffer
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const file_size_usize = std.math.cast(usize, file_size) orelse
        return error.FileTooLarge;

    if (file_size_usize < 4) return error.FileTooSmall;

    const buffer = try world.allocator.alloc(u8, file_size_usize);
    defer world.allocator.free(buffer);

    _ = try file.readAll(buffer);

    // Validate CRC before deserializing (more reliable than tracking through VTable)
    const data_size = file_size_usize - 4;
    const expected_crc = std.mem.readInt(u32, buffer[data_size..][0..4], .little);

    var crc = std.hash.Crc32.init();
    crc.update(buffer[0..data_size]);
    if (crc.final() != expected_crc) {
        return error.ChecksumMismatch;
    }

    // Deserialize from data buffer (CRC already validated, so skip CRC reader wrapper)
    var fbs = std.io.fixedBufferStream(buffer[0..data_size]);
    try deserializeWithoutCRC(world, ComponentTypes, ResourceTypes, EventTypes, fbs.reader());
}

/// Internal helper: deserialize without CRC validation (for pre-validated streams)
fn deserializeWithoutCRC(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    reader: anytype,
) !void {
    const component_info = @typeInfo(ComponentTypes);
    const component_fields = component_info.@"struct".fields;
    const resource_info = @typeInfo(ResourceTypes);
    const resource_fields = resource_info.@"struct".fields;
    const event_info = @typeInfo(EventTypes);
    const event_fields = event_info.@"struct".fields;

    // Use reader directly (no checksum tracking)
    const r = reader;

    // Read and validate header
    const header = try format.Header.read(r);

    // Validate type metadata hash
    const expected_hash = format.computeWorldHash(ComponentTypes, ResourceTypes, EventTypes);
    if (header.type_metadata_hash != expected_hash) {
        return error.TypeMismatch;
    }

    // Validate component/resource/event counts
    if (header.component_type_count != component_fields.len) {
        return error.ComponentCountMismatch;
    }
    if (header.resource_type_count != resource_fields.len) {
        return error.ResourceCountMismatch;
    }
    if (header.event_type_count != event_fields.len) {
        return error.EventCountMismatch;
    }

    // Deserialize EntityRegistry
    world.entity_registry = try entity_registry_ser.deserialize(r);

    // Deserialize component pools
    inline for (component_fields, 0..) |field, i| {
        const Component = field.type;

        if (comptime !traits.shouldSerialize(Component)) {
            world.component_pool[i].deinit();
            world.component_pool[i] = ComponentStorage(Component).init(world.allocator);
            continue;
        }

        const component_id = try compat.readInt(r, u16, .little);
        if (component_id != i) return error.ComponentIdMismatch;

        const type_name_hash = try compat.readInt(r, u64, .little);
        const expected_type_hash = format.hashTypeName(Component);
        if (type_name_hash != expected_type_hash) {
            return error.ComponentTypeMismatch;
        }

        world.component_pool[i].deinit();

        if (comptime isTagComponent(Component)) {
            world.component_pool[i] = try tag_storage_ser.deserialize(
                Component,
                world.allocator,
                r,
            );
        } else {
            world.component_pool[i] = try sparse_set_ser.deserialize(
                Component,
                world.allocator,
                r,
                header.format_version,
            );
        }
    }

    // Deserialize resources
    inline for (resource_fields, 0..) |field, i| {
        const Resource = field.type;

        if (comptime !traits.shouldSerialize(Resource)) {
            continue;
        }

        const resource_id = try compat.readInt(r, u16, .little);
        if (resource_id != i) return error.ResourceIdMismatch;

        const type_name_hash = try compat.readInt(r, u64, .little);
        const expected_type_hash = format.hashTypeName(Resource);
        if (type_name_hash != expected_type_hash) {
            return error.ResourceTypeMismatch;
        }

        const is_initialized = try compat.readInt(r, u8, .little);
        if (is_initialized == 0) {
            return error.UninitializedResource;
        }

        const Serializer = traits.getSerializer(Resource);
        world.resource_pool[i] = try Serializer.deserialize(r);

        if (comptime resource_fields.len > 0) {
            world.resource_initialized.set(i);
        }
    }

    // Deserialize events
    inline for (event_fields, 0..) |field, i| {
        const Event = field.type;

        if (comptime !traits.shouldSerialize(Event)) {
            world.event_pool[i].read_buffer.clearRetainingCapacity();
            world.event_pool[i].write_buffer.clearRetainingCapacity();
            continue;
        }

        const event_id = try compat.readInt(r, u16, .little);
        if (event_id != i) return error.EventIdMismatch;

        const type_name_hash = try compat.readInt(r, u64, .little);
        const expected_type_hash = format.hashTypeName(Event);
        if (type_name_hash != expected_type_hash) {
            return error.EventTypeMismatch;
        }

        world.event_pool[i].read_buffer.clearRetainingCapacity();

        const read_count = try compat.readInt(r, u32, .little);
        try world.event_pool[i].read_buffer.ensureTotalCapacity(world.allocator, read_count);

        const Serializer = traits.getSerializer(Event);
        for (0..read_count) |_| {
            const event = try Serializer.deserialize(r);
            world.event_pool[i].read_buffer.appendAssumeCapacity(event);
        }

        world.event_pool[i].write_buffer.clearRetainingCapacity();
    }
    // No CRC validation - already done upfront
}
