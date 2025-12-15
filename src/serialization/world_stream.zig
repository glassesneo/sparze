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

    var checksum_writer = writer_mod.bufferedChecksumWriter(writer);
    const w = checksum_writer.writer();

    const type_hash = format.computeWorldHash(ComponentTypes, ResourceTypes, EventTypes);
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

    try entity_registry_ser.serialize(&world.entity_registry, w);

    inline for (component_fields, 0..) |field, i| {
        const Component = field.type;
        if (comptime !traits.shouldSerialize(Component)) {
            continue;
        }
        const component_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Component);

        try w.writeInt(u16, component_id, .little);
        try w.writeInt(u64, type_name_hash, .little);

        if (comptime isTagComponent(Component)) {
            try tag_storage_ser.serialize(Component, &world.component_pool[i], w);
        } else {
            try sparse_set_ser.serialize(Component, &world.component_pool[i], w);
        }
    }

    inline for (resource_fields, 0..) |field, i| {
        const Resource = field.type;
        if (comptime !traits.shouldSerialize(Resource)) {
            continue;
        }
        const resource_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Resource);

        try w.writeInt(u16, resource_id, .little);
        try w.writeInt(u64, type_name_hash, .little);

        const is_initialized = blk: {
            if (comptime resource_fields.len == 0) break :blk false;
            break :blk world.resource_initialized.isSet(i);
        };
        if (!is_initialized) return error.UninitializedResource;

        try w.writeInt(u8, 1, .little);
        const Serializer = traits.getSerializer(Resource);
        try Serializer.serialize(world.resource_pool[i], w);
    }

    inline for (event_fields, 0..) |field, i| {
        const Event = field.type;
        if (comptime !traits.shouldSerialize(Event)) {
            continue;
        }
        const event_id: u16 = @intCast(i);
        const type_name_hash = format.hashTypeName(Event);

        try w.writeInt(u16, event_id, .little);
        try w.writeInt(u64, type_name_hash, .little);

        const read_buffer = world.event_pool[i].read_buffer.items;
        const read_count: u32 = @intCast(read_buffer.len);
        try w.writeInt(u32, read_count, .little);

        const Serializer = traits.getSerializer(Event);
        for (read_buffer) |event| {
            try Serializer.serialize(event, w);
        }
    }

    const crc = try checksum_writer.finish();
    try writer.writeInt(u32, crc, .little);
}

pub fn deserialize(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    reader: anytype,
) !void {
    var checksum_reader = reader_mod.bufferedChecksumReader(reader);
    try deserializeBody(world, ComponentTypes, ResourceTypes, EventTypes, checksum_reader.reader());
    const expected_crc = try checksum_reader.readChecksumFooter();
    try checksum_reader.validateChecksum(expected_crc);
}

pub fn deserializeWithoutCRC(
    world: anytype,
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
    reader: anytype,
) !void {
    try deserializeBody(world, ComponentTypes, ResourceTypes, EventTypes, reader);
}

fn deserializeBody(
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

    const header = try format.Header.read(reader);

    const expected_hash = format.computeWorldHash(ComponentTypes, ResourceTypes, EventTypes);
    if (header.type_metadata_hash != expected_hash) {
        return error.TypeMismatch;
    }
    if (header.component_type_count != component_fields.len) return error.ComponentCountMismatch;
    if (header.resource_type_count != resource_fields.len) return error.ResourceCountMismatch;
    if (header.event_type_count != event_fields.len) return error.EventCountMismatch;

    world.entity_registry = try entity_registry_ser.deserialize(reader);

    inline for (component_fields, 0..) |field, i| {
        const Component = field.type;
        if (comptime !traits.shouldSerialize(Component)) {
            world.component_pool[i].deinit();
            world.component_pool[i] = ComponentStorage(Component).init(world.allocator);
            continue;
        }

        const component_id = try compat.readInt(reader, u16, .little);
        if (component_id != i) return error.ComponentIdMismatch;
        const type_name_hash = try compat.readInt(reader, u64, .little);
        const expected_type_hash = format.hashTypeName(Component);
        if (type_name_hash != expected_type_hash) {
            return error.ComponentTypeMismatch;
        }

        world.component_pool[i].deinit();
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

    inline for (resource_fields, 0..) |field, i| {
        const Resource = field.type;
        if (comptime !traits.shouldSerialize(Resource)) {
            continue;
        }
        const resource_id = try compat.readInt(reader, u16, .little);
        if (resource_id != i) return error.ResourceIdMismatch;
        const type_name_hash = try compat.readInt(reader, u64, .little);
        const expected_type_hash = format.hashTypeName(Resource);
        if (type_name_hash != expected_type_hash) {
            return error.ResourceTypeMismatch;
        }
        const is_initialized = try compat.readInt(reader, u8, .little);
        if (is_initialized == 0) return error.UninitializedResource;

        const Serializer = traits.getSerializer(Resource);
        world.resource_pool[i] = try Serializer.deserialize(reader);
        if (comptime resource_fields.len > 0) {
            world.resource_initialized.set(i);
        }
    }

    inline for (event_fields, 0..) |field, i| {
        const Event = field.type;
        if (comptime !traits.shouldSerialize(Event)) {
            world.event_pool[i].read_buffer.clearRetainingCapacity();
            world.event_pool[i].write_buffer.clearRetainingCapacity();
            continue;
        }
        const event_id = try compat.readInt(reader, u16, .little);
        if (event_id != i) return error.EventIdMismatch;
        const type_name_hash = try compat.readInt(reader, u64, .little);
        const expected_type_hash = format.hashTypeName(Event);
        if (type_name_hash != expected_type_hash) {
            return error.EventTypeMismatch;
        }
        world.event_pool[i].read_buffer.clearRetainingCapacity();
        const read_count = try compat.readInt(reader, u32, .little);
        try world.event_pool[i].read_buffer.ensureTotalCapacity(world.allocator, read_count);

        const Serializer = traits.getSerializer(Event);
        for (0..read_count) |_| {
            const event = try Serializer.deserialize(reader);
            world.event_pool[i].read_buffer.appendAssumeCapacity(event);
        }
        world.event_pool[i].write_buffer.clearRetainingCapacity();
    }
}
