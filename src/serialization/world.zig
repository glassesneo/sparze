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
    const WriterType = @TypeOf(writer);
    var old_adapter: ?writer_mod.OldWriterAdapter(WriterType) = null;

    const io_writer: *std.Io.Writer = blk: {
        switch (@typeInfo(WriterType)) {
            .pointer => |ptr| {
                if (ptr.child == std.Io.Writer) break :blk writer;
            },
            else => {},
        }

        if (comptime @hasField(WriterType, "interface")) {
            break :blk &writer.interface;
        }

        if (comptime writer_mod.hasOldWriterApi(WriterType)) {
            old_adapter = writer_mod.initOldWriterAdapter(writer);
            break :blk old_adapter.?.writer();
        }

        @compileError("serialize expects a std.Io.Writer or a type exposing an .interface field");
    };

    // Create buffered checksum writer
    var checksum_writer = writer_mod.bufferedChecksumWriter(io_writer);
    const w = checksum_writer.writer();

    // Write header
    try writeHeader(world, ComponentTypes, ResourceTypes, EventTypes, w);

    // Serialize EntityRegistry
    try entity_registry_ser.serialize(&world.entity_registry, w);

    // Serialize components, resources, and events
    try serializeComponents(world, ComponentTypes, w);
    try serializeResources(world, ResourceTypes, w);
    try serializeEvents(world, EventTypes, w);

    // Write CRC32 checksum footer
    const crc = try checksum_writer.finish();
    try checksum_writer.underlying_writer.writeInt(u32, crc, .little);
}

/// Write serialization header with type metadata
fn writeHeader(
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
    try header.write(writer);
}

/// Serialize all component pools
fn serializeComponents(
    world: anytype,
    comptime ComponentTypes: type,
    writer: anytype,
) !void {
    const component_info = @typeInfo(ComponentTypes);
    const component_fields = component_info.@"struct".fields;

    inline for (component_fields, 0..) |field, i| {
        const Component = field.type;

        // Skip components that opt out of serialization at comptime
        if (comptime !traits.shouldSerialize(Component)) {
            continue;
        }

        const component_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Component);

        // Write component metadata
        try writer.writeInt(u16, component_id, .little);
        try writer.writeInt(u64, type_name_hash, .little);

        // Serialize component storage (tag or sparse set)
        if (comptime isTagComponent(Component)) {
            try tag_storage_ser.serialize(Component, &world.component_pool[i], writer);
        } else {
            try sparse_set_ser.serialize(Component, &world.component_pool[i], writer);
        }
    }
}

/// Serialize all resources
fn serializeResources(
    world: anytype,
    comptime ResourceTypes: type,
    writer: anytype,
) !void {
    const resource_info = @typeInfo(ResourceTypes);
    const resource_fields = resource_info.@"struct".fields;

    inline for (resource_fields, 0..) |field, i| {
        const Resource = field.type;

        // Skip resources that opt out of serialization at comptime
        if (comptime !traits.shouldSerialize(Resource)) {
            continue;
        }

        const resource_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Resource);

        // Write resource metadata
        try writer.writeInt(u16, resource_id, .little);
        try writer.writeInt(u64, type_name_hash, .little);

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
        try writer.writeInt(u8, 1, .little);

        // Serialize resource data
        const Serializer = traits.getSerializer(Resource);
        try Serializer.serialize(world.resource_pool[i], writer);
    }
}

/// Serialize all events (read buffer only)
fn serializeEvents(
    world: anytype,
    comptime EventTypes: type,
    writer: anytype,
) !void {
    const event_info = @typeInfo(EventTypes);
    const event_fields = event_info.@"struct".fields;

    inline for (event_fields, 0..) |field, i| {
        const Event = field.type;

        // Skip events that opt out of serialization at comptime
        if (comptime !traits.shouldSerialize(Event)) {
            continue;
        }

        const event_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Event);

        // Write event metadata
        try writer.writeInt(u16, event_id, .little);
        try writer.writeInt(u64, type_name_hash, .little);

        // Write read buffer only
        const read_buffer = world.event_pool[i].read_buffer.items;
        const read_count: u32 = @intCast(read_buffer.len);
        try writer.writeInt(u32, read_count, .little);

        // Serialize events
        const Serializer = traits.getSerializer(Event);
        for (read_buffer) |event| {
            try Serializer.serialize(event, writer);
        }
    }
}

/// Deserialize World from reader
pub fn deserialize(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    reader: anytype,
) !void {
    // Read all data into memory to validate checksum before mutating world state
    // This prevents leaving the world in a corrupted state if checksum validation fails
    var data_list = std.ArrayList(u8).init(world.allocator);
    defer data_list.deinit();

    // Read data in chunks until EOF
    const chunk_size = 64 * 1024; // 64 KB chunks
    while (true) {
        const start_len = data_list.items.len;
        try data_list.resize(start_len + chunk_size);

        var vec = [_][]u8{data_list.items[start_len..]};
        const bytes_read = reader.readVec(&vec) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };

        if (bytes_read == 0) {
            try data_list.resize(start_len);
            break;
        }
        try data_list.resize(start_len + bytes_read);
    }

    const data = data_list.items;

    // Verify we have at least enough data for a checksum footer
    if (data.len < 4) {
        return error.EndOfStream;
    }

    // Split data and checksum footer
    const payload = data[0 .. data.len - 4];
    const footer_bytes = data[data.len - 4 ..];
    const expected_crc = std.mem.readInt(u32, footer_bytes[0..4], .little);

    // Validate checksum before deserializing
    var crc = std.hash.Crc32.init();
    crc.update(payload);
    const actual_crc = crc.final();
    if (actual_crc != expected_crc) {
        return error.ChecksumMismatch;
    }

    // Checksum valid - now safe to deserialize into world
    var payload_stream = std.io.fixedBufferStream(payload);
    const payload_reader = payload_stream.reader();
    try deserializeCore(world, ComponentTypes, ResourceTypes, EventTypes, payload_reader);

    // Ensure entire payload was consumed (detect trailing data before checksum)
    if (payload_stream.pos != payload.len) {
        return error.TrailingDataAfterChecksum;
    }
}

/// Convenience method to serialize World to file
pub fn serializeToFile(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    path: []const u8,
) !void {
    // Write to temporary file first for atomic operation
    const tmp_path = try std.fmt.allocPrint(world.allocator, "{s}.tmp", .{path});
    defer world.allocator.free(tmp_path);

    // Ensure temp file is cleaned up on error
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Open file for writing
    const file = try std.fs.cwd().createFile(tmp_path, .{});
    var file_open = true;
    errdefer if (file_open) file.close(); // Close file on error (guarded to prevent double-close)

    // Use zero-length buffer to fully disable file-level buffering
    var no_buffer: [0]u8 = .{};
    var file_writer = file.writer(&no_buffer);

    // Serialize directly to file (serialize() uses BufferedChecksumWriter internally)
    try serialize(world, ComponentTypes, ResourceTypes, EventTypes, &file_writer.interface);

    // Flush buffered data and sync to disk for crash safety
    try file_writer.interface.flush();
    try file.sync();

    // Close file before renaming (required on some platforms)
    file.close();
    file_open = false; // Prevent errdefer from double-closing

    // Atomically replace the target file
    try std.fs.cwd().rename(tmp_path, path);

    // Note: Full crash safety would require syncing the directory after rename
    // to ensure the directory entry is durable, but Dir.sync() is not available
    // in Zig 0.15.1. The file data is synced above, so only the rename metadata
    // may be lost on crash.
}

/// Convenience method to deserialize World from file
pub fn deserializeFromFile(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    path: []const u8,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Get file size to know how much to checksum (everything except 4-byte footer)
    const file_size = try file.getEndPos();
    if (file_size < 4) {
        return error.ChecksumMismatch; // File too short
    }
    try file.seekTo(0); // Rewind after getEndPos

    // Phase 1: Stream through file to validate checksum without buffering
    // Create zero-length buffer to disable file-level buffering
    var no_buffer: [0]u8 = .{};
    var file_reader = file.reader(&no_buffer);
    var checksum_reader = reader_mod.bufferedChecksumReader(&file_reader.interface);

    // Stream through payload (all but last 4 bytes) to compute CRC
    const payload_size = file_size - 4;
    const discarded = try checksum_reader.reader().discard(@enumFromInt(payload_size));
    if (discarded != payload_size) {
        return error.EndOfStream; // Unexpected EOF
    }

    // Read and validate checksum footer
    const expected_crc = try checksum_reader.readChecksumFooter();
    try checksum_reader.validateChecksum(expected_crc);

    // Phase 2: Checksum valid - rewind and deserialize
    try file.seekTo(0);

    // Create new buffered reader for deserialization
    var deserialize_file_reader = file.reader(&no_buffer);
    var deserialize_checksum_reader = reader_mod.bufferedChecksumReader(&deserialize_file_reader.interface);
    
    // Deserialize using the buffered checksum reader (provides proper buffering)
    try deserializeCore(world, ComponentTypes, ResourceTypes, EventTypes, deserialize_checksum_reader.reader());
}

/// Core deserialization logic shared by deserialize and file I/O
fn deserializeCore(
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

    // Read and validate header
    const header = try format.Header.read(reader);

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
    world.entity_registry = try entity_registry_ser.deserialize(reader);

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
        const component_id = try compat.readInt(reader, u16, .little);
        if (component_id != i) return error.ComponentIdMismatch;

        const type_name_hash = try compat.readInt(reader, u64, .little);
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
                reader,
            );
        } else {
            world.component_pool[i] = try sparse_set_ser.deserialize(
                Component,
                world.allocator,
                reader,
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
        const resource_id = try compat.readInt(reader, u16, .little);
        if (resource_id != i) return error.ResourceIdMismatch;

        const type_name_hash = try compat.readInt(reader, u64, .little);
        const expected_type_hash = format.hashTypeName(Resource);
        if (type_name_hash != expected_type_hash) {
            return error.ResourceTypeMismatch;
        }

        // Read initialized flag
        const is_initialized = try compat.readInt(reader, u8, .little);
        if (is_initialized == 0) {
            return error.UninitializedResource;
        }

        // Deserialize resource data
        const Serializer = traits.getSerializer(Resource);
        world.resource_pool[i] = try Serializer.deserialize(reader);

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
        const event_id = try compat.readInt(reader, u16, .little);
        if (event_id != i) return error.EventIdMismatch;

        const type_name_hash = try compat.readInt(reader, u64, .little);
        const expected_type_hash = format.hashTypeName(Event);
        if (type_name_hash != expected_type_hash) {
            return error.EventTypeMismatch;
        }

        // Clear existing read buffer
        world.event_pool[i].read_buffer.clearRetainingCapacity();

        // Read read buffer count
        const read_count = try compat.readInt(reader, u32, .little);

        // Reserve capacity
        try world.event_pool[i].read_buffer.ensureTotalCapacity(world.allocator, read_count);

        // Deserialize events
        const Serializer = traits.getSerializer(Event);
        for (0..read_count) |_| {
            const event = try Serializer.deserialize(reader);
            world.event_pool[i].read_buffer.appendAssumeCapacity(event);
        }

        // Clear write buffer
        world.event_pool[i].write_buffer.clearRetainingCapacity();
    }
}