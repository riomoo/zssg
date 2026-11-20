// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors); Chroma (MIT, Copyright Alec Thomas).
// The original notices and licences are kept in NOTICE and licenses/.
//! Hugo's markup/highlight on top of the Chroma port in chroma.zig: site
//! configuration, per-block options (code fence attributes, `highlight`
//! shortcode and transform.Highlight options) and the HTML wrapping.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const chroma = @import("chroma.zig");

const LineNos = union(enum) { off, on, inline_, table };

pub const Config = struct {
    style: []const u8 = "monokai",
    code_fences: bool = true,
    wrapper_class: []const u8 = "highlight",
    no_classes: bool = true,
    line_nos: LineNos = .off,
    line_numbers_in_table: bool = true,
    anchor_line_nos: bool = false,
    line_anchors: []const u8 = "",
    line_no_start: i64 = 1,
    hl_lines: []const u8 = "",
    hl_inline: bool = false,
    hl_parsed: ?[]const [2]i64 = null,
    tab_width: i64 = 4,
    guess_syntax: bool = false,
};

pub var cfg: Config = .{};

// kept for callers that only toggle these
pub var use_classes = false;
pub var code_fences = true;

fn weakBool(x: Value) bool {
    return switch (x) {
        .bool => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .str => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "t"),
        else => false,
    };
}
const Value = v.Value;

fn weakInt(x: Value, def: i64) i64 {
    return switch (x) {
        .int => |i| i,
        .float => |f| @intFromFloat(f),
        .bool => |b| @intFromBool(b),
        .str => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch def,
        else => def,
    };
}

/// One option, with the key already lower-cased (mapstructure.WeakDecode).
fn applyOne(c: *Config, k: []const u8, x: Value) void {
    if (std.mem.eql(u8, k, "style")) c.style = v.toStr(x) else if (std.mem.eql(u8, k, "codefences")) c.code_fences = weakBool(x) else if (std.mem.eql(u8, k, "wrapperclass")) c.wrapper_class = v.toStr(x) else if (std.mem.eql(u8, k, "noclasses")) c.no_classes = weakBool(x) else if (std.mem.eql(u8, k, "linenos")) {
        c.line_nos = switch (x) {
            .bool => |b| if (b) .on else .off,
            .str => |s| if (std.mem.eql(u8, s, "inline")) .inline_ else if (std.mem.eql(u8, s, "table")) .table else if (weakBool(x)) .on else .off,
            else => if (weakBool(x)) .on else .off,
        };
    } else if (std.mem.eql(u8, k, "linenumbersintable")) c.line_numbers_in_table = weakBool(x) else if (std.mem.eql(u8, k, "anchorlinenos")) c.anchor_line_nos = weakBool(x) else if (std.mem.eql(u8, k, "lineanchors")) c.line_anchors = v.toStr(x) else if (std.mem.eql(u8, k, "linenostart")) c.line_no_start = weakInt(x, 1) else if (std.mem.eql(u8, k, "hl_lines")) c.hl_lines = v.toStr(x) else if (std.mem.eql(u8, k, "hl_inline")) c.hl_inline = weakBool(x) else if (std.mem.eql(u8, k, "tabwidth")) c.tab_width = weakInt(x, 4) else if (std.mem.eql(u8, k, "guesssyntax")) c.guess_syntax = weakBool(x);
}

pub const Opt = struct { key: []const u8, val: Value, ranges: ?[]const [2]i64 = null };

/// normalizeHighlightOptions + applyOptionsFromMap.
fn applyOpts(c: *Config, opts: []const Opt) void {
    var base: i64 = 1;
    for (opts) |o| if (std.mem.eql(u8, v.lower(o.key), "linenostart")) {
        base = weakInt(o.val, 1);
    };
    for (opts) |o| {
        const k = v.lower(o.key);
        if (std.mem.eql(u8, k, "linenos")) {
            if (o.val == .str) {
                const s = o.val.str;
                if (std.mem.eql(u8, s, "table") or std.mem.eql(u8, s, "inline")) c.line_numbers_in_table = std.mem.eql(u8, s, "table");
                c.line_nos = if (!std.mem.eql(u8, s, "false")) .on else .off;
                continue;
            }
        }
        if (std.mem.eql(u8, k, "hl_lines")) if (o.ranges) |rs| {
            const adj = sys.A.alloc([2]i64, rs.len) catch continue;
            for (rs, 0..) |r, i| adj[i] = .{ r[0] + base, r[1] + base };
            c.hl_parsed = adj;
            continue;
        };
        applyOne(c, k, o.val);
    }
}

fn parseOptionString(s0: []const u8) []Opt {
    var out: std.ArrayList(Opt) = .empty;
    const s = std.mem.trim(u8, s0, " ");
    if (s.len == 0) return out.items;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |kv| {
        var parts = std.mem.splitScalar(u8, kv, '=');
        const key = std.mem.trim(u8, parts.first(), " ");
        const val = parts.next() orelse continue;
        if (parts.next() != null) continue;
        out.append(sys.A, .{ .key = key, .val = v.S(val) }) catch {};
    }
    return out.items;
}

/// Site configuration ([markup.highlight] plus legacy pygments* keys).
pub fn configure(h: ?*v.Map, site_cfg: *v.Map) void {
    cfg = .{};
    if (h) |m| {
        for (m.m.keys(), m.m.values()) |k, x| applyOne(&cfg, v.lower(k), x);
    }
    if (std.mem.eql(u8, cfg.style, "monokai")) if (site_cfg.str("pygmentsStyle")) |s| if (s.len > 0) {
        cfg.style = s;
    };
    if (cfg.no_classes) if (site_cfg.get("pygmentsUseClasses")) |x| {
        cfg.no_classes = !weakBool(x);
    };
    if (cfg.code_fences) if (site_cfg.get("pygmentsCodeFences")) |x| {
        cfg.code_fences = weakBool(x);
    };
    if (site_cfg.str("pygmentsOptions")) |po| applyOpts(&cfg, parseOptionString(po));
    use_classes = !cfg.no_classes;
    code_fences = cfg.code_fences;
}

fn hlLinesToRanges(start: i64, s0: []const u8) ?[]const [2]i64 {
    var out: std.ArrayList([2]i64) = .empty;
    const s = std.mem.trim(u8, s0, " \t\n");
    var it = std.mem.splitScalar(u8, s, ' ');
    while (it.next()) |f0| {
        const f = std.mem.trim(u8, f0, " \t");
        if (f.len == 0) continue;
        var nums = std.mem.splitScalar(u8, f, '-');
        const a = std.fmt.parseInt(i64, nums.first(), 10) catch return null;
        var r = [2]i64{ a + start - 1, a + start - 1 };
        if (nums.next()) |b| r[1] = (std.fmt.parseInt(i64, b, 10) catch return null) + start - 1;
        out.append(sys.A, r) catch {};
    }
    std.mem.sort([2]i64, out.items, {}, struct {
        fn lt(_: void, x: [2]i64, y: [2]i64) bool {
            return x[0] < y[0];
        }
    }.lt);
    return out.items;
}

fn escAttr(s: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    chroma.escape(&b, s);
    return b.items;
}

const Pre = struct {
    lang: []const u8,
    inline_: bool,
    low: usize = 0,
    high: usize = 0,

    fn start(ctx: *anyopaque, b: *std.ArrayList(u8), code: bool, style_attr: []const u8) void {
        const p: *Pre = @ptrCast(@alignCast(ctx));
        if (p.inline_) {
            if (code) b.print(sys.A, "<code class=\"code-inline language-{s}\">", .{escAttr(p.lang)}) catch {};
            return;
        }
        b.print(sys.A, "<pre tabindex=\"0\"{s}><code", .{style_attr}) catch {};
        if (code and p.lang.len > 0) {
            const l = escAttr(p.lang);
            b.print(sys.A, " class=\"language-{s}\" data-lang=\"{s}\"", .{ l, l }) catch {};
        }
        b.append(sys.A, '>') catch {};
        p.low = b.items.len;
    }
    fn end(ctx: *anyopaque, b: *std.ArrayList(u8), code: bool) void {
        const p: *Pre = @ptrCast(@alignCast(ctx));
        if (p.inline_) {
            if (code) b.appendSlice(sys.A, "</code>") catch {};
            return;
        }
        p.high = b.items.len;
        b.appendSlice(sys.A, "</code></pre>") catch {};
    }
};

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Result = struct { html: []const u8, low: usize, high: usize };

/// Hugo's highlight(): renders `code` with the given config and the
/// non-option code block attributes (class/id/... for the wrapper div).
pub fn render(code: []const u8, lang_in: []const u8, attrs: ?[]const Attr, c: Config) Result {
    var b: std.ArrayList(u8) = .empty;
    var lang = lang_in;
    var lexer = if (lang.len > 0) chroma.get(lang) else null;
    if (lexer == null and c.guess_syntax) {
        lexer = chroma.get("plaintext");
        lang = "plaintext";
    }
    if (lexer == null) {
        if (c.hl_inline) {
            b.print(sys.A, "<code class=\"code-inline language-{s}\">", .{escAttr(lang)}) catch {};
            chroma.escape(&b, code);
            b.appendSlice(sys.A, "</code>") catch {};
            return .{ .html = b.items, .low = 0, .high = 0 };
        }
        var pre = Pre{ .lang = lang, .inline_ = false };
        Pre.start(&pre, &b, true, "");
        chroma.escape(&b, code);
        Pre.end(&pre, &b, true);
        return .{ .html = b.items, .low = pre.low, .high = pre.high };
    }
    const style = chroma.getStyle(c.style) orelse chroma.getStyle("swapoff") orelse chroma.getStyle("monokai").?;
    const toks = chroma.highlightTokens(lexer.?, code) catch &.{};
    if (!c.hl_inline) {
        b.appendSlice(sys.A, "<div class=\"") catch {};
        b.appendSlice(sys.A, escAttr(c.wrapper_class)) catch {};
        if (attrs) |as| {
            for (as) |a| if (std.mem.eql(u8, a.name, "class")) {
                b.print(sys.A, " {s}", .{escAttr(a.value)}) catch {};
                break;
            };
            b.append(sys.A, '"') catch {};
            for (as) |a| {
                if (std.mem.eql(u8, a.name, "class")) continue;
                b.print(sys.A, " {s}=\"{s}\"", .{ a.name, escAttr(a.value) }) catch {};
            }
        } else b.append(sys.A, '"') catch {};
        b.append(sys.A, '>') catch {};
    }
    var line_nos = false;
    var in_table = c.line_numbers_in_table;
    switch (c.line_nos) {
        .off => {},
        .on => line_nos = true,
        .inline_ => {
            line_nos = true;
            in_table = false;
        },
        .table => {
            line_nos = true;
            in_table = true;
        },
    }
    var ranges: []const [2]i64 = &.{};
    if (c.hl_parsed) |hp| {
        ranges = hp;
    } else if (c.hl_lines.len > 0) ranges = hlLinesToRanges(c.line_no_start, c.hl_lines) orelse &.{};
    const o = chroma.FormatOpts{
        .classes = !c.no_classes,
        .tab_width = c.tab_width,
        .line_numbers = line_nos,
        .in_table = in_table,
        .linkable = c.anchor_line_nos,
        .id_prefix = if (c.line_anchors.len > 0) v.concat(&.{ escAttr(c.line_anchors), "-" }) else "",
        .base_line = c.line_no_start,
        .hl_ranges = ranges,
        .inline_code = c.hl_inline,
    };
    var pre = Pre{ .lang = lang, .inline_ = c.hl_inline };
    chroma.format(&b, style, toks, o, .{ .ctx = &pre, .start = Pre.start, .end = Pre.end });
    if (!c.hl_inline) b.appendSlice(sys.A, "</div>") catch {};
    return .{ .html = b.items, .low = pre.low, .high = if (pre.high == 0) b.items.len else pre.high };
}

// ---------------------------------------------------------------- code fence attributes

pub const Parsed = struct { attrs: []Attr, opts: []Opt };

const option_keys = [_][]const u8{ "anchorlinenos", "guesssyntax", "hl_lines", "hl_inline", "lineanchors", "linenos", "linenostart", "linenumbersintable", "noclasses", "style", "tabwidth" };

fn isOptionKey(k: []const u8) bool {
    const l = v.lower(k);
    for (option_keys) |o| if (std.mem.eql(u8, o, l)) return true;
    return false;
}

/// Parses Goldmark's attribute block `{.cls #id key=val key="v" hl_lines=[1,"3-4"]}`.
pub fn parseAttributes(src: []const u8) Parsed {
    var out: std.ArrayList(Attr) = .empty;
    var opts: std.ArrayList(Opt) = .empty;
    const put = struct {
        fn f(list: *std.ArrayList(Attr), name: []const u8, value: []const u8, merge_class: bool) void {
            for (list.items) |*a| if (std.mem.eql(u8, a.name, name)) {
                a.value = if (merge_class) v.concat(&.{ a.value, " ", value }) else value;
                return;
            };
            list.append(sys.A, .{ .name = name, .value = value }) catch {};
        }
    }.f;
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == ',' or src[i] == '\t')) i += 1;
        if (i >= src.len) break;
        if (src[i] == '.' or src[i] == '#') {
            const kind = src[i];
            i += 1;
            const s = i;
            while (i < src.len and src[i] != ' ' and src[i] != ',' and src[i] != '}') i += 1;
            if (kind == '.') put(&out, "class", src[s..i], true) else put(&out, "id", src[s..i], false);
            continue;
        }
        const ks = i;
        while (i < src.len and src[i] != '=' and src[i] != ' ' and src[i] != ',') i += 1;
        const key = src[ks..i];
        if (i >= src.len or src[i] != '=') {
            continue;
        }
        i += 1;
        var val: Value = .nil;
        var ranges: ?[]const [2]i64 = null;
        var sval: []const u8 = "";
        if (i < src.len and (src[i] == '"' or src[i] == '\'')) {
            const q = src[i];
            const e = std.mem.indexOfScalarPos(u8, src, i + 1, q) orelse src.len;
            sval = src[i + 1 .. e];
            val = v.S(sval);
            i = @min(src.len, e + 1);
        } else if (i < src.len and src[i] == '[') {
            const e = std.mem.indexOfScalarPos(u8, src, i, ']') orelse src.len;
            var rs: std.ArrayList([2]i64) = .empty;
            var it = std.mem.tokenizeAny(u8, src[i + 1 .. e], ", ");
            while (it.next()) |item0| {
                const quoted = item0.len > 0 and (item0[0] == '"' or item0[0] == '\'');
                const item = std.mem.trim(u8, item0, "\"'");
                var parts = std.mem.splitScalar(u8, item, '-');
                const a = std.fmt.parseInt(i64, parts.first(), 10) catch continue;
                var b = a;
                if (quoted) if (parts.next()) |bs| {
                    b = std.fmt.parseInt(i64, bs, 10) catch continue;
                };
                rs.append(sys.A, .{ a - 1, b - 1 }) catch {};
            }
            ranges = rs.items;
            sval = src[i..@min(src.len, e + 1)];
            val = v.S(sval);
            i = @min(src.len, e + 1);
        } else {
            const s = i;
            while (i < src.len and src[i] != ' ' and src[i] != ',' and src[i] != '}') i += 1;
            sval = src[s..i];
            if (std.mem.eql(u8, sval, "true")) val = v.B(true) else if (std.mem.eql(u8, sval, "false")) val = v.B(false) else if (std.fmt.parseFloat(f64, sval) catch null) |f| {
                val = if (@floor(f) == f and @abs(f) < 1e15) v.I(@as(i64, @intFromFloat(f))) else .{ .float = f };
            } else val = v.S(sval);
        }
        if (isOptionKey(key)) {
            opts.append(sys.A, .{ .key = key, .val = val, .ranges = ranges }) catch {};
        } else if (!std.mem.startsWith(u8, v.lower(key), "on")) {
            const lk = v.lower(key);
            put(&out, lk, v.toStr(val), std.mem.eql(u8, lk, "class"));
        }
    }
    return .{ .attrs = out.items, .opts = opts.items };
}

/// Splits a fence info string `go {linenos=table}` into the attribute part.
pub fn infoAttributes(info: []const u8) ?[]const u8 {
    const o = v.indexOfChar(info, '{') orelse return null;
    const c = v.lastIndexOfChar(info, '}') orelse return null;
    if (c <= o) return null;
    return info[o + 1 .. c];
}

/// Default rendering of a fenced code block (Hugo's RenderCodeblock).
pub fn codeBlock(lang: []const u8, code: []const u8, info: []const u8, ordinal: usize) []const u8 {
    if (!cfg.code_fences) {
        if (lang.len == 0) return v.fmt("<pre><code>{s}</code></pre>\n", .{v.escText(code)});
        return v.fmt("<pre><code class=\"language-{s}\">{s}</code></pre>\n", .{ v.escText(lang), v.escText(code) });
    }
    var c = cfg;
    var attrs: ?[]const Attr = null;
    if (infoAttributes(info)) |a| {
        const p = parseAttributes(a);
        applyOpts(&c, p.opts);
        if (p.attrs.len > 0) attrs = p.attrs;
    }
    if (c.line_anchors.len == 0) c.line_anchors = v.fmt("hl-{d}", .{ordinal});
    const src = v.concat(&.{ std.mem.trimEnd(u8, code, "\r\n"), "\n" });
    return render(src, lang, attrs, c).html;
}

/// transform.Highlight / the highlight shortcode.
pub fn highlight(code_in: []const u8, lang_in: []const u8, opts: Value) []const u8 {
    var c = cfg;
    var code = code_in;
    var lang = lang_in;
    applyValueOpts(&c, opts, &lang, &code);
    return render(code, lang, null, c).html;
}

fn applyValueOpts(c: *Config, opts: Value, lang: *[]const u8, code: *[]const u8) void {
    var list: std.ArrayList(Opt) = .empty;
    switch (opts) {
        .nil => {},
        .map => |m| for (m.m.keys(), m.m.values()) |k, x| list.append(sys.A, .{ .key = v.lower(k), .val = x }) catch {},
        else => list.appendSlice(sys.A, parseOptionString(v.toStr(opts))) catch {},
    }
    var rest: std.ArrayList(Opt) = .empty;
    for (list.items) |o| {
        if (std.mem.eql(u8, o.key, "type")) lang.* = v.toStr(o.val) else if (std.mem.eql(u8, o.key, "code")) code.* = v.toStr(o.val) else rest.append(sys.A, o) catch {};
    }
    applyOpts(c, rest.items);
}

/// transform.HighlightCodeBlock: returns the wrapped markup and the inner part.
pub fn highlightCodeBlock(lang_in: []const u8, code_in: []const u8, options: ?*v.Map, attributes: ?*v.Map, opts: Value) [2][]const u8 {
    var c = cfg;
    if (options) |m| {
        var list: std.ArrayList(Opt) = .empty;
        for (m.m.keys(), m.m.values()) |k, x| list.append(sys.A, .{ .key = k, .val = x }) catch {};
        applyOpts(&c, list.items);
    }
    var lang = lang_in;
    var code = code_in;
    applyValueOpts(&c, opts, &lang, &code);
    if (c.line_anchors.len == 0) c.line_anchors = "hl-0";
    var attrs: ?[]const Attr = null;
    if (attributes) |am| if (am.m.count() > 0) {
        var list: std.ArrayList(Attr) = .empty;
        for (am.m.keys(), am.m.values()) |k, x| list.append(sys.A, .{ .name = k, .value = v.toStr(x) }) catch {};
        attrs = list.items;
    };
    const r = render(code, lang, attrs, c);
    return .{ r.html, r.html[r.low..r.high] };
}

pub fn known(name: []const u8) bool {
    return chroma.get(name) != null;
}

/// Legacy entry point: a fenced block with default options.
pub fn block(lang: []const u8, code: []const u8) []const u8 {
    return codeBlock(lang, code, "", 0);
}

/// `zssg gen chromastyles`
pub fn chromaStylesCss(style_name: []const u8, line_nos: bool, in_table: bool) ?[]const u8 {
    const st = chroma.getStyle(style_name) orelse return null;
    var b: std.ArrayList(u8) = .empty;
    chroma.writeCss(&b, st, .{ .classes = true, .tab_width = 4, .line_numbers = line_nos, .in_table = in_table });
    return b.items;
}
