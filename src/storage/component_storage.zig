const sparse_set_module = @import("sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;
const tag_storage_module = @import("tag_storage.zig");
const TagStorage = tag_storage_module.TagStorage;

pub fn isTagComponent(comptime C: type) bool {
    return @typeInfo(C).@"struct".fields.len == 0;
}

pub fn ComponentStorage(comptime C: type) type {
    return if (isTagComponent(C)) TagStorage(C) else SparseSet(C);
}
