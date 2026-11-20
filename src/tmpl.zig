// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Go (BSD-3-Clause, Copyright The Go Authors) text/template and html/template; Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Go text/template compatible parser and executor with html/template style
//! contextual auto-escaping, as used by Hugo layouts.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const data = @import("data.zig");
const funcs = @import("funcs.zig");
const Value = v.Value;

pub threadlocal var err_msg: []const u8 = "";
pub fn fail(comptime f: []const u8, args: anytype) anyerror {
    err_msg = v.fmt(f, args);
    return error.TemplateError;
}

// ------------------------------------------------------------------ AST

pub const Expr = union(enum) {
    dot,
    nil,
    lit: Value,
    variable: []const u8,
    ident: []const u8,
    field: struct { base: ?*Expr, names: [][]const u8 },
    pipe: *Pipe,
};
pub const Cmd = struct { args: []Expr };
pub const Pipe = struct { decl: [][]const u8 = &.{}, assign: bool = false, cmds: []Cmd = &.{}, line: u32 = 0 };
pub const Branch = struct { pipe: *Pipe, body: []Node, else_: ?[]Node = null };
pub const Node = union(enum) {
    text: []const u8,
    action: *Pipe,
    if_: *Branch,
    range: *Branch,
    with: *Branch,
    template: struct { name: []const u8, pipe: ?*Pipe, line: u32 },
    break_,
    continue_,
    ret: ?*Pipe,
};
pub const Defs = std.StringArrayHashMapUnmanaged([]Node);
pub const Template = struct {
    name: []const u8,
    nodes: []Node = &.{},
    defs: Defs = .empty,
    /// true when the file consists only of {{ define }} blocks (=> wants a baseof)
    only_defines: bool = false,
};

// ------------------------------------------------------------------ lexer

const TokKind = enum { ident, field, dot, variable, str, num, char, lparen, rparen, pipe, declare, assign, comma };
const Tok = struct { kind: TokKind, s: []const u8, sp: bool };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn lexAction(src: []const u8, tname: []const u8, line: u32) anyerror![]Tok {
    var toks: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    var sp = true;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            sp = true;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i = if (v.indexOfPos(src, i, "*/")) |e| e + 2 else src.len;
            sp = true;
            continue;
        }
        var t: Tok = .{ .kind = .ident, .s = "", .sp = sp };
        sp = false;
        if (c == '"') {
            var b: v.Buf = .{};
            i += 1;
            while (i < src.len and src[i] != '"') : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1;
                    switch (src[i]) {
                        'n' => b.ch('\n'),
                        't' => b.ch('\t'),
                        'r' => b.ch('\r'),
                        '\\' => b.ch('\\'),
                        '"' => b.ch('"'),
                        '\'' => b.ch('\''),
                        'a' => b.ch(7),
                        'b' => b.ch(8),
                        'f' => b.ch(12),
                        'v' => b.ch(11),
                        'x' => {
                            if (i + 2 < src.len) b.ch(std.fmt.parseInt(u8, src[i + 1 .. i + 3], 16) catch '?');
                            i += 2;
                        },
                        'u', 'U' => {
                            const n: usize = if (src[i] == 'u') 4 else 8;
                            if (i + n < src.len) {
                                const cp = std.fmt.parseInt(u21, src[i + 1 .. i + 1 + n], 16) catch 0xFFFD;
                                var tmp: [4]u8 = undefined;
                                const l = std.unicode.utf8Encode(cp, &tmp) catch 0;
                                b.add(tmp[0..l]);
                            }
                            i += n;
                        },
                        else => {
                            b.ch('\\');
                            b.ch(src[i]);
                        },
                    }
                } else b.ch(src[i]);
            }
            if (i >= src.len) return fail("{s}:{d}: unterminated quoted string", .{ tname, line });
            i += 1;
            t.kind = .str;
            t.s = b.str();
        } else if (c == '`') {
            const e = v.indexOfPos(src, i + 1, "`") orelse return fail("{s}:{d}: unterminated raw string", .{ tname, line });
            t.kind = .str;
            t.s = src[i + 1 .. e];
            i = e + 1;
        } else if (c == '\'') {
            var e = i + 1;
            while (e < src.len and src[e] != '\'') : (e += 1) {
                if (src[e] == '\\') e += 1;
            }
            t.kind = .char;
            t.s = src[i + 1 .. @min(e, src.len)];
            i = @min(e + 1, src.len);
        } else if (c == '(') {
            t.kind = .lparen;
            i += 1;
        } else if (c == ')') {
            t.kind = .rparen;
            i += 1;
        } else if (c == '|') {
            t.kind = .pipe;
            i += 1;
        } else if (c == ',') {
            t.kind = .comma;
            i += 1;
        } else if (c == ':' and i + 1 < src.len and src[i + 1] == '=') {
            t.kind = .declare;
            i += 2;
        } else if (c == '=') {
            t.kind = .assign;
            i += 1;
        } else if (c == '$') {
            var e = i + 1;
            while (e < src.len and isIdent(src[e])) e += 1;
            t.kind = .variable;
            t.s = src[i..e];
            i = e;
        } else if (c == '.' and i + 1 < src.len and std.ascii.isDigit(src[i + 1])) {
            var e = i + 1;
            while (e < src.len and (std.ascii.isDigit(src[e]) or src[e] == 'e')) e += 1;
            t.kind = .num;
            t.s = src[i..e];
            i = e;
        } else if (c == '.') {
            var e = i + 1;
            while (e < src.len and isIdent(src[e])) e += 1;
            if (e == i + 1) {
                t.kind = .dot;
            } else {
                t.kind = .field;
                t.s = src[i + 1 .. e];
            }
            i = e;
        } else if (std.ascii.isDigit(c) or ((c == '-' or c == '+') and i + 1 < src.len and (std.ascii.isDigit(src[i + 1]) or src[i + 1] == '.'))) {
            var e = i + 1;
            while (e < src.len and (std.ascii.isAlphanumeric(src[e]) or src[e] == '.' or src[e] == '_' or ((src[e] == '-' or src[e] == '+') and (src[e - 1] == 'e' or src[e - 1] == 'E')))) e += 1;
            t.kind = .num;
            t.s = src[i..e];
            i = e;
        } else if (isIdent(c)) {
            var e = i + 1;
            while (e < src.len and isIdent(src[e])) e += 1;
            t.s = src[i..e];
            i = e;
        } else return fail("{s}:{d}: unexpected character '{c}' in action", .{ tname, line, c });
        try toks.append(sys.A, t);
    }
    return toks.items;
}

// ------------------------------------------------------------------ parser

const P = struct {
    toks: []Tok,
    i: usize = 0,
    tname: []const u8,
    line: u32,

    fn peek(p: *P) ?Tok {
        return if (p.i < p.toks.len) p.toks[p.i] else null;
    }

    fn pipeline(p: *P) anyerror!*Pipe {
        const pipe = try sys.A.create(Pipe);
        pipe.* = .{ .line = p.line };
        // declarations
        if (p.peek()) |t0| if (t0.kind == .variable) {
            var j = p.i + 1;
            var names: std.ArrayList([]const u8) = .empty;
            try names.append(sys.A, t0.s);
            while (j + 1 < p.toks.len and p.toks[j].kind == .comma and p.toks[j + 1].kind == .variable) : (j += 2) {
                try names.append(sys.A, p.toks[j + 1].s);
            }
            if (j < p.toks.len and (p.toks[j].kind == .declare or p.toks[j].kind == .assign)) {
                pipe.decl = names.items;
                pipe.assign = p.toks[j].kind == .assign;
                p.i = j + 1;
            }
        };
        var cmds: std.ArrayList(Cmd) = .empty;
        while (true) {
            var args: std.ArrayList(Expr) = .empty;
            while (p.peek()) |t| {
                if (t.kind == .pipe or t.kind == .rparen) break;
                try args.append(sys.A, try p.operand());
            }
            if (args.items.len == 0) return fail("{s}:{d}: missing value for command", .{ p.tname, p.line });
            try cmds.append(sys.A, .{ .args = args.items });
            if (p.peek()) |t| {
                if (t.kind == .pipe) {
                    p.i += 1;
                    continue;
                }
            }
            break;
        }
        pipe.cmds = cmds.items;
        return pipe;
    }

    fn operand(p: *P) anyerror!Expr {
        const t = p.toks[p.i];
        p.i += 1;
        var e: Expr = undefined;
        switch (t.kind) {
            .dot => e = .dot,
            .variable => e = .{ .variable = t.s },
            .str => e = .{ .lit = v.S(t.s) },
            .char => {
                var cp: i64 = '?';
                if (t.s.len > 0) {
                    if (t.s[0] == '\\' and t.s.len > 1) {
                        cp = switch (t.s[1]) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            else => t.s[1],
                        };
                    } else cp = v.decodeRune(t.s).cp;
                }
                e = .{ .lit = v.I(cp) };
            },
            .num => {
                const clean = v.replaceAll(t.s, "_", "");
                if (std.fmt.parseInt(i64, clean, 0) catch null) |n| {
                    e = .{ .lit = v.I(n) };
                } else if (std.fmt.parseFloat(f64, clean) catch null) |f| {
                    e = .{ .lit = .{ .float = f } };
                } else return fail("{s}:{d}: bad number syntax: {s}", .{ p.tname, p.line, t.s });
            },
            .lparen => {
                const inner = try p.pipeline();
                if (p.peek() == null or p.toks[p.i].kind != .rparen) return fail("{s}:{d}: unclosed left paren", .{ p.tname, p.line });
                p.i += 1;
                e = .{ .pipe = inner };
            },
            .field => {
                p.i -= 1;
                return p.fields(null);
            },
            .ident => {
                if (v.eq(t.s, "true")) {
                    e = .{ .lit = v.B(true) };
                } else if (v.eq(t.s, "false")) {
                    e = .{ .lit = v.B(false) };
                } else if (v.eq(t.s, "nil")) {
                    e = .nil;
                } else {
                    var name = t.s;
                    // namespaced function: strings.ToUpper
                    if (p.peek()) |n| if (n.kind == .field and !n.sp) {
                        const full = v.concat(&.{ t.s, ".", n.s });
                        if (funcs.exists(full) or (funcs.isNamespace(t.s) and !funcs.exists(t.s))) {
                            name = full;
                            p.i += 1;
                        }
                    };
                    e = .{ .ident = name };
                }
            },
            else => return fail("{s}:{d}: unexpected token in command", .{ p.tname, p.line }),
        }
        if (p.peek()) |n| if (n.kind == .field and !n.sp) {
            const base = try sys.A.create(Expr);
            base.* = e;
            return p.fields(base);
        };
        return e;
    }

    fn fields(p: *P, base: ?*Expr) anyerror!Expr {
        var names: std.ArrayList([]const u8) = .empty;
        var first = true;
        while (p.peek()) |n| {
            if (n.kind != .field or (!first and n.sp)) break;
            first = false;
            try names.append(sys.A, n.s);
            p.i += 1;
        }
        return .{ .field = .{ .base = base, .names = names.items } };
    }
};

const Frame = struct {
    kind: enum { root, if_, range, with, define, block },
    nodes: std.ArrayList(Node) = .empty,
    branch: ?*Branch = null,
    in_else: bool = false,
    name: []const u8 = "",
    /// number of extra frames opened by `else if` / `else with` chains
    chained: bool = false,
    block_pipe: ?*Pipe = null,
    line: u32 = 0,
};

pub fn parse(name: []const u8, src: []const u8) anyerror!*Template {
    const t = try sys.A.create(Template);
    t.* = .{ .name = name };
    var stack: std.ArrayList(Frame) = .empty;
    try stack.append(sys.A, .{ .kind = .root });
    var i: usize = 0;
    var line: u32 = 1;
    var trim_next = false;
    var top_level_content = false;
    var saw_define = false;
    while (i < src.len) {
        const open = v.indexOfPos(src, i, "{{") orelse src.len;
        var text = src[i..open];
        if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
        var after_open = open + 2;
        var is_comment_or_action = open < src.len;
        if (is_comment_or_action and after_open < src.len and src[after_open] == '-' and after_open + 1 < src.len and (src[after_open + 1] == ' ' or src[after_open + 1] == '\t' or src[after_open + 1] == '\n' or src[after_open + 1] == '\r')) {
            text = std.mem.trimEnd(u8, text, " \t\r\n");
            after_open += 1;
        }
        if (text.len > 0) {
            const cur = &stack.items[stack.items.len - 1];
            try cur.nodes.append(sys.A, .{ .text = text });
            if (stack.items.len == 1 and v.trimWs(text).len > 0) top_level_content = true;
        }
        for (src[i..@min(open, src.len)]) |c| {
            if (c == '\n') line += 1;
        }
        if (open >= src.len) break;
        is_comment_or_action = true;
        // find the end of the action, respecting strings and comments
        var j = after_open;
        var close: ?usize = null;
        while (j < src.len) {
            const c = src[j];
            if (c == '"') {
                j += 1;
                while (j < src.len and src[j] != '"') : (j += 1) {
                    if (src[j] == '\\') j += 1;
                }
                j += 1;
            } else if (c == '`') {
                j = (v.indexOfPos(src, j + 1, "`") orelse src.len) + 1;
            } else if (c == '\'') {
                j += 1;
                while (j < src.len and src[j] != '\'') : (j += 1) {
                    if (src[j] == '\\') j += 1;
                }
                j += 1;
            } else if (c == '/' and j + 1 < src.len and src[j + 1] == '*') {
                j = (v.indexOfPos(src, j, "*/") orelse src.len) + 2;
            } else if (c == '}' and j + 1 < src.len and src[j + 1] == '}') {
                close = j;
                break;
            } else j += 1;
        }
        const cl = close orelse return fail("{s}:{d}: unclosed action", .{ name, line });
        var body = src[after_open..cl];
        trim_next = false;
        if (body.len >= 2 and body[body.len - 1] == '-' and (body[body.len - 2] == ' ' or body[body.len - 2] == '\t' or body[body.len - 2] == '\n' or body[body.len - 2] == '\r')) {
            trim_next = true;
            body = body[0 .. body.len - 1];
        } else if (body.len == 1 and body[0] == '-') {
            trim_next = true;
            body = "";
        }
        const action_line = line;
        for (src[open..cl]) |c| {
            if (c == '\n') line += 1;
        }
        i = cl + 2;
        const toks = try lexAction(body, name, action_line);
        if (toks.len == 0) continue; // comment
        var p: P = .{ .toks = toks, .tname = name, .line = action_line };
        const kw = if (toks[0].kind == .ident) toks[0].s else "";
        const cur = &stack.items[stack.items.len - 1];
        if (v.eq(kw, "if") or v.eq(kw, "range") or v.eq(kw, "with")) {
            p.i = 1;
            const br = try sys.A.create(Branch);
            br.* = .{ .pipe = try p.pipeline(), .body = &.{} };
            try stack.append(sys.A, .{ .kind = if (v.eq(kw, "if")) .if_ else if (v.eq(kw, "range")) .range else .with, .branch = br, .line = action_line });
        } else if (v.eq(kw, "else")) {
            if (cur.branch == null or cur.in_else) return fail("{s}:{d}: unexpected {{{{else}}}}", .{ name, action_line });
            cur.branch.?.body = cur.nodes.items;
            cur.nodes = .empty;
            cur.in_else = true;
            if (toks.len > 1 and toks[1].kind == .ident and (v.eq(toks[1].s, "if") or v.eq(toks[1].s, "with"))) {
                p.i = 2;
                const br = try sys.A.create(Branch);
                br.* = .{ .pipe = try p.pipeline(), .body = &.{} };
                try stack.append(sys.A, .{ .kind = if (v.eq(toks[1].s, "if")) .if_ else .with, .branch = br, .chained = true, .line = action_line });
            }
        } else if (v.eq(kw, "end")) {
            while (true) {
                if (stack.items.len <= 1) return fail("{s}:{d}: unexpected {{{{end}}}}", .{ name, action_line });
                const fr = stack.pop().?;
                const parent = &stack.items[stack.items.len - 1];
                switch (fr.kind) {
                    .if_, .range, .with => {
                        const br = fr.branch.?;
                        if (fr.in_else) br.else_ = fr.nodes.items else br.body = fr.nodes.items;
                        const node: Node = switch (fr.kind) {
                            .if_ => .{ .if_ = br },
                            .range => .{ .range = br },
                            else => .{ .with = br },
                        };
                        try parent.nodes.append(sys.A, node);
                        if (fr.chained) continue; // close the enclosing branch as well
                    },
                    .define => try t.defs.put(sys.A, fr.name, fr.nodes.items),
                    .block => {
                        if (!t.defs.contains(fr.name)) try t.defs.put(sys.A, fr.name, fr.nodes.items);
                        try parent.nodes.append(sys.A, .{ .template = .{ .name = fr.name, .pipe = fr.block_pipe, .line = fr.line } });
                    },
                    .root => unreachable,
                }
                break;
            }
        } else if (v.eq(kw, "define") or v.eq(kw, "block")) {
            if (toks.len < 2 or toks[1].kind != .str) return fail("{s}:{d}: {s} needs a quoted name", .{ name, action_line, kw });
            var fr: Frame = .{ .kind = if (v.eq(kw, "define")) .define else .block, .name = toks[1].s, .line = action_line };
            if (fr.kind == .block and toks.len > 2) {
                p.i = 2;
                fr.block_pipe = try p.pipeline();
            }
            if (fr.kind == .define and stack.items.len == 1) saw_define = true;
            if (fr.kind == .block and stack.items.len == 1) top_level_content = true;
            try stack.append(sys.A, fr);
        } else if (v.eq(kw, "template")) {
            if (toks.len < 2 or toks[1].kind != .str) return fail("{s}:{d}: template needs a quoted name", .{ name, action_line });
            var pipe: ?*Pipe = null;
            if (toks.len > 2) {
                p.i = 2;
                pipe = try p.pipeline();
            }
            try cur.nodes.append(sys.A, .{ .template = .{ .name = toks[1].s, .pipe = pipe, .line = action_line } });
            if (stack.items.len == 1) top_level_content = true;
        } else if (v.eq(kw, "break") and toks.len == 1) {
            try cur.nodes.append(sys.A, .break_);
        } else if (v.eq(kw, "continue") and toks.len == 1) {
            try cur.nodes.append(sys.A, .continue_);
        } else if (v.eq(kw, "return")) {
            var pipe: ?*Pipe = null;
            if (toks.len > 1) {
                p.i = 1;
                pipe = try p.pipeline();
            }
            try cur.nodes.append(sys.A, .{ .ret = pipe });
        } else {
            const pipe = try p.pipeline();
            if (p.i < toks.len) return fail("{s}:{d}: unexpected token after pipeline", .{ name, action_line });
            try cur.nodes.append(sys.A, .{ .action = pipe });
            if (stack.items.len == 1) top_level_content = true;
        }
    }
    if (stack.items.len != 1) return fail("{s}:{d}: unclosed {{{{{s}}}}} (missing {{{{end}}}})", .{ name, stack.items[stack.items.len - 1].line, @tagName(stack.items[stack.items.len - 1].kind) });
    t.nodes = stack.items[0].nodes.items;
    t.only_defines = saw_define and !top_level_content;
    return t;
}

// ------------------------------------------------------------------ escaper

const State = enum { text, tag_open, tag, attr_name, after_name, before_value, attr_dq, attr_sq, attr_unq, script, style, comment, rcdata };
const AttrKind = enum { normal, url, js, css, srcset };

fn attrKindOf(name_in: []const u8) AttrKind {
    var n = v.lower(name_in);
    if (v.startsWith(n, "data-")) n = n[5..] else if (v.indexOfChar(n, ':')) |c| {
        if (v.eq(n[0..c], "xmlns")) return .url;
        n = n[c + 1 ..];
    }
    if (v.startsWith(n, "on")) return .js;
    if (v.eq(n, "style")) return .css;
    if (v.eq(n, "srcset")) return .srcset;
    const urls = [_][]const u8{ "action", "archive", "background", "cite", "classid", "codebase", "data", "formaction", "href", "icon", "longdesc", "manifest", "poster", "profile", "src", "usemap", "xmlns" };
    for (urls) |u| if (v.eq(n, u)) return .url;
    if (v.contains(n, "src") or v.contains(n, "uri") or v.contains(n, "url")) return .url;
    return .normal;
}

pub const Out = struct {
    b: v.Buf = .{},
    st: State = .text,
    tag: []const u8 = "",
    attr: []const u8 = "",
    attr_kind: AttrKind = .normal,
    val_start: usize = 0,
    closing: bool = false,
    name_start: usize = 0,
    js_q: u8 = 0,
    script_js: bool = true,
    script_json: bool = false,
    is_type_attr: bool = false,
    raw_mode: bool = false, // plain text output formats: no escaping

    pub fn text(o: *Out, s: []const u8) void {
        if (o.raw_mode) return o.b.add(s);
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            switch (o.st) {
                .text => {
                    const nx = v.indexOfPos(s, i, "<") orelse {
                        o.b.add(s[i..]);
                        return;
                    };
                    o.b.add(s[i..nx]);
                    i = nx;
                    if (v.startsWith(s[i..], "<!--")) {
                        o.st = .comment;
                        i += 4;
                        continue;
                    }
                    o.b.ch('<');
                    i += 1;
                    if (i < s.len and (std.ascii.isAlphabetic(s[i]) or s[i] == '/')) {
                        o.closing = s[i] == '/';
                        o.st = .tag_open;
                        o.name_start = o.b.len();
                        o.script_js = true;
                        o.script_json = false;
                    } else if (i >= s.len) {
                        // "<" at the very end of a text node: assume a tag follows
                    }
                    continue;
                },
                .comment => {
                    if (v.indexOfPos(s, i, "-->")) |e| {
                        i = e + 3;
                        o.st = .text;
                    } else return;
                    continue;
                },
                .tag_open => {
                    if (c == '/' and o.b.len() == o.name_start) {
                        o.b.ch(c);
                        i += 1;
                        o.name_start = o.b.len();
                        continue;
                    }
                    if (std.ascii.isAlphanumeric(c) or c == '-' or c == ':') {
                        o.b.ch(c);
                        i += 1;
                        continue;
                    }
                    o.tag = v.lower(o.b.str()[o.name_start..]);
                    o.st = .tag;
                    continue;
                },
                .tag => {
                    if (c == '>') {
                        o.b.ch(c);
                        i += 1;
                        o.endTag();
                    } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '/') {
                        o.b.ch(c);
                        i += 1;
                    } else {
                        o.st = .attr_name;
                        o.name_start = o.b.len();
                    }
                    continue;
                },
                .attr_name => {
                    if (c == '=' or c == '>' or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '/') {
                        o.attr = o.b.str()[o.name_start..];
                        o.attr_kind = attrKindOf(o.attr);
                        o.is_type_attr = v.eqi(o.attr, "type");
                        o.st = .after_name;
                    } else {
                        o.b.ch(c);
                        i += 1;
                    }
                    continue;
                },
                .after_name => {
                    if (c == '=') {
                        o.b.ch(c);
                        i += 1;
                        o.st = .before_value;
                    } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                        o.b.ch(c);
                        i += 1;
                    } else o.st = .tag;
                    continue;
                },
                .before_value => {
                    if (c == '"' or c == '\'') {
                        o.b.ch(c);
                        i += 1;
                        o.st = if (c == '"') .attr_dq else .attr_sq;
                        o.val_start = o.b.len();
                    } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                        o.b.ch(c);
                        i += 1;
                    } else if (c == '>') {
                        o.st = .tag;
                    } else {
                        o.st = .attr_unq;
                        o.val_start = o.b.len();
                    }
                    continue;
                },
                .attr_dq, .attr_sq => {
                    const q: u8 = if (o.st == .attr_dq) '"' else '\'';
                    const e = v.indexOfChar(s[i..], q) orelse {
                        o.b.add(s[i..]);
                        return;
                    };
                    o.b.add(s[i .. i + e + 1]);
                    i += e + 1;
                    o.attrDone(o.b.str()[o.val_start .. o.b.len() - 1]);
                    o.st = .tag;
                    continue;
                },
                .attr_unq => {
                    if (c == '>' or c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                        o.attrDone(o.b.str()[o.val_start..]);
                        o.st = .tag;
                    } else {
                        o.b.ch(c);
                        i += 1;
                    }
                    continue;
                },
                .script, .style, .rcdata => {
                    // look for the closing tag
                    const close = if (o.st == .script) "</script" else if (o.st == .style) "</style" else v.concat(&.{ "</", o.tag });
                    var j = i;
                    var found: ?usize = null;
                    while (j < s.len) : (j += 1) {
                        const ch = s[j];
                        if (o.st == .script) {
                            if (o.js_q != 0) {
                                if (ch == '\\') {
                                    j += 1;
                                    continue;
                                }
                                if (ch == o.js_q or (ch == '\n' and o.js_q != '`')) o.js_q = 0;
                                if (ch != '<') continue;
                            } else if (ch == '"' or ch == '\'' or ch == '`') {
                                o.js_q = ch;
                                continue;
                            } else if (o.script_json) {
                                // no comments in JSON
                            } else if (ch == '/' and j + 1 < s.len and s[j + 1] == '/' and (j == 0 or s[j - 1] != '\\')) {
                                // html/template strips JS comments
                                o.b.add(s[i..j]);
                                while (j < s.len and s[j] != '\n') j += 1;
                                i = j;
                                if (j >= s.len) break;
                                continue;
                            } else if (ch == '/' and j + 1 < s.len and s[j + 1] == '*') {
                                o.b.add(s[i..j]);
                                j = (v.indexOfPos(s, j + 2, "*/") orelse s.len -| 2) + 2;
                                o.b.ch(' ');
                                i = @min(j, s.len);
                                if (j >= s.len) break;
                                j -= 1;
                                continue;
                            }
                        }
                        if (o.st == .style and ch == '/' and j + 1 < s.len and s[j + 1] == '*') {
                            o.b.add(s[i..j]);
                            j = (v.indexOfPos(s, j + 2, "*/") orelse s.len -| 2) + 2;
                            o.b.ch(' ');
                            i = @min(j, s.len);
                            if (j >= s.len) break;
                            j -= 1;
                            continue;
                        }
                        if (ch == '<' and j + close.len <= s.len and v.eqi(s[j .. j + close.len], close)) {
                            found = j;
                            break;
                        }
                    }
                    if (found) |f| {
                        o.b.add(s[i..f]);
                        i = f;
                        o.st = .text;
                        o.js_q = 0;
                    } else {
                        o.b.add(s[i..]);
                        return;
                    }
                    continue;
                },
            }
        }
    }

    fn attrDone(o: *Out, val: []const u8) void {
        if (o.is_type_attr and v.eq(o.tag, "script")) {
            const t = v.lower(v.trimWs(val));
            o.script_js = t.len == 0 or v.contains(t, "javascript") or v.contains(t, "ecmascript") or v.contains(t, "json") or v.eq(t, "module");
            o.script_json = v.contains(t, "json");
        }
    }

    fn endTag(o: *Out) void {
        o.st = .text;
        if (o.closing) return;
        if (v.eq(o.tag, "script")) {
            if (o.script_js) o.st = .script;
            o.js_q = 0;
        } else if (v.eq(o.tag, "style")) {
            o.st = .style;
        } else if (v.eq(o.tag, "title") or v.eq(o.tag, "textarea")) {
            o.st = .rcdata;
        }
    }

    pub fn value(o: *Out, val: Value) void {
        if (o.raw_mode) return o.b.add(v.toStr(val));
        const safe: ?v.SafeKind = if (val == .safe) val.safe.kind else null;
        if (safe == .escaped and (o.st == .text or o.st == .rcdata or ((o.st == .attr_dq or o.st == .attr_sq) and o.attr_kind == .normal))) return o.b.add(val.safe.s);
        switch (o.st) {
            .text => {
                if (safe == .html) o.b.add(val.safe.s) else o.b.add(v.htmlEscape(v.toStr(val)));
            },
            .rcdata => {
                if (safe == .html) o.b.add(normEscape(val.safe.s)) else o.b.add(v.htmlEscape(v.toStr(val)));
            },
            .comment => {},
            .tag_open, .tag, .attr_name, .after_name => {
                if (o.st == .tag_open) {
                    o.tag = v.lower(o.b.str()[o.name_start..]);
                    o.st = .tag;
                }
                const s = v.toStr(val);
                if (safe == .attr) {
                    o.b.add(s);
                } else if (s.len == 0) {} else if (validAttrName(s)) {
                    o.b.add(s);
                } else o.b.add("ZgotmplZ");
            },
            .before_value => {
                // unquoted attribute value starting with an action: quote it like html/template does
                o.b.ch('"');
                o.val_start = o.b.len();
                o.attrValue(val, safe);
                o.b.ch('"');
                o.st = .tag;
            },
            .attr_dq, .attr_sq, .attr_unq => o.attrValue(val, safe),
            .script => o.jsValue(val, safe, false),
            .style => {
                const s = v.toStr(val);
                o.b.add(if (safe == .css) s else cssFilter(s));
            },
        }
    }

    fn attrValue(o: *Out, val: Value, safe: ?v.SafeKind) void {
        const s = v.toStr(val);
        switch (o.attr_kind) {
            .normal, .srcset => {
                if (safe == .html) o.b.add(normEscape(goStripTags(s))) else o.b.add(v.htmlEscape(s));
            },
            .url => {
                const sofar = o.b.str()[o.val_start..];
                if (v.indexOfChar(sofar, '?') != null or v.indexOfChar(sofar, '#') != null) {
                    o.b.add(v.htmlEscape(if (safe == .url) urlNormalize(s) else urlEscape(s)));
                } else if (sofar.len > 0) {
                    o.b.add(v.htmlEscape(urlNormalize(s)));
                } else {
                    o.b.add(v.htmlEscape(urlNormalize(if (safe == .url or urlIsSafe(s)) s else "#ZgotmplZ")));
                }
            },
            .js => {
                var tmp: Out = .{ .st = .script };
                tmp.js_q = jsQuoteState(o.b.str()[o.val_start..]);
                tmp.jsValue(val, safe, true);
                o.b.add(v.htmlEscape(tmp.b.str()));
            },
            .css => o.b.add(v.htmlEscape(if (safe == .css) s else cssFilter(s))),
        }
    }

    fn jsValue(o: *Out, val: Value, safe: ?v.SafeKind, in_attr: bool) void {
        _ = in_attr;
        const sval = if (val == .time) @import("time.zig").format(val.time, "2006-01-02T15:04:05Z07:00") else v.toStr(val);
        if (o.js_q != 0) {
            o.b.add(jsStrEscape(sval));
            return;
        }
        if (safe == .js) return o.b.add(val.safe.s);
        switch (val) {
            .str, .safe, .time, .obj => jsQuote(&o.b, sval),
            .nil => o.b.add(" null "),
            .bool, .int, .float, .dur => {
                o.b.ch(' ');
                o.b.add(v.toStr(val));
                o.b.ch(' ');
            },
            .list, .map => data.toJson(&o.b, val, .{}, 0),
        }
    }

    pub fn str(o: *const Out) []const u8 {
        return o.b.str();
    }
};

/// The JS string quote open at the end of an event-handler attribute value
/// written so far (0 when not inside a string literal).
fn jsQuoteState(raw: []const u8) u8 {
    var q: u8 = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var c = raw[i];
        if (c == '&') {
            // the few entities that can stand for quotes or backslashes
            const ents = [_]struct { e: []const u8, c: u8 }{ .{ .e = "&#34;", .c = '"' }, .{ .e = "&#39;", .c = '\'' }, .{ .e = "&quot;", .c = '"' }, .{ .e = "&apos;", .c = '\'' }, .{ .e = "&#x27;", .c = '\'' }, .{ .e = "&#x22;", .c = '"' }, .{ .e = "&#92;", .c = '\\' } };
            for (ents) |e| if (v.startsWith(raw[i..], e.e)) {
                c = e.c;
                i += e.e.len - 1;
                break;
            };
        }
        if (q != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == q) q = 0;
        } else if (c == '"' or c == '\'' or c == '`') q = c;
    }
    return q;
}

fn goStripTags(s: []const u8) []const u8 {
    if (v.indexOfChar(s, '<') == null) return s;
    var b: v.Buf = .{};
    var in_tag = false;
    for (s) |c| {
        if (c == '<') in_tag = true else if (c == '>' and in_tag) in_tag = false else if (!in_tag) b.ch(c);
    }
    return b.str();
}

fn validAttrName(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.')) return false;
    return true;
}

/// Escape for HTML but leave existing entities alone.
fn normEscape(s: []const u8) []const u8 {
    var b: v.Buf = .{};
    for (s) |c| switch (c) {
        '<' => b.add("&lt;"),
        '>' => b.add("&gt;"),
        '"' => b.add("&#34;"),
        '\'' => b.add("&#39;"),
        '+' => b.add("&#43;"),
        else => b.ch(c),
    };
    return b.str();
}

fn urlIsSafe(s: []const u8) bool {
    const colon = v.indexOfChar(s, ':') orelse return true;
    if (v.indexOfChar(s[0..colon], '/') != null) return true;
    const scheme = s[0..colon];
    return v.eqi(scheme, "http") or v.eqi(scheme, "https") or v.eqi(scheme, "mailto");
}

/// html/template's urlEscaper: everything but unreserved characters, lowercase hex.
fn urlEscape(s: []const u8) []const u8 {
    var b: v.Buf = .{};
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') b.ch(c) else b.print("%{x:0>2}", .{c});
    }
    return b.str();
}

fn urlNormalize(s: []const u8) []const u8 {
    var b: v.Buf = .{};
    for (s) |c| {
        switch (c) {
            '!', '#', '$', '&', '*', '+', ',', '/', ':', ';', '=', '?', '@', '[', ']', '-', '.', '_', '~', '%' => b.ch(c),
            else => if (std.ascii.isAlphanumeric(c)) b.ch(c) else b.print("%{x:0>2}", .{c}),
        }
    }
    return b.str();
}

fn cssFilter(s: []const u8) []const u8 {
    for (s) |c| switch (c) {
        0, '"', '\'', '(', ')', '/', ';', '@', '[', '\\', ']', '`', '{', '}', '<', '>' => return "ZgotmplZ",
        else => {},
    };
    if (v.contains(s, "--")) return "ZgotmplZ";
    const l = v.lower(s);
    if (v.contains(l, "expression") or v.contains(l, "mozbinding")) return "ZgotmplZ";
    return s;
}

fn jsStrEscape(s: []const u8) []const u8 {
    var b: v.Buf = .{};
    for (s) |c| switch (c) {
        '\\' => b.add("\\\\"),
        '\'' => b.add("\\u0027"),
        '"' => b.add("\\u0022"),
        '`' => b.add("\\u0060"),
        '\n' => b.add("\\n"),
        '\r' => b.add("\\r"),
        '\t' => b.add("\\t"),
        '<' => b.add("\\u003c"),
        '>' => b.add("\\u003e"),
        '&' => b.add("\\u0026"),
        '+' => b.add("\\u002b"),
        '/' => b.add("\\/"),
        '=' => b.add("\\u003d"),
        else => if (c < 0x20) b.print("\\u{x:0>4}", .{c}) else b.ch(c),
    };
    return b.str();
}

fn jsQuote(b: *v.Buf, s: []const u8) void {
    data.jsonStr(b, s, true);
}

// ------------------------------------------------------------------ executor

const Var = struct { name: []const u8, val: Value };

pub const deferred_prefix = "__hdeferred/zssg";
pub const Deferred = struct {
    body: []Node,
    data: Value,
    tmpl: *Template,
    over: ?*Defs,
    page: Value,
    key: ?[]const u8,
    raw_mode: bool,
    site: *@import("site.zig").Site,
    done: ?[]const u8 = null,
};
pub var deferred: std.ArrayList(Deferred) = .empty;

/// Executes deferred block `idx` (once; keyed blocks share their output).
pub fn runDeferred(idx: usize) anyerror![]const u8 {
    const d = &deferred.items[idx];
    if (d.done) |o| return o;
    if (d.key) |k| {
        for (deferred.items[0..idx]) |*o| {
            if (o.done != null and o.key != null and v.eq(o.key.?, k) and o.body.ptr == d.body.ptr) {
                d.done = o.done;
                return o.done.?;
            }
        }
    }
    const site = @import("site.zig");
    const saved = site.S;
    site.S = d.site;
    defer site.S = saved;
    var out: Out = .{ .raw_mode = d.raw_mode };
    var ex: Exec = .{ .out = &out, .tmpl = d.tmpl, .over = d.over, .page = d.page };
    try ex.vars.append(sys.A, .{ .name = "$", .val = d.data });
    ex.nodes(d.body, d.data) catch |e| {
        if (e != error.TmplReturn) return e;
    };
    d.done = out.str();
    return d.done.?;
}

pub const Exec = struct {
    out: *Out,
    vars: std.ArrayList(Var) = .empty,
    tmpl: *Template,
    /// extra define sets consulted before the template's own (page template overriding baseof blocks)
    over: ?*Defs = null,
    ret: Value = .nil,
    depth: u32 = 0,
    /// the page being rendered (for `page` func, partialCached etc.)
    page: Value = .nil,

    pub fn run(ex: *Exec, dot: Value) anyerror!void {
        try ex.vars.append(sys.A, .{ .name = "$", .val = dot });
        ex.nodes(ex.tmpl.nodes, dot) catch |e| {
            if (e == error.TmplReturn) return;
            return e;
        };
    }

    fn where(ex: *Exec, line: u32) []const u8 {
        return v.fmt("{s}:{d}", .{ ex.tmpl.name, line });
    }

    pub fn nodes(ex: *Exec, list: []Node, dot: Value) anyerror!void {
        for (list) |*n| switch (n.*) {
            .text => |t| ex.out.text(t),
            .action => |p| {
                const val = try ex.pipe(p, dot);
                if (p.decl.len == 0) ex.out.value(val);
            },
            .if_ => |br| {
                const mark = ex.vars.items.len;
                defer ex.vars.shrinkRetainingCapacity(mark);
                const c = try ex.pipe(br.pipe, dot);
                if (v.truth(c)) try ex.nodes(br.body, dot) else if (br.else_) |e| try ex.nodes(e, dot);
            },
            .with => |br| {
                const mark = ex.vars.items.len;
                defer ex.vars.shrinkRetainingCapacity(mark);
                const c = try ex.pipe(br.pipe, dot);
                if (c == .map and c.map.get("__deferred") != null) {
                    // templates.Defer: leave a placeholder; the block runs after all pages are
                    // rendered (and minified), see runDeferred.
                    const key: ?[]const u8 = if (c.map.get("key")) |k| (if (k == .str) k.str else null) else null;
                    deferred.append(sys.A, .{ .body = br.body, .data = c.map.get("data") orelse .nil, .tmpl = ex.tmpl, .over = ex.over, .page = ex.page, .key = key, .raw_mode = ex.out.raw_mode, .site = @import("site.zig").S }) catch {};
                    ex.out.b.add(v.fmt("{s}{d}__", .{ deferred_prefix, deferred.items.len - 1 }));
                } else if (v.truth(c)) try ex.nodes(br.body, c) else if (br.else_) |e| try ex.nodes(e, dot);
            },
            .range => |br| try ex.range(br, dot),
            .template => |t| {
                const arg: Value = if (t.pipe) |p| try ex.pipe(p, dot) else .nil;
                try ex.callTemplate(t.name, arg, t.line);
            },
            .break_ => return error.TmplBreak,
            .continue_ => return error.TmplContinue,
            .ret => |p| {
                ex.ret = if (p) |pp| try ex.pipe(pp, dot) else .nil;
                return error.TmplReturn;
            },
        };
    }

    fn callTemplate(ex: *Exec, name: []const u8, arg: Value, line: u32) anyerror!void {
        if (ex.depth > 200) return fail("{s}: template recursion too deep calling \"{s}\"", .{ ex.where(line), name });
        var body: ?[]Node = null;
        if (ex.over) |o| body = o.get(name);
        if (body == null) body = ex.tmpl.defs.get(name);
        if (body == null) body = funcs.globalDefine(name);
        if (body) |b| {
            const saved = ex.vars;
            ex.vars = .empty;
            try ex.vars.append(sys.A, .{ .name = "$", .val = arg });
            ex.depth += 1;
            defer {
                ex.vars = saved;
                ex.depth -= 1;
            }
            return ex.nodes(b, arg);
        }
        // fall back to partial / embedded template files
        const res = try funcs.templateByName(ex, name, arg, line);
        ex.out.value(res);
    }

    fn range(ex: *Exec, br: *Branch, dot: Value) anyerror!void {
        const mark = ex.vars.items.len;
        defer ex.vars.shrinkRetainingCapacity(mark);
        const decl = br.pipe.decl;
        // evaluate the pipeline without performing the declaration
        var tmp = br.pipe.*;
        tmp.decl = &.{};
        var coll = try ex.pipe(&tmp, dot);
        if (coll == .obj) coll = try funcs.objIter(coll.obj);
        var count: usize = 0;
        const Body = struct {
            fn one(e: *Exec, b: *Branch, d: [][]const u8, key: Value, val: Value) anyerror!bool {
                const m = e.vars.items.len;
                defer e.vars.shrinkRetainingCapacity(m);
                if (d.len == 1) {
                    try e.vars.append(sys.A, .{ .name = d[0], .val = val });
                } else if (d.len >= 2) {
                    try e.vars.append(sys.A, .{ .name = d[0], .val = key });
                    try e.vars.append(sys.A, .{ .name = d[1], .val = val });
                }
                e.nodes(b.body, val) catch |er| {
                    if (er == error.TmplBreak) return false;
                    if (er == error.TmplContinue) return true;
                    return er;
                };
                return true;
            }
        };
        switch (coll) {
            .list => |l| {
                // iterate over a snapshot so appends during iteration are safe
                const items = try sys.A.dupe(Value, l.items.items);
                for (items, 0..) |it, idx| {
                    count += 1;
                    if (!try Body.one(ex, br, decl, v.I(idx), it)) break;
                }
            },
            .map => |m| {
                for (v.sortedKeys(m)) |k| {
                    count += 1;
                    if (!try Body.one(ex, br, decl, v.S(k), m.m.get(k) orelse .nil)) break;
                }
            },
            .int => |n| {
                var k: i64 = 0;
                while (k < n) : (k += 1) {
                    count += 1;
                    if (!try Body.one(ex, br, decl, v.I(k), v.I(k))) break;
                }
            },
            .nil => {},
            .str, .safe => {
                const s = v.rawStr(coll).?;
                var i: usize = 0;
                var idx: i64 = 0;
                while (i < s.len) : (idx += 1) {
                    const r = v.decodeRune(s[i..]);
                    count += 1;
                    if (!try Body.one(ex, br, decl, v.I(i), v.I(r.cp))) break;
                    i += r.len;
                }
            },
            else => return fail("{s}: range can't iterate over {s}", .{ ex.where(br.pipe.line), v.toStr(coll) }),
        }
        if (count == 0) if (br.else_) |e| try ex.nodes(e, dot);
    }

    pub fn getVar(ex: *Exec, name: []const u8) ?Value {
        var i = ex.vars.items.len;
        while (i > 0) : (i -= 1) if (v.eq(ex.vars.items[i - 1].name, name)) return ex.vars.items[i - 1].val;
        return null;
    }

    pub fn pipe(ex: *Exec, p: *Pipe, dot: Value) anyerror!Value {
        var val: Value = .nil;
        var have = false;
        for (p.cmds) |cm| {
            val = ex.cmd(cm, dot, if (have) val else null, p.line) catch |e| {
                if (e == error.TemplateError and !v.contains(err_msg, ".html:") and !v.contains(err_msg, ex.tmpl.name)) {
                    err_msg = v.fmt("{s}: {s}", .{ ex.where(p.line), err_msg });
                }
                return e;
            };
            have = true;
        }
        if (p.decl.len > 0) {
            const name = p.decl[0];
            if (p.assign) {
                var i = ex.vars.items.len;
                var found = false;
                while (i > 0) : (i -= 1) if (v.eq(ex.vars.items[i - 1].name, name)) {
                    ex.vars.items[i - 1].val = val;
                    found = true;
                    break;
                };
                if (!found) return fail("{s}: undefined variable \"{s}\"", .{ ex.where(p.line), name });
            } else try ex.vars.append(sys.A, .{ .name = name, .val = val });
        }
        return val;
    }

    fn cmd(ex: *Exec, c: Cmd, dot: Value, piped: ?Value, line: u32) anyerror!Value {
        const first = c.args[0];
        switch (first) {
            .ident => |name| {
                // short-circuit forms
                if (v.eq(name, "and") or v.eq(name, "or")) {
                    const is_and = name[0] == 'a';
                    var last: Value = .nil;
                    for (c.args[1..]) |a| {
                        last = try ex.expr(a, dot, line);
                        if (v.truth(last) != is_and) return last;
                    }
                    if (piped) |pv| return pv;
                    return last;
                }
                if (v.eq(name, "try") and c.args.len == 2) {
                    const m = v.newMap();
                    if (ex.expr(c.args[1], dot, line)) |val| {
                        m.put("Value", val);
                        m.put("Err", .nil);
                    } else |e| {
                        if (e != error.TemplateError) return e;
                        m.put("Value", .nil);
                        m.put("Err", v.S(err_msg));
                    }
                    return v.M(m);
                }
                var args: std.ArrayList(Value) = .empty;
                for (c.args[1..]) |a| try args.append(sys.A, try ex.expr(a, dot, line));
                if (piped) |pv| try args.append(sys.A, pv);
                return funcs.call(ex, name, args.items, dot);
            },
            .field => |f| {
                if (c.args.len > 1 or piped != null) {
                    var base: Value = if (f.base) |b| try ex.expr(b.*, dot, line) else dot;
                    for (f.names[0 .. f.names.len - 1]) |n| base = try funcs.field(ex, base, n, &.{});
                    var args: std.ArrayList(Value) = .empty;
                    for (c.args[1..]) |a| try args.append(sys.A, try ex.expr(a, dot, line));
                    if (piped) |pv| try args.append(sys.A, pv);
                    return funcs.field(ex, base, f.names[f.names.len - 1], args.items);
                }
                return ex.expr(first, dot, line);
            },
            else => {
                if (c.args.len > 1) return fail("{s}: can't give arguments to a non-function value", .{ex.where(line)});
                if (piped != null) return fail("{s}: non-executable command in pipeline", .{ex.where(line)});
                return ex.expr(first, dot, line);
            },
        }
    }

    fn expr(ex: *Exec, e: Expr, dot: Value, line: u32) anyerror!Value {
        switch (e) {
            .dot => return dot,
            .nil => return .nil,
            .lit => |l| return l,
            .variable => |name| return ex.getVar(name) orelse fail("{s}: undefined variable \"{s}\"", .{ ex.where(line), name }),
            .ident => |name| return funcs.call(ex, name, &.{}, dot),
            .pipe => |p| return ex.pipe(p, dot),
            .field => |f| {
                var base: Value = if (f.base) |b| try ex.expr(b.*, dot, line) else dot;
                for (f.names) |n| base = try funcs.field(ex, base, n, &.{});
                return base;
            },
        }
    }
};

/// Execute `t` (optionally inside `base`, whose blocks `t` overrides) and return the output.
pub fn render(t: *Template, base: ?*Template, dot: Value, page: Value, raw_mode: bool) anyerror![]const u8 {
    var out: Out = .{ .raw_mode = raw_mode };
    var ex: Exec = .{ .out = &out, .tmpl = base orelse t, .page = page };
    if (base != null) ex.over = &t.defs;
    try ex.run(dot);
    return out.str();
}
