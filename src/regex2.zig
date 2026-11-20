// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: regexp2 (MIT, Copyright Doug Clark).
// The original notices and licences are kept in NOTICE and licenses/.
//! Backtracking regular expression engine with the .NET/regexp2 dialect that
//! Chroma lexers are written in: lookahead and lookbehind, backreferences,
//! atomic groups, named groups, inline flags and (?x) extended mode.
//! Matching is always anchored at the start position (Chroma's `\G`).
const std = @import("std");
const sys = @import("sys.zig");

pub const Error = error{RegexError};
pub var err_msg: []const u8 = "";

const Range = struct { lo: u21, hi: u21 };
const Class = struct {
    ranges: []const Range,
    neg: bool,
    fold: bool,
    // perl classes embedded in a bracket expression
    perl: u8 = 0, // unused
    // categories in order of appearance (regexp2 evaluates them in order, see inClass)
    cats: [6]u8 = .{ 0, 0, 0, 0, 0, 0 }, // 1=\d 2=\D 4=\w 8=\W 16=\s 32=\S
    ncats: u8 = 0,
    anything: bool = false,
};

fn addCat(cls: *Class, bit: u8) void {
    const base: u8 = switch (bit) {
        1, 2 => 1,
        4, 8 => 4,
        else => 16,
    };
    for (cls.cats[0..cls.ncats]) |c| {
        const cb: u8 = switch (c) {
            1, 2 => 1,
            4, 8 => 4,
            else => 16,
        };
        if (cb == base) {
            if (c != bit) cls.anything = true;
            return;
        }
    }
    if (cls.ncats < 6) {
        cls.cats[cls.ncats] = bit;
        cls.ncats += 1;
    }
}

const NONE: u32 = std.math.maxInt(u32);

const Kind = enum { char, any, class, alt1, str, bol, eol, bot, eot, eotnl, gpos, wordb, nwordb, group, alt, repeat, look, backref, atomic, empty };

const Node = struct {
    kind: Kind,
    next: u32 = NONE,
    // payloads
    c: u21 = 0,
    fold: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    class: ?*const Class = null,
    s: []const u8 = "",
    body: u32 = NONE,
    alts: []const u32 = &.{},
    idx: u32 = 0,
    min: u32 = 0,
    max: u32 = NONE,
    greedy: bool = true,
    neg: bool = false,
    behind: bool = false,
    single: bool = false, // repeat body is a single-char matcher
    sets: []const ?*const Set = &.{}, // alt: first-byte set per branch (null = any)
};

pub const Set = std.StaticBitSet(256);

pub const Regex = struct {
    nodes: []Node,
    start: u32,
    first: ?*const Set = null, // bytes a match can start with (null = any / empty match)
    has_backrefs: bool = false,
    backref_groups: []const u32 = &.{},
    ncap: u32,
    names: []const []const u8, // index -> name ("" when unnamed)
};

const Flags = struct { i: bool = false, m: bool = false, s: bool = false, x: bool = false };

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    ncap: u32 = 1,
    names: std.ArrayList([]const u8) = .empty,
    named: std.ArrayList(struct { name: []const u8, node: u32 }) = .empty,
    backref_names: std.ArrayList(struct { name: []const u8, node: u32 }) = .empty,

    fn fail(p: *Parser, msg: []const u8) Error {
        err_msg = std.fmt.allocPrint(sys.A, "{s} in `{s}`", .{ msg, p.s }) catch msg;
        return error.RegexError;
    }
    fn add(p: *Parser, n: Node) !u32 {
        try p.nodes.append(sys.A, n);
        return @intCast(p.nodes.items.len - 1);
    }
    fn more(p: *Parser) bool {
        return p.i < p.s.len;
    }
    fn skipX(p: *Parser, f: Flags) void {
        if (!f.x) return;
        while (p.more()) {
            const c = p.s[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0b' or c == '\x0c') {
                p.i += 1;
            } else if (c == '#') {
                while (p.more() and p.s[p.i] != '\n') p.i += 1;
            } else break;
        }
    }

    /// Returns a sequence (first node index, last node index) whose last node's
    /// `next` is left NONE for the caller to link.
    const Seq = struct { first: u32, last: u32 };

    fn alt(p: *Parser, f: *Flags) anyerror!Seq {
        var branches: std.ArrayList(u32) = .empty;
        var seq = try p.concat(f);
        if (!(p.more() and p.s[p.i] == '|')) return seq;
        // alternation: each branch ends with NONE (continuation handled by the alt node)
        try branches.append(sys.A, seq.first);
        while (p.more() and p.s[p.i] == '|') {
            p.i += 1;
            seq = try p.concat(f);
            try branches.append(sys.A, seq.first);
        }
        var all_single = true;
        for (branches.items) |bi| {
            const bn = p.nodes.items[bi];
            if (bn.next != NONE or !(bn.kind == .char or bn.kind == .class or bn.kind == .any)) all_single = false;
        }
        const n = try p.add(.{ .kind = if (all_single) .alt1 else .alt, .alts = branches.items });
        return .{ .first = n, .last = n };
    }

    fn concat(p: *Parser, f: *Flags) anyerror!Seq {
        var first: u32 = NONE;
        var last: u32 = NONE;
        while (true) {
            p.skipX(f.*);
            if (!p.more() or p.s[p.i] == '|' or p.s[p.i] == ')') break;
            var at = (try p.atom(f)) orelse continue;
            // quantifiers
            while (true) {
                p.skipX(f.*);
                if (!p.more()) break;
                const c = p.s[p.i];
                var min: u32 = 0;
                var max: u32 = NONE;
                if (c == '*') {
                    p.i += 1;
                } else if (c == '+') {
                    min = 1;
                    p.i += 1;
                } else if (c == '?') {
                    max = 1;
                    p.i += 1;
                } else if (c == '{') {
                    const e = std.mem.indexOfScalarPos(u8, p.s, p.i, '}') orelse break;
                    const body = p.s[p.i + 1 .. e];
                    if (body.len == 0 or !std.ascii.isDigit(body[0])) break;
                    if (std.mem.indexOfScalar(u8, body, ',')) |cm| {
                        min = std.fmt.parseInt(u32, body[0..cm], 10) catch break;
                        max = if (cm + 1 == body.len) NONE else std.fmt.parseInt(u32, body[cm + 1 ..], 10) catch break;
                    } else {
                        min = std.fmt.parseInt(u32, body, 10) catch break;
                        max = min;
                    }
                    p.i = e + 1;
                } else break;
                var greedy = true;
                var possessive = false;
                if (p.more() and p.s[p.i] == '?') {
                    greedy = false;
                    p.i += 1;
                } else if (p.more() and p.s[p.i] == '+') {
                    possessive = true;
                    p.i += 1;
                }
                const bn = &p.nodes.items[at.first];
                const is_single = at.first == at.last and (bn.kind == .char or bn.kind == .any or bn.kind == .class or bn.kind == .alt1);
                const r = try p.add(.{ .kind = .repeat, .body = at.first, .min = min, .max = max, .greedy = greedy, .single = is_single });
                at = .{ .first = r, .last = r };
                if (possessive) {
                    const a = try p.add(.{ .kind = .atomic, .body = r });
                    at = .{ .first = a, .last = a };
                }
            }
            if (first == NONE) {
                first = at.first;
            } else p.nodes.items[last].next = at.first;
            last = at.last;
        }
        if (first == NONE) {
            const e = try p.add(.{ .kind = .empty });
            return .{ .first = e, .last = e };
        }
        return .{ .first = first, .last = last };
    }

    fn group(p: *Parser, f: Flags) anyerror!u32 {
        // parses up to and including ')'; returns the body's first node
        var inner_f = f;
        const seq = try p.alt(&inner_f);
        if (!p.more() or p.s[p.i] != ')') return p.fail("missing closing )");
        p.i += 1;
        return seq.first;
    }

    fn atom(p: *Parser, f: *Flags) anyerror!?Seq {
        const c = p.s[p.i];
        switch (c) {
            '(' => {
                p.i += 1;
                if (p.more() and p.s[p.i] == '?') {
                    p.i += 1;
                    if (!p.more()) return p.fail("bad group");
                    const d = p.s[p.i];
                    if (d == ':') {
                        p.i += 1;
                        const b = try p.group(f.*);
                        if (p.nodes.items[b].next == NONE) return .{ .first = b, .last = b };
                        const n = try p.add(.{ .kind = .group, .body = b, .idx = NONE });
                        return .{ .first = n, .last = n };
                    }
                    if (d == '=' or d == '!') {
                        p.i += 1;
                        const b = try p.group(f.*);
                        const n = try p.add(.{ .kind = .look, .body = b, .neg = d == '!' });
                        return .{ .first = n, .last = n };
                    }
                    if (d == '>') {
                        p.i += 1;
                        const b = try p.group(f.*);
                        const n = try p.add(.{ .kind = .atomic, .body = b });
                        return .{ .first = n, .last = n };
                    }
                    if (d == '<' and p.i + 1 < p.s.len and (p.s[p.i + 1] == '=' or p.s[p.i + 1] == '!')) {
                        const neg = p.s[p.i + 1] == '!';
                        p.i += 2;
                        const b = try p.group(f.*);
                        const n = try p.add(.{ .kind = .look, .body = b, .neg = neg, .behind = true });
                        return .{ .first = n, .last = n };
                    }
                    if (d == '<' or d == '\'' or d == 'P') {
                        if (d == 'P') p.i += 1;
                        const close: u8 = if (p.s[p.i] == '\'') '\'' else '>';
                        const e = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, close) orelse return p.fail("bad named group");
                        const name = p.s[p.i + 1 .. e];
                        p.i = e + 1;
                        const idx = p.ncap;
                        p.ncap += 1;
                        const b = try p.group(f.*);
                        const n = try p.add(.{ .kind = .group, .body = b, .idx = idx });
                        try p.named.append(sys.A, .{ .name = name, .node = n });
                        return .{ .first = n, .last = n };
                    }
                    // inline flags
                    var neg = false;
                    var nf = f.*;
                    while (p.more() and p.s[p.i] != ')' and p.s[p.i] != ':') : (p.i += 1) {
                        switch (p.s[p.i]) {
                            '-' => neg = true,
                            'i' => nf.i = !neg,
                            'm' => nf.m = !neg,
                            's' => nf.s = !neg,
                            'x' => nf.x = !neg,
                            'n', 'U', 'u' => {},
                            else => return p.fail("unrecognized grouping construct"),
                        }
                    }
                    if (!p.more()) return p.fail("missing closing )");
                    if (p.s[p.i] == ')') {
                        p.i += 1;
                        f.* = nf; // applies to the rest of the enclosing group
                        return null;
                    }
                    p.i += 1;
                    const b = try p.group(nf);
                    const n = try p.add(.{ .kind = .group, .body = b, .idx = NONE });
                    return .{ .first = n, .last = n };
                }
                const idx = p.ncap;
                p.ncap += 1;
                const b = try p.group(f.*);
                const n = try p.add(.{ .kind = .group, .body = b, .idx = idx });
                return .{ .first = n, .last = n };
            },
            '[' => {
                const cls = try p.class(f.*);
                const n = try p.add(.{ .kind = .class, .class = cls });
                return .{ .first = n, .last = n };
            },
            '.' => {
                p.i += 1;
                const n = try p.add(.{ .kind = .any, .dotall = f.s });
                return .{ .first = n, .last = n };
            },
            '^' => {
                p.i += 1;
                const n = try p.add(.{ .kind = .bol, .multiline = f.m });
                return .{ .first = n, .last = n };
            },
            '$' => {
                p.i += 1;
                const n = try p.add(.{ .kind = .eol, .multiline = f.m });
                return .{ .first = n, .last = n };
            },
            '\\' => return try p.escape(f.*),
            else => {
                const ch = p.cp();
                const n = try p.add(.{ .kind = .char, .c = ch, .fold = f.i });
                return .{ .first = n, .last = n };
            },
        }
    }

    fn cp(p: *Parser) u21 {
        const l = std.unicode.utf8ByteSequenceLength(p.s[p.i]) catch 1;
        if (p.i + l <= p.s.len) {
            if (std.unicode.utf8Decode(p.s[p.i .. p.i + l])) |c| {
                p.i += l;
                return c;
            } else |_| {}
        }
        p.i += 1;
        return p.s[p.i - 1];
    }

    fn hexN(p: *Parser, n: usize) !u21 {
        if (p.i + n > p.s.len) return p.fail("bad escape");
        const x = std.fmt.parseInt(u21, p.s[p.i .. p.i + n], 16) catch return p.fail("bad escape");
        p.i += n;
        return x;
    }

    /// Parses an escape that denotes a single character; returns null if it is
    /// not a character escape.
    fn charEscape(p: *Parser) !?u21 {
        const e = p.s[p.i];
        switch (e) {
            'n' => {
                p.i += 1;
                return '\n';
            },
            't' => {
                p.i += 1;
                return '\t';
            },
            'r' => {
                p.i += 1;
                return '\r';
            },
            'f' => {
                p.i += 1;
                return 0x0c;
            },
            'v' => {
                p.i += 1;
                return 0x0b;
            },
            'a' => {
                p.i += 1;
                return 0x07;
            },
            'e' => {
                p.i += 1;
                return 0x1b;
            },
            '0' => {
                p.i += 1;
                var x: u21 = 0;
                var k: usize = 0;
                while (k < 2 and p.more() and p.s[p.i] >= '0' and p.s[p.i] <= '7') : (k += 1) {
                    x = x * 8 + (p.s[p.i] - '0');
                    p.i += 1;
                }
                return x;
            },
            'x' => {
                p.i += 1;
                if (p.more() and p.s[p.i] == '{') {
                    const end = std.mem.indexOfScalarPos(u8, p.s, p.i, '}') orelse return p.fail("bad escape");
                    const x = std.fmt.parseInt(u21, p.s[p.i + 1 .. end], 16) catch return p.fail("bad escape");
                    p.i = end + 1;
                    return x;
                }
                return try p.hexN(2);
            },
            'u' => {
                p.i += 1;
                return try p.hexN(4);
            },
            'c' => {
                p.i += 1;
                if (!p.more()) return p.fail("bad escape");
                const x = p.s[p.i] & 0x1f;
                p.i += 1;
                return x;
            },
            else => {
                if (std.ascii.isAlphanumeric(e)) return null;
                return p.cp();
            },
        }
    }

    fn escape(p: *Parser, f: Flags) anyerror!?Seq {
        p.i += 1;
        if (!p.more()) return p.fail("trailing backslash");
        const e = p.s[p.i];
        const simple: ?Kind = switch (e) {
            'A' => .bot,
            'z' => .eot,
            'Z' => .eotnl,
            'G' => .gpos,
            'b' => .wordb,
            'B' => .nwordb,
            else => null,
        };
        if (simple) |k| {
            p.i += 1;
            const n = try p.add(.{ .kind = k });
            return .{ .first = n, .last = n };
        }
        switch (e) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                p.i += 1;
                const cls = try sys.A.create(Class);
                cls.* = .{ .ranges = &.{}, .neg = false, .fold = false };
                addCat(cls, perlBit(e));
                const n = try p.add(.{ .kind = .class, .class = cls });
                return .{ .first = n, .last = n };
            },
            'p', 'P' => {
                p.i += 1;
                const cls = try p.unicodeClass(e == 'P', f.i);
                const n = try p.add(.{ .kind = .class, .class = cls });
                return .{ .first = n, .last = n };
            },
            'k' => {
                p.i += 1;
                if (!p.more() or (p.s[p.i] != '<' and p.s[p.i] != '\'' and p.s[p.i] != '{')) return p.fail("bad \\k");
                const close: u8 = switch (p.s[p.i]) {
                    '<' => '>',
                    '{' => '}',
                    else => '\'',
                };
                const end = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, close) orelse return p.fail("bad \\k");
                const name = p.s[p.i + 1 .. end];
                p.i = end + 1;
                const n = try p.add(.{ .kind = .backref, .fold = f.i });
                try p.backref_names.append(sys.A, .{ .name = name, .node = n });
                return .{ .first = n, .last = n };
            },
            '1'...'9' => {
                var x: u32 = 0;
                while (p.more() and std.ascii.isDigit(p.s[p.i])) {
                    x = x * 10 + (p.s[p.i] - '0');
                    p.i += 1;
                }
                const n = try p.add(.{ .kind = .backref, .idx = x, .fold = f.i });
                return .{ .first = n, .last = n };
            },
            else => {},
        }
        const ch = (try p.charEscape()) orelse {
            // unknown letter escape: treat literally (lenient)
            const l = p.s[p.i];
            p.i += 1;
            const n = try p.add(.{ .kind = .char, .c = l, .fold = f.i });
            return .{ .first = n, .last = n };
        };
        const n = try p.add(.{ .kind = .char, .c = ch, .fold = f.i });
        return .{ .first = n, .last = n };
    }

    fn unicodeClass(p: *Parser, neg: bool, fold: bool) !*Class {
        var name: []const u8 = undefined;
        if (p.more() and p.s[p.i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, p.s, p.i, '}') orelse return p.fail("bad \\p");
            name = p.s[p.i + 1 .. end];
            p.i = end + 1;
        } else {
            name = p.s[p.i .. p.i + 1];
            p.i += 1;
        }
        const cls = try sys.A.create(Class);
        cls.* = .{ .ranges = unicodeRanges(name), .neg = neg, .fold = fold };
        return cls;
    }

    fn class(p: *Parser, f: Flags) !*Class {
        p.i += 1; // [
        var neg = false;
        if (p.more() and p.s[p.i] == '^') {
            neg = true;
            p.i += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        const cls = try sys.A.create(Class);
        cls.* = .{ .ranges = &.{}, .neg = false, .fold = f.i };
        var first = true;
        while (p.more() and (p.s[p.i] != ']' or first)) {
            first = false;
            var lo: u21 = undefined;
            if (p.s[p.i] == '\\') {
                p.i += 1;
                if (!p.more()) return p.fail("bad class");
                const e = p.s[p.i];
                switch (e) {
                    'd', 'D', 'w', 'W', 's', 'S' => {
                        addCat(cls, perlBit(e));
                        p.i += 1;
                        continue;
                    },
                    'p', 'P' => {
                        p.i += 1;
                        const u = try p.unicodeClass(false, false);
                        if (e == 'P') {
                            // complement of the ranges
                            var prev: u21 = 0;
                            for (u.ranges) |r| {
                                if (r.lo > prev) try ranges.append(sys.A, .{ .lo = prev, .hi = r.lo - 1 });
                                prev = r.hi +| 1;
                            }
                            if (prev <= 0x10ffff) try ranges.append(sys.A, .{ .lo = prev, .hi = 0x10ffff });
                        } else try ranges.appendSlice(sys.A, u.ranges);
                        continue;
                    },
                    'b' => {
                        p.i += 1;
                        lo = 0x08;
                    },
                    else => lo = (try p.charEscape()) orelse blk: {
                        p.i += 1;
                        break :blk e;
                    },
                }
            } else if (p.s[p.i] == '[' and p.i + 1 < p.s.len and p.s[p.i + 1] == ':') {
                // POSIX class [:alpha:]
                if (std.mem.indexOfPos(u8, p.s, p.i, ":]")) |end| {
                    const nm = p.s[p.i + 2 .. end];
                    if (posix(nm)) |r| {
                        try ranges.appendSlice(sys.A, r);
                        p.i = end + 2;
                        continue;
                    }
                }
                lo = p.cp();
            } else lo = p.cp();
            var hi = lo;
            if (p.i + 1 < p.s.len and p.s[p.i] == '-' and p.s[p.i + 1] != ']') {
                if (p.s[p.i + 1] == '[') {
                    // .NET subtraction: not supported, treat '-' literally
                } else {
                    p.i += 1;
                    if (p.s[p.i] == '\\') {
                        p.i += 1;
                        hi = (try p.charEscape()) orelse blk: {
                            const x = p.s[p.i];
                            p.i += 1;
                            break :blk x;
                        };
                    } else hi = p.cp();
                }
            }
            if (hi < lo) return p.fail("bad class range");
            try ranges.append(sys.A, .{ .lo = lo, .hi = hi });
        }
        if (!p.more()) return p.fail("missing ]");
        p.i += 1;
        cls.ranges = ranges.items;
        cls.neg = neg;
        return cls;
    }
};

fn perlBit(e: u8) u8 {
    return switch (e) {
        'd' => 1,
        'D' => 2,
        'w' => 4,
        'W' => 8,
        's' => 16,
        else => 32,
    };
}

fn posix(nm: []const u8) ?[]const Range {
    const T = struct {
        const alpha = [_]Range{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' } };
        const digit = [_]Range{.{ .lo = '0', .hi = '9' }};
        const alnum = [_]Range{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '0', .hi = '9' } };
        const space = [_]Range{ .{ .lo = 9, .hi = 13 }, .{ .lo = ' ', .hi = ' ' } };
        const upper = [_]Range{.{ .lo = 'A', .hi = 'Z' }};
        const lower = [_]Range{.{ .lo = 'a', .hi = 'z' }};
        const xdigit = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'a', .hi = 'f' }, .{ .lo = 'A', .hi = 'F' } };
        const punct = [_]Range{ .{ .lo = '!', .hi = '/' }, .{ .lo = ':', .hi = '@' }, .{ .lo = '[', .hi = '`' }, .{ .lo = '{', .hi = '~' } };
    };
    if (std.mem.eql(u8, nm, "alpha")) return &T.alpha;
    if (std.mem.eql(u8, nm, "digit")) return &T.digit;
    if (std.mem.eql(u8, nm, "alnum")) return &T.alnum;
    if (std.mem.eql(u8, nm, "space")) return &T.space;
    if (std.mem.eql(u8, nm, "upper")) return &T.upper;
    if (std.mem.eql(u8, nm, "lower")) return &T.lower;
    if (std.mem.eql(u8, nm, "xdigit")) return &T.xdigit;
    if (std.mem.eql(u8, nm, "punct")) return &T.punct;
    return null;
}

fn unicodeRanges(name: []const u8) []const Range {
    const T = struct {
        const L = [_]Range{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0xaa, .hi = 0xaa }, .{ .lo = 0xb5, .hi = 0xb5 }, .{ .lo = 0xba, .hi = 0xba }, .{ .lo = 0xc0, .hi = 0xd6 }, .{ .lo = 0xd8, .hi = 0xf6 }, .{ .lo = 0xf8, .hi = 0x2c1 }, .{ .lo = 0x370, .hi = 0x3ff }, .{ .lo = 0x400, .hi = 0x52f }, .{ .lo = 0x531, .hi = 0x587 }, .{ .lo = 0x5d0, .hi = 0x5ea }, .{ .lo = 0x620, .hi = 0x64a }, .{ .lo = 0x904, .hi = 0x939 }, .{ .lo = 0x1e00, .hi = 0x1fff }, .{ .lo = 0x3040, .hi = 0x30ff }, .{ .lo = 0x3400, .hi = 0x4dbf }, .{ .lo = 0x4e00, .hi = 0x9fff }, .{ .lo = 0xac00, .hi = 0xd7a3 } };
        const Lu = [_]Range{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 0xc0, .hi = 0xd6 }, .{ .lo = 0xd8, .hi = 0xde }, .{ .lo = 0x391, .hi = 0x3a9 }, .{ .lo = 0x410, .hi = 0x42f } };
        const Ll = [_]Range{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0xdf, .hi = 0xf6 }, .{ .lo = 0xf8, .hi = 0xff }, .{ .lo = 0x3b1, .hi = 0x3c9 }, .{ .lo = 0x430, .hi = 0x44f } };
        const N = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 0xb2, .hi = 0xb3 }, .{ .lo = 0xb9, .hi = 0xb9 }, .{ .lo = 0xbc, .hi = 0xbe }, .{ .lo = 0x660, .hi = 0x669 } };
        const Nd = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 0x660, .hi = 0x669 } };
        const Lt = [_]Range{ .{ .lo = 0x1c5, .hi = 0x1c5 }, .{ .lo = 0x1c8, .hi = 0x1c8 }, .{ .lo = 0x1cb, .hi = 0x1cb } };
        const Lm = [_]Range{ .{ .lo = 0x2b0, .hi = 0x2c1 }, .{ .lo = 0x3005, .hi = 0x3005 } };
        const Lo = [_]Range{ .{ .lo = 0xaa, .hi = 0xaa }, .{ .lo = 0xba, .hi = 0xba }, .{ .lo = 0x5d0, .hi = 0x5ea }, .{ .lo = 0x620, .hi = 0x64a }, .{ .lo = 0x3040, .hi = 0x30ff }, .{ .lo = 0x4e00, .hi = 0x9fff } };
        const Nl = [_]Range{ .{ .lo = 0x16ee, .hi = 0x16f0 }, .{ .lo = 0x2160, .hi = 0x2188 } };
        const Mn = [_]Range{ .{ .lo = 0x300, .hi = 0x36f }, .{ .lo = 0x483, .hi = 0x487 }, .{ .lo = 0x591, .hi = 0x5bd } };
        const Mc = [_]Range{ .{ .lo = 0x903, .hi = 0x903 }, .{ .lo = 0x93b, .hi = 0x93b } };
        const Pc = [_]Range{ .{ .lo = '_', .hi = '_' }, .{ .lo = 0x203f, .hi = 0x2040 } };
        const Cf = [_]Range{ .{ .lo = 0xad, .hi = 0xad }, .{ .lo = 0x200b, .hi = 0x200f } };
        const Zs = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = 0xa0, .hi = 0xa0 }, .{ .lo = 0x2000, .hi = 0x200a }, .{ .lo = 0x3000, .hi = 0x3000 } };
        const P = [_]Range{ .{ .lo = '!', .hi = '#' }, .{ .lo = '%', .hi = '*' }, .{ .lo = ',', .hi = '/' }, .{ .lo = ':', .hi = ';' }, .{ .lo = '?', .hi = '@' }, .{ .lo = '[', .hi = ']' }, .{ .lo = '_', .hi = '_' }, .{ .lo = '{', .hi = '{' }, .{ .lo = '}', .hi = '}' }, .{ .lo = 0xa1, .hi = 0xa1 }, .{ .lo = 0xa7, .hi = 0xa7 }, .{ .lo = 0xab, .hi = 0xab }, .{ .lo = 0xb6, .hi = 0xb7 }, .{ .lo = 0xbb, .hi = 0xbb }, .{ .lo = 0xbf, .hi = 0xbf }, .{ .lo = 0x2010, .hi = 0x2027 } };
        const S = [_]Range{ .{ .lo = '$', .hi = '$' }, .{ .lo = '+', .hi = '+' }, .{ .lo = '<', .hi = '>' }, .{ .lo = '^', .hi = '^' }, .{ .lo = '`', .hi = '`' }, .{ .lo = '|', .hi = '|' }, .{ .lo = '~', .hi = '~' }, .{ .lo = 0xa2, .hi = 0xa6 }, .{ .lo = 0xa8, .hi = 0xa9 }, .{ .lo = 0xac, .hi = 0xac }, .{ .lo = 0xae, .hi = 0xb1 }, .{ .lo = 0xb4, .hi = 0xb4 }, .{ .lo = 0xd7, .hi = 0xd7 }, .{ .lo = 0xf7, .hi = 0xf7 }, .{ .lo = 0x2190, .hi = 0x21ff }, .{ .lo = 0x2200, .hi = 0x22ff } };
        const Sm = [_]Range{ .{ .lo = '+', .hi = '+' }, .{ .lo = '<', .hi = '>' }, .{ .lo = '|', .hi = '|' }, .{ .lo = '~', .hi = '~' }, .{ .lo = 0xac, .hi = 0xac }, .{ .lo = 0xb1, .hi = 0xb1 }, .{ .lo = 0xd7, .hi = 0xd7 }, .{ .lo = 0xf7, .hi = 0xf7 }, .{ .lo = 0x2200, .hi = 0x22ff } };
        const Z = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = 0xa0, .hi = 0xa0 }, .{ .lo = 0x2000, .hi = 0x200a }, .{ .lo = 0x2028, .hi = 0x2029 }, .{ .lo = 0x3000, .hi = 0x3000 } };
        const Han = [_]Range{ .{ .lo = 0x3400, .hi = 0x4dbf }, .{ .lo = 0x4e00, .hi = 0x9fff }, .{ .lo = 0xf900, .hi = 0xfaff } };
        const none = [_]Range{};
    };
    const map = .{
        .{ "L", &T.L },   .{ "Lu", &T.Lu }, .{ "Ll", &T.Ll }, .{ "Lt", &T.Lt }, .{ "Lm", &T.Lm }, .{ "Lo", &T.Lo }, .{ "N", &T.N }, .{ "Nd", &T.Nd }, .{ "Nl", &T.Nl },
        .{ "Mn", &T.Mn }, .{ "Mc", &T.Mc }, .{ "Pc", &T.Pc }, .{ "Cf", &T.Cf }, .{ "Zs", &T.Zs }, .{ "P", &T.P }, .{ "S", &T.S }, .{ "Sm", &T.Sm }, .{ "Z", &T.Z },
        .{ "Han", &T.Han }, .{ "IsCJKUnifiedIdeographs", &T.Han }, .{ "Letter", &T.L },
    };
    inline for (map) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return &T.none;
}

pub fn compile(pat: []const u8) anyerror!*Regex {
    var p = Parser{ .s = pat };
    var f = Flags{};
    const seq = try p.alt(&f);
    if (p.more()) return p.fail("unexpected )");
    // resolve names
    const names = try sys.A.alloc([]const u8, p.ncap);
    @memset(names, "");
    for (p.named.items) |nm| names[p.nodes.items[nm.node].idx] = nm.name;
    // .NET numbers named groups after the unnamed ones
    if (p.named.items.len > 0) {
        var order: std.ArrayList(u32) = .empty;
        var next: u32 = 1;
        // renumber: unnamed groups first (in order), then named
        const remap = try sys.A.alloc(u32, p.ncap);
        for (0..p.ncap) |i| remap[i] = @intCast(i);
        for (p.nodes.items) |*n| _ = n;
        // collect capture idxs in order of appearance (by index)
        var is_named = try sys.A.alloc(bool, p.ncap);
        @memset(is_named, false);
        for (p.named.items) |nm| is_named[p.nodes.items[nm.node].idx] = true;
        for (1..p.ncap) |i| if (!is_named[i]) {
            remap[i] = next;
            next += 1;
        };
        for (1..p.ncap) |i| if (is_named[i]) {
            remap[i] = next;
            next += 1;
            try order.append(sys.A, @intCast(i));
        };
        for (p.nodes.items) |*n| if (n.kind == .group and n.idx != NONE) {
            n.idx = remap[n.idx];
        };
        for (p.nodes.items) |*n| if (n.kind == .backref and n.idx != 0 and n.idx < p.ncap) {
            n.idx = remap[n.idx];
        };
        @memset(names, "");
        for (p.named.items) |nm| names[p.nodes.items[nm.node].idx] = nm.name;
    }
    for (p.backref_names.items) |br| {
        var found: ?u32 = null;
        for (names, 0..) |nm, i| if (std.mem.eql(u8, nm, br.name)) {
            found = @intCast(i);
        };
        if (found == null) {
            found = std.fmt.parseInt(u32, br.name, 10) catch return p.fail("reference to undefined group");
        }
        p.nodes.items[br.node].idx = found.?;
    }
    const re = try sys.A.create(Regex);
    re.* = .{ .nodes = p.nodes.items, .start = seq.first, .ncap = p.ncap, .names = names };
    var brg: std.ArrayList(u32) = .empty;
    for (p.nodes.items) |n| if (n.kind == .backref and n.idx < p.ncap) {
        re.has_backrefs = true;
        try brg.append(sys.A, n.idx);
    };
    re.backref_groups = brg.items;
    for (p.nodes.items) |*n| if (n.kind == .look and n.behind) {
        n.max = maxWidth(p.nodes.items, n.body, 0);
    };
    var fs = FirstSets{ .nodes = p.nodes.items };
    re.first = try fs.seq(seq.first, null, 0);
    return re;
}

/// Maximum number of codepoints a sequence can match (NONE = unbounded).
fn maxWidth(nodes: []Node, start: u32, depth: u32) u32 {
    if (depth > 64) return NONE;
    var total: u64 = 0;
    var ni = start;
    while (ni != NONE) {
        const n = &nodes[ni];
        const w: u64 = switch (n.kind) {
            .char, .any, .class, .alt1 => 1,
            .str => n.s.len,
            .empty, .bol, .eol, .bot, .eot, .eotnl, .gpos, .wordb, .nwordb, .look => 0,
            .group, .atomic => maxWidth(nodes, n.body, depth + 1),
            .alt => blk: {
                var m: u64 = 0;
                for (n.alts) |a| m = @max(m, maxWidth(nodes, a, depth + 1));
                break :blk m;
            },
            .repeat => blk: {
                if (n.max == NONE) break :blk NONE;
                const bw = maxWidth(nodes, n.body, depth + 1);
                if (bw == NONE) break :blk NONE;
                break :blk @as(u64, bw) * n.max;
            },
            .backref => NONE,
        };
        if (w >= NONE) return NONE;
        total += w;
        if (total >= NONE) return NONE;
        ni = n.next;
    }
    return @intCast(total);
}

// ================================================================ first-byte sets

const FirstSets = struct {
    nodes: []Node,

    fn unionOf(a: ?*const Set, b: ?*const Set) !?*const Set {
        const x = a orelse return null;
        const y = b orelse return null;
        const o = try sys.A.create(Set);
        o.* = x.unionWith(y.*);
        return o;
    }

    fn cpSet(set: *Set, c: u21) void {
        var buf: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(c, &buf) catch {
            set.set(@intCast(c & 0xff));
            return;
        };
        _ = l;
        set.set(buf[0]);
    }

    /// Set of bytes a match of the sequence starting at `ni` can begin with,
    /// given `follow` for what follows the sequence. null = unconstrained.
    fn seq(f: *FirstSets, ni: u32, follow: ?*const Set, depth: u32) anyerror!?*const Set {
        if (depth > 64) return null;
        if (ni == NONE) return follow;
        const n = &f.nodes[ni];
        const after = struct {
            fn get(ff: *FirstSets, nn: *Node, c: ?*const Set, d: u32) anyerror!?*const Set {
                return ff.seq(nn.next, c, d + 1);
            }
        }.get;
        switch (n.kind) {
            .empty, .bol, .eol, .bot, .eot, .eotnl, .gpos, .wordb, .nwordb, .look => return after(f, n, follow, depth),
            .char => {
                const o = try sys.A.create(Set);
                o.* = Set.empty;
                cpSet(o, n.c);
                if (n.fold) {
                    cpSet(o, lowerCp(n.c));
                    if (n.c < 128 and std.ascii.isAlphabetic(@intCast(n.c))) {
                        o.set(std.ascii.toUpper(@intCast(n.c)));
                        o.set(std.ascii.toLower(@intCast(n.c)));
                    } else if (n.c >= 128) return null;
                }
                return o;
            },
            .any => return null,
            .alt1 => {
                var acc: ?*const Set = null;
                for (n.alts, 0..) |a, k| {
                    const st = try f.seq(a, null, depth + 1);
                    acc = if (k == 0) st else try unionOf(acc, st);
                }
                return acc;
            },
            .class => {
                const o = try sys.A.create(Set);
                o.* = Set.empty;
                for (0..128) |b| if (inClass(n.class.?, @intCast(b))) o.set(b);
                for (128..256) |b| o.set(b);
                return o;
            },
            .str => {
                if (n.s.len == 0) return after(f, n, follow, depth);
                const o = try sys.A.create(Set);
                o.* = Set.empty;
                o.set(n.s[0]);
                return o;
            },
            .group, .atomic => {
                const nx = try after(f, n, follow, depth);
                return f.seq(n.body, nx, depth + 1);
            },
            .alt => {
                const nx = try after(f, n, follow, depth);
                const sets = try sys.A.alloc(?*const Set, n.alts.len);
                var acc: ?*const Set = null;
                for (n.alts, 0..) |a, k| {
                    sets[k] = try f.seq(a, nx, depth + 1);
                    acc = if (k == 0) sets[k] else try unionOf(acc, sets[k]);
                }
                n.sets = sets;
                return acc;
            },
            .repeat => {
                const nx = try after(f, n, follow, depth);
                const b = try f.seq(n.body, null, depth + 1);
                if (n.min == 0) return unionOf(b, nx);
                return b;
            },
            .backref => return null,
        }
    }
};

// ================================================================ matching

const K = struct {
    tag: enum { root, next, close, rep, look_end, atomic_end },
    node: u32 = NONE, // node whose `next` to continue with
    parent: ?*const K = null,
    idx: u32 = 0,
    count: u32 = 0,
    start: usize = 0,
    target: usize = 0, // look_end: required end position for lookbehind
};

const M = struct {
    re: *const Regex,
    s: []const u8,
    gpos: usize,
    caps: []isize, // 2*ncap, -1 = unset
    end: usize = 0,
    steps: usize = 0,
    budget_hit: bool = false,
    memo: ?*std.AutoHashMapUnmanaged(MemoKey, void) = null,
};

const MemoKey = struct { ni: u32, count: u32, i: usize, k: usize, kc: u32, ks: usize, bh: u64 };
const MEMO_AFTER: usize = 20_000;

fn decodeAt(s: []const u8, i: usize) struct { c: u21, l: usize } {
    const b = s[i];
    if (b < 0x80) return .{ .c = b, .l = 1 };
    const l = std.unicode.utf8ByteSequenceLength(b) catch return .{ .c = b, .l = 1 };
    if (i + l > s.len) return .{ .c = b, .l = 1 };
    const c = std.unicode.utf8Decode(s[i .. i + l]) catch return .{ .c = b, .l = 1 };
    return .{ .c = c, .l = l };
}

fn prevStart(s: []const u8, i: usize) usize {
    var j = i - 1;
    var k: usize = 0;
    while (j > 0 and k < 3 and (s[j] & 0xc0) == 0x80) : (k += 1) j -= 1;
    return j;
}

pub fn lowerCp(c: u21) u21 {
    if (c < 0x80) return if (c >= 'A' and c <= 'Z') c + 32 else c;
    if ((c >= 0xc0 and c <= 0xde and c != 0xd7) or (c >= 0x391 and c <= 0x3ab) or (c >= 0x410 and c <= 0x42f)) return c + 32;
    if (c >= 0x400 and c <= 0x40f) return c + 80;
    if (c >= 0x100 and c <= 0x17f and c % 2 == 0) return c + 1;
    return c;
}

fn isWordCp(c: u21) bool {
    if (c < 0x80) return std.ascii.isAlphanumeric(@intCast(c)) or c == '_';
    return isLetterish(c);
}
fn isLetterish(c: u21) bool {
    if (c == 0xd7 or c == 0xf7) return false;
    if (c >= 0x80 and c <= 0xbf) return c == 0xaa or c == 0xb5 or c == 0xba;
    if (c >= 0x2000 and c <= 0x2bff) return false; // punctuation, symbols, arrows
    if (c >= 0x3000 and c <= 0x303f) return false;
    if (c >= 0xff00 and c <= 0xff0f) return false;
    return true;
}
fn isSpaceCp(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x85, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => c >= 0x2000 and c <= 0x200a,
    };
}
fn isDigitCp(c: u21) bool {
    return (c >= '0' and c <= '9') or (c >= 0x660 and c <= 0x669) or (c >= 0xff10 and c <= 0xff19);
}

fn inClass(cls: *const Class, c0: u21) bool {
    var hit = cls.anything;
    if (!hit) {
        for (cls.ranges) |r| if (c0 >= r.lo and c0 <= r.hi) {
            hit = true;
            break;
        };
        if (!hit and cls.fold) {
            const lc = lowerCp(c0);
            for (cls.ranges) |r| {
                if (lc >= r.lo and lc <= r.hi) {
                    hit = true;
                    break;
                }
                // upper-case variant of a lower-case char
                if (r.lo <= 'z' and r.hi >= 'a') {
                    const lo = @max(r.lo, 'a');
                    const hi = @min(r.hi, 'z');
                    if (c0 >= lo - 32 and c0 <= hi - 32) {
                        hit = true;
                        break;
                    }
                }
                if (lowerCp(r.lo) == lc and r.lo == r.hi) {
                    hit = true;
                    break;
                }
            }
        }
    }
    if (!hit and cls.ncats > 0) hit = catsMatch(cls, c0);
    return hit != cls.neg;
}

/// regexp2's charInCategories, including its early return: a positive test
/// that fails a member check... returns at the first category that decides.
fn catsMatch(cls: *const Class, c: u21) bool {
    for (cls.cats[0..cls.ncats]) |cat| {
        const negate = cat == 2 or cat == 8 or cat == 32;
        const member = switch (cat) {
            1, 2 => isDigitCp(c),
            4, 8 => isWordCp(c),
            else => isSpaceCp(c),
        };
        if (member) return !negate;
        if (negate) return true;
    }
    return false;
}

/// Matches a single-character node at i; returns its byte length or null.
fn single(m: *M, n: *const Node, i: usize) ?usize {
    if (i >= m.s.len) return null;
    const d = decodeAt(m.s, i);
    switch (n.kind) {
        .char => {
            if (d.c == n.c or (n.fold and lowerCp(d.c) == lowerCp(n.c))) return d.l;
            return null;
        },
        .any => {
            if (!n.dotall and d.c == '\n') return null;
            return d.l;
        },
        .class => return if (inClass(n.class.?, d.c)) d.l else null,
        .alt1 => {
            for (n.alts) |a| if (single(m, &m.re.nodes[a], i)) |l| return l;
            return null;
        },
        else => return null,
    }
}

fn wordAt(s: []const u8, i: usize) bool {
    if (i >= s.len) return false;
    return isWordCp(decodeAt(s, i).c);
}
fn wordBefore(s: []const u8, i: usize) bool {
    if (i == 0) return false;
    return isWordCp(decodeAt(s, prevStart(s, i)).c);
}

const MAX_STEPS: usize = 2_000_000;

fn cont(m: *M, k: *const K, i: usize) bool {
    switch (k.tag) {
        .root => {
            m.end = i;
            return true;
        },
        .next => return run(m, m.re.nodes[k.node].next, i, k.parent.?),
        .close => {
            const old_s = m.caps[2 * k.idx];
            const old_e = m.caps[2 * k.idx + 1];
            m.caps[2 * k.idx] = @intCast(k.start);
            m.caps[2 * k.idx + 1] = @intCast(i);
            if (run(m, m.re.nodes[k.node].next, i, k.parent.?)) return true;
            m.caps[2 * k.idx] = old_s;
            m.caps[2 * k.idx + 1] = old_e;
            return false;
        },
        .rep => {
            // an iteration of node k.node finished at i, started at k.start
            // .NET: an empty iteration is accepted but ends the loop
            if (i == k.start and k.count > m.re.nodes[k.node].min) return run(m, m.re.nodes[k.node].next, i, k.parent.?);
            return repeat(m, k.node, k.count, i, k.parent.?);
        },
        .look_end => {
            if (k.target != std.math.maxInt(usize) and i != k.target) return false;
            m.end = i;
            return true;
        },
        .atomic_end => {
            m.end = i;
            return true;
        },
    }
}

fn repeat(m: *M, ni: u32, count: u32, i: usize, k: *const K) bool {
    const n = &m.re.nodes[ni];
    // failure memo for pathological backtracking (only once a match gets expensive)
    if (m.steps > MEMO_AFTER and n.max == NONE) {
        var bh: u64 = 0;
        for (m.re.backref_groups) |g| {
            bh = bh *% 1000003 +% @as(u64, @bitCast(@as(i64, m.caps[2 * g])));
            bh = bh *% 1000003 +% @as(u64, @bitCast(@as(i64, m.caps[2 * g + 1])));
        }
        const key = MemoKey{ .ni = ni, .count = @min(count, n.min), .i = i, .k = @intFromPtr(k), .kc = k.count, .ks = k.start, .bh = bh };
        if (m.memo == null) {
            m.memo = sys.A.create(std.AutoHashMapUnmanaged(MemoKey, void)) catch null;
            if (m.memo) |mm| mm.* = .empty;
        }
        if (m.memo) |mm| {
            if (mm.contains(key)) return false;
            const r = repeatInner(m, ni, count, i, k);
            if (!r and !m.budget_hit) mm.put(sys.A, key, {}) catch {};
            return r;
        }
    }
    return repeatInner(m, ni, count, i, k);
}

fn repeatInner(m: *M, ni: u32, count: u32, i: usize, k: *const K) bool {
    const n = &m.re.nodes[ni];
    const can_more = n.max == NONE or count < n.max;
    if (n.greedy) {
        if (can_more) {
            const kk = K{ .tag = .rep, .node = ni, .count = count + 1, .start = i, .parent = k };
            if (run(m, n.body, i, &kk)) return true;
        }
        if (count >= n.min) return run(m, n.next, i, k);
        return false;
    } else {
        if (count >= n.min and run(m, n.next, i, k)) return true;
        if (can_more) {
            const kk = K{ .tag = .rep, .node = ni, .count = count + 1, .start = i, .parent = k };
            return run(m, n.body, i, &kk);
        }
        return false;
    }
}

fn run(m: *M, ni_start: u32, i_start: usize, k: *const K) bool {
    var ni = ni_start;
    var i = i_start;
    while (true) {
        m.steps += 1;
        if (m.steps > MAX_STEPS) {
            m.budget_hit = true;
            return false;
        }
        if (ni == NONE) return cont(m, k, i);
        const n = &m.re.nodes[ni];
        switch (n.kind) {
            .empty => {},
            .char, .any, .class, .alt1 => {
                i += single(m, n, i) orelse return false;
            },
            .str => {
                if (!std.mem.startsWith(u8, m.s[i..], n.s)) return false;
                i += n.s.len;
            },
            .bol => {
                if (!(i == 0 or (n.multiline and m.s[i - 1] == '\n'))) return false;
            },
            .eol => {
                const ok = i == m.s.len or (m.s[i] == '\n' and (n.multiline or i + 1 == m.s.len));
                if (!ok) return false;
            },
            .bot => if (i != 0) return false,
            .eot => if (i != m.s.len) return false,
            .eotnl => if (!(i == m.s.len or (i + 1 == m.s.len and m.s[i] == '\n'))) return false,
            .gpos => if (i != m.gpos) return false,
            .wordb => if (wordBefore(m.s, i) == wordAt(m.s, i)) return false,
            .nwordb => if (wordBefore(m.s, i) != wordAt(m.s, i)) return false,
            .group => {
                if (n.idx == NONE) {
                    const kk = K{ .tag = .next, .node = ni, .parent = k };
                    return run(m, n.body, i, &kk);
                }
                const kk = K{ .tag = .close, .node = ni, .idx = n.idx, .start = i, .parent = k };
                return run(m, n.body, i, &kk);
            },
            .alt => {
                const kk = K{ .tag = .next, .node = ni, .parent = k };
                for (n.alts, 0..) |a, ai| {
                    if (n.sets.len > 0) if (n.sets[ai]) |st| {
                        if (i >= m.s.len or !st.isSet(m.s[i])) continue;
                    };
                    if (run(m, a, i, &kk)) return true;
                    if (m.budget_hit) return false;
                }
                return false;
            },
            .repeat => {
                if (n.single) {
                    const b = &m.re.nodes[n.body];
                    if (n.greedy) {
                        var cnt: u32 = 0;
                        var j = i;
                        while (n.max == NONE or cnt < n.max) {
                            const l = single(m, b, j) orelse break;
                            j += l;
                            cnt += 1;
                        }
                        if (cnt < n.min) return false;
                        while (true) {
                            if (n.next == NONE) {
                                if (cont(m, k, j)) return true;
                            } else if (run(m, n.next, j, k)) return true;
                            if (m.budget_hit) return false;
                            if (cnt == n.min) return false;
                            j = prevStart(m.s, j);
                            cnt -= 1;
                        }
                    } else {
                        var cnt: u32 = 0;
                        var j = i;
                        while (cnt < n.min) : (cnt += 1) j += single(m, b, j) orelse return false;
                        while (true) {
                            if (run(m, n.next, j, k)) return true;
                            if (m.budget_hit) return false;
                            if (n.max != NONE and cnt >= n.max) return false;
                            j += single(m, b, j) orelse return false;
                            cnt += 1;
                        }
                    }
                }
                return repeat(m, ni, 0, i, k);
            },
            .look => {
                const saved = m.end;
                var ok = false;
                if (!n.behind) {
                    const kk = K{ .tag = .look_end, .target = std.math.maxInt(usize) };
                    ok = run(m, n.body, i, &kk);
                } else {
                    const kk = K{ .tag = .look_end, .target = i };
                    var st = i;
                    var back: u32 = 0;
                    while (true) {
                        if (run(m, n.body, st, &kk)) {
                            ok = true;
                            break;
                        }
                        if (st == 0 or m.budget_hit or back >= n.max) break;
                        st = prevStart(m.s, st);
                        back += 1;
                    }
                }
                m.end = saved;
                if (m.budget_hit) return false;
                if (ok == n.neg) return false;
            },
            .atomic => {
                const saved = m.end;
                const kk = K{ .tag = .atomic_end };
                if (!run(m, n.body, i, &kk)) return false;
                i = m.end;
                m.end = saved;
            },
            .backref => {
                if (n.idx >= m.re.ncap) return false;
                const s0 = m.caps[2 * n.idx];
                const e0 = m.caps[2 * n.idx + 1];
                if (s0 < 0 or e0 < 0) return false; // .NET: unset group fails
                const sub = m.s[@intCast(s0)..@intCast(e0)];
                if (i + sub.len > m.s.len) return false;
                if (n.fold) {
                    if (!std.ascii.eqlIgnoreCase(m.s[i .. i + sub.len], sub)) return false;
                } else if (!std.mem.eql(u8, m.s[i .. i + sub.len], sub)) return false;
                i += sub.len;
            },
        }
        ni = n.next;
    }
}

pub const Match = struct { end: usize, caps: []isize };

/// Anchored match at `pos`. Captures are byte offsets (-1 when unset).
pub fn matchAt(re: *const Regex, s: []const u8, pos: usize, caps: []isize) ?usize {
    if (re.first) |st| if (pos >= s.len or !st.isSet(s[pos])) return null;
    @memset(caps, -1);
    var m = M{ .re = re, .s = s, .gpos = pos, .caps = caps };
    const k = K{ .tag = .root };
    if (!run(&m, re.start, pos, &k)) return null;
    caps[0] = @intCast(pos);
    caps[1] = @intCast(m.end);
    return m.end;
}
