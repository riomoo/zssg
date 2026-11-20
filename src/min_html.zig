// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/minify and tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! HTML minifier: a port of tdewolff/parse/html (lexer) and
//! tdewolff/minify/html (MIT) with Hugo's default options (keep document
//! tags, end tags, default attribute values and special comments).
const std = @import("std");
const sys = @import("sys.zig");
const min = @import("min.zig");
const tables = @import("min_html_tables.zig");

const TT = enum { err, comment, doctype, start_tag, start_tag_close, start_tag_void, end_tag, attribute, text, svg, math, xml, template };
const LexTok = struct { tt: TT, data: []u8 };

// ================================================================ lexer

const Lexer = struct {
    b: []u8, // mutable copy: the Go lexer lower-cases names in place
    pos: usize = 0,
    start: usize = 0,
    raw_tag: []const u8 = "",
    in_tag: bool = false,
    text: ?[]u8 = null,
    attr_val: ?[]u8 = null,
    failed: bool = false,

    fn peek(l: *const Lexer, n: usize) u8 {
        return if (l.pos + n < l.b.len) l.b[l.pos + n] else 0;
    }
    fn eofAt(l: *const Lexer, n: usize) bool {
        return l.pos + n >= l.b.len;
    }
    fn eof(l: *const Lexer) bool {
        return l.pos >= l.b.len;
    }
    fn shift(l: *Lexer) []u8 {
        const r = l.b[l.start..l.pos];
        l.start = l.pos;
        return r;
    }
    fn lexeme(l: *Lexer) []u8 {
        return l.b[l.start..l.pos];
    }
    fn rel(l: *const Lexer) usize {
        return l.pos - l.start;
    }
    fn at(l: *const Lexer, s: []const u8) bool {
        for (s, 0..) |c, i| if (l.peek(i) != c) return false;
        return true;
    }
    fn atCI(l: *const Lexer, s: []const u8) bool {
        for (s, 0..) |c, i| if (l.peek(i) != c and l.peek(i) +% ('a' - 'A') != c) return false;
        return true;
    }
    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
    }
    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }
    fn lower(s: []u8) []u8 {
        for (s) |*c| c.* = std.ascii.toLower(c.*);
        return s;
    }

    fn next(l: *Lexer) LexTok {
        l.text = null;
        var c: u8 = 0;
        if (l.in_tag) {
            l.attr_val = null;
            while (true) {
                c = l.peek(0);
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
                    l.pos += 1;
                    continue;
                }
                break;
            }
            if (c == 0 and l.eof()) return .{ .tt = .err, .data = &.{} };
            if (c != '>' and (c != '/' or l.peek(1) != '>')) return .{ .tt = .attribute, .data = l.shiftAttribute() };
            l.start = l.pos;
            l.in_tag = false;
            if (c == '/') {
                l.pos += 2;
                return .{ .tt = .start_tag_void, .data = l.shift() };
            }
            l.pos += 1;
            return .{ .tt = .start_tag_close, .data = l.shift() };
        }
        if (l.raw_tag.len > 0) {
            const raw = l.shiftRawText();
            l.raw_tag = "";
            if (raw.len > 0) {
                l.text = raw;
                return .{ .tt = .text, .data = raw };
            }
        }
        while (true) {
            c = l.peek(0);
            if (c == '<') {
                c = l.peek(1);
                const is_end = c == '/' and l.peek(2) != '>' and (l.peek(2) != 0 or !l.eofAt(2));
                if (!is_end and !isAlpha(c) and c != '!' and c != '?') {
                    l.pos += 1;
                } else if (l.rel() > 0) {
                    l.text = l.shift();
                    return .{ .tt = .text, .data = l.text.? };
                } else if (is_end) {
                    l.pos += 2;
                    if (!isAlpha(l.peek(0))) return .{ .tt = .comment, .data = l.shiftBogusComment() };
                    return .{ .tt = .end_tag, .data = l.shiftEndTag() };
                } else if (isAlpha(c)) {
                    l.pos += 1;
                    l.in_tag = true;
                    return l.shiftStartTag();
                } else if (c == '!') {
                    l.pos += 2;
                    return l.readMarkup();
                } else if (c == '?') {
                    l.pos += 1;
                    return .{ .tt = .comment, .data = l.shiftBogusComment() };
                }
            } else if (c == 0 and l.eof()) {
                if (l.rel() > 0) {
                    l.text = l.shift();
                    return .{ .tt = .text, .data = l.text.? };
                }
                return .{ .tt = .err, .data = &.{} };
            } else l.pos += 1;
        }
    }

    fn nameAt(l: *Lexer, from: usize) []const u8 {
        const s = l.b[from..l.pos];
        const o = sys.A.alloc(u8, s.len) catch return "";
        for (s, 0..) |ch, i| o[i] = std.ascii.toLower(ch);
        return o;
    }

    fn shiftRawText(l: *Lexer) []u8 {
        if (std.mem.eql(u8, l.raw_tag, "plaintext")) {
            l.pos = l.b.len;
            return l.shift();
        }
        while (true) {
            const c = l.peek(0);
            if (c == '<') {
                if (l.peek(1) == '/') {
                    const mark = l.pos;
                    l.pos += 2;
                    while (isAlpha(l.peek(0))) l.pos += 1;
                    if (std.mem.eql(u8, l.nameAt(mark + 2), l.raw_tag)) {
                        l.pos = mark;
                        return l.shift();
                    }
                } else if (std.mem.eql(u8, l.raw_tag, "script") and l.peek(1) == '!' and l.peek(2) == '-' and l.peek(3) == '-') {
                    l.pos += 4;
                    var in_script = false;
                    while (true) {
                        const d = l.peek(0);
                        if (d == '-' and l.peek(1) == '-' and l.peek(2) == '>') {
                            l.pos += 3;
                            break;
                        } else if (d == '<') {
                            const is_end = l.peek(1) == '/';
                            l.pos += if (is_end) 2 else 1;
                            const mark = l.pos;
                            while (isAlpha(l.peek(0))) l.pos += 1;
                            if (std.mem.eql(u8, l.nameAt(mark), "script")) {
                                if (!is_end) {
                                    in_script = true;
                                } else {
                                    if (!in_script) {
                                        l.pos = mark - 2;
                                        return l.shift();
                                    }
                                    in_script = false;
                                }
                            }
                        } else if (d == 0 and l.eof()) {
                            return l.shift();
                        } else l.pos += 1;
                    }
                } else l.pos += 1;
            } else if (c == 0 and l.eof()) {
                return l.shift();
            } else l.pos += 1;
        }
    }

    fn readMarkup(l: *Lexer) LexTok {
        if (l.at("--")) {
            l.pos += 2;
            while (true) {
                if (l.peek(0) == 0 and l.eof()) {
                    l.text = l.lexeme()[4..];
                    return .{ .tt = .comment, .data = l.shift() };
                } else if (l.at("-->")) {
                    l.text = l.lexeme()[4..];
                    l.pos += 3;
                    return .{ .tt = .comment, .data = l.shift() };
                } else if (l.at("--!>")) {
                    l.text = l.lexeme()[4..];
                    l.pos += 4;
                    return .{ .tt = .comment, .data = l.shift() };
                }
                l.pos += 1;
            }
        } else if (l.at("[CDATA[")) {
            l.pos += 7;
            while (true) {
                if (l.peek(0) == 0 and l.eof()) {
                    l.text = l.lexeme()[9..];
                    return .{ .tt = .text, .data = l.shift() };
                } else if (l.at("]]>")) {
                    l.text = l.lexeme()[9..];
                    l.pos += 3;
                    return .{ .tt = .text, .data = l.shift() };
                }
                l.pos += 1;
            }
        } else if (l.atCI("doctype")) {
            l.pos += 7;
            if (l.peek(0) == ' ') l.pos += 1;
            while (true) {
                const c = l.peek(0);
                if (c == '>' or (c == 0 and l.eof())) {
                    const lx = l.lexeme();
                    l.text = if (lx.len >= 9) lx[9..] else lx[lx.len..];
                    if (c == '>') l.pos += 1;
                    return .{ .tt = .doctype, .data = l.shift() };
                }
                l.pos += 1;
            }
        }
        return .{ .tt = .comment, .data = l.shiftBogusComment() };
    }

    fn shiftBogusComment(l: *Lexer) []u8 {
        while (true) {
            const c = l.peek(0);
            if (c == '>') {
                l.text = l.lexeme()[2..];
                l.pos += 1;
                return l.shift();
            } else if (c == 0 and l.eof()) {
                l.text = l.lexeme()[@min(2, l.rel())..];
                return l.shift();
            }
            l.pos += 1;
        }
    }

    fn shiftStartTag(l: *Lexer) LexTok {
        while (true) {
            const c = l.peek(0);
            if (c == ' ' or c == '>' or (c == '/' and l.peek(1) == '>') or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or (c == 0 and l.eof())) break;
            l.pos += 1;
        }
        l.text = lower(l.lexeme()[1..]);
        const h = l.text.?;
        const raw_names = [_][]const u8{ "textarea", "title", "style", "xmp", "iframe", "script", "plaintext", "svg", "math", "xml" };
        for (raw_names) |rn| if (std.mem.eql(u8, h, rn)) {
            if (std.mem.eql(u8, h, "svg") or std.mem.eql(u8, h, "math") or std.mem.eql(u8, h, "xml")) {
                const data = l.shiftXML(rn);
                if (l.failed) return .{ .tt = .err, .data = &.{} };
                l.in_tag = false;
                if (std.mem.eql(u8, h, "svg")) return .{ .tt = .svg, .data = data };
                if (std.mem.eql(u8, h, "math")) return .{ .tt = .math, .data = data };
                return .{ .tt = .xml, .data = data };
            }
            l.raw_tag = rn;
            break;
        };
        return .{ .tt = .start_tag, .data = l.shift() };
    }

    fn shiftAttribute(l: *Lexer) []u8 {
        const name_start = l.rel();
        var c: u8 = 0;
        while (true) {
            c = l.peek(0);
            if (c == ' ' or c == '=' or c == '>' or (c == '/' and l.peek(1) == '>') or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or (c == 0 and l.eof())) break;
            l.pos += 1;
        }
        const name_end = l.rel();
        while (true) {
            c = l.peek(0);
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
                l.pos += 1;
                continue;
            }
            break;
        }
        if (c == '=') {
            l.pos += 1;
            while (true) {
                c = l.peek(0);
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
                    l.pos += 1;
                    continue;
                }
                break;
            }
            const attr_pos = l.rel();
            const delim = c;
            if (delim == '"' or delim == '\'') {
                l.pos += 1;
                while (true) {
                    const d = l.peek(0);
                    if (d == delim) {
                        l.pos += 1;
                        break;
                    } else if (d == 0 and l.eof()) break;
                    l.pos += 1;
                }
            } else {
                while (true) {
                    const d = l.peek(0);
                    if (d == ' ' or d == '>' or d == '\t' or d == '\n' or d == '\r' or d == 0x0c or (d == 0 and l.eof())) break;
                    l.pos += 1;
                }
            }
            l.attr_val = l.lexeme()[attr_pos..];
        } else {
            l.pos = l.start + name_end;
            l.attr_val = null;
        }
        l.text = lower(l.lexeme()[name_start..name_end]);
        return l.shift();
    }

    fn shiftEndTag(l: *Lexer) []u8 {
        while (true) {
            const c = l.peek(0);
            if (c == '>') {
                l.text = l.lexeme()[2..];
                l.pos += 1;
                break;
            } else if (c == 0 and l.eof()) {
                l.text = l.lexeme()[2..];
                break;
            }
            l.pos += 1;
        }
        var t = l.text.?;
        var end = t.len;
        while (end > 0) {
            const c = t[end - 1];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                end -= 1;
                continue;
            }
            break;
        }
        t = t[0..end];
        l.text = t;
        return lower(l.shift());
    }

    fn shiftXML(l: *Lexer, raw: []const u8) []u8 {
        var nested: usize = 0;
        var in_quote = false;
        outer: while (true) {
            const c = l.peek(0);
            if (c == '"') {
                in_quote = !in_quote;
                l.pos += 1;
            } else if (c == '<' and !in_quote) {
                var s = l.pos;
                const is_end = l.peek(1) == '/';
                if (is_end) {
                    l.pos += 2;
                    s += 2;
                } else {
                    l.pos += 1;
                    s += 1;
                }
                while (isAlpha(l.peek(0))) l.pos += 1;
                if (!is_end and l.peek(0) == '/') {} else if (std.mem.eql(u8, l.nameAt(s), raw)) {
                    if (is_end) {
                        if (nested == 0) break :outer;
                        nested -= 1;
                    } else nested += 1;
                }
            } else if (c == 0) {
                if (!l.eof()) l.failed = true;
                return l.shift();
            } else l.pos += 1;
        }
        while (true) {
            const c = l.peek(0);
            if (c == '>') {
                l.pos += 1;
                break;
            } else if (c == 0) {
                if (!l.eof()) l.failed = true;
                return l.shift();
            }
            l.pos += 1;
        }
        return l.shift();
    }
};

// ================================================================ tables

const NORMAL: u16 = 1;
const RAW: u16 = 2;
const BLOCK: u16 = 4;
const OBJECT: u16 = 8;
const OMIT_P: u16 = 16;
const KEEP_P: u16 = 32;
const BOOLEAN: u16 = 1;
const URL: u16 = 2;
const TRIM: u16 = 4;

fn bsearch(comptime T: type, list: []const T, key: []const u8, comptime keyOf: fn (T) []const u8) ?T {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, keyOf(list[mid]), key)) {
            .eq => return list[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}
fn traitName(t: tables.Trait) []const u8 {
    return t.name;
}
fn strSelf(s: []const u8) []const u8 {
    return s;
}
fn entKey(e: [2][]const u8) []const u8 {
    return e[0];
}

fn hashOf(name: []const u8) []const u8 {
    return if (bsearch([]const u8, &tables.names, name, strSelf) != null) name else "";
}
fn tagTraits(h: []const u8) u16 {
    if (h.len == 0) return 0;
    return if (bsearch(tables.Trait, &tables.tags, h, traitName)) |t| t.t else 0;
}
fn attrTraits(h: []const u8) u16 {
    if (h.len == 0) return 0;
    return if (bsearch(tables.Trait, &tables.attrs, h, traitName)) |t| t.t else 0;
}
fn entity(name: []const u8) ?[]const u8 {
    return if (bsearch([2][]const u8, &tables.entities, name, entKey)) |e| e[1] else null;
}

// ================================================================ text helpers

fn isAlnum(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// parse.replaceEntities on an ArrayList: returns the new index.
fn replaceEntityAt(b: *std.ArrayList(u8), i: usize, rev_lt: bool) usize {
    const s = b.items;
    var r_buf: [16]u8 = undefined;
    var r: []const u8 = undefined;
    var j = i + 1;
    if (s[j] == '#') {
        j += 1;
        if (j < s.len and s[j] == 'x') {
            j += 1;
            var c: u32 = 0;
            while (j < s.len and ((s[j] >= '0' and s[j] <= '9') or (s[j] >= 'a' and s[j] <= 'f') or (s[j] >= 'A' and s[j] <= 'F'))) : (j += 1) {
                const d: u32 = if (s[j] <= '9') s[j] - '0' else if (s[j] <= 'F') s[j] - 'A' + 10 else s[j] - 'a' + 10;
                c = (c << 4) +% d;
                if (c > 1 << 28) c = 1 << 28;
            }
            if (j <= i + 3 or 10000 <= c) return j - 1;
            if (c < 128) {
                r_buf[0] = @intCast(c);
                r = r_buf[0..1];
            } else r = std.fmt.bufPrint(&r_buf, "&#{d};", .{c}) catch return i;
        } else {
            var c: u32 = 0;
            while (j < s.len and c < 128 and s[j] >= '0' and s[j] <= '9') : (j += 1) c = c * 10 + (s[j] - '0');
            if (j <= i + 2 or 128 <= c) return j - 1;
            r_buf[0] = @intCast(c);
            r = r_buf[0..1];
        }
    } else {
        while (j < s.len and j - i - 1 <= 31 and s[j] != ';') : (j += 1) {
            if (!isAlnum(s[j])) break;
        }
        if (s.len <= j or j == i + 1 or s[j] != ';') return i;
        r = entity(s[i + 1 .. j]) orelse return j;
    }
    const n = j + 1 - i;
    if (j < s.len and s[j] == ';' and 2 < n) {
        if (r.len == 1) {
            if (rev_lt and r[0] == '<') {
                if (std.mem.eql(u8, s[i .. j + 1], "&lt;")) return j;
                r = "&lt;";
            } else if (r[0] == '&') {
                const k = j + 1;
                if (k < s.len and (isAlnum(s[k]) or s[k] == '#')) return k;
            }
        }
        const rr = sys.A.dupe(u8, r) catch return i;
        b.replaceRange(sys.A, i, j + 1 - i, rr) catch return i;
        return i + rr.len - 1;
    }
    return i;
}

fn replaceEntities(src: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(sys.A, src) catch return src;
    var i: usize = 0;
    while (i < b.items.len) : (i += 1) {
        if (b.items[i] == '&' and i + 3 < b.items.len) i = replaceEntityAt(&b, i, false);
    }
    return b.items;
}

/// parse.ReplaceMultipleWhitespaceAndEntities (whitespace runs collapse to a
/// single space or newline; entities are decoded where shorter).
fn replaceWsAndEntities(src: []const u8, rev_lt: bool) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(sys.A, src) catch return src;
    var j: usize = 0;
    var k: usize = 0;
    var i: usize = 0;
    while (i < b.items.len) : (i += 1) {
        if (min.isWhitespace(b.items[i])) {
            const start = i;
            var nl = min.isNewline(b.items[i]);
            i += 1;
            while (i < b.items.len and min.isWhitespace(b.items[i])) : (i += 1) {
                if (min.isNewline(b.items[i])) nl = true;
            }
            b.items[start] = if (nl) '\n' else ' ';
            if (1 < i - start) {
                if (j == 0) {
                    j = start + 1;
                } else {
                    std.mem.copyForwards(u8, b.items[j..], b.items[k .. start + 1]);
                    j += start + 1 - k;
                }
                k = i;
            }
        }
        if (i + 3 < b.items.len and b.items[i] == '&') i = replaceEntityAt(&b, i, rev_lt);
    }
    if (j == 0) return b.items;
    if (j == 1) {
        b.items[k - 1] = b.items[0];
        return b.items[k - 1 ..];
    }
    if (k < b.items.len) {
        std.mem.copyForwards(u8, b.items[j..], b.items[k..]);
        j += b.items.len - k;
    }
    return b.items[0..j];
}

fn isAllWhitespace(s: []const u8) bool {
    for (s) |c| if (!min.isWhitespace(c)) return false;
    return true;
}

const char_table = blk: {
    var t = @as([256]bool, @splat(false));
    for ([_]u8{ '\t', '\n', 0x0c, '\r', ' ', '"', '\'', '<', '=', '>', '`' }) |c| t[c] = true;
    break :blk t;
};

fn escapeAttrVal(b: []const u8, orig_quote: u8, must_quote: bool) []const u8 {
    var singles: usize = 0;
    var doubles: usize = 0;
    var unquoted = true;
    for (b) |c| if (char_table[c]) {
        unquoted = false;
        if (c == '"') doubles += 1 else if (c == '\'') singles += 1;
    };
    if (unquoted and (!must_quote or orig_quote == 0)) return b;
    if ((singles == 0 and orig_quote == '\'') or (doubles == 0 and orig_quote == '"')) {
        return std.mem.concat(sys.A, u8, &.{ &.{orig_quote}, b, &.{orig_quote} }) catch b;
    }
    var quote: u8 = undefined;
    var esc: []const u8 = undefined;
    if (singles > doubles or (singles == doubles and orig_quote != '\'')) {
        quote = '"';
        esc = "&#34;";
    } else {
        quote = '\'';
        esc = "&#39;";
    }
    var out: std.ArrayList(u8) = .empty;
    out.append(sys.A, quote) catch {};
    for (b) |c| {
        if (c == quote) out.appendSlice(sys.A, esc) catch {} else out.append(sys.A, c) catch {};
    }
    out.append(sys.A, quote) catch {};
    return out.items;
}

/// parse.Mediatype: the mime type without parameters.
fn mediatypeOnly(b0: []const u8) []const u8 {
    var b = b0;
    var i: usize = 0;
    while (i < b.len and b[i] == ' ') i += 1;
    b = b[i..];
    var k: usize = 3;
    while (k < b.len) : (k += 1) if (b[k] == ';' or b[k] == ' ') return b[0..k];
    return b;
}

// ================================================================ token buffer

const Token = struct {
    tt: TT,
    hash: []const u8 = "",
    data: []u8,
    text: ?[]u8,
    attr_val: ?[]u8 = null,
    traits: u16 = 0,
};

const TokenBuffer = struct {
    l: *Lexer,
    buf: std.ArrayList(Token) = .empty,
    pos: usize = 0,

    fn read(z: *TokenBuffer) Token {
        const r = z.l.next();
        var t = Token{ .tt = r.tt, .data = r.data, .text = z.l.text };
        if (t.tt == .attribute) {
            var aval = z.l.attr_val;
            if (aval) |a| if (1 < a.len and (a[0] == '"' or a[0] == '\'')) {
                aval = a[1 .. a.len - 1];
            };
            t.attr_val = aval;
            t.hash = hashOf(t.text orelse "");
            t.traits = attrTraits(t.hash);
        } else if (t.tt == .start_tag or t.tt == .end_tag) {
            t.hash = hashOf(t.text orelse "");
            t.traits = tagTraits(t.hash);
        }
        return t;
    }
    fn peek(z: *TokenBuffer, n: usize) *Token {
        while (z.pos + n >= z.buf.items.len) {
            if (z.buf.items.len > 0 and z.buf.items[z.buf.items.len - 1].tt == .err) return &z.buf.items[z.buf.items.len - 1];
            z.buf.append(sys.A, z.read()) catch {};
        }
        return &z.buf.items[z.pos + n];
    }
    fn shift(z: *TokenBuffer) *Token {
        if (z.pos >= z.buf.items.len) {
            z.buf.append(sys.A, z.read()) catch {};
        }
        const t = &z.buf.items[z.pos];
        z.pos += 1;
        return t;
    }
    fn attributes(z: *TokenBuffer, hashes: []const []const u8, out: []?*Token) void {
        var n: usize = 0;
        while (z.peek(n).tt == .attribute) n += 1;
        for (out) |*o| o.* = null;
        var i = z.pos;
        while (i < z.pos + n) : (i += 1) {
            const a = &z.buf.items[i];
            for (hashes, 0..) |h, j| if (std.mem.eql(u8, h, a.hash)) {
                out[j] = a;
            };
        }
    }
};

// ================================================================ minifier

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn av(t: anytype) []const u8 {
    return if (t.attr_val) |x| x else "";
}

pub fn minify(src: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try minifyInto(&out, src);
    return out.items;
}

fn minifyInto(out: *std.ArrayList(u8), src: []const u8) anyerror!void {
    const buf = try sys.A.dupe(u8, src);
    var lx = Lexer{ .b = buf };
    var tb = TokenBuffer{ .l = &lx };
    var raw_tag: []const u8 = "";
    var raw_media: ?[]const u8 = null;
    var omit_space = true;
    var in_pre = false;
    var in_template = false;
    const W = struct {
        o: *std.ArrayList(u8),
        fn w(self: @This(), s: []const u8) void {
            self.o.appendSlice(sys.A, s) catch {};
        }
    };
    const wr = W{ .o = out };
    while (true) {
        var t = tb.shift().*;
        switch (t.tt) {
            .err => {
                if (lx.failed) return error.HtmlSyntax;
                return;
            },
            .doctype => wr.w("<!doctype html>"),
            .comment => {
                const text = t.text orelse "";
                if (6 < text.len and (std.mem.startsWith(u8, text, "[if ") or std.mem.endsWith(u8, text, "[endif]") or std.mem.endsWith(u8, text, "[endif]--"))) {
                    if (std.mem.startsWith(u8, t.data, "<!--[if ") and std.mem.endsWith(u8, t.data, "<![endif]-->")) {
                        const begin = (std.mem.indexOfScalar(u8, t.data, '>') orelse 0) + 1;
                        const end = t.data.len - "<![endif]-->".len;
                        if (begin < end) {
                            wr.w(t.data[0..begin]);
                            try minifyInto(out, t.data[begin..end]);
                            wr.w(t.data[end..]);
                        } else wr.w(t.data);
                    } else wr.w(t.data);
                } else if (1 < text.len and text[0] == '#') wr.w(t.data);
            },
            .svg => {
                if (@import("min_svg.zig").minifySvg(t.data, true)) |m| wr.w(m) else |_| wr.w(t.data);
                omit_space = false;
            },
            .math => {
                wr.w(t.data);
                omit_space = false;
            },
            .xml => {
                if (min.minifyByMime("text/xml", t.data)) |m| wr.w(m) else wr.w(t.data);
                omit_space = false;
            },
            .template => {
                wr.w(t.data);
                omit_space = false;
            },
            .text => {
                if (raw_tag.len > 0) {
                    if (eq(raw_tag, "style") or eq(raw_tag, "script") or eq(raw_tag, "iframe")) {
                        var mt: []const u8 = "";
                        var esc = false;
                        if (eq(raw_tag, "iframe")) {
                            mt = "text/html";
                        } else if (raw_media) |rm| {
                            mt = mediatypeOnly(rm);
                        } else if (eq(raw_tag, "script")) {
                            mt = "application/javascript";
                            esc = true;
                        } else mt = "text/css";
                        if (min.isJsMime(mt)) {
                            if (min.minifyJs(t.data, esc)) |m| wr.w(m) else |_| wr.w(t.data);
                        } else if (min.minifyByMime(mt, t.data)) |m| wr.w(m) else wr.w(t.data);
                    } else wr.w(t.data);
                } else if (in_pre) {
                    wr.w(t.data);
                } else {
                    var d = replaceWsAndEntities(t.data, true);
                    if (omit_space and d.len > 0 and min.isWhitespace(d[0])) d = d[1..];
                    omit_space = false;
                    if (d.len == 0) {
                        omit_space = true;
                    } else if (min.isWhitespace(d[d.len - 1])) {
                        omit_space = true;
                        var i: usize = 0;
                        while (true) : (i += 1) {
                            const nx = tb.peek(i);
                            if (100 < i) {
                                omit_space = false;
                                break;
                            } else if (nx.tt == .err) {
                                d = d[0 .. d.len - 1];
                                omit_space = false;
                                break;
                            } else if ((nx.tt == .text and !isAllWhitespace(nx.data)) or nx.tt == .template) {
                                break;
                            } else if (nx.tt == .start_tag or nx.tt == .end_tag or nx.tt == .svg or nx.tt == .math or nx.tt == .xml) {
                                if (nx.traits & BLOCK != 0) {
                                    d = d[0 .. d.len - 1];
                                    omit_space = false;
                                    break;
                                } else if (nx.tt == .start_tag or nx.tt == .svg or nx.tt == .math or nx.tt == .xml) break;
                            }
                        }
                    }
                    wr.w(d);
                }
            },
            .start_tag, .end_tag => {
                raw_tag = "";
                var has_attrs = false;
                if (t.tt == .start_tag) {
                    if (tb.peek(0).tt == .attribute) has_attrs = true;
                    if (t.traits & RAW != 0) {
                        if (!has_attrs and (eq(t.hash, "script") or eq(t.hash, "style"))) {
                            if (tb.peek(1).tt == .end_tag) {
                                _ = tb.shift();
                                _ = tb.shift();
                                continue;
                            }
                        }
                        raw_tag = t.hash;
                        raw_media = null;
                        if (has_attrs and eq(t.hash, "style")) {
                            var a: [1]?*Token = undefined;
                            tb.attributes(&.{"amp-boilerplate"}, &a);
                            if (a[0] != null) raw_tag = "";
                        }
                    }
                } else if (eq(t.hash, "template")) omit_space = true;
                if (eq(t.hash, "pre")) {
                    in_pre = t.tt == .start_tag;
                } else if (eq(t.hash, "template")) in_template = t.tt == .start_tag;
                if (!has_attrs and eq(t.hash, "colgroup")) continue;
                if (t.tt == .end_tag) {
                    if (t.traits & OBJECT != 0) {
                        omit_space = false;
                    } else if (t.traits & BLOCK != 0) omit_space = true;
                    const tl = if (t.text) |tx| tx.len else 0;
                    if (3 + tl < t.data.len) {
                        t.data[2 + tl] = '>';
                        t.data = t.data[0 .. 3 + tl];
                    }
                    wr.w(t.data);
                    if (eq(t.hash, "option") or eq(t.hash, "optgroup")) {
                        if (tb.peek(0).tt == .text) _ = tb.shift();
                    }
                    continue;
                }
                if (t.traits & OBJECT != 0) {
                    omit_space = false;
                } else if (t.traits & BLOCK != 0) omit_space = true;
                wr.w(t.data);
                if (has_attrs) {
                    if (eq(t.hash, "meta")) {
                        var a: [4]?*Token = undefined;
                        tb.attributes(&.{ "content", "http-equiv", "charset", "name" }, &a);
                        if (a[0]) |content| {
                            if (a[1]) |he| {
                                he.attr_val = @constCast(min.trimWhitespace(if (he.attr_val) |x| x else ""));
                                if (a[2] == null and min.eqlFold(he.attr_val.?, "content-type")) {
                                    content.attr_val = @constCast(mediatype(if (content.attr_val) |x| x else ""));
                                    if (eq(content.attr_val.?, "text/html;charset=utf-8")) {
                                        he.text = null;
                                        content.text = @constCast("charset");
                                        content.hash = "charset";
                                        content.attr_val = @constCast("utf-8");
                                    }
                                }
                            }
                            if (a[3]) |name| {
                                name.attr_val = @constCast(min.trimWhitespace(if (name.attr_val) |x| x else ""));
                                if (min.eqlFold(name.attr_val.?, "keywords")) {
                                    content.attr_val = std.mem.replaceOwned(u8, sys.A, if (content.attr_val) |x| x else "", ", ", ",") catch content.attr_val;
                                } else if (min.eqlFold(name.attr_val.?, "viewport")) {
                                    content.attr_val = viewport(if (content.attr_val) |x| x else "");
                                }
                            }
                        }
                    } else if (eq(t.hash, "script")) {
                        var a: [2]?*Token = undefined;
                        tb.attributes(&.{ "src", "charset" }, &a);
                        if (a[0] != null and a[1] != null) a[1].?.text = null;
                    } else if (eq(t.hash, "input")) {
                        var a: [2]?*Token = undefined;
                        tb.attributes(&.{ "type", "value" }, &a);
                        if (a[0]) |ty| if (a[1]) |val| {
                            const radio = min.eqlFold(av(ty), "radio");
                            if (!radio and (av(val)).len == 0) {
                                val.text = null;
                            } else if (radio and min.eqlFold(if (val.attr_val) |x| x else "", "on")) val.text = null;
                        };
                    } else if (eq(t.hash, "a")) {
                        var a: [2]?*Token = undefined;
                        tb.attributes(&.{ "id", "name" }, &a);
                        if (a[0]) |id| if (a[1]) |name| {
                            if (eq(if (id.attr_val) |x| x else "", if (name.attr_val) |x| x else "")) name.text = null;
                        };
                    }
                    while (true) {
                        const attr = tb.shift().*;
                        if (attr.tt != .attribute) break;
                        const atext = attr.text orelse continue;
                        var val: []const u8 = if (attr.attr_val) |x| x else "";
                        if (attr.traits & TRIM != 0) {
                            val = min.trimWhitespace(replaceWsAndEntities(val, false));
                        } else val = replaceEntities(val);
                        if (t.traits != 0) {
                            if (val.len == 0 and (eq(attr.hash, "class") or eq(attr.hash, "dir") or eq(attr.hash, "id") or eq(attr.hash, "name") or (eq(attr.hash, "action") and eq(t.hash, "form")))) continue;
                            if (raw_tag.len > 0 and eq(attr.hash, "type")) raw_media = try sys.A.dupe(u8, val);
                            if (eq(attr.hash, "enctype") or eq(attr.hash, "formenctype") or eq(attr.hash, "accept") or (eq(attr.hash, "type") and (eq(t.hash, "a") or eq(t.hash, "link") or eq(t.hash, "embed") or eq(t.hash, "object") or eq(t.hash, "source") or eq(t.hash, "script")))) {
                                val = mediatype(val);
                            }
                            if (eq(attr.hash, "style")) {
                                val = min.trimWhitespace(val);
                                if (@import("min_css.zig").minify(val, true)) |m| {
                                    val = m;
                                } else |_| {}
                                if (val.len == 0) continue;
                            } else if (2 < atext.len and atext[0] == 'o' and atext[1] == 'n') {
                                val = min.trimWhitespace(val);
                                if (11 <= val.len and min.eqlFold(val[0..11], "javascript:")) val = val[11..];
                                if (min.minifyInlineJs(val)) |m| val = m;
                                if (val.len == 0) continue;
                            } else if (attr.traits & URL != 0) {
                                val = min.trimWhitespace(val);
                                if (5 < val.len) {
                                    if (min.eqlFold(val[0..4], "http")) {
                                        if (val[4] == ':') {
                                            val = std.mem.concat(sys.A, u8, &.{ "http", val[4..] }) catch val;
                                        } else if ((val[4] == 's' or val[4] == 'S') and val[5] == ':') {
                                            val = std.mem.concat(sys.A, u8, &.{ "https", val[5..] }) catch val;
                                        }
                                    } else if (min.eqlFold(val[0..5], "data:")) val = min.dataUri(val);
                                }
                            }
                        }
                        wr.w(" ");
                        wr.w(atext);
                        if (0 < val.len and attr.traits & BOOLEAN == 0) {
                            wr.w("=");
                            const h = attr.hash;
                            const is_xml = eq(h, "vocab") or eq(h, "typeof") or eq(h, "property") or eq(h, "resource") or eq(h, "prefix") or eq(h, "content") or eq(h, "about") or eq(h, "rev") or eq(h, "datatype") or eq(h, "inlist");
                            var quote: u8 = 0;
                            if (attr.data.len > 0 and (attr.data[attr.data.len - 1] == '\'' or attr.data[attr.data.len - 1] == '"')) quote = attr.data[attr.data.len - 1];
                            wr.w(escapeAttrVal(val, quote, is_xml));
                        }
                    }
                } else {
                    _ = tb.shift(); // StartTagClose
                }
                wr.w(">");
                if (eq(t.hash, "select") or eq(t.hash, "optgroup")) {
                    if (tb.peek(0).tt == .text) _ = tb.shift();
                }
                if (t.tt == .start_tag and t.traits == NORMAL) {
                    const nx = tb.peek(0);
                    if (eq(nx.hash, t.hash) and nx.tt == .end_tag) omit_space = false;
                }
            },
            else => {},
        }
    }
}

/// minify.Mediatype: drops whitespace and lower-cases outside quoted strings.
fn mediatype(b0: []const u8) []const u8 {
    const b = sys.A.dupe(u8, b0) catch return b0;
    var j: usize = 0;
    var in_string = false;
    var start: usize = 0;
    var last_string: usize = 0;
    for (b0, 0..) |c, i| {
        if (!in_string and min.isWhitespace(c)) {
            if (start != 0) {
                std.mem.copyForwards(u8, b[j..], b[start..i]);
                j += i - start;
            } else j += i;
            start = i + 1;
        } else if (c == '"') {
            in_string = !in_string;
            if (in_string) {
                if (i - last_string < 1024) for (b[last_string..i]) |*x| {
                    x.* = std.ascii.toLower(x.*);
                };
            } else last_string = j + (i + 1 - start);
        }
    }
    if (start != 0) {
        std.mem.copyForwards(u8, b[j..], b[start..]);
        j += b.len - start;
        for (b[last_string..j]) |*x| x.* = std.ascii.toLower(x.*);
        return b[0..j];
    }
    for (b[last_string..]) |*x| x.* = std.ascii.toLower(x.*);
    return b;
}

fn viewport(v0: []const u8) []u8 {
    var v = std.mem.replaceOwned(u8, sys.A, v0, " ", "") catch return @constCast(v0);
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] == '=' and i + 2 < v.len) {
            i += 1;
            var n: usize = 0;
            // parse.Number: length of the number at the start
            {
                var k: usize = 0;
                if (k < v.len - i and (v[i + k] == '+' or v[i + k] == '-')) k += 1;
                const ds = k;
                while (i + k < v.len and v[i + k] >= '0' and v[i + k] <= '9') k += 1;
                var digits = k > ds;
                if (i + k < v.len and v[i + k] == '.') {
                    const dot = k;
                    k += 1;
                    const fs = k;
                    while (i + k < v.len and v[i + k] >= '0' and v[i + k] <= '9') k += 1;
                    if (k == fs) k = dot else digits = true;
                }
                n = if (digits) k else 0;
            }
            if (0 < n) {
                const mn = min.number(v[i .. i + n], -1);
                if (mn.len < n) {
                    const nv = std.mem.concat(sys.A, u8, &.{ v[0..i], mn, v[i + n ..] }) catch v;
                    v = nv;
                }
                i += mn.len;
            }
            i -= 1;
        }
    }
    return v;
}
