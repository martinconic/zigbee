const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const secp = buildSecp256k1(b, target, optimize);

    const mod = b.addModule("zigbee", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zigbee",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigbee", .module = mod },
            },
        }),
    });

    linkSecp(exe, secp);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    linkSecp(mod_tests, secp);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    linkSecp(exe_tests, secp);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn buildSecp256k1(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "secp256k1",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.addIncludePath(b.path("vendor/secp256k1"));
    lib.addIncludePath(b.path("vendor/secp256k1/src"));
    lib.addIncludePath(b.path("vendor/secp256k1/include"));
    lib.addCSourceFiles(.{
        .files = &.{
            "vendor/secp256k1/src/secp256k1.c",
            "vendor/secp256k1/src/precomputed_ecmult.c",
            "vendor/secp256k1/src/precomputed_ecmult_gen.c",
        },
        .flags = &.{
            "-DENABLE_MODULE_RECOVERY=1",
            "-DECMULT_WINDOW_SIZE=15",
            "-DECMULT_GEN_PREC_BITS=4",
            "-Wno-unused-function",
        },
    });
    return lib;
}

fn linkSecp(step: *std.Build.Step.Compile, secp: *std.Build.Step.Compile) void {
    step.linkLibrary(secp);
    step.addIncludePath(secp.root_module.owner.path("vendor/secp256k1/include"));
}
