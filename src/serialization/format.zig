const std = @import("std");

/// Magic number for Sparze serialization format: "SPZE"
pub const MAGIC: [4]u8 = .{ 'S', 'P', 'Z', 'E' };

/// Current serialization format version
pub const FORMAT_VERSION: u32 = 1;

/// Header structure for serialized world data
pub const Header = struct {
    magic: [4]u8,
    format_version: u32,
    type_metadata_hash: u64,
    entity_count: u32,
    component_type_count: u32,
    resource_type_count: u32,
    event_type_count: u32,

    pub fn write(self: Header, writer: anytype) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u32, self.format_version, .little);
        try writer.writeInt(u64, self.type_metadata_hash, .little);
        try writer.writeInt(u32, self.entity_count, .little);
        try writer.writeInt(u32, self.component_type_count, .little);
        try writer.writeInt(u32, self.resource_type_count, .little);
        try writer.writeInt(u32, self.event_type_count, .little);
    }

    pub fn read(reader: anytype) !Header {
        var header: Header = undefined;
        try reader.readNoEof(&header.magic);

        // Validate magic number
        if (!std.mem.eql(u8, &header.magic, &MAGIC)) {
            return error.InvalidMagicNumber;
        }

        header.format_version = try reader.readInt(u32, .little);
        if (header.format_version != FORMAT_VERSION) {
            return error.UnsupportedFormatVersion;
        }

        header.type_metadata_hash = try reader.readInt(u64, .little);
        header.entity_count = try reader.readInt(u32, .little);
        header.component_type_count = try reader.readInt(u32, .little);
        header.resource_type_count = try reader.readInt(u32, .little);
        header.event_type_count = try reader.readInt(u32, .little);

        return header;
    }
};

/// FNV-1a hash function for type names
/// Fast, simple, good distribution for short strings
pub fn fnv1aHash(bytes: []const u8) u64 {
    const FNV_OFFSET: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;

    var hash: u64 = FNV_OFFSET;
    for (bytes) |byte| {
        hash ^= byte;
        hash = @mulWithOverflow(hash, FNV_PRIME)[0];
    }
    return hash;
}

/// Compute hash for a single type name
pub fn hashTypeName(comptime T: type) u64 {
    const name = @typeName(T);
    return comptime fnv1aHash(name);
}

/// Compute combined hash for a tuple of types
pub fn hashTypeTuple(comptime Types: type) u64 {
    const type_info = @typeInfo(Types);
    if (type_info != .@"struct") {
        @compileError("Expected struct type for type tuple");
    }

    const fields = type_info.@"struct".fields;
    if (fields.len == 0) {
        return 0; // Empty tuple has hash 0
    }

    var hash: u64 = 0xcbf29ce484222325; // FNV offset
    inline for (fields) |field| {
        const type_hash = comptime hashTypeName(field.type);
        hash ^= type_hash;
        hash = @mulWithOverflow(hash, 0x100000001b3)[0]; // FNV prime
    }
    return hash;
}

/// Compute combined metadata hash for World type signature
pub fn computeWorldHash(
    comptime ComponentTypes: type,
    comptime ResourceTypes: type,
    comptime EventTypes: type,
) u64 {
    const component_hash = hashTypeTuple(ComponentTypes);
    const resource_hash = hashTypeTuple(ResourceTypes);
    const event_hash = hashTypeTuple(EventTypes);

    // Combine hashes using FNV-1a
    var hash: u64 = 0xcbf29ce484222325;
    hash ^= component_hash;
    hash = @mulWithOverflow(hash, 0x100000001b3)[0];
    hash ^= resource_hash;
    hash = @mulWithOverflow(hash, 0x100000001b3)[0];
    hash ^= event_hash;
    hash = @mulWithOverflow(hash, 0x100000001b3)[0];
    return hash;
}

test "fnv1aHash" {
    const hash1 = fnv1aHash("test");
    const hash2 = fnv1aHash("test");
    const hash3 = fnv1aHash("different");

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
}

test "hashTypeName" {
    const hash1 = hashTypeName(u32);
    const hash2 = hashTypeName(u32);
    const hash3 = hashTypeName(f32);

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
}

test "hashTypeTuple" {
    const Tuple1 = struct { u32, f32, bool };
    const Tuple2 = struct { u32, f32, bool };
    const Tuple3 = struct { u32, bool, f32 }; // Different order
    const Empty = struct {};

    const hash1 = hashTypeTuple(Tuple1);
    const hash2 = hashTypeTuple(Tuple2);
    const hash3 = hashTypeTuple(Tuple3);
    const hash_empty = hashTypeTuple(Empty);

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
    try std.testing.expectEqual(@as(u64, 0), hash_empty);
}

test "computeWorldHash" {
    const hash1 = computeWorldHash(
        struct { u32, f32 },
        struct { bool },
        struct {},
    );
    const hash2 = computeWorldHash(
        struct { u32, f32 },
        struct { bool },
        struct {},
    );
    const hash3 = computeWorldHash(
        struct { f32, u32 }, // Different component order
        struct { bool },
        struct {},
    );

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
}

test "Header write/read" {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    const header = Header{
        .magic = MAGIC,
        .format_version = FORMAT_VERSION,
        .type_metadata_hash = 0x123456789ABCDEF0,
        .entity_count = 100,
        .component_type_count = 5,
        .resource_type_count = 2,
        .event_type_count = 3,
    };

    // Write
    try header.write(fbs.writer());

    // Read
    fbs.pos = 0;
    const read_header = try Header.read(fbs.reader());

    try std.testing.expectEqualSlices(u8, &header.magic, &read_header.magic);
    try std.testing.expectEqual(header.format_version, read_header.format_version);
    try std.testing.expectEqual(header.type_metadata_hash, read_header.type_metadata_hash);
    try std.testing.expectEqual(header.entity_count, read_header.entity_count);
    try std.testing.expectEqual(header.component_type_count, read_header.component_type_count);
    try std.testing.expectEqual(header.resource_type_count, read_header.resource_type_count);
    try std.testing.expectEqual(header.event_type_count, read_header.event_type_count);
}
