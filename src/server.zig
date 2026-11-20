// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! `zssg server`: builds the site, serves the output directory over HTTP, and
//! rebuilds (in a child process) when source files change. Pages get a tiny
//! live-reload script that polls the build stamp.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const site = @import("site.zig");
const objs = @import("objs.zig");

const net = std.Io.net;

var stamp: u64 = 0;
var last_check: i64 = 0;
var fingerprint: u64 = 0;

fn hashDir(h: *std.hash.Wyhash, dir: []const u8) void {
    for (sys.walk(dir)) |rel| {
        const st = sys.stat(v.pathJoin(&.{ dir, rel })) orelse continue;
        h.update(rel);
        h.update(std.mem.asBytes(&st.mtime));
        h.update(std.mem.asBytes(&st.size));
    }
}

fn sourceFingerprint(root: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ "content", "layouts", "static", "assets", "data", "i18n", "archetypes", "themes", "config" }) |d| hashDir(&h, v.pathJoin(&.{ root, d }));
    for ([_][]const u8{ "hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json", "config.toml", "config.yaml", "config.yml", "config.json" }) |f| {
        if (sys.stat(v.pathJoin(&.{ root, f }))) |st| {
            h.update(f);
            h.update(std.mem.asBytes(&st.mtime));
            h.update(std.mem.asBytes(&st.size));
        }
    }
    return h.final();
}

fn rebuild(exe: []const u8, opt: site.Options, port: u16) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(sys.A, &.{ exe, "build", "-s", opt.root, "-d", site.S.dest, "-e", opt.env, "--quiet", "--serverPort", v.fmt("{d}", .{port}) }) catch return false;
    if (opt.drafts) argv.append(sys.A, "-D") catch {};
    if (opt.future) argv.append(sys.A, "-F") catch {};
    if (opt.expired) argv.append(sys.A, "-E") catch {};
    if (opt.theme) |t| argv.appendSlice(sys.A, &.{ "-t", t }) catch {};
    const t0 = sys.nowMillis();
    const res = sys.run(argv.items) orelse {
        sys.eprint("Error: could not start the build process\n", .{});
        return false;
    };
    if (res.stderr.len > 0) sys.eprint("{s}", .{res.stderr});
    if (res.ok) sys.print("Built in {d} ms\n", .{sys.nowMillis() - t0}) else sys.eprint("Build failed; serving the last successful output\n", .{});
    stamp += 1;
    return res.ok;
}

fn contentType(path: []const u8) []const u8 {
    const mt = objs.mediaTypeOf(path);
    if (v.startsWith(mt, "text/") or v.eq(mt, "application/json") or v.eq(mt, "application/xml") or v.eq(mt, "image/svg+xml")) return v.concat(&.{ mt, "; charset=utf-8" });
    return mt;
}

const reload_script =
    \\<script>(function(){var s=null;setInterval(function(){fetch("/__zssg/stamp",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){if(s===null){s=t}else if(s!==t){location.reload()}}).catch(function(){})},1000)})();</script>
;

fn percentDecode(s: []const u8) []const u8 {
    if (v.indexOfChar(s, '%') == null) return s;
    var b: v.Buf = .{};
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len + 0 and i + 2 <= s.len - 1 + 1) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch null) |c| {
                b.ch(c);
                i += 2;
                continue;
            }
        }
        b.ch(s[i]);
    }
    return b.str();
}

fn respond(w: *std.Io.Writer, status: []const u8, ctype: []const u8, body: []const u8, head_only: bool) !void {
    try w.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len });
    if (!head_only) try w.writeAll(body);
    try w.flush();
}

fn handle(stream: net.Stream, exe: []const u8, opt: site.Options, port: u16) !void {
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = net.Stream.Reader.init(stream, sys.io, &rbuf);
    var writer = net.Stream.Writer.init(stream, sys.io, &wbuf);
    const r = &reader.interface;
    const w = &writer.interface;
    const line = v.dup(v.trimWs(r.takeDelimiterInclusive('\n') catch return));
    // drain headers
    while (true) {
        const h = r.takeDelimiterInclusive('\n') catch break;
        if (v.trimWs(h).len == 0) break;
    }
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return;
    var target = it.next() orelse return;
    const head_only = v.eq(method, "HEAD");
    if (!v.eq(method, "GET") and !head_only) return respond(w, "405 Method Not Allowed", "text/plain", "method not allowed\n", false);
    if (v.indexOfAny(target, "?#")) |q| target = target[0..q];
    const path = percentDecode(target);
    if (v.eq(path, "/__zssg/stamp")) return respond(w, "200 OK", "text/plain", v.fmt("{d}", .{stamp}), head_only);

    // rebuild when sources changed (checked at most twice a second)
    const now = sys.nowMillis();
    if (now - last_check > 500) {
        last_check = now;
        const fp = sourceFingerprint(opt.root);
        if (fp != fingerprint) {
            fingerprint = fp;
            sys.print("Change detected, rebuilding site\n", .{});
            _ = rebuild(exe, opt, port);
        }
    }

    if (v.contains(path, "..")) return respond(w, "400 Bad Request", "text/plain", "bad request\n", false);
    var rel = path;
    const bp = site.S.base_path;
    if (bp.len > 0) {
        if (v.eq(rel, bp)) {
            try w.print("HTTP/1.1 301 Moved Permanently\r\nLocation: {s}/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{bp});
            return w.flush();
        }
        if (v.startsWith(rel, bp) and rel.len > bp.len and rel[bp.len] == '/') rel = rel[bp.len..];
    }
    var file = v.pathJoin(&.{ site.S.dest, rel });
    if (sys.kindOf(file) == .dir) {
        if (!v.endsWith(path, "/")) {
            try w.print("HTTP/1.1 301 Moved Permanently\r\nLocation: {s}/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{path});
            return w.flush();
        }
        file = v.pathJoin(&.{ file, "index.html" });
    }
    var status: []const u8 = "200 OK";
    var body = sys.readFile(file);
    if (body == null) {
        status = "404 Not Found";
        file = v.pathJoin(&.{ site.S.dest, "404.html" });
        body = sys.readFile(file) orelse {
            return respond(w, status, "text/plain; charset=utf-8", "404 page not found\n", head_only);
        };
    }
    var out: []const u8 = body.?;
    const ctype = contentType(file);
    if (v.startsWith(ctype, "text/html")) {
        if (v.lastIndexOf(out, "</body>")) |b| out = v.concat(&.{ out[0..b], reload_script, out[b..] }) else out = v.concat(&.{ out, reload_script });
    }
    try respond(w, status, ctype, out, head_only);
}

pub fn serve(opt_in: site.Options, bind: []const u8, port: u16) !void {
    var opt = opt_in;
    opt.server = true;
    opt.port = port;
    if (v.eq(opt.env, "production") and !opt.env_set) opt.env = "development";
    const exe = try std.process.executablePathAlloc(sys.io, sys.A);
    // load once to learn the destination and base path
    try site.load(opt);
    fingerprint = sourceFingerprint(opt.root);
    if (!rebuild(exe, opt, port)) sys.eprint("Initial build failed; fix the errors above and save to rebuild\n", .{});
    const addr = try net.IpAddress.parse(bind, port);
    var srv = addr.listen(sys.io, .{ .reuse_address = true }) catch |e| {
        sys.eprint("Error: cannot listen on {s}:{d}: {s}\n", .{ bind, port, @errorName(e) });
        std.process.exit(1);
    };
    defer srv.deinit(sys.io);
    sys.print("Web Server is available at http://{s}:{d}{s}/ (bind address {s})\nPress Ctrl+C to stop\n", .{ if (v.eq(bind, "0.0.0.0")) "localhost" else bind, port, site.S.base_path, bind });
    while (true) {
        const stream = srv.accept(sys.io) catch |e| {
            sys.eprint("accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        handle(stream, exe, opt, port) catch {};
        stream.close(sys.io);
    }
}
