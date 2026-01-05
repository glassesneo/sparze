const std = @import("std");

/// Check if Resource should be auto-initialized (default: true)
pub fn shouldAutoInit(comptime R: type) bool {
    if (@hasDecl(R, "auto_init")) {
        return R.auto_init;
    }
    return true;
}

/// Check if Resource has valid init(Allocator) R signature
pub fn hasInitMethod(comptime R: type) bool {
    if (!@hasDecl(R, "init")) return false;

    const init_fn = @TypeOf(R.init);
    const type_info = @typeInfo(init_fn);

    if (type_info != .@"fn") return false;
    const fn_info = type_info.@"fn";

    // Validate signature: fn(Allocator) R
    if (fn_info.params.len != 1) return false;

    const param_type = fn_info.params[0].type orelse return false;
    if (param_type != std.mem.Allocator) return false;

    const return_type = fn_info.return_type orelse return false;
    if (return_type != R) return false;

    return true;
}

/// Check if Resource has valid deinit(*R, Allocator) void signature
pub fn hasDeinitMethod(comptime R: type) bool {
    if (!@hasDecl(R, "deinit")) return false;

    const deinit_fn = @TypeOf(@field(R, "deinit"));
    const type_info = @typeInfo(deinit_fn);

    if (type_info != .@"fn") return false;
    const fn_info = type_info.@"fn";

    // Validate signature: fn(*R, Allocator) void
    if (fn_info.params.len != 2) return false;

    const self_type = fn_info.params[0].type orelse return false;
    if (self_type != *R) return false;

    const alloc_type = fn_info.params[1].type orelse return false;
    if (alloc_type != std.mem.Allocator) return false;

    const return_type = fn_info.return_type orelse return false;
    if (return_type != void) return false;

    return true;
}

/// Determine initialization strategy at compile time
pub fn getInitStrategy(comptime R: type) enum { custom_init, opt_out, zeroes } {
    if (!shouldAutoInit(R)) return .opt_out;
    if (hasInitMethod(R)) return .custom_init;
    return .zeroes;
}

/// Validate resource type at compile time. Returns error message or null if valid.
/// Rules:
/// - Resources with deinit() MUST have init() (deinit on zeroed memory is unsafe)
/// - Resources with deinit() but auto_init=false is allowed (manual init required)
pub fn validateResource(comptime R: type) ?[]const u8 {
    const has_deinit = hasDeinitMethod(R);
    const has_init = hasInitMethod(R);
    const auto_init = shouldAutoInit(R);

    // deinit without init AND auto_init=true means zeroed memory would be deinit'd
    if (has_deinit and !has_init and auto_init) {
        return "Resource '" ++ @typeName(R) ++ "' has deinit() but no init(). " ++
            "This is unsafe because deinit() would be called on zero-initialized memory. " ++
            "Either add an init(Allocator) method or set 'pub const auto_init = false'.";
    }

    return null;
}

// Unit Tests

test "shouldAutoInit - default true" {
    const Simple = struct { x: f32 };
    try std.testing.expect(shouldAutoInit(Simple));
}

test "shouldAutoInit - explicit false" {
    const Manual = struct {
        pub const auto_init = false;
    };
    try std.testing.expect(!shouldAutoInit(Manual));
}

test "shouldAutoInit - explicit true" {
    const Auto = struct {
        pub const auto_init = true;
    };
    try std.testing.expect(shouldAutoInit(Auto));
}

test "hasInitMethod - valid signature" {
    const Valid = struct {
        pub fn init(allocator: std.mem.Allocator) @This() {
            _ = allocator;
            return .{};
        }
    };
    try std.testing.expect(hasInitMethod(Valid));
}

test "hasInitMethod - no init method" {
    const NoInit = struct { x: u32 };
    try std.testing.expect(!hasInitMethod(NoInit));
}

test "hasInitMethod - wrong param count" {
    const NoParams = struct {
        pub fn init() @This() {
            return .{};
        }
    };
    const TwoParams = struct {
        pub fn init(_: std.mem.Allocator, _: u32) @This() {
            return .{};
        }
    };

    try std.testing.expect(!hasInitMethod(NoParams));
    try std.testing.expect(!hasInitMethod(TwoParams));
}

test "hasInitMethod - wrong param type" {
    const WrongParam = struct {
        pub fn init(_: u32) @This() {
            return .{};
        }
    };
    try std.testing.expect(!hasInitMethod(WrongParam));
}

test "hasInitMethod - wrong return type" {
    const WrongReturn = struct {
        pub fn init(_: std.mem.Allocator) u32 {
            return 0;
        }
    };
    try std.testing.expect(!hasInitMethod(WrongReturn));
}

test "hasDeinitMethod - valid signature" {
    const Valid = struct {
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    try std.testing.expect(hasDeinitMethod(Valid));
}

test "hasDeinitMethod - no deinit method" {
    const NoDeinit = struct { x: u32 };
    try std.testing.expect(!hasDeinitMethod(NoDeinit));
}

test "hasDeinitMethod - wrong param count" {
    const OneParam = struct {
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    try std.testing.expect(!hasDeinitMethod(OneParam));
}

test "hasDeinitMethod - wrong self param type" {
    const WrongSelf = struct {
        pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
    };
    try std.testing.expect(!hasDeinitMethod(WrongSelf));
}

test "hasDeinitMethod - wrong return type" {
    const WrongReturn = struct {
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) u32 {
            _ = self;
            _ = allocator;
            return 0;
        }
    };
    try std.testing.expect(!hasDeinitMethod(WrongReturn));
}

test "getInitStrategy - custom_init mode" {
    const Custom = struct {
        pub fn init(a: std.mem.Allocator) @This() {
            _ = a;
            return .{};
        }
    };
    try std.testing.expectEqual(.custom_init, getInitStrategy(Custom));
}

test "getInitStrategy - opt_out mode" {
    const OptOut = struct {
        pub const auto_init = false;
    };
    try std.testing.expectEqual(.opt_out, getInitStrategy(OptOut));
}

test "getInitStrategy - zeroes mode (POD)" {
    const POD = struct { x: f32, y: f32 };
    try std.testing.expectEqual(.zeroes, getInitStrategy(POD));
}

test "getInitStrategy - opt_out overrides init()" {
    const OptOutWithInit = struct {
        pub const auto_init = false;
        pub fn init(a: std.mem.Allocator) @This() {
            _ = a;
            return .{};
        }
    };
    try std.testing.expectEqual(.opt_out, getInitStrategy(OptOutWithInit));
}

test "validateResource - valid: init and deinit" {
    const Valid = struct {
        data: u32,
        pub fn init(a: std.mem.Allocator) @This() {
            _ = a;
            return .{ .data = 42 };
        }
        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            _ = self;
            _ = a;
        }
    };
    try std.testing.expectEqual(@as(?[]const u8, null), validateResource(Valid));
}

test "validateResource - valid: POD without deinit" {
    const POD = struct { x: f32, y: f32 };
    try std.testing.expectEqual(@as(?[]const u8, null), validateResource(POD));
}

test "validateResource - valid: deinit with auto_init=false (manual init)" {
    const ManualInit = struct {
        data: u32,
        pub const auto_init = false;
        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            _ = self;
            _ = a;
        }
    };
    try std.testing.expectEqual(@as(?[]const u8, null), validateResource(ManualInit));
}

test "validateResource - invalid: deinit without init (unsafe)" {
    const Unsafe = struct {
        data: u32,
        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            _ = self;
            _ = a;
        }
    };
    // Should return an error message
    try std.testing.expect(validateResource(Unsafe) != null);
}
