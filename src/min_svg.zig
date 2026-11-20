// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/minify and tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! XML and SVG minifiers: ports of tdewolff/parse/xml and tdewolff/minify
//! xml + svg (MIT), with Hugo's default options.
const std = @import("std");
const sys = @import("sys.zig");
const min = @import("min.zig");

// ================================================================ lexer

pub const TT = enum { err, comment, doctype, cdata, start_tag, start_tag_pi, start_tag_close, start_tag_close_void, start_tag_close_pi, end_tag, attribute, text };

const Lexer = struct {
    s: []u8,
    pos: usize = 0,
    start: usize = 0,
    in_tag: bool = false,
    failed: bool = false,
    text: ?[]u8 = null,
    attr_val: ?[]u8 = null,

    fn peek(l: *const Lexer, n: usize) u8 {
        return if (l.start + l.pos + n < l.s.len) l.s[l.start + l.pos + n] else 0;
    }
    fn eof(l: *const Lexer) bool {
        return l.start + l.pos >= l.s.len;
    }
    fn lexeme(l: *Lexer) []u8 {
        return l.s[l.start .. l.start + l.pos];
    }
    fn shift(l: *Lexer) []u8 {
        const b = l.lexeme();
        l.start += l.pos;
        l.pos = 0;
        return b;
    }
    fn at(l: *const Lexer, b: []const u8) bool {
        for (b, 0..) |c, i| if (l.peek(i) != c) return false;
        return true;
    }

    fn next(l: *Lexer) struct { tt: TT, data: []u8 } {
        l.text = null;
        var c: u8 = 0;
        if (l.in_tag) {
            l.attr_val = null;
            while (true) {
                c = l.peek(0);
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                    l.pos += 1;
                    continue;
                }
                break;
            }
            if (c == 0) {
                if (!l.eof()) l.failed = true;
                return .{ .tt = .err, .data = &.{} };
            } else if (c != '>' and ((c != '/' and c != '?') or l.peek(1) != '>')) {
                return .{ .tt = .attribute, .data = l.shiftAttribute() };
            }
            // skip whitespace
            l.start += l.pos;
            l.pos = 0;
            l.in_tag = false;
            if (c == '/') {
                l.pos += 2;
                return .{ .tt = .start_tag_close_void, .data = l.shift() };
            } else if (c == '?') {
                l.pos += 2;
                return .{ .tt = .start_tag_close_pi, .data = l.shift() };
            }
            l.pos += 1;
            return .{ .tt = .start_tag_close, .data = l.shift() };
        }
        while (true) {
            c = l.peek(0);
            if (c == '<') {
                if (l.pos > 0) {
                    l.text = l.shift();
                    return .{ .tt = .text, .data = l.text.? };
                }
                c = l.peek(1);
                if (c == '/') {
                    l.pos += 2;
                    return .{ .tt = .end_tag, .data = l.shiftEndTag() };
                } else if (c == '!') {
                    l.pos += 2;
                    if (l.at("--")) {
                        l.pos += 2;
                        return .{ .tt = .comment, .data = l.shiftCommentText() };
                    } else if (l.at("[CDATA[")) {
                        l.pos += 7;
                        return .{ .tt = .cdata, .data = l.shiftCDATAText() };
                    } else if (l.at("DOCTYPE")) {
                        l.pos += 7;
                        return .{ .tt = .doctype, .data = l.shiftDOCTYPEText() };
                    }
                    l.pos -= 2;
                } else if (c == '?') {
                    l.pos += 2;
                    l.in_tag = true;
                    return .{ .tt = .start_tag_pi, .data = l.shiftStartTag() };
                }
                l.pos += 1;
                l.in_tag = true;
                return .{ .tt = .start_tag, .data = l.shiftStartTag() };
            } else if (c == 0 and l.eof()) {
                if (l.pos > 0) {
                    l.text = l.shift();
                    return .{ .tt = .text, .data = l.text.? };
                }
                return .{ .tt = .err, .data = &.{} };
            } else if (c == 0) {
                if (l.pos > 0) {
                    l.text = l.shift();
                    return .{ .tt = .text, .data = l.text.? };
                }
                l.failed = true;
                return .{ .tt = .err, .data = &.{} };
            }
            l.pos += 1;
        }
    }
    fn shiftDOCTYPEText(l: *Lexer) []u8 {
        var in_string = false;
        var in_brackets = false;
        while (true) {
            const c = l.peek(0);
            if (c == '"') {
                in_string = !in_string;
            } else if ((c == '[' or c == ']') and !in_string) {
                in_brackets = c == '[';
            } else if (c == '>' and !in_string and !in_brackets) {
                l.text = l.lexeme()[9..];
                l.pos += 1;
                return l.shift();
            } else if (c == 0 and l.eof()) {
                l.text = l.lexeme()[9..];
                return l.shift();
            }
            l.pos += 1;
        }
    }
    fn shiftCDATAText(l: *Lexer) []u8 {
        while (true) {
            const c = l.peek(0);
            if (c == ']' and l.peek(1) == ']' and l.peek(2) == '>') {
                l.text = l.lexeme()[9..];
                l.pos += 3;
                return l.shift();
            } else if (c == 0 and l.eof()) {
                l.text = l.lexeme()[9..];
                return l.shift();
            }
            l.pos += 1;
        }
    }
    fn shiftCommentText(l: *Lexer) []u8 {
        while (true) {
            const c = l.peek(0);
            if (c == '-' and l.peek(1) == '-' and l.peek(2) == '>') {
                l.text = l.lexeme()[4..];
                l.pos += 3;
                return l.shift();
            } else if (c == 0 and l.eof()) return l.shift();
            l.pos += 1;
        }
    }
    fn nameEnd(l: *const Lexer, c: u8, with_eq: bool) bool {
        return c == ' ' or (with_eq and c == '=') or c == '>' or ((c == '/' or c == '?') and l.peek(1) == '>') or c == '\t' or c == '\n' or c == '\r' or c == 0;
    }
    fn shiftStartTag(l: *Lexer) []u8 {
        const name_start = l.pos;
        while (!l.nameEnd(l.peek(0), false)) l.pos += 1;
        l.text = l.lexeme()[name_start..];
        return l.shift();
    }
    fn shiftAttribute(l: *Lexer) []u8 {
        const name_start = l.pos;
        var c: u8 = 0;
        while (true) {
            c = l.peek(0);
            if (l.nameEnd(c, true)) break;
            l.pos += 1;
        }
        const name_end = l.pos;
        while (true) {
            c = l.peek(0);
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                l.pos += 1;
                continue;
            }
            break;
        }
        if (c == '=') {
            l.pos += 1;
            while (true) {
                c = l.peek(0);
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                    l.pos += 1;
                    continue;
                }
                break;
            }
            const attr_pos = l.pos;
            const delim = c;
            if (delim == '"' or delim == '\'') {
                l.pos += 1;
                while (true) {
                    c = l.peek(0);
                    if (c == delim) {
                        l.pos += 1;
                        break;
                    } else if (c == 0 and l.eof()) break;
                    l.pos += 1;
                    if (c == '\t' or c == '\n' or c == '\r') l.lexeme()[l.pos - 1] = ' ';
                }
            } else {
                while (!l.nameEnd(l.peek(0), false)) l.pos += 1;
            }
            l.attr_val = l.lexeme()[attr_pos..];
        } else {
            l.pos = name_end;
            l.attr_val = null;
        }
        l.text = l.lexeme()[name_start..name_end];
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
        return l.shift();
    }
};

// ================================================================ helpers

fn escapeAttrVal(b: []const u8) []u8 {
    var singles: usize = 0;
    var doubles: usize = 0;
    for (b) |c| {
        if (c == '"') doubles += 1 else if (c == '\'') singles += 1;
    }
    var quote: u8 = '"';
    var esc: []const u8 = "&#34;";
    if (doubles > singles) {
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

fn escapeCDATAVal(b: []u8) struct { b: []u8, use: bool } {
    var n: usize = 0;
    for (b) |c| {
        if (c == '<' or c == '&') {
            n += if (c == '<') 3 else 4;
            if (n > "<![CDATA[]]>".len) return .{ .b = b, .use = false };
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (b) |c| {
        if (c == '<') {
            out.appendSlice(sys.A, "&lt;") catch {};
        } else if (c == '&') {
            out.appendSlice(sys.A, "&amp;") catch {};
        } else out.append(sys.A, c) catch {};
    }
    return .{ .b = out.items, .use = true };
}

const RevMap = enum { attr, text };
fn revEntity(m: RevMap, c: u8) ?[]const u8 {
    return switch (c) {
        '\t' => "&#9;",
        '\n' => "&#10;",
        '\r' => "&#13;",
        '<' => if (m == .text) "&lt;" else null,
        '>' => if (m == .text) "&gt;" else null,
        '&' => if (m == .text) "&amp;" else null,
        else => null,
    };
}

/// parse's replaceEntities with minify/xml's EntitiesMap (apos, quot).
fn replaceEntities(b0: []u8, i: usize, m: RevMap) struct { b: []u8, i: usize } {
    var b = b0;
    var buf: [32]u8 = undefined;
    var r: []const u8 = &.{};
    var j = i + 1;
    if (b[j] == '#') {
        j += 1;
        if (b[j] == 'x') {
            j += 1;
            var c: i64 = 0;
            while (j < b.len and std.ascii.isHex(b[j])) : (j += 1) {
                c = c * 16 + (std.fmt.charToDigit(b[j], 16) catch 0);
                if (c > 1 << 40) c = 1 << 40;
            }
            if (j <= i + 3 or 10000 <= c) return .{ .b = b, .i = j - 1 };
            if (c < 128) {
                buf[0] = @intCast(c);
                r = buf[0..1];
            } else {
                r = std.fmt.bufPrint(&buf, "&#{d};", .{c}) catch return .{ .b = b, .i = j - 1 };
            }
        } else {
            var c: i64 = 0;
            while (j < b.len and c < 128 and b[j] >= '0' and b[j] <= '9') : (j += 1) c = c * 10 + (b[j] - '0');
            if (j <= i + 2 or 128 <= c) return .{ .b = b, .i = j - 1 };
            buf[0] = @intCast(c);
            r = buf[0..1];
        }
    } else {
        while (j < b.len and j - i - 1 <= 31 and b[j] != ';') : (j += 1) {
            if (!std.ascii.isAlphanumeric(b[j])) break;
        }
        if (b.len <= j or j == i + 1 or b[j] != ';') return .{ .b = b, .i = i };
        const name = b[i + 1 .. j];
        if (std.mem.eql(u8, name, "apos")) {
            r = "'";
        } else if (std.mem.eql(u8, name, "quot")) {
            r = "\"";
        } else return .{ .b = b, .i = j };
    }
    const n = j + 1 - i;
    if (j < b.len and b[j] == ';' and 2 < n) {
        if (r.len == 1) {
            if (revEntity(m, r[0])) |q| {
                if (std.mem.eql(u8, q, b[i .. j + 1])) return .{ .b = b, .i = j };
                r = q;
            } else if (r[0] == '&') {
                const k = j + 1;
                if (k < b.len and (std.ascii.isAlphanumeric(b[k]) or b[k] == '#')) return .{ .b = b, .i = k };
            }
        }
        if (r.len > n) return .{ .b = b, .i = j };
        @memcpy(b[i .. i + r.len], r);
        std.mem.copyForwards(u8, b[i + r.len ..], b[j + 1 ..]);
        b = b[0 .. b.len - n + r.len];
        return .{ .b = b, .i = i + r.len - 1 };
    }
    return .{ .b = b, .i = i };
}

fn replaceEntitiesAll(b0: []u8, m: RevMap) []u8 {
    var b = b0;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (b[i] == '&' and i + 3 < b.len) {
            const r = replaceEntities(b, i, m);
            b = r.b;
            i = r.i;
        }
    }
    return b;
}

fn replaceMultipleWhitespaceAndEntities(b0: []u8, m: RevMap) []u8 {
    var b = b0;
    var j: usize = 0;
    var k: usize = 0;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (min.isWhitespace(b[i])) {
            const start = i;
            var newline = min.isNewline(b[i]);
            i += 1;
            while (i < b.len and min.isWhitespace(b[i])) : (i += 1) {
                if (min.isNewline(b[i])) newline = true;
            }
            b[start] = if (newline) '\n' else ' ';
            if (1 < i - start) {
                if (j == 0) {
                    j = start + 1;
                } else {
                    const len = start + 1 - k;
                    std.mem.copyForwards(u8, b[j .. j + len], b[k .. start + 1]);
                    j += len;
                }
                k = i;
            }
        }
        if (i + 3 < b.len and b[i] == '&') {
            const r = replaceEntities(b, i, m);
            b = r.b;
            i = r.i;
        }
    }
    if (j == 0) return b;
    if (j == 1) {
        b[k - 1] = b[0];
        return b[k - 1 ..];
    }
    if (k < b.len) {
        const len = b.len - k;
        std.mem.copyForwards(u8, b[j .. j + len], b[k..]);
        j += len;
    }
    return b[0..j];
}

fn trimWs(b: []u8) []u8 {
    const t = min.trimWhitespace(b);
    if (t.len == 0) return b[0..0];
    const off = @intFromPtr(t.ptr) - @intFromPtr(b.ptr);
    return b[off .. off + t.len];
}

fn isAllWs(b: []const u8) bool {
    for (b) |c| if (!min.isWhitespace(c)) return false;
    return true;
}

// ================================================================ token buffer

const Token = struct {
    tt: TT,
    hash: []const u8 = "",
    data: []u8,
    text: ?[]u8,
    attr_val: ?[]u8 = null,
};

const svg_names = [_][]const u8{ "a", "alignment-baseline", "baseProfile", "baseline-shift", "buffered-rendering", "clip", "clip-path", "clip-rule", "color", "color-interpolation", "color-interpolation-filters", "color-profile", "color-rendering", "contentScriptType", "contentStyleType", "cursor", "d", "defs", "direction", "display", "dominant-baseline", "enable-background", "feImage", "fill", "fill-opacity", "fill-rule", "filter", "flood-color", "flood-opacity", "font", "font-family", "font-size", "font-size-adjust", "font-stretch", "font-style", "font-variant", "font-weight", "foreignObject", "g", "glyph-orientation-horizontal", "glyph-orientation-vertical", "height", "href", "image", "image-rendering", "kerning", "letter-spacing", "lighting-color", "line", "marker", "marker-end", "marker-mid", "marker-start", "mask", "metadata", "missing-glyph", "opacity", "overflow", "paint-order", "path", "pattern", "pointer-events", "points", "polygon", "polyline", "preserveAspectRatio", "rect", "rx", "ry", "script", "shape-rendering", "solid-color", "solid-opacity", "stop-color", "stop-opacity", "stroke", "stroke-dasharray", "stroke-dashoffset", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width", "style", "svg", "switch", "symbol", "text-anchor", "text-decoration", "text-rendering", "type", "unicode-bidi", "use", "vector-effect", "version", "viewBox", "viewport-fill", "viewport-fill-opacity", "visibility", "white-space", "width", "word-spacing", "writing-mode", "x", "x1", "x2", "xlink", "xml:space", "xmlns", "y", "y1", "y2" };

fn toHash(s: []const u8) []const u8 {
    for (svg_names) |n| if (std.mem.eql(u8, n, s)) return n;
    return "";
}

const TokenBuffer = struct {
    l: *Lexer,
    svg: bool,
    buf: std.ArrayList(Token) = .empty,
    pos: usize = 0,

    fn read(z: *TokenBuffer) Token {
        const r = z.l.next();
        var t = Token{ .tt = r.tt, .data = r.data, .text = z.l.text };
        if (r.tt == .attribute) {
            t.attr_val = z.l.attr_val;
            if (z.svg) {
                if (t.attr_val) |av| {
                    if (av.len > 1 and (av[0] == '"' or av[0] == '\'')) {
                        var v = av[1 .. av.len - 1];
                        v = replaceMultipleWhitespaceAndEntities(v, .attr);
                        t.attr_val = trimWs(v);
                    }
                }
                t.hash = toHash(t.text orelse "");
            }
        } else if (z.svg and (r.tt == .start_tag or r.tt == .end_tag)) {
            t.hash = toHash(t.text orelse "");
        }
        return t;
    }
    fn peek(z: *TokenBuffer, n: usize) *Token {
        const want = z.pos + n;
        while (want >= z.buf.items.len) {
            if (z.buf.items.len > 0 and z.buf.items[z.buf.items.len - 1].tt == .err) return &z.buf.items[z.buf.items.len - 1];
            z.buf.append(sys.A, z.read()) catch {};
        }
        return &z.buf.items[want];
    }
    fn shift(z: *TokenBuffer) Token {
        if (z.pos >= z.buf.items.len) return z.read();
        const t = z.buf.items[z.pos];
        z.pos += 1;
        if (z.pos == z.buf.items.len) {
            z.buf.items.len = 0;
            z.pos = 0;
        }
        return t;
    }
};

const Out = struct {
    o: std.ArrayList(u8) = .empty,
    fn w(s: *Out, b: []const u8) void {
        s.o.appendSlice(sys.A, b) catch {};
    }
};

// ================================================================ XML minifier

pub fn minifyXml(src: []const u8) ![]const u8 {
    const buf = try sys.A.dupe(u8, src);
    var l = Lexer{ .s = buf };
    var tb = TokenBuffer{ .l = &l, .svg = false };
    var out = Out{};
    var omit_space = true;
    while (true) {
        var t = tb.shift();
        if (t.tt == .cdata) {
            const tx = t.text orelse continue;
            if (tx.len == 0) continue;
            const e = escapeCDATAVal(tx);
            if (e.use) t.data = e.b;
        }
        switch (t.tt) {
            .err => {
                if (l.failed) return error.XMLError;
                return out.o.items;
            },
            .doctype => out.w(t.data),
            .cdata => {
                out.w(t.data);
                const tx = t.text orelse &.{};
                if (tx.len > 0 and min.isWhitespace(tx[tx.len - 1])) omit_space = true;
            },
            .text => {
                t.data = replaceMultipleWhitespaceAndEntities(t.data, .text);
                if (omit_space and t.data.len > 0 and min.isWhitespace(t.data[0])) t.data = t.data[1..];
                omit_space = false;
                if (t.data.len == 0) {
                    omit_space = true;
                } else if (min.isWhitespace(t.data[t.data.len - 1])) {
                    omit_space = true;
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const nx = tb.peek(i);
                        if (nx.tt == .err) {
                            t.data = t.data[0 .. t.data.len - 1];
                            omit_space = false;
                            break;
                        } else if (nx.tt == .text) {
                            if (nx.data.len > 0 and min.isWhitespace(nx.data[0])) {
                                t.data = t.data[0 .. t.data.len - 1];
                                omit_space = false;
                            }
                            break;
                        } else if (nx.tt == .cdata) {
                            const ntx = nx.text orelse &.{};
                            if (ntx.len > 0 and min.isWhitespace(ntx[0])) {
                                t.data = t.data[0 .. t.data.len - 1];
                                omit_space = false;
                            }
                            break;
                        } else if (nx.tt == .start_tag or nx.tt == .end_tag) {
                            t.data = t.data[0 .. t.data.len - 1];
                            omit_space = false;
                            break;
                        }
                    }
                }
                out.w(t.data);
            },
            .start_tag, .start_tag_pi => out.w(t.data),
            .attribute => {
                out.w(" ");
                out.w(t.text orelse "");
                out.w("=");
                const av: []u8 = t.attr_val orelse buf[0..0];
                if (av.len < 2 or av[0] != '"' or av[av.len - 1] != '"') {
                    out.w(av);
                } else {
                    var val = av[1 .. av.len - 1];
                    val = replaceEntitiesAll(val, .attr);
                    out.w(escapeAttrVal(val));
                }
            },
            .start_tag_close => {
                var nx = tb.peek(0);
                var skip_extra = false;
                if (nx.tt == .text and isAllWs(nx.data)) {
                    nx = tb.peek(1);
                    skip_extra = true;
                }
                if (nx.tt == .end_tag) {
                    _ = tb.shift();
                    if (skip_extra) _ = tb.shift();
                    out.w("/>");
                } else out.w(t.data);
            },
            .start_tag_close_void, .start_tag_close_pi => out.w(t.data),
            .end_tag => {
                const tl = if (t.text) |tx| tx.len else 0;
                if (t.data.len > 3 + tl) {
                    t.data[2 + tl] = '>';
                    t.data = t.data[0 .. 3 + tl];
                }
                out.w(t.data);
            },
            .comment => {},
        }
    }
}

// ================================================================ SVG minifier

const precision: i64 = 0;
const new_precision: i64 = 15;

fn shortenDimension(b: []const u8) struct { b: []const u8, n: usize } {
    const d = dimension(b);
    if (d.n > 0) {
        var unit: []const u8 = b[d.n .. d.n + d.m];
        const num = min.number(b[0..d.n], precision);
        if (num.len != 1 or num[0] != '0') {
            if (d.m == 2 and unit[0] == 'p' and unit[1] == 'x') {
                unit = "";
            } else if (d.m > 1) unit = min.toLower(unit);
            return .{ .b = std.mem.concat(sys.A, u8, &.{ num, unit }) catch num, .n = d.n + d.m };
        }
        return .{ .b = num, .n = d.n + d.m };
    }
    return .{ .b = b, .n = 0 };
}

pub fn numberLen(b: []const u8) usize {
    if (b.len == 0) return 0;
    var i: usize = 0;
    if (b[i] == '+' or b[i] == '-') {
        i += 1;
        if (i >= b.len) return 0;
    }
    const first_digit = b[i] >= '0' and b[i] <= '9';
    if (first_digit) {
        i += 1;
        while (i < b.len and b[i] >= '0' and b[i] <= '9') i += 1;
    }
    if (i < b.len and b[i] == '.') {
        i += 1;
        if (i < b.len and b[i] >= '0' and b[i] <= '9') {
            i += 1;
            while (i < b.len and b[i] >= '0' and b[i] <= '9') i += 1;
        } else if (first_digit) {
            return i - 1;
        } else return 0;
    } else if (!first_digit) return 0;
    const i_old = i;
    if (i < b.len and (b[i] == 'e' or b[i] == 'E')) {
        i += 1;
        if (i < b.len and (b[i] == '+' or b[i] == '-')) i += 1;
        if (i >= b.len or b[i] < '0' or b[i] > '9') return i_old;
        while (i < b.len and b[i] >= '0' and b[i] <= '9') i += 1;
    }
    return i;
}

fn dimension(b: []const u8) struct { n: usize, m: usize } {
    const num = numberLen(b);
    if (num == 0 or num == b.len) return .{ .n = num, .m = 0 };
    if (b[num] == '%') return .{ .n = num, .m = 1 };
    if (std.ascii.isAlphabetic(b[num])) {
        var i = num + 1;
        while (i < b.len and std.ascii.isAlphabetic(b[i])) i += 1;
        return .{ .n = num, .m = i - num };
    }
    return .{ .n = num, .m = 0 };
}

fn skipTag(tb: *TokenBuffer) void {
    var level: usize = 0;
    while (true) {
        const t = tb.shift();
        if (t.tt == .err) break;
        if (t.tt == .end_tag or t.tt == .start_tag_close_void) {
            if (level == 0) break;
            level -= 1;
        } else if (t.tt == .start_tag) level += 1;
    }
}

fn printTag(out: *Out, tb: *TokenBuffer, tag: []const u8) void {
    var level: usize = 0;
    var in_start = false;
    while (true) {
        const t = tb.peek(0).*;
        switch (t.tt) {
            .err => return,
            .start_tag => {
                in_start = std.mem.eql(u8, t.hash, tag);
                if (in_start) level += 1;
            },
            .start_tag_close_void => {
                if (in_start) {
                    if (level == 0) return;
                    level -= 1;
                }
            },
            .end_tag => {
                if (std.mem.eql(u8, t.hash, tag)) {
                    if (level == 0) return;
                    level -= 1;
                }
            },
            else => {},
        }
        out.w(t.data);
        _ = tb.shift();
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const keep_namespaces = [_][]const u8{ "xlink", "", "x-bind" };

pub fn minifySvg(src: []const u8, inline_: bool) ![]const u8 {
    const buf = try sys.A.dupe(u8, src);
    var l = Lexer{ .s = buf };
    var tb = TokenBuffer{ .l = &l, .svg = true };
    var out = Out{};
    var tag: []const u8 = "";
    var default_style_type: []const u8 = "text/css";
    var pd = PathData{};
    while (true) {
        var t = tb.shift();
        switch (t.tt) {
            .err => {
                if (l.failed) return error.SVGError;
                return out.o.items;
            },
            .comment => {},
            .doctype => {
                const tx = t.text orelse "";
                if (tx.len > 0 and tx[tx.len - 1] == ']') out.w(t.data);
            },
            .text => {
                t.data = replaceMultipleWhitespaceAndEntities(t.data, .text);
                t.data = trimWs(t.data);
                if (eq(tag, "style") and t.data.len > 0) {
                    if (min.minifyByMime(default_style_type, t.data)) |m| out.w(m) else out.w(t.data);
                } else out.w(t.data);
            },
            .cdata => {
                var text = t.text orelse buf[0..0];
                if (eq(tag, "style")) {
                    if (min.minifyByMime(default_style_type, text)) |m| {
                        const nd = std.mem.concat(sys.A, u8, &.{ t.data[0..9], m, "]]>" }) catch t.data;
                        t.data = nd;
                        text = nd[9 .. nd.len - 3];
                    }
                }
                const e = escapeCDATAVal(text);
                if (e.use) {
                    out.w(min.trimWhitespace(min.replaceMultipleWhitespace(e.b)));
                } else out.w(t.data);
            },
            .start_tag_pi => {
                while (true) {
                    const t2 = tb.shift();
                    if (t2.tt == .start_tag_close_pi or t2.tt == .err) break;
                }
            },
            .start_tag => {
                tag = t.hash;
                var data: ?[]const u8 = t.data;
                const text = t.text orelse "";
                if (eq(tag, "metadata")) {
                    data = null;
                } else if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
                    if (eq(text[0..colon], "svg")) {
                        data = std.mem.concat(sys.A, u8, &.{ t.data[0..1], t.data[5..] }) catch t.data;
                    } else {
                        var keep = false;
                        for (keep_namespaces) |ns| if (eq(text[0..colon], ns)) {
                            keep = true;
                        };
                        if (!keep) data = null;
                    }
                } else if (eq(tag, "defs") and tb.peek(1).tt == .start_tag_close_void) {
                    data = null;
                }
                if (data) |d| out.w(d) else skipTag(&tb);
            },
            .attribute => {
                const attr = t.hash;
                const text = t.text orelse "";
                var val: []const u8 = t.attr_val orelse "";
                const dm = dimension(val);
                if (dm.n + dm.m == val.len and !eq(attr, "version")) val = shortenDimension(val).b;
                if ((eq(attr, "xml:space") and eq(val, "preserve")) or
                    (eq(tag, "svg") and ((inline_ and eq(attr, "xmlns")) or
                    (eq(attr, "version") and eq(val, "1.1")) or
                    (eq(attr, "x") and eq(val, "0")) or
                    (eq(attr, "y") and eq(val, "0")) or
                    (eq(attr, "preserveAspectRatio") and eq(val, "xMidYMid meet")) or
                    (eq(attr, "baseProfile") and eq(val, "none")) or
                    (eq(attr, "contentScriptType") and eq(val, "application/ecmascript")) or
                    (eq(attr, "contentStyleType") and eq(val, "text/css")))) or
                    (eq(tag, "style") and eq(attr, "type") and eq(val, "text/css"))) continue;
                if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
                    var keep = false;
                    for (keep_namespaces) |ns| {
                        if (eq(text[0..colon], ns) or (eq(tag, "svg") and eq(text[0..colon], "xmlns") and eq(ns, text[colon + 1 ..]))) {
                            keep = true;
                            break;
                        }
                    }
                    if (!keep) continue;
                }
                out.w(" ");
                out.w(text);
                out.w("=");
                if (eq(tag, "svg") and eq(attr, "contentStyleType")) {
                    val = mediatype(val);
                    default_style_type = val;
                } else if (eq(attr, "style")) {
                    if (min.isCssMime(default_style_type)) {
                        if (@import("min_css.zig").minify(val, true)) |m| val = m else |_| {}
                    }
                } else if (eq(attr, "d")) {
                    val = pd.shorten(val);
                } else if (eq(attr, "viewBox")) {
                    var nv: std.ArrayList(u8) = .empty;
                    var j: usize = 0;
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        if (i != 0) {
                            if (j >= val.len or (val[j] != ' ' and val[j] != ',')) {
                                if (j <= val.len) nv.appendSlice(sys.A, val[@min(j, val.len)..]) catch {};
                                break;
                            }
                            nv.append(sys.A, ' ') catch {};
                            j += 1;
                        }
                        const sd = shortenDimension(val[j..]);
                        if (sd.n > 0) {
                            nv.appendSlice(sys.A, sd.b) catch {};
                            j += sd.n;
                        } else {
                            nv.appendSlice(sys.A, val[j..]) catch {};
                            break;
                        }
                    }
                    val = nv.items;
                } else if ((eq(attr, "color") or eq(attr, "fill") or eq(attr, "stroke") or eq(attr, "stop-color") or eq(attr, "flood-color") or eq(attr, "lighting-color")) and val.len > 0 and (val.len < 5 or !min.eqlFold(val[0..4], "url("))) {
                    if (val[0] == '#') {
                        if (@import("min_css.zig").shortenHex(val)) |name| {
                            val = name;
                        } else if (val.len == 7 and val[1] == val[2] and val[3] == val[4] and val[5] == val[6]) {
                            const nv = sys.A.alloc(u8, 4) catch unreachable;
                            nv[0] = '#';
                            nv[1] = val[1];
                            nv[2] = val[3];
                            nv[3] = val[5];
                            val = nv;
                        }
                    } else if (@import("min_css.zig").shortenName(val)) |hex| val = hex;
                }
                out.w(escapeAttrVal(val));
            },
            .start_tag_close => {
                var nx = tb.peek(0);
                var skip_extra = false;
                if (nx.tt == .text and isAllWs(nx.data)) {
                    nx = tb.peek(1);
                    skip_extra = true;
                }
                if (nx.tt == .end_tag) {
                    _ = tb.shift();
                    if (skip_extra) _ = tb.shift();
                    out.w("/>");
                } else out.w(t.data);
                if (eq(tag, "foreignObject")) printTag(&out, &tb, tag);
            },
            .start_tag_close_void => {
                tag = "";
                out.w(t.data);
            },
            .start_tag_close_pi => {},
            .end_tag => {
                tag = "";
                const tl = if (t.text) |tx| tx.len else 0;
                if (t.data.len > 3 + tl) {
                    t.data[2 + tl] = '>';
                    t.data = t.data[0 .. 3 + tl];
                }
                out.w(t.data);
            },
        }
    }
}

/// minify.Mediatype: removes whitespace outside strings, lowercases.
fn mediatype(b0: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_string = false;
    for (b0) |c| {
        if (!in_string and min.isWhitespace(c)) continue;
        if (c == '"') in_string = !in_string;
        out.append(sys.A, if (in_string) c else std.ascii.toLower(c)) catch {};
    }
    return out.items;
}

// ================================================================ path data

const State = struct {
    cmd: u8 = 0,
    prev_digit: bool = false,
    prev_digit_is_int: bool = false,
    prev_flag: bool = false,

    fn copyNumber(state: *State, buffer: *std.ArrayList(u8), coord0: []const u8) void {
        if (coord0.len == 0) return;
        if (state.prev_digit and ((coord0[0] >= '0' and coord0[0] <= '9') or (coord0[0] == '.' and state.prev_digit_is_int))) {
            if (coord0[0] == '0' and !state.prev_digit_is_int) {
                buffer.appendSlice(sys.A, ".0") catch {};
                return;
            }
            buffer.append(sys.A, ' ') catch {};
        }
        state.prev_digit = true;
        state.prev_digit_is_int = true;
        const coord = sys.A.dupe(u8, coord0) catch return;
        if (coord.len > 2 and coord[coord.len - 2] == '0' and coord[coord.len - 1] == '0') {
            coord[coord.len - 2] = 'e';
            coord[coord.len - 1] = '2';
            state.prev_digit_is_int = false;
        } else {
            for (coord) |c| if (c == '.' or c == 'e' or c == 'E') {
                state.prev_digit_is_int = false;
                break;
            };
        }
        buffer.appendSlice(sys.A, coord) catch {};
        state.prev_flag = false;
    }
    fn copyFlag(state: *State, buffer: *std.ArrayList(u8), flag: bool) void {
        if (!state.prev_flag) buffer.append(sys.A, ' ') catch {};
        buffer.append(sys.A, if (flag) '1' else '0') catch {};
        state.prev_flag = true;
        state.prev_digit = false;
        state.prev_digit_is_int = false;
    }
};

fn isPathCmd(c: u8) bool {
    return switch (c) {
        'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'Q', 'q', 'T', 't', 'C', 'c', 'S', 's', 'A', 'a', 'Z', 'z' => true,
        else => false,
    };
}

const nan = std.math.nan(f64);

/// Go's strconv.AppendFloat(f, 'g', -1, 64).
pub fn goFormatG(f: f64) []const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f > 0) "+Inf" else "-Inf";
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{e}", .{f}) catch return "0";
    // s: [-]d[.ddd]e[-]x
    var i: usize = 0;
    const neg = s[0] == '-';
    if (neg) i = 1;
    const epos = std.mem.indexOfScalar(u8, s, 'e') orelse return sys.A.dupe(u8, s) catch "0";
    var digits: std.ArrayList(u8) = .empty;
    for (s[i..epos]) |c| if (c != '.') digits.append(sys.A, c) catch {};
    // trim trailing zeros (keep at least one digit)
    while (digits.items.len > 1 and digits.items[digits.items.len - 1] == '0') digits.items.len -= 1;
    const exp = std.fmt.parseInt(i32, s[epos + 1 ..], 10) catch 0;
    const d = digits.items;
    var out: std.ArrayList(u8) = .empty;
    if (neg) out.append(sys.A, '-') catch {};
    if (d.len == 1 and d[0] == '0') {
        out.append(sys.A, '0') catch {};
        return out.items;
    }
    if (exp < -4 or exp >= 6) {
        out.append(sys.A, d[0]) catch {};
        if (d.len > 1) {
            out.append(sys.A, '.') catch {};
            out.appendSlice(sys.A, d[1..]) catch {};
        }
        const ae: i32 = if (exp < 0) -exp else exp;
        var eb: [16]u8 = undefined;
        out.appendSlice(sys.A, std.fmt.bufPrint(&eb, "e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @as(u32, @intCast(ae)) }) catch "") catch {};
        return out.items;
    }
    if (exp < 0) {
        out.appendSlice(sys.A, "0.") catch {};
        var k: i32 = -1;
        while (k > exp) : (k -= 1) out.append(sys.A, '0') catch {};
        out.appendSlice(sys.A, d) catch {};
    } else {
        const ip: usize = @intCast(exp + 1);
        if (d.len <= ip) {
            out.appendSlice(sys.A, d) catch {};
            var k = d.len;
            while (k < ip) : (k += 1) out.append(sys.A, '0') catch {};
        } else {
            out.appendSlice(sys.A, d[0..ip]) catch {};
            out.append(sys.A, '.') catch {};
            out.appendSlice(sys.A, d[ip..]) catch {};
        }
    }
    return out.items;
}

/// tdewolff/parse/strconv.ParseFloat
fn parseFloat(b: []const u8) f64 {
    const pow10 = [_]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };
    var i: usize = 0;
    var neg = false;
    if (i < b.len and (b[i] == '+' or b[i] == '-')) {
        neg = b[i] == '-';
        i += 1;
    }
    const start = i;
    var dot: ?usize = null;
    var trunk: ?usize = null;
    var n: u64 = 0;
    while (i < b.len) : (i += 1) {
        const c = b[i];
        if ('0' <= c and c <= '9') {
            if (trunk == null) {
                if (std.math.maxInt(u64) / 10 < n or std.math.maxInt(u64) - @as(u64, c - '0') < n *% 10) {
                    trunk = i;
                } else {
                    n = n * 10 + (c - '0');
                }
            }
        } else if (dot == null and c == '.') {
            dot = i;
        } else break;
    }
    if (i == start or (i == start + 1 and dot != null and dot.? == start)) return 0;
    var f: f64 = @floatFromInt(n);
    if (neg) f = -f;
    var mant_exp: i64 = 0;
    if (dot) |d| {
        if (trunk == null) trunk = i;
        const tr: i64 = @intCast(trunk.?);
        const di: i64 = @intCast(d);
        mant_exp = if (tr < di) tr - di else tr - di - 1;
    } else if (trunk) |tr| {
        mant_exp = @as(i64, @intCast(tr)) - @as(i64, @intCast(i));
    }
    var exp_exp: i64 = 0;
    if (i < b.len and (b[i] == 'e' or b[i] == 'E')) {
        var k = i + 1;
        var eneg = false;
        if (k < b.len and (b[k] == '+' or b[k] == '-')) {
            eneg = b[k] == '-';
            k += 1;
        }
        const ks = k;
        var e: i64 = 0;
        while (k < b.len and b[k] >= '0' and b[k] <= '9') : (k += 1) e = e *| 10 +| (b[k] - '0');
        if (k > ks) exp_exp = if (eneg) -e else e;
    }
    const exp = exp_exp - mant_exp;
    if (exp == 0) return f;
    if (0 < exp and exp <= 15 + 22) {
        var g = f;
        var gexp = exp;
        if (22 < gexp) {
            g *= pow10[@intCast(gexp - 22)];
            gexp = 22;
        }
        if (-1e15 <= g and g <= 1e15) return g * pow10[@intCast(gexp)];
    } else if (-22 <= exp and exp < 0) {
        return f / pow10[@intCast(-exp)];
    }
    if (f == 0.0) return f;
    var h = f * std.math.pow(f64, 10, @floatFromInt(-mant_exp));
    h *= std.math.pow(f64, 10, @floatFromInt(exp_exp));
    if (h == 0.0 or std.math.isInf(h)) {
        var ff = f;
        var e2 = exp;
        if (e2 < -308) {
            ff *= std.math.pow(f64, 10, -308);
            e2 += 308;
        } else if (308 < e2) {
            ff *= std.math.pow(f64, 10, 308);
            e2 -= 308;
        }
        h = ff * std.math.pow(f64, 10, @floatFromInt(e2));
    }
    return h;
}

const PathData = struct {
    x: f64 = 0,
    y: f64 = 0,
    x0: f64 = 0,
    y0: f64 = 0,
    coords: std.ArrayList([]const u8) = .empty,
    floats: std.ArrayList(f64) = .empty,
    cx: f64 = nan,
    cy: f64 = nan,
    qx: f64 = nan,
    qy: f64 = nan,
    state: State = .{},
    cur: std.ArrayList(u8) = .empty,
    alt: std.ArrayList(u8) = .empty,

    fn shorten(p: *PathData, b0: []const u8) []const u8 {
        if (100000 < b0.len) return b0;
        const b = sys.A.dupe(u8, b0) catch return b0;
        p.x = 0;
        p.y = 0;
        p.coords.items.len = 0;
        p.floats.items.len = 0;
        p.state = .{};
        var out: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        var cmd: u8 = 0;
        var i: usize = 0;
        while (i < b.len) : (i += 1) {
            const c = b[i];
            if (c == ' ' or c == ',' or c == '\n' or c == '\r' or c == '\t') {
                continue;
            } else if (isPathCmd(c) and (cmd == 0 or (cmd != c and (cmd != 'M' or c != 'L') and (cmd != 'm' or c != 'l')) or c == 'M' or c == 'm')) {
                if (0 < i) {
                    if (cmd != 0) {
                        p.copyInstruction(&out, b[k..i], cmd);
                    } else out.appendSlice(sys.A, b[k..i]) catch {};
                    k = i;
                }
                cmd = c;
                p.coords.items.len = 0;
                p.floats.items.len = 0;
            } else if ((cmd == 'A' or cmd == 'a') and (p.floats.items.len % 7 == 3 or p.floats.items.len % 7 == 4)) {
                if (c == '1') {
                    p.coords.append(sys.A, b[i .. i + 1]) catch {};
                    p.floats.append(sys.A, 1.0) catch {};
                } else if (c == '0') {
                    p.coords.append(sys.A, b[i .. i + 1]) catch {};
                    p.floats.append(sys.A, 0.0) catch {};
                } else cmd = 0;
            } else {
                const n = numberLen(b[i..]);
                if (0 < n) {
                    p.coords.append(sys.A, b[i .. i + n]) catch {};
                    p.floats.append(sys.A, parseFloat(b[i .. i + n])) catch {};
                    i += n - 1;
                } else if (!isPathCmd(c)) cmd = 0;
            }
        }
        if (cmd != 0) {
            p.copyInstruction(&out, b[k..], cmd);
        } else out.appendSlice(sys.A, b[k..]) catch {};
        return out.items;
    }

    fn copyInstruction(p: *PathData, out: *std.ArrayList(u8), orig: []const u8, cmd0: u8) void {
        var cmd = cmd0;
        const n = p.coords.items.len;
        if (n == 0) {
            if (cmd == 'Z' or cmd == 'z') {
                p.state.cmd = 0;
                p.state.prev_digit = false;
                p.state.prev_digit_is_int = false;
                p.x = p.x0;
                p.y = p.y0;
                out.append(sys.A, 'z') catch {};
                return;
            }
            out.appendSlice(sys.A, orig) catch {};
            return;
        }
        const is_rel = cmd >= 'a';
        var di: usize = 0;
        if ((cmd == 'M' or cmd == 'm') and n % 2 == 0) {
            di = 2;
        } else if ((cmd == 'L' or cmd == 'l' or cmd == 'T' or cmd == 't') and n % 2 == 0) {
            di = 2;
        } else if (cmd == 'H' or cmd == 'h' or cmd == 'V' or cmd == 'v') {
            di = 1;
        } else if ((cmd == 'S' or cmd == 's' or cmd == 'Q' or cmd == 'q') and n % 4 == 0) {
            di = 4;
        } else if ((cmd == 'C' or cmd == 'c') and n % 6 == 0) {
            di = 6;
        } else if ((cmd == 'A' or cmd == 'a') and n % 7 == 0) {
            di = 7;
        } else {
            out.appendSlice(sys.A, orig) catch {};
            return;
        }
        var orig_cmd = cmd;
        var i: usize = 0;
        while (i < n) : (i += di) {
            if (0 < i and (orig_cmd == 'M' or orig_cmd == 'm')) orig_cmd = 'L' + (orig_cmd - 'M');
            cmd = orig_cmd;
            var coords = p.coords.items[i .. i + di];
            var cf = p.floats.items[i .. i + di];
            var ax: f64 = 0;
            var ay: f64 = 0;
            if (cmd == 'H' or cmd == 'h') {
                ax = cf[di - 1];
                if (is_rel) ax += p.x;
                ay = p.y;
            } else if (cmd == 'V' or cmd == 'v') {
                ax = p.x;
                ay = cf[di - 1];
                if (is_rel) ay += p.y;
            } else {
                ax = cf[di - 2];
                ay = cf[di - 1];
                if (is_rel) {
                    ax += p.x;
                    ay += p.y;
                }
            }
            if (cmd == 'C' or cmd == 'c' or cmd == 'S' or cmd == 's') {
                if (std.math.isNan(p.cx)) {
                    p.cx = p.x;
                    p.cy = p.y;
                } else {
                    p.cx = 2 * p.x - p.cx;
                    p.cy = 2 * p.y - p.cy;
                }
                var cp1x: f64 = 0;
                var cp1y: f64 = 0;
                var cp2x = cf[di - 4];
                var cp2y = cf[di - 3];
                if (is_rel) {
                    cp2x += p.x;
                    cp2y += p.y;
                }
                if (cmd == 'C' or cmd == 'c') {
                    cp1x = cf[di - 6];
                    cp1y = cf[di - 5];
                    if (is_rel) {
                        cp1x += p.x;
                        cp1y += p.y;
                    }
                    if (cp1x == p.cx and cp1y == p.cy) {
                        cmd = if (is_rel) 's' else 'S';
                        coords = coords[2..];
                        cf = cf[2..];
                    }
                } else {
                    cp1x = p.cx;
                    cp1y = p.cy;
                }
                if ((cmd == 'C' or cmd == 'c' or (i == 0 and i + di >= n)) and ((cp1x == p.x and cp1y == p.y) or (cp1x == ax and cp1y == ay)) and ((cp2x == p.x and cp2y == p.y) or (cp2x == ax and cp2y == ay))) {
                    cmd = if (is_rel) 'l' else 'L';
                    coords = coords[coords.len - 2 ..];
                    cf = cf[cf.len - 2 ..];
                    cp2x = nan;
                    cp2y = nan;
                }
                p.cx = cp2x;
                p.cy = cp2y;
            } else {
                p.cx = nan;
                p.cy = nan;
            }
            if (cmd == 'Q' or cmd == 'q' or cmd == 'T' or cmd == 't') {
                if (std.math.isNan(p.qx)) {
                    p.qx = p.x;
                    p.qy = p.y;
                } else {
                    p.qx = 2 * p.x - p.qx;
                    p.qy = 2 * p.y - p.qy;
                }
                var cpx: f64 = 0;
                var cpy: f64 = 0;
                if (cmd == 'Q' or cmd == 'q') {
                    cpx = cf[di - 4];
                    cpy = cf[di - 3];
                    if (is_rel) {
                        cpx += p.x;
                        cpy += p.y;
                    }
                    if (cpx == p.qx and cpy == p.qy) {
                        cmd = if (is_rel) 't' else 'T';
                        coords = coords[2..];
                        cf = cf[2..];
                    }
                } else {
                    cpx = p.qx;
                    cpy = p.qy;
                }
                if ((cmd == 'Q' or cmd == 'q' or (i == 0 and i + di >= n)) and ((cpx == p.x and cpy == p.y) or (cpx == ax and cpy == ay))) {
                    cmd = if (is_rel) 'l' else 'L';
                    coords = coords[coords.len - 2 ..];
                    cf = cf[cf.len - 2 ..];
                    cpx = nan;
                    cpy = nan;
                }
                p.qx = cpx;
                p.qy = cpy;
            } else {
                p.qx = nan;
                p.qy = nan;
            }
            if (cmd == 'L' or cmd == 'l') {
                if (ax == p.x and ay == p.y) {
                    continue;
                } else if (ax == p.x) {
                    cmd = if (is_rel) 'v' else 'V';
                    coords = coords[1..];
                    cf = cf[1..];
                } else if (ay == p.y) {
                    cmd = if (is_rel) 'h' else 'H';
                    coords = coords[0..1];
                    cf = cf[0..1];
                }
            }
            const cur_state = p.shortenCur(cmd, coords);
            const alt_state = if (is_rel) p.shortenAlt(cmd - 'a' + 'A', cf, p.x, p.y) else p.shortenAlt(cmd - 'A' + 'a', cf, -p.x, -p.y);
            if (p.alt.items.len < p.cur.items.len) {
                out.appendSlice(sys.A, p.alt.items) catch {};
                p.state = alt_state;
            } else {
                out.appendSlice(sys.A, p.cur.items) catch {};
                p.state = cur_state;
            }
            p.x = ax;
            p.y = ay;
            if (i == 0 and (orig_cmd == 'M' or orig_cmd == 'm')) {
                p.x0 = p.x;
                p.y0 = p.y;
            }
        }
    }

    fn shortenCur(p: *PathData, cmd: u8, coords: []const []const u8) State {
        var state = p.state;
        p.cur.items.len = 0;
        if ((cmd != state.cmd or cmd == 'M' or cmd == 'm') and !((state.cmd == 'M' and cmd == 'L') or (state.cmd == 'm' and cmd == 'l'))) {
            p.cur.append(sys.A, cmd) catch {};
            state.prev_digit = false;
            state.prev_digit_is_int = false;
        }
        state.cmd = cmd;
        for (coords, 0..) |coord, i| {
            if ((cmd == 'A' or cmd == 'a') and (i % 7 == 3 or i % 7 == 4)) {
                state.copyFlag(&p.cur, coord[0] == '1');
                continue;
            }
            state.copyNumber(&p.cur, min.number(coord, precision));
        }
        return state;
    }

    fn shortenAlt(p: *PathData, cmd: u8, cf: []const f64, x0: f64, y0: f64) State {
        var x = x0;
        var y = y0;
        var state = p.state;
        p.alt.items.len = 0;
        if ((cmd != state.cmd or cmd == 'M' or cmd == 'm') and !((state.cmd == 'M' and cmd == 'L') or (state.cmd == 'm' and cmd == 'l'))) {
            p.alt.append(sys.A, cmd) catch {};
            state.prev_digit = false;
            state.prev_digit_is_int = false;
        }
        state.cmd = cmd;
        for (cf, 0..) |f0, i| {
            var f = f0;
            if (cmd == 'M' or cmd == 'm') {
                if (i % 2 == 0) {
                    f += x;
                    x = f;
                } else {
                    f += y;
                    y = f;
                }
            } else if (cmd == 'L' or cmd == 'l' or cmd == 'C' or cmd == 'c' or cmd == 'S' or cmd == 's' or cmd == 'Q' or cmd == 'q' or cmd == 'T' or cmd == 't') {
                if (i % 2 == 0) f += x else f += y;
            } else if (cmd == 'H' or cmd == 'h') {
                f += x;
            } else if (cmd == 'V' or cmd == 'v') {
                f += y;
            } else if (cmd == 'A' or cmd == 'a') {
                if (i % 7 == 5) {
                    f += x;
                } else if (i % 7 == 6) {
                    f += y;
                } else if (i % 7 == 3 or i % 7 == 4) {
                    state.copyFlag(&p.alt, f == 1.0);
                    continue;
                }
            }
            state.copyNumber(&p.alt, min.number(goFormatG(f), new_precision));
        }
        return state;
    }
};
