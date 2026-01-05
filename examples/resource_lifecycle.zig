const std = @import("std");
const World = @import("sparze").World;

/// Example 1: Resource with custom init/deinit (auto-initialized)
/// This Resource has complex state (ArrayList) and provides init/deinit methods
const Cache = struct {
    data: std.ArrayList(u8),
    hit_count: u32,

    pub fn init(allocator: std.mem.Allocator) Cache {
        _ = allocator;
        std.debug.print("[Cache] Auto-initialized with init() method\n", .{});
        return .{
            .data = .{},
            .hit_count = 0,
        };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        std.debug.print("[Cache] Cleaning up {d} bytes of cached data\n", .{self.data.items.len});
        self.data.deinit(allocator);
    }
};

/// Example 2: Resource that opts out of auto-initialization
/// This Resource requires external setup (like hardware initialization)
const AudioEngine = struct {
    device_id: u32,
    sample_rate: u32,
    pub const auto_init = false; // Requires manual initialization
};

/// Example 3: Simple POD Resource (auto zero-initialized)
/// This Resource has no complex state and doesn't need init/deinit
const GameConfig = struct {
    gravity: f32,
    max_speed: f32,
    debug_mode: bool,
};

/// Example 4: Resource with init but no deinit
/// Demonstrates that deinit() is optional
const Logger = struct {
    level: enum { debug, info, warn, err },
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator) Logger {
        _ = allocator;
        const timestamp = std.time.milliTimestamp();
        std.debug.print("[Logger] Auto-initialized at timestamp {d}\n", .{timestamp});
        return .{
            .level = .info,
            .timestamp = timestamp,
        };
    }
};

// Define our World type with all example Resources
const ExampleWorld = World(
    .{}, // No components
    .{ Cache, AudioEngine, GameConfig, Logger }, // Resources
    .{}, // No events
    .{}, // No groups
);

pub fn main() !void {
    std.debug.print("\n=== Sparze Resource Lifecycle Example ===\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create World - Resources are initialized according to their strategy
    var world = ExampleWorld.init(allocator);
    defer world.deinit();

    std.debug.print("\n--- After World.init() ---\n\n", .{});

    // Check initialization status
    std.debug.print("Cache initialized? {}\n", .{world.isResourceInitialized(Cache)});
    std.debug.print("AudioEngine initialized? {}\n", .{world.isResourceInitialized(AudioEngine)});
    std.debug.print("GameConfig initialized? {}\n", .{world.isResourceInitialized(GameConfig)});
    std.debug.print("Logger initialized? {}\n\n", .{world.isResourceInitialized(Logger)});

    // Example 1: Use Cache (auto-initialized with init())
    {
        std.debug.print("--- Using Cache (auto-initialized) ---\n\n", .{});
        const cache = world.getResourcePtrMut(Cache);
        try cache.data.append(allocator, 'H');
        try cache.data.append(allocator, 'i');
        cache.hit_count += 1;
        std.debug.print("Cache contents: {s}\n", .{cache.data.items});
        std.debug.print("Cache hits: {d}\n\n", .{cache.hit_count});
    }

    // Example 2: Manually initialize AudioEngine (opt-out)
    {
        std.debug.print("--- Initializing AudioEngine (opt-out) ---\n\n", .{});
        std.debug.print("AudioEngine requires manual setup (e.g., hardware detection)\n", .{});
        const device_id: u32 = 42; // Simulated device detection
        world.setResource(AudioEngine, .{
            .device_id = device_id,
            .sample_rate = 48000,
        });
        std.debug.print("AudioEngine initialized with device {d} at {d}Hz\n\n", .{ device_id, 48000 });

        const audio = world.getResource(AudioEngine);
        std.debug.print("AudioEngine device_id: {d}\n", .{audio.device_id});
        std.debug.print("AudioEngine sample_rate: {d}\n\n", .{audio.sample_rate});
    }

    // Example 3: Use GameConfig (POD, zero-initialized)
    {
        std.debug.print("--- Using GameConfig (POD, zero-initialized) ---\n\n", .{});
        const config = world.getResource(GameConfig);
        std.debug.print("GameConfig gravity: {d}\n", .{config.gravity});
        std.debug.print("GameConfig max_speed: {d}\n", .{config.max_speed});
        std.debug.print("GameConfig debug_mode: {}\n\n", .{config.debug_mode});

        // Update config
        world.setResource(GameConfig, .{
            .gravity = 9.8,
            .max_speed = 100.0,
            .debug_mode = true,
        });
        const updated_config = world.getResource(GameConfig);
        std.debug.print("Updated GameConfig gravity: {d}\n", .{updated_config.gravity});
        std.debug.print("Updated GameConfig max_speed: {d}\n", .{updated_config.max_speed});
        std.debug.print("Updated GameConfig debug_mode: {}\n\n", .{updated_config.debug_mode});
    }

    // Example 4: Use Logger (auto-initialized, no deinit)
    {
        std.debug.print("--- Using Logger (auto-initialized, no deinit) ---\n\n", .{});
        const logger = world.getResource(Logger);
        std.debug.print("Logger level: {s}\n", .{@tagName(logger.level)});
        std.debug.print("Logger timestamp: {d}\n\n", .{logger.timestamp});
    }

    // Demonstrate bulk initialization with initResources()
    {
        std.debug.print("--- Bulk Initialization ---\n\n", .{});

        // Create new World to demonstrate initResources
        var world2 = ExampleWorld.init(allocator);
        defer world2.deinit();

        // Initialize multiple Resources at once
        try world2.initResources(.{
            .audio_engine = AudioEngine{ .device_id = 99, .sample_rate = 44100 },
            .game_config = GameConfig{ .gravity = 9.8, .max_speed = 200.0, .debug_mode = false },
        });

        std.debug.print("Bulk-initialized AudioEngine device: {d}\n", .{world2.getResource(AudioEngine).device_id});
        std.debug.print("Bulk-initialized GameConfig gravity: {d}\n\n", .{world2.getResource(GameConfig).gravity});
    }

    std.debug.print("--- World.deinit() called ---\n\n", .{});
    std.debug.print("Resources with deinit() methods will be cleaned up automatically\n\n", .{});
}
