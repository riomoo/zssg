// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! js.Build / css.Build through esbuild (Hugo embeds esbuild v0.28.2 as a Go
//! library; ZSSG runs the esbuild npm package with Node.js and the same options
//! and resolver plugins, see esbuild_driver.js).
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const site = @import("site.zig");
const data = @import("data.zig");
const Value = v.Value;
const Map = v.Map;

const driver = @embedFile("esbuild_driver.js");

pub const OutFile = struct { path: []const u8, contents: []const u8 };
pub const Result = struct { main: []const u8, others: []OutFile };

pub const Error = error{ EsbuildFailed, Unavailable };
pub var last_error: []const u8 = "";

var missing = false;

fn optStr(o: ?*Map, key: []const u8) ?[]const u8 {
    const m = o orelse return null;
    const x = m.getCI(key) orelse return null;
    return switch (x) {
        .str => |s| s,
        .nil => null,
        else => v.toStr(x),
    };
}
fn optList(o: ?*Map, key: []const u8) ?[]Value {
    const m = o orelse return null;
    const x = m.getCI(key) orelse return null;
    return switch (x) {
        .list => |l| l.items.items,
        .str => |s| blk: {
            const one = sys.A.alloc(Value, 1) catch return null;
            one[0] = v.S(s);
            break :blk one;
        },
        else => null,
    };
}

fn jsonS(b: *v.Buf, s: []const u8) void {
    data.jsonStr(b, s, false);
}

pub fn assetsDirs() [][]const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    const adir = site.S.cfg.str("assetDir") orelse "assets";
    for (site.S.components) |comp| {
        const d = sys.absNoResolve(v.pathJoin(&.{ comp, adir }));
        l.append(sys.A, d) catch {};
    }
    return l.items;
}

/// Runs esbuild for resource content `contents` (source path `src_name`, media `media`).
pub fn build(contents: []const u8, src_name: []const u8, media: []const u8, opts: ?*Map, css_mode: bool, out_dir_rel: []const u8) Error!Result {
    if (missing) return error.Unavailable;
    const work = sys.absNoResolve(site.S.opt.root);
    const name = std.mem.trimStart(u8, src_name, "/");
    var source_dir = v.pathDir(name);
    if (source_dir.len == 0) source_dir = ".";

    const loader: []const u8 = if (v.eq(media, "text/javascript")) "js" else if (v.eq(media, "text/typescript")) "ts" else if (v.eq(media, "text/tsx")) "tsx" else if (v.eq(media, "text/jsx")) "jsx" else if (v.eq(media, "text/css")) "css" else {
        last_error = v.fmt("unsupported Media Type: \"{s}\"", .{media});
        return error.EsbuildFailed;
    };

    var b: v.Buf = .{};
    b.add("{\"contents\":");
    jsonS(&b, contents);
    b.add(",\"stdinLoader\":");
    jsonS(&b, loader);
    b.add(",\"stdinSourcePath\":");
    jsonS(&b, name);
    b.add(",\"sourceDir\":");
    jsonS(&b, source_dir);
    b.add(",\"resolveDir\":");
    jsonS(&b, work);
    b.add(",\"absWorkingDir\":");
    jsonS(&b, work);
    b.add(",\"outdir\":");
    jsonS(&b, sys.absNoResolve(site.S.dest));
    b.add(",\"isCSS\":");
    b.add(if (css_mode) "true" else "false");
    b.add(",\"assetsDirs\":[");
    for (assetsDirs(), 0..) |d, i| {
        if (i > 0) b.ch(',');
        jsonS(&b, d);
    }
    b.add("]");
    // params (Go's json.Marshal: sorted keys, HTML-escaped)
    b.add(",\"params\":");
    var pb: v.Buf = .{};
    if (opts) |o| if (o.getCI("params")) |p| data.toJson(&pb, p, .{}, 0) else pb.add("{}") else pb.add("{}");
    jsonS(&b, pb.str());
    if (opts) |o| if (o.getCI("vars")) |vars| {
        b.add(",\"vars\":");
        data.toJson(&b, vars, .{ .html_escape = false }, 0);
    };
    if (opts) |o| if (o.getCI("shims")) |sh| {
        b.add(",\"shims\":");
        data.toJson(&b, sh, .{ .html_escape = false }, 0);
    };
    b.add(",\"external\":[");
    if (optList(opts, "externals")) |ex| for (ex, 0..) |x, i| {
        if (i > 0) b.ch(',');
        jsonS(&b, v.toStr(x));
    };
    b.add("]");
    // loaders
    var loaders: v.Buf = .{};
    var nload: usize = 0;
    if (css_mode) {
        const css_loaders = [_][2][]const u8{ .{ ".css", "css" }, .{ ".png", "file" }, .{ ".jpg", "file" }, .{ ".jpeg", "file" }, .{ ".gif", "file" }, .{ ".svg", "file" }, .{ ".webp", "file" }, .{ ".avif", "file" }, .{ ".woff", "file" }, .{ ".woff2", "file" }, .{ ".ttf", "file" }, .{ ".eot", "file" }, .{ ".otf", "file" } };
        for (css_loaders) |cl| {
            if (opts) |o| if (o.map("loaders")) |lm| if (lm.getCI(cl[0]) != null) continue;
            if (nload > 0) loaders.ch(',');
            jsonS(&loaders, cl[0]);
            loaders.ch(':');
            jsonS(&loaders, cl[1]);
            nload += 1;
        }
    }
    if (opts) |o| if (o.getCI("loaders")) |lv| if (lv == .map) {
        const valid = [_][]const u8{ "none", "base64", "binary", "copy", "css", "dataurl", "default", "empty", "file", "global-css", "js", "json", "jsx", "local-css", "text", "ts", "tsx" };
        for (lv.map.m.keys(), lv.map.m.values()) |k, x| {
            const name_l = v.toStr(x);
            var ok = false;
            for (valid) |vv| if (v.eq(vv, name_l)) {
                ok = true;
            };
            if (!ok) {
                last_error = v.fmt("invalid loader: \"{s}\"", .{name_l});
                return error.EsbuildFailed;
            }
            if (nload > 0) loaders.ch(',');
            jsonS(&loaders, k);
            loaders.ch(':');
            jsonS(&loaders, if (v.eq(name_l, "copy")) "file" else name_l);
            nload += 1;
        }
    };
    if (nload > 0) {
        b.add(",\"loader\":{");
        b.add(loaders.str());
        b.ch('}');
    }

    // esbuild build options (Hugo's options.go compile())
    b.add(",\"options\":{");
    // target + engines
    const targets = [_][]const u8{ "esnext", "es5", "es6", "es2015", "es2016", "es2017", "es2018", "es2019", "es2020", "es2021", "es2022", "es2023", "es2024", "es2025" };
    const ranks = [_]u8{ 99, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var best: u8 = 0;
    var best_name: []const u8 = "esnext";
    var engines: std.ArrayList([]const u8) = .empty;
    var ntargets: usize = 0;
    if (optList(opts, "target")) |tl| for (tl) |tv| {
        ntargets += 1;
        const t = v.lower(v.toStr(tv));
        var found = false;
        for (targets, 0..) |tn, i| if (v.eq(tn, t)) {
            found = true;
            if (ranks[i] > best) {
                best = ranks[i];
                best_name = if (v.eq(tn, "es6")) "es2015" else tn;
            }
        };
        if (!found) {
            const engs = [_][]const u8{ "firefox", "chrome", "hermes", "safari", "opera", "rhino", "node", "edge", "deno", "ios", "ie" };
            for (engs) |e| if (v.startsWith(t, e)) {
                if (t.len == e.len) {
                    last_error = v.fmt("invalid engine version: \"{s}\"", .{t});
                    return error.EsbuildFailed;
                }
                engines.append(sys.A, t) catch {};
                break;
            };
        }
    };
    if (best == 0 and engines.items.len == 0 and ntargets > 0) {
        last_error = "unsupported target";
        return error.EsbuildFailed;
    }
    if (best == 0) best_name = "esnext";
    b.add("\"target\":[");
    jsonS(&b, best_name);
    for (engines.items) |e| {
        b.ch(',');
        jsonS(&b, e);
    }
    b.add("]");
    const format = v.lower(optStr(opts, "format") orelse "");
    b.add(",\"format\":");
    if (format.len == 0 or v.eq(format, "iife")) jsonS(&b, "iife") else if (v.eq(format, "esm")) jsonS(&b, "esm") else if (v.eq(format, "cjs")) jsonS(&b, "cjs") else {
        last_error = v.fmt("unsupported script output format: \"{s}\"", .{format});
        return error.EsbuildFailed;
    }
    const platform = optStr(opts, "platform") orelse "browser";
    b.add(",\"platform\":");
    jsonS(&b, if (platform.len == 0) "browser" else platform);
    const charset = optStr(opts, "charset") orelse "ascii";
    b.add(",\"charset\":");
    jsonS(&b, if (charset.len == 0) "ascii" else charset);
    if (optList(opts, "mainFields")) |mf| {
        b.add(",\"mainFields\":[");
        for (mf, 0..) |x, i| {
            if (i > 0) b.ch(',');
            jsonS(&b, v.toStr(x));
        }
        b.add("]");
    } else if (css_mode) b.add(",\"mainFields\":[\"style\",\"main\"]");
    const sm = optStr(opts, "sourceMap") orelse "";
    b.add(",\"sourcemap\":");
    if (v.eq(sm, "inline")) jsonS(&b, "inline") else if (v.eq(sm, "external")) jsonS(&b, "external") else if (v.eq(sm, "linked")) jsonS(&b, "linked") else b.add("false");
    var sources_content = true;
    if (opts) |o| if (o.getCI("sourcesContent")) |sc| {
        sources_content = v.truth(sc);
    };
    b.add(",\"sourcesContent\":");
    b.add(if (sources_content) "true" else "false");
    var minify = false;
    if (opts) |o| if (o.getCI("minify")) |mv| {
        minify = v.truth(mv) or v.eq(v.toStr(mv), "true");
    };
    const mb = if (minify) "true" else "false";
    b.print(",\"minifyWhitespace\":{s},\"minifyIdentifiers\":{s},\"minifySyntax\":{s}", .{ mb, mb, mb });
    if (css_mode) {
        b.add(",\"publicPath\":");
        var dir = out_dir_rel;
        if (v.eq(dir, ".") or v.eq(dir, "/")) dir = "";
        const pp = v.concat(&.{ "/", std.mem.trimStart(u8, v.pathClean(v.concat(&.{ site.S.base_path, "/", dir })), "/") });
        jsonS(&b, pp);
    }
    if (opts) |o| if (o.getCI("defines")) |dv| if (dv == .map) {
        b.add(",\"define\":{");
        for (dv.map.m.keys(), dv.map.m.values(), 0..) |k, x, i| {
            if (i > 0) b.ch(',');
            jsonS(&b, k);
            b.ch(':');
            jsonS(&b, v.toStr(x));
        }
        b.add("}");
    };
    if (optList(opts, "externals")) |ex| {
        b.add(",\"external\":[");
        for (ex, 0..) |x, i| {
            if (i > 0) b.ch(',');
            jsonS(&b, v.toStr(x));
        }
        b.add("]");
    }
    if (optStr(opts, "drop")) |d| if (d.len > 0) {
        if (!v.eq(d, "console") and !v.eq(d, "debugger")) {
            last_error = v.fmt("unsupported drop type: \"{s}\"", .{d});
            return error.EsbuildFailed;
        }
        b.add(",\"drop\":[");
        jsonS(&b, d);
        b.add("]");
    };
    if (optStr(opts, "jsxFactory")) |x| if (x.len > 0) {
        b.add(",\"jsxFactory\":");
        jsonS(&b, x);
    };
    if (optStr(opts, "jsxFragment")) |x| if (x.len > 0) {
        b.add(",\"jsxFragment\":");
        jsonS(&b, x);
    };
    const jsx = optStr(opts, "jsx") orelse "";
    b.add(",\"jsx\":");
    jsonS(&b, if (jsx.len == 0) "transform" else jsx);
    if (optStr(opts, "jsxImportSource")) |x| if (x.len > 0) {
        b.add(",\"jsxImportSource\":");
        jsonS(&b, x);
    };
    const tsconfig = v.pathJoin(&.{ work, "tsconfig.json" });
    if (sys.exists(tsconfig)) {
        b.add(",\"tsconfig\":");
        jsonS(&b, tsconfig);
    }
    if (optList(opts, "inject")) |inj| {
        b.add(",\"inject\":[");
        for (inj, 0..) |x, i| {
            const p = v.toStr(x);
            if (std.fs.path.isAbsolute(p)) {
                last_error = "inject: absolute paths not supported, must be relative to /assets";
                return error.EsbuildFailed;
            }
            const f = resolveComponent(p) orelse {
                last_error = v.fmt("inject: file \"{s}\" not found", .{p});
                return error.EsbuildFailed;
            };
            if (i > 0) b.ch(',');
            jsonS(&b, f);
        }
        b.add("]");
    }
    b.add("}}");

    const cfg_path = v.pathJoin(&.{ sys.tmpDir(), v.fmt("zssg-esbuild-{d}-{d}.json", .{ sys.pid(), sys.nowMillis() }) });
    sys.writeFile(cfg_path, b.str()) catch {
        last_error = "failed to write esbuild config";
        return error.EsbuildFailed;
    };
    defer sys.removeTree(cfg_path);
    const r = sys.run(&.{ "node", "-e", driver, cfg_path }) orelse {
        missing = true;
        return error.Unavailable;
    };
    const res = data.parseJson(r.stdout) catch {
        last_error = v.trimWs(if (r.stderr.len > 0) r.stderr else r.stdout);
        if (!r.ok) {
            missing = true;
            return error.Unavailable;
        }
        return error.EsbuildFailed;
    };
    if (res != .map) return error.EsbuildFailed;
    if (res.map.get("noesbuild") != null) {
        missing = true;
        return error.Unavailable;
    }
    if (res.map.get("error")) |e| {
        last_error = v.toStr(e);
        return error.EsbuildFailed;
    }
    var main: ?[]const u8 = null;
    var others: std.ArrayList(OutFile) = .empty;
    if (res.map.get("files")) |fl| if (fl == .list) for (fl.list.items.items) |f| {
        if (f != .map) continue;
        const p = f.map.str("path") orelse continue;
        const b64 = f.map.str("contents") orelse "";
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch 0;
        const buf = sys.A.alloc(u8, n) catch continue;
        dec.decode(buf, b64) catch continue;
        const base = std.fs.path.basename(p);
        if (v.startsWith(base, "stdin.") and !v.endsWith(base, ".map")) main = buf else others.append(sys.A, .{ .path = base, .contents = buf }) catch {};
    };
    return .{ .main = main orelse {
        last_error = "esbuild: entry point output not found";
        return error.EsbuildFailed;
    }, .others = others.items };
}

fn statAsset(rel: []const u8) ?struct { path: []const u8, dir: bool } {
    for (assetsDirs()) |d| {
        const p = v.pathJoin(&.{ d, rel });
        if (sys.kindOf(p) == .dir) return .{ .path = p, .dir = true };
        if (sys.exists(p)) return .{ .path = p, .dir = false };
    }
    return null;
}

/// Hugo's esbuild.ResolveComponent over the assets file system.
pub fn resolveComponent(imp: []const u8) ?[]const u8 {
    const exts = [_][]const u8{ ".js", ".ts", ".tsx", ".jsx" };
    const S = struct {
        fn findFirst(i: []const u8, base: []const u8) ?[]const u8 {
            for (exts) |e| {
                if (v.endsWith(i, e)) continue;
                if (statAsset(v.concat(&.{ base, e }))) |s| return s.path;
            }
            return null;
        }
    };
    if (S.findFirst(imp, imp)) |p| return p;
    const base = std.fs.path.basename(imp);
    if (v.eq(base, "index")) if (S.findFirst(imp, v.concat(&.{ imp, ".esm" }))) |p| return p;
    if (statAsset(imp)) |s| {
        if (!s.dir) return s.path;
        if (S.findFirst(imp, v.pathJoin(&.{ imp, "index" }))) |p| return p;
        if (S.findFirst(imp, v.pathJoin(&.{ imp, "index.esm" }))) |p| return p;
    }
    if (v.endsWith(base, ".js")) return S.findFirst(imp, imp[0 .. imp.len - 3]);
    return null;
}
