const std = @import("std");

const examples = [_]Example{
    .{ .name = "basic" },
};

const Example = struct {
    name: []const u8,
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sparze",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Build examples
    buildExamples(b, .{
        .target = target,
        .optimize = optimize,
        .mod_sparze = lib_mod,
    });

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
