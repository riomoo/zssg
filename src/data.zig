// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! TOML, YAML and JSON readers producing dynamic values, plus a JSON writer.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const tm = @import("time.zig");
const Value = v.Value;
const Map = v.Map;

pub var err_msg: []const u8 = "";
fn fail(comptime f: []const u8, args: anytype) anyerror {
    err_msg = v.fmt(f, args);
    return error.ParseError;
}

// =============================================================== TOML

const Toml = struct {
    s: []const u8,
    i: usize = 0,

    fn line(p: *Toml) usize {
        var n: usize = 1;
        for (p.s[0..@min(p.i, p.s.len)]) |c| {
            if (c == '\n') n += 1;
        }
        return n;
    }
    fn peek(p: *Toml) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }
    fn ws(p: *Toml) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }
    fn wsNl(p: *Toml) void {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.i += 1;
            } else if (c == '#') {
                while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
            } else break;
        }
    }
    fn key(p: *Toml) anyerror![]const u8 {
        p.ws();
        const c = p.peek();
        if (c == '"') return p.basicStr();
        if (c == '\'') return p.litStr();
        const st = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_' or p.s[p.i] == '-')) p.i += 1;
        if (p.i == st) return fail("TOML line {d}: expected key", .{p.line()});
        return p.s[st..p.i];
    }
    fn keyPath(p: *Toml) anyerror![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            try parts.append(sys.A, try p.key());
            p.ws();
            if (p.peek() == '.') {
                p.i += 1;
            } else break;
        }
        return parts.items;
    }
    fn basicStr(p: *Toml) anyerror![]const u8 {
        var b: v.Buf = .{};
        if (v.startsWith(p.s[p.i..], "\"\"\"")) {
            p.i += 3;
            if (p.peek() == '\r') p.i += 1;
            if (p.peek() == '\n') p.i += 1;
            while (p.i < p.s.len) {
                if (v.startsWith(p.s[p.i..], "\"\"\"")) {
                    p.i += 3;
                    while (p.peek() == '"') {
                        b.ch('"');
                        p.i += 1;
                    }
                    return b.str();
                }
                if (p.s[p.i] == '\\') {
                    var j = p.i + 1;
                    while (j < p.s.len and (p.s[j] == ' ' or p.s[j] == '\t')) j += 1;
                    if (j < p.s.len and (p.s[j] == '\n' or p.s[j] == '\r')) {
                        while (j < p.s.len and (p.s[j] == ' ' or p.s[j] == '\t' or p.s[j] == '\n' or p.s[j] == '\r')) j += 1;
                        p.i = j;
                        continue;
                    }
                    try p.escape(&b);
                    continue;
                }
                b.ch(p.s[p.i]);
                p.i += 1;
            }
            return fail("TOML: unterminated multi-line string", .{});
        }
        p.i += 1;
        while (p.i < p.s.len and p.s[p.i] != '"') {
            if (p.s[p.i] == '\n') break;
            if (p.s[p.i] == '\\') {
                try p.escape(&b);
                continue;
            }
            b.ch(p.s[p.i]);
            p.i += 1;
        }
        if (p.peek() != '"') return fail("TOML line {d}: unterminated string", .{p.line()});
        p.i += 1;
        return b.str();
    }
    fn escape(p: *Toml, b: *v.Buf) anyerror!void {
        p.i += 1;
        const c = p.peek();
        p.i += 1;
        switch (c) {
            'n' => b.ch('\n'),
            't' => b.ch('\t'),
            'r' => b.ch('\r'),
            'b' => b.ch(8),
            'f' => b.ch(12),
            'e' => b.ch(27),
            '"' => b.ch('"'),
            '\\' => b.ch('\\'),
            'u', 'U', 'x' => {
                const n: usize = if (c == 'u') 4 else if (c == 'U') 8 else 2;
                if (p.i + n > p.s.len) return fail("TOML: bad escape", .{});
                const cp = std.fmt.parseInt(u21, p.s[p.i .. p.i + n], 16) catch return fail("TOML: bad unicode escape", .{});
                p.i += n;
                var tmp: [4]u8 = undefined;
                const l = std.unicode.utf8Encode(cp, &tmp) catch return fail("TOML: bad code point", .{});
                b.add(tmp[0..l]);
            },
            else => return fail("TOML line {d}: invalid escape \\{c}", .{ p.line(), c }),
        }
    }
    fn litStr(p: *Toml) anyerror![]const u8 {
        if (v.startsWith(p.s[p.i..], "'''")) {
            p.i += 3;
            if (p.peek() == '\r') p.i += 1;
            if (p.peek() == '\n') p.i += 1;
            const st = p.i;
            const e = v.indexOfPos(p.s, p.i, "'''") orelse return fail("TOML: unterminated literal string", .{});
            p.i = e + 3;
            var end = e;
            while (p.peek() == '\'') {
                p.i += 1;
                end += 1;
            }
            return p.s[st..end];
        }
        p.i += 1;
        const st = p.i;
        while (p.i < p.s.len and p.s[p.i] != '\'' and p.s[p.i] != '\n') p.i += 1;
        if (p.peek() != '\'') return fail("TOML line {d}: unterminated string", .{p.line()});
        p.i += 1;
        return p.s[st .. p.i - 1];
    }
    fn value(p: *Toml) anyerror!Value {
        p.ws();
        const c = p.peek();
        if (c == '"') return v.S(try p.basicStr());
        if (c == '\'') return v.S(try p.litStr());
        if (c == '[') {
            p.i += 1;
            const l = v.newList();
            while (true) {
                p.wsNl();
                if (p.peek() == ']') {
                    p.i += 1;
                    break;
                }
                v.push(l, try p.value());
                p.wsNl();
                if (p.peek() == ',') {
                    p.i += 1;
                } else if (p.peek() == ']') {
                    p.i += 1;
                    break;
                } else return fail("TOML line {d}: expected , or ] in array", .{p.line()});
            }
            return v.L(l);
        }
        if (c == '{') {
            p.i += 1;
            const m = v.newMap();
            while (true) {
                p.wsNl();
                if (p.peek() == '}') {
                    p.i += 1;
                    break;
                }
                const path = try p.keyPath();
                p.ws();
                if (p.peek() != '=') return fail("TOML line {d}: expected = in inline table", .{p.line()});
                p.i += 1;
                const val = try p.value();
                const t = try descend(m, path[0 .. path.len - 1], false);
                t.put(path[path.len - 1], val);
                p.wsNl();
                if (p.peek() == ',') {
                    p.i += 1;
                } else if (p.peek() == '}') {
                    p.i += 1;
                    break;
                } else return fail("TOML line {d}: expected , or }} in inline table", .{p.line()});
            }
            return v.M(m);
        }
        const st = p.i;
        while (p.i < p.s.len) : (p.i += 1) {
            const ch = p.s[p.i];
            if (ch == ',' or ch == ']' or ch == '}' or ch == '\n' or ch == '\r' or ch == '#') break;
        }
        const tok = v.trimWs(p.s[st..p.i]);
        if (tok.len == 0) return fail("TOML line {d}: missing value", .{p.line()});
        if (v.eq(tok, "true")) return v.B(true);
        if (v.eq(tok, "false")) return v.B(false);
        if (tok.len >= 10 and std.ascii.isDigit(tok[0]) and tok[4] == '-') {
            if (tm.parse(tok)) |t| return .{ .time = t };
        }
        const clean = v.replaceAll(tok, "_", "");
        if (std.fmt.parseInt(i64, clean, 0) catch null) |n| return v.I(n);
        if (v.eq(clean, "inf") or v.eq(clean, "+inf")) return .{ .float = std.math.inf(f64) };
        if (v.eq(clean, "-inf")) return .{ .float = -std.math.inf(f64) };
        if (v.endsWith(clean, "nan")) return .{ .float = std.math.nan(f64) };
        if (std.fmt.parseFloat(f64, clean) catch null) |f| return .{ .float = f };
        return fail("TOML line {d}: invalid value '{s}'", .{ p.line(), tok });
    }
};

fn descend(root: *Map, path: []const []const u8, last_array: bool) anyerror!*Map {
    var cur = root;
    for (path, 0..) |k, idx| {
        const is_last = idx == path.len - 1;
        if (cur.get(k)) |ex| {
            switch (ex) {
                .map => |m| {
                    if (is_last and last_array) return fail("TOML: key '{s}' is not an array of tables", .{k});
                    cur = m;
                },
                .list => |l| {
                    if (is_last and last_array) {
                        const nm = v.newMap();
                        v.push(l, v.M(nm));
                        cur = nm;
                    } else {
                        const items = l.items.items;
                        if (items.len == 0 or items[items.len - 1] != .map) return fail("TOML: key '{s}' is not a table", .{k});
                        cur = items[items.len - 1].map;
                    }
                },
                else => return fail("TOML: key '{s}' already has a non-table value", .{k}),
            }
        } else {
            const nm = v.newMap();
            if (is_last and last_array) {
                const l = v.newList();
                v.push(l, v.M(nm));
                cur.put(k, v.L(l));
            } else cur.put(k, v.M(nm));
            cur = nm;
        }
    }
    return cur;
}

pub fn parseToml(src: []const u8) anyerror!*Map {
    var p: Toml = .{ .s = src };
    if (v.startsWith(src, "\xEF\xBB\xBF")) p.i = 3;
    const root = v.newMap();
    var cur = root;
    while (true) {
        p.wsNl();
        if (p.i >= p.s.len) break;
        if (p.peek() == '[') {
            const arr = v.startsWith(p.s[p.i..], "[[");
            p.i += if (arr) 2 else 1;
            const path = try p.keyPath();
            p.ws();
            if (!v.startsWith(p.s[p.i..], if (arr) "]]" else "]")) return fail("TOML line {d}: malformed table header", .{p.line()});
            p.i += if (arr) 2 else 1;
            cur = try descend(root, path, arr);
            continue;
        }
        const path = try p.keyPath();
        p.ws();
        if (p.peek() != '=') return fail("TOML line {d}: expected '=' after key", .{p.line()});
        p.i += 1;
        const val = try p.value();
        const t = try descend(cur, path[0 .. path.len - 1], false);
        t.put(path[path.len - 1], val);
        p.ws();
        if (p.i < p.s.len and p.peek() != '\n' and p.peek() != '\r' and p.peek() != '#') return fail("TOML line {d}: unexpected trailing characters", .{p.line()});
    }
    return root;
}

// =============================================================== YAML / JSON

const YLine = struct { indent: usize, text: []const u8, raw: []const u8 };

fn stripComment(s: []const u8) []const u8 {
    var q: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (q != 0) {
            if (c == '\\' and q == '"') {
                i += 1;
            } else if (c == q) q = 0;
        } else if ((c == '"' or c == '\'') and (i == 0 or s[i - 1] == ' ' or s[i - 1] == ':' or s[i - 1] == '[' or s[i - 1] == '{' or s[i - 1] == ',' or s[i - 1] == '-')) {
            q = c;
        } else if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
            return s[0..i];
        }
    }
    return s;
}

const Yaml = struct {
    lines: []YLine,
    i: usize = 0,

    fn skipBlank(p: *Yaml) void {
        while (p.i < p.lines.len and p.lines[p.i].text.len == 0) p.i += 1;
    }

    fn node(p: *Yaml, min: usize) anyerror!Value {
        p.skipBlank();
        if (p.i >= p.lines.len) return .nil;
        const ln = p.lines[p.i];
        if (ln.indent < min) return .nil;
        if (isSeq(ln.text)) return p.seq(ln.indent);
        if (splitKey(ln.text) != null) return p.mapping(ln.indent);
        p.i += 1;
        return p.scalarMulti(ln.text, ln.indent, false);
    }

    fn isSeq(t: []const u8) bool {
        return v.eq(t, "-") or v.startsWith(t, "- ");
    }

    fn seq(p: *Yaml, ind: usize) anyerror!Value {
        const l = v.newList();
        while (true) {
            p.skipBlank();
            if (p.i >= p.lines.len) break;
            const ln = p.lines[p.i];
            if (ln.indent != ind or !isSeq(ln.text)) break;
            const rest_raw = ln.text[1..];
            const rest = std.mem.trimStart(u8, rest_raw, " ");
            if (rest.len == 0) {
                p.i += 1;
                v.push(l, try p.node(ind + 1));
            } else {
                const off = 1 + (rest_raw.len - rest.len);
                p.lines[p.i] = .{ .indent = ind + off, .text = rest, .raw = ln.raw };
                v.push(l, try p.node(ind + off));
            }
        }
        return v.L(l);
    }

    const KV = struct { key: []const u8, rest: []const u8 };

    fn splitKey(t: []const u8) ?KV {
        if (t.len == 0) return null;
        if (t[0] == '"' or t[0] == '\'') {
            const q = t[0];
            var i: usize = 1;
            while (i < t.len and t[i] != q) : (i += 1) {
                if (t[i] == '\\' and q == '"') i += 1;
            }
            if (i >= t.len) return null;
            const after = std.mem.trimStart(u8, t[i + 1 ..], " ");
            if (after.len == 0 or after[0] != ':') return null;
            if (after.len > 1 and after[1] != ' ') return null;
            return .{ .key = unquote(t[0 .. i + 1]), .rest = v.trimWs(after[1..]) };
        }
        if (t[0] == '[' or t[0] == '{') return null;
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            if (t[i] == ':' and (i + 1 == t.len or t[i + 1] == ' ')) {
                return .{ .key = v.trimWs(t[0..i]), .rest = v.trimWs(t[i + 1 ..]) };
            }
        }
        return null;
    }

    fn mapping(p: *Yaml, ind: usize) anyerror!Value {
        const m = v.newMap();
        while (true) {
            p.skipBlank();
            if (p.i >= p.lines.len) break;
            const ln = p.lines[p.i];
            if (ln.indent != ind) break;
            const kv = splitKey(ln.text) orelse break;
            p.i += 1;
            var val: Value = .nil;
            if (kv.rest.len == 0) {
                p.skipBlank();
                if (p.i < p.lines.len) {
                    const nx = p.lines[p.i];
                    if (nx.indent > ind) {
                        val = try p.node(ind + 1);
                    } else if (nx.indent == ind and isSeq(nx.text)) {
                        val = try p.seq(ind);
                    }
                }
            } else if (kv.rest[0] == '|' or kv.rest[0] == '>') {
                val = v.S(p.blockScalar(kv.rest, ind));
            } else {
                val = try p.scalarMulti(kv.rest, ind, true);
            }
            m.put(kv.key, val);
        }
        return v.M(m);
    }

    fn blockScalar(p: *Yaml, hdr: []const u8, ind: usize) []const u8 {
        const folded = hdr[0] == '>';
        const chomp: u8 = if (v.indexOfChar(hdr, '-') != null) '-' else if (v.indexOfChar(hdr, '+') != null) '+' else 0;
        var block_ind: ?usize = null;
        var b: v.Buf = .{};
        var pending_nl: usize = 0;
        var first = true;
        var prev_more = false;
        while (p.i < p.lines.len) : (p.i += 1) {
            const raw = p.lines[p.i].raw;
            const trimmed = std.mem.trimStart(u8, raw, " ");
            if (v.trimWs(raw).len == 0) {
                pending_nl += 1;
                continue;
            }
            const li = raw.len - trimmed.len;
            if (li <= ind) break;
            if (block_ind == null) block_ind = li;
            const bi = block_ind.?;
            if (li < bi) break;
            const content = std.mem.trimEnd(u8, raw[bi..], "\r");
            const more = content.len > 0 and content[0] == ' ';
            if (!first) {
                if (folded and pending_nl == 0 and !more and !prev_more) b.ch(' ') else {
                    b.ch('\n');
                    var k: usize = 0;
                    while (k < pending_nl) : (k += 1) b.ch('\n');
                    if (folded and pending_nl > 0 and !more and !prev_more) _ = b.l.pop();
                }
            } else {
                var k: usize = 0;
                while (k < pending_nl) : (k += 1) b.ch('\n');
            }
            pending_nl = 0;
            b.add(content);
            first = false;
            prev_more = more;
        }
        if (chomp != '-' and !first) b.ch('\n');
        if (chomp == '+') {
            var k: usize = 0;
            while (k < pending_nl) : (k += 1) b.ch('\n');
        }
        return b.str();
    }

    /// Scalar or flow collection that may continue on following (more indented) lines.
    fn scalarMulti(p: *Yaml, first: []const u8, ind: usize, in_map: bool) anyerror!Value {
        var text = first;
        const c = first[0];
        if (c == '[' or c == '{') {
            while (!balanced(text) and p.i < p.lines.len) : (p.i += 1) {
                text = v.concat(&.{ text, " ", p.lines[p.i].text });
            }
            var f: Flow = .{ .s = text };
            return f.value();
        }
        if (c == '"' or c == '\'') {
            while (!quoteClosed(text) and p.i < p.lines.len) : (p.i += 1) {
                const t = v.trimWs(p.lines[p.i].raw);
                text = v.concat(&.{ text, if (t.len == 0) "\n" else " ", t });
            }
            return v.S(unquote(v.trimWs(text)));
        }
        // plain multi-line continuation
        while (p.i < p.lines.len) {
            const nx = p.lines[p.i];
            if (nx.text.len == 0) break;
            if (in_map) {
                if (nx.indent <= ind) break;
            } else if (nx.indent < ind or isSeq(nx.text) or splitKey(nx.text) != null) break;
            text = v.concat(&.{ text, " ", nx.text });
            p.i += 1;
        }
        return plain(text);
    }
};

fn balanced(s: []const u8) bool {
    var depth: i32 = 0;
    var q: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (q != 0) {
            if (c == '\\' and q == '"') {
                i += 1;
            } else if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == '[' or c == '{') {
            depth += 1;
        } else if (c == ']' or c == '}') depth -= 1;
    }
    return depth <= 0;
}

fn quoteClosed(s: []const u8) bool {
    const q = s[0];
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and q == '"') {
            i += 1;
        } else if (s[i] == q) {
            if (q == '\'' and i + 1 < s.len and s[i + 1] == '\'') {
                i += 1;
                continue;
            }
            return true;
        }
    }
    return false;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    const q = s[0];
    var end = s.len - 1;
    // find the real closing quote (ignore trailing junk)
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and q == '"') {
            i += 1;
        } else if (s[i] == q) {
            if (q == '\'' and i + 1 < s.len and s[i + 1] == '\'') {
                i += 1;
                continue;
            }
            end = i;
            break;
        }
    }
    const body = s[1..end];
    if (q == '\'') return v.replaceAll(body, "''", "'");
    var b: v.Buf = .{};
    i = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\' or i + 1 >= body.len) {
            b.ch(body[i]);
            continue;
        }
        i += 1;
        switch (body[i]) {
            'n' => b.ch('\n'),
            't' => b.ch('\t'),
            'r' => b.ch('\r'),
            '0' => b.ch(0),
            'b' => b.ch(8),
            'f' => b.ch(12),
            '/' => b.ch('/'),
            'e' => b.ch(27),
            ' ' => b.ch(' '),
            '_' => b.add("\u{a0}"),
            'u', 'x', 'U' => {
                const n: usize = if (body[i] == 'u') 4 else if (body[i] == 'x') 2 else 8;
                if (i + n < body.len + 0 and i + 1 + n <= body.len) {
                    var cp: u21 = std.fmt.parseInt(u21, body[i + 1 .. i + 1 + n], 16) catch 0xFFFD;
                    i += n;
                    // surrogate pair
                    if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 < body.len + 0 and body[i + 1] == '\\' and body[i + 2] == 'u') {
                        const lo = std.fmt.parseInt(u21, body[i + 3 .. i + 7], 16) catch 0;
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            i += 6;
                        }
                    }
                    var tmp: [4]u8 = undefined;
                    const l = std.unicode.utf8Encode(cp, &tmp) catch 0;
                    b.add(tmp[0..l]);
                }
            },
            else => b.ch(body[i]),
        }
    }
    return b.str();
}

fn plain(t_in: []const u8) Value {
    const t = v.trimWs(t_in);
    if (t.len == 0 or v.eq(t, "~") or v.eq(t, "null") or v.eq(t, "Null") or v.eq(t, "NULL")) return .nil;
    if (v.eq(t, "true") or v.eq(t, "True") or v.eq(t, "TRUE")) return v.B(true);
    if (v.eq(t, "false") or v.eq(t, "False") or v.eq(t, "FALSE")) return v.B(false);
    if (std.ascii.isDigit(t[0]) or t[0] == '-' or t[0] == '+' or t[0] == '.') {
        if (std.fmt.parseInt(i64, t, 10) catch null) |n| return v.I(n);
        if (v.startsWith(t, "0x")) if (std.fmt.parseInt(i64, t[2..], 16) catch null) |n| return v.I(n);
        if (t.len >= 10 and t[4] == '-' and t[7] == '-') if (tm.parse(t)) |d| return .{ .time = d };
        var numeric = true;
        for (t) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '-' or c == '+')) {
            numeric = false;
        };
        if (numeric) if (std.fmt.parseFloat(f64, t) catch null) |f| return .{ .float = f };
    }
    return v.S(t);
}

const Flow = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(p: *Flow) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }
    fn quoted(p: *Flow) []const u8 {
        const q = p.s[p.i];
        const st = p.i;
        p.i += 1;
        while (p.i < p.s.len) : (p.i += 1) {
            if (p.s[p.i] == '\\' and q == '"') {
                p.i += 1;
            } else if (p.s[p.i] == q) {
                if (q == '\'' and p.i + 1 < p.s.len and p.s[p.i + 1] == '\'') {
                    p.i += 1;
                    continue;
                }
                break;
            }
        }
        p.i = @min(p.i + 1, p.s.len);
        return unquote(p.s[st..p.i]);
    }
    fn value(p: *Flow) anyerror!Value {
        p.ws();
        if (p.i >= p.s.len) return .nil;
        const c = p.s[p.i];
        if (c == '[') {
            p.i += 1;
            const l = v.newList();
            while (true) {
                p.ws();
                if (p.i >= p.s.len) return fail("unterminated [ in flow sequence", .{});
                if (p.s[p.i] == ']') {
                    p.i += 1;
                    break;
                }
                v.push(l, try p.value());
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == ',') p.i += 1;
            }
            return v.L(l);
        }
        if (c == '{') {
            p.i += 1;
            const m = v.newMap();
            while (true) {
                p.ws();
                if (p.i >= p.s.len) return fail("unterminated {{ in flow mapping", .{});
                if (p.s[p.i] == '}') {
                    p.i += 1;
                    break;
                }
                var key: []const u8 = undefined;
                if (p.s[p.i] == '"' or p.s[p.i] == '\'') {
                    key = p.quoted();
                } else {
                    const st = p.i;
                    while (p.i < p.s.len and p.s[p.i] != ':' and p.s[p.i] != ',' and p.s[p.i] != '}') p.i += 1;
                    key = v.trimWs(p.s[st..p.i]);
                }
                p.ws();
                var val: Value = .nil;
                if (p.i < p.s.len and p.s[p.i] == ':') {
                    p.i += 1;
                    val = try p.value();
                }
                m.put(key, val);
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == ',') p.i += 1;
            }
            return v.M(m);
        }
        if (c == '"' or c == '\'') return v.S(p.quoted());
        const st = p.i;
        while (p.i < p.s.len and p.s[p.i] != ',' and p.s[p.i] != ']' and p.s[p.i] != '}') p.i += 1;
        return plain(p.s[st..p.i]);
    }
};

pub fn parseYaml(src: []const u8) anyerror!Value {
    var lines: std.ArrayList(YLine) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw0| {
        var raw = std.mem.trimEnd(u8, raw0, "\r");
        if (first and v.startsWith(raw, "\xEF\xBB\xBF")) raw = raw[3..];
        first = false;
        if (v.startsWith(raw, "---") and (raw.len == 3 or raw[3] == ' ')) {
            try lines.append(sys.A, .{ .indent = 0, .text = "", .raw = "" });
            continue;
        }
        if (v.contains(raw, "\t") and v.trimWs(raw).len > 0) {
            // tabs are not valid YAML indentation; treat leading tabs as 2 spaces to be lenient
            var k: usize = 0;
            while (k < raw.len and (raw[k] == ' ' or raw[k] == '\t')) k += 1;
            if (v.indexOfChar(raw[0..k], '\t') != null) raw = v.concat(&.{ v.replaceAll(raw[0..k], "\t", "  "), raw[k..] });
        }
        const lead = raw.len - std.mem.trimStart(u8, raw, " ").len;
        const text = std.mem.trimEnd(u8, stripComment(raw[lead..]), " \t");
        try lines.append(sys.A, .{ .indent = lead, .text = text, .raw = raw });
    }
    var p: Yaml = .{ .lines = lines.items };
    return p.node(0);
}

pub fn parseJson(src: []const u8) anyerror!Value {
    var f: Flow = .{ .s = src };
    if (v.startsWith(src, "\xEF\xBB\xBF")) f.i = 3;
    return f.value();
}

pub fn parseCsv(src: []const u8, delim: u8) Value {
    const rows = v.newList();
    var i: usize = 0;
    var row = v.newList();
    var cell: v.Buf = .{};
    var inq = false;
    var any = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (inq) {
            if (c == '"') {
                if (i + 1 < src.len and src[i + 1] == '"') {
                    cell.ch('"');
                    i += 1;
                } else inq = false;
            } else cell.ch(c);
            continue;
        }
        if (c == '"') {
            inq = true;
            any = true;
        } else if (c == delim) {
            v.push(row, v.S(cell.str()));
            cell = .{};
            any = true;
        } else if (c == '\n') {
            if (any or cell.len() > 0) {
                v.push(row, v.S(cell.str()));
                v.push(rows, v.L(row));
            }
            row = v.newList();
            cell = .{};
            any = false;
        } else if (c != '\r') {
            cell.ch(c);
        }
    }
    if (any or cell.len() > 0) {
        v.push(row, v.S(cell.str()));
        v.push(rows, v.L(row));
    }
    return v.L(rows);
}

// =============================================================== XML

const Xml = struct {
    s: []const u8,
    i: usize = 0,

    fn skipMisc(p: *Xml) void {
        while (p.i < p.s.len) {
            while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\n' or p.s[p.i] == '\t' or p.s[p.i] == '\r')) p.i += 1;
            if (v.startsWith(p.s[p.i..], "<?")) {
                p.i = (v.indexOfPos(p.s, p.i, "?>") orelse p.s.len - 2) + 2;
            } else if (v.startsWith(p.s[p.i..], "<!--")) {
                p.i = (v.indexOfPos(p.s, p.i, "-->") orelse p.s.len - 3) + 3;
            } else if (v.startsWith(p.s[p.i..], "<!") and !v.startsWith(p.s[p.i..], "<![CDATA[")) {
                p.i = (v.indexOfPos(p.s, p.i, ">") orelse p.s.len - 1) + 1;
            } else break;
        }
    }

    const Elem = struct { name: []const u8, val: Value };

    /// Parses one element starting at '<'. Mirrors the mxj conventions Hugo uses:
    /// attributes become "-name", text mixed with attributes/children becomes "#text".
    fn element(p: *Xml) anyerror!Elem {
        p.i += 1;
        const ns = p.i;
        while (p.i < p.s.len and !(p.s[p.i] == ' ' or p.s[p.i] == '>' or p.s[p.i] == '/' or p.s[p.i] == '\n' or p.s[p.i] == '\t' or p.s[p.i] == '\r')) p.i += 1;
        const name = p.s[ns..p.i];
        const m = v.newMap();
        // attributes
        while (p.i < p.s.len) {
            while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\n' or p.s[p.i] == '\t' or p.s[p.i] == '\r')) p.i += 1;
            if (p.i >= p.s.len) return fail("XML: unexpected end of input in <{s}>", .{name});
            if (p.s[p.i] == '/') {
                p.i = @min(p.i + 2, p.s.len);
                return .{ .name = name, .val = if (m.m.count() == 0) v.S("") else v.M(m) };
            }
            if (p.s[p.i] == '>') {
                p.i += 1;
                break;
            }
            const as = p.i;
            while (p.i < p.s.len and p.s[p.i] != '=' and p.s[p.i] != ' ' and p.s[p.i] != '>' and p.s[p.i] != '/') p.i += 1;
            const an = p.s[as..p.i];
            var av: []const u8 = "";
            if (p.i < p.s.len and p.s[p.i] == '=') {
                p.i += 1;
                if (p.i < p.s.len and (p.s[p.i] == '"' or p.s[p.i] == '\'')) {
                    const q = p.s[p.i];
                    const e = v.indexOfPos(p.s, p.i + 1, &.{q}) orelse return fail("XML: unterminated attribute in <{s}>", .{name});
                    av = v.htmlUnescape(p.s[p.i + 1 .. e]);
                    p.i = e + 1;
                }
            }
            m.put(v.concat(&.{ "-", an }), v.S(av));
        }
        var text: v.Buf = .{};
        var children: usize = 0;
        while (p.i < p.s.len) {
            if (v.startsWith(p.s[p.i..], "</")) {
                p.i = (v.indexOfPos(p.s, p.i, ">") orelse p.s.len - 1) + 1;
                break;
            }
            if (v.startsWith(p.s[p.i..], "<![CDATA[")) {
                const e = v.indexOfPos(p.s, p.i, "]]>") orelse p.s.len;
                text.add(p.s[p.i + 9 .. e]);
                p.i = @min(e + 3, p.s.len);
            } else if (v.startsWith(p.s[p.i..], "<!--") or v.startsWith(p.s[p.i..], "<?")) {
                p.skipMisc();
            } else if (p.s[p.i] == '<') {
                const ch = try p.element();
                children += 1;
                if (m.get(ch.name)) |ex| {
                    if (ex == .list) v.push(ex.list, ch.val) else m.put(ch.name, v.listOf(&.{ ex, ch.val }));
                } else m.put(ch.name, ch.val);
            } else {
                const e = v.indexOfPos(p.s, p.i, "<") orelse p.s.len;
                text.add(v.htmlUnescape(p.s[p.i..e]));
                p.i = e;
            }
        }
        const t = v.trimWs(text.str());
        if (m.m.count() == 0) return .{ .name = name, .val = v.S(t) };
        if (t.len > 0) m.put("#text", v.S(t));
        return .{ .name = name, .val = v.M(m) };
    }
};

/// Returns the content of the root element (like Hugo's transform.Unmarshal for XML).
pub fn parseXml(src: []const u8) anyerror!Value {
    var p: Xml = .{ .s = src };
    p.skipMisc();
    if (p.i >= src.len or src[p.i] != '<') return fail("XML: no root element", .{});
    const root = try p.element();
    return root.val;
}

/// Parse by file extension.
pub fn parseByExt(ext: []const u8, src: []const u8) anyerror!Value {
    if (v.eqi(ext, ".toml")) return v.M(try parseToml(src));
    if (v.eqi(ext, ".yaml") or v.eqi(ext, ".yml")) return parseYaml(src);
    if (v.eqi(ext, ".json")) return parseJson(src);
    if (v.eqi(ext, ".csv")) return parseCsv(src, ',');
    if (v.eqi(ext, ".xml") or v.eqi(ext, ".svg")) return parseXml(src);
    return fail("unsupported data format {s}", .{ext});
}

/// Sniff format (used by transform.Unmarshal on strings).
pub fn parseAuto(src: []const u8) anyerror!Value {
    const t = v.trimWs(src);
    if (t.len == 0) return .nil;
    if (t[0] == '{' or t[0] == '[') return parseJson(t);
    if (parseToml(src)) |m| {
        if (m.m.count() > 0) return v.M(m);
    } else |_| {}
    return parseYaml(src);
}

// =============================================================== JSON writer

pub fn jsonStr(b: *v.Buf, s: []const u8, html_escape: bool) void {
    b.ch('"');
    for (s) |c| switch (c) {
        '"' => b.add("\\\""),
        '\\' => b.add("\\\\"),
        '\n' => b.add("\\n"),
        '\r' => b.add("\\r"),
        '\t' => b.add("\\t"),
        '<' => if (html_escape) b.add("\\u003c") else b.ch(c),
        '>' => if (html_escape) b.add("\\u003e") else b.ch(c),
        '&' => if (html_escape) b.add("\\u0026") else b.ch(c),
        else => if (c < 0x20) b.print("\\u{x:0>4}", .{c}) else b.ch(c),
    };
    b.ch('"');
}

pub const JsonOpts = struct { indent: []const u8 = "", prefix: []const u8 = "", html_escape: bool = true };

pub fn toJson(b: *v.Buf, val: Value, o: JsonOpts, depth: usize) void {
    switch (val) {
        .nil => b.add("null"),
        .bool => |x| b.add(if (x) "true" else "false"),
        .int => |x| b.print("{d}", .{x}),
        .float => |x| b.add(v.floatStr(x)),
        .str => |s| jsonStr(b, s, o.html_escape),
        .safe => |s| jsonStr(b, s.s, o.html_escape),
        .time => |t| jsonStr(b, tm.format(t, "2006-01-02T15:04:05Z07:00"), false),
        .dur => |d| b.print("{d}", .{d}),
        .obj => jsonStr(b, v.toStr(val), o.html_escape),
        .list => |l| {
            if (l.items.items.len == 0) return b.add("[]");
            b.ch('[');
            for (l.items.items, 0..) |it, i| {
                if (i > 0) b.ch(',');
                nl(b, o, depth + 1);
                toJson(b, it, o, depth + 1);
            }
            nl(b, o, depth);
            b.ch(']');
        },
        .map => |m| {
            if (m.m.count() == 0) return b.add("{}");
            b.ch('{');
            for (v.sortedKeys(m), 0..) |k, i| {
                if (i > 0) b.ch(',');
                nl(b, o, depth + 1);
                jsonStr(b, k, o.html_escape);
                b.ch(':');
                if (o.indent.len > 0) b.ch(' ');
                toJson(b, m.m.get(k).?, o, depth + 1);
            }
            nl(b, o, depth);
            b.ch('}');
        },
    }
}

fn scalarText(b: *v.Buf, val: Value, toml: bool) void {
    switch (val) {
        .str, .safe => {
            const s = v.rawStr(val).?;
            var plain_ok = !toml and s.len > 0;
            for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == ' ' or c == '_' or c == '-' or c == '/' or c == '.')) {
                plain_ok = false;
            };
            if (plain_ok and (std.fmt.parseFloat(f64, s) catch null) == null and !v.eq(s, "true") and !v.eq(s, "false") and !v.eq(s, "null") and s[0] != ' ' and s[0] != '-') b.add(s) else jsonStr(b, s, false);
        },
        .time => |t| b.add(tm.format(t, "2006-01-02T15:04:05Z07:00")),
        .nil => b.add(if (toml) "''" else "null"),
        else => toJson(b, val, .{ .html_escape = false }, 0),
    }
}

fn yamlNode(b: *v.Buf, val: Value, indent: usize) void {
    const pad = struct {
        fn f(buf: *v.Buf, n: usize) void {
            var k: usize = 0;
            while (k < n) : (k += 1) buf.ch(' ');
        }
    }.f;
    switch (val) {
        .map => |m| for (v.sortedKeys(m)) |k| {
            const x = m.m.get(k).?;
            pad(b, indent);
            b.add(k);
            b.ch(':');
            if ((x == .map and x.map.m.count() > 0) or (x == .list and x.list.items.items.len > 0)) {
                b.ch('\n');
                yamlNode(b, x, if (x == .list) indent else indent + 2);
            } else {
                b.ch(' ');
                if (x == .map) b.add("{}") else if (x == .list) b.add("[]") else scalarText(b, x, false);
                b.ch('\n');
            }
        },
        .list => |l| for (l.items.items) |x| {
            pad(b, indent);
            b.add("- ");
            if (x == .map and x.map.m.count() > 0) {
                var tmp: v.Buf = .{};
                yamlNode(&tmp, x, indent + 2);
                b.add(std.mem.trimStart(u8, tmp.str(), " "));
            } else {
                scalarText(b, x, false);
                b.ch('\n');
            }
        },
        else => {
            scalarText(b, val, false);
            b.ch('\n');
        },
    }
}

fn tomlTable(b: *v.Buf, m: *Map, prefix: []const u8) void {
    const keys = v.sortedKeys(m);
    for (keys) |k| {
        const x = m.m.get(k).?;
        if (x == .map) continue;
        if (x == .list and x.list.items.items.len > 0 and x.list.items.items[0] == .map) continue;
        b.add(k);
        b.add(" = ");
        if (x == .list) {
            b.ch('[');
            for (x.list.items.items, 0..) |it, i| {
                if (i > 0) b.add(", ");
                scalarText(b, it, true);
            }
            b.ch(']');
        } else scalarText(b, x, true);
        b.ch('\n');
    }
    for (keys) |k| {
        const x = m.m.get(k).?;
        const full = if (prefix.len > 0) v.concat(&.{ prefix, ".", k }) else k;
        if (x == .map) {
            b.print("\n[{s}]\n", .{full});
            tomlTable(b, x.map, full);
        } else if (x == .list and x.list.items.items.len > 0 and x.list.items.items[0] == .map) {
            for (x.list.items.items) |it| if (it == .map) {
                b.print("\n[[{s}]]\n", .{full});
                tomlTable(b, it.map, full);
            };
        }
    }
}

pub fn toYamlToml(b: *v.Buf, val: Value, toml: bool) void {
    if (toml) {
        if (val == .map) tomlTable(b, val.map, "");
    } else yamlNode(b, val, 0);
}

fn nl(b: *v.Buf, o: JsonOpts, depth: usize) void {
    if (o.indent.len == 0) return;
    b.ch('\n');
    b.add(o.prefix);
    var i: usize = 0;
    while (i < depth) : (i += 1) b.add(o.indent);
}

/// Deep merge `src` into `dst` without overwriting existing keys (theme config defaults).
pub fn mergeDefaults(dst: *Map, src: *const Map) void {
    for (src.m.keys(), src.m.values()) |k, val| {
        if (dst.getCI(k)) |ex| {
            if (ex == .map and val == .map) mergeDefaults(ex.map, val.map);
        } else dst.put(k, deepCopy(val));
    }
}

pub fn deepCopy(val: Value) Value {
    switch (val) {
        .map => |m| {
            const n = v.newMap();
            for (m.m.keys(), m.m.values()) |k, x| n.put(k, deepCopy(x));
            return v.M(n);
        },
        .list => |l| {
            const n = v.newList();
            for (l.items.items) |x| v.push(n, deepCopy(x));
            return v.L(n);
        },
        else => return val,
    }
}

/// Lower-case all keys recursively (Hugo params semantics).
pub fn lowerKeys(val: Value) Value {
    switch (val) {
        .map => |m| {
            const n = v.newMap();
            for (m.m.keys(), m.m.values()) |k, x| n.put(v.lower(k), lowerKeys(x));
            return v.M(n);
        },
        .list => |l| {
            const n = v.newList();
            for (l.items.items) |x| v.push(n, lowerKeys(x));
            return v.L(n);
        },
        else => return val,
    }
}
