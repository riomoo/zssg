// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
//! Small backtracking regular expression engine covering the RE2 syntax
//! commonly used in Hugo templates (replaceRE, findRE, findRESubmatch, where ... "like").
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");

pub var err_msg: []const u8 = "";

const Range = struct { lo: u21, hi: u21 };
const Class = struct { ranges: []Range, neg: bool };

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: Class,
    bol,
    eol,
    bot,
    eot,
    wordb,
    nwordb,
    concat: []Node,
    alt: []Node,
    repeat: struct { n: *Node, min: u32, max: ?u32, greedy: bool },
    group: struct { n: *Node, idx: ?u32 },
    flags: struct { n: *Node, i: bool, s: bool, m: bool },
};

const Inst = union(enum) {
    char: struct { c: u21, fold: bool },
    any: bool, // true = matches newline
    class: struct { c: Class, fold: bool },
    bol: bool, // multiline
    eol: bool,
    bot,
    eot,
    wordb,
    nwordb,
    split: struct { a: u32, b: u32 },
    jmp: u32,
    save: u32,
    match,
};

pub const Regex = struct {
    prog: []Inst,
    ncap: u32,
    names: [][]const u8,
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    ncap: u32 = 1,
    names: std.ArrayList([]const u8) = .empty,
    fi: bool = false,
    fs: bool = false,
    fm: bool = false,
    fu: bool = false,

    fn fail(p: *Parser, msg: []const u8) anyerror {
        err_msg = v.fmt("error parsing regexp: {s}: `{s}`", .{ msg, p.s });
        return error.RegexError;
    }
    fn more(p: *Parser) bool {
        return p.i < p.s.len;
    }
    fn alt(p: *Parser) anyerror!Node {
        var alts: std.ArrayList(Node) = .empty;
        try alts.append(sys.A, try p.concat());
        while (p.more() and p.s[p.i] == '|') {
            p.i += 1;
            try alts.append(sys.A, try p.concat());
        }
        if (alts.items.len == 1) return alts.items[0];
        return .{ .alt = alts.items };
    }
    fn concat(p: *Parser) anyerror!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.more() and p.s[p.i] != '|' and p.s[p.i] != ')') {
            var at = try p.atom();
            // quantifiers
            while (p.more()) {
                const c = p.s[p.i];
                var min: u32 = 0;
                var max: ?u32 = null;
                if (c == '*') {
                    p.i += 1;
                } else if (c == '+') {
                    min = 1;
                    p.i += 1;
                } else if (c == '?') {
                    max = 1;
                    p.i += 1;
                } else if (c == '{') {
                    const e = v.indexOfPos(p.s, p.i, "}") orelse break;
                    const body = p.s[p.i + 1 .. e];
                    if (body.len == 0 or !std.ascii.isDigit(body[0])) break;
                    if (v.indexOfChar(body, ',')) |cm| {
                        min = std.fmt.parseInt(u32, body[0..cm], 10) catch break;
                        max = if (cm + 1 == body.len) null else std.fmt.parseInt(u32, body[cm + 1 ..], 10) catch break;
                    } else {
                        min = std.fmt.parseInt(u32, body, 10) catch break;
                        max = min;
                    }
                    p.i = e + 1;
                } else break;
                var greedy = !p.fu;
                if (p.more() and p.s[p.i] == '?') {
                    greedy = !greedy;
                    p.i += 1;
                }
                const n = try sys.A.create(Node);
                n.* = at;
                at = .{ .repeat = .{ .n = n, .min = min, .max = max, .greedy = greedy } };
            }
            try items.append(sys.A, at);
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .concat = items.items };
    }
    fn wrap(p: *Parser, n: Node) anyerror!Node {
        const np = try sys.A.create(Node);
        np.* = n;
        return .{ .flags = .{ .n = np, .i = p.fi, .s = p.fs, .m = p.fm } };
    }
    fn atom(p: *Parser) anyerror!Node {
        const c = p.s[p.i];
        switch (c) {
            '(' => {
                p.i += 1;
                var idx: ?u32 = null;
                const save = .{ p.fi, p.fs, p.fm, p.fu };
                var scoped = false;
                if (p.more() and p.s[p.i] == '?') {
                    p.i += 1;
                    if (p.more() and (p.s[p.i] == 'P' or p.s[p.i] == '<')) {
                        if (p.s[p.i] == 'P') p.i += 1;
                        if (!p.more() or p.s[p.i] != '<') return p.fail("invalid named capture");
                        const e = v.indexOfPos(p.s, p.i, ">") orelse return p.fail("invalid named capture");
                        idx = p.ncap;
                        p.ncap += 1;
                        while (p.names.items.len < idx.?) try p.names.append(sys.A, "");
                        try p.names.append(sys.A, p.s[p.i + 1 .. e]);
                        p.i = e + 1;
                    } else {
                        var neg = false;
                        while (p.more() and p.s[p.i] != ')' and p.s[p.i] != ':') : (p.i += 1) {
                            switch (p.s[p.i]) {
                                '-' => neg = true,
                                'i' => p.fi = !neg,
                                's' => p.fs = !neg,
                                'm' => p.fm = !neg,
                                'U' => p.fu = !neg,
                                else => return p.fail("invalid or unsupported Perl syntax"),
                            }
                        }
                        if (!p.more()) return p.fail("missing closing )");
                        if (p.s[p.i] == ')') {
                            // flags apply to the rest of the enclosing group
                            p.i += 1;
                            const rest = try p.alt();
                            return p.wrap(rest);
                        }
                        p.i += 1;
                        scoped = true;
                    }
                } else {
                    idx = p.ncap;
                    p.ncap += 1;
                }
                var inner = try p.alt();
                if (!p.more() or p.s[p.i] != ')') return p.fail("missing closing )");
                p.i += 1;
                if (scoped) {
                    inner = try p.wrap(inner);
                    p.fi = save[0];
                    p.fs = save[1];
                    p.fm = save[2];
                    p.fu = save[3];
                    return inner;
                }
                const np = try sys.A.create(Node);
                np.* = inner;
                return .{ .group = .{ .n = np, .idx = idx } };
            },
            '[' => return .{ .class = try p.class() },
            '.' => {
                p.i += 1;
                return .any;
            },
            '^' => {
                p.i += 1;
                return .bol;
            },
            '$' => {
                p.i += 1;
                return .eol;
            },
            '\\' => {
                p.i += 1;
                if (!p.more()) return p.fail("trailing backslash");
                const e = p.s[p.i];
                p.i += 1;
                switch (e) {
                    'b' => return .wordb,
                    'B' => return .nwordb,
                    'A' => return .bot,
                    'z' => return .eot,
                    'd', 'D', 'w', 'W', 's', 'S' => return .{ .class = try perlClass(e) },
                    'p', 'P' => {
                        var name: []const u8 = "";
                        if (p.more() and p.s[p.i] == '{') {
                            const en = v.indexOfPos(p.s, p.i, "}") orelse return p.fail("invalid character class range");
                            name = p.s[p.i + 1 .. en];
                            p.i = en + 1;
                        } else if (p.more()) {
                            name = p.s[p.i .. p.i + 1];
                            p.i += 1;
                        }
                        return .{ .class = try unicodeClass(name, e == 'P') };
                    },
                    'Q' => {
                        const en = v.indexOfPos(p.s, p.i, "\\E") orelse p.s.len;
                        var items: std.ArrayList(Node) = .empty;
                        for (p.s[p.i..en]) |ch| try items.append(sys.A, .{ .char = ch });
                        p.i = @min(en + 2, p.s.len);
                        return .{ .concat = items.items };
                    },
                    else => return .{ .char = try p.escapeChar(e) },
                }
            },
            '*', '+', '?' => return p.fail("missing argument to repetition operator"),
            else => {
                const r = v.decodeRune(p.s[p.i..]);
                p.i += r.len;
                return .{ .char = r.cp };
            },
        }
    }
    fn escapeChar(p: *Parser, e: u8) anyerror!u21 {
        return switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 12,
            'v' => 11,
            'a' => 7,
            'x' => blk: {
                if (p.more() and p.s[p.i] == '{') {
                    const en = v.indexOfPos(p.s, p.i, "}") orelse return p.fail("invalid escape sequence");
                    const cp = std.fmt.parseInt(u21, p.s[p.i + 1 .. en], 16) catch return p.fail("invalid escape sequence");
                    p.i = en + 1;
                    break :blk cp;
                }
                if (p.i + 2 > p.s.len) return p.fail("invalid escape sequence");
                const cp = std.fmt.parseInt(u21, p.s[p.i .. p.i + 2], 16) catch return p.fail("invalid escape sequence");
                p.i += 2;
                break :blk cp;
            },
            else => if (std.ascii.isAlphanumeric(e)) p.fail("invalid escape sequence") else e,
        };
    }
    fn class(p: *Parser) anyerror!Class {
        p.i += 1;
        var ranges: std.ArrayList(Range) = .empty;
        var neg = false;
        if (p.more() and p.s[p.i] == '^') {
            neg = true;
            p.i += 1;
        }
        var first = true;
        while (p.more() and (p.s[p.i] != ']' or first)) {
            first = false;
            if (v.startsWith(p.s[p.i..], "[:")) {
                if (v.indexOfPos(p.s, p.i, ":]")) |e| {
                    const name = p.s[p.i + 2 .. e];
                    p.i = e + 2;
                    const pc: []const Range = if (v.eq(name, "alpha")) &.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' } } else if (v.eq(name, "digit")) &.{.{ .lo = '0', .hi = '9' }} else if (v.eq(name, "alnum")) &.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '0', .hi = '9' } } else if (v.eq(name, "space")) &.{ .{ .lo = 9, .hi = 13 }, .{ .lo = ' ', .hi = ' ' } } else if (v.eq(name, "upper")) &.{.{ .lo = 'A', .hi = 'Z' }} else if (v.eq(name, "lower")) &.{.{ .lo = 'a', .hi = 'z' }} else if (v.eq(name, "punct")) &.{ .{ .lo = '!', .hi = '/' }, .{ .lo = ':', .hi = '@' }, .{ .lo = '[', .hi = '`' }, .{ .lo = '{', .hi = '~' } } else if (v.eq(name, "word")) &.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '0', .hi = '9' }, .{ .lo = '_', .hi = '_' } } else if (v.eq(name, "xdigit")) &.{ .{ .lo = 'a', .hi = 'f' }, .{ .lo = 'A', .hi = 'F' }, .{ .lo = '0', .hi = '9' } } else return p.fail("invalid character class range");
                    try ranges.appendSlice(sys.A, pc);
                    continue;
                }
            }
            var lo: u21 = undefined;
            if (p.s[p.i] == '\\') {
                p.i += 1;
                if (!p.more()) return p.fail("missing closing ]");
                const e = p.s[p.i];
                p.i += 1;
                if (e == 'd' or e == 'w' or e == 's' or e == 'D' or e == 'W' or e == 'S') {
                    const pc = try perlClass(e);
                    if (pc.neg) {
                        // approximate negated perl class inside a class by complement ranges
                        var prev: u21 = 0;
                        for (pc.ranges) |rg| {
                            if (rg.lo > prev) try ranges.append(sys.A, .{ .lo = prev, .hi = rg.lo - 1 });
                            prev = rg.hi + 1;
                        }
                        try ranges.append(sys.A, .{ .lo = prev, .hi = 0x10FFFF });
                    } else try ranges.appendSlice(sys.A, pc.ranges);
                    continue;
                }
                if (e == 'p' or e == 'P') {
                    var name: []const u8 = "";
                    if (p.more() and p.s[p.i] == '{') {
                        const en = v.indexOfPos(p.s, p.i, "}") orelse return p.fail("invalid character class range");
                        name = p.s[p.i + 1 .. en];
                        p.i = en + 1;
                    } else if (p.more()) {
                        name = p.s[p.i .. p.i + 1];
                        p.i += 1;
                    }
                    const uc = try unicodeClass(name, false);
                    try ranges.appendSlice(sys.A, uc.ranges);
                    continue;
                }
                lo = try p.escapeChar(e);
            } else {
                const r = v.decodeRune(p.s[p.i..]);
                p.i += r.len;
                lo = r.cp;
            }
            var hi = lo;
            if (p.i + 1 < p.s.len and p.s[p.i] == '-' and p.s[p.i + 1] != ']') {
                p.i += 1;
                if (p.s[p.i] == '\\') {
                    p.i += 1;
                    const e = p.s[p.i];
                    p.i += 1;
                    hi = try p.escapeChar(e);
                } else {
                    const r = v.decodeRune(p.s[p.i..]);
                    p.i += r.len;
                    hi = r.cp;
                }
                if (hi < lo) return p.fail("invalid character class range");
            }
            try ranges.append(sys.A, .{ .lo = lo, .hi = hi });
        }
        if (!p.more()) return p.fail("missing closing ]");
        p.i += 1;
        return .{ .ranges = ranges.items, .neg = neg };
    }
};

fn perlClass(e: u8) anyerror!Class {
    const d = [_]Range{.{ .lo = '0', .hi = '9' }};
    const w = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
    const s = [_]Range{ .{ .lo = 9, .hi = 10 }, .{ .lo = 12, .hi = 13 }, .{ .lo = ' ', .hi = ' ' } };
    const base: []const Range = switch (std.ascii.toLower(e)) {
        'd' => &d,
        'w' => &w,
        else => &s,
    };
    return .{ .ranges = try sys.A.dupe(Range, base), .neg = std.ascii.isUpper(e) };
}

fn unicodeClass(name: []const u8, neg: bool) anyerror!Class {
    var r: std.ArrayList(Range) = .empty;
    const n = if (name.len > 0 and name[0] == '^') name[1..] else name;
    const flip = name.len > 0 and name[0] == '^';
    if (n.len > 0 and n[0] == 'L' or v.eq(n, "Latin") or v.eq(n, "Han") or v.eq(n, "Cyrillic") or v.eq(n, "Greek")) {
        if (!(v.eq(n, "Han") or v.eq(n, "Cyrillic") or v.eq(n, "Greek"))) {
            if (!v.eq(n, "Lu")) try r.append(sys.A, .{ .lo = 'a', .hi = 'z' });
            if (!v.eq(n, "Ll")) try r.append(sys.A, .{ .lo = 'A', .hi = 'Z' });
        }
        try r.append(sys.A, .{ .lo = 0xAA, .hi = 0x10FFFF });
    } else if (n.len > 0 and n[0] == 'N') {
        try r.append(sys.A, .{ .lo = '0', .hi = '9' });
    } else if (n.len > 0 and n[0] == 'P' or n.len > 0 and n[0] == 'S') {
        try r.appendSlice(sys.A, &.{ .{ .lo = '!', .hi = '/' }, .{ .lo = ':', .hi = '@' }, .{ .lo = '[', .hi = '`' }, .{ .lo = '{', .hi = '~' }, .{ .lo = 0x2000, .hi = 0x206F } });
    } else if (n.len > 0 and n[0] == 'Z') {
        try r.appendSlice(sys.A, &.{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = 0xA0, .hi = 0xA0 }, .{ .lo = 0x2000, .hi = 0x200A } });
    } else {
        try r.append(sys.A, .{ .lo = 0, .hi = 0x10FFFF });
    }
    return .{ .ranges = r.items, .neg = neg != flip };
}

const Emit = struct {
    prog: std.ArrayList(Inst) = .empty,
    fi: bool = false,
    fs: bool = false,
    fm: bool = false,

    fn pc(e: *Emit) u32 {
        return @intCast(e.prog.items.len);
    }
    fn add(e: *Emit, i: Inst) anyerror!u32 {
        try e.prog.append(sys.A, i);
        return e.pc() - 1;
    }
    fn node(e: *Emit, n: Node) anyerror!void {
        switch (n) {
            .empty => {},
            .char => |c| _ = try e.add(.{ .char = .{ .c = c, .fold = e.fi } }),
            .any => _ = try e.add(.{ .any = e.fs }),
            .class => |c| _ = try e.add(.{ .class = .{ .c = c, .fold = e.fi } }),
            .bol => _ = try e.add(.{ .bol = e.fm }),
            .eol => _ = try e.add(.{ .eol = e.fm }),
            .bot => _ = try e.add(.bot),
            .eot => _ = try e.add(.eot),
            .wordb => _ = try e.add(.wordb),
            .nwordb => _ = try e.add(.nwordb),
            .concat => |items| for (items) |it| try e.node(it),
            .alt => |alts| {
                var jumps: std.ArrayList(u32) = .empty;
                for (alts, 0..) |a, idx| {
                    if (idx + 1 < alts.len) {
                        const sp = try e.add(.{ .split = .{ .a = 0, .b = 0 } });
                        e.prog.items[sp].split.a = e.pc();
                        try e.node(a);
                        try jumps.append(sys.A, try e.add(.{ .jmp = 0 }));
                        e.prog.items[sp].split.b = e.pc();
                    } else try e.node(a);
                }
                for (jumps.items) |j| e.prog.items[j].jmp = e.pc();
            },
            .group => |g| {
                if (g.idx) |i| _ = try e.add(.{ .save = i * 2 });
                try e.node(g.n.*);
                if (g.idx) |i| _ = try e.add(.{ .save = i * 2 + 1 });
            },
            .flags => |f| {
                const save = .{ e.fi, e.fs, e.fm };
                e.fi = f.i;
                e.fs = f.s;
                e.fm = f.m;
                try e.node(f.n.*);
                e.fi = save[0];
                e.fs = save[1];
                e.fm = save[2];
            },
            .repeat => |r| {
                var k: u32 = 0;
                while (k < r.min) : (k += 1) try e.node(r.n.*);
                if (r.max) |mx| {
                    var ends: std.ArrayList(u32) = .empty;
                    k = r.min;
                    while (k < mx) : (k += 1) {
                        const sp = try e.add(.{ .split = .{ .a = 0, .b = 0 } });
                        try ends.append(sys.A, sp);
                        if (r.greedy) e.prog.items[sp].split.a = e.pc() else e.prog.items[sp].split.b = e.pc();
                        try e.node(r.n.*);
                    }
                    for (ends.items) |sp| {
                        if (r.greedy) e.prog.items[sp].split.b = e.pc() else e.prog.items[sp].split.a = e.pc();
                    }
                } else {
                    const sp = try e.add(.{ .split = .{ .a = 0, .b = 0 } });
                    if (r.greedy) e.prog.items[sp].split.a = e.pc() else e.prog.items[sp].split.b = e.pc();
                    try e.node(r.n.*);
                    _ = try e.add(.{ .jmp = sp });
                    if (r.greedy) e.prog.items[sp].split.b = e.pc() else e.prog.items[sp].split.a = e.pc();
                }
            },
        }
    }
};

var cache: std.StringHashMapUnmanaged(*Regex) = .empty;

pub fn compile(pat: []const u8) anyerror!*Regex {
    if (cache.get(pat)) |r| return r;
    var p: Parser = .{ .s = pat };
    const ast = try p.alt();
    if (p.more()) return p.fail("unexpected )");
    var e: Emit = .{};
    _ = try e.add(.{ .save = 0 });
    try e.node(ast);
    _ = try e.add(.{ .save = 1 });
    _ = try e.add(.match);
    const re = try sys.A.create(Regex);
    while (p.names.items.len < p.ncap) try p.names.append(sys.A, "");
    re.* = .{ .prog = e.prog.items, .ncap = p.ncap, .names = p.names.items };
    try cache.put(sys.A, v.dup(pat), re);
    return re;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn fold(c: u21) u21 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn inClass(c: Class, cp: u21, f: bool) bool {
    var hit = false;
    for (c.ranges) |r| {
        if (cp >= r.lo and cp <= r.hi) {
            hit = true;
            break;
        }
        if (f) {
            const lo = fold(cp);
            const up: u21 = if (cp >= 'a' and cp <= 'z') cp - 32 else cp;
            if ((lo >= r.lo and lo <= r.hi) or (up >= r.lo and up <= r.hi)) {
                hit = true;
                break;
            }
        }
    }
    return hit != c.neg;
}

const Back = struct { pc: u32, sp: usize, restore: bool = false, idx: u32 = 0, val: ?usize = null };

/// Try to match at exactly position `start`. caps has 2*ncap entries.
fn matchAt(re: *const Regex, s: []const u8, start: usize, caps: []?usize, stack: *std.ArrayList(Back)) bool {
    stack.clearRetainingCapacity();
    var pc: u32 = 0;
    var sp: usize = start;
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > 20_000_000) return false;
        var ok = true;
        switch (re.prog[pc]) {
            .char => |c| {
                if (sp < s.len) {
                    const r = v.decodeRune(s[sp..]);
                    if (r.cp == c.c or (c.fold and fold(r.cp) == fold(c.c))) {
                        sp += r.len;
                        pc += 1;
                    } else ok = false;
                } else ok = false;
            },
            .any => |nl| {
                if (sp < s.len and (nl or s[sp] != '\n')) {
                    sp += v.decodeRune(s[sp..]).len;
                    pc += 1;
                } else ok = false;
            },
            .class => |c| {
                if (sp < s.len) {
                    const r = v.decodeRune(s[sp..]);
                    if (inClass(c.c, r.cp, c.fold)) {
                        sp += r.len;
                        pc += 1;
                    } else ok = false;
                } else ok = false;
            },
            .bol => |m| {
                if (sp == 0 or (m and s[sp - 1] == '\n')) pc += 1 else ok = false;
            },
            .eol => |m| {
                if (sp == s.len or (m and s[sp] == '\n')) pc += 1 else ok = false;
            },
            .bot => {
                if (sp == 0) pc += 1 else ok = false;
            },
            .eot => {
                if (sp == s.len) pc += 1 else ok = false;
            },
            .wordb, .nwordb => {
                const a = sp > 0 and isWord(s[sp - 1]);
                const b = sp < s.len and isWord(s[sp]);
                if ((a != b) == (re.prog[pc] == .wordb)) pc += 1 else ok = false;
            },
            .split => |sp2| {
                stack.append(sys.A, .{ .pc = sp2.b, .sp = sp }) catch return false;
                pc = sp2.a;
            },
            .jmp => |t| pc = t,
            .save => |i| {
                stack.append(sys.A, .{ .pc = 0, .sp = 0, .restore = true, .idx = i, .val = caps[i] }) catch return false;
                caps[i] = sp;
                pc += 1;
            },
            .match => return true,
        }
        if (!ok) {
            while (true) {
                const b = stack.pop() orelse return false;
                if (b.restore) {
                    caps[b.idx] = b.val;
                } else {
                    pc = b.pc;
                    sp = b.sp;
                    break;
                }
            }
        }
    }
}

pub const Match = struct {
    caps: []?usize,
    pub fn start(m: Match) usize {
        return m.caps[0].?;
    }
    pub fn end(m: Match) usize {
        return m.caps[1].?;
    }
    pub fn group(m: Match, s: []const u8, i: usize) []const u8 {
        if (i * 2 + 1 >= m.caps.len) return "";
        const a = m.caps[i * 2] orelse return "";
        const b = m.caps[i * 2 + 1] orelse return "";
        return s[a..b];
    }
};

pub fn find(re: *const Regex, s: []const u8, from: usize) ?Match {
    var stack: std.ArrayList(Back) = .empty;
    const caps = sys.A.alloc(?usize, re.ncap * 2) catch return null;
    var i = from;
    while (i <= s.len) {
        for (caps) |*c| c.* = null;
        if (matchAt(re, s, i, caps, &stack)) return .{ .caps = caps };
        if (i >= s.len) break;
        i += v.decodeRune(s[i..]).len;
    }
    return null;
}

pub fn isMatch(re: *const Regex, s: []const u8) bool {
    return find(re, s, 0) != null;
}

/// All non-overlapping matches (limit < 0 = all).
pub fn findAll(re: *const Regex, s: []const u8, limit: i64) []Match {
    var out: std.ArrayList(Match) = .empty;
    var pos: usize = 0;
    while (pos <= s.len) {
        if (limit >= 0 and out.items.len >= @as(usize, @intCast(limit))) break;
        const m = find(re, s, pos) orelse break;
        out.append(sys.A, m) catch break;
        if (m.end() == m.start()) {
            if (m.end() >= s.len) break;
            pos = m.end() + v.decodeRune(s[m.end()..]).len;
        } else pos = m.end();
    }
    return out.items;
}

fn expand(b: *v.Buf, re: *const Regex, s: []const u8, m: Match, repl: []const u8) void {
    var i: usize = 0;
    while (i < repl.len) {
        if (repl[i] == '$' and i + 1 < repl.len) {
            if (repl[i + 1] == '$') {
                b.ch('$');
                i += 2;
                continue;
            }
            var name: []const u8 = "";
            var next = i + 1;
            if (repl[i + 1] == '{') {
                if (v.indexOfPos(repl, i, "}")) |e| {
                    name = repl[i + 2 .. e];
                    next = e + 1;
                }
            } else {
                var e = i + 1;
                while (e < repl.len and (std.ascii.isAlphanumeric(repl[e]) or repl[e] == '_')) e += 1;
                name = repl[i + 1 .. e];
                next = e;
            }
            if (name.len > 0) {
                if (std.fmt.parseInt(usize, name, 10) catch null) |n| {
                    b.add(m.group(s, n));
                } else {
                    for (re.names, 0..) |nm, gi| if (v.eq(nm, name)) b.add(m.group(s, gi));
                }
                i = next;
                continue;
            }
        }
        b.ch(repl[i]);
        i += 1;
    }
}

pub fn replaceAll(re: *const Regex, s: []const u8, repl: []const u8, limit: i64) []const u8 {
    var b: v.Buf = .{};
    var pos: usize = 0;
    for (findAll(re, s, limit)) |m| {
        b.add(s[pos..m.start()]);
        expand(&b, re, s, m, repl);
        pos = m.end();
    }
    b.add(s[pos..]);
    return b.str();
}
