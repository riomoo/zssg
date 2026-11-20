// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
const std = @import("std");
const vendor = @import("avif_sources.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The embedded AVIF codec (libavif with dav1d, aom and libyuv, the versions
    // Hugo 0.170.0 embeds). -Davif=false builds a pure-Zig binary that uses
    // external tools for AVIF instead.
    const with_avif = b.option(bool, "avif", "Embed libavif (default: true)") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "avif", with_avif);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_options", options);
    const vendor_ok = !with_avif or vendorPresent(b);
    if (with_avif and vendor_ok) linkAvif(b, root, target);

    const exe = b.addExecutable(.{ .name = "zssg", .root_module = root });
    b.installArtifact(exe);
    if (!vendor_ok) {
        const fail = b.addFail("vendor/ is empty: the AVIF codecs live in the zssg-vendor submodule.\n" ++
            "Run `git submodule update --init` (or clone with --recursive), or build without them: zig build -Davif=false");
        b.getInstallStep().dependOn(&fail.step);
        exe.step.dependOn(&fail.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    // `b.args` exists in Zig 0.16; 0.17 forwards `--` arguments differently.
    if (@hasField(std.Build, "args")) {
        if (@field(b, "args")) |args| run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zssg");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);
    if (with_avif and vendor_ok) linkAvif(b, test_mod, target);
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// Whether the zssg-vendor submodule is checked out.
fn vendorPresent(b: *std.Build) bool {
    const io = b.graph.io;
    const rel = "vendor/libavif/include/avif/avif.h";
    if (@hasField(std.Build, "build_root")) {
        b.build_root.handle.access(io, rel, .{}) catch return false;
    } else {
        const root = @field(b, "root");
        const p = std.fs.path.join(b.allocator, &.{ root.sub_path, rel }) catch return false;
        root.root_dir.handle.access(io, p, .{}) catch return false;
    }
    return true;
}

/// Hugo compiles these libraries to WebAssembly with plain C code paths (no
/// SIMD-specific kernels, one thread). They are built the same way here, and
/// always optimised; floating point contraction is off as in WebAssembly, so
/// the encoder makes the same decisions.
fn cLib(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, cpp: bool) *std.Build.Step.Compile {
    const m = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true, .link_libcpp = if (cpp) true else null });
    return b.addLibrary(.{ .name = name, .linkage = .static, .root_module = m });
}

fn linkAvif(b: *std.Build, root: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const common = [_][]const u8{ "-DNDEBUG", "-ffp-contract=off", "-fno-sanitize=undefined", "-w" };

    // aom (encoder and decoder, generic C)
    const aom = cLib(b, "aom", target, false);
    aom.root_module.addIncludePath(b.path("vendor/aom"));
    aom.root_module.addCSourceFiles(.{ .root = b.path("vendor/aom"), .files = &vendor.aom, .flags = &(common ++ [_][]const u8{ "-std=c11", "-D_LARGEFILE_SOURCE", "-D_FILE_OFFSET_BITS=64" }) });

    // dav1d (decoder), 8- and 16-bit templates
    const dav1d = cLib(b, "dav1d", target, false);
    for ([_][]const u8{ "vendor/dav1d/config", "vendor/dav1d", "vendor/dav1d/src", "vendor/dav1d/include", "vendor/dav1d/include/dav1d" }) |p| dav1d.root_module.addIncludePath(b.path(p));
    const dflags = common ++ [_][]const u8{ "-std=c99", "-D_GNU_SOURCE", "-D_FILE_OFFSET_BITS=64", "-ffast-math", "-fomit-frame-pointer" };
    dav1d.root_module.addCSourceFiles(.{ .root = b.path("vendor/dav1d"), .files = &vendor.dav1d, .flags = &dflags });
    dav1d.root_module.addCSourceFiles(.{ .root = b.path("vendor/dav1d"), .files = &vendor.dav1d_tmpl, .flags = &(dflags ++ [_][]const u8{"-DBITDEPTH=8"}) });
    dav1d.root_module.addCSourceFiles(.{ .root = b.path("vendor/dav1d"), .files = &vendor.dav1d_tmpl, .flags = &(dflags ++ [_][]const u8{"-DBITDEPTH=16"}) });

    // libyuv (C paths only)
    const yuv = cLib(b, "yuv", target, true);
    yuv.root_module.addIncludePath(b.path("vendor/libyuv/include"));
    yuv.root_module.addCSourceFiles(.{ .root = b.path("vendor/libyuv"), .files = &vendor.libyuv, .flags = &(common ++ [_][]const u8{ "-std=c++17", "-DLIBYUV_DISABLE_X86", "-DLIBYUV_DISABLE_NEON", "-DLIBYUV_DISABLE_SVE", "-DLIBYUV_DISABLE_SME", "-DLIBYUV_DISABLE_LSX", "-DLIBYUV_DISABLE_LASX", "-DLIBYUV_DISABLE_RVV", "-DLIBYUV_DISABLE_MSA", "-DLIBYUV_DISABLE_MMI" }) });

    // libavif + ZSSG's bridge
    const avif = cLib(b, "avif", target, false);
    for ([_][]const u8{ "vendor/libavif/include", "vendor/aom", "vendor/dav1d/include", "vendor/libyuv/include" }) |p| avif.root_module.addIncludePath(b.path(p));
    const aflags = common ++ [_][]const u8{ "-std=c11", "-DAVIF_CODEC_AOM=1", "-DAVIF_CODEC_AOM_ENCODE=1", "-DAVIF_CODEC_AOM_DECODE=1", "-DAVIF_CODEC_DAV1D=1", "-DAVIF_LIBYUV_ENABLED=1" };
    avif.root_module.addCSourceFiles(.{ .root = b.path("vendor/libavif"), .files = &vendor.libavif, .flags = &aflags });
    avif.root_module.addCSourceFiles(.{ .root = b.path("src"), .files = &.{"avif_shim.c"}, .flags = &aflags });

    root.link_libc = true;
    root.link_libcpp = true;
    root.linkLibrary(avif);
    root.linkLibrary(aom);
    root.linkLibrary(dav1d);
    root.linkLibrary(yuv);
}
