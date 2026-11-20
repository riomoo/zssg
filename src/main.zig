// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! ZSSG — a Hugo-compatible static site generator written in Zig.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const tm = @import("time.zig");
const tmpl = @import("tmpl.zig");
const site = @import("site.zig");
const objs = @import("objs.zig");
const builder = @import("builder.zig");

const usage =
    \\zssg is a Hugo-compatible static site generator written in Zig.
    \\
    \\Usage:
    \\  zssg [flags]                 build the site (same as `zssg build`)
    \\  zssg build [flags]           build the site into the publish directory
    \\  zssg server [flags]          build, serve on http://localhost:1313 and rebuild on change
    \\  zssg new site <path>         create a new site skeleton
    \\  zssg new content <path>      create a new content file (e.g. posts/hello.md)
    \\  zssg version                 print version information
    \\
    \\Flags:
    \\  -s, --source <dir>          project root (default ".")
    \\  -d, --destination <dir>     output directory (default "public")
    \\  -b, --baseURL <url>         override baseURL
    \\  -t, --theme <name>          theme to use (in themes/)
    \\  -e, --environment <name>    build environment (default "production")
    \\  -D, --buildDrafts           include drafts
    \\  -F, --buildFuture           include content with a future publishDate
    \\  -E, --buildExpired          include expired content
    \\  -p, --port <n>              server port (default 1313)
    \\      --bind <addr>           server bind address (default 127.0.0.1)
    \\      --cleanDestinationDir   remove the destination directory before building
    \\      --quiet                 suppress warnings and the build summary
    \\  -h, --help                  show this help
    \\
;

fn newSite(path: []const u8) !void {
    if (sys.exists(v.pathJoin(&.{ path, "hugo.toml" }))) {
        sys.eprint("Error: {s} already contains a project\n", .{path});
        std.process.exit(1);
    }
    for ([_][]const u8{ "archetypes", "assets", "content", "data", "i18n", "layouts", "static", "themes" }) |d| sys.mkdirAll(v.pathJoin(&.{ path, d }));
    try sys.writeFile(v.pathJoin(&.{ path, "hugo.toml" }), "baseURL = 'https://example.org/'\nlanguageCode = 'en-us'\ntitle = 'My New ZSSG Site'\n");
    try sys.writeFile(v.pathJoin(&.{ path, "archetypes", "default.md" }), "+++\ndate = '{{ .Date }}'\ndraft = true\ntitle = '{{ replace .File.ContentBaseName \"-\" \" \" | title }}'\n+++\n");
    sys.print("Congratulations! Your new ZSSG site was created in {s}.\n\nJust a few more steps...\n\n1. Change the current directory to {s}.\n2. Create or install a theme (any Hugo theme works: put it in themes/ and set `theme` in hugo.toml).\n3. Add content with `zssg new content <SECTIONNAME>/<FILENAME>.md`.\n4. Build the site with `zssg`.\n", .{ path, path });
}

fn newContent(root: []const u8, rel: []const u8) !void {
    const dest = v.pathJoin(&.{ root, "content", rel });
    if (sys.exists(dest)) {
        sys.eprint("Error: {s} already exists\n", .{dest});
        std.process.exit(1);
    }
    var stem = v.pathStem(rel);
    if (v.eq(stem, "index") or v.eq(stem, "_index")) stem = v.pathBase(v.pathDir(rel));
    const title = @import("funcs.zig").titleCase(v.replaceAll(v.replaceAll(stem, "-", " "), "_", " "));
    const now = tm.format(.{ .sec = sys.nowSeconds() }, "2006-01-02T15:04:05Z07:00");
    try sys.writeFile(dest, v.fmt("+++\ndate = '{s}'\ndraft = true\ntitle = '{s}'\n+++\n", .{ now, title }));
    sys.print("Content \"{s}\" created\n", .{dest});
}

pub fn main(init: std.process.Init) !void {
    sys.A = init.arena.allocator();
    sys.main_A = sys.A;
    sys.io = init.io;
    sys.environ = init.environ_map;
    v.timeToStr = &tm.toString;
    v.objToStr = &objs.objStr;
    const args = try init.minimal.args.toSlice(sys.A);
    if (args.len > 1 and v.eq(args[1], "gen")) return genCmd(args);
    if (args.len > 3 and v.eq(args[1], "minify")) return minifyCmd(args);

    var opt: site.Options = .{};
    var port: u16 = 1313;
    var bind: []const u8 = "127.0.0.1";
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var a: []const u8 = args[i];
        var inline_val: ?[]const u8 = null;
        if (v.startsWith(a, "--")) if (v.indexOfChar(a, '=')) |e| {
            inline_val = a[e + 1 ..];
            a = a[0..e];
        };
        const Next = struct {
            fn get(argv: []const [:0]const u8, idx: *usize, iv: ?[]const u8, flag: []const u8) []const u8 {
                if (iv) |x| return x;
                idx.* += 1;
                if (idx.* >= argv.len) {
                    sys.eprint("Error: flag needs an argument: {s}\n", .{flag});
                    std.process.exit(1);
                }
                return argv[idx.*];
            }
        };
        if (v.eq(a, "-s") or v.eq(a, "--source")) opt.root = Next.get(args, &i, inline_val, a) else if (v.eq(a, "-d") or v.eq(a, "--destination")) opt.dest = Next.get(args, &i, inline_val, a) else if (v.eq(a, "-b") or v.eq(a, "--baseURL")) opt.base_url = Next.get(args, &i, inline_val, a) else if (v.eq(a, "-t") or v.eq(a, "--theme")) opt.theme = Next.get(args, &i, inline_val, a) else if (v.eq(a, "-e") or v.eq(a, "--environment")) {
            opt.env = Next.get(args, &i, inline_val, a);
            opt.env_set = true;
        } else if (v.eq(a, "-p") or v.eq(a, "--port")) {
            port = std.fmt.parseInt(u16, Next.get(args, &i, inline_val, a), 10) catch 1313;
        } else if (v.eq(a, "--bind")) {
            bind = Next.get(args, &i, inline_val, a);
        } else if (v.eq(a, "--serverPort")) {
            opt.port = std.fmt.parseInt(u16, Next.get(args, &i, inline_val, a), 10) catch 0;
            opt.server = true;
        } else if (v.eq(a, "-D") or v.eq(a, "--buildDrafts")) opt.drafts = true else if (v.eq(a, "-F") or v.eq(a, "--buildFuture")) opt.future = true else if (v.eq(a, "-E") or v.eq(a, "--buildExpired")) opt.expired = true else if (v.eq(a, "--cleanDestinationDir")) opt.clean = true else if (v.eq(a, "--quiet")) opt.quiet = true else if (v.eq(a, "--minify") or v.eq(a, "--gc") or v.eq(a, "--panicOnWarning") or v.eq(a, "--printPathWarnings") or v.eq(a, "--ignoreCache")) {
            if (v.eq(a, "--minify")) opt.minify = true;
        } else if (v.eq(a, "-h") or v.eq(a, "--help")) {
            sys.print("{s}", .{usage});
            return;
        } else if (v.startsWith(a, "-") and a.len > 1) {
            sys.eprint("Error: unknown flag: {s}\n\n{s}", .{ a, usage });
            std.process.exit(1);
        } else try pos.append(sys.A, a);
    }
    if (sys.getenv("HUGO_ENVIRONMENT") orelse sys.getenv("HUGO_ENV")) |e| {
        if (v.eq(opt.env, "production")) opt.env = e;
    }
    const cmd: []const u8 = if (pos.items.len > 0) pos.items[0] else "build";
    if (v.eq(cmd, "version")) {
        sys.print("zssg v{s} (Hugo v{s} template/theme compatible) zig {s}\n", .{ site.version, site.hugo_compat, @import("builtin").zig_version_string });
        return;
    }
    if (v.eq(cmd, "gen")) return genCmd(args);
    if (v.eq(cmd, "new")) {
        if (pos.items.len >= 3 and v.eq(pos.items[1], "site")) return newSite(pos.items[2]);
        if (pos.items.len >= 3 and v.eq(pos.items[1], "content")) return newContent(opt.root, pos.items[2]);
        if (pos.items.len == 2) return newContent(opt.root, pos.items[1]);
        sys.eprint("Error: usage: zssg new site <path> | zssg new content <path>\n", .{});
        std.process.exit(1);
    }
    if (v.eq(cmd, "server") or v.eq(cmd, "serve")) {
        @import("server.zig").serve(opt, bind, port) catch |e| {
            switch (e) {
                error.Fatal => sys.eprint("Error: {s}\n", .{site.fatal_msg}),
                else => sys.eprint("Error: {s}\n", .{@errorName(e)}),
            }
            std.process.exit(1);
        };
        return;
    }
    if (!v.eq(cmd, "build")) {
        sys.eprint("Error: unknown command \"{s}\"\n\n{s}", .{ cmd, usage });
        std.process.exit(1);
    }

    const t0 = sys.nowMillis();
    run(opt) catch |e| {
        switch (e) {
            error.Fatal => sys.eprint("Error: {s}\n", .{site.fatal_msg}),
            error.TemplateError => sys.eprint("Error: {s}\n", .{tmpl.err_msg}),
            else => sys.eprint("Error: {s}\n", .{@errorName(e)}),
        }
        std.process.exit(1);
    };
    var errors: usize = 0;
    for (site.all.items) |x| errors += x.errors;
    if (!opt.quiet) {
        // one column per language, like Hugo's build summary
        var out: v.Buf = .{};
        out.add("\n                  |");
        for (site.all.items, 0..) |x, k| out.print("{s} {s:<4}", .{ if (k > 0) " |" else "", v.upper(x.lang) });
        out.add("\n------------------+");
        for (site.all.items, 0..) |_, k| out.add(if (k > 0) "+------" else "------");
        out.add("\n");
        const Row = struct { name: []const u8, f: *const fn (*const site.Site) usize };
        const rows = [_]Row{
            .{ .name = "Pages", .f = struct {
                fn f(x: *const site.Site) usize {
                    return x.n_pages;
                }
            }.f },
            .{ .name = "Paginator pages", .f = struct {
                fn f(x: *const site.Site) usize {
                    return x.n_paginator;
                }
            }.f },
            .{ .name = "Static files", .f = struct {
                fn f(x: *const site.Site) usize {
                    return x.n_static;
                }
            }.f },
            .{ .name = "Processed assets", .f = struct {
                fn f(x: *const site.Site) usize {
                    return x.n_resources;
                }
            }.f },
            .{ .name = "Aliases", .f = struct {
                fn f(x: *const site.Site) usize {
                    return x.n_aliases;
                }
            }.f },
        };
        for (rows) |r| {
            out.print(" {s:<17}|", .{r.name});
            for (site.all.items, 0..) |x, k| out.print("{s} {d:<4}", .{ if (k > 0) " |" else "", r.f(x) });
            out.add("\n");
        }
        out.print("\nTotal in {d} ms\n", .{sys.nowMillis() - t0});
        sys.print("{s}", .{out.str()});
    }
    if (errors > 0) {
        sys.eprint("Error: build finished with {d} error(s)\n", .{errors});
        std.process.exit(1);
    }
}

fn run(opt: site.Options) !void {
    try site.load(opt);
    try builder.build();
}

/// Hidden helper: `zssg minify <mediatype> <file>` writes the minified file to stdout.
fn minifyCmd(args: []const [:0]const u8) !void {
    const min = @import("min.zig");
    const data = sys.readFile(args[3]) orelse return error.FileNotFound;
    var mt: []const u8 = args[2];
    var params: []const u8 = "";
    if (v.indexOfChar(mt, ';')) |k| {
        params = mt[k..];
        mt = mt[0..k];
    }
    if (min.isJsMime(mt)) {
        const opts = @import("min_js.zig").Options{ .escape_html = v.indexOf(params, "escape-html=1") != null, .inline_ = v.indexOf(params, "inline=1") != null };
        const out = @import("min_js.zig").minify(data, opts) catch {
            sys.eprint("ERR: JS minify failed\n", .{});
            std.process.exit(1);
        };
        sys.print("{s}", .{out});
        return;
    }
    if (v.eq(mt, "image/svg+xml")) {
        const out = @import("min_svg.zig").minifySvg(data, v.indexOf(params, "inline=1") != null) catch {
            sys.eprint("ERR: SVG minify failed\n", .{});
            std.process.exit(1);
        };
        sys.print("{s}", .{out});
        return;
    }
    if (min.minifyByMime(mt, data)) |out| sys.print("{s}", .{out}) else {
        sys.eprint("ERR: minify failed\n", .{});
        std.process.exit(1);
    }
}

fn genCmd(args: []const [:0]const u8) !void {
    var sub: []const u8 = "";
    var o = @import("chroma.zig").StylesCssOpts{ .style = "friendly" };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var a: []const u8 = args[i];
        var val: ?[]const u8 = null;
        if (v.startsWith(a, "--")) if (v.indexOfChar(a, '=')) |e| {
            val = a[e + 1 ..];
            a = a[0..e];
        };
        const takes = v.eq(a, "--style") or v.eq(a, "--mode") or v.eq(a, "--classDark") or v.eq(a, "--classLight") or v.eq(a, "--highlightStyle") or v.eq(a, "--lineNumbersInlineStyle") or v.eq(a, "--lineNumbersTableStyle");
        if (takes and val == null) {
            i += 1;
            val = if (i < args.len) args[i] else "";
        }
        if (v.eq(a, "--style")) o.style = v.lower(val.?) else if (v.eq(a, "--mode")) o.mode = val.? else if (v.eq(a, "--classDark")) o.class_dark = val.? else if (v.eq(a, "--classLight")) o.class_light = val.? else if (v.eq(a, "--highlightStyle")) o.highlight_style = val.? else if (v.eq(a, "--lineNumbersInlineStyle")) o.ln_inline_style = val.? else if (v.eq(a, "--lineNumbersTableStyle")) o.ln_table_style = val.? else if (v.eq(a, "--modeSelector")) o.mode_selector = true else if (v.eq(a, "--omitClassComments")) o.omit_comments = true else if (v.eq(a, "--omitEmpty")) {} else if (!v.startsWith(a, "-") and !v.eq(a, "gen")) sub = a;
    }
    if (!v.eq(sub, "chromastyles")) {
        sys.eprint("Usage: zssg gen chromastyles [--style=NAME] [--mode=light|dark] [--modeSelector] [--highlightStyle=..] [--lineNumbersInlineStyle=..] [--lineNumbersTableStyle=..] [--omitClassComments]\n", .{});
        std.process.exit(1);
    }
    const css = @import("chroma.zig").chromaStylesCss(o) catch |e| {
        sys.eprint("Error: {s}: {s}\n", .{ if (e == error.InvalidStyle) "invalid style" else "style does not have that mode", o.style });
        std.process.exit(1);
    };
    var joined: v.Buf = .{};
    for (args[1..], 0..) |a, k| {
        if (k > 0) joined.ch(' ');
        joined.add(a);
    }
    sys.print("/* Generated using: zssg {s} */\n\n{s}", .{ joined.str(), css });
}
