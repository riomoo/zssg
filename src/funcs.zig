// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors); Go (BSD-3-Clause, Copyright The Go Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Hugo template function library.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const data = @import("data.zig");
const tm = @import("time.zig");
const md = @import("markdown.zig");
const regex = @import("regex.zig");
const tmpl = @import("tmpl.zig");
const site = @import("site.zig");
const objs = @import("objs.zig");
const embedded = @import("embedded.zig");
const Value = v.Value;
const Map = v.Map;
const fail = tmpl.fail;

pub const Ctx = struct {
    ex: *tmpl.Exec,
    a: []Value,
    dot: Value,
    name: []const u8,

    fn need(c: *Ctx, n: usize) anyerror!void {
        if (c.a.len < n) return fail("wrong number of args for {s}: want at least {d} got {d}", .{ c.name, n, c.a.len });
    }
    fn s(c: *Ctx, i: usize) []const u8 {
        return if (i < c.a.len) v.toStr(c.a[i]) else "";
    }
    fn int(c: *Ctx, i: usize) anyerror!i64 {
        if (i >= c.a.len) return fail("{s}: missing argument {d}", .{ c.name, i + 1 });
        return v.toInt(c.a[i]) orelse fail("{s}: unable to cast {s} to int", .{ c.name, v.toStr(c.a[i]) });
    }
    fn float(c: *Ctx, i: usize) anyerror!f64 {
        if (i >= c.a.len) return fail("{s}: missing argument {d}", .{ c.name, i + 1 });
        return v.toFloat(c.a[i]) orelse fail("{s}: unable to cast {s} to float", .{ c.name, v.toStr(c.a[i]) });
    }
    fn last(c: *Ctx) Value {
        return if (c.a.len > 0) c.a[c.a.len - 1] else .nil;
    }
    fn page(c: *Ctx) ?*site.Page {
        if (objs.asPage(c.ex.page)) |p| return p;
        if (objs.asPage(c.dot)) |p| return p;
        return null;
    }
};

const Fn = *const fn (*Ctx) anyerror!Value;

var defines: std.StringHashMapUnmanaged([]tmpl.Node) = .empty;
pub fn registerDefine(name: []const u8, body: []tmpl.Node) void {
    if (!defines.contains(name)) defines.put(sys.A, name, body) catch {};
}
pub fn globalDefine(name: []const u8) ?[]tmpl.Node {
    return defines.get(name);
}

pub fn exists(name: []const u8) bool {
    return table.has(name);
}

/// Hugo's function namespaces; used so that a missing `ns.Func` is reported by its full name.
pub fn isNamespace(name: []const u8) bool {
    const list = [_][]const u8{ "cast", "collections", "compare", "crypto", "css", "data", "debug", "diagrams", "encoding", "fmt", "hash", "images", "inflect", "js", "lang", "math", "openapi3", "os", "partials", "path", "reflect", "resources", "safe", "strings", "templates", "time", "transform", "urls" };
    for (list) |n| if (v.eq(n, name)) return true;
    return false;
}

pub fn call(ex: *tmpl.Exec, name: []const u8, args: []Value, dot: Value) anyerror!Value {
    const f = table.get(name) orelse {
        return fail("function \"{s}\" not defined (not implemented in ZSSG)", .{name});
    };
    var c: Ctx = .{ .ex = ex, .a = args, .dot = dot, .name = name };
    return f(&c);
}

pub fn objIter(o: v.Obj) anyerror!Value {
    return objs.objIter(o);
}

// ================================================================ field access

fn timeField(t: v.Time, name: []const u8, args: []Value) anyerror!Value {
    const c = tm.civil(t);
    if (v.eq(name, "Format")) return v.S(tm.format(t, if (args.len > 0) v.toStr(args[0]) else "2006-01-02"));
    if (v.eq(name, "Year")) return v.I(c.year);
    if (v.eq(name, "Month")) return v.S(tm.monthName(c.month));
    if (v.eq(name, "Day")) return v.I(c.day);
    if (v.eq(name, "Hour")) return v.I(c.hour);
    if (v.eq(name, "Minute")) return v.I(c.min);
    if (v.eq(name, "Second")) return v.I(c.sec);
    if (v.eq(name, "Nanosecond")) return v.I(t.nsec);
    if (v.eq(name, "YearDay")) return v.I(c.yday);
    if (v.eq(name, "Weekday")) return v.S(tm.format(t, "Monday"));
    if (v.eq(name, "Unix")) return v.I(t.sec);
    if (v.eq(name, "UnixMilli")) return v.I(t.sec * 1000 + t.nsec / 1_000_000);
    if (v.eq(name, "UnixNano")) return v.I(t.sec * 1_000_000_000 + t.nsec);
    if (v.eq(name, "IsZero")) return v.B(t.zero);
    if (v.eq(name, "String")) return v.S(tm.toString(t));
    if (v.eq(name, "UTC")) {
        var u = t;
        u.off = 0;
        return .{ .time = u };
    }
    if (v.eq(name, "Local") or v.eq(name, "Truncate") or v.eq(name, "Round") or v.eq(name, "In")) return .{ .time = t };
    if (v.eq(name, "Before") or v.eq(name, "After") or v.eq(name, "Equal") or v.eq(name, "Sub")) {
        if (args.len == 0 or args[0] != .time) return fail("time.{s} needs a time argument", .{name});
        const o = args[0].time;
        if (v.eq(name, "Sub")) return .{ .dur = (t.sec - o.sec) * 1_000_000_000 + (@as(i64, t.nsec) - @as(i64, o.nsec)) };
        const ord = v.cmp(.{ .time = t }, .{ .time = o });
        return v.B(if (v.eq(name, "Before")) ord == .lt else if (v.eq(name, "After")) ord == .gt else ord == .eq);
    }
    if (v.eq(name, "Add")) {
        if (args.len == 0) return fail("time.Add needs a duration", .{});
        const d: i64 = if (args[0] == .dur) args[0].dur else v.toInt(args[0]) orelse 0;
        var n = t;
        n.sec += @divFloor(d, 1_000_000_000);
        return .{ .time = n };
    }
    if (v.eq(name, "AddDate")) {
        if (args.len < 3) return fail("time.AddDate needs years, months, days", .{});
        var n = tm.make(c.year + (v.toInt(args[0]) orelse 0), @as(i64, c.month) + (v.toInt(args[1]) orelse 0), @as(i64, c.day) + (v.toInt(args[2]) orelse 0), c.hour, c.min, c.sec, t.off);
        n.nsec = t.nsec;
        return .{ .time = n };
    }
    return fail("can't evaluate field {s} in type time.Time", .{name});
}

fn durField(d: i64, name: []const u8) anyerror!Value {
    const f: f64 = @floatFromInt(d);
    if (v.eq(name, "Seconds")) return .{ .float = f / 1e9 };
    if (v.eq(name, "Minutes")) return .{ .float = f / 60e9 };
    if (v.eq(name, "Hours")) return .{ .float = f / 3600e9 };
    if (v.eq(name, "Milliseconds")) return v.I(@divTrunc(d, 1_000_000));
    if (v.eq(name, "Microseconds")) return v.I(@divTrunc(d, 1000));
    if (v.eq(name, "Nanoseconds")) return v.I(d);
    if (v.eq(name, "String")) return v.S(v.toStr(.{ .dur = d }));
    return fail("can't evaluate field {s} in type time.Duration", .{name});
}

pub fn field(ex: *tmpl.Exec, base: Value, name: []const u8, args: []Value) anyerror!Value {
    switch (base) {
        .map => |m| {
            if (m.getCI(name)) |x| return x;
            if (m.get("__menu_entry") != null) {
                if (v.eq(name, "IsMenuCurrent") or v.eq(name, "HasMenuCurrent")) return v.B(false);
            }
            if (v.eq(name, "String")) if (m.get("__str")) |x| return x;
            return .nil;
        },
        .list => |l| {
            if (try objs.resListMethod(l, name, args)) |r| return r;
            return objs.listMethod(l, name, args);
        },
        .obj => |o| return objs.objField(ex, o, name, args),
        .time => |t| return timeField(t, name, args),
        .dur => |d| return durField(d, name),
        .nil => return .nil,
        else => return fail("can't evaluate field {s} in type {s} (value: {s})", .{ name, @tagName(base), v.toStr(base) }),
    }
}

// ================================================================ helpers

pub fn titleCase(s: []const u8) []const u8 {
    const small = [_][]const u8{ "a", "an", "and", "as", "at", "but", "by", "en", "for", "if", "in", "nor", "of", "on", "or", "per", "the", "to", "v", "v.", "via", "vs", "vs." };
    var b: v.Buf = .{};
    var i: usize = 0;
    var word_idx: usize = 0;
    while (i < s.len) {
        if (s[i] == ' ' or s[i] == '\t' or s[i] == '\n') {
            b.ch(s[i]);
            i += 1;
            continue;
        }
        var e = i;
        while (e < s.len and s[e] != ' ' and s[e] != '\t' and s[e] != '\n') e += 1;
        const w = s[i..e];
        var is_small = false;
        for (small) |sm| if (v.eqi(sm, w)) {
            is_small = true;
        };
        const is_last = v.trimWs(s[e..]).len == 0;
        if (is_small and word_idx > 0 and !is_last) {
            b.add(v.lower(w));
        } else {
            var cap = true;
            for (w) |c| {
                if (cap and std.ascii.isAlphabetic(c)) {
                    b.ch(std.ascii.toUpper(c));
                    cap = false;
                } else {
                    b.ch(c);
                    if (c == '-' or c == '/') cap = true else if (std.ascii.isAlphanumeric(c) or c >= 0x80) cap = false;
                }
            }
        }
        word_idx += 1;
        i = e;
    }
    return b.str();
}

pub fn queryEscape(s: []const u8) []const u8 {
    var b: v.Buf = .{};
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') b.ch(c) else if (c == ' ') b.ch('+') else b.print("%{X:0>2}", .{c});
    }
    return b.str();
}

fn hex(bytes: []const u8) []const u8 {
    var b: v.Buf = .{};
    for (bytes) |x| b.print("{x:0>2}", .{x});
    return b.str();
}

pub fn md5hex(s: []const u8) []const u8 {
    var out: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(s, &out, .{});
    return hex(&out);
}

var hugo_val: ?Value = null;
pub fn hugoVal() Value {
    if (hugo_val) |h| return h;
    const m = v.newMap();
    const env = site.S.opt.env;
    m.put("Version", v.S(site.hugo_compat));
    m.put("ZssgVersion", v.S(site.version));
    m.put("Environment", v.S(env));
    m.put("IsProduction", v.B(v.eq(env, "production")));
    m.put("IsDevelopment", v.B(v.eq(env, "development")));
    m.put("IsServer", v.B(site.S.opt.server));
    m.put("IsExtended", v.B(false));
    m.put("IsMultilingual", v.B(site.isMultilingual()));
    m.put("IsMultihost", v.B(false));
    m.put("Generator", v.H(v.fmt("<meta name=\"generator\" content=\"ZSSG {s}\">", .{site.version})));
    m.put("CommitHash", v.S(""));
    m.put("BuildDate", v.S(""));
    m.put("GoVersion", v.S("zig"));
    m.put("WorkingDir", v.S(site.S.opt.root));
    m.put("Deps", v.L(v.newList()));
    const sites = v.newList();
    for (site.all.items) |x| v.push(sites, x.val());
    m.put("Sites", v.L(sites));
    m.put("Store", objs.scratchVal(v.newMap()));
    hugo_val = v.M(m);
    return hugo_val.?;
}

fn pageOrHome(c: *Ctx) *site.Page {
    return c.page() orelse site.S.home;
}

// ================================================================ partials & templates

fn partialTemplate(name_in: []const u8) anyerror!?*tmpl.Template {
    var name = name_in;
    if (v.startsWith(name, "partials/")) name = name[9..];
    if (v.startsWith(name, "_partials/")) name = name[10..];
    const with_ext = if (v.pathExt(name).len == 0) v.concat(&.{ name, ".html" }) else name;
    for ([_][]const u8{ with_ext, name }) |n| {
        if (try site.getTemplate(v.concat(&.{ "_partials/", n }))) |t| return t;
        if (try site.getTemplate(v.concat(&.{ "partials/", n }))) |t| return t;
    }
    // inline partials: {{ define "_partials/name.html" }}
    for ([_][]const u8{ with_ext, name }) |n| {
        for ([_][]const u8{ "_partials/", "partials/" }) |pre| {
            const key = v.concat(&.{ pre, n });
            if (inline_partials.get(key)) |t| return t;
            if (defines.get(key)) |body| {
                const t = try sys.A.create(tmpl.Template);
                t.* = .{ .name = key, .nodes = body };
                try inline_partials.put(sys.A, key, t);
                return t;
            }
        }
    }
    return embedded.partial(with_ext);
}

var inline_partials: std.StringHashMapUnmanaged(*tmpl.Template) = .empty;

fn fHighlightCodeBlock(c: *Ctx) anyerror!Value {
    try c.need(1);
    const m = v.newMap();
    var lang: []const u8 = "";
    var code: []const u8 = "";
    var options: ?*v.Map = null;
    var attributes: ?*v.Map = null;
    if (c.a[0] == .map) {
        lang = c.a[0].map.strOr("Type", "");
        code = c.a[0].map.strOr("Inner", "");
        options = c.a[0].map.map("Options");
        attributes = c.a[0].map.map("Attributes");
    }
    const r = @import("highlight.zig").highlightCodeBlock(lang, code, options, attributes, if (c.a.len > 1) c.a[1] else .nil);
    m.put("Wrapped", v.H(r[0]));
    m.put("Inner", v.H(r[1]));
    return v.M(m);
}

fn execTemplate(ex: *tmpl.Exec, t: *tmpl.Template, dot: Value) anyerror!Value {
    if (ex.depth > 150) return fail("maximum template call stack size exceeded in {s}", .{t.name});
    var out: tmpl.Out = .{ .raw_mode = ex.out.raw_mode and !v.endsWith(t.name, ".html") };
    var sub: tmpl.Exec = .{ .out = &out, .tmpl = t, .page = ex.page, .depth = ex.depth + 1 };
    var returned = false;
    sub.vars.append(sys.A, .{ .name = "$", .val = dot }) catch {};
    sub.nodes(t.nodes, dot) catch |e| {
        if (e == error.TmplReturn) returned = true else return e;
    };
    if (returned) return sub.ret;
    return v.H(out.str());
}

fn fPartial(c: *Ctx) anyerror!Value {
    try c.need(1);
    const name = c.s(0);
    const t = (try partialTemplate(name)) orelse return fail("partial \"{s}\" not found", .{name});
    return execTemplate(c.ex, t, if (c.a.len > 1) c.a[1] else .nil);
}

fn fPartialCached(c: *Ctx) anyerror!Value {
    try c.need(1);
    var key: v.Buf = .{};
    key.add(c.s(0));
    if (c.a.len > 2) {
        for (c.a[2..]) |a| {
            key.ch(0);
            key.add(v.toStr(a));
        }
    }
    if (site.S.partial_cache.get(key.str())) |r| return r;
    const r = try fPartial(c);
    try site.S.partial_cache.put(sys.A, key.str(), r);
    return r;
}

pub fn templateByName(ex: *tmpl.Exec, name: []const u8, arg: Value, line: u32) anyerror!Value {
    if (v.startsWith(name, "_internal/")) {
        if (embedded.partial(name[10..])) |t| return execTemplate(ex, t, arg);
        site.warn("embedded template \"{s}\" is not available in ZSSG", .{name});
        return v.H("");
    }
    if (v.startsWith(name, "partials/") or v.startsWith(name, "_partials/")) {
        if (try partialTemplate(name)) |t| return execTemplate(ex, t, arg);
    }
    if (try site.getTemplate(name)) |t| return execTemplate(ex, t, arg);
    if (try partialTemplate(name)) |t| return execTemplate(ex, t, arg);
    return fail("{s}:{d}: template \"{s}\" not defined", .{ ex.tmpl.name, line, name });
}

fn fTemplatesExists(c: *Ctx) anyerror!Value {
    const name = c.s(0);
    if (site.S.layouts.contains(name)) return v.B(true);
    if (v.startsWith(name, "partials/")) if (site.S.layouts.contains(v.concat(&.{ "_", name }))) return v.B(true);
    if (v.startsWith(name, "_partials/")) if (site.S.layouts.contains(name[1..])) return v.B(true);
    return v.B(false);
}

// ================================================================ core

fn lenOf(x: Value) ?usize {
    return switch (x) {
        .str => |s| s.len,
        .safe => |s| s.s.len,
        .list => |l| l.items.items.len,
        .map => |m| m.m.count(),
        .nil => 0,
        .obj => |o| objs.objLen(o),
        else => null,
    };
}

fn fLen(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.I(lenOf(c.a[0]) orelse return fail("len of type {s}", .{@tagName(c.a[0])}));
}

fn indexOne(base: Value, key: Value) anyerror!Value {
    switch (base) {
        .list => |l| {
            const i = v.toInt(key) orelse return fail("index: cannot index slice with {s}", .{v.toStr(key)});
            if (i < 0 or @as(usize, @intCast(i)) >= l.items.items.len) return .nil;
            return l.items.items[@intCast(i)];
        },
        .map => |m| return m.getCI(v.toStr(key)) orelse .nil,
        .str, .safe => {
            const s = v.rawStr(base).?;
            const i = v.toInt(key) orelse return fail("index: cannot index string with {s}", .{v.toStr(key)});
            if (i < 0 or @as(usize, @intCast(i)) >= s.len) return fail("error calling index: index out of range: {d}", .{i});
            return v.I(s[@intCast(i)]);
        },
        .nil => return .nil,
        .obj => |o| {
            if (o.kind == .taxonomy or o.kind == .term) {
                const it = try objs.objIter(o);
                return indexOne(it, key);
            }
            return .nil;
        },
        else => return fail("can't index item of type {s}", .{@tagName(base)}),
    }
}

fn fIndex(c: *Ctx) anyerror!Value {
    try c.need(1);
    var cur = c.a[0];
    for (c.a[1..]) |k| {
        if (k == .list) {
            for (k.list.items.items) |kk| cur = try indexOne(cur, kk);
        } else cur = try indexOne(cur, k);
    }
    return cur;
}

fn fSlice(c: *Ctx) anyerror!Value {
    return v.listOf(c.a);
}

fn fDict(c: *Ctx) anyerror!Value {
    const m = v.newMap();
    var i: usize = 0;
    while (i + 1 < c.a.len) : (i += 2) {
        if (c.a[i] == .list) {
            // nested key path
            var cur = m;
            const keys = c.a[i].list.items.items;
            for (keys, 0..) |k, idx| {
                const ks = v.toStr(k);
                if (idx == keys.len - 1) cur.put(ks, c.a[i + 1]) else {
                    cur = cur.map(ks) orelse blk: {
                        const n = v.newMap();
                        cur.put(ks, v.M(n));
                        break :blk n;
                    };
                }
            }
        } else m.put(v.toStr(c.a[i]), c.a[i + 1]);
    }
    if (c.a.len % 2 != 0) return fail("invalid dictionary call: odd number of arguments", .{});
    return v.M(m);
}

fn fPrint(c: *Ctx) anyerror!Value {
    var b: v.Buf = .{};
    for (c.a, 0..) |a, i| {
        // Go's Sprint adds a space between operands when neither is a string
        if (i > 0 and !v.isStr(a) and !v.isStr(c.a[i - 1])) b.ch(' ');
        b.add(v.toStr(a));
    }
    return v.S(b.str());
}

fn fPrintln(c: *Ctx) anyerror!Value {
    var b: v.Buf = .{};
    for (c.a, 0..) |a, i| {
        if (i > 0) b.ch(' ');
        b.add(v.toStr(a));
    }
    b.ch('\n');
    return v.S(b.str());
}

fn goQuote(s: []const u8) []const u8 {
    var b: v.Buf = .{};
    b.ch('"');
    for (s) |ch| switch (ch) {
        '"' => b.add("\\\""),
        '\\' => b.add("\\\\"),
        '\n' => b.add("\\n"),
        '\t' => b.add("\\t"),
        '\r' => b.add("\\r"),
        else => b.ch(ch),
    };
    b.ch('"');
    return b.str();
}

pub fn sprintf(f: []const u8, args: []const Value) []const u8 {
    var b: v.Buf = .{};
    var ai: usize = 0;
    var i: usize = 0;
    while (i < f.len) {
        if (f[i] != '%') {
            b.ch(f[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= f.len) {
            b.add("%!(NOVERB)");
            break;
        }
        if (f[i] == '%') {
            b.ch('%');
            i += 1;
            continue;
        }
        var minus = false;
        var plus = false;
        var zero = false;
        var sharp = false;
        var space = false;
        while (i < f.len) : (i += 1) {
            switch (f[i]) {
                '-' => minus = true,
                '+' => plus = true,
                '0' => zero = true,
                '#' => sharp = true,
                ' ' => space = true,
                else => break,
            }
        }
        var width: usize = 0;
        while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) width = width * 10 + (f[i] - '0');
        var prec: ?usize = null;
        if (i < f.len and f[i] == '.') {
            i += 1;
            var p: usize = 0;
            while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) p = p * 10 + (f[i] - '0');
            prec = p;
        }
        if (i >= f.len) break;
        const verb = f[i];
        i += 1;
        if (ai >= args.len) {
            b.print("%!{c}(MISSING)", .{verb});
            continue;
        }
        const a = args[ai];
        ai += 1;
        var s: []const u8 = "";
        switch (verb) {
            'v', 's' => {
                s = v.toStr(a);
                if (a == .nil) s = if (verb == 's') "%!s(<nil>)" else "<nil>";
                if (prec) |p| if (verb == 's' and p < s.len) {
                    s = s[0..p];
                };
            },
            'q' => s = goQuote(v.toStr(a)),
            'd' => {
                if (v.toInt(a)) |n| {
                    if (a == .float or a == .str or a == .safe) {
                        s = if (a == .float) v.fmt("%!d(float64={d})", .{a.float}) else v.fmt("%!d(string={s})", .{v.toStr(a)});
                    } else {
                        s = v.fmt("{d}", .{if (n < 0) -n else n});
                        if (n < 0) s = v.concat(&.{ "-", s }) else if (plus) s = v.concat(&.{ "+", s }) else if (space) s = v.concat(&.{ " ", s });
                    }
                } else s = v.fmt("%!d({s})", .{v.toStr(a)});
            },
            'f', 'F', 'e', 'g' => {
                if (v.toFloat(a)) |x| {
                    if (verb == 'g' and prec == null) {
                        s = v.floatStr(x);
                    } else {
                        const p = prec orelse 6;
                        s = fmtFixed(x, p);
                    }
                    if (plus and x >= 0) s = v.concat(&.{ "+", s });
                } else s = v.fmt("%!{c}({s})", .{ verb, v.toStr(a) });
            },
            't' => s = v.toStr(a),
            'x', 'X' => {
                if (a == .int) {
                    s = if (verb == 'x') v.fmt("{x}", .{a.int}) else v.fmt("{X}", .{a.int});
                    if (sharp) s = v.concat(&.{ "0x", s });
                } else {
                    var hb: v.Buf = .{};
                    for (v.toStr(a)) |ch| if (verb == 'x') hb.print("{x:0>2}", .{ch}) else hb.print("{X:0>2}", .{ch});
                    s = hb.str();
                }
            },
            'c' => {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(@max(v.toInt(a) orelse '?', 0)), &tmp) catch 0;
                s = v.dup(tmp[0..n]);
            },
            'U' => s = v.fmt("U+{X:0>4}", .{v.toInt(a) orelse 0}),
            'T' => s = switch (a) {
                .str => "string",
                .safe => |sf| switch (sf.kind) {
                    .html => "template.HTML",
                    .attr => "template.HTMLAttr",
                    .css => "template.CSS",
                    .js => "template.JS",
                    .url => "template.URL",
                    .escaped => "string",
                },
                .int => "int",
                .float => "float64",
                .bool => "bool",
                .list => "[]interface {}",
                .map => "map[string]interface {}",
                .nil => "<nil>",
                .time => "time.Time",
                .dur => "time.Duration",
                .obj => |o| switch (o.kind) {
                    .page => "*hugolib.pageState",
                    .site => "*hugolib.Site",
                    else => "object",
                },
            },
            else => s = v.fmt("%!{c}({s})", .{ verb, v.toStr(a) }),
        }
        const w = v.runeCount(s);
        if (w < width) {
            const padn = width - w;
            if (minus) {
                b.add(s);
                var k: usize = 0;
                while (k < padn) : (k += 1) b.ch(' ');
            } else if (zero and verb != 's' and verb != 'v' and verb != 'q') {
                var body = s;
                if (body.len > 0 and (body[0] == '-' or body[0] == '+')) {
                    b.ch(body[0]);
                    body = body[1..];
                }
                var k: usize = 0;
                while (k < padn) : (k += 1) b.ch('0');
                b.add(body);
            } else {
                var k: usize = 0;
                while (k < padn) : (k += 1) b.ch(' ');
                b.add(s);
            }
        } else b.add(s);
    }
    if (ai < args.len) {
        b.add("%!(EXTRA ");
        for (args[ai..], 0..) |a, k| {
            if (k > 0) b.add(", ");
            b.add(v.toStr(a));
        }
        b.ch(')');
    }
    return b.str();
}

fn fmtFixed(x: f64, prec: usize) []const u8 {
    if (!std.math.isFinite(x)) return if (std.math.isNan(x)) "NaN" else if (x > 0) "+Inf" else "-Inf";
    const scale = std.math.pow(f64, 10, @floatFromInt(prec));
    const r = @round(@abs(x) * scale);
    const whole = @divTrunc(r, scale);
    const frac = r - whole * scale;
    var b: v.Buf = .{};
    if (x < 0 and r != 0) b.ch('-');
    b.print("{d}", .{@as(u64, @intFromFloat(whole))});
    if (prec > 0) {
        b.ch('.');
        const fs = v.fmt("{d}", .{@as(u64, @intFromFloat(frac))});
        var k = fs.len;
        while (k < prec) : (k += 1) b.ch('0');
        b.add(fs);
    }
    return b.str();
}

fn fPrintf(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(sprintf(c.s(0), c.a[1..]));
}

fn fNot(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.B(!v.truth(c.a[0]));
}
fn fAnd(c: *Ctx) anyerror!Value {
    var lastv: Value = .nil;
    for (c.a) |a| {
        lastv = a;
        if (!v.truth(a)) return a;
    }
    return lastv;
}
fn fOr(c: *Ctx) anyerror!Value {
    var lastv: Value = .nil;
    for (c.a) |a| {
        lastv = a;
        if (v.truth(a)) return a;
    }
    return lastv;
}
fn fEq(c: *Ctx) anyerror!Value {
    try c.need(2);
    for (c.a[1..]) |a| if (v.eql(c.a[0], a)) return v.B(true);
    return v.B(false);
}
fn fNe(c: *Ctx) anyerror!Value {
    try c.need(2);
    for (c.a[1..]) |a| if (v.eql(c.a[0], a)) return v.B(false);
    return v.B(true);
}
fn cmp2(c: *Ctx) anyerror!std.math.Order {
    try c.need(2);
    return v.cmp(c.a[0], c.a[1]);
}
fn fLt(c: *Ctx) anyerror!Value {
    return v.B((try cmp2(c)) == .lt);
}
fn fLe(c: *Ctx) anyerror!Value {
    return v.B((try cmp2(c)) != .gt and (v.cmp(c.a[0], c.a[1]) == .lt or v.eql(c.a[0], c.a[1])));
}
fn fGt(c: *Ctx) anyerror!Value {
    return v.B((try cmp2(c)) == .gt);
}
fn fGe(c: *Ctx) anyerror!Value {
    return v.B((try cmp2(c)) == .gt or v.eql(c.a[0], c.a[1]));
}

fn fDefault(c: *Ctx) anyerror!Value {
    try c.need(1);
    if (c.a.len < 2) return c.a[0];
    const given = c.a[1];
    const set = switch (given) {
        .nil => false,
        .str => |s| s.len > 0,
        .safe => |s| s.s.len > 0,
        .list => |l| l.items.items.len > 0,
        .map => |m| m.m.count() > 0,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .bool => true,
        .time => |t| !t.zero,
        else => true,
    };
    return if (set) given else c.a[0];
}
fn fCond(c: *Ctx) anyerror!Value {
    try c.need(3);
    return if (v.truth(c.a[0])) c.a[1] else c.a[2];
}
fn fIsset(c: *Ctx) anyerror!Value {
    try c.need(2);
    switch (c.a[0]) {
        .map => |m| return v.B(if (m.getCI(c.s(1))) |x| x != .nil else false),
        .list => |l| {
            const i = v.toInt(c.a[1]) orelse return v.B(false);
            return v.B(i >= 0 and @as(usize, @intCast(i)) < l.items.items.len);
        },
        else => return v.B(false),
    }
}

// ================================================================ collections

fn asList(x: Value) ?[]Value {
    return switch (x) {
        .list => |l| l.items.items,
        .nil => &.{},
        else => null,
    };
}

fn listArg(c: *Ctx, i: usize) anyerror![]Value {
    if (i >= c.a.len) return fail("{s}: missing collection argument", .{c.name});
    var x = c.a[i];
    if (x == .obj and (x.obj.kind == .term or x.obj.kind == .taxonomy)) x = try objs.objIter(x.obj);
    if (x == .map) {
        const l = v.newList();
        for (v.sortedKeys(x.map)) |k| v.push(l, x.map.get(k).?);
        return l.items.items;
    }
    return asList(x) orelse fail("{s}: can't iterate over {s}", .{ c.name, @tagName(x) });
}

fn fFirst(c: *Ctx) anyerror!Value {
    try c.need(2);
    const n: usize = @intCast(@max(try c.int(0), 0));
    if (v.rawStr(c.a[1])) |s| return v.S(s[0..@min(n, s.len)]);
    const l = try listArg(c, 1);
    return v.listOf(l[0..@min(n, l.len)]);
}
fn fLast(c: *Ctx) anyerror!Value {
    try c.need(2);
    const n: usize = @intCast(@max(try c.int(0), 0));
    const l = try listArg(c, 1);
    return v.listOf(l[l.len - @min(n, l.len) ..]);
}
fn fAfter(c: *Ctx) anyerror!Value {
    try c.need(2);
    const n: usize = @intCast(@max(try c.int(0), 0));
    const l = try listArg(c, 1);
    return v.listOf(l[@min(n, l.len)..]);
}
fn fReverse(c: *Ctx) anyerror!Value {
    const l = try listArg(c, 0);
    const n = v.newList();
    var i = l.len;
    while (i > 0) : (i -= 1) v.push(n, l[i - 1]);
    return v.L(n);
}
fn fAppend(c: *Ctx) anyerror!Value {
    try c.need(2);
    const target = c.last();
    const n = v.newList();
    if (asList(target)) |l| {
        for (l) |x| v.push(n, x);
    } else return fail("append: expected a slice, got {s}", .{@tagName(target)});
    const adds = c.a[0 .. c.a.len - 1];
    if (adds.len == 1 and adds[0] == .list and !(n.items.items.len > 0 and n.items.items[0] == .list)) {
        for (adds[0].list.items.items) |x| v.push(n, x);
    } else for (adds) |x| v.push(n, x);
    return v.L(n);
}
fn fIn(c: *Ctx) anyerror!Value {
    try c.need(2);
    if (v.rawStr(c.a[0])) |s| return v.B(v.contains(s, c.s(1)));
    const l = asList(c.a[0]) orelse return v.B(false);
    for (l) |x| if (v.eql(x, c.a[1])) return v.B(true);
    return v.B(false);
}
fn fDelimit(c: *Ctx) anyerror!Value {
    try c.need(2);
    const l = try listArg(c, 0);
    const d = c.s(1);
    var b: v.Buf = .{};
    for (l, 0..) |x, i| {
        if (i > 0) b.add(if (c.a.len > 2 and i == l.len - 1) c.s(2) else d);
        b.add(v.toStr(x));
    }
    return v.S(b.str());
}
fn fUniq(c: *Ctx) anyerror!Value {
    const l = try listArg(c, 0);
    const n = v.newList();
    outer: for (l) |x| {
        for (n.items.items) |y| if (v.eql(x, y)) continue :outer;
        v.push(n, x);
    }
    return v.L(n);
}
fn fUnion(c: *Ctx) anyerror!Value {
    try c.need(2);
    const n = v.newList();
    for (c.a[0..2]) |arg| {
        const l = asList(arg) orelse continue;
        outer: for (l) |x| {
            for (n.items.items) |y| if (v.eql(x, y)) continue :outer;
            v.push(n, x);
        }
    }
    return v.L(n);
}
fn fIntersect(c: *Ctx) anyerror!Value {
    try c.need(2);
    const a = asList(c.a[0]) orelse return v.L(v.newList());
    const b = asList(c.a[1]) orelse return v.L(v.newList());
    const n = v.newList();
    outer: for (a) |x| {
        for (b) |y| if (v.eql(x, y)) {
            for (n.items.items) |z| if (v.eql(x, z)) continue :outer;
            v.push(n, x);
            continue :outer;
        };
    }
    return v.L(n);
}
fn fComplement(c: *Ctx) anyerror!Value {
    try c.need(2);
    const base = asList(c.last()) orelse return v.L(v.newList());
    const n = v.newList();
    outer: for (base) |x| {
        for (c.a[0 .. c.a.len - 1]) |ex| {
            const l = asList(ex) orelse continue;
            for (l) |y| if (v.eql(x, y)) continue :outer;
        }
        v.push(n, x);
    }
    return v.L(n);
}
fn fSymdiff(c: *Ctx) anyerror!Value {
    try c.need(2);
    const a = asList(c.a[0]) orelse &.{};
    const b = asList(c.a[1]) orelse &.{};
    const n = v.newList();
    o1: for (b) |x| {
        for (a) |y| if (v.eql(x, y)) continue :o1;
        v.push(n, x);
    }
    o2: for (a) |x| {
        for (b) |y| if (v.eql(x, y)) continue :o2;
        v.push(n, x);
    }
    return v.L(n);
}
fn fSeq(c: *Ctx) anyerror!Value {
    try c.need(1);
    var first: i64 = 1;
    var inc: i64 = 1;
    var lastn: i64 = undefined;
    if (c.a.len == 1) {
        lastn = try c.int(0);
        if (lastn == 0) return v.L(v.newList());
        if (lastn < 0) {
            inc = -1;
            first = -1;
        }
    } else if (c.a.len == 2) {
        first = try c.int(0);
        lastn = try c.int(1);
        if (lastn < first) inc = -1;
    } else {
        first = try c.int(0);
        inc = try c.int(1);
        lastn = try c.int(2);
    }
    if (inc == 0) return fail("seq: increment must not be 0", .{});
    const n = v.newList();
    var x = first;
    var guard: usize = 0;
    while ((inc > 0 and x <= lastn) or (inc < 0 and x >= lastn)) : (x += inc) {
        v.push(n, v.I(x));
        guard += 1;
        if (guard > 1_000_000) return fail("seq: size of result exceeds limit", .{});
    }
    return v.L(n);
}
fn fShuffle(c: *Ctx) anyerror!Value {
    const l = try listArg(c, 0);
    const n = v.listOf(l);
    var prng = std.Random.DefaultPrng.init(@intCast(sys.nowMillis()));
    prng.random().shuffle(Value, n.list.items.items);
    return n;
}

fn mergeMaps(dst: *Map, src: *Map) void {
    for (src.m.keys(), src.m.values()) |k, x| {
        if (dst.getCI(k)) |ex| {
            if (ex == .map and x == .map) {
                const nm = data.deepCopy(ex).map;
                mergeMaps(nm, x.map);
                dst.putCI(k, v.M(nm));
                continue;
            }
        }
        dst.putCI(k, x);
    }
}
fn fMerge(c: *Ctx) anyerror!Value {
    try c.need(2);
    const out = v.newMap();
    for (c.a) |a| {
        if (a == .nil) continue;
        if (a != .map) return fail("merge: expected a map, got {s}", .{@tagName(a)});
        mergeMaps(out, a.map);
    }
    return v.M(out);
}

/// Resolve a dotted key path against a page / map element.
fn resolvePath(c: *Ctx, elem: Value, path: []const u8) anyerror!Value {
    var cur = elem;
    var it = std.mem.tokenizeScalar(u8, path, '.');
    while (it.next()) |seg| {
        switch (cur) {
            .nil => return .nil,
            .map => |m| cur = m.getCI(seg) orelse .nil,
            .obj => cur = field(c.ex, cur, seg, &.{}) catch |e| blk: {
                // lower-case keys address params: where .Pages "Params.x" / "x"
                if (e != error.TemplateError) return e;
                if (objs.asPage(cur)) |p| break :blk objs.paramLookup(p, seg);
                break :blk Value.nil;
            },
            else => cur = try field(c.ex, cur, seg, &.{}),
        }
    }
    return cur;
}

fn whereMatch(op: []const u8, have: Value, want: Value) anyerror!bool {
    if (v.eq(op, "=") or v.eq(op, "==") or v.eq(op, "eq")) return v.eql(have, want);
    if (v.eq(op, "!=") or v.eq(op, "<>") or v.eq(op, "ne")) return !v.eql(have, want);
    if (v.eq(op, "in") or v.eq(op, "not in")) {
        var hit = false;
        if (want == .list) {
            for (want.list.items.items) |x| if (v.eql(x, have)) {
                hit = true;
            };
        } else if (v.rawStr(want)) |s| {
            if (v.rawStr(have)) |h| hit = v.contains(s, h);
        }
        return hit == v.eq(op, "in");
    }
    if (v.eq(op, "intersect")) {
        if (have != .list or want != .list) return false;
        for (have.list.items.items) |x| for (want.list.items.items) |y| if (v.eql(x, y)) return true;
        return false;
    }
    if (v.eq(op, "like")) {
        const re = regex.compile(v.toStr(want)) catch return fail("where: {s}", .{regex.err_msg});
        return regex.isMatch(re, v.toStr(have));
    }
    if (have == .nil or want == .nil) return false;
    const o = v.cmp(have, want);
    if (v.eq(op, ">") or v.eq(op, "gt")) return o == .gt;
    if (v.eq(op, ">=") or v.eq(op, "ge")) return o != .lt;
    if (v.eq(op, "<") or v.eq(op, "lt")) return o == .lt;
    if (v.eq(op, "<=") or v.eq(op, "le")) return o != .gt;
    return fail("where: invalid operator \"{s}\"", .{op});
}

fn fWhere(c: *Ctx) anyerror!Value {
    try c.need(3);
    const l = try listArg(c, 0);
    const key = std.mem.trim(u8, c.s(1), ".");
    const op = if (c.a.len > 3) c.s(2) else "=";
    const want = c.last();
    const n = v.newList();
    for (l) |x| {
        const have = try resolvePath(c, x, key);
        if (try whereMatch(op, have, want)) v.push(n, x);
    }
    return v.L(n);
}

const SortBy = struct { c: *Ctx, key: []const u8, desc: bool, err: ?anyerror = null };
fn sortLess(sb: *SortBy, a: Value, b: Value) bool {
    var x = a;
    var y = b;
    if (sb.key.len > 0 and !v.eq(sb.key, "value")) {
        x = resolvePath(sb.c, a, sb.key) catch |e| blk: {
            sb.err = e;
            break :blk Value.nil;
        };
        y = resolvePath(sb.c, b, sb.key) catch |e| blk: {
            sb.err = e;
            break :blk Value.nil;
        };
    }
    var o = v.cmp(x, y);
    if (v.isStr(x) and v.isStr(y)) {
        const ci = std.ascii.orderIgnoreCase(v.rawStr(x).?, v.rawStr(y).?);
        if (ci != .eq) o = ci;
    }
    return if (sb.desc) o == .gt else o == .lt;
}
fn fSort(c: *Ctx) anyerror!Value {
    try c.need(1);
    const l = try listArg(c, 0);
    const n = v.listOf(l);
    var sb: SortBy = .{ .c = c, .key = if (c.a.len > 1) std.mem.trim(u8, c.s(1), ".") else "", .desc = c.a.len > 2 and v.eqi(c.s(2), "desc") };
    std.mem.sort(Value, n.list.items.items, &sb, sortLess);
    if (sb.err) |e| return e;
    return n;
}

fn fGroup(c: *Ctx) anyerror!Value {
    try c.need(2);
    const m = v.newMap();
    m.put("Key", c.a[0]);
    m.put("Pages", c.a[1]);
    return v.M(m);
}

fn fApply(c: *Ctx) anyerror!Value {
    try c.need(2);
    const l = try listArg(c, 0);
    const fname = c.s(1);
    const n = v.newList();
    for (l) |x| {
        var args: std.ArrayList(Value) = .empty;
        for (c.a[2..]) |a| try args.append(sys.A, if (v.rawStr(a) != null and v.eq(v.rawStr(a).?, ".")) x else a);
        v.push(n, try call(c.ex, fname, args.items, c.dot));
    }
    return v.L(n);
}

fn fNewScratch(_: *Ctx) anyerror!Value {
    return objs.scratchVal(v.newMap());
}

fn fQuerify(c: *Ctx) anyerror!Value {
    var pairs: []Value = c.a;
    if (c.a.len == 1 and c.a[0] == .list) pairs = c.a[0].list.items.items;
    var b: v.Buf = .{};
    if (c.a.len == 1 and c.a[0] == .map) {
        for (v.sortedKeys(c.a[0].map), 0..) |k, i| {
            if (i > 0) b.ch('&');
            b.print("{s}={s}", .{ queryEscape(k), queryEscape(v.toStr(c.a[0].map.get(k).?)) });
        }
        return v.S(b.str());
    }
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        if (i > 0) b.ch('&');
        b.print("{s}={s}", .{ queryEscape(v.toStr(pairs[i])), queryEscape(v.toStr(pairs[i + 1])) });
    }
    return v.S(b.str());
}

fn fEchoParam(c: *Ctx) anyerror!Value {
    try c.need(2);
    return indexOne(c.a[0], c.a[1]) catch .nil;
}

fn fKeyVals(c: *Ctx) anyerror!Value {
    try c.need(1);
    const m = v.newMap();
    m.put("Key", c.a[0]);
    m.put("Values", v.listOf(c.a[1..]));
    return v.M(m);
}

// ================================================================ cast / math

fn fInt(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.I(try c.int(0));
}
fn fFloat(c: *Ctx) anyerror!Value {
    try c.need(1);
    return .{ .float = try c.float(0) };
}
fn fString(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(v.toStr(c.a[0]));
}

fn arith(c: *Ctx, op: u8) anyerror!Value {
    try c.need(2);
    var all_int = true;
    for (c.a) |a| if (a != .int) {
        all_int = false;
    };
    if (all_int and op != '/') {
        var acc = c.a[0].int;
        for (c.a[1..]) |a| switch (op) {
            '+' => acc +%= a.int,
            '-' => acc -%= a.int,
            '*' => acc *%= a.int,
            else => unreachable,
        };
        return v.I(acc);
    }
    if (all_int) {
        var acc = c.a[0].int;
        for (c.a[1..]) |a| {
            if (a.int == 0) return fail("can't divide the value by 0", .{});
            acc = @divTrunc(acc, a.int);
        }
        return v.I(acc);
    }
    if (op == '+' and v.isStr(c.a[0])) {
        var b: v.Buf = .{};
        for (c.a) |a| b.add(v.toStr(a));
        return v.S(b.str());
    }
    var acc = try c.float(0);
    for (c.a[1..], 1..) |_, i| {
        const x = try c.float(i);
        switch (op) {
            '+' => acc += x,
            '-' => acc -= x,
            '*' => acc *= x,
            else => {
                if (x == 0) return fail("can't divide the value by 0", .{});
                acc /= x;
            },
        }
    }
    return .{ .float = acc };
}
fn fAdd(c: *Ctx) anyerror!Value {
    return arith(c, '+');
}
fn fSub(c: *Ctx) anyerror!Value {
    return arith(c, '-');
}
fn fMul(c: *Ctx) anyerror!Value {
    return arith(c, '*');
}
fn fDiv(c: *Ctx) anyerror!Value {
    return arith(c, '/');
}
fn fMod(c: *Ctx) anyerror!Value {
    try c.need(2);
    const b = try c.int(1);
    if (b == 0) return fail("the number can't be divided by zero at modulo operation", .{});
    return v.I(@rem(try c.int(0), b));
}
fn fModBool(c: *Ctx) anyerror!Value {
    const r = try fMod(c);
    return v.B(r.int == 0);
}
fn math1(c: *Ctx) anyerror!Value {
    try c.need(1);
    const x = try c.float(0);
    const n = c.name[5..];
    const r: f64 = if (v.eq(n, "Ceil")) @ceil(x) else if (v.eq(n, "Floor")) @floor(x) else if (v.eq(n, "Round")) @round(x) else if (v.eq(n, "Sqrt")) @sqrt(x) else if (v.eq(n, "Abs")) @abs(x) else if (v.eq(n, "Log")) @log(x) else if (v.eq(n, "Sin")) @sin(x) else if (v.eq(n, "Cos")) @cos(x) else if (v.eq(n, "Tan")) @tan(x) else x;
    return .{ .float = r };
}
fn fPow(c: *Ctx) anyerror!Value {
    try c.need(2);
    return .{ .float = std.math.pow(f64, try c.float(0), try c.float(1)) };
}
fn flatNums(c: *Ctx, out: *std.ArrayList(f64), args: []Value) anyerror!void {
    for (args) |a| {
        if (a == .list) try flatNums(c, out, a.list.items.items) else try out.append(sys.A, v.toFloat(a) orelse return fail("{s}: not a number: {s}", .{ c.name, v.toStr(a) }));
    }
}
fn fMaxMin(c: *Ctx) anyerror!Value {
    var nums: std.ArrayList(f64) = .empty;
    try flatNums(c, &nums, c.a);
    if (nums.items.len == 0) return fail("{s}: needs at least one value", .{c.name});
    var r = nums.items[0];
    const n = c.name[5..];
    for (nums.items[1..]) |x| {
        if (v.eq(n, "Max")) r = @max(r, x) else if (v.eq(n, "Min")) r = @min(r, x) else if (v.eq(n, "Sum")) r += x else r *= x;
    }
    return .{ .float = r };
}
var counter: i64 = 0;
fn fCounter(_: *Ctx) anyerror!Value {
    counter += 1;
    return v.I(counter);
}
fn fRand(_: *Ctx) anyerror!Value {
    var prng = std.Random.DefaultPrng.init(@intCast(sys.nowMillis() +% counter));
    counter += 1;
    return .{ .float = prng.random().float(f64) };
}

// ================================================================ strings

fn reArg(c: *Ctx, i: usize) anyerror!*regex.Regex {
    return regex.compile(c.s(i)) catch fail("{s}: {s}", .{ c.name, regex.err_msg });
}

fn keepSafe(orig: Value, s: []const u8) Value {
    _ = orig;
    return v.S(s);
}

fn fLower(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(v.lower(c.s(0)));
}
fn fUpper(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(v.upper(c.s(0)));
}
fn fTitle(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(titleCase(c.s(0)));
}
fn fFirstUpper(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    if (s.len == 0) return v.S(s);
    return v.S(v.concat(&.{ v.upper(s[0..1]), s[1..] }));
}
fn fTrim(c: *Ctx) anyerror!Value {
    try c.need(2);
    return v.S(std.mem.trim(u8, c.s(0), c.s(1)));
}
fn fTrimLeft(c: *Ctx) anyerror!Value {
    try c.need(2);
    return v.S(std.mem.trimStart(u8, c.s(1), c.s(0)));
}
fn fTrimRight(c: *Ctx) anyerror!Value {
    try c.need(2);
    return v.S(std.mem.trimEnd(u8, c.s(1), c.s(0)));
}
fn fTrimPrefix(c: *Ctx) anyerror!Value {
    try c.need(2);
    const s = c.s(1);
    return v.S(if (v.startsWith(s, c.s(0))) s[c.s(0).len..] else s);
}
fn fTrimSuffix(c: *Ctx) anyerror!Value {
    try c.need(2);
    const s = c.s(1);
    return v.S(if (v.endsWith(s, c.s(0))) s[0 .. s.len - c.s(0).len] else s);
}
fn fTrimSpace(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(v.trimWs(c.s(0)));
}
fn fChomp(c: *Ctx) anyerror!Value {
    try c.need(1);
    const r = std.mem.trimEnd(u8, c.s(0), "\r\n");
    return if (c.a[0] == .safe) v.H(r) else v.S(r);
}
fn fHasPrefix(c: *Ctx) anyerror!Value {
    try c.need(2);
    return v.B(v.startsWith(c.s(0), c.s(1)));
}
fn fHasSuffix(c: *Ctx) anyerror!Value {
    try c.need(2);
    return v.B(v.endsWith(c.s(0), c.s(1)));
}
fn fContains(c: *Ctx) anyerror!Value {
    try c.need(2);
    return v.B(v.contains(c.s(0), c.s(1)));
}
fn fContainsAny(c: *Ctx) anyerror!Value {
    try c.need(2);
    return v.B(v.indexOfAny(c.s(0), c.s(1)) != null);
}
fn fContainsNonSpace(c: *Ctx) anyerror!Value {
    return v.B(v.trimWs(c.s(0)).len > 0);
}
fn fCount(c: *Ctx) anyerror!Value {
    try c.need(2);
    const sub = c.s(0);
    const s = c.s(1);
    if (sub.len == 0) return v.I(v.runeCount(s) + 1);
    var n: usize = 0;
    var i: usize = 0;
    while (v.indexOfPos(s, i, sub)) |p| {
        n += 1;
        i = p + sub.len;
    }
    return v.I(n);
}
fn fRepeat(c: *Ctx) anyerror!Value {
    try c.need(2);
    const n: usize = @intCast(@max(try c.int(0), 0));
    var b: v.Buf = .{};
    var i: usize = 0;
    while (i < n) : (i += 1) b.add(c.s(1));
    return v.S(b.str());
}
fn fReplace(c: *Ctx) anyerror!Value {
    try c.need(3);
    const s = c.s(0);
    const from = c.s(1);
    const to = c.s(2);
    if (c.a.len > 3) {
        var limit = try c.int(3);
        var b: v.Buf = .{};
        var i: usize = 0;
        while (limit != 0) {
            const p = v.indexOfPos(s, i, from) orelse break;
            b.add(s[i..p]);
            b.add(to);
            i = p + from.len;
            limit -= 1;
            if (from.len == 0) break;
        }
        b.add(s[i..]);
        return v.S(b.str());
    }
    return v.S(v.replaceAll(s, from, to));
}
fn fReplaceRE(c: *Ctx) anyerror!Value {
    try c.need(3);
    const re = try reArg(c, 0);
    const limit: i64 = if (c.a.len > 3) try c.int(3) else -1;
    return v.S(regex.replaceAll(re, c.s(2), c.s(1), limit));
}
fn fFindRE(c: *Ctx) anyerror!Value {
    try c.need(2);
    const re = try reArg(c, 0);
    const s = c.s(1);
    const limit: i64 = if (c.a.len > 2) try c.int(2) else -1;
    const n = v.newList();
    for (regex.findAll(re, s, limit)) |m| v.push(n, v.S(s[m.start()..m.end()]));
    return v.L(n);
}
fn fFindRESubmatch(c: *Ctx) anyerror!Value {
    try c.need(2);
    const re = try reArg(c, 0);
    const s = c.s(1);
    const limit: i64 = if (c.a.len > 2) try c.int(2) else -1;
    const n = v.newList();
    for (regex.findAll(re, s, limit)) |m| {
        const g = v.newList();
        var i: usize = 0;
        while (i < re.ncap) : (i += 1) v.push(g, v.S(m.group(s, i)));
        v.push(n, v.L(g));
    }
    return v.L(n);
}
fn fSplit(c: *Ctx) anyerror!Value {
    try c.need(2);
    const s = c.s(0);
    const d = c.s(1);
    const n = v.newList();
    if (d.len == 0) {
        var i: usize = 0;
        while (i < s.len) {
            const l = @min(v.utf8Len(s[i]), s.len - i);
            v.push(n, v.S(s[i .. i + l]));
            i += l;
        }
        return v.L(n);
    }
    var i: usize = 0;
    while (v.indexOfPos(s, i, d)) |p| {
        v.push(n, v.S(s[i..p]));
        i = p + d.len;
    }
    v.push(n, v.S(s[i..]));
    return v.L(n);
}
fn runeSlice(s: []const u8, start: usize, end: usize) []const u8 {
    var i: usize = 0;
    var r: usize = 0;
    var bs: usize = s.len;
    var be: usize = s.len;
    while (i < s.len) : (r += 1) {
        if (r == start) bs = i;
        if (r == end) {
            be = i;
            break;
        }
        i += @min(v.utf8Len(s[i]), s.len - i);
    }
    if (bs > be) return "";
    return s[bs..be];
}
fn fSubstr(c: *Ctx) anyerror!Value {
    try c.need(2);
    const s = c.s(0);
    const n: i64 = @intCast(v.runeCount(s));
    var start = try c.int(1);
    if (start < 0) start += n;
    start = std.math.clamp(start, 0, n);
    var end = n;
    if (c.a.len > 2) {
        const l = try c.int(2);
        end = if (l < 0) n + l else start + l;
    }
    end = std.math.clamp(end, start, n);
    return v.S(runeSlice(s, @intCast(start), @intCast(end)));
}
fn fSliceString(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    const n: i64 = @intCast(v.runeCount(s));
    const start = if (c.a.len > 1) try c.int(1) else 0;
    const end = if (c.a.len > 2) try c.int(2) else n;
    if (start < 0 or end > n or start > end) return fail("slice bounds out of range", .{});
    return v.S(runeSlice(s, @intCast(start), @intCast(end)));
}
/// Go's html.EscapeString
fn goHtmlEscape(s: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, s, "&'<>\"") == null) return s;
    var b: v.Buf = .{};
    for (s) |ch| switch (ch) {
        '&' => b.add("&amp;"),
        '\'' => b.add("&#39;"),
        '<' => b.add("&lt;"),
        '>' => b.add("&gt;"),
        '"' => b.add("&#34;"),
        else => b.ch(ch),
    };
    return b.str();
}

// ---- port of Hugo's common/hhtml scanner (used by truncate)
const HTokType = enum { none, start, end, markup };
const HTok = struct { typ: HTokType = .none, name: []const u8 = "", self_closing: bool = false, start: usize = 0 };
const HScanner = struct {
    s: []const u8,
    pos: usize,
    fn isLetter(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }
    fn isSp(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c;
    }
    fn nameEnd(ch: u8) bool {
        return isSp(ch) or ch == '/' or ch == '>';
    }
    fn skipPast(sc: *HScanner, limit: usize, sep: []const u8) void {
        if (std.mem.indexOf(u8, sc.s[sc.pos..limit], sep)) |i| sc.pos += i + sep.len else sc.pos = limit;
    }
    fn next(sc: *HScanner, limit: usize) ?HTok {
        while (true) {
            const i = std.mem.indexOfScalar(u8, sc.s[sc.pos..limit], '<') orelse {
                sc.pos = limit;
                return null;
            };
            if (sc.pos + i + 1 >= limit) {
                sc.pos = limit;
                return null;
            }
            var t: HTok = .{ .start = sc.pos + i };
            sc.pos = t.start + 1;
            const ch = sc.s[sc.pos];
            if (ch == '!' or ch == '?') {
                const rest = sc.s[sc.pos..limit];
                if (v.startsWith(rest, "!--")) {
                    sc.pos += 3;
                    sc.skipPast(limit, "-->");
                } else if (v.startsWith(rest, "![CDATA[")) sc.skipPast(limit, "]]>") else sc.skipPast(limit, ">");
                t.typ = .markup;
                return t;
            } else if (ch == '/') {
                sc.pos += 1;
                if (sc.pos < limit and !isLetter(sc.s[sc.pos])) {
                    sc.skipPast(limit, ">");
                    t.typ = .markup;
                    return t;
                }
                t.typ = .end;
            } else if (isLetter(ch)) {
                t.typ = .start;
            } else continue;
            const ns = sc.pos;
            while (sc.pos < limit and !nameEnd(sc.s[sc.pos])) sc.pos += 1;
            t.name = v.lower(sc.s[ns..sc.pos]);
            while (sc.pos < limit) {
                const x = sc.s[sc.pos];
                sc.pos += 1;
                switch (x) {
                    '>' => return t,
                    '/' => t.self_closing = t.typ == .start and sc.pos < limit and sc.s[sc.pos] == '>',
                    '=' => {
                        while (sc.pos < limit and isSp(sc.s[sc.pos])) sc.pos += 1;
                        if (sc.pos < limit and (sc.s[sc.pos] == '"' or sc.s[sc.pos] == '\'')) {
                            const q = sc.s[sc.pos];
                            sc.pos += 1;
                            if (std.mem.indexOfScalar(u8, sc.s[sc.pos..limit], q)) |j| sc.pos += j + 1 else sc.pos = limit;
                        }
                    },
                    else => {},
                }
            }
            return t;
        }
    }
    fn skipRawText(sc: *HScanner, limit: usize, name: []const u8) void {
        while (true) {
            sc.skipPast(limit, "</");
            if (sc.pos >= limit) return;
            const rest = sc.s[sc.pos..limit];
            if (rest.len > name.len and std.ascii.eqlIgnoreCase(rest[0..name.len], name) and nameEnd(rest[name.len])) {
                sc.pos -= 2;
                return;
            }
        }
    }
};
fn isRawTextEl(n: []const u8) bool {
    for ([_][]const u8{ "script", "style", "textarea", "title", "iframe", "xmp", "noembed", "noframes" }) |x| if (v.eq(n, x)) return true;
    return false;
}
fn isVoidEl(n: []const u8) bool {
    for ([_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" }) |x| if (v.eq(n, x)) return true;
    return false;
}

const Truncator = struct {
    length: usize,
    cur: usize = 0,
    last_word: usize = 0,
    last_non_space: usize = 0,
    fn isCjk(r: u21) bool {
        return switch (r) {
            0x1100...0x11FF, 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3041...0x309F, 0x30A1...0x30FF, 0x3131...0x318E, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9D, 0xFFA0...0xFFDC, 0x20000...0x3FFFF => true,
            else => false,
        };
    }
    fn isSpaceRune(r: u21) bool {
        return switch (r) {
            ' ', '\t', '\n', 0x0b, 0x0c, '\r', 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
            else => false,
        };
    }
    fn scan(t: *Truncator, s: []const u8, start: usize, end: usize) ?usize {
        var i = start;
        while (i < end) {
            const n = @min(std.unicode.utf8ByteSequenceLength(s[i]) catch 1, end - i);
            const r: u21 = std.unicode.utf8Decode(s[i .. i + n]) catch 0xFFFD;
            const rl: usize = if (r == 0xFFFD and n == 1) 3 else n;
            t.cur += 1;
            if (isSpaceRune(r)) {
                t.last_word = t.last_non_space;
            } else if (isCjk(r)) {
                t.last_word = t.last_non_space;
                t.last_non_space = i + rl;
                if (t.cur <= t.length) t.last_word = t.last_non_space;
            } else t.last_non_space = i + rl;
            if (t.cur > t.length) return if (t.last_word == 0) i else t.last_word;
            i += n;
        }
        return null;
    }
};

fn truncateHtmlAt(s: []const u8, end: usize, ellipsis: []const u8) []const u8 {
    var stack: std.ArrayList([]const u8) = .empty;
    var sc: HScanner = .{ .s = s, .pos = 0 };
    while (sc.next(end)) |t| switch (t.typ) {
        .end => {
            var k = stack.items.len;
            while (k > 0) : (k -= 1) if (v.eq(stack.items[k - 1], t.name)) {
                stack.shrinkRetainingCapacity(k - 1);
                break;
            };
        },
        .start => if (!(t.self_closing or isVoidEl(t.name))) {
            if (isRawTextEl(t.name)) sc.skipRawText(end, t.name);
            stack.append(sys.A, t.name) catch {};
        },
        else => {},
    };
    var b: v.Buf = .{};
    b.add(s[0..end]);
    b.add(ellipsis);
    var k = stack.items.len;
    while (k > 0) : (k -= 1) b.print("</{s}>", .{stack.items[k - 1]});
    return b.str();
}

/// truncate (port of Hugo 0.170 tpl/strings/truncate.go)
fn fTruncate(c: *Ctx) anyerror!Value {
    try c.need(2);
    const length: usize = @intCast(@max(try c.int(0), 0));
    var ellipsis: []const u8 = " …";
    if (c.a.len > 2) {
        ellipsis = v.toStr(c.a[1]);
        if (!(c.a[1] == .safe and c.a[1].safe.kind == .html)) ellipsis = goHtmlEscape(ellipsis);
    }
    const tv = c.last();
    const text = v.toStr(tv);
    const is_html = tv == .safe and tv.safe.kind == .html;
    if (v.runeCount(text) <= length) return v.H(if (is_html) text else goHtmlEscape(text));
    var t: Truncator = .{ .length = length };
    if (!is_html) {
        if (t.scan(text, 0, text.len)) |end| return v.H(v.concat(&.{ goHtmlEscape(text[0..end]), ellipsis }));
        return v.H(goHtmlEscape(text));
    }
    var sc: HScanner = .{ .s = text, .pos = 0 };
    while (true) {
        const text_start = sc.pos;
        const tok = sc.next(text.len);
        const text_end = if (tok) |x| x.start else text.len;
        if (t.scan(text, text_start, text_end)) |end| return v.H(truncateHtmlAt(text, end, ellipsis));
        const tk = tok orelse return v.H(text);
        t.last_word = t.last_non_space;
        if (tk.typ == .start and !tk.self_closing and isRawTextEl(tk.name)) sc.skipRawText(text.len, tk.name);
    }
}
fn fCountWords(c: *Ctx) anyerror!Value {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, v.stripTags(c.s(0)), " \t\r\n");
    while (it.next()) |_| n += 1;
    return v.I(n);
}
fn fCountRunes(c: *Ctx) anyerror!Value {
    var n: usize = 0;
    const s = v.stripTags(c.s(0));
    var i: usize = 0;
    while (i < s.len) {
        if (!(s[i] == ' ' or s[i] == '\n' or s[i] == '\t' or s[i] == '\r')) n += 1;
        i += @min(v.utf8Len(s[i]), s.len - i);
    }
    return v.I(n);
}
fn fRuneCount(c: *Ctx) anyerror!Value {
    return v.I(v.runeCount(c.s(0)));
}
fn fPlainify(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(v.stripTags(c.s(0)));
}
fn fHtmlEscape(c: *Ctx) anyerror!Value {
    try c.need(1);
    var b: v.Buf = .{};
    for (c.s(0)) |ch| switch (ch) {
        '&' => b.add("&amp;"),
        '<' => b.add("&lt;"),
        '>' => b.add("&gt;"),
        '"' => b.add("&#34;"),
        '\'' => b.add("&#39;"),
        else => b.ch(ch),
    };
    return v.S(b.str());
}
fn fHtmlUnescape(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(v.htmlUnescape(c.s(0)));
}
fn fXMLEscape(c: *Ctx) anyerror!Value {
    try c.need(1);
    var b: v.Buf = .{};
    for (c.s(0)) |ch| switch (ch) {
        '&' => b.add("&amp;"),
        '<' => b.add("&lt;"),
        '>' => b.add("&gt;"),
        '"' => b.add("&#34;"),
        '\'' => b.add("&#39;"),
        '\n' => b.add("&#xA;"),
        '\t' => b.add("&#x9;"),
        '\r' => b.add("&#xD;"),
        else => b.ch(ch),
    };
    return v.S(b.str());
}
fn fHtml(c: *Ctx) anyerror!Value {
    const r = try fHtmlEscape(c);
    return .{ .safe = .{ .kind = .escaped, .s = r.str } };
}
fn fUrlquery(c: *Ctx) anyerror!Value {
    return v.S(queryEscape(c.s(0)));
}
fn fJs(c: *Ctx) anyerror!Value {
    var b: v.Buf = .{};
    for (c.s(0)) |ch| switch (ch) {
        '\\' => b.add("\\\\"),
        '\'' => b.add("\\'"),
        '"' => b.add("\\\""),
        '<' => b.add("\\u003C"),
        '>' => b.add("\\u003E"),
        '&' => b.add("\\u0026"),
        '=' => b.add("\\u003D"),
        '\n' => b.add("\\n"),
        else => b.ch(ch),
    };
    return v.S(b.str());
}
fn safeOf(c: *Ctx, kind: v.SafeKind) anyerror!Value {
    try c.need(1);
    return .{ .safe = .{ .kind = kind, .s = c.s(0) } };
}
fn fSafeHTML(c: *Ctx) anyerror!Value {
    return safeOf(c, .html);
}
fn fSafeAttr(c: *Ctx) anyerror!Value {
    return safeOf(c, .attr);
}
fn fSafeCSS(c: *Ctx) anyerror!Value {
    return safeOf(c, .css);
}
fn fSafeJS(c: *Ctx) anyerror!Value {
    return safeOf(c, .js);
}
fn fSafeURL(c: *Ctx) anyerror!Value {
    return safeOf(c, .url);
}

fn fHumanize(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = v.trimWs(c.s(0));
    if (s.len == 0) return v.S("");
    if (std.fmt.parseInt(i64, s, 10) catch null) |n| {
        const m100 = @mod(n, 100);
        const suf = if (m100 >= 11 and m100 <= 13) "th" else switch (@mod(n, 10)) {
            1 => "st",
            2 => "nd",
            3 => "rd",
            else => "th",
        };
        return v.S(v.fmt("{d}{s}", .{ n, suf }));
    }
    var b: v.Buf = .{};
    for (s, 0..) |ch, i| {
        if (ch == '-' or ch == '_') b.ch(' ') else if (std.ascii.isUpper(ch) and i > 0 and std.ascii.isLower(s[i - 1])) {
            b.ch(' ');
            b.ch(std.ascii.toLower(ch));
        } else b.ch(if (i == 0) std.ascii.toUpper(ch) else ch);
    }
    return v.S(b.str());
}
fn fPluralize(c: *Ctx) anyerror!Value {
    try c.need(1);
    return pluralizeWord(c.s(0));
}
pub fn pluralStr(s: []const u8) []const u8 {
    return pluralizeWord(s).str;
}
fn pluralizeWord(s: []const u8) Value {
    if (s.len == 0) return v.S(s);
    const l = v.lower(s);
    const irregular = [_][2][]const u8{ .{ "person", "people" }, .{ "man", "men" }, .{ "child", "children" }, .{ "mouse", "mice" }, .{ "foot", "feet" }, .{ "tooth", "teeth" }, .{ "goose", "geese" } };
    for (irregular) |p| if (v.eq(l, p[0])) return v.S(v.concat(&.{ s[0..1], p[1][1..] }));
    for (irregular) |p| if (v.eq(l, p[1])) return v.S(s);
    if (v.endsWith(l, "s") and !v.endsWith(l, "ss") and !v.endsWith(l, "us")) return v.S(s);
    if (v.endsWith(l, "y") and s.len > 1 and v.indexOfChar("aeiou", l[l.len - 2]) == null) return v.S(v.concat(&.{ s[0 .. s.len - 1], "ies" }));
    if (v.endsWith(l, "s") or v.endsWith(l, "x") or v.endsWith(l, "z") or v.endsWith(l, "ch") or v.endsWith(l, "sh")) return v.S(v.concat(&.{ s, "es" }));
    return v.S(v.concat(&.{ s, "s" }));
}
fn fSingularize(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    const l = v.lower(s);
    if (v.eq(l, "people")) return v.S(v.concat(&.{ s[0..1], "erson" }));
    if (v.endsWith(l, "ies") and s.len > 3) return v.S(v.concat(&.{ s[0 .. s.len - 3], "y" }));
    if (v.endsWith(l, "sses") or v.endsWith(l, "xes") or v.endsWith(l, "ches") or v.endsWith(l, "shes")) return v.S(s[0 .. s.len - 2]);
    if (v.endsWith(l, "s") and !v.endsWith(l, "ss") and !v.endsWith(l, "us") and s.len > 1) return v.S(s[0 .. s.len - 1]);
    return v.S(s);
}

fn fAnchorize(c: *Ctx) anyerror!Value {
    try c.need(1);
    var b: v.Buf = .{};
    const s = v.trimWs(c.s(0));
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch < 0x80) {
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') b.ch(std.ascii.toLower(ch)) else if (ch == ' ') b.ch('-');
            i += 1;
        } else {
            const n = @min(v.utf8Len(ch), s.len - i);
            b.add(s[i .. i + n]);
            i += n;
        }
    }
    return v.S(b.str());
}
fn fUrlize(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(site.urlize(c.s(0)));
}

// ================================================================ urls

fn isAbsUrl(s: []const u8) bool {
    return v.contains(s, "://") or v.startsWith(s, "//") or v.startsWith(s, "mailto:") or v.startsWith(s, "tel:") or v.startsWith(s, "data:") or v.startsWith(s, "#");
}
fn fAbsURL(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    if (isAbsUrl(s)) return v.S(s);
    const base = std.mem.trimEnd(u8, site.S.base_url, "/");
    if (v.startsWith(s, "/")) {
        // leading slash: relative to the host root
        const host_end = if (v.indexOf(base, "://")) |p| (v.indexOfPos(base, p + 3, "/") orelse base.len) else 0;
        return v.S(v.concat(&.{ base[0..host_end], s }));
    }
    return v.S(v.concat(&.{ base, "/", s }));
}
fn fRelURL(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    if (isAbsUrl(s)) {
        // strip own base url
        const base = std.mem.trimEnd(u8, site.S.base_url, "/");
        if (base.len > 1 and v.startsWith(s, base)) {
            const rest = s[base.len..];
            return v.S(v.concat(&.{ site.S.base_path, if (rest.len == 0) "/" else rest }));
        }
        return v.S(s);
    }
    if (v.startsWith(s, "/")) return v.S(s);
    // paths.AddContextRoot: path.Join(basePath, s), keeping a trailing slash
    var np = v.pathClean(v.concat(&.{ site.S.base_path, "/", s }));
    if (!v.eq(np, "/") and v.endsWith(s, "/")) np = v.concat(&.{ np, "/" });
    if (s.len == 0 and !v.endsWith(np, "/")) np = v.concat(&.{ np, "/" });
    if (!v.startsWith(np, "/")) np = v.concat(&.{ "/", np });
    return v.S(np);
}
fn fLangURL(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    const pre = site.S.lang_prefix;
    if (pre.len == 0 or isAbsUrl(s)) return if (v.startsWith(c.name, "abs") or v.eq(c.name, "urls.AbsLangURL")) fAbsURL(c) else fRelURL(c);
    const path = v.concat(&.{ pre, "/", std.mem.trimStart(u8, s, "/") });
    if (v.startsWith(c.name, "abs") or v.eq(c.name, "urls.AbsLangURL")) return v.S(objs.absUrl(path));
    return v.S(objs.relUrl(path));
}

fn fRef(c: *Ctx) anyerror!Value {
    try c.need(2);
    const p = objs.asPage(c.a[0]) orelse pageOrHome(c);
    const target = if (c.a[1] == .map) c.a[1].map.str("path") orelse "" else c.s(1);
    return v.S(objs.refUrl(p, target, v.eq(c.name, "ref")));
}
fn fUrlParse(c: *Ctx) anyerror!Value {
    try c.need(1);
    var s = c.s(0);
    const m = v.newMap();
    m.put("__str", v.S(s));
    var frag: []const u8 = "";
    var query: []const u8 = "";
    var scheme: []const u8 = "";
    var host: []const u8 = "";
    if (v.indexOfChar(s, '#')) |h| {
        frag = s[h + 1 ..];
        s = s[0..h];
    }
    if (v.indexOfChar(s, '?')) |q| {
        query = s[q + 1 ..];
        s = s[0..q];
    }
    if (v.indexOf(s, "://")) |p| {
        scheme = s[0..p];
        s = s[p + 3 ..];
        const sl = v.indexOfChar(s, '/') orelse s.len;
        host = s[0..sl];
        s = s[sl..];
    } else if (v.startsWith(s, "//")) {
        s = s[2..];
        const sl = v.indexOfChar(s, '/') orelse s.len;
        host = s[0..sl];
        s = s[sl..];
    } else if (v.indexOfChar(s, ':')) |p| {
        if (v.indexOfChar(s[0..p], '/') == null) {
            scheme = s[0..p];
            m.put("Opaque", v.S(s[p + 1 ..]));
            s = "";
        }
    }
    m.put("Scheme", v.S(scheme));
    m.put("Host", v.S(host));
    m.put("Hostname", v.S(if (v.lastIndexOfChar(host, ':')) |p| host[0..p] else host));
    m.put("Port", v.S(if (v.lastIndexOfChar(host, ':')) |p| host[p + 1 ..] else ""));
    m.put("Path", v.S(s));
    m.put("RawQuery", v.S(query));
    m.put("Fragment", v.S(frag));
    m.put("IsAbs", v.B(scheme.len > 0));
    if (m.get("Opaque") == null) m.put("Opaque", v.S(""));
    m.put("RequestURI", v.S(if (query.len > 0) v.concat(&.{ s, "?", query }) else s));
    return v.M(m);
}
fn flatStrs(out: *std.ArrayList([]const u8), args: []Value) void {
    for (args) |a| {
        if (a == .list) flatStrs(out, a.list.items.items) else out.append(sys.A, v.toStr(a)) catch {};
    }
}
fn fJoinPath(c: *Ctx) anyerror!Value {
    var parts: std.ArrayList([]const u8) = .empty;
    flatStrs(&parts, c.a);
    if (v.eq(c.name, "urls.JoinPath")) {
        if (parts.items.len == 0) return v.S("");
        const first = parts.items[0];
        if (v.indexOf(first, "://")) |p| {
            const host_end = v.indexOfPos(first, p + 3, "/") orelse first.len;
            var rest: std.ArrayList([]const u8) = .empty;
            try rest.append(sys.A, first[host_end..]);
            try rest.appendSlice(sys.A, parts.items[1..]);
            const trailing = v.endsWith(parts.items[parts.items.len - 1], "/");
            var joined = v.pathClean(v.concat(&.{ "/", v.pathJoin(rest.items) }));
            if (trailing and !v.endsWith(joined, "/")) joined = v.concat(&.{ joined, "/" });
            return v.S(v.concat(&.{ first[0..host_end], joined }));
        }
        const trailing = v.endsWith(parts.items[parts.items.len - 1], "/");
        var joined = v.pathClean(v.pathJoin(parts.items));
        if (trailing and !v.endsWith(joined, "/")) joined = v.concat(&.{ joined, "/" });
        return v.S(joined);
    }
    return v.S(v.pathClean(v.pathJoin(parts.items)));
}
fn fPathBase(c: *Ctx) anyerror!Value {
    return v.S(v.pathBase(c.s(0)));
}
fn fPathDir(c: *Ctx) anyerror!Value {
    const d = v.pathDir(c.s(0));
    return v.S(if (d.len == 0) "." else d);
}
fn fPathExt(c: *Ctx) anyerror!Value {
    return v.S(v.pathExt(c.s(0)));
}
fn fPathClean(c: *Ctx) anyerror!Value {
    return v.S(v.pathClean(c.s(0)));
}
fn fPathBaseName(c: *Ctx) anyerror!Value {
    return v.S(v.pathStem(c.s(0)));
}
fn fPathSplit(c: *Ctx) anyerror!Value {
    const s = c.s(0);
    const m = v.newMap();
    const p = v.lastIndexOfChar(s, '/');
    m.put("Dir", v.S(if (p) |i| s[0 .. i + 1] else ""));
    m.put("File", v.S(if (p) |i| s[i + 1 ..] else s));
    return v.M(m);
}

// ================================================================ time

fn fNow(_: *Ctx) anyerror!Value {
    return .{ .time = .{ .sec = sys.nowSeconds() } };
}
fn fTime(c: *Ctx) anyerror!Value {
    try c.need(1);
    if (c.a[0] == .time) return c.a[0];
    return .{ .time = site.toTime(c.a[0]) orelse return fail("time: unable to parse date: {s}", .{c.s(0)}) };
}
fn fDateFormat(c: *Ctx) anyerror!Value {
    try c.need(2);
    const t = site.toTime(c.a[1]) orelse return fail("dateFormat: unable to parse date: {s}", .{c.s(1)});
    return v.S(tm.formatLocale(t, c.s(0), site.S.locale()));
}
fn parseDuration(s: []const u8) ?i64 {
    var total: f64 = 0;
    var i: usize = 0;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    while (i < s.len) {
        const st = i;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
        const num = std.fmt.parseFloat(f64, s[st..i]) catch return null;
        const us = i;
        while (i < s.len and !std.ascii.isDigit(s[i]) and s[i] != '.') i += 1;
        const unit = s[us..i];
        const mult: f64 = if (v.eq(unit, "ns")) 1 else if (v.eq(unit, "us") or v.eq(unit, "µs")) 1e3 else if (v.eq(unit, "ms")) 1e6 else if (v.eq(unit, "s")) 1e9 else if (v.eq(unit, "m")) 60e9 else if (v.eq(unit, "h")) 3600e9 else return null;
        total += num * mult;
    }
    return @intFromFloat(if (neg) -total else total);
}
fn fDuration(c: *Ctx) anyerror!Value {
    try c.need(2);
    const unit = c.s(0);
    const n = try c.float(1);
    const mult: f64 = if (v.startsWith(unit, "ns") or v.startsWith(unit, "nano")) 1 else if (v.startsWith(unit, "us") or v.startsWith(unit, "micro")) 1e3 else if (v.startsWith(unit, "ms") or v.startsWith(unit, "milli")) 1e6 else if (v.startsWith(unit, "s")) 1e9 else if (v.startsWith(unit, "m")) 60e9 else if (v.startsWith(unit, "h")) 3600e9 else return fail("duration: unknown unit {s}", .{unit});
    return .{ .dur = @intFromFloat(n * mult) };
}
fn fParseDuration(c: *Ctx) anyerror!Value {
    return .{ .dur = parseDuration(c.s(0)) orelse return fail("time.ParseDuration: invalid duration {s}", .{c.s(0)}) };
}

// ================================================================ encoding / hashing

fn fJsonify(c: *Ctx) anyerror!Value {
    try c.need(1);
    var o: data.JsonOpts = .{};
    if (c.a.len > 1 and c.a[0] == .map) {
        o.indent = c.a[0].map.str("indent") orelse "";
        o.prefix = c.a[0].map.str("prefix") orelse "";
        o.html_escape = !c.a[0].map.boolean("noHTMLEscape", false);
    }
    var b: v.Buf = .{};
    data.toJson(&b, c.last(), o, 0);
    return v.H(b.str());
}
fn fUnmarshal(c: *Ctx) anyerror!Value {
    try c.need(1);
    const x = c.last();
    var src: []const u8 = undefined;
    var ext: []const u8 = "";
    if (objs.asRes(x)) |r| {
        src = objs.resContent(r);
        ext = v.pathExt(r.name);
    } else src = v.toStr(x);
    var delim: u8 = ',';
    if (c.a.len > 1 and c.a[0] == .map) {
        if (c.a[0].map.str("delimiter")) |d| if (d.len > 0) {
            delim = d[0];
        };
        if (c.a[0].map.str("format")) |fm| ext = v.concat(&.{ ".", v.lower(fm) });
    }
    if (v.eqi(ext, ".csv")) return data.parseCsv(src, delim);
    if (ext.len > 0) return data.parseByExt(ext, src) catch fail("unmarshal: {s}", .{data.err_msg});
    if (v.startsWith(v.trimWs(src), "<")) return data.parseXml(src) catch fail("unmarshal: {s}", .{data.err_msg});
    return data.parseAuto(src) catch fail("unmarshal: {s}", .{data.err_msg});
}
fn fBase64Encode(c: *Ctx) anyerror!Value {
    const s = c.s(0);
    const enc = std.base64.standard.Encoder;
    const out = try sys.A.alloc(u8, enc.calcSize(s.len));
    return v.S(enc.encode(out, s));
}
fn fBase64Decode(c: *Ctx) anyerror!Value {
    const s = c.s(0);
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return fail("base64Decode: illegal base64 data", .{});
    const out = try sys.A.alloc(u8, n);
    dec.decode(out, s) catch return fail("base64Decode: illegal base64 data", .{});
    return v.S(out);
}
fn fMd5(c: *Ctx) anyerror!Value {
    return v.S(md5hex(c.s(0)));
}
fn fSha1(c: *Ctx) anyerror!Value {
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(c.s(0), &out, .{});
    return v.S(hex(&out));
}
fn fSha256(c: *Ctx) anyerror!Value {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(c.s(0), &out, .{});
    return v.S(hex(&out));
}
fn fFnv32a(c: *Ctx) anyerror!Value {
    var h: u32 = 2166136261;
    for (c.s(0)) |b| {
        h ^= b;
        h *%= 16777619;
    }
    return v.I(h);
}
fn fXxHash(c: *Ctx) anyerror!Value {
    return v.S(v.fmt("{x:0>16}", .{std.hash.XxHash64.hash(0, c.s(0))}));
}

// ================================================================ os

fn fGetenv(c: *Ctx) anyerror!Value {
    return v.S(sys.getenv(c.s(0)) orelse "");
}
fn projPath(p: []const u8) []const u8 {
    return v.pathJoin(&.{ site.S.opt.root, p });
}
fn fFileExists(c: *Ctx) anyerror!Value {
    const p = c.s(0);
    if (sys.exists(projPath(p))) return v.B(true);
    for (site.S.components) |comp| if (sys.exists(v.pathJoin(&.{ comp, p }))) return v.B(true);
    return v.B(false);
}
fn fReadFile(c: *Ctx) anyerror!Value {
    const p = c.s(0);
    if (sys.readFile(projPath(p))) |s| return v.S(s);
    for (site.S.components) |comp| if (sys.readFile(v.pathJoin(&.{ comp, p }))) |s| return v.S(s);
    return fail("readFile: file \"{s}\" does not exist", .{p});
}
fn fReadDir(c: *Ctx) anyerror!Value {
    const n = v.newList();
    for (sys.listDir(projPath(c.s(0)))) |e| {
        const m = v.newMap();
        m.put("Name", v.S(e.name));
        m.put("IsDir", v.B(e.is_dir));
        const st = sys.stat(v.pathJoin(&.{ projPath(c.s(0)), e.name }));
        m.put("Size", v.I(if (st) |x| x.size else 0));
        m.put("ModTime", .{ .time = .{ .sec = if (st) |x| x.mtime else 0 } });
        v.push(n, v.M(m));
    }
    return v.L(n);
}

// ================================================================ transform

fn fMarkdownify(c: *Ctx) anyerror!Value {
    try c.need(1);
    const r = try objs.renderMarkdown(pageOrHome(c), v.toStr(c.last()), false);
    var html = v.trimWs(r.html);
    if (v.startsWith(html, "<p>") and v.endsWith(html, "</p>") and v.indexOfPos(html, 3, "<p>") == null) html = html[3 .. html.len - 4];
    return v.H(html);
}
fn fHighlight(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.H(@import("highlight.zig").highlight(c.s(0), if (c.a.len > 1) c.s(1) else "", if (c.a.len > 2) c.a[2] else .nil));
}
/// transform.ToMath: Hugo renders TeX to MathML with an embedded KaTeX. ZSSG runs the
/// same KaTeX library through Node.js when it is installed (npm i katex, locally or
/// globally); otherwise it emits the TeX source for client-side rendering.
const katex_js =
    \\const expr = process.argv[1], opts = JSON.parse(process.argv[2]);
    \\let katex;
    \\const tries = [process.cwd() + '/node_modules/katex', 'katex'];
    \\for (const p of (process.env.NODE_PATH || '').split(':')) if (p) tries.push(p + '/katex');
    \\for (const p of ['/usr/local/lib/node_modules', '/usr/lib/node_modules', '/opt/homebrew/lib/node_modules', (process.env.HOME || '') + '/.npm-global/lib/node_modules', '/opt/npm-tools/node_modules']) tries.push(p + '/katex');
    \\for (const t of tries) { try { katex = require(t); break; } catch (e) {} }
    \\if (!katex) { process.stdout.write(JSON.stringify({ nokatex: true })); process.exit(0); }
    \\const warnings = [];
    \\if (opts.strict === 'warn') opts.strict = (code, msg) => { warnings.push(msg); return 'ignore'; };
    \\try { process.stdout.write(JSON.stringify({ output: katex.renderToString(expr, opts), warnings })); }
    \\catch (e) { process.stdout.write(JSON.stringify({ error: e.message })); }
;
var katex_cache: std.StringHashMapUnmanaged([]const u8) = .empty;
var katex_missing = false;

fn fToMath(c: *Ctx) anyerror!Value {
    try c.need(1);
    const expr = c.s(0);
    // Hugo's defaults, then user options (keys are case-insensitive)
    const opts = v.newMap();
    opts.put("output", v.S("mathml"));
    opts.put("minRuleThickness", .{ .float = 0.04 });
    opts.put("errorColor", v.S("#cc0000"));
    opts.put("throwOnError", v.B(true));
    opts.put("strict", v.S("error"));
    const names = [_][]const u8{ "displayMode", "output", "leqno", "fleqn", "throwOnError", "errorColor", "macros", "minRuleThickness", "strict", "trust", "maxSize", "maxExpand", "globalGroup" };
    if (c.a.len > 1 and c.a[1] == .map) {
        var it = c.a[1].map.m.iterator();
        while (it.next()) |e| {
            for (names) |n| if (std.ascii.eqlIgnoreCase(n, e.key_ptr.*)) opts.put(n, e.value_ptr.*);
        }
    }
    const strict = v.toStr(opts.get("strict") orelse v.S("error"));
    if (!v.eq(strict, "error") and !v.eq(strict, "ignore") and !v.eq(strict, "warn"))
        return site.fatal("invalid strict mode; expected one of error, ignore, or warn; received {s}", .{strict});
    var ob: v.Buf = .{};
    data.toJson(&ob, v.M(opts), .{ .html_escape = false }, 0);
    const key = v.concat(&.{ expr, "\x00", ob.str() });
    if (katex_cache.get(key)) |o| return v.H(o);
    if (!katex_missing) {
        if (sys.run(&.{ "node", "-e", katex_js, expr, ob.str() })) |r| {
            if (r.ok) {
                const res = data.parseJson(r.stdout) catch Value.nil;
                if (res == .map) {
                    if (res.map.get("output")) |o| {
                        if (res.map.get("warnings")) |w| if (w == .list) for (w.list.items.items) |msg| site.warn("transform.ToMath: {s}", .{v.toStr(msg)});
                        const out = v.toStr(o);
                        katex_cache.put(sys.A, key, out) catch {};
                        return v.H(out);
                    }
                    if (res.map.get("error")) |e| return site.fatal("transform.ToMath: {s}", .{v.toStr(e)});
                }
            }
        }
        katex_missing = true;
        site.warn("transform.ToMath: KaTeX is not available (install Node.js and `npm install katex`); emitting TeX source for client-side rendering", .{});
    }
    const display = if (opts.get("displayMode")) |dm| v.truth(dm) else false;
    const tex = v.htmlEscape(v.trimWs(expr));
    return v.H(if (display) v.concat(&.{ "<span class=\"katex-display\">\\[", tex, "\\]</span>" }) else v.concat(&.{ "<span class=\"katex\">\\(", tex, "\\)</span>" }));
}

fn fEmojify(c: *Ctx) anyerror!Value {
    return v.H(c.s(0));
}
fn fIdentity(c: *Ctx) anyerror!Value {
    return c.last();
}

// ================================================================ i18n

fn fI18n(c: *Ctx) anyerror!Value {
    try c.need(1);
    const key = c.s(0);
    const s = site.S;
    var entry: ?Value = null;
    for ([_][]const u8{ v.lower(s.lang), v.lower(s.cfg.str("defaultContentLanguage") orelse "en"), "en" }) |lg| {
        if (s.i18n.map(lg)) |m| if (m.get(key)) |x| {
            entry = x;
            break;
        };
        // "en-us" falls back to "en"
        if (v.indexOfChar(lg, '-')) |d| if (s.i18n.map(lg[0..d])) |m| if (m.get(key)) |x| {
            entry = x;
            break;
        };
    }
    const e = entry orelse return v.S("");
    var text: []const u8 = "";
    var arg: Value = if (c.a.len > 1) c.a[1] else .nil;
    switch (e) {
        .map => |m| {
            var count: ?i64 = null;
            if (v.isNum(arg)) count = v.toInt(arg) else if (arg == .map) {
                if (arg.map.getCI("count")) |cv| count = v.toInt(cv);
            }
            const form = if (count) |n| (if (n == 1) "one" else if (n == 0 and m.str("zero") != null) "zero" else "other") else "other";
            text = m.str(form) orelse m.str("other") orelse m.str("one") orelse "";
            if (v.isNum(arg)) {
                const cm = v.newMap();
                cm.put("Count", arg);
                arg = v.M(cm);
            }
        },
        else => text = v.toStr(e),
    }
    if (v.contains(text, "{{")) {
        const t = tmpl.parse(v.concat(&.{ "i18n:", key }), text) catch return v.S(text);
        var out: tmpl.Out = .{ .raw_mode = true };
        var sub: tmpl.Exec = .{ .out = &out, .tmpl = t, .page = c.ex.page };
        try sub.run(arg);
        return v.S(out.str());
    }
    return v.S(text);
}

fn groupDigits(int_part: []const u8, sep: []const u8) []const u8 {
    var b: v.Buf = .{};
    for (int_part, 0..) |ch, i| {
        if (i > 0 and (int_part.len - i) % 3 == 0) b.add(sep);
        b.ch(ch);
    }
    return b.str();
}
fn fFormatNumber(c: *Ctx) anyerror!Value {
    try c.need(2);
    const prec: usize = @intCast(@max(try c.int(0), 0));
    const x = try c.float(1);
    var neg: []const u8 = "-";
    var dec: []const u8 = ".";
    var grp: []const u8 = ",";
    if (v.eq(c.name, "lang.FormatNumberCustom") and c.a.len > 2) {
        const opts = c.s(2);
        const delim = if (c.a.len > 3) c.s(3) else " ";
        var it = std.mem.splitSequence(u8, opts, delim);
        if (it.next()) |n| neg = n;
        if (it.next()) |d| dec = d;
        grp = it.next() orelse "";
    }
    const fixed = fmtFixed(@abs(x), prec);
    const dot = v.indexOfChar(fixed, '.') orelse fixed.len;
    var b: v.Buf = .{};
    if (x < 0) b.add(neg);
    b.add(groupDigits(fixed[0..dot], grp));
    if (dot < fixed.len) {
        b.add(dec);
        b.add(fixed[dot + 1 ..]);
    }
    if (v.eq(c.name, "lang.FormatPercent")) b.ch('%');
    return v.S(b.str());
}

// ================================================================ resources

fn findAsset(name: []const u8) ?[]const u8 {
    const dir = site.S.cfg.str("assetDir") orelse "assets";
    return site.findFile(dir, std.mem.trimStart(u8, name, "/"));
}

fn fResGet(c: *Ctx) anyerror!Value {
    try c.need(1);
    const name = v.pathClean(std.mem.trimStart(u8, c.s(0), "/"));
    if (site.S.res_cache.get(name)) |r| return objs.resVal(r);
    const path = findAsset(name) orelse return .nil;
    const r = objs.newResource(name, null, path);
    try site.S.res_cache.put(sys.A, name, r);
    return objs.resVal(r);
}

fn allAssets() [][]const u8 {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    const dir = site.S.cfg.str("assetDir") orelse "assets";
    for (site.S.components) |comp| {
        for (sys.walk(v.pathJoin(&.{ comp, dir }))) |rel| seen.put(sys.A, rel, {}) catch {};
    }
    return seen.keys();
}

fn fResMatch(c: *Ctx) anyerror!Value {
    try c.need(1);
    const pat = std.mem.trimStart(u8, c.s(0), "/");
    const n = v.newList();
    const first_only = v.eq(c.name, "resources.GetMatch");
    for (allAssets()) |rel| {
        if (!objs.glob(pat, rel)) continue;
        var cc: Ctx = .{ .ex = c.ex, .a = @constCast(&[_]Value{v.S(rel)}), .dot = c.dot, .name = "resources.Get" };
        const r = try fResGet(&cc);
        if (first_only) return r;
        v.push(n, r);
    }
    if (first_only) return .nil;
    return v.L(n);
}

fn fResByType(c: *Ctx) anyerror!Value {
    try c.need(1);
    const want = c.s(0);
    const n = v.newList();
    for (allAssets()) |rel| {
        const mt = objs.mediaTypeOf(rel);
        if (!(v.startsWith(mt, want) and mt.len > want.len and mt[want.len] == '/')) continue;
        var cc: Ctx = .{ .ex = c.ex, .a = @constCast(&[_]Value{v.S(rel)}), .dot = c.dot, .name = "resources.Get" };
        v.push(n, try fResGet(&cc));
    }
    return v.L(n);
}

fn resArg(c: *Ctx) anyerror!*site.Resource {
    return objs.asRes(c.last()) orelse fail("{s}: expected a resource, got {s} (is the asset path correct?)", .{ c.name, if (c.last() == .nil) "nil" else @tagName(c.last()) });
}

fn derive(r: *site.Resource, target: []const u8, content: []const u8) *site.Resource {
    const n = objs.newResource(target, content, null);
    n.title = r.title;
    n.params = r.params;
    n.data = r.data;
    return n;
}

fn fFromString(c: *Ctx) anyerror!Value {
    try c.need(2);
    return objs.resVal(objs.newResource(c.s(0), c.s(1), null));
}

fn fConcat(c: *Ctx) anyerror!Value {
    try c.need(2);
    const l = asList(c.a[1]) orelse return fail("resources.Concat: expected a slice of resources", .{});
    var b: v.Buf = .{};
    var mt: []const u8 = "";
    for (l, 0..) |x, i| {
        const r = objs.asRes(x) orelse return fail("resources.Concat: slice contains a non-resource value (nil?)", .{});
        if (i > 0 and !v.eq(r.media, mt)) return fail("resources in Concat must be of the same Media Type, got \"{s}\" and \"{s}\"", .{ r.media, mt });
        mt = r.media;
    }
    // JavaScript files get a barrier between them, like Hugo
    const js = v.eq(mt, "text/javascript");
    for (l, 0..) |x, i| {
        if (i > 0 and js) b.add("\n;\n");
        b.add(objs.resContent(objs.asRes(x).?));
    }
    const n = objs.newResource(v.pathClean(c.s(0)), b.str(), null);
    return objs.resVal(n);
}

fn fExecAsTemplate(c: *Ctx) anyerror!Value {
    try c.need(3);
    const r = try resArg(c);
    const t = tmpl.parse(r.name, objs.resContent(r)) catch return fail("resources.ExecuteAsTemplate: {s}", .{tmpl.err_msg});
    var out: tmpl.Out = .{ .raw_mode = true };
    var sub: tmpl.Exec = .{ .out = &out, .tmpl = t, .page = c.ex.page };
    try sub.run(c.a[1]);
    return objs.resVal(derive(r, c.s(0), out.str()));
}

fn fMinify(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    var content = objs.resContent(r);
    if (@import("min.zig").minifyByMime(r.media, content)) |out| {
        content = out;
    } else if (v.eq(r.media, "application/json")) {
        if (data.parseJson(content)) |val| {
            var b: v.Buf = .{};
            data.toJson(&b, val, .{ .html_escape = false }, 0);
            content = b.str();
        } else |_| {}
    } else if (v.eq(r.media, "text/javascript")) {
        // conservative: only trim surrounding whitespace on lines
        var b: v.Buf = .{};
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |ln| {
            const t = v.trimWs(ln);
            if (t.len == 0) continue;
            b.add(t);
            b.ch('\n');
        }
        content = b.str();
    }
    const ext = v.pathExt(r.target);
    const base = r.target[0 .. r.target.len - ext.len];
    const target = if (v.endsWith(base, ".min")) r.target else v.concat(&.{ base, ".min", ext });
    return objs.resVal(derive(r, target, content));
}

fn fFingerprint(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    const algo = if (c.a.len > 1) v.lower(c.s(0)) else "sha256";
    const content = objs.resContent(r);
    var digest: []const u8 = undefined;
    if (v.eq(algo, "md5")) {
        var out: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(content, &out, .{});
        digest = v.dup(&out);
    } else if (v.eq(algo, "sha384")) {
        var out: [48]u8 = undefined;
        std.crypto.hash.sha2.Sha384.hash(content, &out, .{});
        digest = v.dup(&out);
    } else if (v.eq(algo, "sha512")) {
        var out: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(content, &out, .{});
        digest = v.dup(&out);
    } else {
        var out: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &out, .{});
        digest = v.dup(&out);
    }
    const ext = v.pathExt(r.target);
    const target = v.fmt("{s}.{s}{s}", .{ r.target[0 .. r.target.len - ext.len], hex(digest), ext });
    const n = derive(r, target, content);
    const enc = std.base64.standard.Encoder;
    const b64 = try sys.A.alloc(u8, enc.calcSize(digest.len));
    n.integrity = v.fmt("{s}-{s}", .{ if (v.eq(algo, "md5") or v.eq(algo, "sha384") or v.eq(algo, "sha512")) algo else "sha256", enc.encode(b64, digest) });
    return objs.resVal(n);
}

fn inlineCssImports(content: []const u8, dir: []const u8, depth: usize) []const u8 {
    if (depth > 8 or !v.contains(content, "@import")) return content;
    var b: v.Buf = .{};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |ln| {
        const t = v.trimWs(ln);
        if (v.startsWith(t, "@import") and !v.contains(t, "url(") and !v.contains(t, "://")) {
            const q1 = v.indexOfAny(t, "\"'");
            if (q1) |a| if (v.indexOfAny(t[a + 1 ..], "\"'")) |blen| {
                const rel = t[a + 1 .. a + 1 + blen];
                const full = v.pathClean(v.pathJoin(&.{ dir, rel }));
                if (findAsset(full)) |path| if (sys.readFile(path)) |sub_src| {
                    b.add(inlineCssImports(sub_src, v.pathDir(full), depth + 1));
                    b.ch('\n');
                    continue;
                };
            };
        }
        b.add(ln);
        b.ch('\n');
    }
    return b.str();
}

fn fCssBuild(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    var opts: ?*Map = null;
    if (c.a.len > 1 and c.a[0] == .map) opts = c.a[0].map;
    return esbuildRes(c, r, opts, true);
}

var sass_bin: ?[]const u8 = null;
var sass_checked = false;

fn fToCSS(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    var opts: ?*Map = null;
    if (c.a.len > 1 and c.a[0] == .map) opts = c.a[0].map;
    const ext = v.pathExt(r.target);
    var target = v.concat(&.{ r.target[0 .. r.target.len - ext.len], ".css" });
    if (opts) |o| if (o.str("targetPath")) |tp| {
        target = tp;
    };
    if (v.eq(ext, ".css")) return objs.resVal(derive(r, target, objs.resContent(r)));
    if (opts) |o| if (o.str("transpiler")) |t| if (v.eqi(t, "libsass")) return fail("css.Sass: the libsass transpiler was removed in Hugo v0.170.0; use Dart Sass (transpiler = \"dartsass\")", .{});
    if (!sass_checked) {
        sass_checked = true;
        for ([_][]const u8{ "sass", "dart-sass" }) |bin| {
            if (sys.run(&.{ bin, "--version" })) |res| if (res.ok) {
                sass_bin = bin;
                break;
            };
        }
    }
    const bin = sass_bin orelse return fail("css.Sass: Dart Sass executable (\"sass\") not found in PATH; install it to transpile {s} (https://sass-lang.com/install)", .{r.name});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(sys.A, bin);
    try argv.append(sys.A, "--no-source-map");
    const style = if (opts) |o| o.str("outputStyle") orelse "expanded" else "expanded";
    try argv.append(sys.A, v.concat(&.{ "--style=", if (v.eq(style, "compressed")) "compressed" else "expanded" }));
    const adir = site.S.cfg.str("assetDir") orelse "assets";
    for (site.S.components) |comp| {
        try argv.append(sys.A, v.concat(&.{ "--load-path=", v.pathJoin(&.{ comp, adir }) }));
        try argv.append(sys.A, v.concat(&.{ "--load-path=", v.pathJoin(&.{ comp, adir, v.pathDir(std.mem.trimStart(u8, r.name, "/")) }) }));
    }
    if (opts) |o| if (o.list("includePaths")) |ips| for (ips.items.items) |ip| {
        for (site.S.components) |comp| try argv.append(sys.A, v.concat(&.{ "--load-path=", v.pathJoin(&.{ comp, v.toStr(ip) }) }));
    };
    var src = r.src_path;
    var tmp: ?[]const u8 = null;
    if (src == null or (opts != null and opts.?.map("vars") != null)) {
        var content: v.Buf = .{};
        if (opts) |o| if (o.map("vars")) |vars| for (vars.m.keys(), vars.m.values()) |k, x| content.print("${s}: {s};\n", .{ k, v.toStr(x) });
        content.add(objs.resContent(r));
        tmp = v.pathJoin(&.{ site.S.dest, v.fmt(".zssg-sass-{d}{s}", .{ sys.nowMillis(), ext }) });
        try sys.writeFile(tmp.?, content.str());
        src = tmp;
    }
    try argv.append(sys.A, src.?);
    const res = sys.run(argv.items) orelse return fail("css.Sass: failed to run {s}", .{bin});
    if (tmp) |t| sys.removeTree(t);
    if (!res.ok) return fail("css.Sass: {s}: {s}", .{ r.name, v.trimWs(res.stderr) });
    return objs.resVal(derive(r, target, res.stdout));
}

// ---------------------------------------------------------------- Node.js tools

const NodeRun = struct { ok: bool, not_found: bool, stdout: []const u8, stderr: []const u8 };

/// Runs a Node.js CLI like Hugo's hexec.Npx: node_modules/.bin first, then PATH,
/// in the project directory with Hugo's environment, feeding `input` on stdin.
fn reSearch(pat: []const u8, s: []const u8) bool {
    const re2 = @import("regex2.zig");
    const re = re2.compile(pat) catch return false;
    const caps = sys.A.alloc(isize, (re.ncap + 1) * 2) catch return false;
    var pos: usize = 0;
    while (pos <= s.len) : (pos += 1) {
        if (re2.matchAt(re, s, pos, caps) != null) return true;
    }
    return false;
}

/// Hugo's security.exec.allow whitelist (patterns starting with "! " deny).
pub fn execAllowed(name: []const u8) bool {
    const defaults = [_][]const u8{ "^(dart-)?sass$", "^go$", "^git$", "^node$", "^postcss$" };
    var pats: std.ArrayList([]const u8) = .empty;
    var configured = false;
    if (site.S.cfg.map("security")) |sec| if (sec.map("exec")) |ex| if (ex.getCI("allow")) |al| {
        configured = true;
        switch (al) {
            .list => |l| for (l.items.items) |x| pats.append(sys.A, v.toStr(x)) catch {},
            else => pats.append(sys.A, v.toStr(al)) catch {},
        }
    };
    if (!configured) pats.appendSlice(sys.A, &defaults) catch {};
    for (pats.items) |p| if (v.startsWith(p, "! ") and reSearch(p[2..], name)) return false;
    for (pats.items) |p| if (!v.startsWith(p, "! ") and reSearch(p, name)) return true;
    return false;
}

fn runNodeTool(name: []const u8, args: []const []const u8, input: []const u8) NodeRun {
    const work = sys.absNoResolve(site.S.opt.root);
    const dest = sys.absNoResolve(site.S.dest);
    sys.mkdirAll(dest);
    const tmp = v.pathJoin(&.{ sys.tmpDir(), v.fmt("zssg-{s}-{d}-{d}.in", .{ name, sys.pid(), sys.nowMillis() }) });
    sys.writeFile(tmp, input) catch return .{ .ok = false, .not_found = false, .stdout = "", .stderr = "failed to write temporary file" };
    defer sys.removeTree(tmp);
    const local = v.pathJoin(&.{ work, "node_modules", ".bin", name });
    const bin = if (sys.exists(local)) local else name;
    var argv: std.ArrayList([]const u8) = .empty;
    const script =
        \\cd "$1" || exit 1; f="$2"; export HUGO_ENVIRONMENT="$3" HUGO_ENV="$3" HUGO_PUBLISHDIR="$4" PWD="$1"
        \\export NODE_PATH="$1/node_modules${NODE_PATH:+:$NODE_PATH}"; shift 4
        \\command -v "$1" >/dev/null 2>&1 || exit 127
        \\exec "$@" < "$f"
    ;
    argv.appendSlice(sys.A, &.{ "sh", "-c", script, "sh", work, tmp, site.S.opt.env, dest, bin }) catch {};
    argv.appendSlice(sys.A, args) catch {};
    const r = sys.runCode(argv.items) orelse return .{ .ok = false, .not_found = true, .stdout = "", .stderr = "" };
    return .{ .ok = r.code == 0, .not_found = r.code == 127, .stdout = r.stdout, .stderr = r.stderr };
}

/// Renders AsciiDoc / Pandoc / reStructuredText / Org content with the external
/// helper Hugo uses (asciidoctor, pandoc, rst2html; Org via pandoc).
pub fn renderExternal(p: *site.Page, src: []const u8) anyerror![]const u8 {
    const doc = p.file_abs;
    var bin: []const u8 = "";
    var args: std.ArrayList([]const u8) = .empty;
    const mk = p.ext_markup;
    if (v.eq(mk, "asciidocext")) {
        bin = "asciidoctor";
        var cfgm: ?*Map = null;
        if (site.S.cfg.map("markup")) |m| cfgm = m.map("asciidocExt") orelse m.map("asciidocext");
        const backend = if (cfgm) |c| c.str("backend") orelse "html5" else "html5";
        if (!v.eq(backend, "html5")) try args.appendSlice(sys.A, &.{ "-b", backend });
        if (cfgm) |c| {
            if (c.list("extensions")) |exts| for (exts.items.items) |e| {
                const es = v.toStr(e);
                if (std.mem.lastIndexOfAny(u8, es, "\\/.") != null) {
                    site.errorf("The \"{s}\" Asciidoctor extension is unsupported and ignored. Only installed Asciidoctor extensions are allowed.", .{es});
                    continue;
                }
                try args.appendSlice(sys.A, &.{ "-r", es });
            };
            if (c.map("attributes")) |am| for (am.m.keys(), am.m.values()) |k, x| {
                if (v.eq(k, "outdir")) continue;
                if (x == .bool) {
                    try args.appendSlice(sys.A, &.{ "-a", if (x.bool) k else v.concat(&.{ "'!", k, "'" }) });
                } else try args.appendSlice(sys.A, &.{ "-a", v.concat(&.{ k, "=", v.toStr(x) }) });
            };
        }
        const nohf = if (cfgm) |c| c.boolean("noHeaderOrFooter", true) else true;
        if (nohf) try args.append(sys.A, "--no-header-footer") else site.warn("Asciidoctor parameter NoHeaderOrFooter is required for correct HTML rendering", .{});
        if (cfgm) |c| {
            if (c.boolean("sectionNumbers", false)) try args.append(sys.A, "--section-numbers");
            if (c.boolean("verbose", false)) try args.append(sys.A, "--verbose");
            if (c.boolean("trace", false)) try args.append(sys.A, "--trace");
            const fl = c.str("failureLevel") orelse "fatal";
            if (!v.eq(fl, "fatal")) try args.appendSlice(sys.A, &.{ "--failure-level", fl });
            const sm = c.str("safeMode") orelse "unsafe";
            if (!v.eq(sm, "unsafe")) try args.appendSlice(sys.A, &.{ "--safe-mode", sm });
        }
        try args.append(sys.A, "-");
    } else if (v.eq(mk, "pandoc") or v.eq(mk, "org")) {
        bin = "pandoc";
        if (v.eq(mk, "org")) try args.appendSlice(sys.A, &.{ "-f", "org" });
        try args.appendSlice(sys.A, &.{ "--mathjax", "--citeproc" });
    } else if (v.eq(mk, "rst")) {
        bin = if (sys.runCode(&.{ "sh", "-c", "command -v rst2html" })) |r| (if (r.code == 0) "rst2html" else "rst2html.py") else "rst2html";
        try args.appendSlice(sys.A, &.{ "--leave-comments", "--initial-header-level=2" });
    }
    if (!v.eq(mk, "org") and !execAllowed(bin)) return site.fatal("\"{s}:1:1\": access denied: \"{s}\" is not whitelisted in policy \"security.exec.allow\"", .{ doc, bin });
    if (v.eq(mk, "org") and !execAllowed("pandoc")) return site.fatal("\"{s}:1:1\": Org content needs pandoc in ZSSG (Hugo uses its built-in go-org); allow it with security.exec.allow", .{doc});
    const res = runNodeTool(bin, args.items, src);
    if (res.not_found) return site.fatal("{s} not found in $PATH, cannot render \"{s}\"", .{ bin, p.file orelse doc });
    var it = std.mem.splitScalar(u8, res.stderr, '\n');
    while (it.next()) |ln| {
        const t = v.trimWs(ln);
        if (t.len == 0) continue;
        if (res.ok) site.warn("{s}: {s}", .{ p.file orelse doc, t }) else site.errorf("{s}: {s}", .{ p.file orelse doc, t });
    }
    var out = std.mem.replaceOwned(u8, sys.A, res.stdout, "\r", "") catch res.stdout;
    if (v.eq(mk, "rst")) {
        var bs: usize = 0;
        if (v.indexOf(out, "<body>\n")) |i| bs = i + 7;
        var be: usize = if (out.len > 0) out.len - 1 else 0;
        if (v.indexOf(out, "\n</body>")) |i| be = i;
        if (bs <= be) out = out[bs..be];
    }
    if (v.eq(mk, "asciidocext")) out = asciidocToc(p, out);
    if (v.eq(mk, "org")) site.warn("Org content is rendered with pandoc in ZSSG; Hugo uses go-org, so the HTML may differ", .{});
    return out;
}

/// Removes Asciidoctor's <div id="toc"> (unless preserveTOC) and turns it into .TableOfContents.
fn asciidocToc(p: *site.Page, html: []const u8) []const u8 {
    const start = v.indexOf(html, "<div id=\"toc\"") orelse v.indexOf(html, "<nav id=\"toc\"") orelse return html;
    const tag: []const u8 = if (v.startsWith(html[start..], "<div")) "div" else "nav";
    // find the matching close tag
    var depth: usize = 0;
    var i = start;
    var end: usize = html.len;
    while (i < html.len) {
        const lt = v.indexOfPos(html, i, "<") orelse break;
        if (v.startsWith(html[lt..], v.concat(&.{ "</", tag, ">" }))) {
            depth -= 1;
            if (depth == 0) {
                end = lt + tag.len + 3;
                break;
            }
            i = lt + 1;
        } else if (v.startsWith(html[lt..], v.concat(&.{ "<", tag })) and lt + tag.len + 1 < html.len and (html[lt + tag.len + 1] == ' ' or html[lt + tag.len + 1] == '>')) {
            depth += 1;
            i = lt + 1;
        } else i = lt + 1;
    }
    const block = html[start..end];
    // headings from the TOC lists: level = <ul> nesting depth + 1
    var hs: std.ArrayList(md.Heading) = .empty;
    var lvl: u8 = 0;
    var k: usize = 0;
    while (k < block.len) {
        if (v.startsWith(block[k..], "<ul") or v.startsWith(block[k..], "<ol")) {
            lvl += 1;
            k += 3;
        } else if (v.startsWith(block[k..], "</ul>") or v.startsWith(block[k..], "</ol>")) {
            if (lvl > 0) lvl -= 1;
            k += 5;
        } else if (v.startsWith(block[k..], "<a href=\"#")) {
            const q = k + 10;
            const qe = v.indexOfPos(block, q, "\"") orelse break;
            const gt = v.indexOfPos(block, qe, ">") orelse break;
            const ae = v.indexOfPos(block, gt, "</a>") orelse break;
            hs.append(sys.A, .{ .level = lvl + 1, .id = block[q..qe], .html = block[gt + 1 .. ae], .plain = block[gt + 1 .. ae] }) catch {};
            k = ae + 4;
        } else k += 1;
    }
    p.headings = hs.items;
    var s0: i32 = 2;
    var e0: i32 = 3;
    var ordered = false;
    if (site.S.cfg.map("markup")) |mk| if (mk.map("tableOfContents")) |tc| {
        s0 = @intCast(tc.int("startLevel", 2));
        e0 = @intCast(tc.int("endLevel", 3));
        ordered = tc.boolean("ordered", false);
    };
    p.toc = md.toc(hs.items, s0, e0, ordered);
    var preserve = false;
    if (site.S.cfg.map("markup")) |m| if (m.map("asciidocExt") orelse m.map("asciidocext")) |c| {
        preserve = c.boolean("preserveTOC", false);
    };
    if (preserve) return html;
    return v.concat(&.{ html[0..start], html[end..] });
}

fn jsConfigFile(names: []const []const u8) ?[]const u8 {
    const work = sys.absNoResolve(site.S.opt.root);
    for (names) |n| {
        const p = v.pathJoin(&.{ work, n });
        if (sys.exists(p)) return p;
    }
    return null;
}

fn optMap(c: *Ctx) ?*Map {
    if (c.a.len > 1 and c.a[0] == .map) return c.a[0].map;
    return null;
}

fn fPostCSS(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    const o = optMap(c);
    var args: std.ArrayList([]const u8) = .empty;
    var cfg: ?[]const u8 = null;
    if (o) |m| if (m.str("config")) |cf| {
        cfg = if (std.fs.path.isAbsolute(cf)) cf else jsConfigFile(&.{cf}) orelse return fail("postcss config \"{s}\" not found", .{cf});
    };
    if (cfg == null) cfg = jsConfigFile(&.{ "postcss.config.js", "postcss.config.mjs", "postcss.config.cjs" });
    if (cfg) |cf| try args.appendSlice(sys.A, &.{ "--config", cf });
    if (o) |m| {
        if (m.boolean("noMap", false)) try args.append(sys.A, "--no-map");
        if (m.str("use")) |u| if (u.len > 0) {
            try args.append(sys.A, "--use");
            var it = std.mem.tokenizeAny(u8, u, " \t\n");
            while (it.next()) |w| try args.append(sys.A, w);
        };
        if (m.str("parser")) |x| if (x.len > 0) try args.appendSlice(sys.A, &.{ "--parser", x });
        if (m.str("stringifier")) |x| if (x.len > 0) try args.appendSlice(sys.A, &.{ "--stringifier", x });
        if (m.str("syntax")) |x| if (x.len > 0) try args.appendSlice(sys.A, &.{ "--syntax", x });
    }
    var input = objs.resContent(r);
    if (o) |m| if (m.boolean("inlineImports", false)) {
        input = inlineCssImports(input, v.pathDir(std.mem.trimStart(u8, r.name, "/")), 0);
    };
    if (!execAllowed("postcss")) return fail("POSTCSS: failed to transform \"{s}\" (text/css): access denied: \"postcss\" is not whitelisted in policy \"security.exec.allow\"", .{std.mem.trimStart(u8, r.name, "/")});
    const res = runNodeTool("postcss", args.items, input);
    if (res.not_found) return fail("failed to transform \"{s}\" (text/css). Check your PostCSS installation; install with \"npm install postcss-cli\". See https://gohugo.io/functions/css/postcss/: binary with name \"postcss\" not found in PATH", .{std.mem.trimStart(u8, r.name, "/")});
    if (!res.ok) return fail("POSTCSS: failed to transform \"{s}\" (text/css): {s}", .{ std.mem.trimStart(u8, r.name, "/"), v.trimWs(res.stderr) });
    return objs.resVal(derive(r, r.target, res.stdout));
}

fn fTailwind(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    const o = optMap(c);
    const work = sys.absNoResolve(site.S.opt.root);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(sys.A, &.{ "--input=-", "--cwd", work });
    if (o) |m| {
        if (m.boolean("minify", false)) try args.append(sys.A, "--minify");
        if (m.boolean("optimize", false)) try args.append(sys.A, "--optimize");
    }
    var input = objs.resContent(r);
    const disable_inline = if (o) |m| m.boolean("disableInlineImports", false) else false;
    if (!disable_inline) input = inlineCssImports(input, v.pathDir(std.mem.trimStart(u8, r.name, "/")), 0);
    if (!execAllowed("tailwindcss")) return fail("TAILWINDCSS: failed to transform \"{s}\" (text/css): access denied: \"tailwindcss\" is not whitelisted in policy \"security.exec.allow\"", .{std.mem.trimStart(u8, r.name, "/")});
    const res = runNodeTool("tailwindcss", args.items, input);
    if (res.not_found) return fail("failed to transform \"{s}\" (text/css). Check your TailwindCSS installation; install with \"npm install tailwindcss @tailwindcss/cli\". See https://gohugo.io/functions/css/tailwindcss/: binary with name \"tailwindcss\" not found in PATH", .{std.mem.trimStart(u8, r.name, "/")});
    if (!res.ok) {
        var msg = v.trimWs(res.stderr);
        if (disable_inline and v.contains(msg, "Can't resolve")) msg = v.concat(&.{ msg, "You may want to set the 'disableInlineImports' option to false to inline imports, see https://gohugo.io/functions/css/tailwindcss/#disableinlineimports" });
        return fail("TAILWINDCSS: failed to transform \"{s}\" (text/css): {s}", .{ std.mem.trimStart(u8, r.name, "/"), msg });
    }
    return objs.resVal(derive(r, r.target, res.stdout));
}

fn fBabel(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    const o = optMap(c);
    var args: std.ArrayList([]const u8) = .empty;
    var cfg: ?[]const u8 = null;
    if (o) |m| if (m.str("config")) |cf| {
        cfg = if (std.fs.path.isAbsolute(cf)) cf else jsConfigFile(&.{cf}) orelse return fail("babel config \"{s}\" not found", .{cf});
    };
    if (cfg == null) cfg = jsConfigFile(&.{ "babel.config.js", "babel.config.mjs", "babel.config.cjs" });
    if (cfg) |cf| try args.appendSlice(sys.A, &.{ "--config-file", cf });
    var sm: []const u8 = "";
    if (o) |m| {
        sm = m.str("sourceMap") orelse "";
        if (sm.len > 0 and !v.eq(sm, "none")) try args.append(sys.A, "--source-maps=inline");
        if (m.boolean("minified", false)) try args.append(sys.A, "--minified");
        if (m.boolean("noComments", false)) try args.append(sys.A, "--no-comments");
        if (m.getCI("compact")) |cp| try args.append(sys.A, if (v.truth(cp)) "--compact=true" else "--compact=false");
        if (m.boolean("verbose", false)) try args.append(sys.A, "--verbose");
        if (m.boolean("noBabelrc", false)) try args.append(sys.A, "--no-babelrc");
    }
    try args.append(sys.A, v.concat(&.{ "--filename=", std.mem.trimStart(u8, r.name, "/") }));
    if (!execAllowed("babel")) return fail("access denied: \"babel\" is not whitelisted in policy \"security.exec.allow\"", .{});
    const res = runNodeTool("babel", args.items, objs.resContent(r));
    if (res.not_found) return fail("failed to transform \"{s}\" (text/javascript). Check your Babel installation; install with \"npm install @babel/cli @babel/core\". See https://gohugo.io/functions/js/babel/: binary with name \"babel\" not found in PATH", .{std.mem.trimStart(u8, r.name, "/")});
    if (!res.ok) return fail("{s}: exit status 1", .{v.trimWs(res.stderr)});
    var out = res.stdout;
    const ext = v.pathExt(r.target);
    var target = v.concat(&.{ r.target[0 .. r.target.len - ext.len], ".js" });
    if (v.eq(sm, "external")) {
        const marker = "//# sourceMappingURL=data:application/json;charset=utf-8;base64,";
        if (v.indexOf(out, marker)) |i| {
            var e = v.indexOfPos(out, i, "\n") orelse out.len;
            const b64 = v.trimWs(out[i + marker.len .. e]);
            const dec = std.base64.standard.Decoder;
            if (dec.calcSizeForSlice(b64)) |n| {
                const buf = try sys.A.alloc(u8, n);
                if (dec.decode(buf, b64)) |_| {
                    const mp = v.pathJoin(&.{ site.S.dest, v.concat(&.{ target, ".map" }) });
                    sys.mkdirAll(v.pathDir(mp));
                    try sys.writeFile(mp, buf);
                    if (e < out.len) e += 1;
                    out = v.concat(&.{ out[0..i], "//# sourceMappingURL=", std.fs.path.basename(target), ".map\n", out[e..] });
                } else |_| {}
            } else |_| {}
        }
    }
    if (o) |m| if (m.str("targetPath")) |tp| {
        target = v.concat(&.{ "/", std.mem.trimStart(u8, tp, "/") });
    };
    const n = derive(r, target, out);
    n.media = "text/javascript";
    return objs.resVal(n);
}

fn fPassRes(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    site.warn("{s} is not implemented in ZSSG; the resource {s} is passed through unchanged", .{ c.name, r.name });
    return c.last();
}
fn fJsBuild(c: *Ctx) anyerror!Value {
    const r = try resArg(c);
    var opts: ?*Map = null;
    if (c.a.len > 1 and c.a[0] == .map) opts = c.a[0].map;
    return esbuildRes(c, r, opts, false);
}

/// js.Build / css.Build via esbuild; falls back to publishing the source unchanged
/// (with a warning) when Node.js or the esbuild package is not installed.
fn esbuildRes(c: *Ctx, r: *site.Resource, opts: ?*Map, css_mode: bool) anyerror!Value {
    const content = objs.resContent(r);
    const is_css = v.eq(r.media, "text/css");
    const ext = v.pathExt(r.target);
    var target = v.concat(&.{ r.target[0 .. r.target.len - ext.len], if (is_css) ".css" else ".js" });
    if (opts) |o| if (o.str("targetPath")) |tp| {
        target = v.concat(&.{ "/", std.mem.trimStart(u8, tp, "/") });
    };
    const out_dir = v.pathDir(std.mem.trimStart(u8, target, "/"));
    const esb = @import("esbuild.zig");
    if (esb.build(content, r.name, r.media, opts, css_mode, out_dir)) |res| {
        var main = res.main;
        const sm = if (opts) |o| o.str("sourceMap") orelse "" else "";
        for (res.others) |f| {
            if (v.endsWith(f.path, ".map")) {
                if (v.eq(sm, "linked") or v.eq(sm, "external")) {
                    const mp = v.concat(&.{ target, ".map" });
                    sys.mkdirAll(v.pathDir(v.pathJoin(&.{ site.S.dest, mp })));
                    try sys.writeFile(v.pathJoin(&.{ site.S.dest, mp }), f.contents);
                }
            } else {
                sys.mkdirAll(v.pathJoin(&.{ site.S.dest, out_dir }));
                try sys.writeFile(v.pathJoin(&.{ site.S.dest, out_dir, f.path }), f.contents);
            }
        }
        if (v.eq(sm, "linked")) {
            const sym = v.concat(&.{ std.fs.path.basename(target), ".map" });
            const marker: []const u8 = if (is_css) "/*# sourceMappingURL=" else "//# sourceMappingURL=";
            if (v.indexOf(main, marker)) |i| {
                var e = v.indexOfPos(main, i, "\n") orelse main.len;
                if (e < main.len) e += 1;
                main = v.concat(&.{ main[0..i], marker, sym, if (is_css) " */\n" else "\n", main[e..] });
            }
        }
        const n = derive(r, target, main);
        n.media = if (is_css) "text/css" else "text/javascript";
        return objs.resVal(n);
    } else |e| switch (e) {
        error.EsbuildFailed => return fail("{s}: failed to transform \"{s}\" ({s}): {s}", .{ if (css_mode) "css.Build" else "js.Build", std.mem.trimStart(u8, r.name, "/"), r.media, esb.last_error }),
        error.Unavailable => {},
    }
    _ = c;
    site.warn("{s}: esbuild is not available (install Node.js and `npm install esbuild@0.28.2`); {s} is published without bundling", .{ if (css_mode) "css.Build" else "js.Build", r.name });
    var out = content;
    if (css_mode) out = inlineCssImports(content, v.pathDir(std.mem.trimStart(u8, r.name, "/")), 0);
    if (opts) |o| if (o.boolean("minify", false) and css_mode) {
        out = @import("min_css.zig").minify(out, false) catch out;
    };
    const n = derive(r, target, out);
    n.media = if (is_css) "text/css" else "text/javascript";
    return objs.resVal(n);
}
fn fResCopy(c: *Ctx) anyerror!Value {
    try c.need(2);
    const r = try resArg(c);
    const n = objs.newResource(c.s(0), r.content, r.src_path);
    return objs.resVal(n);
}
var remote_cache: std.StringHashMapUnmanaged(?*site.Resource) = .empty;

/// Hugo's security.http.urls / methods whitelists.
fn httpAllowed(url: []const u8, method: []const u8) ?[]const u8 {
    const def_urls = [_][]const u8{ "(?i)^https?://[a-z0-9]", "! (?i)^https?://\\d+\\.", "! (?i)localhost", "! (?i)^https?://[^/?#]*@" };
    const def_methods = [_][]const u8{"(?i)GET|POST"};
    var urls: std.ArrayList([]const u8) = .empty;
    var methods: std.ArrayList([]const u8) = .empty;
    var http: ?*Map = null;
    if (site.S.cfg.map("security")) |sec| http = sec.map("http");
    if (http) |h| if (h.getCI("urls")) |u| switch (u) {
        .list => |l| for (l.items.items) |x| urls.append(sys.A, v.toStr(x)) catch {},
        else => urls.append(sys.A, v.toStr(u)) catch {},
    };
    if (urls.items.len == 0) urls.appendSlice(sys.A, &def_urls) catch {};
    if (http) |h| if (h.getCI("methods")) |u| switch (u) {
        .list => |l| for (l.items.items) |x| methods.append(sys.A, v.toStr(x)) catch {},
        else => methods.append(sys.A, v.toStr(u)) catch {},
    };
    if (methods.items.len == 0) methods.appendSlice(sys.A, &def_methods) catch {};
    const S = struct {
        fn accept(pats: []const []const u8, x: []const u8) bool {
            for (pats) |p| if (v.startsWith(p, "! ") and reSearch(p[2..], x)) return false;
            for (pats) |p| if (!v.startsWith(p, "! ") and reSearch(p, x)) return true;
            return false;
        }
    };
    if (!S.accept(urls.items, url)) return v.fmt("access denied: \"{s}\" is not whitelisted in policy \"security.http.urls\"", .{url});
    if (!S.accept(methods.items, method)) return v.fmt("access denied: \"{s}\" is not whitelisted in policy \"security.http.method\"", .{method});
    return null;
}

fn httpStatusText(code: i64) []const u8 {
    return switch (code) {
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "",
    };
}

fn suffixForMedia(mt: []const u8) ?[]const u8 {
    const mtab = [_][2][]const u8{ .{ "text/css", ".css" }, .{ "text/javascript", ".js" }, .{ "application/javascript", ".js" }, .{ "application/json", ".json" }, .{ "text/html", ".html" }, .{ "application/xml", ".xml" }, .{ "text/xml", ".xml" }, .{ "text/plain", ".txt" }, .{ "text/csv", ".csv" }, .{ "text/markdown", ".md" }, .{ "image/svg+xml", ".svg" }, .{ "image/png", ".png" }, .{ "image/jpeg", ".jpg" }, .{ "image/gif", ".gif" }, .{ "image/webp", ".webp" }, .{ "image/avif", ".avif" }, .{ "image/x-icon", ".ico" }, .{ "image/vnd.microsoft.icon", ".ico" }, .{ "image/bmp", ".bmp" }, .{ "image/tiff", ".tif" }, .{ "application/pdf", ".pdf" }, .{ "font/woff", ".woff" }, .{ "font/woff2", ".woff2" }, .{ "font/ttf", ".ttf" }, .{ "font/otf", ".otf" }, .{ "video/mp4", ".mp4" }, .{ "video/webm", ".webm" }, .{ "audio/mpeg", ".mp3" }, .{ "application/toml", ".toml" }, .{ "application/yaml", ".yaml" }, .{ "application/rss+xml", ".rss" }, .{ "application/atom+xml", ".xml" }, .{ "application/wasm", ".wasm" }, .{ "application/zip", ".zip" } };
    for (mtab) |t| if (v.eq(t[0], mt)) return t[1];
    return null;
}

/// Sniffs common binary formats (Hugo's media.FromContent).
fn sniffSuffix(body: []const u8) ?[]const u8 {
    if (v.startsWith(body, "\x89PNG")) return ".png";
    if (v.startsWith(body, "\xff\xd8\xff")) return ".jpg";
    if (v.startsWith(body, "GIF8")) return ".gif";
    if (body.len > 12 and v.startsWith(body, "RIFF") and v.eq(body[8..12], "WEBP")) return ".webp";
    if (v.startsWith(body, "%PDF")) return ".pdf";
    if (v.startsWith(body, "wOF2")) return ".woff2";
    if (v.startsWith(body, "wOFF")) return ".woff";
    return null;
}

/// resources.GetRemote: fetched with curl (which honours the usual proxy and CA
/// settings); 404 gives nil, other non-2xx statuses are errors (like Hugo).
fn fGetRemote(c: *Ctx) anyerror!Value {
    try c.need(1);
    const url = c.s(0);
    var opts: ?*Map = null;
    if (c.a.len > 1 and c.a[1] == .map) opts = c.a[1].map;
    var method: []const u8 = "GET";
    if (opts) |o| if (o.getCI("method")) |m| {
        method = v.upper(v.toStr(m));
    };
    var ob: v.Buf = .{};
    ob.add(url);
    if (opts) |o| data.toJson(&ob, v.M(o), .{}, 0);
    const okey = ob.str();
    if (remote_cache.get(okey)) |r| return if (r) |rr| objs.resVal(rr) else .nil;
    if (httpAllowed(url, method)) |msg| return fail("{s}", .{msg});
    var user_key = v.fmt("{d}", .{std.hash.XxHash64.hash(0, okey)});
    if (opts) |o| if (o.getCI("key")) |k| {
        user_key = v.fmt("{d}", .{std.hash.XxHash64.hash(0, v.toStr(k))});
    };

    const tmpd = sys.tmpDir();
    const id = sys.pid();
    const body_path = v.pathJoin(&.{ tmpd, v.fmt("zssg-remote-{d}.body", .{id}) });
    const hdr_path = v.pathJoin(&.{ tmpd, v.fmt("zssg-remote-{d}.hdr", .{id}) });
    defer sys.removeTree(body_path);
    defer sys.removeTree(hdr_path);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(sys.A, &.{ "curl", "-sS", "-L", "-X", method, "-D", hdr_path, "-o", body_path, "-w", "%{http_code}" });
    var has_ua = false;
    if (opts) |o| if (o.getCI("headers")) |hv| if (hv == .map) for (hv.map.m.keys(), hv.map.m.values()) |k, x| {
        if (std.ascii.eqlIgnoreCase(k, "User-Agent")) has_ua = true;
        const vals: []Value = if (x == .list) x.list.items.items else @constCast(&[_]Value{x});
        for (vals) |one| try argv.appendSlice(sys.A, &.{ "-H", v.concat(&.{ k, ": ", v.toStr(one) }) });
    };
    if (!has_ua) try argv.appendSlice(sys.A, &.{ "-H", "User-Agent: Hugo Static Site Generator" });
    if (opts) |o| if (o.getCI("body")) |b| {
        const req_path = v.pathJoin(&.{ tmpd, v.fmt("zssg-remote-{d}.req", .{id}) });
        try sys.writeFile(req_path, if (b == .list) blk: {
            var bb: std.ArrayList(u8) = .empty;
            for (b.list.items.items) |x| try bb.append(sys.A, @intCast(@as(u8, @truncate(@as(u64, @bitCast(if (x == .int) x.int else 0))))));
            break :blk bb.items;
        } else v.toStr(b));
        try argv.appendSlice(sys.A, &.{ "--data-binary", v.concat(&.{ "@", req_path }) });
    };
    if (opts) |o| if (o.getCI("timeout")) |t| {
        if (parseDuration(v.toStr(t))) |ns| try argv.appendSlice(sys.A, &.{ "--max-time", v.fmt("{d}", .{@max(@divTrunc(ns, std.time.ns_per_s), 1)}) });
    };
    if (v.eq(method, "HEAD")) try argv.append(sys.A, "-I");
    try argv.append(sys.A, url);
    const r = sys.runCode(argv.items) orelse return fail("resources.GetRemote: curl is required to fetch remote resources (not found in PATH)", .{});
    if (r.code != 0) return fail("failed to fetch remote resource from '{s}': {s}", .{ url, v.trimWs(r.stderr) });
    const code = std.fmt.parseInt(i64, v.trimWs(r.stdout), 10) catch 0;
    if (code == 404) {
        try remote_cache.put(sys.A, okey, null);
        return .nil;
    }
    // headers of the final response
    const hdr_all = sys.readFile(hdr_path) orelse "";
    var hdr = hdr_all;
    while (v.indexOf(hdr, "\r\n\r\nHTTP/")) |i| hdr = hdr[i + 4 ..];
    var ctype: []const u8 = "";
    var disposition: []const u8 = "";
    var clen: i64 = -1;
    const headers = v.newMap();
    var it = std.mem.splitSequence(u8, hdr, "\r\n");
    _ = it.next();
    while (it.next()) |ln| {
        const colon = v.indexOfChar(ln, ':') orelse continue;
        const k = v.trimWs(ln[0..colon]);
        const val = v.trimWs(ln[colon + 1 ..]);
        if (std.ascii.eqlIgnoreCase(k, "content-type")) ctype = val;
        if (std.ascii.eqlIgnoreCase(k, "content-disposition")) disposition = val;
        if (std.ascii.eqlIgnoreCase(k, "content-length")) clen = std.fmt.parseInt(i64, val, 10) catch -1;
        // canonical header key (Go's textproto.CanonicalMIMEHeaderKey)
        const ck = try sys.A.dupe(u8, k);
        var up = true;
        for (ck) |*ch| {
            ch.* = if (up) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*);
            up = ch.* == '-';
        }
        const l = if (headers.get(ck)) |ex| ex.list else v.newList();
        v.push(l, v.S(val));
        headers.put(ck, v.L(l));
    }
    const status_text = httpStatusText(code);
    if (code < 200 or code > 299) {
        return fail("failed to fetch remote resource from '{s}': {s}", .{ url, if (status_text.len > 0) status_text else v.fmt("{d}", .{code}) });
    }
    const body = sys.readFile(body_path) orelse "";
    const path_part = blk: {
        var u = url;
        if (v.indexOf(u, "://")) |i| u = u[i + 3 ..];
        if (v.indexOfChar(u, '/')) |i| u = u[i..] else u = "/";
        if (v.indexOfAny(u, "?#")) |i| u = u[0..i];
        break :blk u;
    };
    var filename = std.fs.path.basename(path_part);
    if (filename.len == 0) filename = "/";
    if (v.indexOf(disposition, "filename=")) |i| {
        filename = std.mem.trim(u8, disposition[i + 9 ..], "\" ;");
    }
    const base_ct = v.trimWs(if (v.indexOfChar(ctype, ';')) |i| ctype[0..i] else ctype);
    var suffix: ?[]const u8 = null;
    var media: []const u8 = base_ct;
    if (!v.startsWith(base_ct, "text/plain") and !v.eq(base_ct, "application/octet-stream")) suffix = suffixForMedia(base_ct);
    if (suffix == null) {
        const ext = v.pathExt(filename);
        if (sniffSuffix(body)) |sx| {
            suffix = sx;
        } else if (ext.len > 0) {
            suffix = ext;
        } else if (v.startsWith(base_ct, "text/plain")) {
            suffix = ".txt";
        } else {
            const t = v.trimWs(body[0..@min(body.len, 512)]);
            if (v.startsWith(t, "<svg") or (v.startsWith(t, "<?xml") and v.contains(t, "<svg"))) suffix = ".svg" else if (v.startsWith(t, "{") or v.startsWith(t, "[")) suffix = ".json" else if (v.startsWith(t, "<")) suffix = ".html";
        }
        if (suffix) |sx| media = objs.mediaTypeOf(v.concat(&.{ "x", sx }));
    }
    const sx = suffix orelse return fail("failed to resolve media type for remote resource \"{s}\"", .{url});
    const stem = filename[0 .. filename.len - v.pathExt(filename).len];
    const target = v.concat(&.{ std.mem.trimStart(u8, stem, "/"), "_", user_key, sx });
    const res = objs.newResource(target, body, null);
    res.media = media;
    const dm = v.newMap();
    dm.put("ContentLength", v.I(if (clen >= 0) clen else @as(i64, @intCast(body.len))));
    dm.put("ContentType", v.S(ctype));
    dm.put("Status", v.S(v.fmt("{d} {s}", .{ code, status_text })));
    dm.put("StatusCode", v.I(code));
    dm.put("TransferEncoding", v.L(v.newList()));
    if (opts) |o| if (o.getCI("responseHeaders")) |rh| if (rh == .list) {
        const hm = v.newMap();
        for (rh.list.items.items) |want| {
            for (headers.m.keys(), headers.m.values()) |k, x| if (std.ascii.eqlIgnoreCase(k, v.toStr(want))) hm.put(k, x);
        }
        dm.put("Headers", v.M(hm));
    };
    res.data = dm;
    try remote_cache.put(sys.A, okey, res);
    return objs.resVal(res);
}

// ================================================================ misc

fn fSite(_: *Ctx) anyerror!Value {
    return site.S.val();
}
fn fHugo(_: *Ctx) anyerror!Value {
    return hugoVal();
}
fn fPage(c: *Ctx) anyerror!Value {
    return c.ex.page;
}
fn fErrorf(c: *Ctx) anyerror!Value {
    try c.need(1);
    const is_id = v.endsWith(c.name, "idf");
    const msg = if (is_id) sprintf(c.s(1), c.a[@min(2, c.a.len)..]) else sprintf(c.s(0), c.a[1..]);
    if (v.startsWith(c.name, "warn")) site.warn("{s}", .{msg}) else site.errorf("{s}", .{msg});
    return v.S("");
}
fn fDump(c: *Ctx) anyerror!Value {
    var b: v.Buf = .{};
    data.toJson(&b, c.last(), .{ .indent = "  " }, 0);
    return v.S(b.str());
}
fn fIsMap(c: *Ctx) anyerror!Value {
    return v.B(c.a.len > 0 and c.a[0] == .map);
}
fn fReflectRes(c: *Ctx) anyerror!Value {
    const a: Value = if (c.a.len > 0) c.a[0] else .nil;
    const n = c.name[8..];
    if (v.eq(n, "IsPage")) return v.B(a == .obj and a.obj.kind == .page);
    if (v.eq(n, "IsSite")) return v.B(a == .obj and a.obj.kind == .site);
    if (v.eq(n, "IsResource")) return v.B(a == .obj and (a.obj.kind == .resource or a.obj.kind == .page));
    const r = objs.asRes(a) orelse return v.B(false);
    if (v.eq(n, "IsImageResource")) return v.B(v.startsWith(r.media, "image/") and !v.eq(r.media, "image/svg+xml") and !v.eq(r.media, "image/x-icon"));
    return v.B(objs.isProcessableImage(r)); // IsImageResourceProcessable, IsImageResourceWithMeta
}
fn fIsSlice(c: *Ctx) anyerror!Value {
    return v.B(c.a.len > 0 and c.a[0] == .list);
}
/// templates.Defer: the block runs after all pages are rendered (see tmpl.runDeferred).
fn fDefer(c: *Ctx) anyerror!Value {
    const m = v.newMap();
    m.put("__deferred", v.B(true));
    m.put("data", if (c.a.len > 0 and c.a[0] == .map) c.a[0].map.getCI("data") orelse .nil else .nil);
    if (c.a.len > 0 and c.a[0] == .map) if (c.a[0].map.getCI("key")) |k| m.put("key", k);
    return v.M(m);
}
fn fEmpty(_: *Ctx) anyerror!Value {
    return v.S("");
}
fn fImageFilterCtor(c: *Ctx) anyerror!Value {
    return @import("imgops.zig").filterVal(v.lower(c.name[7..]), c.a);
}
fn fImagesFilter(c: *Ctx) anyerror!Value {
    try c.need(2);
    const r = try resArg(c);
    return objs.resVal(try @import("imgops.zig").applyFilters(r, c.a[0 .. c.a.len - 1]));
}

fn fImagesConfig(c: *Ctx) anyerror!Value {
    const m = v.newMap();
    var cc: Ctx = .{ .ex = c.ex, .a = c.a, .dot = c.dot, .name = "readFile" };
    const content = (try fReadFile(&cc)).str;
    const r = objs.newResource(c.s(0), content, null);
    m.put("Width", try objs.objField(c.ex, .{ .kind = .resource, .ptr = r }, "Width", &.{}));
    m.put("Height", try objs.objField(c.ex, .{ .kind = .resource, .ptr = r }, "Height", &.{}));
    return v.M(m);
}

const table = std.StaticStringMap(Fn).initComptime(.{
    .{ "len", fLen },                         .{ "index", fIndex },                       .{ "slice", fSlice },
    .{ "dict", fDict },                       .{ "print", fPrint },                       .{ "println", fPrintln },
    .{ "printf", fPrintf },                   .{ "fmt.Print", fPrint },                   .{ "fmt.Println", fPrintln },
    .{ "fmt.Printf", fPrintf },               .{ "not", fNot },                           .{ "and", fAnd },
    .{ "or", fOr },                           .{ "eq", fEq },                             .{ "ne", fNe },
    .{ "lt", fLt },                           .{ "le", fLe },                             .{ "gt", fGt },
    .{ "ge", fGe },                           .{ "compare.Eq", fEq },                     .{ "compare.Ne", fNe },
    .{ "compare.Lt", fLt },                   .{ "compare.Le", fLe },                     .{ "compare.Gt", fGt },
    .{ "compare.Ge", fGe },                   .{ "default", fDefault },                   .{ "compare.Default", fDefault },
    .{ "cond", fCond },                       .{ "compare.Conditional", fCond },          .{ "isset", fIsset },
    .{ "collections.IsSet", fIsset },         .{ "first", fFirst },                       .{ "collections.First", fFirst },
    .{ "last", fLast },                       .{ "collections.Last", fLast },             .{ "after", fAfter },
    .{ "collections.After", fAfter },         .{ "collections.Reverse", fReverse },       .{ "append", fAppend },
    .{ "collections.Append", fAppend },       .{ "in", fIn },                             .{ "collections.In", fIn },
    .{ "delimit", fDelimit },                 .{ "collections.Delimit", fDelimit },       .{ "uniq", fUniq },
    .{ "collections.Uniq", fUniq },           .{ "union", fUnion },                       .{ "collections.Union", fUnion },
    .{ "intersect", fIntersect },             .{ "collections.Intersect", fIntersect },   .{ "complement", fComplement },
    .{ "collections.Complement", fComplement }, .{ "symdiff", fSymdiff },                 .{ "collections.SymDiff", fSymdiff },
    .{ "seq", fSeq },                         .{ "collections.Seq", fSeq },               .{ "shuffle", fShuffle },
    .{ "collections.Shuffle", fShuffle },     .{ "merge", fMerge },                       .{ "collections.Merge", fMerge },
    .{ "where", fWhere },                     .{ "collections.Where", fWhere },           .{ "sort", fSort },
    .{ "collections.Sort", fSort },           .{ "group", fGroup },                       .{ "collections.Group", fGroup },
    .{ "apply", fApply },                     .{ "collections.Apply", fApply },           .{ "newScratch", fNewScratch },
    .{ "collections.NewScratch", fNewScratch }, .{ "querify", fQuerify },                 .{ "collections.Querify", fQuerify },
    .{ "echoParam", fEchoParam },             .{ "collections.Index", fIndex },           .{ "collections.Slice", fSlice },
    .{ "collections.Dictionary", fDict },     .{ "collections.KeyVals", fKeyVals },       .{ "keyVals", fKeyVals },
    .{ "int", fInt },                         .{ "cast.ToInt", fInt },                    .{ "float", fFloat },
    .{ "cast.ToFloat", fFloat },              .{ "string", fString },                     .{ "cast.ToString", fString },
    .{ "add", fAdd },                         .{ "math.Add", fAdd },                      .{ "sub", fSub },
    .{ "math.Sub", fSub },                    .{ "mul", fMul },                           .{ "math.Mul", fMul },
    .{ "div", fDiv },                         .{ "math.Div", fDiv },                      .{ "mod", fMod },
    .{ "math.Mod", fMod },                    .{ "modBool", fModBool },                   .{ "math.ModBool", fModBool },
    .{ "math.Ceil", math1 },                  .{ "math.Floor", math1 },                   .{ "math.Round", math1 },
    .{ "math.Sqrt", math1 },                  .{ "math.Abs", math1 },                     .{ "math.Log", math1 },
    .{ "math.Sin", math1 },                   .{ "math.Cos", math1 },                     .{ "math.Tan", math1 },
    .{ "math.Pow", fPow },                    .{ "pow", fPow },                           .{ "math.Max", fMaxMin },
    .{ "math.Min", fMaxMin },                 .{ "math.Sum", fMaxMin },                   .{ "math.Product", fMaxMin },
    .{ "math.Counter", fCounter },            .{ "math.Rand", fRand },                    .{ "lower", fLower },
    .{ "strings.ToLower", fLower },           .{ "upper", fUpper },                       .{ "strings.ToUpper", fUpper },
    .{ "title", fTitle },                     .{ "strings.Title", fTitle },               .{ "strings.FirstUpper", fFirstUpper },
    .{ "trim", fTrim },                       .{ "strings.Trim", fTrim },                 .{ "strings.TrimLeft", fTrimLeft },
    .{ "strings.TrimRight", fTrimRight },     .{ "strings.TrimPrefix", fTrimPrefix },     .{ "strings.TrimSuffix", fTrimSuffix },
    .{ "strings.TrimSpace", fTrimSpace },     .{ "chomp", fChomp },                       .{ "strings.Chomp", fChomp },
    .{ "hasPrefix", fHasPrefix },             .{ "strings.HasPrefix", fHasPrefix },       .{ "hasSuffix", fHasSuffix },
    .{ "strings.HasSuffix", fHasSuffix },     .{ "strings.Contains", fContains },         .{ "strings.ContainsAny", fContainsAny },
    .{ "strings.ContainsNonSpace", fContainsNonSpace }, .{ "strings.Count", fCount },     .{ "strings.Repeat", fRepeat },
    .{ "replace", fReplace },                 .{ "strings.Replace", fReplace },           .{ "replaceRE", fReplaceRE },
    .{ "strings.ReplaceRE", fReplaceRE },     .{ "findRE", fFindRE },                     .{ "strings.FindRE", fFindRE },
    .{ "findRESubmatch", fFindRESubmatch },   .{ "strings.FindRESubmatch", fFindRESubmatch }, .{ "split", fSplit },
    .{ "strings.Split", fSplit },             .{ "substr", fSubstr },                     .{ "strings.Substr", fSubstr },
    .{ "slicestr", fSliceString },            .{ "strings.SliceString", fSliceString },   .{ "truncate", fTruncate },
    .{ "strings.Truncate", fTruncate },       .{ "countwords", fCountWords },             .{ "strings.CountWords", fCountWords },
    .{ "countrunes", fCountRunes },           .{ "strings.CountRunes", fCountRunes },     .{ "strings.RuneCount", fRuneCount },
    .{ "plainify", fPlainify },               .{ "transform.Plainify", fPlainify },       .{ "htmlEscape", fHtmlEscape },
    .{ "transform.HTMLEscape", fHtmlEscape }, .{ "htmlUnescape", fHtmlUnescape },         .{ "transform.HTMLUnescape", fHtmlUnescape },
    .{ "transform.XMLEscape", fXMLEscape },   .{ "html", fHtml },                         .{ "urlquery", fUrlquery },
    .{ "js", fJs },                           .{ "safeHTML", fSafeHTML },                 .{ "safe.HTML", fSafeHTML },
    .{ "safeHTMLAttr", fSafeAttr },           .{ "safe.HTMLAttr", fSafeAttr },            .{ "safeCSS", fSafeCSS },
    .{ "safe.CSS", fSafeCSS },                .{ "safeJS", fSafeJS },                     .{ "safe.JS", fSafeJS },
    .{ "safeJSStr", fSafeJS },                .{ "safe.JSStr", fSafeJS },                 .{ "safeURL", fSafeURL },
    .{ "safe.URL", fSafeURL },                .{ "humanize", fHumanize },                 .{ "inflect.Humanize", fHumanize },
    .{ "pluralize", fPluralize },             .{ "inflect.Pluralize", fPluralize },       .{ "singularize", fSingularize },
    .{ "inflect.Singularize", fSingularize }, .{ "anchorize", fAnchorize },               .{ "urls.Anchorize", fAnchorize },
    .{ "urlize", fUrlize },                   .{ "urls.URLize", fUrlize },                .{ "absURL", fAbsURL },
    .{ "urls.AbsURL", fAbsURL },              .{ "absLangURL", fLangURL },                 .{ "urls.AbsLangURL", fLangURL },
    .{ "relURL", fRelURL },                   .{ "urls.RelURL", fRelURL },                .{ "relLangURL", fLangURL },
    .{ "urls.RelLangURL", fLangURL },          .{ "ref", fRef },                           .{ "relref", fRef },
    .{ "urls.Ref", fRef },                    .{ "urls.RelRef", fRef },                   .{ "urls.Parse", fUrlParse },
    .{ "urls.JoinPath", fJoinPath },          .{ "path.Join", fJoinPath },                .{ "path.Base", fPathBase },
    .{ "path.Dir", fPathDir },                .{ "path.Ext", fPathExt },                  .{ "path.Clean", fPathClean },
    .{ "path.BaseName", fPathBaseName },      .{ "path.Split", fPathSplit },              .{ "now", fNow },
    .{ "time.Now", fNow },                    .{ "time", fTime },                         .{ "time.AsTime", fTime },
    .{ "dateFormat", fDateFormat },           .{ "time.Format", fDateFormat },            .{ "duration", fDuration },
    .{ "time.Duration", fDuration },          .{ "time.ParseDuration", fParseDuration },  .{ "jsonify", fJsonify },
    .{ "encoding.Jsonify", fJsonify },        .{ "unmarshal", fUnmarshal },               .{ "transform.Unmarshal", fUnmarshal },
    .{ "base64Encode", fBase64Encode },       .{ "encoding.Base64Encode", fBase64Encode }, .{ "base64Decode", fBase64Decode },
    .{ "encoding.Base64Decode", fBase64Decode }, .{ "md5", fMd5 },                        .{ "crypto.MD5", fMd5 },
    .{ "sha1", fSha1 },                       .{ "crypto.SHA1", fSha1 },                  .{ "sha256", fSha256 },
    .{ "crypto.SHA256", fSha256 },            .{ "hash.FNV32a", fFnv32a },                .{ "crypto.FNV32a", fFnv32a },
    .{ "hash.XxHash", fXxHash },              .{ "xxhash", fXxHash },                     .{ "getenv", fGetenv },
    .{ "os.Getenv", fGetenv },                .{ "fileExists", fFileExists },             .{ "os.FileExists", fFileExists },
    .{ "readFile", fReadFile },               .{ "os.ReadFile", fReadFile },              .{ "readDir", fReadDir },
    .{ "os.ReadDir", fReadDir },              .{ "markdownify", fMarkdownify },           .{ "transform.Markdownify", fMarkdownify },
    .{ "highlight", fHighlight },             .{ "transform.Highlight", fHighlight },     .{ "emojify", fEmojify },
    .{ "transform.Emojify", fEmojify },       .{ "i18n", fI18n },                         .{ "T", fI18n },
    .{ "lang.Translate", fI18n },             .{ "lang.FormatNumber", fFormatNumber },    .{ "lang.FormatNumberCustom", fFormatNumber },
    .{ "lang.FormatPercent", fFormatNumber }, .{ "partial", fPartial },                   .{ "partials.Include", fPartial },
    .{ "partialCached", fPartialCached },     .{ "partials.IncludeCached", fPartialCached }, .{ "templates.Exists", fTemplatesExists },
    .{ "templates.Defer", fDefer },           .{ "resources.Get", fResGet },              .{ "resources.GetMatch", fResMatch },
    .{ "resources.Match", fResMatch },        .{ "resources.ByType", fResByType },        .{ "resources.FromString", fFromString },
    .{ "resources.Concat", fConcat },         .{ "resources.ExecuteAsTemplate", fExecAsTemplate }, .{ "resources.Minify", fMinify },
    .{ "minify", fMinify },                   .{ "resources.Fingerprint", fFingerprint }, .{ "fingerprint", fFingerprint },
    .{ "resources.ToCSS", fToCSS },           .{ "toCSS", fToCSS },                       .{ "css.Sass", fToCSS },
    .{ "resources.PostCSS", fPostCSS },       .{ "postCSS", fPostCSS },                   .{ "css.PostCSS", fPostCSS },
    .{ "css.TailwindCSS", fTailwind },        .{ "resources.Babel", fBabel },             .{ "babel", fBabel },
    .{ "js.Babel", fBabel },                .{ "resources.PostProcess", fIdentity },    .{ "js.Build", fJsBuild },
    .{ "resources.Copy", fResCopy },          .{ "resources.GetRemote", fGetRemote },     .{ "site", fSite },
    .{ "hugo", fHugo },                       .{ "page", fPage },                         .{ "errorf", fErrorf },
    .{ "fmt.Errorf", fErrorf },               .{ "erroridf", fErrorf },                   .{ "fmt.Erroridf", fErrorf },
    .{ "warnf", fErrorf },                    .{ "fmt.Warnf", fErrorf },                  .{ "warnidf", fErrorf },
    .{ "fmt.Warnidf", fErrorf },              .{ "debug.Dump", fDump },                   .{ "reflect.IsMap", fIsMap },
    .{ "reflect.IsSlice", fIsSlice },         .{ "reflect.IsPage", fReflectRes },         .{ "reflect.IsSite", fReflectRes },
    .{ "reflect.IsResource", fReflectRes },   .{ "reflect.IsImageResource", fReflectRes }, .{ "reflect.IsImageResourceProcessable", fReflectRes },
    .{ "reflect.IsImageResourceWithMeta", fReflectRes },         .{ "debug.Timer", fEmpty },                 .{ "images.Config", fImagesConfig },
    .{ "imageConfig", fImagesConfig },
    .{ "images.Filter", fImagesFilter },      .{ "images.Brightness", fImageFilterCtor }, .{ "images.ColorBalance", fImageFilterCtor },
    .{ "images.Colorize", fImageFilterCtor }, .{ "images.Contrast", fImageFilterCtor },   .{ "images.Dither", fImageFilterCtor },
    .{ "images.Gamma", fImageFilterCtor },    .{ "images.GaussianBlur", fImageFilterCtor }, .{ "images.Grayscale", fImageFilterCtor },
    .{ "images.Hue", fImageFilterCtor },      .{ "images.Invert", fImageFilterCtor },     .{ "images.Mask", fImageFilterCtor },
    .{ "images.Opacity", fImageFilterCtor },  .{ "images.Overlay", fImageFilterCtor },    .{ "images.Padding", fImageFilterCtor },
    .{ "images.Pixelate", fImageFilterCtor }, .{ "images.Process", fImageFilterCtor },    .{ "images.Saturation", fImageFilterCtor },
    .{ "images.Sepia", fImageFilterCtor },    .{ "images.Sigmoid", fImageFilterCtor },    .{ "images.Text", fImageFilterCtor },
    .{ "images.UnsharpMask", fImageFilterCtor }, .{ "images.AutoOrient", fImageFilterCtor },
    .{ "urls.PathEscape", fPathEscape },      .{ "urls.PathUnescape", fPathUnescape },   .{ "encoding.HexEncode", fHexEncode },
    .{ "encoding.HexDecode", fHexDecode },    .{ "crypto.HMAC", fHmac },                  .{ "hmac", fHmac },
    .{ "math.Pi", fMathConst },               .{ "math.MaxInt64", fMathConst },           .{ "math.Acos", fMathTrig },
    .{ "math.Asin", fMathTrig },              .{ "math.Atan", fMathTrig },                .{ "math.Atan2", fMathTrig },
    .{ "math.ToDegrees", fMathTrig },         .{ "math.ToRadians", fMathTrig },           .{ "os.Stat", fOsStat },
    .{ "resources.Publish", fResPublish },    .{ "time.In", fTimeIn },                    .{ "transform.Remarshal", fRemarshal },
    .{ "debug.VisualizeSpaces", fVisualizeSpaces }, .{ "templates.Current", fTemplatesCurrent }, .{ "compare.LtCollate", fLtCollate },
    .{ "lang.Merge", fLangMerge },            .{ "lang.FormatCurrency", fFormatCurrency }, .{ "lang.FormatAccounting", fFormatCurrency },
    .{ "collections.D", fCollD },             .{ "isSet", fIsset },                       .{ "fmt.Errormf", fErrorf },
    .{ "fmt.Warnmf", fErrorf },        .{ "transform.ToMath", fToMath },        .{ "css.Build", fCssBuild },        .{ "transform.HighlightCodeBlock", fHighlightCodeBlock },        .{ "transform.CanHighlight", fIsMap },
});

// ================================================================ assorted (urls, encoding, crypto, math, os, time, lang)

fn pathSegKeep(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or switch (ch) {
        '-', '_', '.', '~', '$', '&', '+', ':', '=', '@' => true,
        else => false,
    };
}
fn fPathEscape(c: *Ctx) anyerror!Value {
    try c.need(1);
    var b: v.Buf = .{};
    for (c.s(0)) |ch| {
        if (pathSegKeep(ch)) b.ch(ch) else b.print("%{X:0>2}", .{ch});
    }
    return v.S(b.str());
}
fn fPathUnescape(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    var b: v.Buf = .{};
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return fail("invalid URL escape \"{s}\"", .{s[i..]});
            const x = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return fail("invalid URL escape \"{s}\"", .{s[i .. i + 3]});
            b.ch(x);
            i += 2;
        } else b.ch(s[i]);
    }
    return v.S(b.str());
}
fn fHexEncode(c: *Ctx) anyerror!Value {
    try c.need(1);
    return v.S(hex(c.s(0)));
}
fn fHexDecode(c: *Ctx) anyerror!Value {
    try c.need(1);
    const s = c.s(0);
    if (s.len % 2 != 0) return fail("encoding/hex: odd length hex string", .{});
    const out = try sys.A.alloc(u8, s.len / 2);
    for (0..out.len) |i| out[i] = std.fmt.parseInt(u8, s[2 * i .. 2 * i + 2], 16) catch return fail("encoding/hex: invalid byte: U+{X:0>4} '{c}'", .{ s[2 * i], s[2 * i] });
    return v.S(out);
}
fn fHmac(c: *Ctx) anyerror!Value {
    try c.need(3);
    const algo = v.lower(c.s(0));
    const key = c.s(1);
    const msg = c.s(2);
    const enc = if (c.a.len > 3) v.lower(c.s(3)) else "hex";
    var buf: [64]u8 = undefined;
    var out: []const u8 = undefined;
    const H = std.crypto.auth.hmac;
    if (v.eq(algo, "md5")) {
        H.HmacMd5.create(buf[0..16], msg, key);
        out = buf[0..16];
    } else if (v.eq(algo, "sha1")) {
        H.HmacSha1.create(buf[0..20], msg, key);
        out = buf[0..20];
    } else if (v.eq(algo, "sha256")) {
        H.sha2.HmacSha256.create(buf[0..32], msg, key);
        out = buf[0..32];
    } else if (v.eq(algo, "sha512")) {
        H.sha2.HmacSha512.create(buf[0..64], msg, key);
        out = buf[0..64];
    } else return fail("hmac: {s} is not a supported hash function", .{c.s(0)});
    if (v.eq(enc, "binary")) return v.S(try sys.A.dupe(u8, out));
    if (v.eq(enc, "base64")) {
        const e = std.base64.standard.Encoder;
        const o = try sys.A.alloc(u8, e.calcSize(out.len));
        return v.S(e.encode(o, out));
    }
    if (!v.eq(enc, "hex")) return fail("hmac: {s} is not a supported encoding method", .{c.s(3)});
    return v.S(hex(out));
}
fn fMathConst(c: *Ctx) anyerror!Value {
    if (v.eq(c.name, "math.MaxInt64")) return v.I(std.math.maxInt(i64));
    return .{ .float = std.math.pi };
}
fn fMathTrig(c: *Ctx) anyerror!Value {
    const n = c.name[5..];
    if (v.eq(n, "Atan2")) {
        try c.need(2);
        return .{ .float = std.math.atan2(try c.float(0), try c.float(1)) };
    }
    try c.need(1);
    const x = try c.float(0);
    const r: f64 = if (v.eq(n, "Acos")) std.math.acos(x) else if (v.eq(n, "Asin")) std.math.asin(x) else if (v.eq(n, "Atan")) std.math.atan(x) else if (v.eq(n, "ToDegrees")) x * (180.0 / std.math.pi) else x * (std.math.pi / 180.0);
    return .{ .float = r };
}
fn fOsStat(c: *Ctx) anyerror!Value {
    try c.need(1);
    const rel = c.s(0);
    var path = v.pathJoin(&.{ site.S.opt.root, rel });
    var kind = sys.kindOf(path);
    if (kind == .none) {
        // also look in the content directory, like Hugo's working-dir filesystem
        path = v.pathJoin(&.{ site.S.opt.root, site.S.cfg.str("contentDir") orelse "content", rel });
        kind = sys.kindOf(path);
    }
    if (kind == .none) return fail("stat {s}: no such file or directory", .{rel});
    const st = sys.stat(path) orelse sys.Stat{ .size = 0, .mtime = 0 };
    const m = v.newMap();
    m.put("Name", v.S(v.pathBase(path)));
    m.put("Size", v.I(@as(i64, @intCast(st.size))));
    m.put("IsDir", v.B(kind == .dir));
    m.put("ModTime", .{ .time = .{ .sec = st.mtime } });
    return v.M(m);
}
fn fResPublish(c: *Ctx) anyerror!Value {
    try c.need(1);
    const r = try resArg(c);
    objs.publish(r);
    return objs.resVal(r);
}

/// Offset (seconds east of UTC) of an IANA zone at a given instant, from the
/// system zoneinfo database.
fn zoneOffset(name: []const u8, at: i64) ?i32 {
    if (v.eq(name, "UTC") or v.eq(name, "") or v.eq(name, "GMT")) return 0;
    const path = v.concat(&.{ "/usr/share/zoneinfo/", name });
    const b = sys.readFile(path) orelse return null;
    if (b.len < 44 or !std.mem.eql(u8, b[0..4], "TZif")) return null;
    const rd = struct {
        fn be32(x: []const u8) i32 {
            return std.mem.readInt(i32, x[0..4], .big);
        }
    };
    var p: usize = 0;
    var ver2 = b[4] >= '2';
    var tsz: usize = 4;
    while (true) {
        const isutcnt: usize = @intCast(rd.be32(b[p + 20 ..]));
        const isstdcnt: usize = @intCast(rd.be32(b[p + 24 ..]));
        const leapcnt: usize = @intCast(rd.be32(b[p + 28 ..]));
        const timecnt: usize = @intCast(rd.be32(b[p + 32 ..]));
        const typecnt: usize = @intCast(rd.be32(b[p + 36 ..]));
        const charcnt: usize = @intCast(rd.be32(b[p + 40 ..]));
        const body = p + 44;
        const total = timecnt * tsz + timecnt + typecnt * 6 + charcnt + leapcnt * (tsz + 4) + isstdcnt + isutcnt;
        if (ver2) {
            ver2 = false;
            p = body + total;
            tsz = 8;
            if (p + 44 > b.len) return null;
            continue;
        }
        if (body + total > b.len) return null;
        const times = b[body..];
        const idxs = b[body + timecnt * tsz ..];
        const tt = b[body + timecnt * tsz + timecnt ..];
        var type_idx: usize = 0;
        // first non-DST type is used before the first transition
        for (0..typecnt) |k| if (tt[k * 6 + 4] == 0) {
            type_idx = k;
            break;
        };
        for (0..timecnt) |k| {
            const t: i64 = if (tsz == 8) std.mem.readInt(i64, times[k * 8 ..][0..8], .big) else rd.be32(times[k * 4 ..]);
            if (t > at) break;
            type_idx = idxs[k];
        }
        return rd.be32(tt[type_idx * 6 ..]);
    }
}
fn fTimeIn(c: *Ctx) anyerror!Value {
    try c.need(2);
    const zone = c.s(0);
    var t = site.toTime(c.a[1]) orelse return fail("time.In: unable to parse date: {s}", .{c.s(1)});
    if (v.eq(zone, "Local")) return .{ .time = t };
    t.off = zoneOffset(zone, t.sec) orelse return fail("unknown time zone {s}", .{zone});
    return .{ .time = t };
}
fn fRemarshal(c: *Ctx) anyerror!Value {
    try c.need(2);
    const format = v.lower(c.s(0));
    var val = c.a[1];
    if (val != .map) {
        const src = c.s(1);
        val = data.parseAuto(src) catch return fail("failed to detect format from content", .{});
    }
    var b: v.Buf = .{};
    if (v.eq(format, "json")) {
        data.toJson(&b, val, .{ .indent = "  ", .html_escape = false }, 0);
        b.ch('\n');
    } else if (v.eq(format, "yaml")) {
        data.toYamlToml(&b, val, false);
    } else if (v.eq(format, "toml")) {
        data.toYamlToml(&b, val, true);
    } else return fail("format not supported: {s}", .{c.s(0)});
    return v.S(b.str());
}
fn fVisualizeSpaces(c: *Ctx) anyerror!Value {
    var s = c.s(0);
    const reps = [_][2][]const u8{ .{ " ", "[SPACE]" }, .{ "\t", "[TAB]" }, .{ "\n", "[NEWLINE]\n" }, .{ "\r", "[CR]" }, .{ "\x0b", "[VTAB]" }, .{ "\x00", "[NUL]" }, .{ "\u{fffd}", "[U+FFFD]" } };
    for (reps) |r| s = try std.mem.replaceOwned(u8, sys.A, s, r[0], r[1]);
    return v.S(s);
}
fn fTemplatesCurrent(c: *Ctx) anyerror!Value {
    const m = v.newMap();
    const name = c.ex.tmpl.name;
    m.put("Name", v.S(name));
    m.put("Filename", v.S(name));
    m.put("Ancestors", .{ .list = v.newList() });
    m.put("Parent", .nil);
    return v.M(m);
}
fn fLtCollate(c: *Ctx) anyerror!Value {
    try c.need(3);
    // locale-aware collation approximated by case-insensitive ordering
    const a = v.toStr(c.a[1]);
    const b = v.toStr(c.a[2]);
    const o = std.ascii.orderIgnoreCase(a, b);
    if (o == .eq) return v.B(std.mem.order(u8, a, b) == .lt);
    return v.B(o == .lt);
}
fn fLangMerge(c: *Ctx) anyerror!Value {
    try c.need(2);
    const p2 = c.a[0];
    const p1 = c.a[1];
    if (!v.truth(p1)) return p2;
    if (!v.truth(p2)) return p1;
    if (p1 != .list or p2 != .list) return fail("language merge not supported for {s}", .{@tagName(p1)});
    // keep p1, add pages from p2 whose translation key is not present
    const out = v.newList();
    try out.items.appendSlice(sys.A, p1.list.items.items);
    for (p2.list.items.items) |x| {
        var dup = false;
        for (p1.list.items.items) |y| if (v.eq(pageKey(x), pageKey(y))) {
            dup = true;
            break;
        };
        if (!dup) try out.items.append(sys.A, x);
    }
    return .{ .list = out };
}
fn fFormatCurrency(c: *Ctx) anyerror!Value {
    try c.need(3);
    const prec: usize = @intCast(@max(try c.int(0), 0));
    const cur = c.s(1);
    const x = try c.float(2);
    const sym: []const u8 = if (v.eq(cur, "USD")) "$" else if (v.eq(cur, "EUR")) "€" else if (v.eq(cur, "GBP")) "£" else if (v.eq(cur, "JPY")) "¥" else if (v.eq(cur, "INR")) "₹" else if (v.eq(cur, "CNY")) "CN¥" else if (v.eq(cur, "CAD")) "CA$" else if (v.eq(cur, "AUD")) "A$" else cur;
    const fixed = fmtFixed(@abs(x), @max(prec, 2));
    const dot = v.indexOfChar(fixed, '.') orelse fixed.len;
    var num: v.Buf = .{};
    num.add(groupDigits(fixed[0..dot], ","));
    if (dot < fixed.len) {
        num.ch('.');
        num.add(fixed[dot + 1 ..]);
    }
    if (x < 0) {
        if (v.eq(c.name, "lang.FormatAccounting")) return v.S(v.concat(&.{ "(", sym, num.str(), ")" }));
        return v.S(v.concat(&.{ "-", sym, num.str() }));
    }
    return v.S(v.concat(&.{ sym, num.str() }));
}

// collections.D: Vitter's algorithm D over Go's math/rand/v2 PCG source.
const Pcg = struct {
    hi: u64,
    lo: u64,
    fn next(p: *Pcg) u64 {
        const mul_hi: u64 = 2549297995355413924;
        const mul_lo: u64 = 4865540595714422341;
        const inc_hi: u64 = 6364136223846793005;
        const inc_lo: u64 = 1442695040888963407;
        const full = @as(u128, p.lo) * mul_lo;
        var hi: u64 = @truncate(full >> 64);
        var lo: u64 = @truncate(full);
        hi +%= p.hi *% mul_lo +% p.lo *% mul_hi;
        const s = @addWithOverflow(lo, inc_lo);
        lo = s[0];
        hi = hi +% inc_hi +% s[1];
        p.lo = lo;
        p.hi = hi;
        const cheap: u64 = 0xda942042e4dd58b5;
        var h = hi;
        h ^= h >> 32;
        h *%= cheap;
        h ^= h >> 48;
        h *%= (lo | 1);
        return h;
    }
    fn float(p: *Pcg) f64 {
        return @as(f64, @floatFromInt(p.next() << 11 >> 11)) / 9007199254740992.0;
    }
};

fn vitterA(prng: *Pcg, want0: i64, max0: i64, j0: i64, out: *std.ArrayList(Value)) void {
    var want = want0;
    var max = max0;
    var j = j0;
    while (want >= 2) {
        j += 1;
        const V = prng.float();
        var quot = @as(f64, @floatFromInt(max - want)) / @as(f64, @floatFromInt(max));
        while (quot > V) {
            j += 1;
            max -= 1;
            quot *= @as(f64, @floatFromInt(max - want));
            quot /= @as(f64, @floatFromInt(max));
        }
        out.append(sys.A, v.I(j)) catch {};
        max -= 1;
        want -= 1;
    }
    const S: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(max)) * prng.float()));
    j += S + 1;
    out.append(sys.A, v.I(j)) catch {};
}

fn vitterD(prng: *Pcg, want0: i64, max0: i64, out: *std.ArrayList(Value)) void {
    var want = want0;
    var max = max0;
    if (want <= 0 or want > max) return;
    var j: i64 = -1;
    var qu1: i64 = -want + 1 + max;
    const negalphainv: i64 = -13;
    var threshold: i64 = -negalphainv * want;
    var wantf: f64 = @floatFromInt(want);
    var maxf: f64 = @floatFromInt(max);
    var ninv: f64 = 1.0 / wantf;
    var nmin1inv: f64 = 0;
    var Vprime = @exp(@log(prng.float()) * ninv);
    var qu1real: f64 = -wantf + 1.0 + maxf;
    var U: f64 = 0;
    var X: f64 = 0;
    var y1: f64 = 0;
    var y2: f64 = 0;
    var top: f64 = 0;
    var bottom: f64 = 0;
    var negSreal: f64 = 0;
    while (want > 1 and threshold < max) {
        var S: i64 = 0;
        nmin1inv = 1.0 / (-1.0 + wantf);
        while (true) {
            while (true) {
                X = maxf * (-Vprime + 1.0);
                S = @intFromFloat(@floor(X));
                if (S < qu1) break;
                Vprime = @exp(@log(prng.float()) * ninv);
            }
            U = prng.float();
            negSreal = @floatFromInt(-S);
            y1 = @exp(@log(U * maxf / qu1real) * nmin1inv);
            Vprime = y1 * (-X / maxf + 1.0) * (qu1real / (negSreal + qu1real));
            if (Vprime <= 1.0) break;
            y2 = 1.0;
            top = -1.0 + maxf;
            var limit: i64 = 0;
            if (-1 + want > S) {
                bottom = -wantf + maxf;
                limit = -S + max;
            } else {
                bottom = -1.0 + negSreal + maxf;
                limit = qu1;
            }
            var t = max - 1;
            while (t >= limit) : (t -= 1) {
                y2 = (y2 * top) / bottom;
                top -= 1;
                bottom -= 1;
            }
            if (maxf / (-X + maxf) >= y1 * @exp(@log(y2) * nmin1inv)) {
                Vprime = @exp(@log(prng.float()) * nmin1inv);
                break;
            }
            Vprime = @exp(@log(prng.float()) * ninv);
        }
        j += S + 1;
        out.append(sys.A, v.I(j)) catch {};
        max = -S + (-1 + max);
        maxf = negSreal + (-1.0 + maxf);
        want -= 1;
        wantf -= 1;
        ninv = nmin1inv;
        qu1 = -S + qu1;
        qu1real = negSreal + qu1real;
        threshold += negalphainv;
    }
    if (want > 1) {
        vitterA(prng, want, max, j, out);
    } else {
        const S: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(max)) * Vprime));
        j += S + 1;
        out.append(sys.A, v.I(j)) catch {};
    }
}

fn fCollD(c: *Ctx) anyerror!Value {
    try c.need(3);
    const seed = try c.int(0);
    const n = try c.int(1);
    const hi = try c.int(2);
    const max_seq: i64 = 1_000_000;
    if (seed < 0) return fail("the seed value ({d}) must be a non-negative integer", .{seed});
    if (n < 0 or n > max_seq) return fail("the number of requested values ({d}) must be a non-negative integer <= {d}", .{ n, max_seq });
    if (hi < 0 or hi > max_seq) return fail("the maximum requested value ({d}) must be a non-negative integer <= {d}", .{ hi, max_seq });
    const out = v.newList();
    if (n == 0 or hi == 0) return .{ .list = out };
    if (n > hi) {
        var i: i64 = 0;
        while (i < hi) : (i += 1) try out.items.append(sys.A, v.I(i));
        return .{ .list = out };
    }
    var prng = Pcg{ .hi = @intCast(seed), .lo = 0 };
    vitterD(&prng, n, hi, &out.items);
    return .{ .list = out };
}

fn pageKey(x: Value) []const u8 {
    if (x == .obj and x.obj.kind == .page) {
        const p: *site.Page = @ptrCast(@alignCast(x.obj.ptr));
        return p.path;
    }
    return v.toStr(x);
}
