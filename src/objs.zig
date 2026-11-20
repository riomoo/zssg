// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Object model exposed to templates: Page, Site, Pager, Resource, Scratch,
//! shortcode contexts, taxonomies; plus content rendering (shortcodes, hooks).
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const data = @import("data.zig");
const tm = @import("time.zig");
const md = @import("markdown.zig");
const tmpl = @import("tmpl.zig");
const site = @import("site.zig");
const funcs = @import("funcs.zig");
const embedded = @import("embedded.zig");
const Value = v.Value;
const Map = v.Map;
const Page = site.Page;
const Resource = site.Resource;
const fail = tmpl.fail;

pub fn pagesVal(list: []const *Page) Value {
    const l = v.newList();
    for (list) |p| v.push(l, p.val());
    return v.L(l);
}

pub fn asPage(val: Value) ?*Page {
    if (val == .obj and val.obj.kind == .page) return @ptrCast(@alignCast(val.obj.ptr));
    return null;
}

pub fn linkTitle(p: *const Page) []const u8 {
    return p.param("linkTitle") orelse p.title;
}

pub fn objStr(o: v.Obj) []const u8 {
    return switch (o.kind) {
        .page => blk: {
            const pg_ = asPage(.{ .obj = o }).?;
            // Hugo prints a page as its absolute filename (or its path when it has no file)
            break :blk if (pg_.file_abs.len > 0) sys.absNoResolve(pg_.file_abs) else pg_.path;
        },
        .site => "Site",
        .resource => blk: {
            const r: *Resource = @ptrCast(@alignCast(o.ptr));
            break :blk r.name;
        },
        .term => blk: {
            const t: *site.Term = @ptrCast(@alignCast(o.ptr));
            break :blk t.name;
        },
        else => v.fmt("<{s}>", .{@tagName(o.kind)}),
    };
}

pub fn permalink(rel: []const u8) []const u8 {
    return v.concat(&.{ std.mem.trimEnd(u8, site.S.base_url, "/"), rel[site.S.base_path.len..] });
}

pub fn relUrl(u: []const u8) []const u8 {
    return v.concat(&.{ site.S.base_path, u });
}

pub fn absUrl(u: []const u8) []const u8 {
    return v.concat(&.{ std.mem.trimEnd(u8, site.S.base_url, "/"), u });
}

/// Site-relative url (no base path) of page `p` in output format `f`.
pub fn outUrl(p: *Page, f: *const site.OutputFormat) []const u8 {
    if (v.eq(f.name, "html")) return p.url;
    var dir = if (v.endsWith(p.url, "/")) p.url else v.concat(&.{ v.pathDir(p.url), "/" });
    if (v.eq(dir, "//")) dir = "/";
    if (f.path.len > 0) dir = v.concat(&.{ "/", f.path, dir });
    return v.fmt("{s}{s}.{s}", .{ dir, f.base, f.suffix });
}

pub fn mediaTypeOf(name: []const u8) []const u8 {
    const ext = v.lower(v.pathExt(name));
    const table = [_][2][]const u8{ .{ ".css", "text/css" }, .{ ".scss", "text/x-scss" }, .{ ".sass", "text/x-sass" }, .{ ".js", "text/javascript" }, .{ ".mjs", "text/javascript" }, .{ ".ts", "text/typescript" }, .{ ".tsx", "text/tsx" }, .{ ".jsx", "text/jsx" }, .{ ".json", "application/json" }, .{ ".html", "text/html" }, .{ ".htm", "text/html" }, .{ ".xml", "application/xml" }, .{ ".txt", "text/plain" }, .{ ".md", "text/markdown" }, .{ ".csv", "text/csv" }, .{ ".svg", "image/svg+xml" }, .{ ".png", "image/png" }, .{ ".jpg", "image/jpeg" }, .{ ".jpeg", "image/jpeg" }, .{ ".gif", "image/gif" }, .{ ".webp", "image/webp" }, .{ ".avif", "image/avif" }, .{ ".jxl", "image/jxl" }, .{ ".heic", "image/heic" }, .{ ".heif", "image/heif" }, .{ ".tif", "image/tiff" }, .{ ".apng", "image/apng" }, .{ ".ico", "image/x-icon" }, .{ ".bmp", "image/bmp" }, .{ ".tiff", "image/tiff" }, .{ ".pdf", "application/pdf" }, .{ ".woff", "font/woff" }, .{ ".woff2", "font/woff2" }, .{ ".ttf", "font/ttf" }, .{ ".otf", "font/otf" }, .{ ".mp4", "video/mp4" }, .{ ".webm", "video/webm" }, .{ ".mp3", "audio/mpeg" }, .{ ".ogg", "audio/ogg" }, .{ ".wav", "audio/wav" }, .{ ".toml", "application/toml" }, .{ ".yaml", "application/yaml" }, .{ ".yml", "application/yaml" }, .{ ".webmanifest", "application/manifest+json" }, .{ ".wasm", "application/wasm" }, .{ ".zip", "application/zip" } };
    for (table) |t| if (v.eq(t[0], ext)) return t[1];
    return "application/octet-stream";
}

pub fn mediaVal(mt: []const u8) Value {
    const m = v.newMap();
    m.put("Type", v.S(mt));
    const sl = v.indexOfChar(mt, '/') orelse mt.len;
    m.put("MainType", v.S(mt[0..sl]));
    var sub = if (sl < mt.len) mt[sl + 1 ..] else "";
    var suffix: []const u8 = "";
    if (v.indexOfChar(sub, '+')) |p| {
        suffix = sub[p + 1 ..];
        sub = sub[0..p];
    }
    m.put("SubType", v.S(sub));
    m.put("Suffix", v.S(suffix));
    m.put("__str", v.S(mt));
    return v.M(m);
}

// ================================================================ resources

pub fn resVal(r: *Resource) Value {
    return .{ .obj = .{ .kind = .resource, .ptr = r } };
}
pub fn asRes(val: Value) ?*Resource {
    if (val == .obj and val.obj.kind == .resource) return @ptrCast(@alignCast(val.obj.ptr));
    return null;
}

pub fn resContent(r: *Resource) []const u8 {
    if (r.job != null) @import("imgops.zig").waitFor(r);
    if (r.content) |c| return c;
    if (r.src_path) |p| {
        r.content = sys.readFile(p) orelse "";
        return r.content.?;
    }
    return "";
}

pub fn newResource(name: []const u8, content: ?[]const u8, src: ?[]const u8) *Resource {
    const r = sys.A.create(Resource) catch @panic("oom");
    const target = if (v.startsWith(name, "/")) name else v.concat(&.{ "/", name });
    r.* = .{ .name = target, .title = name, .content = content, .src_path = src, .target = target, .media = mediaTypeOf(name), .params = v.newMap() };
    return r;
}

pub fn publish(r: *Resource) void {
    if (r.published) return;
    r.published = true;
    const dest = v.pathJoin(&.{ site.S.dest, r.target });
    if (site.S.written.contains(dest)) return;
    site.S.written.put(sys.A, dest, {}) catch {};
    if (r.job != null and @import("imgops.zig").writeWhenDone(r, dest)) {
        site.S.n_resources += 1;
        return;
    }
    if (r.content == null and r.src_path != null) {
        sys.copyFile(r.src_path.?, dest) catch |e| site.warn("failed to publish {s}: {s}", .{ r.target, @errorName(e) });
    } else {
        sys.writeFile(dest, resContent(r)) catch |e| site.warn("failed to publish {s}: {s}", .{ r.target, @errorName(e) });
    }
    site.S.n_resources += 1;
}

fn be16(b: []const u8) i64 {
    return (@as(i64, b[0]) << 8) | b[1];
}
fn be32(b: []const u8) i64 {
    return (@as(i64, b[0]) << 24) | (@as(i64, b[1]) << 16) | (@as(i64, b[2]) << 8) | b[3];
}
fn le16(b: []const u8) i64 {
    return (@as(i64, b[1]) << 8) | b[0];
}
fn le24(b: []const u8) i64 {
    return (@as(i64, b[2]) << 16) | (@as(i64, b[1]) << 8) | b[0];
}

fn le32(b: []const u8) i64 {
    return (@as(i64, b[3]) << 24) | (@as(i64, b[2]) << 16) | (@as(i64, b[1]) << 8) | b[0];
}

/// Image dimensions, read from the file header when the content is not loaded.
pub fn imageDims(r: *Resource) void {
    if (r.width >= 0) return;
    if (r.content == null and r.job == null) if (r.src_path) |p| {
        if (sys.readFilePrefix(p, 128 * 1024)) |head| {
            imageDimsOf(r, head);
            if (r.width > 0) return;
            r.width = -1;
        }
    };
    imageDimsOf(r, resContent(r));
}

fn imageDimsOf(r: *Resource, c: []const u8) void {
    r.width = 0;
    r.height = 0;
    if (c.len > 24 and v.startsWith(c, "\x89PNG")) {
        r.width = be32(c[16..20]);
        r.height = be32(c[20..24]);
    } else if (c.len > 10 and v.startsWith(c, "GIF8")) {
        r.width = le16(c[6..8]);
        r.height = le16(c[8..10]);
    } else if (c.len > 30 and v.startsWith(c, "RIFF") and v.eq(c[8..12], "WEBP")) {
        if (v.eq(c[12..16], "VP8 ")) {
            r.width = le16(c[26..28]) & 0x3fff;
            r.height = le16(c[28..30]) & 0x3fff;
        } else if (v.eq(c[12..16], "VP8L")) {
            const bits: u32 = @intCast(le16(c[21..23]) | (le16(c[23..25]) << 16));
            r.width = (bits & 0x3fff) + 1;
            r.height = ((bits >> 14) & 0x3fff) + 1;
        } else if (v.eq(c[12..16], "VP8X")) {
            r.width = le24(c[24..27]) + 1;
            r.height = le24(c[27..30]) + 1;
        }
    } else if (@import("avif.zig").isAvif(c)) {
        if (@import("avif.zig").dims(c)) |d| {
            r.width = d.w;
            r.height = d.h;
        }
    } else if (c.len > 4 and c[0] == 0xFF and c[1] == 0xD8) {
        var i: usize = 2;
        while (i + 9 < c.len) {
            if (c[i] != 0xFF) {
                i += 1;
                continue;
            }
            const m = c[i + 1];
            if (m == 0xFF) {
                i += 1;
                continue;
            }
            if (m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC) {
                r.height = be16(c[i + 5 .. i + 7]);
                r.width = be16(c[i + 7 .. i + 9]);
                return;
            }
            if (m == 0xD8 or (m >= 0xD0 and m <= 0xD7) or m == 0x01) {
                i += 2;
                continue;
            }
            i += 2 + @as(usize, @intCast(be16(c[i + 2 .. i + 4])));
        }
    }
}

/// Image formats Hugo can decode and process.
pub fn isProcessableImage(r: *Resource) bool {
    const m = r.media;
    return v.eq(m, "image/jpeg") or v.eq(m, "image/png") or v.eq(m, "image/gif") or v.eq(m, "image/webp") or v.eq(m, "image/avif") or v.eq(m, "image/bmp") or v.eq(m, "image/tiff");
}

/// Number of animation frames (GIF, animated WebP); 1 for still images.
pub fn frameCount(c: []const u8) i64 {
    if (c.len > 13 and v.startsWith(c, "GIF8")) {
        var i: usize = 13;
        if (c[10] & 0x80 != 0) i += 3 * (@as(usize, 1) << @intCast((c[10] & 7) + 1));
        var n: i64 = 0;
        while (i < c.len) {
            switch (c[i]) {
                0x21 => {
                    i += 2;
                    while (i < c.len and c[i] != 0) i += @as(usize, c[i]) + 1;
                    i += 1;
                },
                0x2C => {
                    n += 1;
                    if (i + 10 > c.len) break;
                    const flags = c[i + 9];
                    i += 10;
                    if (flags & 0x80 != 0) i += 3 * (@as(usize, 1) << @intCast((flags & 7) + 1));
                    i += 1; // LZW min code size
                    while (i < c.len and c[i] != 0) i += @as(usize, c[i]) + 1;
                    i += 1;
                },
                else => break,
            }
        }
        return @max(n, 1);
    }
    if (c.len > 30 and v.startsWith(c, "RIFF") and v.eq(c[8..12], "WEBP") and v.eq(c[12..16], "VP8X")) {
        var n: i64 = 0;
        var i: usize = 12;
        while (i + 8 <= c.len) {
            const sz: usize = @intCast(le32(c[i + 4 .. i + 8]));
            if (v.eq(c[i .. i + 4], "ANMF")) n += 1;
            i += 8 + sz + (sz & 1);
        }
        return @max(n, 1);
    }
    return 1;
}

const RF = enum { RelPermalink, Permalink, Content, Name, Title, MediaType, ResourceType, Data, Width, Height, Params, Key, Publish, Resize, Fit, Fill, Crop, Process, Filter, Exif, Colors, Err, Value, FrameCount, Meta };

fn resField(r: *Resource, name: []const u8, args: []Value) anyerror!Value {
    const f = std.meta.stringToEnum(RF, name) orelse return fail("can't evaluate field {s} in type resource.Resource", .{name});
    switch (f) {
        .Width, .Height, .Resize, .Fit, .Fill, .Crop, .Process, .Filter, .Colors, .FrameCount, .Meta => if (v.startsWith(r.media, "image/") and !v.eq(r.media, "image/svg+xml") and !isProcessableImage(r)) {
            return fail("error calling {s}: resource \"{s}\" of media type \"{s}\" does not support this method: use reflect.IsImageResource, reflect.IsImageResourceProcessable, or reflect.IsImageResourceWithMeta to check if the resource supports this method before calling it", .{ name, r.name, r.media });
        },
        else => {},
    }
    switch (f) {
        .RelPermalink => {
            publish(r);
            return v.S(relUrl(r.target));
        },
        .Permalink => {
            publish(r);
            return v.S(absUrl(r.target));
        },
        .Publish => {
            publish(r);
            return v.S("");
        },
        .Content => {
            const c = resContent(r);
            if (v.eq(r.media, "text/html") or v.eq(r.media, "image/svg+xml")) return v.H(c);
            if (v.eq(r.media, "text/css")) return .{ .safe = .{ .kind = .css, .s = c } };
            if (v.eq(r.media, "text/javascript")) return .{ .safe = .{ .kind = .js, .s = c } };
            return v.S(c);
        },
        .Name => return v.S(r.name),
        .Title => return v.S(r.title),
        .Key => return v.S(r.target),
        .MediaType => return mediaVal(r.media),
        .ResourceType => {
            const sl = v.indexOfChar(r.media, '/') orelse r.media.len;
            return v.S(r.media[0..sl]);
        },
        .Data => {
            const m = r.data orelse v.newMap();
            m.put("Integrity", v.S(r.integrity));
            return v.M(m);
        },
        .Width => {
            imageDims(r);
            return v.I(r.width);
        },
        .Height => {
            imageDims(r);
            return v.I(r.height);
        },
        .Params => return v.M(r.params),
        .Resize, .Fit, .Fill, .Crop, .Process => {
            const imgops = @import("imgops.zig");
            if (v.eq(r.media, "image/svg+xml")) return fail("image processing is not supported for SVG: {s}", .{r.name});
            const spec = if (args.len > 0) v.toStr(args[0]) else "";
            const action = if (f == .Process) "" else v.lower(name);
            return resVal(try imgops.process(r, action, spec));
        },
        .Filter => return resVal(try @import("imgops.zig").applyFilters(r, args)),
        .Exif, .Err, .Value => return .nil,
        .FrameCount => {
            // only GIF and WebP can hold several frames: avoid loading other files
            if (r.content == null and r.job == null) if (r.src_path) |p| {
                const head = sys.readFilePrefix(p, 16) orelse "";
                if (!(v.startsWith(head, "GIF8") or v.startsWith(head, "RIFF"))) return v.I(1);
            };
            return v.I(frameCount(resContent(r)));
        },
        .Meta => {
            const m = v.newMap();
            m.put("Exif", v.M(v.newMap()));
            m.put("IPTC", v.M(v.newMap()));
            m.put("XMP", v.M(v.newMap()));
            m.put("Lat", .{ .float = 0 });
            m.put("Long", .{ .float = 0 });
            m.put("Orientation", v.I(1));
            m.put("Date", .{ .time = .{ .sec = -62135596800, .zero = true } });
            return v.M(m);
        },
        .Colors => return @import("imgops.zig").colors(r),
    }
}

/// Glob match supporting * ** ? and {a,b}.
pub fn glob(pat: []const u8, s: []const u8) bool {
    if (v.indexOfChar(pat, '{')) |o| {
        if (v.indexOfPos(pat, o, "}")) |c| {
            var it = std.mem.splitScalar(u8, pat[o + 1 .. c], ',');
            while (it.next()) |alt| {
                if (glob(v.concat(&.{ pat[0..o], alt, pat[c + 1 ..] }), s)) return true;
            }
            return false;
        }
    }
    return globRec(v.lower(pat), v.lower(s));
}
fn globRec(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (v.startsWith(p, "**")) {
        var rest = p[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        var i: usize = 0;
        while (i <= s.len) : (i += 1) if (globRec(rest, s[i..])) return true;
        return false;
    }
    if (p[0] == '*') {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (globRec(p[1..], s[i..])) return true;
            if (i >= s.len or s[i] == '/') return false;
        }
    }
    if (s.len == 0) return false;
    if (p[0] == '?' and s[0] != '/') return globRec(p[1..], s[1..]);
    if (p[0] == s[0]) return globRec(p[1..], s[1..]);
    return false;
}

fn pageResources(p: *Page) Value {
    const l = v.newList();
    for (p.resources.items) |r| {
        if (r.target.len == 0) {
            const dir = if (v.endsWith(p.url, "/")) p.url else v.concat(&.{ v.pathDir(p.url), "/" });
            r.target = v.concat(&.{ dir, if (r.path.len > 0) r.path else r.name });
        }
        v.push(l, resVal(r));
    }
    return v.L(l);
}

// ================================================================ scratch

const SF = enum { Get, Set, Add, SetInMap, DeleteInMap, Delete, Values, GetSortedMapValues };

fn scratchField(m: *Map, name: []const u8, args: []Value) anyerror!Value {
    const f = std.meta.stringToEnum(SF, name) orelse return fail("can't evaluate field {s} in type Scratch", .{name});
    const key = if (args.len > 0) v.toStr(args[0]) else "";
    switch (f) {
        .Get => return m.get(key) orelse .nil,
        .Set => {
            if (args.len < 2) return fail("Scratch.Set needs a key and a value", .{});
            m.put(v.dup(key), args[1]);
        },
        .Add => {
            if (args.len < 2) return fail("Scratch.Add needs a key and a value", .{});
            if (m.get(key)) |ex| {
                switch (ex) {
                    .list => |l| {
                        if (args[1] == .list) {
                            for (args[1].list.items.items) |x| v.push(l, x);
                        } else v.push(l, args[1]);
                    },
                    .str, .safe => m.put(key, v.S(v.concat(&.{ v.toStr(ex), v.toStr(args[1]) }))),
                    .int => |i| {
                        if (args[1] == .float) m.put(key, .{ .float = @as(f64, @floatFromInt(i)) + args[1].float }) else m.put(key, v.I(i + (v.toInt(args[1]) orelse 0)));
                    },
                    .float => |x| m.put(key, .{ .float = x + (v.toFloat(args[1]) orelse 0) }),
                    else => m.put(key, args[1]),
                }
            } else m.put(v.dup(key), args[1]);
        },
        .SetInMap => {
            if (args.len < 3) return fail("Scratch.SetInMap needs key, mapKey and value", .{});
            const inner = m.map(key) orelse blk: {
                const n = v.newMap();
                m.put(v.dup(key), v.M(n));
                break :blk n;
            };
            inner.put(v.dup(v.toStr(args[1])), args[2]);
        },
        .DeleteInMap => {
            if (args.len > 1) if (m.map(key)) |inner| inner.remove(v.toStr(args[1]));
        },
        .Delete => m.remove(key),
        .Values => return v.M(m),
        .GetSortedMapValues => {
            const l = v.newList();
            if (m.map(key)) |inner| for (v.sortedKeys(inner)) |k| v.push(l, inner.get(k).?);
            return v.L(l);
        },
    }
    return v.S("");
}

pub fn scratchVal(m: *Map) Value {
    return .{ .obj = .{ .kind = .scratch, .ptr = m } };
}

// ================================================================ content rendering

pub const Sc = struct {
    name: []const u8,
    pos: []Value = &.{},
    named: ?*Map = null,
    inner: []const u8 = "",
    page: *Page,
    parent: ?*Sc = null,
    ordinal: usize = 0,
    scratch: *Map,
    markup: bool = false,
    has_inner: bool = false,
    lazy_inner: ?[]const u8 = null,
};

const ScParse = struct {
    src: []const u8,
    page: *Page,
    /// top-level {{< >}} shortcodes, rendered lazily after Markdown (like Hugo)
    placeholders: std.ArrayList(*Sc) = .empty,
    ordinal: usize = 0,
    depth: usize = 0,
};

fn parseScArgs(s: []const u8, sc: *Sc) void {
    var pos: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
        if (i >= s.len) break;
        var key: ?[]const u8 = null;
        // key=
        var j = i;
        while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_' or s[j] == '-' or s[j] == '.')) j += 1;
        if (j < s.len and s[j] == '=' and j > i) {
            key = s[i..j];
            i = j + 1;
        }
        var val: []const u8 = "";
        var quoted = false;
        if (i < s.len and (s[i] == '"' or s[i] == '`')) {
            const q = s[i];
            var b: v.Buf = .{};
            i += 1;
            while (i < s.len and s[i] != q) : (i += 1) {
                if (q == '"' and s[i] == '\\' and i + 1 < s.len) {
                    i += 1;
                    b.ch(switch (s[i]) {
                        'n' => '\n',
                        't' => '\t',
                        else => s[i],
                    });
                } else b.ch(s[i]);
            }
            i += 1;
            val = b.str();
            quoted = true;
        } else {
            const st = i;
            while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n' and s[i] != '\r') i += 1;
            val = s[st..i];
        }
        var value: Value = v.S(val);
        if (!quoted) {
            if (std.fmt.parseInt(i64, val, 10) catch null) |n| value = v.I(n) else if (v.eq(val, "true")) value = v.B(true) else if (v.eq(val, "false")) value = v.B(false) else if (std.fmt.parseFloat(f64, val) catch null) |f| {
                if (v.indexOfChar(val, '.') != null) value = .{ .float = f };
            }
        }
        if (key) |k| {
            if (sc.named == null) sc.named = v.newMap();
            sc.named.?.put(k, value);
        } else pos.append(sys.A, value) catch {};
    }
    sc.pos = pos.items;
}

/// Finds the matching closing tag for shortcode `name` starting at `from`; returns [start,end) of the closing tag.
fn findClose(src: []const u8, from: usize, name: []const u8) ?[2]usize {
    var depth: usize = 0;
    var i = from;
    while (i + 3 < src.len) {
        const o = v.indexOfPos(src, i, "{{") orelse return null;
        if (o + 3 >= src.len) return null;
        const d = src[o + 2];
        if (d != '<' and d != '%') {
            i = o + 2;
            continue;
        }
        const close_delim: []const u8 = if (d == '<') ">}}" else "%}}";
        const e = v.indexOfPos(src, o + 3, close_delim) orelse return null;
        const body = v.trimWs(src[o + 3 .. e]);
        if (v.startsWith(body, "/*")) {
            i = e + 3;
            continue;
        }
        if (body.len > 0 and body[0] == '/') {
            const n = v.trimWs(body[1..]);
            if (v.eq(n, name)) {
                if (depth == 0) return .{ o, e + 3 };
                depth -= 1;
            }
        } else {
            var ne: usize = 0;
            while (ne < body.len and body[ne] != ' ' and body[ne] != '\t' and body[ne] != '\n' and body[ne] != '/') ne += 1;
            if (v.eq(body[0..ne], name) and !v.endsWith(body, "/")) {
                // only counts as nesting if it has its own close later; approximate by counting
                depth += 1;
            }
        }
        i = e + 3;
    }
    return null;
}

fn scTemplate(name: []const u8) anyerror!?*tmpl.Template {
    const cands = [_][]const u8{
        v.fmt("_shortcodes/{s}.html", .{name}),
        v.fmt("shortcodes/{s}.html", .{name}),
    };
    for (cands) |c| if (try site.getTemplate(c)) |t| return t;
    return embedded.shortcode(name);
}

fn countOpens(src: []const u8, name: []const u8) usize {
    _ = src;
    _ = name;
    return 0;
}

/// Replace shortcodes in `src`. `{{< >}}` output is swapped for placeholders (when top-level),
/// `{{% %}}` output is inlined so that it is rendered as Markdown.
fn expandShortcodes(st: *ScParse, src: []const u8, parent: ?*Sc, top: bool) anyerror![]const u8 {
    if (v.indexOf(src, "{{") == null) return src;
    var b: v.Buf = .{};
    var i: usize = 0;
    var local_ord: usize = 0;
    while (i < src.len) {
        const o = v.indexOfPos(src, i, "{{") orelse {
            b.add(src[i..]);
            break;
        };
        if (o + 3 >= src.len or (src[o + 2] != '<' and src[o + 2] != '%')) {
            b.add(src[i .. o + 2]);
            i = o + 2;
            continue;
        }
        const d = src[o + 2];
        const close_delim: []const u8 = if (d == '<') ">}}" else "%}}";
        const e = v.indexOfPos(src, o + 3, close_delim) orelse {
            b.add(src[i .. o + 2]);
            i = o + 2;
            continue;
        };
        b.add(src[i..o]);
        // escaped shortcode: {{</* ... */>}} (may span several shortcodes)
        if (v.startsWith(v.trimWs(src[o + 3 .. e]), "/*")) {
            const cs = v.indexOfPos(src, o + 3, "/*").?;
            var k = cs + 2;
            const found_end: ?usize = blk: while (v.indexOfPos(src, k, "*/")) |ce| {
                var q = ce + 2;
                while (q < src.len and (src[q] == ' ' or src[q] == '\t' or src[q] == '\n' or src[q] == '\r')) q += 1;
                if (v.startsWith(src[q..], close_delim)) break :blk ce;
                k = ce + 2;
            } else null;
            if (found_end) |ce| {
                var q = ce + 2;
                while (q < src.len and (src[q] == ' ' or src[q] == '\t' or src[q] == '\n' or src[q] == '\r')) q += 1;
                b.add("{{");
                b.ch(d);
                b.add(src[o + 3 .. cs]);
                b.add(src[cs + 2 .. ce]);
                b.add(src[ce + 2 .. q]);
                b.add(close_delim);
                i = q + 3;
                continue;
            }
        }
        var body = v.trimWs(src[o + 3 .. e]);
        if (v.startsWith(body, "/*") and v.endsWith(body, "*/")) {
            b.add("{{");
            b.ch(d);
            b.add(src[o + 3 .. e][0..(v.indexOf(src[o + 3 .. e], "/*").?)]);
            b.add(body[2 .. body.len - 2]);
            b.add(src[o + 3 .. e][(v.lastIndexOf(src[o + 3 .. e], "*/").? + 2)..]);
            b.add(close_delim);
            i = e + 3;
            continue;
        }
        if (body.len > 0 and body[0] == '/') {
            // stray closing tag
            i = e + 3;
            continue;
        }
        var self_closing = false;
        if (v.endsWith(body, "/")) {
            self_closing = true;
            body = v.trimWs(body[0 .. body.len - 1]);
        }
        var ne: usize = 0;
        while (ne < body.len and body[ne] != ' ' and body[ne] != '\t' and body[ne] != '\n') ne += 1;
        const name = body[0..ne];
        const sc = try sys.A.create(Sc);
        // zero-based ordinal relative to the parent (the page for top-level shortcodes)
        const ord = if (parent == null) st.ordinal else local_ord;
        sc.* = .{ .name = name, .page = st.page, .parent = parent, .ordinal = ord, .scratch = v.newMap(), .markup = d == '%' };
        if (parent == null) st.ordinal += 1 else local_ord += 1;
        parseScArgs(body[ne..], sc);
        i = e + 3;
        const lazy = d == '<' and top;
        if (!self_closing) {
            if (findClose(src, i, name)) |cl| {
                sc.has_inner = true;
                var inner = src[i..cl[0]];
                if (lazy) {
                    sc.lazy_inner = inner;
                    i = cl[1];
                    try st.placeholders.append(sys.A, sc);
                    b.print("HAHAHUGOSHORTCODE{d}HBHB", .{st.placeholders.items.len - 1});
                    try registerScName(st.page, name);
                    continue;
                }
                inner = try expandShortcodes(st, inner, sc, false);
                if (sc.markup and parent != null and !v.endsWith(st.page.file orelse "", ".html")) {
                    // nested {{% %}}: Hugo renders the inner content as Markdown
                    const r = try renderMarkdown(st.page, inner, false);
                    var ni = r.html;
                    if (v.indexOfChar(inner, '\n') == null and v.startsWith(ni, "<p>") and v.endsWith(ni, "</p>\n") and v.indexOfChar(ni[3 .. ni.len - 5], '\n') == null) ni = ni[3 .. ni.len - 5];
                    inner = ni;
                }
                sc.inner = inner;
                i = cl[1];
            }
        }
        try registerScName(st.page, name);
        if (lazy) {
            try st.placeholders.append(sys.A, sc);
            b.print("HAHAHUGOSHORTCODE{d}HBHB", .{st.placeholders.items.len - 1});
        } else b.add(try renderShortcode(sc));
    }
    return b.str();
}

fn registerScName(p: *Page, name: []const u8) !void {
    for (p.shortcodes.items) |n| if (v.eq(n, name)) return;
    try p.shortcodes.append(sys.A, name);
}

/// Renders a lazily parsed top-level shortcode (inner shortcodes first).
fn finishShortcode(st: *ScParse, sc: *Sc) anyerror![]const u8 {
    if (sc.lazy_inner) |raw| {
        sc.inner = try expandShortcodes(st, raw, sc, false);
        sc.lazy_inner = null;
    }
    return renderShortcode(sc);
}

fn renderShortcode(sc: *Sc) anyerror![]const u8 {
    // natively implemented shortcodes
    if (v.eq(sc.name, "ref") or v.eq(sc.name, "relref")) {
        const target = if (sc.pos.len > 0) v.toStr(sc.pos[0]) else if (sc.named) |n| (n.str("path") orelse "") else "";
        return refUrl(sc.page, target, v.eq(sc.name, "ref"));
    }
    if (v.eq(sc.name, "highlight") and (try site.getTemplate("_shortcodes/highlight.html")) == null and (try site.getTemplate("shortcodes/highlight.html")) == null) {
        const lang = if (sc.pos.len > 0) v.toStr(sc.pos[0]) else "";
        const opts: Value = if (sc.pos.len > 1) sc.pos[1] else v.S("");
        return @import("highlight.zig").highlight(std.mem.trim(u8, sc.inner, "\n"), lang, opts);
    }
    const t = (try scTemplate(sc.name)) orelse {
        site.errorf("\"{s}\": failed to extract shortcode: template for shortcode \"{s}\" not found", .{ sc.page.file orelse sc.page.path, sc.name });
        return "";
    };
    const dot: Value = .{ .obj = .{ .kind = .shortcode, .ptr = sc } };
    return tmpl.render(t, null, dot, sc.page.val(), false) catch |e| {
        if (e == error.TemplateError) return site.fatal("shortcode \"{s}\" in {s}: {s}", .{ sc.name, sc.page.file orelse sc.page.path, tmpl.err_msg });
        return e;
    };
}

pub fn refUrl(from: *Page, target: []const u8, absolute: bool) []const u8 {
    var frag: []const u8 = "";
    var t = target;
    if (v.indexOfChar(t, '#')) |h| {
        frag = t[h..];
        t = t[0..h];
    }
    const p = site.getPage(t, from) orelse {
        site.errorf("[{s}] REF_NOT_FOUND: Ref \"{s}\": \"{s}\": page not found", .{ site.S.lang, target, from.file orelse from.path });
        return "";
    };
    const u = if (absolute) absUrl(p.url) else relUrl(p.url);
    return v.concat(&.{ u, frag });
}

const SCF = enum { Get, Inner, InnerDeindent, Params, Page, Parent, Name, IsNamedParams, Ordinal, Site, Scratch, Store, Position, Ref, RelRef };

fn scField(sc: *Sc, name: []const u8, args: []Value) anyerror!Value {
    const f = std.meta.stringToEnum(SCF, name) orelse return fail("can't evaluate field {s} in type ShortcodeWithPage", .{name});
    switch (f) {
        .Get => {
            if (args.len == 0) return .nil;
            switch (args[0]) {
                .int => |i| {
                    if (i >= 0 and @as(usize, @intCast(i)) < sc.pos.len) return sc.pos[@intCast(i)];
                    return .nil;
                },
                else => {
                    if (sc.named) |n| return n.get(v.toStr(args[0])) orelse .nil;
                    return .nil;
                },
            }
        },
        .Inner => return v.H(sc.inner),
        .InnerDeindent => return v.H(sc.inner),
        .Params => {
            if (sc.named) |n| return v.M(n);
            return v.listOf(sc.pos);
        },
        .Page => return sc.page.val(),
        .Parent => return if (sc.parent) |p| .{ .obj = .{ .kind = .shortcode, .ptr = p } } else .nil,
        .Name => return v.S(sc.name),
        .IsNamedParams => return v.B(sc.named != null),
        .Ordinal => return v.I(sc.ordinal),
        .Site => return site.S.val(),
        .Scratch, .Store => return scratchVal(sc.scratch),
        .Position => return v.S(v.fmt("\"{s}\"", .{sc.page.file_abs})),
        .Ref, .RelRef => {
            const target = if (args.len > 0) v.toStr(args[0]) else "";
            return v.S(refUrl(sc.page, target, f == .Ref));
        },
    }
}

// ---- render hooks

fn hookTemplate(p: *Page, name: []const u8) anyerror!?*tmpl.Template {
    var cands: std.ArrayList([]const u8) = .empty;
    if (p.param("type")) |t| try cands.append(sys.A, v.fmt("{s}/_markup/{s}.html", .{ t, name }));
    if (p.section.len > 0) try cands.append(sys.A, v.fmt("{s}/_markup/{s}.html", .{ p.section, name }));
    try cands.append(sys.A, v.fmt("_markup/{s}.html", .{name}));
    try cands.append(sys.A, v.fmt("_default/_markup/{s}.html", .{name}));
    for (cands.items) |c| if (try site.getTemplate(c)) |t| return t;
    return null;
}

var hook_err: ?anyerror = null;

fn runHook(p: *Page, name: []const u8, ctx: *Map) ?[]const u8 {
    const t = (hookTemplate(p, name) catch |e| {
        hook_err = e;
        return null;
    }) orelse return null;
    ctx.put("Page", p.val());
    ctx.put("PageInner", p.val());
    return tmpl.render(t, null, v.M(ctx), p.val(), false) catch |e| {
        if (hook_err == null) {
            hook_err = e;
            if (e == error.TemplateError) site.fatal_msg = v.fmt("render hook {s}: {s}", .{ name, tmpl.err_msg });
        }
        return "";
    };
}

fn pg(ctx: *anyopaque) *Page {
    return @ptrCast(@alignCast(ctx));
}

fn hookLink(ctx: *anyopaque, dest: []const u8, title: []const u8, text: []const u8, plain: []const u8) ?[]const u8 {
    const m = v.newMap();
    m.put("Destination", v.S(dest));
    m.put("Title", v.S(title));
    m.put("Text", v.H(text));
    m.put("PlainText", v.S(plain));
    return runHook(pg(ctx), "render-link", m);
}
fn hookImage(ctx: *anyopaque, dest: []const u8, title: []const u8, alt: []const u8, is_block: bool) ?[]const u8 {
    const m = v.newMap();
    m.put("Destination", v.S(dest));
    m.put("Title", v.S(title));
    m.put("Text", v.H(v.htmlEscape(alt)));
    m.put("PlainText", v.S(alt));
    m.put("IsBlock", v.B(is_block));
    m.put("Ordinal", v.I(0));
    m.put("Attributes", v.M(v.newMap()));
    return runHook(pg(ctx), "render-image", m);
}
fn hookHeading(ctx: *anyopaque, level: u8, id: []const u8, text: []const u8, plain: []const u8, attrs: []const u8) ?[]const u8 {
    const m = v.newMap();
    m.put("Level", v.I(level));
    m.put("Anchor", v.S(id));
    m.put("Text", v.H(text));
    m.put("PlainText", v.S(plain));
    const am = v.newMap();
    am.put("id", v.S(id));
    var classes: v.Buf = .{};
    var it = std.mem.tokenizeAny(u8, attrs, " \t");
    while (it.next()) |tok| {
        if (tok[0] == '.') {
            if (classes.len() > 0) classes.ch(' ');
            classes.add(tok[1..]);
        } else if (v.indexOfChar(tok, '=')) |e| {
            const val = std.mem.trim(u8, tok[e + 1 ..], "\"'");
            const key = tok[0..e];
            if (v.eq(key, "class")) {
                if (classes.len() > 0) classes.ch(' ');
                classes.add(val);
            } else if (v.eq(val, "true")) am.put(key, v.B(true)) else if (v.eq(val, "false")) am.put(key, v.B(false)) else if (std.fmt.parseInt(i64, val, 10) catch null) |n| am.put(key, v.I(n)) else am.put(key, v.S(val));
        }
    }
    if (classes.len() > 0) am.put("class", v.S(classes.str()));
    m.put("Attributes", v.M(am));
    return runHook(pg(ctx), "render-heading", m);
}
fn hookCode(ctx: *anyopaque, lang: []const u8, code: []const u8, info: []const u8, ordinal: usize) ?[]const u8 {
    const p = pg(ctx);
    const hl = @import("highlight.zig");
    const m = v.newMap();
    m.put("Type", v.S(lang));
    m.put("Inner", v.S(std.mem.trimEnd(u8, code, "\r\n")));
    const am = v.newMap();
    const opts = v.newMap();
    if (hl.infoAttributes(info)) |a| {
        const parsed = hl.parseAttributes(a);
        for (parsed.attrs) |x| am.put(x.name, v.S(x.value));
        for (parsed.opts) |o| {
            if (o.ranges) |rs| {
                const l = v.newList();
                for (rs) |r| {
                    const pair = v.newList();
                    pair.items.append(sys.A, v.I(r[0])) catch {};
                    pair.items.append(sys.A, v.I(r[1])) catch {};
                    l.items.append(sys.A, .{ .list = pair }) catch {};
                }
                opts.put(v.lower(o.key), .{ .list = l });
            } else opts.put(v.lower(o.key), o.val);
        }
    }
    m.put("Attributes", v.M(am));
    m.put("Options", v.M(opts));
    m.put("Ordinal", v.I(ordinal));
    m.put("Position", v.S(p.file_abs));
    if (lang.len > 0) if (runHook(p, v.fmt("render-codeblock-{s}", .{lang}), m)) |r| return r;
    return runHook(p, "render-codeblock", m);
}
fn hookPass(ctx: *anyopaque, inner: []const u8, kind: []const u8, ordinal: usize) ?[]const u8 {
    const m = v.newMap();
    m.put("Inner", v.S(inner));
    m.put("Type", v.S(kind));
    m.put("Ordinal", v.I(@as(i64, @intCast(ordinal))));
    m.put("Attributes", v.M(v.newMap()));
    const p = pg(ctx);
    if (hookTemplate(p, v.concat(&.{ "render-passthrough-", kind })) catch null) |_| return runHook(p, v.concat(&.{ "render-passthrough-", kind }), m);
    return runHook(p, "render-passthrough", m);
}

fn hookQuote(ctx: *anyopaque, inner: []const u8, alert: []const u8, sign: []const u8, title: []const u8) ?[]const u8 {
    const m = v.newMap();
    m.put("Text", v.H(inner));
    m.put("Type", v.S(if (alert.len > 0) "alert" else "regular"));
    m.put("AlertType", v.S(alert));
    m.put("AlertTitle", v.H(title));
    m.put("AlertSign", v.S(sign));
    m.put("Attributes", v.M(v.newMap()));
    m.put("Ordinal", v.I(0));
    return runHook(pg(ctx), "render-blockquote", m);
}

fn passDelims(pt: *Map, key: []const u8) []const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    if (pt.map("delimiters")) |d| if (d.getCI(key)) |l| if (l == .list) for (l.list.items.items) |pair| {
        if (pair == .list and pair.list.items.items.len == 2) out.append(sys.A, .{ v.toStr(pair.list.items.items[0]), v.toStr(pair.list.items.items[1]) }) catch {};
    };
    return out.items;
}

pub fn mdOpts(p: *Page, hooks: *md.Hooks) md.Opts {
    hooks.* = .{ .ctx = p, .link = &hookLink, .image = &hookImage, .heading = &hookHeading, .codeblock = &hookCode, .blockquote = &hookQuote, .passthrough = &hookPass };
    var o: md.Opts = .{ .unsafe = site.S.unsafe_html, .hooks = hooks };
    if (site.S.cfg.map("markup")) |mk| if (mk.map("goldmark")) |g| {
        if (g.map("renderer")) |r| o.hard_wraps = r.boolean("hardWraps", false);
        if (g.map("extensions")) |x| {
            o.linkify = x.boolean("linkify", true);
            if (x.getCI("typographer")) |t| {
                if (t == .bool) o.typographer = t.bool else if (t == .map) o.typographer = !t.map.boolean("disable", false);
            }
            if (x.map("passthrough")) |pt| if (pt.boolean("enable", false)) {
                o.passthrough = .{ .block = passDelims(pt, "block"), .inline_ = passDelims(pt, "inline") };
            };
        }
        if (g.map("parser")) |ps| o.auto_ids = ps.boolean("autoHeadingID", true);
    };
    return o;
}

pub fn renderMarkdown(p: *Page, src: []const u8, inline_only: bool) anyerror!md.Result {
    var hooks: md.Hooks = undefined;
    var o = mdOpts(p, &hooks);
    o.inline_only = inline_only;
    hook_err = null;
    const r = md.render(src, o);
    if (hook_err) |e| return e;
    return r;
}

fn probablyHtmlToken(w: []const u8) bool {
    if (v.eq(w, ">")) return true;
    // ^</?[A-Za-z]+>?$
    if (w.len > 1 and w[0] == '<') {
        var k: usize = 1;
        if (w[k] == '/') k += 1;
        const st = k;
        while (k < w.len and std.ascii.isAlphabetic(w[k])) k += 1;
        if (k > st and (k == w.len or (k + 1 == w.len and w[k] == '>'))) return true;
    }
    // ^[A-Za-z]+=["']
    var k: usize = 0;
    while (k < w.len and std.ascii.isAlphabetic(w[k])) k += 1;
    if (k > 0 and k + 1 < w.len and w[k] == '=' and (w[k + 1] == '"' or w[k + 1] == '\'')) return true;
    return false;
}

/// Position after which every element opened in html[0..high] is closed.
fn balancedEnd(html: []const u8, high: usize) usize {
    const voids = [_][]const u8{ "br", "hr", "img", "input", "meta", "link", "source", "wbr", "col", "area", "embed", "track" };
    var depth: usize = 0;
    var i: usize = 0;
    while (i < html.len) {
        if (i >= high and depth == 0) return @max(i, high);
        const o = v.indexOfPos(html, i, "<") orelse break;
        if (o >= high and depth == 0) return high;
        if (v.startsWith(html[o..], "<!--")) {
            i = (v.indexOfPos(html, o, "-->") orelse break) + 3;
            continue;
        }
        const e = v.indexOfPos(html, o, ">") orelse break;
        const tag = html[o + 1 .. e];
        i = e + 1;
        if (tag.len == 0) continue;
        if (tag[0] == '/') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (!std.ascii.isAlphabetic(tag[0])) continue;
        var ne: usize = 0;
        while (ne < tag.len and std.ascii.isAlphanumeric(tag[ne])) ne += 1;
        const name = v.lower(tag[0..ne]);
        var is_void = v.endsWith(tag, "/");
        for (voids) |vd| if (v.eq(vd, name)) {
            is_void = true;
        };
        if (!is_void) depth += 1;
    }
    return if (depth == 0) @max(high, @min(i, html.len)) else html.len;
}

/// Port of Hugo's ExtractSummaryFromHTML: count words paragraph by paragraph,
/// stop at the </p> where the limit is reached, then extend to balanced HTML.
fn autoSummaryEnd(html: []const u8, limit: usize) usize {
    var count: usize = 0;
    var j: usize = 0;
    while (j < html.len) {
        const closing = v.indexOfPos(html, j, "</p>") orelse break;
        const s = html[j..closing];
        var wi: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const rl = @min(v.utf8Len(s[i]), s.len - i);
            const is_space = s[i] == ' ' or s[i] == '\n' or s[i] == '\t' or s[i] == '\r';
            if (is_space or i + rl == s.len) {
                const w = v.trimWs(s[wi..i]);
                if (w.len > 0 and !probablyHtmlToken(w)) count += 1;
                wi = i;
                if (count >= limit) break;
            }
            i += rl;
        }
        if (count >= limit) return balancedEnd(html, @min(closing + 4, html.len));
        j = closing + 3;
    }
    return html.len;
}

fn wordCount(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |_| n += 1;
    return n;
}

const divider = "ZSSGSUMMARYDIVIDERZSSG";

pub fn renderContent(p: *Page) anyerror!void {
    if (p.rendered) return;
    if (p.rendering) return; // recursive reference: content not available yet
    p.rendering = true;
    defer p.rendering = false;
    var src = p.raw;
    var manual_summary = false;
    for ([_][]const u8{ "<!--more-->", "<!-- more -->" }) |dv| {
        if (v.indexOf(src, dv)) |dpos| {
            manual_summary = true;
            src = v.concat(&.{ src[0..dpos], if (p.is_md) "\n\n" ++ divider ++ "\n\n" else divider, src[dpos + dv.len ..] });
            break;
        }
    }
    var st: ScParse = .{ .src = src, .page = p };
    const expanded = try expandShortcodes(&st, src, null, true);
    var html: []const u8 = undefined;
    if (p.is_md) {
        const r = try renderMarkdown(p, expanded, false);
        html = r.html;
        p.headings = r.headings;
        var start: i32 = 2;
        var end: i32 = 3;
        var ordered = false;
        if (site.S.cfg.map("markup")) |mk| if (mk.map("tableOfContents")) |tc| {
            start = @intCast(tc.int("startLevel", 2));
            end = @intCast(tc.int("endLevel", 3));
            ordered = tc.boolean("ordered", false);
        };
        p.toc = md.toc(r.headings, start, end, ordered);
    } else if (p.ext_markup.len > 0) {
        html = try funcs.renderExternal(p, expanded);
    } else html = expanded;
    // substitute shortcode placeholders
    if (st.placeholders.items.len > 0) {
        var b: v.Buf = .{};
        var i: usize = 0;
        while (i < html.len) {
            const o = v.indexOfPos(html, i, "HAHAHUGOSHORTCODE") orelse {
                b.add(html[i..]);
                break;
            };
            const e = v.indexOfPos(html, o, "HBHB") orelse {
                b.add(html[i..]);
                break;
            };
            const idx = std.fmt.parseInt(usize, html[o + 17 .. e], 10) catch 0;
            var pre = html[i..o];
            var next = e + 4;
            // unwrap <p>PLACEHOLDER</p>
            if (v.endsWith(pre, "<p>") and v.startsWith(html[next..], "</p>")) {
                pre = pre[0 .. pre.len - 3];
                next += 4;
            }
            b.add(pre);
            if (idx < st.placeholders.items.len) b.add(try finishShortcode(&st, st.placeholders.items[idx]));
            i = next;
        }
        html = b.str();
    }
    if (manual_summary) {
        const wrapped = "<p>" ++ divider ++ "</p>\n";
        if (v.indexOf(html, wrapped)) |d| {
            p.summary = std.mem.trimEnd(u8, html[0..d], "\n");
            html = v.concat(&.{ html[0..d], html[d + wrapped.len ..] });
            p.truncated = v.trimWs(html[d..]).len > 0;
        } else if (v.indexOf(html, divider)) |d| {
            p.summary = html[0..d];
            html = v.concat(&.{ html[0..d], html[d + divider.len ..] });
            p.truncated = v.trimWs(html[d..]).len > 0;
        }
    }
    if (manual_summary) html = std.mem.trimEnd(u8, html, "\n");
    p.content = html;
    if (p.param("summary")) |s| {
        const r = try renderMarkdown(p, s, false);
        p.summary = v.trimWs(r.html);
        p.truncated = true;
    } else if (!manual_summary) {
        // automatic summary: whole paragraphs until summaryLength words
        const limit: usize = @intCast(@max(site.S.summary_length, 1));
        const pos = autoSummaryEnd(html, limit);
        p.summary = v.trimWs(html[0..pos]);
        p.truncated = v.trimWs(html[pos..]).len > 0;
    }
    p.rendered = true;
}

fn plainOf(p: *Page) anyerror![]const u8 {
    if (p.plain) |x| return x;
    try renderContent(p);
    const s = v.stripTags(p.content);
    p.plain = s;
    return s;
}

// ================================================================ pagination

fn pagerSize() usize {
    if (site.S.cfg.map("pagination")) |pm| return @intCast(@max(pm.int("pagerSize", 10), 1));
    return @intCast(@max(site.S.cfg.int("paginate", 10), 1));
}

pub fn pagerPath() []const u8 {
    if (site.S.cfg.map("pagination")) |pm| if (pm.str("path")) |x| return x;
    return site.S.cfg.str("paginatePath") orelse "page";
}

pub fn pagerUrl(pgr: *const site.Pager) []const u8 {
    if (pgr.number == 1) return pgr.page.url;
    return v.fmt("{s}{s}/{d}/", .{ pgr.page.url, pagerPath(), pgr.number });
}

fn makePagers(p: *Page, items: []Value, size: usize) anyerror!void {
    const total = @max((items.len + size - 1) / size, 1);
    const list = try sys.A.alloc(*site.Pager, total);
    for (list, 0..) |*slot, i| {
        const pgr = try sys.A.create(site.Pager);
        const lo = @min(i * size, items.len);
        const hi = @min(lo + size, items.len);
        pgr.* = .{ .page = p, .items = items[lo..hi], .number = i + 1, .total = total, .size = size, .all = items.len, .siblings = list };
        slot.* = pgr;
    }
    p.pagers = list;
}

fn pagerVal(pgr: *site.Pager) Value {
    return .{ .obj = .{ .kind = .pager, .ptr = pgr } };
}

fn currentPager(p: *Page) Value {
    return pagerVal(p.pagers[@min(p.cur_pager, p.pagers.len - 1)]);
}

const PGF = enum { Pages, PageNumber, TotalPages, HasNext, HasPrev, Next, Prev, First, Last, URL, Pagers, PagerSize, PageSize, TotalNumberOfElements, NumberOfElements, PageGroups };

fn pagerField(pgr: *site.Pager, name: []const u8) anyerror!Value {
    const f = std.meta.stringToEnum(PGF, name) orelse return fail("can't evaluate field {s} in type *page.Pager", .{name});
    return switch (f) {
        .Pages => v.listOf(pgr.items),
        .PageNumber => v.I(pgr.number),
        .TotalPages => v.I(pgr.total),
        .HasNext => v.B(pgr.number < pgr.total),
        .HasPrev => v.B(pgr.number > 1),
        .Next => if (pgr.number < pgr.total) pagerVal(pgr.siblings[pgr.number]) else .nil,
        .Prev => if (pgr.number > 1) pagerVal(pgr.siblings[pgr.number - 2]) else .nil,
        .First => pagerVal(pgr.siblings[0]),
        .Last => pagerVal(pgr.siblings[pgr.siblings.len - 1]),
        .URL => v.S(relUrl(pagerUrl(pgr))),
        .Pagers => blk: {
            const l = v.newList();
            for (pgr.siblings) |s| v.push(l, pagerVal(s));
            break :blk v.L(l);
        },
        .PagerSize, .PageSize => v.I(pgr.size),
        .TotalNumberOfElements => v.I(pgr.all),
        .NumberOfElements => v.I(pgr.items.len),
        .PageGroups => v.L(v.newList()),
    };
}

// ================================================================ pages collections

pub fn listPagesOf(p: *Page) []*Page {
    if (p.kind == .term) return if (p.term) |t| t.pages.items else &.{};
    if (p.kind == .taxonomy) {
        var out: std.ArrayList(*Page) = .empty;
        if (p.tax) |t| for (t.terms.values()) |term| if (term.page) |tp| out.append(sys.A, tp) catch {};
        site.sortPages(out.items);
        return out.items;
    }
    var out: std.ArrayList(*Page) = .empty;
    for (p.children.items) |c| if (c.list) out.append(sys.A, c) catch {};
    return out.items;
}

fn regularOf(p: *Page, recursive: bool, out: *std.ArrayList(*Page)) void {
    if (p.kind == .term) {
        for (listPagesOf(p)) |c| if (c.kind == .page) out.append(sys.A, c) catch {};
        return;
    }
    for (p.children.items) |c| {
        if (c.kind == .page) {
            if (c.list) out.append(sys.A, c) catch {};
        } else if (recursive) regularOf(c, true, out);
    }
}

const SortKey = enum { date, title, weight, lastmod, publish, expiry, length, linktitle, param };

const SortCtx = struct { key: SortKey, param: []const u8 = "" };

fn pageKeyLess(c: SortCtx, a: Value, b: Value) bool {
    const pa = asPage(a) orelse return false;
    const pb = asPage(b) orelse return false;
    return switch (c.key) {
        .date => pa.date.sec < pb.date.sec,
        .lastmod => pa.lastmod.sec < pb.lastmod.sec,
        .publish => pa.publish.sec < pb.publish.sec,
        .expiry => pa.expiry.sec < pb.expiry.sec,
        .title => std.ascii.orderIgnoreCase(pa.title, pb.title) == .lt,
        .linktitle => std.ascii.orderIgnoreCase(linkTitle(pa), linkTitle(pb)) == .lt,
        .weight => site.pageLess({}, pa, pb),
        .length => pa.raw.len < pb.raw.len,
        .param => blk: {
            const x = paramLookup(pa, c.param);
            const y = paramLookup(pb, c.param);
            if (x == .nil) break :blk false;
            if (y == .nil) break :blk true;
            break :blk v.cmp(x, y) == .lt;
        },
    };
}

pub fn paramLookup(p: *Page, key: []const u8) Value {
    const k = v.lower(key);
    if (lookupPath(p.params, k)) |x| return x;
    if (lookupPath(site.S.params, k)) |x| return x;
    return .nil;
}

fn lookupPath(m: *Map, key: []const u8) ?Value {
    if (m.getCI(key)) |x| return x;
    if (v.indexOfChar(key, '.')) |d| {
        if (m.map(key[0..d])) |sub| return lookupPath(sub, key[d + 1 ..]);
    }
    return null;
}

fn isPageList(l: *v.List) bool {
    if (l.items.items.len == 0) return true;
    return asPage(l.items.items[0]) != null;
}

fn groupVal(key: Value, pages: *v.List) Value {
    const m = v.newMap();
    m.put("Key", key);
    m.put("Pages", v.L(pages));
    return v.M(m);
}

fn groupBy(l: *v.List, mode: enum { date, publish, lastmod, expiry, field, param }, arg: []const u8, desc: bool) anyerror!Value {
    const groups = v.newList();
    var keys: std.ArrayList([]const u8) = .empty;
    for (l.items.items) |pv| {
        const p = asPage(pv) orelse continue;
        var key: Value = .nil;
        switch (mode) {
            .date => key = v.S(tm.format(p.date, arg)),
            .publish => key = v.S(tm.format(p.publish, arg)),
            .lastmod => key = v.S(tm.format(p.lastmod, arg)),
            .expiry => key = v.S(tm.format(p.expiry, arg)),
            .field => key = try pageField(null, p, arg, &.{}),
            .param => {
                key = paramLookup(p, arg);
                if (key == .nil) continue;
            },
        }
        const ks = v.toStr(key);
        var gi: ?usize = null;
        for (keys.items, 0..) |k, i| if (v.eq(k, ks)) {
            gi = i;
        };
        if (gi == null) {
            try keys.append(sys.A, ks);
            v.push(groups, groupVal(key, v.newList()));
            gi = keys.items.len - 1;
        }
        v.push(groups.items.items[gi.?].map.list("Pages").?, pv);
    }
    if (mode == .field or mode == .param) {
        const Ctx = struct {
            desc: bool,
            fn less(c: @This(), a: Value, b: Value) bool {
                const o = v.cmp(a.map.get("Key").?, b.map.get("Key").?);
                return if (c.desc) o == .gt else o == .lt;
            }
        };
        std.mem.sort(Value, groups.items.items, Ctx{ .desc = desc }, Ctx.less);
    } else {
        // date groups: order by the date of the first page in each group
        const Ctx = struct {
            desc: bool,
            fn less(c: @This(), a: Value, b: Value) bool {
                const pa = asPage(a.map.list("Pages").?.items.items[0]).?;
                const pb = asPage(b.map.list("Pages").?.items.items[0]).?;
                return if (c.desc) pa.date.sec > pb.date.sec else pa.date.sec < pb.date.sec;
            }
        };
        std.mem.sort(Value, groups.items.items, Ctx{ .desc = desc }, Ctx.less);
    }
    return v.L(groups);
}

fn termsOf(p: *Page, key: []const u8, out: *std.ArrayList([]const u8)) void {
    const tv = p.fm.getCI(key) orelse return;
    switch (tv) {
        .list => |tl| for (tl.items.items) |x| out.append(sys.A, v.lower(v.toStr(x))) catch {},
        .str => |sx| out.append(sys.A, v.lower(sx)) catch {},
        else => {},
    }
}

/// Approximation of Hugo's related content: pages sharing keywords/tags (or the
/// configured related.indices), ranked by weighted overlap, then by date.
fn related(l: *v.List, args: []Value) anyerror!Value {
    const res = v.newList();
    if (args.len == 0) return v.L(res);
    var target: ?*Page = asPage(args[0]);
    if (target == null and args[0] == .map) if (args[0].map.getCI("document")) |d| {
        target = asPage(d);
    };
    const p = target orelse return v.L(res);
    var names: std.ArrayList([]const u8) = .empty;
    var weights: std.ArrayList(i64) = .empty;
    var include_newer = false;
    if (site.S.cfg.map("related")) |rc| {
        include_newer = rc.boolean("includeNewer", false);
        if (rc.list("indices")) |il| for (il.items.items) |iv| if (iv == .map) {
            const nm = iv.map.str("name") orelse continue;
            if (v.eqi(nm, "date") or v.eqi(nm, "fragmentrefs")) continue;
            try names.append(sys.A, nm);
            try weights.append(sys.A, iv.map.int("weight", 100));
        };
    }
    if (names.items.len == 0) {
        try names.appendSlice(sys.A, &.{ "keywords", "tags" });
        try weights.appendSlice(sys.A, &.{ 100, 80 });
    }
    const Scored = struct { page: *Page, score: i64 };
    var scored: std.ArrayList(Scored) = .empty;
    for (l.items.items) |cv| {
        const c = asPage(cv) orelse continue;
        if (c == p) continue;
        if (!include_newer and c.date.sec > p.date.sec) continue;
        var score: i64 = 0;
        for (names.items, weights.items) |nm, w| {
            var a: std.ArrayList([]const u8) = .empty;
            var b: std.ArrayList([]const u8) = .empty;
            termsOf(p, nm, &a);
            termsOf(c, nm, &b);
            for (a.items) |x| for (b.items) |y| if (v.eq(x, y)) {
                score += w;
            };
        }
        if (score > 0) try scored.append(sys.A, .{ .page = c, .score = score });
    }
    const C = struct {
        fn less(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.page.date.sec > b.page.date.sec;
        }
    };
    std.mem.sort(Scored, scored.items, {}, C.less);
    for (scored.items) |sc| v.push(res, sc.page.val());
    return v.L(res);
}

const LM = enum { ByDate, ByTitle, ByWeight, ByLastmod, ByPublishDate, ByExpiryDate, ByLength, ByLinkTitle, ByParam, ByLanguage, Reverse, Limit, Len, GroupByDate, GroupByPublishDate, GroupByLastmod, GroupByExpiryDate, GroupBy, GroupByParam, GroupByParamDate, Related, RelatedIndices, RelatedTo, Next, Prev, Get, Pages, Count, Alphabetical, ByCount, MergeByLanguage, Canonical, Default };

pub fn listMethod(l: *v.List, name: []const u8, args: []Value) anyerror!Value {
    const f = std.meta.stringToEnum(LM, name) orelse return fail("can't evaluate field {s} in a slice/collection", .{name});
    const items = l.items.items;
    const sorted = struct {
        fn go(src: []Value, c: SortCtx) Value {
            const n = v.newList();
            for (src) |x| v.push(n, x);
            std.mem.sort(Value, n.items.items, c, pageKeyLess);
            return v.L(n);
        }
    }.go;
    switch (f) {
        .ByDate => return sorted(items, .{ .key = .date }),
        .ByTitle => return sorted(items, .{ .key = .title }),
        .ByWeight => return sorted(items, .{ .key = .weight }),
        .ByLastmod => return sorted(items, .{ .key = .lastmod }),
        .ByPublishDate => return sorted(items, .{ .key = .publish }),
        .ByExpiryDate => return sorted(items, .{ .key = .expiry }),
        .ByLength => return sorted(items, .{ .key = .length }),
        .ByLinkTitle => return sorted(items, .{ .key = .linktitle }),
        .ByParam => return sorted(items, .{ .key = .param, .param = if (args.len > 0) v.toStr(args[0]) else "" }),
        .ByLanguage, .MergeByLanguage, .Pages => return v.L(l),
        .Reverse => {
            const n = v.newList();
            var i = items.len;
            while (i > 0) : (i -= 1) v.push(n, items[i - 1]);
            return v.L(n);
        },
        .Limit => {
            const n = v.newList();
            const lim: usize = @intCast(@max(if (args.len > 0) v.toInt(args[0]) orelse 0 else 0, 0));
            for (items[0..@min(lim, items.len)]) |x| v.push(n, x);
            return v.L(n);
        },
        .Len, .Count => return v.I(items.len),
        .GroupByDate, .GroupByPublishDate, .GroupByLastmod, .GroupByExpiryDate => {
            const layout = if (args.len > 0) v.toStr(args[0]) else "2006";
            const desc = !(args.len > 1 and v.eq(v.toStr(args[1]), "asc"));
            return groupBy(l, switch (f) {
                .GroupByDate => .date,
                .GroupByPublishDate => .publish,
                .GroupByLastmod => .lastmod,
                else => .expiry,
            }, layout, desc);
        },
        .GroupBy, .GroupByParam, .GroupByParamDate => {
            const key = if (args.len > 0) v.toStr(args[0]) else "";
            const desc = args.len > 1 and v.eq(v.toStr(args[1]), "desc");
            return groupBy(l, if (f == .GroupBy) .field else .param, key, desc);
        },
        .Related, .RelatedIndices, .RelatedTo => return related(l, args),
        .Next, .Prev => {
            if (args.len == 0) return .nil;
            for (items, 0..) |x, i| if (v.eql(x, args[0])) {
                if (f == .Next) return if (i > 0) items[i - 1] else .nil;
                return if (i + 1 < items.len) items[i + 1] else .nil;
            };
            return .nil;
        },
        .Get => {
            // OutputFormats.Get "rss" / Resources.Get "name"
            const want = if (args.len > 0) v.toStr(args[0]) else "";
            for (items) |x| {
                if (x == .map) {
                    if (x.map.str("Name")) |n| if (v.eqi(n, want)) return x;
                } else if (asRes(x)) |r| {
                    if (v.eqi(r.name, want) or v.eqi(r.name, v.concat(&.{ "/", want })) or (r.path.len > 0 and v.eqi(r.path, want))) return x;
                }
            }
            return .nil;
        },
        .Alphabetical, .ByCount => return v.L(l),
        .Default => {
            // hugo.Sites.Default: the default content language's site
            for (items) |x| if (x == .obj and x.obj.kind == .site) {
                const st: *site.Site = @ptrCast(@alignCast(x.obj.ptr));
                if (v.eq(st.lang, st.default_lang)) return x;
            };
            return if (items.len > 0) items[0] else .nil;
        },
        .Canonical => {
            for (items) |x| if (x == .map) if (x.map.str("Rel")) |r| if (v.eq(r, "canonical")) return x;
            return .nil;
        },
    }
}

/// Resources collection helpers (GetMatch / Match / ByType) for lists of resources.
pub fn resListMethod(l: *v.List, name: []const u8, args: []Value) anyerror!?Value {
    const want = if (args.len > 0) v.toStr(args[0]) else "";
    if (v.eq(name, "GetMatch")) {
        for (l.items.items) |x| if (asRes(x)) |r| {
            if (glob(want, r.name) or glob(want, v.pathBase(r.name)) or (r.path.len > 0 and glob(want, r.path))) return x;
        };
        return .nil;
    }
    if (v.eq(name, "Match")) {
        const n = v.newList();
        for (l.items.items) |x| if (asRes(x)) |r| {
            if (glob(want, r.name) or glob(want, v.pathBase(r.name)) or (r.path.len > 0 and glob(want, r.path))) v.push(n, x);
        };
        return v.L(n);
    }
    if (v.eq(name, "ByType")) {
        const n = v.newList();
        for (l.items.items) |x| if (asRes(x)) |r| {
            if (v.startsWith(r.media, want) and r.media.len > want.len and r.media[want.len] == '/') v.push(n, x);
        };
        return v.L(n);
    }
    return null;
}

// ================================================================ page fields

fn fileVal(p: *Page) Value {
    const f = p.file orelse return .nil;
    const m = v.newMap();
    const dir = v.pathDir(f);
    const stem = v.pathStem(f);
    m.put("Path", v.S(f));
    m.put("Dir", v.S(if (dir.len == 0) "" else v.concat(&.{ dir, "/" })));
    m.put("LogicalName", v.S(v.pathBase(f)));
    m.put("BaseFileName", v.S(stem));
    m.put("TranslationBaseName", v.S(stem));
    m.put("ContentBaseName", v.S(if (v.eq(stem, "index") or v.eq(stem, "_index")) v.pathBase(dir) else stem));
    m.put("Ext", v.S(std.mem.trimStart(u8, v.pathExt(f), ".")));
    m.put("Filename", v.S(p.file_abs));
    m.put("Section", v.S(p.section));
    m.put("Lang", v.S(site.S.lang));
    m.put("IsZero", v.B(false));
    m.put("UniqueID", v.S(funcs.md5hex(f)));
    return v.M(m);
}

pub fn formatVal(p: *Page, f: *const site.OutputFormat) Value {
    const m = v.newMap();
    m.put("Name", v.S(f.name));
    m.put("MediaType", mediaVal(f.media));
    m.put("Rel", v.S(f.rel));
    const u = outUrl(p, f);
    m.put("RelPermalink", v.S(relUrl(u)));
    m.put("Permalink", v.S(absUrl(u)));
    m.put("Format", v.S(f.name));
    return v.M(m);
}

pub fn langVal() Value {
    return langValOf(site.S);
}

pub fn langValOf(s: *site.Site) Value {
    const m = v.newMap();
    m.put("Lang", v.S(s.lang));
    m.put("Name", v.S(s.lang));
    m.put("Locale", v.S(s.cfg.str("locale") orelse s.cfg.str("languageCode") orelse s.lang));
    m.put("LanguageCode", v.S(s.cfg.str("languageCode") orelse s.lang_map.str("languageCode") orelse s.lang));
    m.put("LanguageName", v.S(s.lang_map.str("languageName") orelse s.lang_map.str("label") orelse s.cfg.str("languageName") orelse ""));
    m.put("Label", v.S(s.lang_map.str("label") orelse s.lang_map.str("languageName") orelse ""));
    m.put("Direction", v.S(s.lang_map.str("direction") orelse s.lang_map.str("languageDirection") orelse s.cfg.str("languageDirection") orelse ""));
    m.put("LanguageDirection", v.S(s.lang_map.str("languageDirection") orelse s.cfg.str("languageDirection") orelse ""));
    m.put("Weight", v.I(s.lang_map.int("weight", 0)));
    m.put("Params", v.M(s.params));
    m.put("IsDefault", v.B(v.eq(s.lang, s.default_lang)));
    m.put("__str", v.S(s.lang));
    return v.M(m);
}

fn ancestorsOf(p: *Page) Value {
    const l = v.newList();
    var cur = p.parent;
    while (cur) |c| : (cur = c.parent) v.push(l, c.val());
    return v.L(l);
}

fn firstSection(p: *Page) *Page {
    var cur = p;
    while (cur.parent) |par| {
        if (par.kind == .home) return if (cur.kind == .page) par else cur;
        cur = par;
    }
    return cur;
}

fn currentSection(p: *Page) *Page {
    if (p.kind == .page) return p.parent orelse site.S.home;
    return p;
}

fn isAncestorOf(a: *Page, b: *Page) bool {
    var cur = b.parent;
    while (cur) |c| : (cur = c.parent) if (c == a) return true;
    return false;
}

fn menuCurrent(p: *Page, args: []Value, has: bool) bool {
    if (args.len < 2 or args[1] != .map) return false;
    const e = args[1].map;
    const Chk = struct {
        fn is(pp: *Page, m: *Map) bool {
            if (m.get("Page")) |pv| if (asPage(pv)) |ep| return ep == pp;
            const url = m.str("URL") orelse return false;
            return v.eq(url, relUrl(pp.url)) or v.eq(std.mem.trimEnd(u8, url, "/"), std.mem.trimEnd(u8, relUrl(pp.url), "/"));
        }
        fn anyChild(pp: *Page, m: *Map) bool {
            const ch = m.list("Children") orelse return false;
            for (ch.items.items) |c| {
                if (c != .map) continue;
                if (is(pp, c.map) or anyChild(pp, c.map)) return true;
            }
            return false;
        }
    };
    if (has) return Chk.anyChild(p, e);
    return Chk.is(p, e);
}

const PF = enum { Title, LinkTitle, Content, Summary, Truncated, Plain, PlainWords, RawContent, WordCount, FuzzyWordCount, ReadingTime, Len, TableOfContents, Fragments, Permalink, RelPermalink, Date, Lastmod, PublishDate, ExpiryDate, Params, Param, Kind, Type, Section, Layout, IsHome, IsPage, IsSection, IsNode, Draft, Pages, RegularPages, RegularPagesRecursive, Sections, Parent, Ancestors, CurrentSection, FirstSection, IsAncestor, IsDescendant, InSection, Next, Prev, NextInSection, PrevInSection, NextPage, PrevPage, Site, Sites, File, Resources, Paginator, Paginate, Description, Keywords, Aliases, Slug, Weight, Language, Lang, IsTranslated, Translations, AllTranslations, TranslationKey, OutputFormats, AlternativeOutputFormats, GetTerms, Data, Scratch, Store, RenderString, Render, GetPage, Ref, RelRef, HasMenuCurrent, IsMenuCurrent, HasShortcode, Path, BundleType, GitInfo, Eq, CodeOwners, Sitemap, Page, Author, Hugo, Name, Markup, ContentWithoutSummary, Menus, Rotate, IsNamedParams, Taxonomies, Count, Term, WeightedPages, Position, Format, PageInner, Ordinal, Err };

pub fn pageField(ex: ?*tmpl.Exec, p: *Page, name: []const u8, args: []Value) anyerror!Value {
    const f = std.meta.stringToEnum(PF, name) orelse return fail("can't evaluate field {s} in type page.Page", .{name});
    const s = p.site;
    switch (f) {
        .Title, .Name => return v.S(p.title),
        .LinkTitle => return v.S(linkTitle(p)),
        .Content => {
            try renderContent(p);
            return v.H(p.content);
        },
        .ContentWithoutSummary => {
            try renderContent(p);
            if (v.startsWith(p.content, p.summary)) return v.H(p.content[p.summary.len..]);
            return v.H(p.content);
        },
        .Summary => {
            try renderContent(p);
            return v.H(p.summary);
        },
        .Truncated => {
            try renderContent(p);
            return v.B(p.truncated);
        },
        .Plain => return v.S(try plainOf(p)),
        .PlainWords => {
            const l = v.newList();
            var it = std.mem.tokenizeAny(u8, try plainOf(p), " \t\r\n");
            while (it.next()) |w| v.push(l, v.S(w));
            return v.L(l);
        },
        .RawContent => return v.S(p.raw),
        .WordCount => return v.I(wordCount(try plainOf(p))),
        .FuzzyWordCount => return v.I((wordCount(try plainOf(p)) + 100) / 100 * 100),
        .ReadingTime => return v.I((wordCount(try plainOf(p)) + 212) / 213),
        .Len => {
            try renderContent(p);
            return v.I(p.content.len);
        },
        .TableOfContents => {
            try renderContent(p);
            return v.H(p.toc);
        },
        .Fragments => {
            try renderContent(p);
            const m = v.newMap();
            const hs = v.newList();
            const ids = v.newList();
            for (p.headings) |h| {
                const hm = v.newMap();
                hm.put("ID", v.S(h.id));
                hm.put("Level", v.I(h.level));
                hm.put("Title", v.S(h.plain));
                hm.put("Headings", v.L(v.newList()));
                v.push(hs, v.M(hm));
                v.push(ids, v.S(h.id));
            }
            m.put("Headings", v.L(hs));
            m.put("Identifiers", v.L(ids));
            m.put("ToHTML", v.H(p.toc));
            return v.M(m);
        },
        .Permalink => return v.S(absUrl(p.url)),
        .RelPermalink => return v.S(relUrl(p.url)),
        .Date => return .{ .time = p.date },
        .Lastmod => return .{ .time = p.lastmod },
        .PublishDate => return .{ .time = p.publish },
        .ExpiryDate => return .{ .time = p.expiry },
        .Params => return v.M(p.params),
        .Param => return paramLookup(p, if (args.len > 0) v.toStr(args[0]) else ""),
        .Kind => return v.S(if (p.is_404) "404" else @tagName(p.kind)),
        .Type => return v.S(p.param("type") orelse if (p.section.len > 0) p.section else "page"),
        .Section => return v.S(p.section),
        .Layout => return v.S(p.param("layout") orelse ""),
        .IsHome => return v.B(p.kind == .home),
        .IsPage => return v.B(p.kind == .page and !p.is_404),
        .IsSection => return v.B(p.kind == .section),
        .IsNode => return v.B(p.kind != .page),
        .Draft => return v.B(p.draft),
        .Pages => return pagesVal(listPagesOf(p)),
        .RegularPages, .RegularPagesRecursive => {
            var out: std.ArrayList(*Page) = .empty;
            regularOf(p, f == .RegularPagesRecursive, &out);
            if (f == .RegularPagesRecursive) site.sortPages(out.items);
            return pagesVal(out.items);
        },
        .Sections => {
            var out: std.ArrayList(*Page) = .empty;
            for (p.children.items) |c| if (c.kind == .section) try out.append(sys.A, c);
            return pagesVal(out.items);
        },
        .Parent => return if (p.parent) |x| x.val() else .nil,
        .Ancestors => return ancestorsOf(p),
        .CurrentSection => return currentSection(p).val(),
        .FirstSection => return firstSection(p).val(),
        .IsAncestor => return v.B(if (args.len > 0) if (asPage(args[0])) |o| isAncestorOf(p, o) else false else false),
        .IsDescendant => return v.B(if (args.len > 0) if (asPage(args[0])) |o| isAncestorOf(o, p) else false else false),
        .InSection => return v.B(if (args.len > 0) if (asPage(args[0])) |o| currentSection(p) == currentSection(o) else false else false),
        .Next, .NextPage => return if (p.next) |x| x.val() else .nil,
        .Prev, .PrevPage => return if (p.prev) |x| x.val() else .nil,
        .NextInSection => return if (p.next_in_section) |x| x.val() else .nil,
        .PrevInSection => return if (p.prev_in_section) |x| x.val() else .nil,
        .Site => return s.val(),
        .Sites => return sitesVal(),
        .File => return fileVal(p),
        .Resources => return pageResources(p),
        .Paginator, .Paginate => {
            if (p.pagers.len == 0) {
                var items: []Value = &.{};
                var size = pagerSize();
                if (f == .Paginate) {
                    if (args.len == 0 or args[0] != .list) return fail("Paginate needs a collection of pages", .{});
                    items = args[0].list.items.items;
                    if (args.len > 1) size = @intCast(@max(v.toInt(args[1]) orelse 10, 1));
                } else {
                    var out: std.ArrayList(*Page) = .empty;
                    if (p.kind == .home) try out.appendSlice(sys.A, s.regular.items) else regularOf(p, false, &out);
                    items = pagesVal(out.items).list.items.items;
                }
                try makePagers(p, items, size);
                s.n_paginator += p.pagers.len - 1;
            }
            return currentPager(p);
        },
        .Description => return v.S(p.param("description") orelse ""),
        .Keywords => return if (p.fm.getCI("keywords")) |k| (if (k == .list) k else v.listOf(&.{k})) else v.L(v.newList()),
        .Aliases => return p.fm.getCI("aliases") orelse v.L(v.newList()),
        .Slug => return v.S(p.param("slug") orelse ""),
        .Weight => return v.I(p.weight),
        .Language => return langValOf(s),
        .Lang => return v.S(s.lang),
        .IsTranslated => return v.B(translationsOf(p, false).list.items.items.len > 0),
        .Translations => return translationsOf(p, false),
        .AllTranslations => return translationsOf(p, true),
        .TranslationKey => return v.S(p.path),
        .OutputFormats, .AlternativeOutputFormats => {
            const l = v.newList();
            for (p.outputs) |of| {
                if (f == .AlternativeOutputFormats and of == s.cur_format) continue;
                v.push(l, formatVal(p, of));
            }
            return v.L(l);
        },
        .GetTerms => {
            const l = v.newList();
            const plural = if (args.len > 0) v.toStr(args[0]) else "";
            if (s.taxonomies.get(plural)) |t| {
                if (p.fm.getCI(plural)) |tv| if (tv == .list) for (tv.list.items.items) |nm| {
                    if (t.terms.get(site.urlize(v.toStr(nm)))) |term| if (term.page) |tp| v.push(l, tp.val());
                };
            }
            return v.L(l);
        },
        .Data => {
            const m = v.newMap();
            m.put("Pages", pagesVal(listPagesOf(p)));
            if (p.tax) |t| {
                m.put("Singular", v.S(t.singular));
                m.put("Plural", v.S(t.plural));
                m.put("Terms", .{ .obj = .{ .kind = .taxonomy, .ptr = t } });
            }
            if (p.term) |t| m.put("Term", v.S(t.name));
            return v.M(m);
        },
        .Scratch, .Store => return scratchVal(p.store), // Page.Scratch is an alias of Page.Store
        .RenderString => {
            var text: []const u8 = "";
            var display: []const u8 = "inline";
            if (args.len == 1) text = v.toStr(args[0]) else if (args.len >= 2) {
                if (args[0] == .map) display = args[0].map.str("display") orelse "inline";
                text = v.toStr(args[1]);
            }
            var st: ScParse = .{ .src = text, .page = p };
            const expanded = try expandShortcodes(&st, text, null, false);
            const r = try renderMarkdown(p, expanded, false);
            if (!v.eq(display, "inline")) return v.H(r.html);
            var html = v.trimWs(r.html);
            if (v.startsWith(html, "<p>") and v.endsWith(html, "</p>") and v.indexOfPos(html, 3, "<p>") == null) html = html[3 .. html.len - 4];
            return v.H(html);
        },
        .Render => {
            const lname = if (args.len > 0) v.toStr(args[0]) else "summary";
            var cands: std.ArrayList([]const u8) = .empty;
            if (p.param("type")) |t| try cands.append(sys.A, v.fmt("{s}/{s}.html", .{ t, lname }));
            if (p.section.len > 0) try cands.append(sys.A, v.fmt("{s}/{s}.html", .{ p.section, lname }));
            try cands.append(sys.A, v.fmt("{s}.html", .{lname}));
            try cands.append(sys.A, v.fmt("_default/{s}.html", .{lname}));
            for (cands.items) |c| if (try site.getTemplate(c)) |t| {
                return v.H(try tmpl.render(t, null, p.val(), p.val(), false));
            };
            site.warn("Render: no layout \"{s}\" found for {s}", .{ lname, p.path });
            return v.H("");
        },
        .GetPage => {
            const ref = if (args.len > 0) v.toStr(args[0]) else "";
            return if (site.getPage(ref, p)) |x| x.val() else .nil;
        },
        .Ref, .RelRef => {
            var target: []const u8 = "";
            if (args.len > 0) target = if (args[0] == .map) args[0].map.str("path") orelse "" else v.toStr(args[0]);
            return v.S(refUrl(p, target, f == .Ref));
        },
        .HasMenuCurrent => return v.B(menuCurrent(p, args, true)),
        .IsMenuCurrent => return v.B(menuCurrent(p, args, false)),
        .HasShortcode => {
            try renderContent(p);
            const want = if (args.len > 0) v.toStr(args[0]) else "";
            for (p.shortcodes.items) |n| if (v.eq(n, want)) return v.B(true);
            return v.B(false);
        },
        .Path => return v.S(p.path),
        .BundleType => return v.S(switch (p.bundle) {
            .none => "",
            .leaf => "leaf",
            .branch => "branch",
        }),
        .GitInfo => return if (site.gitInfoFor(p)) |g| gitVal(g) else .nil,
        .CodeOwners, .Author, .Err => return .nil,
        .Eq => return v.B(args.len > 0 and asPage(args[0]) == p),
        .Sitemap => {
            const m = v.newMap();
            const sm = p.fm.map("sitemap") orelse s.cfg.map("sitemap");
            m.put("ChangeFreq", v.S(if (sm) |x| x.str("changefreq") orelse "" else ""));
            m.put("Priority", if (sm) |x| x.getCI("priority") orelse .{ .float = -1 } else .{ .float = -1 });
            m.put("Filename", v.S("sitemap.xml"));
            m.put("Disable", v.B(if (sm) |x| x.boolean("disable", false) else false));
            return v.M(m);
        },
        .Page, .PageInner => return p.val(),
        .Hugo => return funcs.hugoVal(),
        .Markup => return v.S(if (p.ext_markup.len > 0) p.ext_markup else if (p.is_md) "markdown" else "html"),
        .Menus => return v.M(v.newMap()),
        .Taxonomies => return taxonomiesVal(),
        .Count => return v.I(if (p.term) |t| t.pages.items.len else 0),
        .Term => return v.S(if (p.term) |t| t.name else ""),
        .WeightedPages => return pagesVal(listPagesOf(p)),
        .Rotate => {
            const dim = if (args.len > 0) v.toStr(args[0]) else "language";
            if (v.eq(dim, "language")) return translationsOf(p, true);
            return v.listOf(&.{p.val()});
        },
        .IsNamedParams, .Position, .Format, .Ordinal => {
            _ = ex;
            return .nil;
        },
    }
}

fn sitesVal() Value {
    const l = v.newList();
    for (site.all.items) |s| v.push(l, s.val());
    return v.L(l);
}

/// Pages with the same logical path (and kind) in the other languages.
fn translationsOf(p: *Page, include_self: bool) Value {
    const l = v.newList();
    for (site.all.items) |s| {
        if (s == p.site) {
            if (include_self) v.push(l, p.val());
            continue;
        }
        if (p.is_404) {
            if (!s.disabled.contains("404")) v.push(l, site.page404(s).val());
            continue;
        }
        if (s.by_path.get(p.path)) |o| {
            if (o.kind == p.kind and !o.is_404) v.push(l, o.val());
        }
    }
    return v.L(l);
}

// ================================================================ taxonomies

pub fn taxonomiesVal() Value {
    const m = v.newMap();
    for (site.S.taxonomies.keys(), site.S.taxonomies.values()) |k, t| m.put(k, .{ .obj = .{ .kind = .taxonomy, .ptr = t } });
    return v.M(m);
}

fn termVal(t: *site.Term) Value {
    return .{ .obj = .{ .kind = .term, .ptr = t } };
}

fn taxField(t: *site.Taxonomy, name: []const u8, args: []Value) anyerror!Value {
    if (v.eq(name, "Alphabetical") or v.eq(name, "ByCount")) {
        const l = v.newList();
        for (t.terms.values()) |term| v.push(l, termVal(term));
        if (v.eq(name, "ByCount")) {
            const C = struct {
                fn less(_: void, a: Value, b: Value) bool {
                    const ta: *site.Term = @ptrCast(@alignCast(a.obj.ptr));
                    const tb: *site.Term = @ptrCast(@alignCast(b.obj.ptr));
                    if (ta.pages.items.len != tb.pages.items.len) return ta.pages.items.len > tb.pages.items.len;
                    return std.mem.order(u8, ta.key, tb.key) == .lt;
                }
            };
            std.mem.sort(Value, l.items.items, {}, C.less);
        }
        return v.L(l);
    }
    if (v.eq(name, "Get")) {
        const key = site.urlize(if (args.len > 0) v.toStr(args[0]) else "");
        return if (t.terms.get(key)) |term| termVal(term) else v.L(v.newList());
    }
    if (v.eq(name, "Count")) {
        const key = site.urlize(if (args.len > 0) v.toStr(args[0]) else "");
        return v.I(if (t.terms.get(key)) |term| term.pages.items.len else 0);
    }
    if (v.eq(name, "Page")) return if (t.page) |p| p.val() else .nil;
    if (v.eq(name, "Len")) return v.I(t.terms.count());
    // term lookup by key: .Site.Taxonomies.tags.foo
    if (t.terms.get(site.urlize(name))) |term| return termVal(term);
    return .nil;
}

fn termField(ex: ?*tmpl.Exec, t: *site.Term, name: []const u8, args: []Value) anyerror!Value {
    if (v.eq(name, "Name") or v.eq(name, "Term")) return v.S(t.key);
    if (v.eq(name, "Count")) return v.I(t.pages.items.len);
    if (v.eq(name, "Pages") or v.eq(name, "WeightedPages")) return pagesVal(t.pages.items);
    if (v.eq(name, "Page")) return if (t.page) |p| p.val() else .nil;
    if (t.page) |p| return pageField(ex, p, name, args);
    return .nil;
}

// ================================================================ site fields

const STF = enum { Title, BaseURL, Params, Menus, Pages, RegularPages, AllPages, Sections, Taxonomies, Home, Language, LanguageCode, Languages, Copyright, Data, GetPage, Lastmod, IsMultiLingual, Config, MainSections, BuildDrafts, Sites, Store, Hugo, Author, Social, Param, IsServer, LanguagePrefix, DisqusShortname, GoogleAnalytics, RSSLink, Site, AllRegularPages, Dimension };

fn mainSections() Value {
    const s = site.S;
    if (s.main_sections) |m| return m;
    var res: Value = undefined;
    if (s.params.getCI("mainsections")) |ms| {
        res = if (ms == .list) ms else v.listOf(&.{ms});
    } else {
        var best: []const u8 = "";
        var best_n: usize = 0;
        for (s.home.children.items) |c| if (c.kind == .section) {
            var out: std.ArrayList(*Page) = .empty;
            regularOf(c, true, &out);
            if (out.items.len > best_n) {
                best_n = out.items.len;
                best = c.section;
            }
        };
        res = if (best_n > 0) v.strList(&.{best}) else v.L(v.newList());
    }
    s.main_sections = res;
    return res;
}

fn siteField(s: *site.Site, name: []const u8, args: []Value) anyerror!Value {
    const f = std.meta.stringToEnum(STF, name) orelse return fail("can't evaluate field {s} in type *hugolib.Site", .{name});
    switch (f) {
        .Title => return v.S(s.title),
        .BaseURL => return v.S(s.base_url),
        .Params => {
            if (s.params.getCI("mainsections") == null) s.params.put("mainsections", mainSections());
            return v.M(s.params);
        },
        .Param => return lookupPath(s.params, v.lower(if (args.len > 0) v.toStr(args[0]) else "")) orelse .nil,
        .Menus => return v.M(s.menus),
        .Pages, .AllPages => {
            var out: std.ArrayList(*Page) = .empty;
            for (s.pages.items) |p| if (p.list) try out.append(sys.A, p);
            return pagesVal(out.items);
        },
        .RegularPages, .AllRegularPages => return pagesVal(s.regular.items),
        .Sections => return pageField(null, s.home, "Sections", &.{}),
        .Taxonomies => return taxonomiesVal(),
        .Home => return s.home.val(),
        .Language => return langValOf(s),
        .LanguageCode => return v.S(s.cfg.str("languageCode") orelse s.lang),
        .Languages => {
            const l = v.newList();
            for (site.all.items) |x| v.push(l, langValOf(x));
            return v.L(l);
        },
        .Copyright => return v.S(s.cfg.str("copyright") orelse ""),
        .Data => return v.M(s.data),
        .GetPage => {
            var ref: []const u8 = if (args.len > 0) v.toStr(args[0]) else "";
            if (args.len > 1) ref = v.pathJoin(&.{ "/", ref, v.toStr(args[1]) });
            if (!v.startsWith(ref, "/")) {
                if (site.getPage(v.concat(&.{ "/", ref }), null)) |p| return p.val();
            }
            return if (site.getPage(ref, null)) |p| p.val() else .nil;
        },
        .Lastmod => {
            var t = s.home.lastmod;
            for (s.pages.items) |p| if (!p.lastmod.zero and (t.zero or p.lastmod.sec > t.sec)) {
                t = p.lastmod;
            };
            return .{ .time = t };
        },
        .IsMultiLingual => return v.B(site.isMultilingual()),
        .Config => {
            const m = v.newMap();
            const services = v.newMap();
            const svc = s.cfg.map("services");
            const names = [_][2][]const u8{ .{ "GoogleAnalytics", "ID" }, .{ "Disqus", "Shortname" }, .{ "RSS", "Limit" }, .{ "Instagram", "AccessToken" }, .{ "X", "DisableInlineCSS" }, .{ "Twitter", "DisableInlineCSS" } };
            for (names) |n| {
                const sm = v.newMap();
                var val: Value = v.S("");
                if (svc) |sv| if (sv.map(n[0])) |x| {
                    val = x.getCI(n[1]) orelse v.S("");
                };
                if (v.eq(n[0], "GoogleAnalytics") and v.toStr(val).len == 0) val = v.S(s.cfg.str("googleAnalytics") orelse "");
                if (v.eq(n[0], "Disqus") and v.toStr(val).len == 0) val = v.S(s.cfg.str("disqusShortname") orelse "");
                if (v.eq(n[0], "RSS") and v.toStr(val).len == 0) val = v.I(s.cfg.int("rssLimit", -1));
                sm.put(n[1], val);
                services.put(n[0], v.M(sm));
            }
            m.put("Services", v.M(services));
            const priv = v.newMap();
            for ([_][]const u8{ "Disqus", "GoogleAnalytics", "Instagram", "Twitter", "X", "Vimeo", "YouTube" }) |n| {
                const pm = v.newMap();
                pm.put("Disable", v.B(false));
                pm.put("Simple", v.B(false));
                pm.put("PrivacyEnhanced", v.B(false));
                pm.put("RespectDoNotTrack", v.B(false));
                pm.put("EnableDNT", v.B(false));
                if (s.cfg.map("privacy")) |pc| if (pc.map(n)) |x| for (x.m.keys(), x.m.values()) |k, val| pm.putCI(k, val);
                priv.put(n, v.M(pm));
            }
            m.put("Privacy", v.M(priv));
            return v.M(m);
        },
        .MainSections => return mainSections(),
        .BuildDrafts => return v.B(s.opt.drafts),
        .Sites => return sitesVal(),
        .Site => return s.val(),
        .Store => return scratchVal(s.store),
        .Hugo => return funcs.hugoVal(),
        .Author, .Social => return if (s.cfg.getCI(v.lower(name))) |a| data.lowerKeys(a) else (s.params.getCI(v.lower(name)) orelse v.M(v.newMap())),
        .IsServer => return v.B(s.opt.server),
        .LanguagePrefix => return v.S(v.concat(&.{ s.base_path, s.lang_prefix })),
        .DisqusShortname => return v.S(s.cfg.str("disqusShortname") orelse ""),
        .GoogleAnalytics => return v.S(s.cfg.str("googleAnalytics") orelse ""),
        .RSSLink => return v.S(absUrl("/index.xml")),
        .Dimension => {
            const dim = if (args.len > 0) v.toStr(args[0]) else "language";
            if (v.eq(dim, "language")) return langValOf(s);
            const m = v.newMap();
            m.put("Name", v.S(if (v.eq(dim, "version")) "v1.0.0" else "guest"));
            return v.M(m);
        },
    }
}

// ================================================================ dispatch

pub fn objField(ex: *tmpl.Exec, o: v.Obj, name: []const u8, args: []Value) anyerror!Value {
    switch (o.kind) {
        .page => return pageField(ex, @ptrCast(@alignCast(o.ptr)), name, args),
        .site => return siteField(@ptrCast(@alignCast(o.ptr)), name, args),
        .pager => return pagerField(@ptrCast(@alignCast(o.ptr)), name),
        .resource => return resField(@ptrCast(@alignCast(o.ptr)), name, args),
        .scratch => return scratchField(@ptrCast(@alignCast(o.ptr)), name, args),
        .shortcode => return scField(@ptrCast(@alignCast(o.ptr)), name, args),
        .taxonomy => return taxField(@ptrCast(@alignCast(o.ptr)), name, args),
        .term => return termField(ex, @ptrCast(@alignCast(o.ptr)), name, args),
        else => return .nil,
    }
}

/// Value to range over for iterable objects.
pub fn objIter(o: v.Obj) anyerror!Value {
    switch (o.kind) {
        .taxonomy => {
            const t: *site.Taxonomy = @ptrCast(@alignCast(o.ptr));
            const m = v.newMap();
            for (t.terms.keys(), t.terms.values()) |k, term| m.put(k, termVal(term));
            return v.M(m);
        },
        .term => {
            const t: *site.Term = @ptrCast(@alignCast(o.ptr));
            return pagesVal(t.pages.items);
        },
        else => return fail("range can't iterate over {s}", .{objStr(o)}),
    }
}

pub fn objLen(o: v.Obj) ?usize {
    switch (o.kind) {
        .taxonomy => {
            const t: *site.Taxonomy = @ptrCast(@alignCast(o.ptr));
            return t.terms.count();
        },
        .term => {
            const t: *site.Term = @ptrCast(@alignCast(o.ptr));
            return t.pages.items.len;
        },
        else => return null,
    }
}

fn gitVal(g: *site.GitCommit) Value {
    const m = v.newMap();
    m.put("Hash", v.S(g.hash));
    m.put("AbbreviatedHash", v.S(g.abbrev));
    m.put("Subject", v.S(g.subject));
    m.put("AuthorName", v.S(g.author_name));
    m.put("AuthorEmail", v.S(g.author_email));
    m.put("AuthorDate", .{ .time = g.author_date });
    m.put("CommitDate", .{ .time = g.commit_date });
    m.put("Body", v.S(g.body));
    m.put("Parent", if (g.parent) |pp| gitVal(pp) else .nil);
    const anc = v.newList();
    var cur = g.parent;
    while (cur) |c| : (cur = c.parent) anc.items.append(sys.A, gitValFlat(c)) catch {};
    m.put("Ancestors", .{ .list = anc });
    return v.M(m);
}
fn gitValFlat(g: *site.GitCommit) Value {
    const m = v.newMap();
    m.put("Hash", v.S(g.hash));
    m.put("AbbreviatedHash", v.S(g.abbrev));
    m.put("Subject", v.S(g.subject));
    m.put("AuthorName", v.S(g.author_name));
    m.put("AuthorEmail", v.S(g.author_email));
    m.put("AuthorDate", .{ .time = g.author_date });
    m.put("CommitDate", .{ .time = g.commit_date });
    m.put("Body", v.S(g.body));
    return v.M(m);
}
