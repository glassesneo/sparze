const std = @import("std");

const examples = [_]Example{
    .{ .name = "basic" },
    .{ .name = "plugin_architecture" },
    .{ .name = "system_operations" },
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

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
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
