// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/minify and tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! CSS minifier: a port of tdewolff/parse/css (lexer, parser) and
//! tdewolff/minify/css (MIT), so that output and fingerprints match Hugo's.
const std = @import("std");
const sys = @import("sys.zig");
const min = @import("min.zig");

pub const TT = enum(u8) {
    err,
    ident,
    function,
    at_keyword,
    hash,
    string,
    bad_string,
    url,
    bad_url,
    delim,
    number,
    percentage,
    dimension,
    unicode_range,
    include_match,
    dash_match,
    prefix_match,
    suffix_match,
    substring_match,
    column,
    whitespace,
    cdo,
    cdc,
    colon,
    semicolon,
    comma,
    left_bracket,
    right_bracket,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    comment,
    empty,
    custom_property_name,
    custom_property_value,
};

// ================================================================ lexer

pub const Lexer = struct {
    s: []const u8,
    pos: usize = 0,
    start: usize = 0,

    fn peek(l: *const Lexer, n: usize) u8 {
        return if (l.pos + n < l.s.len) l.s[l.pos + n] else 0;
    }
    fn eof(l: *const Lexer) bool {
        return l.pos >= l.s.len;
    }
    fn move(l: *Lexer, n: isize) void {
        l.pos = @intCast(@as(isize, @intCast(l.pos)) + n);
    }
    fn shift(l: *Lexer) []const u8 {
        const r = l.s[l.start..l.pos];
        l.start = l.pos;
        return r;
    }

    pub fn next(l: *Lexer) struct { tt: TT, data: []const u8 } {
        const c = l.peek(0);
        switch (c) {
            ' ', '\t', '\n', '\r', 0x0c => {
                l.move(1);
                while (l.consumeWhitespace()) {}
                return .{ .tt = .whitespace, .data = l.shift() };
            },
            ':' => {
                l.move(1);
                return .{ .tt = .colon, .data = l.shift() };
            },
            ';' => {
                l.move(1);
                return .{ .tt = .semicolon, .data = l.shift() };
            },
            ',' => {
                l.move(1);
                return .{ .tt = .comma, .data = l.shift() };
            },
            '(', ')', '[', ']', '{', '}' => {
                const t: TT = switch (c) {
                    '(' => .left_paren,
                    ')' => .right_paren,
                    '[' => .left_bracket,
                    ']' => .right_bracket,
                    '{' => .left_brace,
                    else => .right_brace,
                };
                l.move(1);
                return .{ .tt = t, .data = l.shift() };
            },
            '#' => if (l.consumeHashToken()) return .{ .tt = .hash, .data = l.shift() },
            '"', '\'' => {
                const t = l.consumeString();
                return .{ .tt = t, .data = l.shift() };
            },
            '.', '+' => if (l.consumeNumeric()) |t| return .{ .tt = t, .data = l.shift() },
            '-' => {
                if (l.consumeCDC()) return .{ .tt = .cdc, .data = l.shift() };
                if (l.consumeCustomVariable()) return .{ .tt = .custom_property_name, .data = l.shift() };
                if (l.consumeIdentlike()) |t| return .{ .tt = t, .data = l.shift() };
                if (l.consumeNumeric()) |t| return .{ .tt = t, .data = l.shift() };
            },
            '@' => if (l.consumeAtKeyword()) return .{ .tt = .at_keyword, .data = l.shift() },
            '$', '*', '^', '~' => if (l.consumeMatch()) |t| return .{ .tt = t, .data = l.shift() },
            '/' => if (l.consumeComment()) return .{ .tt = .comment, .data = l.shift() },
            '<' => if (l.consumeCDO()) return .{ .tt = .cdo, .data = l.shift() },
            '\\' => if (l.consumeIdentlike()) |t| return .{ .tt = t, .data = l.shift() },
            'u', 'U' => {
                if (l.consumeUnicodeRange()) return .{ .tt = .unicode_range, .data = l.shift() };
                if (l.consumeIdentlike()) |t| return .{ .tt = t, .data = l.shift() };
            },
            '|' => {
                if (l.consumeMatch()) |t| return .{ .tt = t, .data = l.shift() };
                if (l.peek(0) == '|' and l.peek(1) == '|') {
                    l.move(2);
                    return .{ .tt = .column, .data = l.shift() };
                }
            },
            0 => if (l.eof()) return .{ .tt = .err, .data = "" },
            else => {
                if (l.consumeNumeric()) |t| return .{ .tt = t, .data = l.shift() };
                if (l.consumeIdentlike()) |t| return .{ .tt = t, .data = l.shift() };
            },
        }
        l.move(1);
        return .{ .tt = .delim, .data = l.shift() };
    }

    fn consumeByte(l: *Lexer, c: u8) bool {
        if (l.peek(0) == c and !(c == 0 and l.eof())) {
            l.move(1);
            return true;
        }
        return false;
    }
    fn consumeComment(l: *Lexer) bool {
        if (l.peek(0) != '/' or l.peek(1) != '*') return false;
        l.move(2);
        while (true) {
            if (l.eof()) break;
            if (l.peek(0) == '*' and l.peek(1) == '/') {
                l.move(2);
                return true;
            }
            l.move(1);
        }
        return true;
    }
    fn consumeNewline(l: *Lexer) bool {
        const c = l.peek(0);
        if (c == '\n' or c == 0x0c) {
            l.move(1);
            return true;
        } else if (c == '\r') {
            if (l.peek(1) == '\n') l.move(2) else l.move(1);
            return true;
        }
        return false;
    }
    fn consumeWhitespace(l: *Lexer) bool {
        const c = l.peek(0);
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
            l.move(1);
            return true;
        }
        return false;
    }
    fn consumeDigit(l: *Lexer) bool {
        const c = l.peek(0);
        if (c >= '0' and c <= '9') {
            l.move(1);
            return true;
        }
        return false;
    }
    fn consumeHexDigit(l: *Lexer) bool {
        const c = l.peek(0);
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            l.move(1);
            return true;
        }
        return false;
    }
    fn consumeEscape(l: *Lexer) bool {
        if (l.peek(0) != '\\') return false;
        const mark = l.pos;
        l.move(1);
        if (l.consumeNewline()) {
            l.pos = mark;
            return false;
        } else if (l.consumeHexDigit()) {
            var k: usize = 1;
            while (k < 6) : (k += 1) if (!l.consumeHexDigit()) break;
            _ = l.consumeWhitespace();
            return true;
        } else {
            const c = l.peek(0);
            if (c >= 0xC0) {
                const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
                l.move(@intCast(n));
                return true;
            } else if (c == 0 and l.eof()) {
                l.pos = mark;
                return false;
            }
        }
        l.move(1);
        return true;
    }
    fn identStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
    }
    fn identChar(c: u8) bool {
        return identStart(c) or (c >= '0' and c <= '9') or c == '-';
    }
    fn consumeIdentToken(l: *Lexer) bool {
        const mark = l.pos;
        var custom = false;
        if (l.peek(0) == '-') {
            l.move(1);
            if (l.peek(0) == '-') {
                l.move(1);
                custom = true;
            }
        }
        if (!custom) {
            const c = l.peek(0);
            if (!identStart(c)) {
                if (c != '\\' or !l.consumeEscape()) {
                    l.pos = mark;
                    return false;
                }
            } else l.move(1);
        }
        while (true) {
            const c = l.peek(0);
            if (!identChar(c) or (c == 0 and l.eof())) {
                if (c != '\\' or !l.consumeEscape()) break;
            } else l.move(1);
        }
        return true;
    }
    fn consumeCustomVariable(l: *Lexer) bool {
        if (l.peek(1) != '-') return false;
        return l.consumeIdentToken();
    }
    fn consumeAtKeyword(l: *Lexer) bool {
        l.move(1);
        if (!l.consumeIdentToken()) {
            l.move(-1);
            return false;
        }
        return true;
    }
    fn consumeHashToken(l: *Lexer) bool {
        const mark = l.pos;
        l.move(1);
        const c = l.peek(0);
        if (!identChar(c) or (c == 0 and l.eof())) {
            if (c != '\\' or !l.consumeEscape()) {
                l.pos = mark;
                return false;
            }
        } else l.move(1);
        while (true) {
            const d = l.peek(0);
            if (!identChar(d) or (d == 0 and l.eof())) {
                if (d != '\\' or !l.consumeEscape()) break;
            } else l.move(1);
        }
        return true;
    }
    fn consumeNumberToken(l: *Lexer) bool {
        var mark = l.pos;
        var c = l.peek(0);
        if (c == '+' or c == '-') l.move(1);
        const first_digit = l.consumeDigit();
        if (first_digit) while (l.consumeDigit()) {};
        if (l.peek(0) == '.') {
            l.move(1);
            if (l.consumeDigit()) {
                while (l.consumeDigit()) {}
            } else if (first_digit) {
                l.move(-1);
                return true;
            } else {
                l.pos = mark;
                return false;
            }
        } else if (!first_digit) {
            l.pos = mark;
            return false;
        }
        mark = l.pos;
        c = l.peek(0);
        if (c == 'e' or c == 'E') {
            l.move(1);
            c = l.peek(0);
            if (c == '+' or c == '-') l.move(1);
            if (!l.consumeDigit()) {
                l.pos = mark;
                return true;
            }
            while (l.consumeDigit()) {}
        }
        return true;
    }
    fn consumeUnicodeRange(l: *Lexer) bool {
        const c = l.peek(0);
        if ((c != 'u' and c != 'U') or l.peek(1) != '+') return false;
        const mark = l.pos;
        l.move(2);
        var k: usize = 0;
        while (l.consumeHexDigit()) k += 1;
        if (l.consumeByte('-')) {
            if (k == 0 or 6 < k) {
                l.pos = mark;
                return false;
            }
            if (l.consumeHexDigit()) {
                k = 1;
                while (l.consumeHexDigit()) k += 1;
            } else {
                l.pos = mark;
                return false;
            }
        } else if (l.consumeByte('?')) {
            k += 1;
            while (l.consumeByte('?')) k += 1;
        }
        if (k == 0 or 6 < k) {
            l.pos = mark;
            return false;
        }
        return true;
    }
    fn consumeCDO(l: *Lexer) bool {
        if (l.peek(0) == '<' and l.peek(1) == '!' and l.peek(2) == '-' and l.peek(3) == '-') {
            l.move(4);
            return true;
        }
        return false;
    }
    fn consumeCDC(l: *Lexer) bool {
        if (l.peek(0) == '-' and l.peek(1) == '-' and l.peek(2) == '>') {
            l.move(3);
            return true;
        }
        return false;
    }
    fn consumeMatch(l: *Lexer) ?TT {
        if (l.peek(1) == '=') {
            const t: ?TT = switch (l.peek(0)) {
                '~' => .include_match,
                '|' => .dash_match,
                '^' => .prefix_match,
                '$' => .suffix_match,
                '*' => .substring_match,
                else => null,
            };
            if (t) |x| {
                l.move(2);
                return x;
            }
        }
        return null;
    }
    fn consumeNumeric(l: *Lexer) ?TT {
        if (l.consumeNumberToken()) {
            if (l.consumeByte('%')) return .percentage;
            if (l.consumeIdentToken()) return .dimension;
            return .number;
        }
        return null;
    }
    fn consumeString(l: *Lexer) TT {
        const delim = l.peek(0);
        l.move(1);
        while (true) {
            const c = l.peek(0);
            if (c == 0 and l.eof()) {
                break;
            } else if (c == '\n' or c == '\r' or c == 0x0c) {
                l.move(1);
                return .bad_string;
            } else if (c == delim) {
                l.move(1);
                break;
            } else if (c == '\\') {
                if (!l.consumeEscape()) {
                    l.move(1);
                    _ = l.consumeNewline();
                }
            } else l.move(1);
        }
        return .string;
    }
    fn consumeUnquotedURL(l: *Lexer) bool {
        while (true) {
            const c = l.peek(0);
            if ((c == 0 and l.eof()) or c == ')') {
                break;
            } else if (c == '"' or c == '\'' or c == '(' or c == '\\' or c == ' ' or c <= 0x1F or c == 0x7F) {
                if (c != '\\' or !l.consumeEscape()) return false;
            } else l.move(1);
        }
        return true;
    }
    fn consumeRemnantsBadURL(l: *Lexer) void {
        while (true) {
            if (l.consumeByte(')') or l.eof()) break;
            if (!l.consumeEscape()) l.move(1);
        }
    }
    fn consumeIdentlike(l: *Lexer) ?TT {
        if (l.consumeIdentToken()) {
            if (l.peek(0) != '(') return .ident;
            const lex = l.s[l.start..l.pos];
            var buf: [8]u8 = undefined;
            var n: usize = 0;
            var is_url = true;
            for (lex) |c| {
                if (c == '\\') continue;
                if (n >= 3) {
                    is_url = false;
                    break;
                }
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
            if (!is_url or n != 3 or !std.mem.eql(u8, buf[0..3], "url")) {
                l.move(1);
                return .function;
            }
            l.move(1);
            while (l.consumeWhitespace()) {}
            const c = l.peek(0);
            if (c == '"' or c == '\'') {
                if (l.consumeString() == .bad_string) {
                    l.consumeRemnantsBadURL();
                    return .bad_url;
                }
            } else if (!l.consumeUnquotedURL() and !l.consumeWhitespace()) {
                l.consumeRemnantsBadURL();
                return .bad_url;
            }
            while (l.consumeWhitespace()) {}
            if (!l.consumeByte(')') and !l.eof()) {
                l.consumeRemnantsBadURL();
                return .bad_url;
            }
            return .url;
        }
        return null;
    }
};

pub fn isIdent(b: []const u8) bool {
    var l = Lexer{ .s = b };
    _ = l.consumeIdentToken();
    return l.pos == b.len;
}
pub fn isUrlUnquoted(b: []const u8) bool {
    var l = Lexer{ .s = b };
    _ = l.consumeUnquotedURL();
    return l.pos == b.len;
}

// ================================================================ parser

pub const GT = enum { err, comment, at_rule, begin_at_rule, end_at_rule, qualified_rule, begin_ruleset, end_ruleset, declaration, token, custom_property };

pub const PTok = struct { tt: TT, data: []const u8 };

const State = enum { stylesheet, declaration_list, at_rule_rule_list, at_rule_declaration_list, at_rule_unknown, qualified_rule_declaration_list };

pub const Parser = struct {
    l: Lexer,
    state: std.ArrayList(State) = .empty,
    has_err: bool = false,
    buf: std.ArrayList(PTok) = .empty,
    level: i64 = 0,
    data: []const u8 = "",
    tt: TT = .err,
    keep_ws: bool = false,
    prev_ws: bool = false,
    prev_end: bool = false,
    prev_comment: bool = false,
    is_stylesheet: bool = false,

    pub fn init(s: []const u8, inline_: bool) Parser {
        var p = Parser{ .l = .{ .s = s } };
        if (inline_) {
            p.state.append(sys.A, .declaration_list) catch {};
        } else {
            p.state.append(sys.A, .stylesheet) catch {};
            p.is_stylesheet = true;
        }
        return p;
    }

    pub fn next(p: *Parser) struct { gt: GT, tt: TT, data: []const u8 } {
        p.has_err = false;
        if (p.prev_end) {
            p.tt = .right_brace;
            p.data = "}";
            p.prev_end = false;
        } else {
            const t = p.popToken(true);
            p.tt = t.tt;
            p.data = t.data;
        }
        const gt = switch (p.state.items[p.state.items.len - 1]) {
            .stylesheet => p.parseStylesheet(),
            .declaration_list => p.parseDeclarationList(),
            .at_rule_rule_list => p.parseAtRuleRuleList(),
            .at_rule_declaration_list => p.parseAtRuleDeclarationList(),
            .at_rule_unknown => p.parseAtRuleUnknown(),
            .qualified_rule_declaration_list => p.parseQualifiedRuleDeclarationList(),
        };
        return .{ .gt = gt, .tt = p.tt, .data = p.data };
    }

    pub fn values(p: *Parser) []PTok {
        return p.buf.items;
    }

    fn popToken(p: *Parser, allow_comment: bool) PTok {
        p.prev_ws = false;
        p.prev_comment = false;
        var t = p.l.next();
        while ((!p.keep_ws and t.tt == .whitespace) or t.tt == .comment) {
            if (t.tt == .whitespace) {
                p.prev_ws = true;
            } else {
                p.prev_comment = true;
                if (allow_comment and p.state.items.len == 1) break;
            }
            t = p.l.next();
        }
        return .{ .tt = t.tt, .data = t.data };
    }
    fn push(p: *Parser, tt: TT, data: []const u8) void {
        p.buf.append(sys.A, .{ .tt = tt, .data = data }) catch {};
    }
    fn popState(p: *Parser) void {
        p.state.items.len -= 1;
    }

    fn parseStylesheet(p: *Parser) GT {
        if (p.tt == .cdo or p.tt == .cdc) return .token;
        if (p.tt == .at_keyword) return p.parseAtRule();
        if (p.tt == .comment) return .comment;
        if (p.tt == .custom_property_name) return p.parseCustomProperty();
        if (p.tt == .err) return .err;
        return p.parseQualifiedRule();
    }

    fn parseDeclarationList(p: *Parser) GT {
        if (p.tt == .comment) {
            const t = p.popToken(false);
            p.tt = t.tt;
            p.data = t.data;
        }
        while (p.tt == .semicolon) {
            const t = p.popToken(false);
            p.tt = t.tt;
            p.data = t.data;
        }
        if (p.tt == .delim and p.data[0] == '*') {
            const t = p.popToken(false);
            p.tt = t.tt;
            p.data = std.mem.concat(sys.A, u8, &.{ p.data, t.data }) catch p.data;
        }
        if (p.tt == .err) return .err;
        if (p.tt == .at_keyword) return p.parseAtRule();
        if (p.tt == .ident or p.tt == .delim) return p.parseDeclaration();
        if (p.tt == .custom_property_name) return p.parseCustomProperty();
        p.buf.clearRetainingCapacity();
        p.has_err = true;
        if (p.tt == .right_brace) {
            p.push(p.tt, p.data);
            return .err;
        }
        return p.parseDeclarationError(p.tt, p.data);
    }

    fn parseAtRule(p: *Parser) GT {
        p.buf.clearRetainingCapacity();
        p.data = min.toLower(p.data);
        var name = p.data;
        if (name.len > 1 and name[1] == '-') {
            if (std.mem.indexOfScalar(u8, name[2..], '-')) |i| name = name[i + 2 ..];
        }
        const at_rule = name[1..];
        var first = true;
        var skip_ws = false;
        while (true) {
            const t = p.popToken(false);
            const tt = t.tt;
            const data = t.data;
            if (tt == .left_brace and p.level == 0) {
                if (eq(at_rule, "font-face") or eq(at_rule, "page")) {
                    p.state.append(sys.A, .at_rule_declaration_list) catch {};
                } else if (eq(at_rule, "document") or eq(at_rule, "keyframes") or eq(at_rule, "layer") or eq(at_rule, "media") or eq(at_rule, "supports")) {
                    p.state.append(sys.A, .at_rule_rule_list) catch {};
                } else p.state.append(sys.A, .at_rule_unknown) catch {};
                return .begin_at_rule;
            } else if (((tt == .semicolon or tt == .right_brace) and p.level == 0) or tt == .err) {
                p.prev_end = tt == .right_brace;
                return .at_rule;
            } else if (tt == .left_paren or tt == .left_brace or tt == .left_bracket or tt == .function) {
                p.level += 1;
            } else if (tt == .right_paren or tt == .right_brace or tt == .right_bracket) {
                if (p.level == 0) {
                    p.push(tt, data);
                    if (1 < p.state.items.len) p.popState();
                    p.has_err = true;
                    return .err;
                }
                p.level -= 1;
            }
            if (first) {
                if (tt == .left_paren or tt == .left_bracket) p.prev_ws = false;
                first = false;
            }
            if (data.len == 1 and (data[0] == ',' or data[0] == ':')) {
                skip_ws = true;
            } else if (p.prev_ws and !skip_ws and tt != .right_paren) {
                p.push(.whitespace, " ");
            } else skip_ws = false;
            if (tt == .left_paren) skip_ws = true;
            p.push(tt, data);
        }
    }

    fn parseAtRuleRuleList(p: *Parser) GT {
        if (p.tt == .right_brace or p.tt == .err) {
            p.popState();
            return .end_at_rule;
        } else if (p.tt == .at_keyword) return p.parseAtRule();
        return p.parseQualifiedRule();
    }

    fn parseAtRuleDeclarationList(p: *Parser) GT {
        while (p.tt == .semicolon) {
            const t = p.popToken(false);
            p.tt = t.tt;
            p.data = t.data;
        }
        if (p.tt == .right_brace or p.tt == .err) {
            p.popState();
            return .end_at_rule;
        }
        return p.parseDeclarationList();
    }

    fn parseAtRuleUnknown(p: *Parser) GT {
        p.keep_ws = true;
        if ((p.tt == .right_brace and p.level == 0) or p.tt == .err) {
            p.popState();
            p.keep_ws = false;
            return .end_at_rule;
        }
        if (p.tt == .left_paren or p.tt == .left_brace or p.tt == .left_bracket or p.tt == .function) {
            p.level += 1;
        } else if (p.tt == .right_paren or p.tt == .right_brace or p.tt == .right_bracket) p.level -= 1;
        return .token;
    }

    fn parseQualifiedRule(p: *Parser) GT {
        p.buf.clearRetainingCapacity();
        var first = true;
        var in_attr = false;
        var skip_ws = true;
        while (true) {
            var tt: TT = undefined;
            var data: []const u8 = undefined;
            if (first) {
                tt = p.tt;
                data = p.data;
                p.tt = .whitespace;
                p.data = "";
                first = false;
            } else {
                const t = p.popToken(false);
                tt = t.tt;
                data = t.data;
            }
            if (tt == .left_brace and p.level == 0) {
                p.state.append(sys.A, .qualified_rule_declaration_list) catch {};
                return .begin_ruleset;
            } else if (tt == .err) {
                p.has_err = true;
                return .err;
            } else if (tt == .left_paren or tt == .left_brace or tt == .left_bracket or tt == .function) {
                p.level += 1;
            } else if (tt == .right_paren or tt == .right_brace or tt == .right_bracket) {
                if (p.level == 0) {
                    p.push(tt, data);
                    if (1 < p.state.items.len) p.popState();
                    p.has_err = true;
                    return .err;
                }
                p.level -= 1;
            }
            if (data.len == 1 and (data[0] == ',' or data[0] == '>' or data[0] == '+' or data[0] == '~')) {
                skip_ws = true;
            } else if (p.prev_ws and !skip_ws and !in_attr) {
                p.push(.whitespace, " ");
            } else skip_ws = false;
            if (tt == .left_bracket) {
                in_attr = true;
            } else if (tt == .right_bracket) in_attr = false;
            p.push(tt, data);
        }
    }

    fn parseQualifiedRuleDeclarationList(p: *Parser) GT {
        while (p.tt == .semicolon) {
            const t = p.popToken(false);
            p.tt = t.tt;
            p.data = t.data;
        }
        if (p.tt == .right_brace or p.tt == .err) {
            p.popState();
            return .end_ruleset;
        }
        return p.parseDeclarationList();
    }

    fn isSep1(d: []const u8) bool {
        return d.len == 1 and (d[0] == ',' or d[0] == '/' or d[0] == ':' or d[0] == '!' or d[0] == '=');
    }

    fn parseDeclaration(p: *Parser) GT {
        p.buf.clearRetainingCapacity();
        p.push(p.tt, p.data);
        while (true) {
            const t = p.popToken(false);
            const tt = t.tt;
            const data = t.data;
            if (((tt == .semicolon or tt == .right_brace) and p.level == 0) or tt == .err) {
                var i: usize = 1;
                while (i < p.buf.items.len and p.buf.items[i].tt == .whitespace) i += 1;
                if (p.buf.items.len == i or p.buf.items[i].tt != .colon) {
                    p.has_err = true;
                    return p.parseDeclarationError(tt, data);
                }
                var vals = p.buf.items[i + 1 ..];
                while (vals.len > 0 and vals[0].tt == .whitespace) vals = vals[1..];
                var out: std.ArrayList(PTok) = .empty;
                var k: usize = 0;
                while (k < vals.len) {
                    if (vals[k].tt == .whitespace) {
                        if (out.items.len > 0 and isSep1(out.items[out.items.len - 1].data)) {
                            k += 1;
                            continue;
                        }
                        if (k + 1 < vals.len) {
                            if (isSep1(vals[k + 1].data)) {
                                k += 1;
                                continue;
                            }
                            out.append(sys.A, vals[k]) catch {};
                            k += 1;
                        }
                        // the Go code then also copies the following token without re-checking it
                        if (k < vals.len) {
                            out.append(sys.A, vals[k]) catch {};
                            k += 1;
                        } else k += 1;
                        continue;
                    }
                    out.append(sys.A, vals[k]) catch {};
                    k += 1;
                }
                p.buf = out;
                p.data = min.toLower(p.data);
                p.prev_end = tt == .right_brace;
                return .declaration;
            } else if (tt == .left_brace and p.level == 0 and p.is_stylesheet) {
                p.tt = .whitespace;
                p.data = "";
                p.state.append(sys.A, .qualified_rule_declaration_list) catch {};
                return .begin_ruleset;
            } else if (tt == .left_paren or tt == .left_brace or tt == .left_bracket or tt == .function) {
                p.level += 1;
            } else if (tt == .right_paren or tt == .right_brace or tt == .right_bracket) {
                if (p.level == 0) {
                    p.has_err = true;
                    return p.parseDeclarationError(tt, data);
                }
                p.level -= 1;
            }
            if ((p.prev_ws or p.prev_comment) and p.buf.items[p.buf.items.len - 1].tt != .whitespace) p.push(.whitespace, " ");
            p.push(tt, data);
        }
    }

    fn parseDeclarationError(p: *Parser, tt0: TT, data0: []const u8) GT {
        var tt = tt0;
        var data = data0;
        p.tt = tt;
        p.data = data;
        while (true) {
            if (((tt == .semicolon or tt == .right_brace) and p.level == 0) or tt == .err) {
                p.prev_end = tt == .right_brace;
                if (tt == .semicolon) p.push(tt, data);
                return .err;
            } else if (tt == .left_paren or tt == .left_brace or tt == .left_bracket or tt == .function) {
                p.level += 1;
            } else if (tt == .right_paren or tt == .right_brace or tt == .right_bracket) p.level -= 1;
            if (p.prev_ws) p.push(.whitespace, " ");
            p.push(tt, data);
            const t = p.popToken(false);
            tt = t.tt;
            data = t.data;
        }
    }

    fn parseCustomProperty(p: *Parser) GT {
        p.buf.clearRetainingCapacity();
        const t0 = p.popToken(false);
        if (t0.tt != .colon) {
            p.has_err = true;
            return .err;
        }
        var val: std.ArrayList(u8) = .empty;
        while (true) {
            const t = p.l.next();
            const tt = t.tt;
            if (((tt == .semicolon or tt == .right_brace) and p.level == 0) or tt == .err) {
                p.prev_end = tt == .right_brace;
                p.push(.custom_property_value, val.items);
                return .custom_property;
            } else if (tt == .left_paren or tt == .left_brace or tt == .left_bracket or tt == .function) {
                p.level += 1;
            } else if (tt == .right_paren or tt == .right_brace or tt == .right_bracket) {
                if (p.level == 0) {
                    p.push(tt, t.data);
                    p.has_err = true;
                    return .err;
                }
                p.level -= 1;
            }
            val.appendSlice(sys.A, t.data) catch {};
        }
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const known_names = @import("min_css_names.zig").names;

/// The perfect-hash lookup of the Go code: a lower-cased name if it is one of
/// the known identifiers, "" (hash 0) otherwise.
fn hashName(lower: []const u8) []const u8 {
    var lo: usize = 0;
    var hi: usize = known_names.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, known_names[mid], lower)) {
            .eq => return lower,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return "";
}

// ================================================================ minifier

const Token = struct {
    tt: TT,
    data: []const u8,
    args: []Token = &.{},
    fun: []const u8 = "", // lower-cased function name (without '(')
    ident: []const u8 = "", // lower-cased identifier

    fn equal(t: Token, o: Token) bool {
        if (t.tt == o.tt and eq(t.data, o.data) and t.args.len == o.args.len) {
            for (t.args, o.args) |a, b| if (!a.equal(b)) return false;
            return true;
        }
        return false;
    }
    fn isZero(t: Token) bool {
        return (t.tt == .dimension or t.tt == .percentage or t.tt == .number) and t.data[0] == '0';
    }
    fn isLength(t: Token) bool {
        if (t.tt == .dimension) return true;
        if (t.tt == .number and t.data[0] == '0') return true;
        if (t.tt == .function) {
            const f = t.data[0 .. t.data.len - 1];
            for ([_][]const u8{ "calc", "min", "max", "clamp", "attr", "var", "env" }) |n| if (eq(f, n)) return true;
        }
        return false;
    }
    fn isLengthPercentage(t: Token) bool {
        return t.tt == .percentage or t.isLength();
    }
    fn id(t: Token, n: []const u8) bool {
        return eq(t.ident, n);
    }
};

const optional_zero_dims = [_][]const u8{ "px", "mm", "q", "cm", "in", "pt", "pc", "ch", "em", "ex", "rem", "vh", "vw", "vmin", "vmax", "deg", "grad", "rad", "turn" };

const shorten_hex = [_][2][]const u8{
    .{ "#000080", "navy" },   .{ "#008000", "green" },  .{ "#008080", "teal" },   .{ "#4b0082", "indigo" }, .{ "#800000", "maroon" },
    .{ "#800080", "purple" }, .{ "#808000", "olive" },  .{ "#808080", "gray" },   .{ "#a0522d", "sienna" }, .{ "#a52a2a", "brown" },
    .{ "#c0c0c0", "silver" }, .{ "#cd853f", "peru" },   .{ "#d2b48c", "tan" },    .{ "#da70d6", "orchid" }, .{ "#dda0dd", "plum" },
    .{ "#ee82ee", "violet" }, .{ "#f0e68c", "khaki" },  .{ "#f0ffff", "azure" },  .{ "#f5deb3", "wheat" },  .{ "#f5f5dc", "beige" },
    .{ "#fa8072", "salmon" }, .{ "#faf0e6", "linen" },  .{ "#ff6347", "tomato" }, .{ "#ff7f50", "coral" },  .{ "#ffa500", "orange" },
    .{ "#ffc0cb", "pink" },   .{ "#ffd700", "gold" },   .{ "#ffe4c4", "bisque" }, .{ "#fffafa", "snow" },   .{ "#fffff0", "ivory" },
    .{ "#ff0000", "red" },    .{ "#f00", "red" },
};

const shorten_name = [_][2][]const u8{
    .{ "black", "#000" },                 .{ "darkblue", "#00008b" },        .{ "mediumblue", "#0000cd" },   .{ "darkgreen", "#006400" },
    .{ "darkcyan", "#008b8b" },           .{ "deepskyblue", "#00bfff" },     .{ "darkturquoise", "#00ced1" }, .{ "mediumspringgreen", "#00fa9a" },
    .{ "springgreen", "#00ff7f" },        .{ "midnightblue", "#191970" },    .{ "dodgerblue", "#1e90ff" },   .{ "lightseagreen", "#20b2aa" },
    .{ "forestgreen", "#228b22" },        .{ "seagreen", "#2e8b57" },        .{ "darkslategray", "#2f4f4f" }, .{ "limegreen", "#32cd32" },
    .{ "mediumseagreen", "#3cb371" },     .{ "turquoise", "#40e0d0" },       .{ "royalblue", "#4169e1" },    .{ "steelblue", "#4682b4" },
    .{ "darkslateblue", "#483d8b" },      .{ "mediumturquoise", "#48d1cc" }, .{ "darkolivegreen", "#556b2f" }, .{ "cadetblue", "#5f9ea0" },
    .{ "cornflowerblue", "#6495ed" },     .{ "mediumaquamarine", "#66cdaa" }, .{ "slateblue", "#6a5acd" },   .{ "olivedrab", "#6b8e23" },
    .{ "slategray", "#708090" },          .{ "lightslateblue", "#789" },     .{ "mediumslateblue", "#7b68ee" }, .{ "lawngreen", "#7cfc00" },
    .{ "chartreuse", "#7fff00" },         .{ "aquamarine", "#7fffd4" },      .{ "lightskyblue", "#87cefa" }, .{ "blueviolet", "#8a2be2" },
    .{ "darkmagenta", "#8b008b" },        .{ "saddlebrown", "#8b4513" },     .{ "darkseagreen", "#8fbc8f" }, .{ "lightgreen", "#90ee90" },
    .{ "mediumpurple", "#9370db" },       .{ "darkviolet", "#9400d3" },      .{ "palegreen", "#98fb98" },    .{ "darkorchid", "#9932cc" },
    .{ "yellowgreen", "#9acd32" },        .{ "darkgray", "#a9a9a9" },        .{ "lightblue", "#add8e6" },    .{ "greenyellow", "#adff2f" },
    .{ "paleturquoise", "#afeeee" },      .{ "lightsteelblue", "#b0c4de" },  .{ "powderblue", "#b0e0e6" },   .{ "firebrick", "#b22222" },
    .{ "darkgoldenrod", "#b8860b" },      .{ "mediumorchid", "#ba55d3" },    .{ "rosybrown", "#bc8f8f" },    .{ "darkkhaki", "#bdb76b" },
    .{ "mediumvioletred", "#c71585" },    .{ "indianred", "#cd5c5c" },       .{ "chocolate", "#d2691e" },    .{ "lightgray", "#d3d3d3" },
    .{ "goldenrod", "#daa520" },          .{ "palevioletred", "#db7093" },   .{ "gainsboro", "#dcdcdc" },    .{ "burlywood", "#deb887" },
    .{ "lightcyan", "#e0ffff" },          .{ "lavender", "#e6e6fa" },        .{ "darksalmon", "#e9967a" },   .{ "palegoldenrod", "#eee8aa" },
    .{ "lightcoral", "#f08080" },         .{ "aliceblue", "#f0f8ff" },       .{ "honeydew", "#f0fff0" },     .{ "sandybrown", "#f4a460" },
    .{ "whitesmoke", "#f5f5f5" },         .{ "mintcream", "#f5fffa" },       .{ "ghostwhite", "#f8f8ff" },   .{ "antiquewhite", "#faebd7" },
    .{ "lightgoldenrodyellow", "#fafad2" }, .{ "fuchsia", "#f0f" },          .{ "magenta", "#f0f" },         .{ "deeppink", "#ff1493" },
    .{ "orangered", "#ff4500" },          .{ "darkorange", "#ff8c00" },      .{ "lightsalmon", "#ffa07a" },  .{ "lightpink", "#ffb6c1" },
    .{ "peachpuff", "#ffdab9" },          .{ "navajowhite", "#ffdead" },     .{ "moccasin", "#ffe4b5" },     .{ "mistyrose", "#ffe4e1" },
    .{ "blanchedalmond", "#ffebcd" },     .{ "papayawhip", "#ffefd5" },      .{ "lavenderblush", "#fff0f5" }, .{ "seashell", "#fff5ee" },
    .{ "cornsilk", "#fff8dc" },           .{ "lemonchiffon", "#fffacd" },    .{ "floralwhite", "#fffaf0" },  .{ "yellow", "#ff0" },
    .{ "lightyellow", "#ffffe0" },        .{ "white", "#fff" },
};

fn lookup(table: []const [2][]const u8, k: []const u8) ?[]const u8 {
    for (table) |e| if (eq(e[0], k)) return e[1];
    return null;
}

const M = struct {
    out: std.ArrayList(u8) = .empty,
    p: Parser,
    level: usize = 0,
    version: i64 = 3,
    precision: i64 = 0,

    fn w(m: *M, s: []const u8) void {
        m.out.appendSlice(sys.A, s) catch {};
    }

    fn grammar(m: *M) !void {
        var semicolon_queued = false;
        var r = m.p.next();
        while (true) {
            var gt = r.gt;
            var data = r.data;
            dispatch: while (true) {
                switch (gt) {
                    .err => {
                        if (m.p.has_err) {
                            if (semicolon_queued) m.w(";");
                            var vals = m.p.values();
                            if (vals.len > 0 and vals[vals.len - 1].tt == .semicolon) {
                                vals = vals[0 .. vals.len - 1];
                                semicolon_queued = true;
                            }
                            for (vals) |v| m.w(v.data);
                            break :dispatch;
                        }
                        return;
                    },
                    .end_at_rule, .end_ruleset => {
                        m.w("}");
                        semicolon_queued = false;
                        break :dispatch;
                    },
                    else => {},
                }
                if (semicolon_queued) {
                    m.w(";");
                    semicolon_queued = false;
                }
                switch (gt) {
                    .at_rule => {
                        m.w(data);
                        const vals = m.p.values();
                        if (eq(min.toLower(data[1..]), "import") and vals.len == 2 and vals[1].tt == .url and 4 < vals[1].data.len and vals[1].data[vals[1].data.len - 1] == ')') {
                            const url = vals[1].data;
                            var nu: []const u8 = undefined;
                            if (url[4] != '"' and url[4] != '\'') {
                                var a: usize = 4;
                                while (min.isWhitespace(url[a]) or min.isNewline(url[a])) a += 1;
                                var b: usize = url.len - 2;
                                while (a < b and (min.isWhitespace(url[b]) or min.isNewline(url[b]))) b -= 1;
                                if (a == b) {
                                    nu = "\"\"";
                                } else nu = std.mem.concat(sys.A, u8, &.{ "\"", url[a .. b + 1], "\"" }) catch url;
                            } else nu = url[4 .. url.len - 1];
                            vals[1].data = nu;
                        }
                        for (vals) |v| m.w(v.data);
                        m.w(";");
                        semicolon_queued = false;
                    },
                    .begin_at_rule => {
                        const rule = data;
                        const vals = sys.A.dupe(PTok, m.p.values()) catch &.{};
                        r = m.p.next();
                        gt = r.gt;
                        data = r.data;
                        if (gt == .end_at_rule) {
                            r = m.p.next();
                            gt = r.gt;
                            data = r.data;
                        } else {
                            m.w(rule);
                            for (vals) |v| m.w(v.data);
                            m.w("{");
                        }
                        continue :dispatch;
                    },
                    .begin_ruleset => {
                        const sels = sys.A.dupe(PTok, m.p.values()) catch &.{};
                        r = m.p.next();
                        gt = r.gt;
                        data = r.data;
                        if (gt == .end_ruleset) {
                            r = m.p.next();
                            gt = r.gt;
                            data = r.data;
                        } else {
                            m.selectors(sels);
                            m.w("{");
                        }
                        continue :dispatch;
                    },
                    .declaration => {
                        m.declaration(data, m.p.values());
                        semicolon_queued = true;
                    },
                    .custom_property => {
                        m.w(data);
                        m.w(":");
                        const raw = m.p.values()[0].data;
                        var value = min.trimWhitespace(raw);
                        if (raw.len != 0 and value.len == 0) value = " ";
                        m.w(value);
                        semicolon_queued = true;
                    },
                    .comment => {
                        if (5 < data.len and data[1] == '*' and data[2] == '!') {
                            m.w(data[0..3]);
                            m.w(min.trimWhitespace(min.replaceMultipleWhitespace(data[3 .. data.len - 2])));
                            m.w(data[data.len - 2 ..]);
                        }
                    },
                    else => m.w(data),
                }
                break :dispatch;
            }
            r = m.p.next();
        }
    }

    fn selectors(m: *M, vals: []const PTok) void {
        var in_attr = false;
        var is_class = false;
        for (vals) |v| {
            var data = v.data;
            if (!in_attr) {
                if (v.tt == .ident) {
                    if (!is_class) data = min.toLower(data);
                    is_class = false;
                } else if (v.tt == .delim and data[0] == '.') {
                    is_class = true;
                } else if (v.tt == .left_bracket) in_attr = true;
            } else {
                if (v.tt == .string and data.len > 2) {
                    const s = data[1 .. data.len - 1];
                    if (isIdent(s)) {
                        m.w(s);
                        continue;
                    }
                } else if (v.tt == .right_bracket) {
                    in_attr = false;
                } else if (v.tt == .ident and data.len == 1 and (data[0] == 'i' or data[0] == 'I')) m.w(" ");
            }
            m.w(data);
        }
    }

    fn parseFunction(m: *M, vals: []const PTok, level: usize) error{TooDeep}!struct { args: []Token, n: usize } {
        if (1000 < level) return error.TooDeep;
        var i: usize = 1;
        var plevel: usize = 0;
        var args: std.ArrayList(Token) = .empty;
        while (i < vals.len) : (i += 1) {
            const tt = vals[i].tt;
            const data = vals[i].data;
            if (tt == .left_paren) {
                plevel += 1;
            } else if (tt == .right_paren) {
                if (plevel == 0) {
                    i += 1;
                    break;
                }
                plevel -= 1;
            }
            if (tt == .function) {
                const sub = try m.parseFunction(vals[i..], level + 1);
                args.append(sys.A, .{ .tt = tt, .data = data, .args = sub.args, .fun = hashName(min.toLower(data[0 .. data.len - 1])) }) catch {};
                i += sub.n - 1;
            } else {
                args.append(sys.A, .{ .tt = tt, .data = data, .ident = if (tt == .ident) hashName(min.toLower(data)) else "" }) catch {};
            }
        }
        return .{ .args = args.items, .n = i };
    }

    fn parseDecl(m: *M, vals: []const PTok) ?std.ArrayList(Token) {
        var prev_sep = true;
        var toks: std.ArrayList(Token) = .empty;
        var i: usize = 0;
        while (i < vals.len) : (i += 1) {
            const tt = vals[i].tt;
            const data = vals[i].data;
            if (tt == .left_paren or tt == .left_brace or tt == .left_bracket or tt == .right_paren or tt == .right_brace or tt == .right_bracket) return null;
            if (!prev_sep and tt != .whitespace and tt != .comma and (tt != .delim or data[0] != '/')) return null;
            if (tt == .whitespace or tt == .comma or (tt == .delim and data[0] == '/')) {
                if (tt != .whitespace) toks.append(sys.A, .{ .tt = tt, .data = data }) catch {};
                prev_sep = true;
            } else if (tt == .function) {
                const r = m.parseFunction(vals[i..], 0) catch return null;
                toks.append(sys.A, .{ .tt = tt, .data = data, .args = r.args, .fun = hashName(min.toLower(data[0 .. data.len - 1])) }) catch {};
                prev_sep = true;
                i += r.n - 1;
            } else {
                toks.append(sys.A, .{ .tt = tt, .data = data, .ident = if (tt == .ident) hashName(min.toLower(data)) else "" }) catch {};
                prev_sep = tt == .url;
            }
        }
        return toks;
    }

    fn declaration(m: *M, prop_name: []const u8, comps0: []const PTok) void {
        m.w(prop_name);
        m.w(":");
        var comps = comps0;
        if (comps.len == 0) return;
        var important = false;
        if (2 < comps.len and comps[comps.len - 2].tt == .delim and comps[comps.len - 2].data[0] == '!' and eq(comps[comps.len - 1].data, "important")) {
            comps = comps[0 .. comps.len - 2];
            important = true;
        }
        const prop = hashName(prop_name);
        var vals = m.parseDecl(comps) orelse {
            var cs = comps;
            if (eq(prop, "filter") and cs.len == 11) {
                if (eq(cs[0].data, "progid") and cs[1].tt == .colon and eq(cs[2].data, "DXImageTransform") and cs[3].data[0] == '.' and eq(cs[4].data, "Microsoft") and cs[5].data[0] == '.' and eq(cs[6].data, "Alpha(") and eq(min.toLower(cs[7].data), "opacity") and cs[8].data[0] == '=' and cs[10].data[0] == ')') {
                    const copy = sys.A.dupe(PTok, cs[6..]) catch return;
                    copy[0].data = "alpha(";
                    copy[1].data = min.toLower(copy[1].data);
                    cs = copy;
                }
            }
            for (cs) |c| m.w(c.data);
            if (important) {
                if (m.version <= 2) m.w(" ");
                m.w("!important");
            }
            return;
        };
        m.tokens(prop, "", vals.items);
        if (vals.items.len > 0) m.property(prop, &vals);
        m.writeDecl(vals.items, important);
    }

    fn writeFunction(m: *M, args: []const Token) void {
        for (args) |a| {
            m.w(a.data);
            if (a.tt == .function) {
                m.writeFunction(a.args);
                m.w(")");
            }
        }
    }

    fn writeDecl(m: *M, vals: []const Token, important: bool) void {
        var prev_sep = true;
        for (vals) |v| {
            if (!prev_sep and v.tt != .comma and (v.tt != .delim or v.data[0] != '/')) m.w(" ");
            m.w(v.data);
            if (v.tt == .function) {
                m.writeFunction(v.args);
                m.w(")");
            }
            prev_sep = v.tt == .comma or (v.tt == .delim and v.data[0] == '/') or v.tt == .function or v.tt == .url;
        }
        if (important) {
            if (m.version <= 2) m.w(" ");
            m.w("!important");
        }
    }

    fn num(m: *M, s: []const u8) []const u8 {
        return if (m.version <= 2) min.decimal(s, m.precision) else min.number(s, m.precision);
    }

    fn tokens(m: *M, prop: []const u8, fun: []const u8, vals: []Token) void {
        if (100 < m.level + 1) return;
        m.level += 1;
        defer m.level -= 1;
        for (vals) |*v| {
            switch (v.tt) {
                .number => {
                    if (eq(prop, "z-index") or eq(prop, "counter-increment") or eq(prop, "counter-reset") or eq(prop, "orphans") or eq(prop, "widows")) continue;
                    v.data = m.num(v.data);
                },
                .percentage => {
                    v.data = std.mem.concat(sys.A, u8, &.{ m.num(v.data[0 .. v.data.len - 1]), "%" }) catch v.data;
                },
                .dimension => {
                    const r = m.dimension(v.*);
                    v.* = r.tok;
                    var opt = false;
                    for (optional_zero_dims) |d| if (eq(d, r.dim)) {
                        opt = true;
                    };
                    if (1 < v.data.len and v.data[0] == '0' and opt and !eq(prop, "flex") and fun.len == 0) v.data = v.data[0..1];
                },
                .string => v.data = removeMarkupNewlines(v.data),
                .url => {
                    if (10 < v.data.len) {
                        var uri = min.trimWhitespace(v.data[4 .. v.data.len - 1]);
                        var delim: u8 = '"';
                        if (1 < uri.len and (uri[0] == '\'' or uri[0] == '"')) {
                            delim = uri[0];
                            uri = removeMarkupNewlines(uri);
                            uri = uri[1 .. uri.len - 1];
                        }
                        if (4 < uri.len and min.eqlFold(uri[0..5], "data:")) uri = min.dataUri(uri);
                        if (isUrlUnquoted(uri)) {
                            v.data = std.mem.concat(sys.A, u8, &.{ "url(", uri, ")" }) catch v.data;
                        } else v.data = std.mem.concat(sys.A, u8, &.{ "url(", &.{delim}, uri, &.{delim}, ")" }) catch v.data;
                    }
                },
                .function => {
                    m.tokens(prop, v.fun, v.args);
                    colorFunction(v);
                },
                else => {},
            }
        }
    }

    fn dimension(m: *M, t: Token) struct { tok: Token, dim: []const u8 } {
        var tok = t;
        const data = sys.A.dupe(u8, t.data) catch return .{ .tok = t, .dim = "" };
        var n = data.len;
        while (0 < n) {
            const c = data[n - 1];
            const lower = c >= 'a' and c <= 'z';
            const upper = c >= 'A' and c <= 'Z';
            if (!lower and !upper) break;
            if (upper) data[n - 1] = c + ('a' - 'A');
            n -= 1;
        }
        const dim = data[n..];
        tok.data = std.mem.concat(sys.A, u8, &.{ m.num(data[0..n]), dim }) catch t.data;
        return .{ .tok = tok, .dim = dim };
    }

    fn property(m: *M, prop: []const u8, list: *std.ArrayList(Token)) void {
        const r = m.propertyVals(prop, list.items);
        list.* = .empty;
        list.appendSlice(sys.A, r) catch {};
    }

    /// minifyProperty; returns the (possibly shortened) value list.
    fn propertyVals(m: *M, prop: []const u8, vals_in: []Token) []Token {
        var values: std.ArrayList(Token) = .empty;
        values.appendSlice(sys.A, vals_in) catch {};
        if (100 < values.items.len) return values.items;
        const V = &values;
        if (eq(prop, "font")) {
            if (V.items.len > 1) {
                var i: isize = @as(isize, @intCast(V.items.len)) - 1;
                for (V.items[2..], 0..) |val, j| if (val.tt == .comma) {
                    i = 2 + @as(isize, @intCast(j)) - 1;
                    break;
                };
                i -= 1;
                while (i > 0) : (i -= 1) {
                    const iu: usize = @intCast(i);
                    if (V.items[iu - 1].tt == .delim and V.items[iu - 1].data[0] == '/') break;
                    if (V.items[iu].tt != .ident and V.items[iu].tt != .string) break;
                    const h = V.items[iu].ident;
                    var size_kw = false;
                    for ([_][]const u8{ "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "smaller", "larger", "inherit", "initial", "unset" }) |k| if (eq(h, k)) {
                        size_kw = true;
                    };
                    if (size_kw) break;
                }
                var iu: usize = @intCast(i);
                const fam = m.propertyVals("font-family", V.items[iu + 1 ..]);
                V.items.len = iu + 1;
                V.appendSlice(sys.A, fam) catch {};
                if (V.items[iu + 1].data[0] == '-') V.items[iu + 1].data = std.mem.concat(sys.A, u8, &.{ "'", V.items[iu + 1].data, "'" }) catch V.items[iu + 1].data;
                if (iu > 0) {
                    var ii: isize = @intCast(iu);
                    if (ii > 1 and V.items[iu - 1].tt == .delim and V.items[iu - 1].data[0] == '/') {
                        if (V.items[iu].id("normal")) removeRange(V, iu - 1, iu + 1);
                        ii -= 2;
                    }
                    ii -= 1;
                    while (ii > -1) : (ii -= 1) {
                        const k: usize = @intCast(ii);
                        if (V.items[k].id("normal")) {
                            removeRange(V, k, k + 1);
                        } else if (V.items[k].id("bold")) {
                            V.items[k].tt = .number;
                            V.items[k].data = "700";
                        } else if (V.items[k].tt == .number and eq(V.items[k].data, "400")) {
                            removeRange(V, k, k + 1);
                        }
                    }
                    iu = 0;
                }
            }
        } else if (eq(prop, "font-family")) {
            for (V.items) |*val| {
                if (val.tt == .string and 2 < val.data.len) {
                    var unquote = true;
                    val.data = min.toLower(val.data);
                    const s = val.data[1 .. val.data.len - 1];
                    if (s.len > 0) {
                        var it = std.mem.splitScalar(u8, s, ' ');
                        while (it.next()) |split| if (split.len == 0 or !isIdent(split)) {
                            unquote = false;
                            break;
                        };
                    }
                    if (unquote) val.data = s;
                }
            }
        } else if (eq(prop, "font-weight")) {
            if (V.items[0].id("normal")) {
                V.items[0].tt = .number;
                V.items[0].data = "400";
            } else if (V.items[0].id("bold")) {
                V.items[0].tt = .number;
                V.items[0].data = "700";
            }
        } else if (eq(prop, "url")) {
            for (V.items) |*val| {
                if (val.tt == .function and val.args.len == 1) {
                    var data = val.args[0].data;
                    if (eq(val.fun, "local") and (data[0] == '\'' or data[0] == '"')) {
                        if (isUrlUnquoted(data[1 .. data.len - 1])) data = data[1 .. data.len - 1];
                        val.args[0].data = data;
                    }
                }
            }
        } else if (eq(prop, "margin") or eq(prop, "padding") or eq(prop, "border-width")) {
            const it = V.items;
            switch (it.len) {
                2 => if (it[0].equal(it[1])) {
                    V.items.len = 1;
                },
                3 => if (it[0].equal(it[1]) and it[0].equal(it[2])) {
                    V.items.len = 1;
                } else if (it[0].equal(it[2])) {
                    V.items.len = 2;
                },
                4 => if (it[0].equal(it[1]) and it[0].equal(it[2]) and it[0].equal(it[3])) {
                    V.items.len = 1;
                } else if (it[0].equal(it[2]) and it[1].equal(it[3])) {
                    V.items.len = 2;
                } else if (it[1].equal(it[3])) {
                    V.items.len = 3;
                },
                else => {},
            }
        } else if (eq(prop, "border") or eq(prop, "border-bottom") or eq(prop, "border-left") or eq(prop, "border-right") or eq(prop, "border-top")) {
            removeIdentsAndColor(V, &.{ "none", "currentcolor", "medium" });
        } else if (eq(prop, "outline")) {
            removeIdentsAndColor(V, &.{ "invert", "none", "medium" });
        } else if (eq(prop, "background")) {
            m.background(V);
        } else if (eq(prop, "background-size")) {
            var start: usize = 0;
            var end: usize = 0;
            while (end <= V.items.len) : (end += 1) {
                if (end != V.items.len and V.items[end].tt != .comma) continue;
                if (start == end) {
                    start += 1;
                    continue;
                }
                if (end - start == 2 and V.items[start + 1].id("auto")) {
                    removeRange(V, start + 1, start + 2);
                    end -= 1;
                }
                start = end + 1;
            }
        } else if (eq(prop, "background-repeat")) {
            var start: usize = 0;
            var end: usize = 0;
            while (end <= V.items.len) : (end += 1) {
                if (end != V.items.len and V.items[end].tt != .comma) continue;
                if (start == end) {
                    start += 1;
                    continue;
                }
                if (end - start == 2 and V.items[start].tt == .ident and V.items[start + 1].tt == .ident) {
                    if (eq(V.items[start].ident, V.items[start + 1].ident)) {
                        removeRange(V, start + 1, start + 2);
                        end -= 1;
                    } else if (V.items[start].id("repeat") and V.items[start + 1].id("no-repeat")) {
                        V.items[start].data = "repeat-x";
                        V.items[start].ident = "repeat-x";
                        removeRange(V, start + 1, start + 2);
                        end -= 1;
                    } else if (V.items[start].id("no-repeat") and V.items[start + 1].id("repeat")) {
                        V.items[start].data = "repeat-y";
                        V.items[start].ident = "repeat-y";
                        removeRange(V, start + 1, start + 2);
                        end -= 1;
                    }
                }
                start = end + 1;
            }
        } else if (eq(prop, "background-position")) {
            m.backgroundPosition(V);
        } else if (eq(prop, "box-shadow")) {
            var start: usize = 0;
            var end: usize = 0;
            while (end <= V.items.len) : (end += 1) {
                if (end != V.items.len and V.items[end].tt != .comma) continue;
                if (start == end) {
                    start += 1;
                    continue;
                }
                if (end - start == 1 and V.items[start].id("initial")) {
                    V.items[start].ident = "none";
                    V.items[start].data = "none";
                } else {
                    var numbers: std.ArrayList(usize) = .empty;
                    for (start..end) |k| if (V.items[k].isLength()) numbers.append(sys.A, k) catch {};
                    if (numbers.items.len == 4 and V.items[numbers.items[3]].isZero()) {
                        removeRange(V, numbers.items[3], numbers.items[3] + 1);
                        numbers.items.len = 3;
                        end -= 1;
                    }
                    if (numbers.items.len == 3 and V.items[numbers.items[2]].isZero()) {
                        removeRange(V, numbers.items[2], numbers.items[2] + 1);
                        end -= 1;
                    }
                }
                start = end + 1;
            }
        } else if (eq(prop, "-ms-filter")) {
            const alpha = "progid:DXImageTransform.Microsoft.Alpha(Opacity=";
            const d = V.items[0].data;
            if (V.items[0].tt == .string and 2 < d.len and std.mem.startsWith(u8, d[1 .. d.len - 1], alpha)) {
                V.items[0].data = std.mem.concat(sys.A, u8, &.{ d[0..1], "alpha(opacity=", d[1 + alpha.len ..] }) catch d;
            }
        } else if (eq(prop, "color") or eq(prop, "background-color") or eq(prop, "caret-color") or eq(prop, "outline-color") or eq(prop, "fill") or eq(prop, "stroke")) {
            V.items[0] = minifyColor(V.items[0]);
        } else if (eq(prop, "border-color")) {
            var same = true;
            for (V.items, 0..) |*val, k| {
                if (val.id("currentcolor")) {
                    val.data = "initial";
                    val.ident = "initial";
                } else val.* = minifyColor(val.*);
                if (0 < k and same and !V.items[0].equal(val.*)) same = false;
            }
            if (same) V.items.len = 1;
        } else if (eq(prop, "border-left-color") or eq(prop, "border-right-color") or eq(prop, "border-top-color") or eq(prop, "border-bottom-color") or eq(prop, "text-decoration-color") or eq(prop, "text-emphasis-color")) {
            if (V.items[0].id("currentcolor")) {
                V.items[0].data = "initial";
                V.items[0].ident = "initial";
            } else V.items[0] = minifyColor(V.items[0]);
        } else if (eq(prop, "column-rule")) {
            removeIdentsAndColor(V, &.{ "currentcolor", "none", "medium" });
        } else if (eq(prop, "text-shadow")) {
            for (V.items) |*val| val.* = minifyColor(val.*);
        } else if (eq(prop, "text-decoration")) {
            removeIdentsAndColor(V, &.{ "currentcolor", "none", "solid" });
        } else if (eq(prop, "text-emphasis")) {
            removeIdentsAndColor(V, &.{ "currentcolor", "none" });
        } else if (eq(prop, "flex")) {
            const it = V.items;
            if (it.len == 2 and it[0].tt == .number) {
                if (it[1].tt != .number and it[1].isZero()) V.items.len = 1;
            } else if (it.len == 3 and it[0].tt == .number and it[1].tt == .number) {
                if (it[0].data.len == 1 and it[1].data.len == 1) {
                    if (it[2].id("auto")) {
                        if (it[0].data[0] == '0' and it[1].data[0] == '1') {
                            V.items.len = 1;
                            V.items[0] = .{ .tt = .ident, .data = "initial", .ident = "initial" };
                        } else if (it[0].data[0] == '1' and it[1].data[0] == '1') {
                            V.items.len = 1;
                            V.items[0] = .{ .tt = .ident, .data = "auto", .ident = "auto" };
                        } else if (it[0].data[0] == '0' and it[1].data[0] == '0') {
                            V.items.len = 1;
                            V.items[0] = .{ .tt = .ident, .data = "none", .ident = "none" };
                        }
                    } else if (it[1].data[0] == '1' and it[2].isZero()) {
                        V.items.len = 1;
                    } else if (it[2].isZero()) {
                        V.items.len = 2;
                    } else V.items[2] = minifyLengthPercentage(V.items[2]);
                }
            }
        } else if (eq(prop, "flex-basis")) {
            if (V.items[0].id("initial")) {
                V.items[0].data = "auto";
                V.items[0].ident = "auto";
            } else V.items[0] = minifyLengthPercentage(V.items[0]);
        } else if (eq(prop, "order") or eq(prop, "flex-grow")) {
            if (V.items[0].id("initial")) V.items[0] = .{ .tt = .number, .data = "0" };
        } else if (eq(prop, "flex-shrink")) {
            if (V.items[0].id("initial")) V.items[0] = .{ .tt = .number, .data = "1" };
        } else if (eq(prop, "unicode-range")) {
            if (unicodeRange(V.items)) |r| return r;
        }
        return V.items;
    }

    fn background(m: *M, V: *std.ArrayList(Token)) void {
        var start: usize = 0;
        var end: usize = 0;
        while (end <= V.items.len) : (end += 1) {
            if (end != V.items.len and V.items[end].tt != .comma) continue;
            if (start == end) {
                start += 1;
                continue;
            }
            var i: isize = @intCast(start);
            while (i < @as(isize, @intCast(end))) : (i += 1) {
                const iu: usize = @intCast(i);
                if (V.items[iu].tt == .delim and V.items[iu].data[0] == '/') {
                    if (iu + 1 < end and (V.items[iu + 1].tt == .number or V.items[iu + 1].isLengthPercentage() or V.items[iu + 1].id("auto"))) {
                        if (iu + 2 < end and (V.items[iu + 2].tt == .number or V.items[iu + 2].isLengthPercentage() or V.items[iu + 2].id("auto"))) {
                            const sv = m.propertyVals("background-size", sys.A.dupe(Token, V.items[iu + 1 .. iu + 3]) catch &.{});
                            if (sv.len == 1 and sv[0].id("auto")) {
                                removeRange(V, iu, iu + 3);
                                end -= 3;
                                i -= 1;
                            } else {
                                replaceRange(V, iu + 1, iu + 3, sv);
                                end -= 2 - sv.len;
                                i += @as(isize, @intCast(sv.len)) - 1;
                            }
                        } else if (V.items[iu + 1].id("auto")) {
                            removeRange(V, iu, iu + 2);
                            end -= 2;
                            i -= 1;
                        }
                    }
                }
            }
            var ipad: isize = -1;
            i = @intCast(start);
            while (i < @as(isize, @intCast(end))) : (i += 1) {
                const iu: usize = @intCast(i);
                const h = V.items[iu].ident;
                V.items[iu] = minifyColor(V.items[iu]);
                if (V.items[iu].tt == .ident) {
                    if (iu + 1 < end and V.items[iu + 1].tt == .ident and (eq(h, "space") or eq(h, "round") or eq(h, "repeat") or eq(h, "no-repeat"))) {
                        const h2 = V.items[iu + 1].ident;
                        if (eq(h2, "space") or eq(h2, "round") or eq(h2, "repeat") or eq(h2, "no-repeat")) {
                            const rv = m.propertyVals("background-repeat", sys.A.dupe(Token, V.items[iu .. iu + 2]) catch &.{});
                            if (rv.len == 1 and rv[0].id("repeat")) {
                                removeRange(V, iu, iu + 2);
                                end -= 2;
                                i -= 1;
                            } else {
                                replaceRange(V, iu, iu + 2, rv);
                                end -= 2 - rv.len;
                                i += @as(isize, @intCast(rv.len)) - 1;
                            }
                            continue;
                        }
                    } else if (eq(h, "none") or eq(h, "scroll") or eq(h, "transparent")) {
                        removeRange(V, iu, iu + 1);
                        end -= 1;
                        i -= 1;
                        continue;
                    } else if (eq(h, "border-box") or eq(h, "padding-box")) {
                        if (ipad == -1 and eq(h, "padding-box")) {
                            ipad = i;
                        } else if (ipad != -1 and eq(h, "border-box")) {
                            removeRange(V, iu, iu + 1);
                            removeRange(V, @intCast(ipad), @as(usize, @intCast(ipad)) + 1);
                            end -= 2;
                            i -= 2;
                        }
                        continue;
                    }
                } else if (V.items[iu].tt == .hash and eq(V.items[iu].data, "#0000")) {
                    removeRange(V, iu, iu + 1);
                    end -= 1;
                    i -= 1;
                    continue;
                } else if (V.items[iu].tt == .function and eq(V.items[iu].data, "var(")) continue;
                const hh = V.items[iu].ident;
                _ = hh;
                if (V.items[iu].tt == .number or V.items[iu].isLengthPercentage() or isPosKw(h)) {
                    var j = iu + 1;
                    while (j < V.items.len) : (j += 1) {
                        if (isPosKw(V.items[j].ident)) continue;
                        if (V.items[j].tt == .number or V.items[j].isLengthPercentage()) continue;
                        break;
                    }
                    const pv = m.propertyVals("background-position", sys.A.dupe(Token, V.items[iu..j]) catch &.{});
                    const has_size = j < V.items.len and V.items[j].tt == .delim and V.items[j].data[0] == '/';
                    if (!has_size and pv.len == 2 and pv[0].isZero() and pv[1].isZero()) {
                        if (end - start == 2) {
                            V.items[iu] = .{ .tt = .number, .data = "0" };
                            V.items[iu + 1] = .{ .tt = .number, .data = "0" };
                            i += 1;
                        } else {
                            removeRange(V, iu, j);
                            end -= j - iu;
                            i -= 1;
                        }
                    } else {
                        if (pv.len == j - iu) {
                            for (pv, 0..) |pval, k| V.items[iu + k] = pval;
                        } else {
                            replaceRange(V, iu, j, pv);
                            end -= j - iu - pv.len;
                        }
                        i += @as(isize, @intCast(pv.len)) - 1;
                    }
                }
            }
            if (end - start == 0) {
                replaceRange(V, start, end, &.{ .{ .tt = .number, .data = "0" }, .{ .tt = .number, .data = "0" } });
                end += 2;
            }
            start = end + 1;
        }
    }

    fn backgroundPosition(m: *M, V: *std.ArrayList(Token)) void {
        _ = m;
        var start: usize = 0;
        var end: usize = 0;
        while (end <= V.items.len) : (end += 1) {
            if (end != V.items.len and V.items[end].tt != .comma) continue;
            if (start == end) {
                start += 1;
                continue;
            }
            if (end - start == 3 or end - start == 4) {
                for ([_]usize{ end - start - 1, start + 1 }) |i| {
                    if (2 < end - start and V.items[i].isZero()) {
                        removeRange(V, i, i + 1);
                        end -= 1;
                    }
                }
                var j = start + 1;
                if (2 < end - start and V.items[start + 2].tt == .ident) j = start + 2;
                var offsets: [2]?Token = .{ null, null };
                var noff: usize = 2;
                for ([_]usize{ j, start }) |i| {
                    if (i + 1 < end and i + 1 != j) {
                        if (V.items[i + 1].tt == .percentage) {
                            if (V.items[i].id("right") or V.items[i].id("bottom")) {
                                const d = V.items[i + 1].data;
                                const n = std.fmt.parseInt(i64, d[0 .. d.len - 1], 10) catch 0;
                                V.items[i + 1].data = std.fmt.allocPrint(sys.A, "{d}%", .{100 - n}) catch d;
                                if (V.items[i].id("right")) {
                                    V.items[i].data = "left";
                                    V.items[i].ident = "left";
                                } else {
                                    V.items[i].data = "top";
                                    V.items[i].ident = "top";
                                }
                            }
                        }
                        if (V.items[i].id("left")) {
                            offsets[0] = V.items[i + 1];
                        } else if (V.items[i].id("top")) offsets[1] = V.items[i + 1];
                    } else if (V.items[i].id("left")) {
                        offsets[0] = .{ .tt = .number, .data = "0" };
                    } else if (V.items[i].id("top")) {
                        offsets[1] = .{ .tt = .number, .data = "0" };
                    } else if (V.items[i].id("right")) {
                        offsets[0] = .{ .tt = .percentage, .data = "100%" };
                        V.items[i].ident = "left";
                    } else if (V.items[i].id("bottom")) {
                        offsets[1] = .{ .tt = .percentage, .data = "100%" };
                        V.items[i].ident = "top";
                    }
                }
                if (V.items[start].id("center") or V.items[j].id("center")) {
                    if (V.items[start].id("left") or V.items[j].id("left")) {
                        noff = 1;
                    } else if (V.items[start].id("top") or V.items[j].id("top")) {
                        offsets[0] = .{ .tt = .number, .data = "50%" };
                    }
                }
                if (offsets[0] != null and (noff == 1 or offsets[1] != null)) {
                    var off: [2]Token = undefined;
                    off[0] = offsets[0].?;
                    if (noff == 2) off[1] = offsets[1].?;
                    replaceRange(V, start, end, off[0..noff]);
                    end -= end - start - noff;
                }
            }
            if (end - start == 1 or end - start == 2) {
                if (end - start == 1 and (V.items[start].id("top") or V.items[start].id("bottom"))) break;
                if (end - start == 2 and (V.items[start].id("top") or V.items[start].id("bottom") or V.items[start + 1].id("left") or V.items[start + 1].id("right"))) {
                    const t = V.items[start];
                    V.items[start] = V.items[start + 1];
                    V.items[start + 1] = t;
                }
                var i = start;
                while (i < end) : (i += 1) {
                    if (V.items[i].tt == .ident) {
                        if (V.items[i].id("left") or V.items[i].id("top")) {
                            V.items[i] = .{ .tt = .number, .data = "0" };
                        } else if (V.items[i].id("right") or V.items[i].id("bottom")) {
                            V.items[i] = .{ .tt = .percentage, .data = "100%" };
                        } else if (V.items[i].id("center")) {
                            if (i == start) {
                                V.items[i] = .{ .tt = .percentage, .data = "50%" };
                            } else {
                                removeRange(V, start + 1, start + 2);
                                end -= 1;
                            }
                        }
                    } else if (i == start + 1 and V.items[i].tt == .percentage and eq(V.items[i].data, "50%")) {
                        removeRange(V, start + 1, start + 2);
                        end -= 1;
                    } else if (V.items[i].tt == .percentage and V.items[i].data[0] == '0') {
                        V.items[i] = .{ .tt = .number, .data = "0" };
                    }
                }
            }
            start = end + 1;
        }
    }
};

fn isPosKw(h: []const u8) bool {
    return eq(h, "left") or eq(h, "right") or eq(h, "top") or eq(h, "bottom") or eq(h, "center");
}

fn removeRange(V: *std.ArrayList(Token), a: usize, b: usize) void {
    const n = b - a;
    std.mem.copyForwards(Token, V.items[a..], V.items[b..]);
    V.items.len -= n;
}

fn replaceRange(V: *std.ArrayList(Token), a: usize, b: usize, with: []const Token) void {
    var out: std.ArrayList(Token) = .empty;
    out.appendSlice(sys.A, V.items[0..a]) catch {};
    out.appendSlice(sys.A, with) catch {};
    out.appendSlice(sys.A, V.items[b..]) catch {};
    V.* = out;
}

fn removeIdentsAndColor(V: *std.ArrayList(Token), idents: []const []const u8) void {
    var i: usize = 0;
    while (i < V.items.len) {
        var hit = false;
        for (idents) |id| if (eq(V.items[i].ident, id)) {
            hit = true;
        };
        if (hit) {
            removeRange(V, i, i + 1);
        } else {
            V.items[i] = minifyColor(V.items[i]);
            i += 1;
        }
    }
    if (V.items.len == 0) V.append(sys.A, .{ .tt = .ident, .data = "none", .ident = "none" }) catch {};
}

fn minifyColor(t: Token) Token {
    var v = t;
    if (v.tt == .ident) {
        if (lookup(&shorten_name, v.ident)) |hex| {
            v.tt = .hash;
            v.data = hex;
        }
    } else if (v.tt == .hash) {
        var data: []u8 = sys.A.dupe(u8, v.data) catch return t;
        for (data[1..]) |*c| c.* = std.ascii.toLower(c.*);
        if (data.len == 9 and data[7] == data[8]) {
            if (data[7] == 'f') {
                data = data[0..7];
            } else if (data[7] == '0') data = sys.A.dupe(u8, "#0000") catch data;
        }
        if (lookup(&shorten_hex, data)) |ident| {
            v.tt = .ident;
            v.data = ident;
            return v;
        } else if (data.len == 7 and data[1] == data[2] and data[3] == data[4] and data[5] == data[6]) {
            v.tt = .hash;
            data[2] = data[3];
            data[3] = data[5];
            data = data[0..4];
        } else if (data.len == 9 and data[1] == data[2] and data[3] == data[4] and data[5] == data[6] and data[7] == data[8]) {
            v.tt = .hash;
            data[2] = data[3];
            data[3] = data[5];
            data[4] = data[7];
            data = data[0..5];
        }
        v.data = data;
    }
    return v;
}

fn minifyLengthPercentage(t: Token) Token {
    var v = t;
    if (v.tt != .number and v.isZero()) {
        v.tt = .number;
        v.data = v.data[0..1];
    }
    return v;
}

fn minifyNumberPercentage(t: Token) Token {
    var v = t;
    var d = sys.A.dupe(u8, v.data) catch return t;
    if (v.tt == .percentage and d.len == 3 and d[d.len - 2] == '0') {
        d[1] = d[0];
        d[0] = '.';
        v.data = d[0..2];
        v.tt = .number;
    } else if (v.tt == .number and 2 < d.len and d[0] == '.' and d[1] == '0') {
        if (d[2] == '0') {
            d[0] = '.';
            std.mem.copyForwards(u8, d[1..], d[3..]);
            d[d.len - 2] = '%';
            v.data = d[0 .. d.len - 1];
            v.tt = .percentage;
        } else if (d.len == 3) {
            d[0] = d[2];
            d[1] = '%';
            v.data = d[0..2];
            v.tt = .percentage;
        }
    }
    return v;
}

fn removeMarkupNewlines(data_in: []const u8) []const u8 {
    var i: usize = 1;
    while (i + 2 < data_in.len) : (i += 1) {
        if (data_in[i] == '\\' and (data_in[i + 1] == '\n' or data_in[i + 1] == '\r')) {
            var data = sys.A.dupe(u8, data_in) catch return data_in;
            var j = i + 2;
            if (data[i + 1] == '\r' and data.len > i + 2 and data[i + 2] == '\n') j += 1;
            while (j < data.len) : (j += 1) {
                if (data[j] == '\\' and data.len > j + 1 and (data[j + 1] == '\n' or data[j + 1] == '\r')) {
                    if (data[j + 1] == '\r' and data.len > j + 2 and data[j + 2] == '\n') j += 1;
                    j += 1;
                } else {
                    data[i] = data[j];
                    i += 1;
                }
            }
            data = data[0..i];
            return data;
        }
    }
    return data_in;
}

fn rgbToToken(r: f64, g: f64, b: f64) Token {
    const rgb = [3]u8{ @intFromFloat(@floor(r * 255.0 + 0.5)), @intFromFloat(@floor(g * 255.0 + 0.5)), @intFromFloat(@floor(b * 255.0 + 0.5)) };
    var val = std.fmt.allocPrint(sys.A, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch return .{ .tt = .hash, .data = "#000" };
    if (lookup(&shorten_hex, val)) |s| return .{ .tt = .ident, .data = s };
    if (val[1] == val[2] and val[3] == val[4] and val[5] == val[6]) {
        val[2] = val[3];
        val[3] = val[5];
        val = val[0..4];
    }
    return .{ .tt = .hash, .data = val };
}

fn parseF32(s: []const u8) ?f64 {
    const x = std.fmt.parseFloat(f32, s) catch return null;
    return @floatCast(x);
}

fn hue2rgb(m1: f64, m2: f64, h0: f64) f64 {
    var h = h0;
    if (h < 0.0) h += 1.0;
    if (h > 1.0) h -= 1.0;
    if (h * 6.0 < 1.0) return m1 + (m2 - m1) * h * 6.0;
    if (h * 2.0 < 1.0) return m2;
    if (h * 3.0 < 2.0) return m1 + (m2 - m1) * (2.0 / 3.0 - h) * 6.0;
    return m1;
}

fn colorFunction(v: *Token) void {
    const fun = v.fun;
    if (!(eq(fun, "rgb") or eq(fun, "rgba") or eq(fun, "hsl") or eq(fun, "hsla"))) return;
    const args = v.args;
    var vals: [8]f64 = undefined;
    var nv: usize = 0;
    for (args, 0..) |arg, i| {
        const numeric = arg.tt == .number or arg.tt == .percentage;
        const sep = arg.tt == .comma or (i != 5 and arg.tt == .whitespace) or (i == 5 and arg.tt == .delim and arg.data[0] == '/');
        if ((i % 2 == 0 and !numeric) or (i % 2 == 1 and !sep)) return;
        if (numeric) {
            var d: f64 = undefined;
            if (arg.tt == .percentage) {
                d = parseF32(arg.data[0 .. arg.data.len - 1]) orelse return;
                d /= 100.0;
                if (d < min.epsilon) {
                    d = 0.0;
                } else if (1.0 - min.epsilon < d) d = 1.0;
            } else d = parseF32(arg.data) orelse return;
            if (nv < 8) {
                vals[nv] = d;
                nv += 1;
            }
        }
    }
    var a: f64 = 1.0;
    if (nv == 4) {
        if (vals[0] < min.epsilon and vals[1] < min.epsilon and vals[2] < min.epsilon and vals[3] < min.epsilon) {
            v.* = .{ .tt = .ident, .data = "transparent", .ident = "transparent" };
            return;
        } else if (1.0 - min.epsilon < vals[3]) {
            nv = 3;
            v.args = v.args[0 .. v.args.len - 2];
            if (eq(fun, "rgba") or eq(fun, "hsla")) {
                var nd = sys.A.dupe(u8, v.data[0 .. v.data.len - 1]) catch return;
                nd[nd.len - 1] = '(';
                v.data = nd;
            }
        } else a = vals[3];
    }
    if (a == 1.0 and (nv == 3 or nv == 4)) {
        if (eq(fun, "rgb") or eq(fun, "rgba")) {
            for (0..3) |j| {
                if (args[j * 2].tt == .number) {
                    vals[j] /= 255.0;
                    if (vals[j] < min.epsilon) {
                        vals[j] = 0.0;
                    } else if (1.0 - min.epsilon < vals[j]) vals[j] = 1.0;
                }
            }
            v.* = rgbToToken(vals[0], vals[1], vals[2]);
            return;
        } else if (eq(fun, "hsl") or (eq(fun, "hsla") and args[0].tt == .number and args[2].tt == .percentage and args[4].tt == .percentage)) {
            vals[0] /= 360.0;
            vals[0] = vals[0] - @trunc(vals[0]);
            if (vals[0] < 0.0) vals[0] = 1.0 + vals[0];
            const h = vals[0];
            const s = vals[1];
            const l = vals[2];
            var m2 = l * (s + 1);
            if (l > 0.5) m2 = l + s - l * s;
            const m1 = l * 2 - m2;
            v.* = rgbToToken(hue2rgb(m1, m2, h + 1.0 / 3.0), hue2rgb(m1, m2, h), hue2rgb(m1, m2, h - 1.0 / 3.0));
            return;
        }
    } else if (nv == 4) {
        args[6] = minifyNumberPercentage(args[6]);
    }
    if (3 <= nv and (eq(fun, "rgb") or eq(fun, "rgba"))) {
        var remove = true;
        for (0..3) |j| {
            if (args[j * 2].tt != .percentage or 2.0 * min.epsilon <= @mod(vals[j] + min.epsilon, 0.2)) {
                remove = false;
                break;
            }
        }
        if (remove) {
            for (0..3) |j| {
                args[j * 2].tt = .number;
                if (vals[j] < min.epsilon) {
                    args[j * 2].data = "0";
                } else if (@abs(vals[j] - 0.2) < min.epsilon) {
                    args[j * 2].data = "51";
                } else if (@abs(vals[j] - 0.4) < min.epsilon) {
                    args[j * 2].data = "102";
                } else if (@abs(vals[j] - 0.6) < min.epsilon) {
                    args[j * 2].data = "153";
                } else if (@abs(vals[j] - 0.8) < min.epsilon) {
                    args[j * 2].data = "204";
                } else if (@abs(vals[j] - 1.0) < min.epsilon) args[j * 2].data = "255";
            }
        }
    }
}

fn unicodeRange(values: []const Token) ?[]Token {
    var ranges: std.ArrayList([2]i64) = .empty;
    for (values) |val| {
        if (val.tt == .comma) continue;
        if (val.tt != .unicode_range) return null;
        const d = val.data;
        var i: usize = 2;
        var iw: usize = 0;
        var start: i64 = 0;
        while (i < d.len and d[i] != '-') : (i += 1) {
            start *= 16;
            if (d[i] >= '0' and d[i] <= '9') {
                start += d[i] - '0';
            } else if ((d[i] | 32) >= 'a' and (d[i] | 32) <= 'f') {
                start += (d[i] | 32) - 'a' + 10;
            } else if (iw == 0 and d[i] == '?') iw = i;
        }
        var end = start;
        if (iw != 0) {
            end = start + std.math.pow(i64, 16, @intCast(d.len - iw)) - 1;
        } else if (i < d.len and d[i] == '-') {
            i += 1;
            end = 0;
            while (i < d.len) : (i += 1) {
                end *= 16;
                if (d[i] >= '0' and d[i] <= '9') {
                    end += d[i] - '0';
                } else if ((d[i] | 32) >= 'a' and (d[i] | 32) <= 'f') end += (d[i] | 32) - 'a' + 10;
            }
            if (end <= start) end = start;
        }
        ranges.append(sys.A, .{ start, end }) catch {};
    }
    std.mem.sort([2]i64, ranges.items, {}, struct {
        fn lt(_: void, a: [2]i64, b: [2]i64) bool {
            return a[0] < b[0];
        }
    }.lt);
    var i: usize = 0;
    while (ranges.items.len > 0 and i < ranges.items.len - 1) : (i += 1) {
        const r = &ranges.items;
        if (r.*[i + 1][1] <= r.*[i][1]) {
            _ = ranges.orderedRemove(i + 1);
        } else if (r.*[i + 1][0] <= r.*[i][1] + 1) {
            r.*[i][1] = r.*[i + 1][1];
            _ = ranges.orderedRemove(i + 1);
        }
    }
    var out: std.ArrayList(Token) = .empty;
    for (ranges.items, 0..) |ran, k| {
        if (k != 0) out.append(sys.A, .{ .tt = .comma, .data = "," }) catch {};
        if (ran[0] == ran[1]) {
            out.append(sys.A, .{ .tt = .unicode_range, .data = std.fmt.allocPrint(sys.A, "U+{X}", .{ran[0]}) catch "" }) catch {};
        } else if (ran[0] == 0 and ran[1] == 0x10FFFF) {
            out.append(sys.A, .{ .tt = .ident, .data = "initial" }) catch {};
        } else {
            var k2: u6 = 0;
            while (k2 < 6 and (ran[0] >> (k2 * 4)) & 0xF == 0 and (ran[1] >> (k2 * 4)) & 0xF == 0xF) k2 += 1;
            var wild: u6 = k2;
            while (k2 < 6) : (k2 += 1) {
                if ((ran[0] >> (k2 * 4)) & 0xF != (ran[1] >> (k2 * 4)) & 0xF) {
                    wild = 0;
                    break;
                }
            }
            var s: []const u8 = undefined;
            if (wild != 0) {
                const q = "??????"[0..wild];
                if (ran[0] >> (wild * 4) == 0) {
                    s = std.fmt.allocPrint(sys.A, "U+{s}", .{q}) catch "";
                } else s = std.fmt.allocPrint(sys.A, "U+{X}{s}", .{ ran[0] >> (wild * 4), q }) catch "";
            } else s = std.fmt.allocPrint(sys.A, "U+{X}-{X}", .{ ran[0], ran[1] }) catch "";
            out.append(sys.A, .{ .tt = .unicode_range, .data = s }) catch {};
        }
    }
    return out.items;
}

/// Minifies a stylesheet (or a declaration list when `inline_`).
pub fn minify(src: []const u8, inline_: bool) ![]const u8 {
    var m = M{ .p = Parser.init(src, inline_) };
    try m.grammar();
    return m.out.items;
}

/// css.ShortenColorHex lookup (exact match), used by the SVG minifier.
pub fn shortenHex(v: []const u8) ?[]const u8 {
    for (shorten_hex) |e| if (std.mem.eql(u8, e[0], v)) return e[1];
    return null;
}
/// css.ShortenColorName lookup (exact match), used by the SVG minifier.
pub fn shortenName(v: []const u8) ?[]const u8 {
    for (shorten_name) |e| if (std.mem.eql(u8, e[0], v)) return e[1];
    return null;
}
