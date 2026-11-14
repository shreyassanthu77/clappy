const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clappy = b.addModule("clappy", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/clappy.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "clappy-example",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "clappy", .module = clappy },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const check_step = b.step("check", "Check if the app compiles");
    check_step.dependOn(&exe.step);
}
