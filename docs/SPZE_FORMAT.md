# SPZE Format Specification

**Version**: 1
**File Extension**: `.spze`
**Magic Number**: `SPZE` (0x53 0x50 0x5A 0x45)

## Overview

SPZE (Sparze Serialization Format) is a binary format for persisting complete ECS world state, designed for high-performance game saves and state snapshots. The format prioritizes performance, data integrity, and type safety.

## Design Goals

1. **Performance**: Buffered I/O, minimal allocations, cache-friendly layouts
2. **Type Safety**: Hash-based validation prevents type mismatches between save and load
3. **Data Integrity**: CRC32 checksums detect file corruption
4. **Reproducibility**: Complete entity state including versioning and free list
5. **Flexibility**: Hybrid serialization (automatic POD, custom for complex types)

## File Structure

```
┌────────────────────────────────────────────────────┐
│ Header                                             │
├────────────────────────────────────────────────────┤
│ Entity Registry                                    │
├────────────────────────────────────────────────────┤
│ Component Pools (per type)                        │
│   ├─ SparseSet (regular components)               │
│   └─ TagStorage (tag components)                  │
├────────────────────────────────────────────────────┤
│ Resource Pools (per type)                         │
├────────────────────────────────────────────────────┤
│ Event Pools (per type, read buffer only)          │
├────────────────────────────────────────────────────┤
│ CRC32 Checksum (footer)                           │
└────────────────────────────────────────────────────┘
```

All multi-byte integers are stored in **little-endian** format.

## Header

**Size**: Variable (minimum 40 bytes)

```
Offset | Size | Field                  | Type   | Description
-------|------|------------------------|--------|------------------------------------------
0      | 4    | magic                  | u8[4]  | Magic number: "SPZE" (0x53504A45)
4      | 4    | format_version         | u32    | Format version (currently 1)
8      | 8    | type_metadata_hash     | u64    | FNV-1a hash of component/resource/event types
16     | 4    | entity_count           | u32    | Number of alive entities
20     | 4    | component_type_count   | u32    | Number of component types
24     | 4    | resource_type_count    | u32    | Number of resource types
28     | 4    | event_type_count       | u32    | Number of event types
```

### Type Metadata Hash

The `type_metadata_hash` is computed using the FNV-1a algorithm:

```
hash = FNV_OFFSET_BASIS (0xcbf29ce484222325)

For each component type:
    type_hash = fnv1a(type_name)
    hash = hash XOR type_hash
    hash = hash * FNV_PRIME (0x100000001b3)

For each resource type:
    type_hash = fnv1a(type_name)
    hash = hash XOR type_hash
    hash = hash * FNV_PRIME

For each event type:
    type_hash = fnv1a(type_name)
    hash = hash XOR type_hash
    hash = hash * FNV_PRIME
```

This ensures that deserialization fails if component/resource/event types don't match.

## Entity Registry

Stores complete entity state including versioning and free list.

```
Offset | Size | Field                    | Type   | Description
-------|------|--------------------------|--------|---------------------------
0      | 2    | next_index               | u16    | Next entity index to allocate
2      | 2    | available                | u16    | Number of recycled entities
4      | 4    | next_index_to_recycle    | u32    | Next index in recycling queue
8      | N*4  | entities                 | u32[]  | Entity array (65535 entries)
```

Each entity value (u32) contains:
- **Bits 0-15**: Entity index
- **Bits 16-31**: Entity version

The entity array preserves the free list structure for exact state reproduction.

## Component Pools

Each component type has its own pool. The pool type (SparseSet vs TagStorage) is determined by whether the component is zero-sized.

### Component Metadata (per type)

```
Offset | Size | Field           | Type   | Description
-------|------|-----------------|--------|-------------------------------
0      | 2    | component_id    | u16    | Component type index (0-based)
2      | 8    | type_name_hash  | u64    | FNV-1a hash of component type name
```

### SparseSet (Regular Components)

Used for components with data (non-zero-sized structs).

```
Offset | Size | Field                    | Type   | Description
-------|------|--------------------------|--------|---------------------------
0      | 4    | group_size               | u32    | Number of entities in group
4      | 4    | dense_count              | u32    | Total entities with component
8      | 4    | allocated_page_count     | u32    | Number of allocated sparse pages
12     | N*2  | allocated_page_indices   | u16[]  | Indices of allocated pages
       | M*4  | sparse_pages             | ...    | Sparse page data (4096 slots each)
       | D*4  | packed_array             | u32[]  | Packed entity array
       | D*C  | components               | T[]    | Component data array
```

**Sparse Pages**: Only allocated pages are serialized. Each page contains 4096 optional u16 values (dense indices). Unallocated slots are represented as null.

**Component Data**: Serialized using either:
- **POD types**: Direct bytewise copy via `std.mem.asBytes()`
- **Custom types**: User-defined `Serializer.serialize()` / `deserialize()`

### TagStorage (Tag Components)

Used for zero-sized components (marker tags).

```
Offset | Size | Field                 | Type   | Description
-------|------|-----------------------|--------|---------------------------
0      | 8    | bitset_capacity       | u64    | Capacity of bit set (in bits)
8      | N    | bitset_data           | u8[]   | Bit set data (ceil(capacity/8) bytes)
       | 4    | entity_count          | u32    | Number of tagged entities
       | M*4  | packed_array          | u32[]  | Packed entity array
```

**Bit Set**: Stores 1 bit per entity index. Bit i is set if entity with index i has the tag.

## Resource Pools

Each resource type is serialized with its metadata and data.

```
Offset | Size | Field           | Type   | Description
-------|------|-----------------|--------|-------------------------------
0      | 2    | resource_id     | u16    | Resource type index (0-based)
2      | 8    | type_name_hash  | u64    | FNV-1a hash of resource type name
10     | 1    | is_initialized  | u8     | 0 = uninitialized, 1 = initialized
11     | N    | resource_data   | T      | Resource data (if initialized)
```

**Resource Data**: Serialized using the same approach as components (POD or custom serializer).

**Note**: Uninitialized resources return an error during deserialization (`error.UninitializedResource`).

## Event Pools

Only the **read buffer** is serialized (events from the previous frame). The write buffer is not included.

```
Offset | Size | Field           | Type   | Description
-------|------|-----------------|--------|-------------------------------
0      | 2    | event_id        | u16    | Event type index (0-based)
2      | 8    | type_name_hash  | u64    | FNV-1a hash of event type name
10     | 4    | read_count      | u32    | Number of events in read buffer
14     | N    | events          | T[]    | Event data array
```

**Event Data**: Serialized using the same approach as components (POD or custom serializer).

## CRC32 Checksum (Footer)

```
Offset | Size | Field    | Type | Description
-------|------|----------|------|--------------------------------------
0      | 4    | checksum | u32  | CRC32 of all data before this footer
```

The CRC32 is computed over the entire file **excluding the checksum footer itself**. This is achieved using a buffered checksum writer/reader that:
1. Computes CRC32 of all written/read data
2. Writes/reads the CRC32 value separately without including it in the checksum

Algorithm: CRC32 (IEEE 802.3)

## Serialization Process

1. **Create buffered checksum writer** (64KB buffer)
2. **Write header** with type metadata hash
3. **Write entity registry** (complete state)
4. **For each component type**:
   - Write component metadata
   - Dispatch to SparseSet or TagStorage serializer
5. **For each resource type**:
   - Write resource metadata
   - Write resource data (if initialized)
6. **For each event type**:
   - Write event metadata
   - Write read buffer events
7. **Finish and write CRC32 checksum**

## Deserialization Process

1. **Create buffered checksum reader** (64KB buffer)
2. **Read and validate header**:
   - Check magic number
   - Verify format version
   - Validate type metadata hash
3. **Read entity registry** (restore complete state)
4. **For each component type**:
   - Read component metadata and validate
   - Dispatch to SparseSet or TagStorage deserializer
5. **For each resource type**:
   - Read resource metadata and validate
   - Read resource data
6. **For each event type**:
   - Read event metadata and validate
   - Read and populate read buffer
7. **Read and validate CRC32 checksum**

**Error Handling**:
- `error.InvalidMagicNumber`: Not a valid SPZE file
- `error.UnsupportedFormatVersion`: Format version mismatch
- `error.TypeMismatch`: Component/resource/event types don't match
- `error.ComponentCountMismatch`: Different number of component types
- `error.ResourceCountMismatch`: Different number of resource types
- `error.EventCountMismatch`: Different number of event types
- `error.ChecksumMismatch`: File corruption detected
- `error.UninitializedResource`: Resource not initialized in save file

## POD Detection

**POD (Plain Old Data)** types are automatically detected at compile time:

**POD types**:
- Primitive types: `int`, `float`, `bool`, `enum`, `void`
- Arrays of POD types
- Structs where all fields are POD

**NOT POD**:
- Pointers
- Slices
- Optionals
- Unions
- Error unions
- Error sets

POD types use direct bytewise serialization (`std.mem.asBytes()`). Non-POD types require a custom `Serializer`.

## Custom Serializers

For non-POD types, define a `pub const Serializer` with these methods:

```zig
pub const Serializer = struct {
    pub fn serialize(value: T, writer: anytype) !void {
        // Write value to writer
    }

    pub fn deserialize(reader: anytype) !T {
        // Read and return value from reader
    }
};
```

**Example** (variable-length string):

```zig
const Name = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    pub const Serializer = struct {
        pub fn serialize(name: Name, writer: anytype) !void {
            try writer.writeInt(u16, @intCast(name.len), .little);
            try writer.writeAll(name.buffer[0..name.len]);
        }

        pub fn deserialize(reader: anytype) !Name {
            const len = try reader.readInt(u16, .little);
            var name = Name{};
            name.len = len;
            try reader.readNoEof(name.buffer[0..len]);
            return name;
        }
    };
};
```

## What Is NOT Serialized

- **Groups**: Must be recreated with `world.createGroup()` after deserialization
- **Command buffers**: Cleared (pending commands are not persisted)
- **Event write buffer**: Only read buffer is serialized

## Performance Characteristics

- **Serialization**: O(n) where n = number of entities × components
- **Deserialization**: O(n) with same characteristics
- **Memory**: Buffered I/O (64KB buffers) minimizes syscalls
- **Type validation**: O(1) hash comparison at load time
- **Sparse page optimization**: Only allocated pages serialized (not full 65535 array)

## Version History

### Version 1 (Current)
- Initial format specification
- FNV-1a type hashing
- CRC32 checksums
- Hybrid POD/custom serialization
- Entity versioning preservation
- Sparse page optimization
- Tag component support
- Resource serialization
- Event read buffer serialization

## Implementation

**Reference Implementation**: `src/serialization/` in the Sparze repository

**Key Modules**:
- `format.zig`: Header and hash computation
- `writer.zig`: Buffered checksum writer
- `reader.zig`: Buffered checksum reader
- `traits.zig`: POD detection and serializer traits
- `entity_registry.zig`: Entity registry serialization
- `sparse_set.zig`: SparseSet serialization
- `tag_storage.zig`: TagStorage serialization
- `world.zig`: High-level World orchestration

## Examples

See `examples/serialization.zig` and `examples/commands_serialization.zig` for complete usage examples.

## License

This format specification is part of the Sparze ECS library and is licensed under the MIT License.
