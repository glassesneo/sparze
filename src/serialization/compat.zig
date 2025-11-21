const std = @import("std");

/// Compatibility wrapper for reading integers that works with both old GenericReader and new std.Io.Reader
pub fn readInt(reader: anytype, comptime T: type, endian: std.builtin.Endian) !T {
    const ReaderType = if (@typeInfo(@TypeOf(reader)) == .pointer)
        std.meta.Child(@TypeOf(reader))
    else
        @TypeOf(reader);

    // New API: std.Io.Reader uses takeInt
    if (@hasDecl(ReaderType, "takeInt")) {
        return reader.takeInt(T, endian);
    }
    // Old API: GenericReader uses readInt
    else if (@hasDecl(ReaderType, "readInt")) {
        return reader.readInt(T, endian);
    }
    // Fallback: should not happen
    else {
        @compileError("Reader type " ++ @typeName(ReaderType) ++ " has neither takeInt nor readInt");
    }
}
