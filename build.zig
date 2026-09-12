const std = @import("std");

fn linkSystemRoots(b: *std.Build, mod: *std.Build.Module, name: []const u8) void {
    const root = switch (b.graph.host.result.os.tag) {
        .macos => switch (b.graph.host.result.cpu.arch) {
            .aarch64 => b.fmt("/opt/homebrew/opt/{s}", .{name}),
            else => b.fmt("/usr/local/opt/{s}", .{name}),
        },
        else => null,
    };
    if (root) |r| {
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{r}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{r}) });
        mod.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{r}) });
    }
}

fn linkLinuxSearchPaths(b: *std.Build, mod: *std.Build.Module) void {
    if (b.graph.host.result.os.tag != .linux) return;
    const io = b.graph.io;
    for ([_][]const u8{
        "/usr/lib",
        "/lib",
        "/usr/lib/aarch64-linux-gnu",
        "/lib/aarch64-linux-gnu",
        "/usr/lib/x86_64-linux-gnu",
        "/lib/x86_64-linux-gnu",
    }) |dir| {
        std.Io.Dir.accessAbsolute(io, dir, .{}) catch continue;
        mod.addLibraryPath(.{ .cwd_relative = dir });
    }
    for ([_][]const u8{ "/usr/include" }) |dir| {
        std.Io.Dir.accessAbsolute(io, dir, .{}) catch continue;
        mod.addIncludePath(.{ .cwd_relative = dir });
    }
}

fn linkOpenSsl(b: *std.Build, mod: *std.Build.Module) void {
    linkLinuxSearchPaths(b, mod);
    mod.linkSystemLibrary("ssl", .{ .needed = true });
    mod.linkSystemLibrary("crypto", .{ .needed = true });
    linkSystemRoots(b, mod, "openssl");
}

fn configure(b: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;
    linkOpenSsl(b, mod);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zust_dep = b.dependency("zust", .{
        .target = target,
        .optimize = optimize,
    });
    const safe_module = zust_dep.module("safe");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "safe", .module = safe_module },
        },
    });
    configure(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "teknap",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run TekNap");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "safe", .module = safe_module },
        },
    });
    configure(b, test_mod);
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const analyzer = zust_dep.artifact("zust-analyze");
    const install_analyzer = b.addInstallArtifact(analyzer, .{});
    const analyzer_step = b.step("zust-analyze", "Build zust-analyze");
    analyzer_step.dependOn(&install_analyzer.step);

    const strictness = b.option([]const u8, "strictness", "zust-analyzer strictness: low|medium|high") orelse "low";
    const sarif = b.option(bool, "sarif", "zust-analyzer SARIF output") orelse false;

    const run_analyzer = b.addRunArtifact(analyzer);
    run_analyzer.addDirectoryArg(b.path("src"));
    run_analyzer.addArg(b.fmt("--strictness={s}", .{strictness}));
    if (sarif) run_analyzer.addArg("--sarif");
    run_analyzer.step.dependOn(&install_analyzer.step);

    const analyze_step = b.step("analyze", "Run zust-analyzer on src/");
    analyze_step.dependOn(&run_analyzer.step);
}
