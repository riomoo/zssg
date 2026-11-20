// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/minify and tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! JSON minifier: a port of tdewolff/parse/json and tdewolff/minify/json (MIT).
const std = @import("std");
const sys = @import("sys.zig");
const min = @import("min.zig");

const GT = enum { err, literal, number, string, start_object, end_object, start_array, end_array };
const State = enum { value, object_key, object_value, array };

const Parser = struct {
    s: []const u8,
    pos: usize = 0,
    start: usize = 0,
    state: std.ArrayList(State) = .empty,
    need_comma: bool = false,
    failed: bool = false,

    fn peek(p: *const Parser, n: usize) u8 {
        return if (p.pos + n < p.s.len) p.s[p.pos + n] else 0;
    }
    fn shift(p: *Parser) []const u8 {
        const r = p.s[p.start..p.pos];
        p.start = p.pos;
        return r;
    }
    fn ws(p: *Parser) void {
        while (true) {
            const c = p.peek(0);
            if (c != ' ' and c != '\n' and c != '\r' and c != '\t') break;
            p.pos += 1;
        }
    }
    fn top(p: *Parser) *State {
        return &p.state.items[p.state.items.len - 1];
    }
    fn fail(p: *Parser) GT {
        p.failed = true;
        return .err;
    }

    fn next(p: *Parser) struct { gt: GT, text: []const u8 } {
        p.ws();
        var c = p.peek(0);
        const st = p.top().*;
        if (c == ',') {
            if (st != .array and st != .object_key) return .{ .gt = p.fail(), .text = "" };
            p.pos += 1;
            p.ws();
            p.need_comma = false;
            c = p.peek(0);
        }
        p.start = p.pos;
        if (p.need_comma and c != '}' and c != ']' and !(c == 0 and p.pos >= p.s.len)) return .{ .gt = p.fail(), .text = "" };
        if (c == '{') {
            p.state.append(sys.A, .object_key) catch {};
            p.pos += 1;
            return .{ .gt = .start_object, .text = p.shift() };
        } else if (c == '}') {
            if (st != .object_key) return .{ .gt = p.fail(), .text = "" };
            p.need_comma = true;
            p.state.items.len -= 1;
            if (p.top().* == .object_value) p.top().* = .object_key;
            p.pos += 1;
            return .{ .gt = .end_object, .text = p.shift() };
        } else if (c == '[') {
            p.state.append(sys.A, .array) catch {};
            p.pos += 1;
            return .{ .gt = .start_array, .text = p.shift() };
        } else if (c == ']') {
            p.need_comma = true;
            if (st != .array) return .{ .gt = p.fail(), .text = "" };
            p.state.items.len -= 1;
            if (p.top().* == .object_value) p.top().* = .object_key;
            p.pos += 1;
            return .{ .gt = .end_array, .text = p.shift() };
        } else if (st == .object_key) {
            if (c != '"' or !p.string()) return .{ .gt = p.fail(), .text = "" };
            const n = p.pos - p.start;
            p.ws();
            if (p.peek(0) != ':') return .{ .gt = p.fail(), .text = "" };
            p.pos += 1;
            p.top().* = .object_value;
            return .{ .gt = .string, .text = p.shift()[0..n] };
        } else {
            p.need_comma = true;
            if (st == .object_value) p.top().* = .object_key;
            if (c == '"' and p.string()) return .{ .gt = .string, .text = p.shift() };
            if (p.number()) return .{ .gt = .number, .text = p.shift() };
            if (p.literal()) return .{ .gt = .literal, .text = p.shift() };
            if (p.peek(0) == 0 and p.pos >= p.s.len) return .{ .gt = .err, .text = "" };
        }
        return .{ .gt = p.fail(), .text = "" };
    }

    fn literal(p: *Parser) bool {
        for ([_][]const u8{ "true", "false", "null" }) |lit| {
            if (std.mem.startsWith(u8, p.s[p.pos..], lit)) {
                p.pos += lit.len;
                return true;
            }
        }
        return false;
    }
    fn digit(p: *const Parser) bool {
        const c = p.peek(0);
        return c >= '0' and c <= '9';
    }
    fn number(p: *Parser) bool {
        var mark = p.pos;
        if (p.peek(0) == '-') p.pos += 1;
        const c = p.peek(0);
        if (c >= '1' and c <= '9') {
            p.pos += 1;
            while (p.digit()) p.pos += 1;
        } else if (c != '0') {
            p.pos = mark;
            return false;
        } else p.pos += 1;
        if (p.peek(0) == '.') {
            p.pos += 1;
            if (!p.digit()) {
                p.pos -= 1;
                return true;
            }
            while (p.digit()) p.pos += 1;
        }
        mark = p.pos;
        const e = p.peek(0);
        if (e == 'e' or e == 'E') {
            p.pos += 1;
            const sg = p.peek(0);
            if (sg == '+' or sg == '-') p.pos += 1;
            if (!p.digit()) {
                p.pos = mark;
                return true;
            }
            while (p.digit()) p.pos += 1;
        }
        return true;
    }
    fn string(p: *Parser) bool {
        p.pos += 1;
        while (true) {
            if (p.pos >= p.s.len) return false;
            const c = p.s[p.pos];
            if (c == '"') {
                var escaped = false;
                var i = p.pos;
                while (i > p.start) {
                    i -= 1;
                    if (p.s[i] == '\\') escaped = !escaped else break;
                }
                if (!escaped) {
                    p.pos += 1;
                    break;
                }
            } else if (c == 0) return false;
            p.pos += 1;
        }
        return true;
    }
};

pub fn minify(src: []const u8) ![]const u8 {
    var p = Parser{ .s = src };
    p.state.append(sys.A, .value) catch {};
    var out: std.ArrayList(u8) = .empty;
    var skip_comma = true;
    while (true) {
        const state = p.top().*;
        const r = p.next();
        if (r.gt == .err) {
            if (p.failed) return error.JsonSyntax;
            return out.items;
        }
        if (!skip_comma and r.gt != .end_object and r.gt != .end_array) {
            if (state == .object_key or state == .array) {
                try out.append(sys.A, ',');
            } else if (state == .object_value) try out.append(sys.A, ':');
        }
        skip_comma = r.gt == .start_object or r.gt == .start_array;
        var text = r.text;
        if (text.len > 0 and ((text[0] >= '0' and text[0] <= '9') or text[0] == '-')) {
            text = min.number(text, 0);
            if (text[0] == '.') {
                try out.append(sys.A, '0');
            } else if (text.len > 1 and text[0] == '-' and text[1] == '.') {
                text = text[1..];
                try out.appendSlice(sys.A, "-0");
            }
        }
        try out.appendSlice(sys.A, text);
    }
}
