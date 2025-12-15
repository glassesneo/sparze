const stream = @import("world_stream.zig");
const file = @import("world_file.zig");

pub const serialize = stream.serialize;
pub const deserialize = stream.deserialize;
pub const serializeToFile = file.serializeToFile;
pub const deserializeFromFile = file.deserializeFromFile;
