const std = @import("std");

const examples = [_]Example{
    .{ .name = "basic" },
    .{ .name = "combination_iterator" },
    .{ .name = "cross_product" },
    .{ .name = "events" },
    .{ .name = "exclude_example" },
    .{ .name = "plugin_architecture" },
    .{ .name = "system_operations" },
    .{ .name = "movement_example" },
    .{ .name = "multiple_groups" },
    .{ .name = "optional_components" },
    .{ .name = "performance_benchmark" },
    .{ .name = "tag_components" },
    .{ .name = "query_vs_group_benchmark" },
    .{ .name = "reserve_benchmark" },
    .{ .name = "resources" },
};

const Example = struct {
    name: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("sparze", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sparze",
        .root_module = lib_mod,
    });

    // Build examples
    buildExamples(b, .{
        .target = target,
        .optimize = optimize,
        .mod_sparze = lib_mod,
    });

    b.installArtifact(lib);

    // Creates a step for unit testing. This builds and runs the unit tests.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    // Expose a `test` step. If the target is wasm32-wasi, run with wasmtime.
    const test_step = b.step("test", "Run unit tests");
    if (target.result.cpu.arch.isWasm() and target.result.os.tag == .wasi) {
        const run_wasi = b.addSystemCommand(&.{"wasmtime"});
        run_wasi.addArtifactArg(lib_unit_tests);
        test_step.dependOn(&run_wasi.step);
    } else {
        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
        test_step.dependOn(&run_lib_unit_tests.step);
    }

    // Convenience: always provide a `test-wasm` step to build+run tests under WASI using wasmtime
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasm_mod = b.addModule("sparze-wasm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const wasm_tests = b.addTest(.{ .root_module = wasm_mod });
    const run_wasm_tests = b.addSystemCommand(&.{"wasmtime"});
    run_wasm_tests.addArtifactArg(wasm_tests);
    b.step("test-wasm", "Run unit tests (wasm32-wasi via wasmtime)").dependOn(&run_wasm_tests.step);
}

const ExampleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod_sparze: *std.Build.Module,
};

fn buildExamples(b: *std.Build, options: ExampleOptions) void {
    const examples_step = b.step("examples", "Build examples");
    const run_examples_step = b.step("run-examples", "Run all examples");

    for (examples) |example| {
        buildExample(b, example, options, examples_step, run_examples_step);
    }
}

fn buildExample(b: *std.Build, example: Example, options: ExampleOptions, examples_step: *std.Build.Step, run_examples_step: *std.Build.Step) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
        .target = options.target,
        .optimize = options.optimize,
    });
    mod.addImport("sparze", options.mod_sparze);

    const example_step = b.addExecutable(.{
        .name = example.name,
        .root_module = mod,
    });

    examples_step.dependOn(&b.addInstallArtifact(example_step, .{}).step);

    const run = b.addRunArtifact(example_step);
    run_examples_step.dependOn(&run.step);
    b.step(b.fmt("run-{s}", .{example.name}), b.fmt("Run {s} example", .{example.name})).dependOn(&run.step);
}
