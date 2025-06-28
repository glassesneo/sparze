pub const Entity = struct {
    id: usize,
    pub fn init(id: usize) Entity {
        return Entity{ .id = id };
    }
};
