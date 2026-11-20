// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
//! Dynamic value model shared by config parsers, the template engine and the site model.
const std = @import("std");
const sys = @import("sys.zig");

pub const SafeKind = enum { html, attr, css, js, url, escaped };
pub const Safe = struct { kind: SafeKind, s: []const u8 };
pub const List = struct { items: std.ArrayList(Value) = .empty };
pub const Map = struct {
    m: std.StringArrayHashMapUnmanaged(Value) = .empty,

    pub fn get(self: *const Map, k: []const u8) ?Value {
        return self.m.get(k);
    }
    /// Case-insensitive lookup (Hugo params are case-insensitive).
    pub fn getCI(self: *const Map, k: []const u8) ?Value {
        if (self.m.get(k)) |v| return v;
        for (self.m.keys(), self.m.values()) |kk, v| if (std.ascii.eqlIgnoreCase(kk, k)) return v;
        return null;
    }
    pub fn put(self: *Map, k: []const u8, v: Value) void {
        self.m.put(sys.A, k, v) catch {};
    }
    pub fn putCI(self: *Map, k: []const u8, v: Value) void {
        for (self.m.keys(), self.m.values()) |kk, *vp| if (std.ascii.eqlIgnoreCase(kk, k)) {
            vp.* = v;
            return;
        };
        self.put(k, v);
    }
    pub fn remove(self: *Map, k: []const u8) void {
        _ = self.m.orderedRemove(k);
    }
    pub fn str(self: *const Map, k: []const u8) ?[]const u8 {
        if (self.getCI(k)) |v| return switch (v) {
            .str => |s| s,
            .safe => |s| s.s,
            .nil, .list, .map, .obj => null,
            else => toStr(v),
        };
        return null;
    }
    pub fn strOr(self: *const Map, k: []const u8, def: []const u8) []const u8 {
        return self.str(k) orelse def;
    }
    pub fn boolean(self: *const Map, k: []const u8, def: bool) bool {
        if (self.getCI(k)) |v| return truth(v);
        return def;
    }
    pub fn int(self: *const Map, k: []const u8, def: i64) i64 {
        if (self.getCI(k)) |v| return toInt(v) orelse def;
        return def;
    }
    pub fn map(self: *const Map, k: []const u8) ?*Map {
        if (self.getCI(k)) |v| if (v == .map) return v.map;
        return null;
    }
    pub fn list(self: *const Map, k: []const u8) ?*List {
        if (self.getCI(k)) |v| if (v == .list) return v.list;
        return null;
    }
};

pub const ObjKind = enum { page, site, pager, resource, scratch, shortcode, taxonomy, term, group, menu, hook, tmpl };
pub const Obj = struct { kind: ObjKind, ptr: *anyopaque };

pub const Time = struct {
    sec: i64 = 0,
    nsec: u32 = 0,
    off: i32 = 0,
    zero: bool = false,
};

pub const Value = union(enum) {
    nil,
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8,
    safe: Safe,
    list: *List,
    map: *Map,
    time: Time,
    dur: i64, // nanoseconds
    obj: Obj,
};

pub fn S(s: []const u8) Value {
    return .{ .str = s };
}
pub fn H(s: []const u8) Value {
    return .{ .safe = .{ .kind = .html, .s = s } };
}
pub fn I(i: anytype) Value {
    return .{ .int = @intCast(i) };
}
pub fn B(b: bool) Value {
    return .{ .bool = b };
}
pub fn newList() *List {
    const l = sys.A.create(List) catch @panic("oom");
    l.* = .{};
    return l;
}
pub fn newMap() *Map {
    const m = sys.A.create(Map) catch @panic("oom");
    m.* = .{};
    return m;
}
pub fn L(l: *List) Value {
    return .{ .list = l };
}
pub fn M(m: *Map) Value {
    return .{ .map = m };
}
pub fn push(l: *List, v: Value) void {
    l.items.append(sys.A, v) catch @panic("oom");
}
pub fn listOf(vals: []const Value) Value {
    const l = newList();
    for (vals) |v| push(l, v);
    return L(l);
}
pub fn strList(strs: []const []const u8) Value {
    const l = newList();
    for (strs) |s| push(l, S(s));
    return L(l);
}

pub fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(sys.A, f, args) catch @panic("oom");
}

pub fn truth(v: Value) bool {
    return switch (v) {
        .nil => false,
        .bool => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .str => |s| s.len > 0,
        .safe => |s| s.s.len > 0,
        .list => |l| l.items.items.len > 0,
        .map => |m| m.m.count() > 0,
        .time => |t| !t.zero,
        .dur => |d| d != 0,
        .obj => true,
    };
}

pub fn isStr(v: Value) bool {
    return v == .str or v == .safe;
}
pub fn rawStr(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s,
        .safe => |s| s.s,
        else => null,
    };
}

pub fn toInt(v: Value) ?i64 {
    return switch (v) {
        .int => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        .bool => |b| @intFromBool(b),
        .str, .safe => blk: {
            const s = trimWs(rawStr(v).?);
            if (std.fmt.parseInt(i64, s, 0) catch null) |i| break :blk i;
            if (std.fmt.parseFloat(f64, s) catch null) |f| break :blk @intFromFloat(f);
            break :blk null;
        },
        .dur => |d| d,
        else => null,
    };
}
pub fn toFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .bool => |b| if (b) 1 else 0,
        .str, .safe => std.fmt.parseFloat(f64, trimWs(rawStr(v).?)) catch null,
        else => null,
    };
}
pub fn isNum(v: Value) bool {
    return v == .int or v == .float;
}

pub var objToStr: *const fn (Obj) []const u8 = &defaultObjStr;
fn defaultObjStr(_: Obj) []const u8 {
    return "<object>";
}
pub var timeToStr: *const fn (Time) []const u8 = &defaultTimeStr;
fn defaultTimeStr(_: Time) []const u8 {
    return "<time>";
}

pub fn floatStr(f: f64) []const u8 {
    if (f == @trunc(f) and @abs(f) < 1e15) return fmt("{d}", .{@as(i64, @intFromFloat(f))});
    return fmt("{d}", .{f});
}

/// Go-style `print` formatting.
pub fn toStr(v: Value) []const u8 {
    return switch (v) {
        .nil => "",
        .bool => |b| if (b) "true" else "false",
        .int => |i| fmt("{d}", .{i}),
        .float => |f| floatStr(f),
        .str => |s| s,
        .safe => |s| s.s,
        .list => |l| blk: {
            var o: std.ArrayList(u8) = .empty;
            o.append(sys.A, '[') catch {};
            for (l.items.items, 0..) |it, i| {
                if (i > 0) o.append(sys.A, ' ') catch {};
                o.appendSlice(sys.A, toStr(it)) catch {};
            }
            o.append(sys.A, ']') catch {};
            break :blk o.items;
        },
        .map => |m| blk: {
            if (m.m.get("__str")) |sv| break :blk toStr(sv);
            var o: std.ArrayList(u8) = .empty;
            o.appendSlice(sys.A, "map[") catch {};
            const keys = sortedKeys(m);
            for (keys, 0..) |k, i| {
                if (i > 0) o.append(sys.A, ' ') catch {};
                o.appendSlice(sys.A, k) catch {};
                o.append(sys.A, ':') catch {};
                o.appendSlice(sys.A, toStr(m.m.get(k).?)) catch {};
            }
            o.append(sys.A, ']') catch {};
            break :blk o.items;
        },
        .time => |t| timeToStr(t),
        .dur => |d| fmt("{d}s", .{@divTrunc(d, 1_000_000_000)}),
        .obj => |o| objToStr(o),
    };
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
pub fn sortedKeys(m: *const Map) [][]const u8 {
    const keys = sys.A.dupe([]const u8, m.m.keys()) catch @panic("oom");
    std.mem.sort([]const u8, keys, {}, strLess);
    return keys;
}

pub fn eql(a: Value, b: Value) bool {
    if (isNum(a) and isNum(b)) {
        if (a == .int and b == .int) return a.int == b.int;
        return toFloat(a).? == toFloat(b).?;
    }
    if (isStr(a) and isStr(b)) return std.mem.eql(u8, rawStr(a).?, rawStr(b).?);
    if (a == .nil or b == .nil) return a == .nil and b == .nil;
    if (a == .bool and b == .bool) return a.bool == b.bool;
    if (a == .time and b == .time) return a.time.sec == b.time.sec and a.time.nsec == b.time.nsec;
    if (a == .obj and b == .obj) return a.obj.ptr == b.obj.ptr;
    if (a == .dur and b == .dur) return a.dur == b.dur;
    if (a == .list and b == .list) {
        const x = a.list.items.items;
        const y = b.list.items.items;
        if (x.len != y.len) return false;
        for (x, y) |p, q| if (!eql(p, q)) return false;
        return true;
    }
    if (a == .map and b == .map) {
        if (a.map == b.map) return true;
        if (a.map.m.count() != b.map.m.count()) return false;
        for (a.map.m.keys(), a.map.m.values()) |k, v| {
            const o = b.map.m.get(k) orelse return false;
            if (!eql(v, o)) return false;
        }
        return true;
    }
    return false;
}

/// Three-way compare used by lt/gt/sort. Returns .eq for incomparable values.
pub fn cmp(a: Value, b: Value) std.math.Order {
    if (isNum(a) and isNum(b)) {
        if (a == .int and b == .int) return std.math.order(a.int, b.int);
        return std.math.order(toFloat(a).?, toFloat(b).?);
    }
    if (isStr(a) and isStr(b)) return std.mem.order(u8, rawStr(a).?, rawStr(b).?);
    if (a == .time and b == .time) {
        if (a.time.zero != b.time.zero) return if (a.time.zero) .lt else .gt;
        const o = std.math.order(a.time.sec, b.time.sec);
        return if (o == .eq) std.math.order(a.time.nsec, b.time.nsec) else o;
    }
    if (a == .bool and b == .bool) return std.math.order(@intFromBool(a.bool), @intFromBool(b.bool));
    if (a == .dur and b == .dur) return std.math.order(a.dur, b.dur);
    if (a == .nil and b != .nil) return .lt;
    if (b == .nil and a != .nil) return .gt;
    // number vs numeric string
    if (isNum(a) and isStr(b)) if (toFloat(b)) |f| return std.math.order(toFloat(a).?, f);
    if (isStr(a) and isNum(b)) if (toFloat(a)) |f| return std.math.order(f, toFloat(b).?);
    return .eq;
}

// ---------------------------------------------------------------- strings

pub fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
pub fn indexOf(h: []const u8, n: []const u8) ?usize {
    return indexOfPos(h, 0, n);
}
pub fn indexOfPos(h: []const u8, start: usize, n: []const u8) ?usize {
    if (n.len > h.len) return null;
    var i = start;
    while (i + n.len <= h.len) : (i += 1) if (std.mem.eql(u8, h[i .. i + n.len], n)) return i;
    return null;
}
pub fn lastIndexOf(h: []const u8, n: []const u8) ?usize {
    if (n.len > h.len) return null;
    var i = h.len - n.len + 1;
    while (i > 0) : (i -= 1) if (std.mem.eql(u8, h[i - 1 .. i - 1 + n.len], n)) return i - 1;
    return null;
}
pub fn indexOfChar(h: []const u8, c: u8) ?usize {
    for (h, 0..) |x, i| if (x == c) return i;
    return null;
}
pub fn lastIndexOfChar(h: []const u8, c: u8) ?usize {
    var i = h.len;
    while (i > 0) : (i -= 1) if (h[i - 1] == c) return i - 1;
    return null;
}
pub fn contains(h: []const u8, n: []const u8) bool {
    return indexOf(h, n) != null;
}
pub fn startsWith(h: []const u8, n: []const u8) bool {
    return h.len >= n.len and std.mem.eql(u8, h[0..n.len], n);
}
pub fn endsWith(h: []const u8, n: []const u8) bool {
    return h.len >= n.len and std.mem.eql(u8, h[h.len - n.len ..], n);
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
pub fn replaceAll(s: []const u8, from: []const u8, to: []const u8) []const u8 {
    if (from.len == 0 or !contains(s, from)) return s;
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + from.len <= s.len and eq(s[i .. i + from.len], from)) {
            o.appendSlice(sys.A, to) catch {};
            i += from.len;
        } else {
            o.append(sys.A, s[i]) catch {};
            i += 1;
        }
    }
    return o.items;
}
pub fn lower(s: []const u8) []const u8 {
    const o = sys.A.alloc(u8, s.len) catch @panic("oom");
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}
pub fn upper(s: []const u8) []const u8 {
    const o = sys.A.alloc(u8, s.len) catch @panic("oom");
    for (s, 0..) |c, i| o[i] = std.ascii.toUpper(c);
    return o;
}
pub fn dup(s: []const u8) []const u8 {
    return sys.A.dupe(u8, s) catch @panic("oom");
}
pub fn concat(parts: []const []const u8) []const u8 {
    return std.mem.concat(sys.A, u8, parts) catch @panic("oom");
}

pub const Buf = struct {
    l: std.ArrayList(u8) = .empty,
    pub fn add(self: *Buf, s: []const u8) void {
        self.l.appendSlice(sys.A, s) catch @panic("oom");
    }
    pub fn ch(self: *Buf, c: u8) void {
        self.l.append(sys.A, c) catch @panic("oom");
    }
    pub fn print(self: *Buf, comptime f: []const u8, args: anytype) void {
        self.add(fmt(f, args));
    }
    pub fn str(self: *const Buf) []const u8 {
        return self.l.items;
    }
    pub fn len(self: *const Buf) usize {
        return self.l.items.len;
    }
};

/// html/template compatible escaping (note: '+' becomes &#43; like Go).
pub fn htmlEscape(s: []const u8) []const u8 {
    var need = false;
    for (s) |c| switch (c) {
        '&', '<', '>', '"', '\'', '+', 0 => {
            need = true;
            break;
        },
        else => {},
    };
    if (!need) return s;
    var b: Buf = .{};
    for (s) |c| switch (c) {
        '&' => b.add("&amp;"),
        '<' => b.add("&lt;"),
        '>' => b.add("&gt;"),
        '"' => b.add("&#34;"),
        '\'' => b.add("&#39;"),
        '+' => b.add("&#43;"),
        0 => b.add("\u{FFFD}"),
        else => b.ch(c),
    };
    return b.str();
}

/// Plain HTML escaping as used by Markdown output / `htmlEscape` func.
pub fn escText(s: []const u8) []const u8 {
    var b: Buf = .{};
    for (s) |c| switch (c) {
        '&' => b.add("&amp;"),
        '<' => b.add("&lt;"),
        '>' => b.add("&gt;"),
        '"' => b.add("&quot;"),
        else => b.ch(c),
    };
    return b.str();
}

fn namedEntity(ent: []const u8) ?[]const u8 {
    const table = [_][2][]const u8{ .{ "copy", "©" }, .{ "reg", "®" }, .{ "trade", "™" }, .{ "laquo", "«" }, .{ "raquo", "»" }, .{ "euro", "€" }, .{ "pound", "£" }, .{ "yen", "¥" }, .{ "cent", "¢" }, .{ "deg", "°" }, .{ "times", "×" }, .{ "divide", "÷" }, .{ "plusmn", "±" }, .{ "micro", "µ" }, .{ "para", "¶" }, .{ "sect", "§" }, .{ "middot", "·" }, .{ "bull", "•" }, .{ "larr", "←" }, .{ "rarr", "→" }, .{ "uarr", "↑" }, .{ "darr", "↓" }, .{ "harr", "↔" }, .{ "frac12", "½" }, .{ "frac14", "¼" }, .{ "frac34", "¾" }, .{ "sup2", "²" }, .{ "sup3", "³" }, .{ "iexcl", "¡" }, .{ "iquest", "¿" }, .{ "szlig", "ß" }, .{ "agrave", "à" }, .{ "aacute", "á" }, .{ "eacute", "é" }, .{ "egrave", "è" }, .{ "uuml", "ü" }, .{ "ouml", "ö" }, .{ "auml", "ä" }, .{ "ntilde", "ñ" }, .{ "ccedil", "ç" }, .{ "infin", "∞" }, .{ "ne", "≠" }, .{ "le", "≤" }, .{ "ge", "≥" }, .{ "check", "✓" }, .{ "hearts", "♥" }, .{ "ensp", "\u{2002}" }, .{ "emsp", "\u{2003}" }, .{ "thinsp", "\u{2009}" }, .{ "zwj", "\u{200d}" }, .{ "zwnj", "\u{200c}" }, .{ "shy", "\u{ad}" } };
    for (table) |t| if (eq(t[0], ent)) return t[1];
    return null;
}

pub fn htmlUnescape(s: []const u8) []const u8 {
    if (indexOfChar(s, '&') == null) return s;
    var b: Buf = .{};
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (indexOfChar(s[i..@min(s.len, i + 12)], ';')) |e| {
                const ent = s[i + 1 .. i + e];
                const rep: ?[]const u8 = if (eq(ent, "amp")) "&" else if (eq(ent, "lt")) "<" else if (eq(ent, "gt")) ">" else if (eq(ent, "quot")) "\"" else if (eq(ent, "apos")) "'" else if (eq(ent, "nbsp")) "\u{a0}" else if (eq(ent, "hellip")) "…" else if (eq(ent, "rsquo")) "’" else if (eq(ent, "lsquo")) "‘" else if (eq(ent, "rdquo")) "”" else if (eq(ent, "ldquo")) "“" else if (eq(ent, "ndash")) "–" else if (eq(ent, "mdash")) "—" else namedEntity(ent);
                if (rep) |r| {
                    b.add(r);
                    i += e + 1;
                    continue;
                }
                if (ent.len > 1 and ent[0] == '#') {
                    const cp: ?u21 = if (ent[1] == 'x' or ent[1] == 'X') std.fmt.parseInt(u21, ent[2..], 16) catch null else std.fmt.parseInt(u21, ent[1..], 10) catch null;
                    if (cp) |c| {
                        var tmp: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(c, &tmp) catch null) |n| {
                            b.add(tmp[0..n]);
                            i += e + 1;
                            continue;
                        }
                    }
                }
            }
        }
        b.ch(s[i]);
        i += 1;
    }
    return b.str();
}

/// Hugo's tpl.StripHTML (`plainify`, `.Plain`): tags, comments and
/// script/style content are dropped; </p> and <br> become newlines, other
/// newlines spaces; text in adjacent block elements is separated by a space;
/// runs of whitespace collapse.
pub fn stripTags(s: []const u8) []const u8 {
    if (indexOfChar(s, '<') == null) return s;
    var w = StripW{};
    var pos: usize = 0;
    while (true) {
        const text_start = pos;
        const t = scanTag(s, &pos) orelse {
            w.text(s[text_start..]);
            break;
        };
        w.text(s[text_start..t.start]);
        if ((t.kind == .start and std.mem.eql(u8, t.name, "br")) or (t.kind == .end and std.mem.eql(u8, t.name, "p"))) {
            w.space('\n');
        } else if (t.kind == .start and (std.mem.eql(u8, t.name, "script") or std.mem.eql(u8, t.name, "style"))) {
            if (!t.self_closing) skipRawText(s, &pos, t.name);
        } else if (isBlockElement(t.name)) {
            w.needs_space = true;
        }
    }
    return w.b.str();
}


const StripW = struct {
    b: Buf = .{},
    was_space: bool = false,
    needs_space: bool = false,

    fn text(w: *StripW, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c >= 0x80) {
                const l = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(s.len, i + l);
                const cp = std.unicode.utf8Decode(s[i..end]) catch 0xfffd;
                const is_space = switch (cp) {
                    0x85, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
                    else => cp >= 0x2000 and cp <= 0x200a,
                };
                if (is_space) {
                    if (!w.was_space) {
                        w.b.add(s[i..end]);
                        w.was_space = true;
                    }
                } else w.nonSpace(s[i..end]);
                i = end;
                continue;
            }
            if (asciiSpace(c)) {
                w.space(if (c == '\n') ' ' else c);
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < s.len and s[j] < 0x80 and !asciiSpace(s[j])) j += 1;
            w.nonSpace(s[i..j]);
            i = j;
        }
    }
    fn nonSpace(w: *StripW, s: []const u8) void {
        if (w.needs_space and !w.was_space and w.b.len() > 0) w.b.ch(' ');
        w.b.add(s);
        w.was_space = false;
        w.needs_space = false;
    }
    fn space(w: *StripW, c: u8) void {
        if (!w.was_space) {
            w.b.ch(c);
            w.was_space = true;
        }
    }
};

fn asciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

const TagTok = struct { kind: enum { start, end, markup }, name: []const u8 = "", self_closing: bool = false, start: usize };

fn skipPast(s: []const u8, pos: *usize, sep: []const u8) void {
    if (std.mem.indexOfPos(u8, s, pos.*, sep)) |i| pos.* = i + sep.len else pos.* = s.len;
}

fn tagNameEnd(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == '/' or c == '>';
}

/// Hugo's hhtml.Scanner.Next.
fn scanTag(s: []const u8, pos: *usize) ?TagTok {
    while (true) {
        const i = std.mem.indexOfScalarPos(u8, s, pos.*, '<') orelse {
            pos.* = s.len;
            return null;
        };
        if (i + 1 >= s.len) {
            pos.* = s.len;
            return null;
        }
        var t = TagTok{ .kind = .start, .start = i };
        pos.* = i + 1;
        const c = s[pos.*];
        if (c == '!' or c == '?') {
            const rest = s[pos.*..];
            if (std.mem.startsWith(u8, rest, "!--")) {
                pos.* += 3;
                skipPast(s, pos, "-->");
            } else if (std.mem.startsWith(u8, rest, "![CDATA[")) {
                skipPast(s, pos, "]]>");
            } else skipPast(s, pos, ">");
            t.kind = .markup;
            return t;
        } else if (c == '/') {
            pos.* += 1;
            if (pos.* < s.len and !std.ascii.isAlphabetic(s[pos.*])) {
                skipPast(s, pos, ">");
                t.kind = .markup;
                return t;
            }
            t.kind = .end;
        } else if (std.ascii.isAlphabetic(c)) {
            t.kind = .start;
        } else continue;
        const ns = pos.*;
        while (pos.* < s.len and !tagNameEnd(s[pos.*])) pos.* += 1;
        t.name = lower(s[ns..pos.*]);
        while (pos.* < s.len) {
            const ch = s[pos.*];
            pos.* += 1;
            switch (ch) {
                '>' => return t,
                '/' => t.self_closing = t.kind == .start and pos.* < s.len and s[pos.*] == '>',
                '=' => {
                    while (pos.* < s.len and (s[pos.*] == ' ' or s[pos.*] == '\t' or s[pos.*] == '\n' or s[pos.*] == '\r' or s[pos.*] == 0x0c)) pos.* += 1;
                    if (pos.* < s.len and (s[pos.*] == '"' or s[pos.*] == '\'')) {
                        const q = s[pos.*];
                        pos.* += 1;
                        if (std.mem.indexOfScalarPos(u8, s, pos.*, q)) |j| pos.* = j + 1 else pos.* = s.len;
                    }
                },
                else => {},
            }
        }
        return t;
    }
}

fn skipRawText(s: []const u8, pos: *usize, name: []const u8) void {
    while (true) {
        skipPast(s, pos, "</");
        if (pos.* >= s.len) return;
        const rest = s[pos.*..];
        if (rest.len > name.len and std.ascii.eqlIgnoreCase(rest[0..name.len], name) and tagNameEnd(rest[name.len])) {
            pos.* -= 2;
            return;
        }
    }
}

fn isBlockElement(name: []const u8) bool {
    const blocks = [_][]const u8{ "address", "article", "aside", "blockquote", "caption", "dd", "details", "dialog", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul" };
    for (blocks) |b| if (std.mem.eql(u8, b, name)) return true;
    return false;
}

// ---------------------------------------------------------------- paths

pub fn pathJoin(parts: []const []const u8) []const u8 {
    var b: Buf = .{};
    for (parts) |p| {
        if (p.len == 0) continue;
        if (b.len() > 0 and b.str()[b.len() - 1] != '/') b.ch('/');
        const pp = if (b.len() > 0) std.mem.trimStart(u8, p, "/") else p;
        b.add(pp);
    }
    return b.str();
}
pub fn pathBase(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    if (lastIndexOfChar(t, '/')) |i| return t[i + 1 ..];
    return t;
}
pub fn pathDir(p: []const u8) []const u8 {
    if (lastIndexOfChar(p, '/')) |i| return if (i == 0) "/" else p[0..i];
    return "";
}
pub fn pathExt(p: []const u8) []const u8 {
    const b = pathBase(p);
    if (lastIndexOfChar(b, '.')) |i| if (i > 0) return b[i..];
    return "";
}
pub fn pathStem(p: []const u8) []const u8 {
    const b = pathBase(p);
    return b[0 .. b.len - pathExt(p).len];
}
pub fn pathClean(p: []const u8) []const u8 {
    const abs = startsWith(p, "/");
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or eq(seg, ".")) continue;
        if (eq(seg, "..")) {
            if (parts.items.len > 0 and !eq(parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!abs) parts.append(sys.A, seg) catch {};
            continue;
        }
        parts.append(sys.A, seg) catch {};
    }
    const joined = std.mem.join(sys.A, "/", parts.items) catch @panic("oom");
    if (abs) return concat(&.{ "/", joined });
    return if (joined.len == 0) "." else joined;
}

pub fn lowerRune(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    if ((cp >= 0xC0 and cp <= 0xDE and cp != 0xD7) or (cp >= 0x391 and cp <= 0x3A9) or (cp >= 0x410 and cp <= 0x42F)) return cp + 32;
    if (cp >= 0x400 and cp <= 0x40F) return cp + 80;
    if ((cp >= 0x100 and cp <= 0x137) or (cp >= 0x14A and cp <= 0x177) or (cp >= 0x1E00 and cp <= 0x1EFF) or (cp >= 0x460 and cp <= 0x4FF)) return if (cp % 2 == 0) cp + 1 else cp;
    if ((cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E)) return if (cp % 2 == 1) cp + 1 else cp;
    return cp;
}

fn baseLetter(cp_in: u21) u21 {
    const cp = lowerRune(cp_in);
    return switch (cp) {
        0xE0...0xE5 => 'a',
        0xE7 => 'c',
        0xE8...0xEB => 'e',
        0xEC...0xEF => 'i',
        0xF1 => 'n',
        0xF2...0xF6, 0xF8 => 'o',
        0xF9...0xFC => 'u',
        0xFD, 0xFF => 'y',
        else => cp,
    };
}

/// Approximate locale-aware ordering: case-insensitive, accents folded to base letters.
pub fn collate(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ra = decodeRune(a[i..]);
        const rb = decodeRune(b[j..]);
        const x = baseLetter(ra.cp);
        const y = baseLetter(rb.cp);
        if (x != y) return std.math.order(x, y);
        i += ra.len;
        j += rb.len;
    }
    if (i < a.len) return .gt;
    if (j < b.len) return .lt;
    return std.mem.order(u8, a, b);
}

pub fn utf8Len(c: u8) usize {
    return std.unicode.utf8ByteSequenceLength(c) catch 1;
}
pub fn runeCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += @min(utf8Len(s[i]), s.len - i);
    return n;
}
pub fn decodeRune(s: []const u8) struct { cp: u21, len: usize } {
    const n = @min(utf8Len(s[0]), s.len);
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = s[0], .len = 1 };
    return .{ .cp = cp, .len = n };
}
pub fn indexOfAny(h: []const u8, set: []const u8) ?usize {
    for (h, 0..) |c, i| for (set) |x| if (c == x) return i;
    return null;
}
