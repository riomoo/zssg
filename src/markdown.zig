// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: goldmark (MIT, Copyright Yusuke Inuzuka); Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Markdown renderer: CommonMark core plus the Goldmark extensions Hugo enables
//! by default (tables, strikethrough, task lists, linkify, footnotes, definition
//! lists, typographer, heading auto-ids, attribute blocks on headings).
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const Buf = v.Buf;

pub const Heading = struct { level: u8, id: []const u8, html: []const u8, plain: []const u8 };

pub const Hooks = struct {
    ctx: *anyopaque,
    link: ?*const fn (*anyopaque, dest: []const u8, title: []const u8, text: []const u8, plain: []const u8) ?[]const u8 = null,
    image: ?*const fn (*anyopaque, dest: []const u8, title: []const u8, alt: []const u8, is_block: bool) ?[]const u8 = null,
    heading: ?*const fn (*anyopaque, level: u8, id: []const u8, text: []const u8, plain: []const u8, attrs: []const u8) ?[]const u8 = null,
    codeblock: ?*const fn (*anyopaque, lang: []const u8, code: []const u8, info: []const u8, ordinal: usize) ?[]const u8 = null,
    blockquote: ?*const fn (*anyopaque, inner: []const u8, alert: []const u8, sign: []const u8, title: []const u8) ?[]const u8 = null,
    passthrough: ?*const fn (*anyopaque, inner: []const u8, kind: []const u8, ordinal: usize) ?[]const u8 = null,
};

/// Goldmark passthrough extension delimiters ([open, close] pairs).
pub const Passthrough = struct { block: []const [2][]const u8 = &.{}, inline_: []const [2][]const u8 = &.{} };

pub const Opts = struct {
    unsafe: bool = false,
    typographer: bool = true,
    hard_wraps: bool = false,
    linkify: bool = true,
    auto_ids: bool = true,
    inline_only: bool = false,
    hooks: ?*const Hooks = null,
    passthrough: ?Passthrough = null,
};

pub const Result = struct { html: []const u8, headings: []Heading };

const Ref = struct { dest: []const u8, title: []const u8 };
const Foot = struct { label: []const u8, lines: [][]const u8, num: usize = 0, refs: usize = 0 };

const R = struct {
    o: Opts,
    /// goldmark never resets its typographer quote counter (its CloseBlock has
    /// the wrong signature), so it lives for the whole document
    qctr: QuoteCounter = .{},
    refs: std.StringHashMapUnmanaged(Ref) = .empty,
    foots: std.ArrayList(Foot) = .empty,
    foot_order: std.ArrayList(usize) = .empty,
    headings: std.ArrayList(Heading) = .empty,
    ids: std.StringHashMapUnmanaged(usize) = .empty,
    in_link: bool = false,
    code_ord: usize = 0,
    pass_ord: usize = 0,
};

fn passNode(r: *R, raw: []const u8, inner: []const u8, kind: []const u8) []const u8 {
    const ord = r.pass_ord;
    r.pass_ord += 1;
    if (r.o.hooks) |h| if (h.passthrough) |f| if (f(h.ctx, inner, kind, ord)) |res| return res;
    return v.escText(raw);
}

/// Finds the next passthrough segment in `s` at or after `from` using `delims`.
fn findPass(s: []const u8, from: usize, delims: []const [2][]const u8) ?struct { start: usize, end: usize, inner_start: usize, inner_end: usize } {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            // an escaped character cannot open a delimiter unless the delimiter itself starts with a backslash
            var opens = false;
            for (delims) |d| if (v.startsWith(s[i..], d[0])) {
                opens = true;
            };
            if (!opens) {
                i += 1;
                continue;
            }
        }
        if (s[i] == '`') {
            // skip code spans
            var n: usize = 0;
            while (i + n < s.len and s[i + n] == '`') n += 1;
            const close = std.mem.indexOfPos(u8, s, i + n, s[i .. i + n]);
            if (close) |cpos| {
                i = cpos + n - 1;
                continue;
            }
            i += n - 1;
            continue;
        }
        for (delims) |d| {
            if (!v.startsWith(s[i..], d[0])) continue;
            const is = i + d[0].len;
            var j = is;
            while (std.mem.indexOfPos(u8, s, j, d[1])) |e| {
                if (e > is) return .{ .start = i, .end = e + d[1].len, .inner_start = is, .inner_end = e };
                j = e + 1;
            }
        }
    }
    return null;
}

pub fn render(src: []const u8, o: Opts) Result {
    var r: R = .{ .o = o };
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| lines.append(sys.A, expandTabs(std.mem.trimEnd(u8, l, "\r"))) catch {};
    const body = collectDefs(&r, lines.items);
    var out: Buf = .{};
    if (o.inline_only) {
        const joined = std.mem.join(sys.A, "\n", body) catch "";
        out.add(inlines(&r, v.trimWs(joined)));
    } else {
        blocks(&r, body, &out, false);
        footnotes(&r, &out);
    }
    return .{ .html = out.str(), .headings = r.headings.items };
}

fn expandTabs(l: []const u8) []const u8 {
    // only leading tabs matter for block structure
    var i: usize = 0;
    while (i < l.len and l[i] == ' ') i += 1;
    if (i >= l.len or l[i] != '\t') return l;
    var b: Buf = .{};
    var col: usize = 0;
    i = 0;
    while (i < l.len and (l[i] == ' ' or l[i] == '\t')) : (i += 1) {
        if (l[i] == '\t') {
            const n = 4 - (col % 4);
            var k: usize = 0;
            while (k < n) : (k += 1) b.ch(' ');
            col += n;
        } else {
            b.ch(' ');
            col += 1;
        }
    }
    const lead = b.len();
    b.add(l[i..]);
    const e = b.str();
    tab_lines.put(sys.A, @intFromPtr(e.ptr) + e.len, .{ .exp = e, .raw = l, .lead = lead }) catch {};
    return e;
}

/// Lines whose leading tabs were expanded, keyed by the end address of the
/// expanded copy, so code blocks can recover the original tabs.
const TabLine = struct { exp: []const u8, raw: []const u8, lead: usize };
var tab_lines: std.AutoHashMapUnmanaged(usize, TabLine) = .empty;

/// The original text for `cl`, a suffix of a (possibly tab-expanded) line.
fn rawSuffix(cl: []const u8) []const u8 {
    const t = tab_lines.get(@intFromPtr(cl.ptr) + cl.len) orelse return cl;
    const k = t.exp.len - cl.len;
    if (k >= t.lead) return cl;
    var col: usize = 0;
    var j: usize = 0;
    while (j < t.raw.len and (t.raw[j] == ' ' or t.raw[j] == '\t')) : (j += 1) {
        if (col == k) return t.raw[j..];
        const w: usize = if (t.raw[j] == '\t') 4 - (col % 4) else 1;
        if (col + w > k) {
            var b: Buf = .{};
            var n = col + w - k;
            while (n > 0) : (n -= 1) b.ch(' ');
            b.add(t.raw[j + 1 ..]);
            return b.str();
        }
        col += w;
    }
    return t.raw[j..];
}

fn indentOf(l: []const u8) usize {
    var i: usize = 0;
    while (i < l.len and l[i] == ' ') i += 1;
    return i;
}
fn isBlank(l: []const u8) bool {
    return v.trimWs(l).len == 0;
}

fn fenceOf(l: []const u8) ?struct { ch: u8, n: usize, info: []const u8, indent: usize } {
    const ind = indentOf(l);
    if (ind > 3) return null;
    const t = l[ind..];
    if (t.len < 3 or (t[0] != '`' and t[0] != '~')) return null;
    var n: usize = 0;
    while (n < t.len and t[n] == t[0]) n += 1;
    if (n < 3) return null;
    const info = v.trimWs(t[n..]);
    if (t[0] == '`' and v.indexOfChar(info, '`') != null) return null;
    return .{ .ch = t[0], .n = n, .info = info, .indent = ind };
}

fn normLabel(s: []const u8) []const u8 {
    var b: Buf = .{};
    var sp = false;
    for (v.trimWs(s)) |c| {
        if (c == ' ' or c == '\n' or c == '\t') {
            sp = true;
        } else {
            if (sp and b.len() > 0) b.ch(' ');
            sp = false;
            b.ch(std.ascii.toLower(c));
        }
    }
    return b.str();
}

/// First pass: pull out link reference definitions and footnote definitions.
fn collectDefs(r: *R, lines: [][]const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var prev_para = false;
    while (i < lines.len) {
        const l = lines[i];
        if (fenceOf(l)) |f| {
            out.append(sys.A, l) catch {};
            i += 1;
            while (i < lines.len) : (i += 1) {
                out.append(sys.A, lines[i]) catch {};
                if (fenceOf(lines[i])) |c| if (c.ch == f.ch and c.n >= f.n and c.info.len == 0) {
                    i += 1;
                    break;
                };
            }
            prev_para = false;
            continue;
        }
        const ind = indentOf(l);
        if (ind <= 3 and !prev_para and v.startsWith(l[ind..], "[^")) {
            if (v.indexOf(l, "]:")) |e| {
                const label = l[ind + 2 .. e];
                if (label.len > 0 and v.indexOfChar(label, ' ') == null) {
                    var fl: std.ArrayList([]const u8) = .empty;
                    fl.append(sys.A, std.mem.trimStart(u8, l[e + 2 ..], " ")) catch {};
                    i += 1;
                    while (i < lines.len) : (i += 1) {
                        if (isBlank(lines[i])) {
                            if (i + 1 < lines.len and indentOf(lines[i + 1]) >= 4 and !isBlank(lines[i + 1])) {
                                fl.append(sys.A, "") catch {};
                                continue;
                            }
                            break;
                        }
                        const li = indentOf(lines[i]);
                        if (li >= 4) fl.append(sys.A, lines[i][4..]) catch {} else if (v.startsWith(lines[i][li..], "[")) break else fl.append(sys.A, lines[i][li..]) catch {};
                    }
                    r.foots.append(sys.A, .{ .label = v.dup(label), .lines = fl.items }) catch {};
                    continue;
                }
            }
        }
        if (ind <= 3 and !prev_para and l.len > ind and l[ind] == '[') {
            if (parseRefDef(l[ind..], if (i + 1 < lines.len) lines[i + 1] else "")) |d| {
                const key = normLabel(d.label);
                if (!r.refs.contains(key)) r.refs.put(sys.A, key, .{ .dest = d.dest, .title = d.title }) catch {};
                i += if (d.used_next) 2 else 1;
                continue;
            }
        }
        prev_para = !isBlank(l) and ind <= 3 and !(l[ind] == '#' or l[ind] == '>');
        out.append(sys.A, l) catch {};
        i += 1;
    }
    return out.items;
}

fn parseRefDef(l: []const u8, next: []const u8) ?struct { label: []const u8, dest: []const u8, title: []const u8, used_next: bool } {
    const e = v.indexOf(l, "]:") orelse return null;
    const label = l[1..e];
    if (label.len == 0 or v.indexOfChar(label, '[') != null or v.indexOfChar(label, ']') != null) return null;
    var rest = v.trimWs(l[e + 2 ..]);
    var used_next = false;
    if (rest.len == 0) {
        rest = v.trimWs(next);
        used_next = true;
        if (rest.len == 0) return null;
    }
    var dest: []const u8 = undefined;
    var after: []const u8 = undefined;
    if (rest[0] == '<') {
        const c = v.indexOfChar(rest, '>') orelse return null;
        dest = rest[1..c];
        after = v.trimWs(rest[c + 1 ..]);
    } else {
        const sp = v.indexOfChar(rest, ' ') orelse rest.len;
        dest = rest[0..sp];
        after = v.trimWs(rest[sp..]);
    }
    var title: []const u8 = "";
    if (after.len > 0) {
        const q = after[0];
        const cq: u8 = if (q == '(') ')' else q;
        if ((q == '"' or q == '\'' or q == '(') and after.len >= 2 and after[after.len - 1] == cq) {
            title = after[1 .. after.len - 1];
        } else return null;
    }
    return .{ .label = label, .dest = dest, .title = title, .used_next = used_next };
}

fn isHr(l: []const u8) bool {
    const ind = indentOf(l);
    if (ind > 3) return false;
    const t = l[ind..];
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (t) |x| {
        if (x == c) n += 1 else if (x != ' ' and x != '\t') return false;
    }
    return n >= 3;
}

fn atxLevel(l: []const u8) u8 {
    const ind = indentOf(l);
    if (ind > 3) return 0;
    const t = l[ind..];
    var n: u8 = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return 0;
    if (n < t.len and t[n] != ' ' and t[n] != '\t') return 0;
    return n;
}

const Marker = struct { ordered: bool, ch: u8, start: usize, width: usize, indent: usize, empty: bool };

fn listMarker(l: []const u8) ?Marker {
    const ind = indentOf(l);
    if (ind > 3) return null;
    const t = l[ind..];
    if (t.len == 0) return null;
    var mlen: usize = 0;
    var m: Marker = .{ .ordered = false, .ch = t[0], .start = 1, .width = 0, .indent = ind, .empty = false };
    if (t[0] == '-' or t[0] == '+' or t[0] == '*') {
        mlen = 1;
    } else if (std.ascii.isDigit(t[0])) {
        var n: usize = 0;
        while (n < t.len and std.ascii.isDigit(t[n]) and n < 9) n += 1;
        if (n >= t.len or (t[n] != '.' and t[n] != ')')) return null;
        m.ordered = true;
        m.ch = t[n];
        m.start = std.fmt.parseInt(usize, t[0..n], 10) catch 1;
        mlen = n + 1;
    } else return null;
    if (mlen == t.len) {
        m.empty = true;
        m.width = ind + mlen + 1;
        return m;
    }
    if (t[mlen] != ' ') return null;
    var sp: usize = 0;
    while (mlen + sp < t.len and t[mlen + sp] == ' ') sp += 1;
    if (mlen + sp == t.len) {
        m.empty = true;
        m.width = ind + mlen + 1;
        return m;
    }
    if (sp > 4) sp = 1;
    m.width = ind + mlen + sp;
    return m;
}

const block_tags = [_][]const u8{ "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul" };

/// Returns html block kind: 1 = script/pre/style/textarea, 2 = comment, 3 = <?, 4 = <!X, 5 = CDATA, 6 = block tag, 7 = other complete tag
fn htmlBlockKind(l: []const u8) u8 {
    const ind = indentOf(l);
    if (ind > 3) return 0;
    const t = l[ind..];
    if (t.len < 2 or t[0] != '<') return 0;
    if (v.startsWith(t, "<!--")) return 2;
    if (v.startsWith(t, "<?")) return 3;
    if (v.startsWith(t, "<![CDATA[")) return 5;
    if (t[1] == '!' and t.len > 2 and std.ascii.isAlphabetic(t[2])) return 4;
    var i: usize = 1;
    if (t[i] == '/') i += 1;
    const st = i;
    while (i < t.len and (std.ascii.isAlphanumeric(t[i]) or t[i] == '-')) i += 1;
    if (i == st) return 0;
    const name = v.lower(t[st..i]);
    const term_ok = i == t.len or t[i] == ' ' or t[i] == '>' or t[i] == '\t' or (t[i] == '/' and i + 1 < t.len and t[i + 1] == '>');
    if (st == 1 and term_ok and (v.eq(name, "script") or v.eq(name, "pre") or v.eq(name, "style") or v.eq(name, "textarea"))) return 1;
    if (term_ok) for (block_tags) |bt| if (v.eq(bt, name)) return 6;
    // type 7: a complete open or closing tag alone on the line
    const tr = v.trimWs(t);
    if (tr[tr.len - 1] == '>' and v.indexOfChar(tr[1 .. tr.len - 1], '<') == null and v.indexOfChar(tr[0 .. tr.len - 1], '>') == null) return 7;
    return 0;
}

fn tableDelim(l: []const u8) ?[]u8 {
    var t = v.trimWs(l);
    if (t.len == 0 or v.indexOfChar(t, '-') == null) return null;
    if (t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    var aligns: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, t, '|');
    while (it.next()) |cell0| {
        const ce = v.trimWs(cell0);
        if (ce.len == 0) return null;
        const left = ce[0] == ':';
        const right = ce.len > 1 and ce[ce.len - 1] == ':';
        const mid = ce[@intFromBool(left) .. ce.len - @intFromBool(right)];
        if (mid.len == 0) return null;
        for (mid) |c| if (c != '-') return null;
        aligns.append(sys.A, if (left and right) 'c' else if (left) 'l' else if (right) 'r' else 'n') catch {};
    }
    return aligns.items;
}

fn splitRow(l: []const u8) [][]const u8 {
    var t = v.trimWs(l);
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|' and (t.len < 2 or t[t.len - 2] != '\\')) t = t[0 .. t.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var cur: Buf = .{};
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] == '\\' and i + 1 < t.len and t[i + 1] == '|') {
            cur.ch('|');
            i += 1;
        } else if (t[i] == '|') {
            cells.append(sys.A, v.trimWs(cur.str())) catch {};
            cur = .{};
        } else cur.ch(t[i]);
    }
    cells.append(sys.A, v.trimWs(cur.str())) catch {};
    return cells.items;
}

fn startsBlock(l: []const u8) bool {
    if (isBlank(l)) return true;
    if (atxLevel(l) > 0 or isHr(l) or fenceOf(l) != null) return true;
    const ind = indentOf(l);
    if (ind <= 3 and l[ind] == '>') return true;
    const k = htmlBlockKind(l);
    if (k >= 1 and k <= 6) return true;
    if (listMarker(l)) |m| {
        if (m.empty) return false;
        if (m.ordered and m.start != 1) return false;
        return true;
    }
    return false;
}

fn headingId(r: *R, plain: []const u8) []const u8 {
    var b: Buf = .{};
    var i: usize = 0;
    const s = v.trimWs(plain);
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') b.ch(std.ascii.toLower(c)) else if (c == ' ') b.ch('-');
            i += 1;
        } else {
            const rn = v.decodeRune(s[i..]);
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(v.lowerRune(rn.cp), &tmp) catch 0;
            b.add(tmp[0..n]);
            i += rn.len;
        }
    }
    var id = b.str();
    if (id.len == 0) id = "heading";
    if (r.ids.getPtr(id)) |cnt| {
        cnt.* += 1;
        return v.fmt("{s}-{d}", .{ id, cnt.* });
    }
    r.ids.put(sys.A, v.dup(id), 0) catch {};
    return id;
}

/// Parse a trailing `{#id .class key="v"}` attribute block. Returns rendered attrs + id.
fn parseAttrs(s: []const u8) struct { id: []const u8, html: []const u8 } {
    var id: []const u8 = "";
    var classes: Buf = .{};
    var other: Buf = .{};
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| {
        if (tok[0] == '#') {
            id = tok[1..];
        } else if (tok[0] == '.') {
            if (classes.len() > 0) classes.ch(' ');
            classes.add(tok[1..]);
        } else if (v.indexOfChar(tok, '=')) |e| {
            const key = tok[0..e];
            const val = std.mem.trim(u8, tok[e + 1 ..], "\"'");
            if (v.eq(key, "class")) {
                if (classes.len() > 0) classes.ch(' ');
                classes.add(val);
            } else if (v.eq(key, "id")) {
                id = val;
            } else other.print(" {s}=\"{s}\"", .{ key, v.escText(val) });
        }
    }
    var h: Buf = .{};
    if (classes.len() > 0) h.print(" class=\"{s}\"", .{v.escText(classes.str())});
    h.add(other.str());
    return .{ .id = id, .html = h.str() };
}

fn heading(r: *R, out: *Buf, level: u8, raw_in: []const u8) void {
    var raw = v.trimWs(raw_in);
    var attrs: []const u8 = "";
    var forced_id: []const u8 = "";
    var raw_attrs: []const u8 = "";
    if (raw.len > 2 and raw[raw.len - 1] == '}') {
        if (v.lastIndexOfChar(raw, '{')) |ob| {
            const inner = raw[ob + 1 .. raw.len - 1];
            if (inner.len > 0 and (inner[0] == '#' or inner[0] == '.' or v.indexOfChar(inner, '=') != null)) {
                raw_attrs = inner;
                const a = parseAttrs(inner);
                attrs = a.html;
                forced_id = a.id;
                raw = v.trimWs(raw[0..ob]);
            }
        }
    }
    const html = inlines(r, raw);
    const plain = v.htmlUnescape(v.stripTags(html));
    const id = if (forced_id.len > 0) forced_id else if (r.o.auto_ids) headingId(r, plainForId(raw)) else "";
    r.headings.append(sys.A, .{ .level = level, .id = id, .html = html, .plain = plain }) catch {};
    if (r.o.hooks) |h| if (h.heading) |f| if (f(h.ctx, level, id, html, plain, raw_attrs)) |res| {
        out.add(res);
        if (res.len > 0 and res[res.len - 1] != '\n') out.ch('\n');
        return;
    };
    if (id.len > 0) out.print("<h{d} id=\"{s}\"{s}>{s}</h{d}>\n", .{ level, v.escText(id), attrs, html, level }) else out.print("<h{d}{s}>{s}</h{d}>\n", .{ level, attrs, html, level });
}

/// Text used for auto ids: the raw markdown with inline markup characters dropped.
fn plainForId(raw: []const u8) []const u8 {
    var b: Buf = .{};
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '[' or c == '*' or c == '`') continue;
        if (c == ']') {
            if (i + 1 < raw.len and raw[i + 1] == '(') {
                i = v.indexOfPos(raw, i, ")") orelse raw.len - 1;
            }
            continue;
        }
        if (c == '<') {
            if (v.indexOfPos(raw, i, ">")) |e| {
                i = e;
                continue;
            }
        }
        b.ch(c);
    }
    return b.str();
}

fn paragraph(r: *R, out: *Buf, lines: [][]const u8, tight: bool) void {
    var b: Buf = .{};
    for (lines, 0..) |l, i| {
        if (i > 0) b.ch('\n');
        b.add(if (i == 0) std.mem.trimStart(u8, l, " ") else std.mem.trimStart(u8, l, " "));
    }
    const text = std.mem.trimEnd(u8, b.str(), " \t\n");
    if (text.len == 0) return;
    // passthrough block delimiters split the paragraph into block nodes
    if (r.o.passthrough) |pt| if (pt.block.len > 0) {
        if (findPass(text, 0, pt.block)) |first| {
            var pos: usize = 0;
            var seg: ?@TypeOf(first) = first;
            while (seg) |sg| {
                const before = text[pos..sg.start];
                if (v.trimWs(before).len > 0) {
                    const h = inlines(r, before);
                    if (tight) out.add(h) else out.print("<p>{s}</p>\n", .{h});
                }
                out.add(passNode(r, text[sg.start..sg.end], text[sg.inner_start..sg.inner_end], "block"));
                pos = sg.end;
                seg = findPass(text, pos, pt.block);
            }
            const rest = text[pos..];
            if (v.trimWs(rest).len > 0) {
                const h = inlines(r, rest);
                if (tight) out.add(h) else out.print("<p>{s}</p>\n", .{h});
            }
            return;
        }
    };
    // a paragraph consisting solely of an image may be handled by a block image hook
    const html = inlinesBlock(r, text);
    if (tight) {
        out.add(html.s);
        out.ch('\n');
    } else {
        if (html.wrap) out.print("<p>{s}</p>\n", .{html.s}) else {
            out.add(html.s);
            out.ch('\n');
        }
    }
}

const BlockInline = struct { s: []const u8, wrap: bool };
fn inlinesBlock(r: *R, text: []const u8) BlockInline {
    return .{ .s = inlines(r, text), .wrap = true };
}

fn blocks(r: *R, lines: [][]const u8, out: *Buf, tight: bool) void {
    var i: usize = 0;
    while (i < lines.len) {
        const l = lines[i];
        if (isBlank(l)) {
            i += 1;
            continue;
        }
        const ind = indentOf(l);
        // indented code
        if (ind >= 4) {
            var code: Buf = .{};
            var j = i;
            var last = i;
            while (j < lines.len) : (j += 1) {
                if (isBlank(lines[j])) continue;
                if (indentOf(lines[j]) < 4) break;
                last = j;
            }
            j = i;
            while (j <= last) : (j += 1) {
                code.add(if (lines[j].len >= 4) rawSuffix(lines[j][4..]) else "");
                code.ch('\n');
            }
            i = last + 1;
            out.print("<pre><code>{s}</code></pre>\n", .{v.escText(code.str())});
            continue;
        }
        if (fenceOf(l)) |f| {
            var code: Buf = .{};
            i += 1;
            while (i < lines.len) : (i += 1) {
                if (fenceOf(lines[i])) |c| if (c.ch == f.ch and c.n >= f.n and c.info.len == 0) {
                    i += 1;
                    break;
                };
                var cl = lines[i];
                var k: usize = 0;
                while (k < f.indent and cl.len > 0 and cl[0] == ' ') : (k += 1) cl = cl[1..];
                code.add(rawSuffix(cl));
                code.ch('\n');
            }
            var lang = f.info;
            if (v.indexOfAny(lang, " \t{")) |sp| lang = lang[0..sp];
            codeBlock(r, out, lang, code.str(), f.info);
            continue;
        }
        const lvl = atxLevel(l);
        if (lvl > 0) {
            var t = v.trimWs(l[ind + lvl ..]);
            // strip closing #s
            var e = t.len;
            while (e > 0 and t[e - 1] == '#') e -= 1;
            if (e == 0) t = "" else if (e < t.len and (t[e - 1] == ' ')) t = v.trimWs(t[0..e]);
            heading(r, out, lvl, t);
            i += 1;
            continue;
        }
        if (isHr(l)) {
            out.add("<hr>\n");
            i += 1;
            continue;
        }
        if (l[ind] == '>') {
            var sub: std.ArrayList([]const u8) = .empty;
            var para_open = false;
            while (i < lines.len) : (i += 1) {
                const x = lines[i];
                const xi = indentOf(x);
                if (xi <= 3 and xi < x.len and x[xi] == '>') {
                    var rest = x[xi + 1 ..];
                    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                    sub.append(sys.A, rest) catch {};
                    para_open = !isBlank(rest) and !startsBlockNoPara(rest);
                } else if (para_open and !startsBlock(x)) {
                    sub.append(sys.A, x) catch {};
                } else break;
            }
            var inner: Buf = .{};
            blocks(r, sub.items, &inner, false);
            const text = inner.str();
            if (r.o.hooks) |h| if (h.blockquote) |fnc| {
                // Hugo's resolveBlockQuoteAlert on the rendered content
                var alert: []const u8 = "";
                var sign: []const u8 = "";
                var title: []const u8 = "";
                var htext = text;
                const t = v.trimWs(text);
                if (v.startsWith(t, "<p>[!")) {
                    var k: usize = 5;
                    while (k < t.len and std.ascii.isAlphabetic(t[k])) k += 1;
                    if (k > 5 and k < t.len and t[k] == ']') {
                        alert = v.lower(t[5..k]);
                        k += 1;
                        if (k < t.len and (t[k] == '-' or t[k] == '+')) {
                            sign = t[k .. k + 1];
                            k += 1;
                        }
                        if (k < t.len and (t[k] == ' ' or t[k] == '\t' or t[k] == 0x0b or t[k] == 0x0c)) k += 1;
                        const e = v.indexOfPos(t, k, "\n") orelse t.len;
                        title = v.trimWs(t[k..e]);
                        if (v.endsWith(title, "</p>")) title = title[0 .. title.len - 4];
                        if (v.indexOfChar(t, '\n')) |nl| {
                            const before = t[0..nl];
                            const after = t[nl + 1 ..];
                            htext = if (v.endsWith(before, "</p>")) after else v.concat(&.{ "<p>", after });
                        } else htext = "";
                    }
                }
                if (fnc(h.ctx, htext, alert, sign, title)) |res| {
                    out.add(res);
                    continue;
                }
            };
            out.add("<blockquote>\n");
            out.add(text);
            out.add("</blockquote>\n");
            continue;
        }
        const hk = htmlBlockKind(l);
        if (hk != 0) {
            var html: Buf = .{};
            const end_marker: ?[]const u8 = switch (hk) {
                2 => "-->",
                3 => "?>",
                4 => ">",
                5 => "]]>",
                else => null,
            };
            while (i < lines.len) : (i += 1) {
                const x = lines[i];
                if (hk >= 6 and isBlank(x)) break;
                html.add(x);
                html.ch('\n');
                if (end_marker) |em| if (v.contains(x, em)) {
                    i += 1;
                    break;
                };
                if (hk == 1) {
                    const lx = v.lower(x);
                    if (v.contains(lx, "</script>") or v.contains(lx, "</pre>") or v.contains(lx, "</style>") or v.contains(lx, "</textarea>")) {
                        i += 1;
                        break;
                    }
                }
            }
            if (r.o.unsafe) out.add(html.str()) else out.add("<!-- raw HTML omitted -->\n");
            continue;
        }
        if (listMarker(l)) |m0| {
            i = list(r, lines, i, m0, out);
            continue;
        }
        // table
        if (i + 1 < lines.len and v.indexOfChar(l, '|') != null) {
            if (tableDelim(lines[i + 1])) |aligns| {
                const hdr = splitRow(l);
                if (hdr.len == aligns.len) {
                    out.add("<table>\n\t<thead>\n\t\t\t<tr>\n");
                    for (hdr, 0..) |c, k| cell(r, out, "th", c, aligns[k]);
                    out.add("\t\t\t</tr>\n\t</thead>\n");
                    i += 2;
                    var any = false;
                    while (i < lines.len and !isBlank(lines[i]) and !startsBlock(lines[i])) : (i += 1) {
                        if (!any) out.add("\t<tbody>\n");
                        any = true;
                        out.add("\t\t\t<tr>\n");
                        const row = splitRow(lines[i]);
                        for (aligns, 0..) |a, k| cell(r, out, "td", if (k < row.len) row[k] else "", if (k < row.len) a else 'n');
                        out.add("\t\t\t</tr>\n");
                    }
                    if (any) out.add("\t</tbody>\n");
                    out.add("</table>\n");
                    continue;
                }
            }
        }
        // paragraph (with setext heading / definition list detection)
        var para: std.ArrayList([]const u8) = .empty;
        var setext: u8 = 0;
        while (i < lines.len) : (i += 1) {
            const x = lines[i];
            if (isBlank(x)) break;
            if (para.items.len > 0) {
                const xi = indentOf(x);
                const t = v.trimWs(x);
                if (xi <= 3 and t.len > 0 and (allOf(t, '=') or allOf(t, '-'))) {
                    setext = if (t[0] == '=') 1 else 2;
                    i += 1;
                    break;
                }
                if (startsBlock(x)) break;
                if (xi <= 3 and v.startsWith(x[xi..], ": ")) break;
            }
            para.append(sys.A, x) catch {};
        }
        if (setext != 0) {
            heading(r, out, setext, std.mem.join(sys.A, "\n", para.items) catch "");
            continue;
        }
        // definition list?
        var peek = i;
        while (peek < lines.len and isBlank(lines[peek])) peek += 1;
        if (peek < lines.len and peek <= i + 1 and indentOf(lines[peek]) <= 3 and v.startsWith(lines[peek][indentOf(lines[peek])..], ": ")) {
            i = defList(r, lines, i, para.items, out);
            continue;
        }
        paragraph(r, out, para.items, tight);
    }
}

fn startsBlockNoPara(l: []const u8) bool {
    return atxLevel(l) > 0 or isHr(l) or fenceOf(l) != null or indentOf(l) >= 4;
}

fn allOf(t: []const u8, c: u8) bool {
    for (t) |x| if (x != c) return false;
    return true;
}

fn defList(r: *R, lines: [][]const u8, start: usize, first_terms: [][]const u8, out: *Buf) usize {
    var i = start;
    out.add("<dl>\n");
    var terms = first_terms;
    while (true) {
        for (terms) |t| out.print("<dt>{s}</dt>\n", .{inlines(r, v.trimWs(t))});
        while (i < lines.len and isBlank(lines[i])) i += 1;
        while (i < lines.len) {
            const x = lines[i];
            const xi = indentOf(x);
            if (!(xi <= 3 and v.startsWith(x[xi..], ": "))) break;
            var sub: std.ArrayList([]const u8) = .empty;
            sub.append(sys.A, x[xi + 2 ..]) catch {};
            i += 1;
            while (i < lines.len) : (i += 1) {
                if (isBlank(lines[i])) {
                    if (i + 1 < lines.len and indentOf(lines[i + 1]) >= 2 and !isBlank(lines[i + 1])) {
                        sub.append(sys.A, "") catch {};
                        continue;
                    }
                    break;
                }
                const li = indentOf(lines[i]);
                if (li <= 3 and v.startsWith(lines[i][li..], ": ")) break;
                sub.append(sys.A, lines[i][@min(li, 4)..]) catch {};
            }
            var inner: Buf = .{};
            blocks(r, sub.items, &inner, true);
            out.print("<dd>{s}</dd>\n", .{std.mem.trimEnd(u8, inner.str(), "\n")});
            while (i < lines.len and isBlank(lines[i])) i += 1;
        }
        // another term group?
        var j = i;
        var nt: std.ArrayList([]const u8) = .empty;
        while (j < lines.len and !isBlank(lines[j]) and !startsBlock(lines[j]) and !v.startsWith(lines[j][indentOf(lines[j])..], ": ")) : (j += 1) nt.append(sys.A, lines[j]) catch {};
        var k = j;
        while (k < lines.len and isBlank(lines[k])) k += 1;
        if (nt.items.len > 0 and k < lines.len and k <= j + 1 and v.startsWith(lines[k][indentOf(lines[k])..], ": ") and indentOf(lines[k]) <= 3) {
            terms = nt.items;
            i = j;
            continue;
        }
        break;
    }
    out.add("</dl>\n");
    return i;
}

fn cell(r: *R, out: *Buf, tag: []const u8, text: []const u8, a: u8) void {
    const al: []const u8 = switch (a) {
        'l' => " style=\"text-align: left\"",
        'r' => " style=\"text-align: right\"",
        'c' => " style=\"text-align: center\"",
        else => "",
    };
    out.print("\t\t\t\t\t<{s}{s}>{s}</{s}>\n", .{ tag, al, inlines(r, text), tag });
}

fn codeBlock(r: *R, out: *Buf, lang: []const u8, code: []const u8, info: []const u8) void {
    const ord = r.code_ord;
    r.code_ord += 1;
    if (r.o.hooks) |h| if (h.codeblock) |f| if (f(h.ctx, lang, code, info, ord)) |res| {
        out.add(res);
        return;
    };
    out.add(@import("highlight.zig").codeBlock(lang, code, info, ord));
}

fn list(r: *R, lines: [][]const u8, start: usize, m0: Marker, out: *Buf) usize {
    const Item = struct { lines: [][]const u8, blank_inside: bool };
    var items: std.ArrayList(Item) = .empty;
    var i = start;
    var loose = false;
    while (i < lines.len) {
        const m = listMarker(lines[i]) orelse break;
        if (m.ordered != m0.ordered or m.ch != m0.ch) break;
        if (isHr(lines[i]) and !m.ordered) break;
        var sub: std.ArrayList([]const u8) = .empty;
        sub.append(sys.A, if (m.empty) "" else lines[i][m.width..]) catch {};
        i += 1;
        var blank_pending = false;
        var blank_inside = false;
        var in_fence: ?u8 = null;
        while (i < lines.len) : (i += 1) {
            const x = lines[i];
            if (isBlank(x)) {
                blank_pending = true;
                sub.append(sys.A, "") catch {};
                continue;
            }
            const xi = indentOf(x);
            if (xi >= m.width) {
                if (blank_pending and in_fence == null) blank_inside = true;
                blank_pending = false;
                const content = x[m.width..];
                if (fenceOf(content)) |f| {
                    if (in_fence == null) in_fence = f.ch else if (in_fence.? == f.ch and f.info.len == 0) in_fence = null;
                }
                sub.append(sys.A, content) catch {};
                continue;
            }
            if (blank_pending) break;
            // lazy continuation of a paragraph
            if (in_fence == null and !startsBlock(x) and listMarker(x) == null) {
                sub.append(sys.A, x[xi..]) catch {};
                continue;
            }
            break;
        }
        // trailing blank lines belong between items
        var n = sub.items.len;
        var trailing = false;
        while (n > 0 and isBlank(sub.items[n - 1])) : (n -= 1) trailing = true;
        items.append(sys.A, .{ .lines = sub.items[0..n], .blank_inside = blank_inside }) catch {};
        if (blank_inside) loose = true;
        if (trailing and i < lines.len) {
            if (listMarker(lines[i])) |nm| {
                if (nm.ordered == m0.ordered and nm.ch == m0.ch) loose = true;
            }
        }
    }
    if (m0.ordered) {
        if (m0.start != 1) out.print("<ol start=\"{d}\">\n", .{m0.start}) else out.add("<ol>\n");
    } else out.add("<ul>\n");
    for (items.items) |it| {
        var inner: Buf = .{};
        var il = it.lines;
        var task: []const u8 = "";
        if (il.len > 0) {
            const t = il[0];
            if (t.len >= 4 and t[0] == '[' and t[2] == ']' and t[3] == ' ' and (t[1] == ' ' or t[1] == 'x' or t[1] == 'X')) {
                task = if (t[1] == ' ') "<input disabled=\"\" type=\"checkbox\"> " else "<input checked=\"\" disabled=\"\" type=\"checkbox\"> ";
                const nl = sys.A.dupe([]const u8, il) catch il;
                nl[0] = t[4..];
                il = nl;
            }
        }
        blocks(r, il, &inner, !loose);
        var body = inner.str();
        if (task.len > 0) {
            if (v.startsWith(body, "<p>")) body = v.concat(&.{ "<p>", task, body[3..] }) else body = v.concat(&.{ task, body });
        }
        if (loose) {
            out.print("<li>\n{s}</li>\n", .{body});
        } else {
            const tb = std.mem.trimEnd(u8, body, "\n");
            // tight item whose content contains nested blocks keeps a newline before them
            if (v.indexOf(tb, "\n<ul>") != null or v.indexOf(tb, "\n<ol>") != null or v.indexOf(tb, "\n<pre") != null or v.indexOf(tb, "\n<div") != null or v.indexOf(tb, "\n<blockquote") != null) {
                out.print("<li>{s}\n</li>\n", .{tb});
            } else out.print("<li>{s}</li>\n", .{tb});
        }
    }
    out.add(if (m0.ordered) "</ol>\n" else "</ul>\n");
    return i;
}

fn footnotes(r: *R, out: *Buf) void {
    if (r.foot_order.items.len == 0) return;
    out.add("<div class=\"footnotes\" role=\"doc-endnotes\">\n<hr>\n<ol>\n");
    var k: usize = 0;
    while (k < r.foot_order.items.len) : (k += 1) {
        const f = &r.foots.items[r.foot_order.items[k]];
        var inner: Buf = .{};
        blocks(r, f.lines, &inner, false);
        var body = std.mem.trimEnd(u8, inner.str(), "\n");
        var bb: Buf = .{};
        bb.print("&#160;<a href=\"#fnref:{d}\" class=\"footnote-backref\" role=\"doc-backlink\">&#x21a9;&#xfe0e;</a>", .{f.num});
        var ri: usize = 1;
        while (ri < f.refs) : (ri += 1) bb.print("&#160;<a href=\"#fnref{d}:{d}\" class=\"footnote-backref\" role=\"doc-backlink\">&#x21a9;&#xfe0e;</a>", .{ ri, f.num });
        const back = bb.str();
        if (v.endsWith(body, "</p>")) body = v.concat(&.{ body[0 .. body.len - 4], back, "</p>" }) else body = v.concat(&.{ body, back });
        out.print("<li id=\"fn:{d}\">\n{s}\n</li>\n", .{ f.num, body });
    }
    out.add("</ol>\n</div>\n");
}

// ================================================================ inlines

const NodeKind = enum { text, delim, open_link, open_image };
const INode = struct {
    kind: NodeKind,
    s: []const u8 = "", // rendered html for text nodes; raw delimiter chars otherwise
    ch: u8 = 0,
    count: usize = 0,
    orig: usize = 0,
    can_open: bool = false,
    can_close: bool = false,
    active: bool = true,
    removed: bool = false,
    src_pos: usize = 0,
};

fn isPunct(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}
fn isWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == '\r' or c == 0;
}

fn escAttr(s: []const u8) []const u8 {
    return v.escText(s);
}

fn escUrl(s: []const u8) []const u8 {
    var b: Buf = .{};
    for (s) |c| switch (c) {
        '&' => b.add("&amp;"),
        '"' => b.add("%22"),
        ' ' => b.add("%20"),
        '<' => b.add("%3C"),
        '>' => b.add("%3E"),
        '\\' => b.add("%5C"),
        '`' => b.add("%60"),
        '[' => b.add("%5B"),
        ']' => b.add("%5D"),
        else => if (c >= 0x80) b.print("%{X:0>2}", .{c}) else b.ch(c),
    };
    return b.str();
}

fn unescapeMd(s: []const u8) []const u8 {
    if (v.indexOfChar(s, '\\') == null and v.indexOfChar(s, '&') == null) return s;
    var b: Buf = .{};
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and isPunct(s[i + 1])) {
            i += 1;
        }
        b.ch(s[i]);
    }
    return v.htmlUnescape(b.str());
}

const LinkTail = struct { dest: []const u8, title: []const u8, end: usize };

/// Parse `(dest "title")` starting at s[i] == '('.
fn inlineLinkTail(s: []const u8, start: usize) ?LinkTail {
    var i = start + 1;
    while (i < s.len and isWs(s[i])) i += 1;
    var dest: []const u8 = "";
    if (i < s.len and s[i] == '<') {
        const e = v.indexOfPos(s, i, ">") orelse return null;
        if (v.indexOfChar(s[i..e], '\n') != null) return null;
        dest = s[i + 1 .. e];
        i = e + 1;
    } else {
        const st = i;
        var depth: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (c == '(') depth += 1;
            if (c == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
            if (isWs(c)) break;
        }
        dest = s[st..i];
    }
    while (i < s.len and isWs(s[i])) i += 1;
    var title: []const u8 = "";
    if (i < s.len and (s[i] == '"' or s[i] == '\'' or s[i] == '(')) {
        const q: u8 = if (s[i] == '(') ')' else s[i];
        var e = i + 1;
        while (e < s.len and s[e] != q) : (e += 1) {
            if (s[e] == '\\') e += 1;
        }
        if (e >= s.len) return null;
        title = s[i + 1 .. e];
        i = e + 1;
        while (i < s.len and isWs(s[i])) i += 1;
    }
    if (i >= s.len or s[i] != ')') return null;
    return .{ .dest = unescapeMd(dest), .title = unescapeMd(title), .end = i + 1 };
}

fn autolinkEnd(s: []const u8, start: usize) usize {
    var e = start;
    while (e < s.len and !isWs(s[e]) and s[e] != '<') e += 1;
    // trim trailing punctuation
    while (e > start) {
        const c = s[e - 1];
        if (c == '.' or c == ',' or c == ':' or c == ';' or c == '!' or c == '?' or c == '"' or c == '\'' or c == '*' or c == '_' or c == '~') {
            e -= 1;
        } else if (c == ')') {
            var open: usize = 0;
            var close: usize = 0;
            for (s[start..e]) |x| {
                if (x == '(') open += 1;
                if (x == ')') close += 1;
            }
            if (close > open) e -= 1 else break;
        } else break;
    }
    return e;
}

const QuoteCounter = struct { single: i32 = 0, double: i32 = 0 };

fn runeAt(s: []const u8, i: usize) u21 {
    if (i >= s.len) return ' ';
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[i];
    if (i + n > s.len) return s[i];
    return std.unicode.utf8Decode(s[i .. i + n]) catch s[i];
}
fn runeBefore(s: []const u8, i: usize) u21 {
    if (i == 0) return '\n';
    var j = i - 1;
    while (j > 0 and (s[j] & 0xC0) == 0x80) j -= 1;
    return runeAt(s, j);
}
fn uSpace(r: u21) bool {
    return switch (r) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r', 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}
/// unicode.IsPunct || unicode.IsSymbol (approximation for non-ASCII)
fn uPunct(r: u21) bool {
    if (r < 0x80) return isPunct(@intCast(r));
    return switch (r) {
        0xA1...0xBF, 0xD7, 0xF7, 0x2010...0x2027, 0x2030...0x205E, 0x2070...0x209F, 0x20A0...0x20CF, 0x2100...0x214F, 0x2190...0x2BFF, 0x2E00...0x2E7F, 0x3001...0x3003, 0x3008...0x3020, 0x30FB, 0xFE10...0xFE6F, 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65, 0x1F000...0x1FAFF => true,
        else => false,
    };
}
fn uLetter(r: u21) bool {
    if (r < 0x80) return std.ascii.isAlphabetic(@intCast(r));
    return !uSpace(r) and !uPunct(r) and !(r >= 0x300 and r <= 0x36F);
}
fn uDigit(r: u21) bool {
    return r >= '0' and r <= '9';
}

/// goldmark's typographer for ' and " (extension/typographer.go). Returns
/// false when the quote stays a literal character.
fn typoQuote(b: *Buf, s: []const u8, i: usize, ctr: *QuoteCounter) bool {
    const c = s[i];
    const nl = v.indexOfPos(s, i, "\n");
    const line = s[i .. if (nl) |n| n + 1 else s.len];
    const before = runeBefore(s, i);
    // ScanDelimiter
    var j: usize = 0;
    while (j < line.len and line[j] == c) j += 1;
    const after: u21 = if (j != line.len) runeAt(line, j) else ' ';
    const bp = uPunct(before);
    const bw = uSpace(before);
    const ap = uPunct(after);
    const aw = uSpace(after);
    const can_open = !aw and (!ap or bw or bp);
    const can_close = !bw and (!bp or aw or ap);
    const l1: u8 = if (line.len > 1) line[1] else 0;
    if (c == '\'') {
        if (can_open and !can_close and line.len > 3 and std.ascii.isDigit(line[1]) and std.ascii.isDigit(line[2]) and line[3] == 's') {
            const aft: u21 = if (line.len > 4) runeAt(line, 4) else ' ';
            if (line.len == 3 or uSpace(aft) or uPunct(aft)) {
                b.add("&rsquo;");
                return true;
            }
        }
        if (line.len > 1 and ((bp and before < 0x80 and std.ascii.isPrint(@intCast(before)) and !isSymbolAscii(@intCast(before))) or (before >= 0x80 and uPunct(before)) or uSpace(before)) and (l1 == 't' or l1 == 'e' or l1 == 'n' or l1 == 'l')) {
            b.add("&rsquo;");
            return true;
        }
        if (line.len > 1 and (uDigit(before) or uLetter(before)) and uLetter(runeAt(line, 1))) {
            b.add("&rsquo;");
            return true;
        }
        if (can_open and !can_close) {
            var right = false;
            if (line.len > 1 and (l1 == 's' or l1 == 'm' or l1 == 't' or l1 == 'd') and (line.len < 3 or isPunct(line[2]) or isWs(line[2]))) right = true;
            if (line.len > 2 and ((l1 == 'v' and line[2] == 'e') or (l1 == 'l' and line[2] == 'l') or (l1 == 'r' and line[2] == 'e')) and (line.len < 4 or isPunct(line[3]) or isWs(line[3]))) right = true;
            if (!right) ctr.single += 1;
            b.add(if (right) "&rsquo;" else "&lsquo;");
            return true;
        }
        // plural possessive and abbreviations: Smiths', doin'
        {
            const r0 = runeAt(line, 0);
            if (line.len > 1 and uSpace(r0) or (isGoPunct(r0) and (line.len > 2 and !uDigit(runeAt(line, 1))))) {
                b.add("&rsquo;");
                return true;
            }
        }
        if (ctr.single > 0) {
            const is_close = can_close and !can_open;
            const maybe = can_close and can_open and line.len > 1 and isGoPunct(runeAt(line, 1)) and (line.len == 2 or (line.len > 2 and isPunct(line[2]) or isWs(line[2])));
            if (is_close or maybe) {
                ctr.single -= 1;
                b.add("&rsquo;");
                return true;
            }
        }
        return false;
    }
    if (can_open and !can_close) {
        ctr.double += 1;
        b.add("&ldquo;");
        return true;
    }
    if (ctr.double > 0) {
        const is_close = can_close and !can_open;
        const maybe = can_close and can_open and line.len > 1 and isGoPunct(runeAt(line, 1)) and (line.len == 2 or (line.len > 2 and isPunct(line[2]) or isWs(line[2])));
        if (is_close or maybe) {
            if (line.len > 1 and l1 == '"' and uDigit(before)) return false;
            ctr.double -= 1;
            b.add("&rdquo;");
            return true;
        }
    }
    return false;
}

fn isSymbolAscii(c: u8) bool {
    return switch (c) {
        '$', '+', '<', '=', '>', '^', '`', '|', '~' => true,
        else => false,
    };
}
/// unicode.IsPunct (symbols excluded)
fn isGoPunct(r: u21) bool {
    if (r < 0x80) return isPunct(@intCast(r)) and !isSymbolAscii(@intCast(r));
    return uPunct(r);
}

pub fn inlines(r: *R, s: []const u8) []const u8 {
    var nodes: std.ArrayList(INode) = .empty;
    var txt: Buf = .{};
    var i: usize = 0;
    const flush = struct {
        fn f(n: *std.ArrayList(INode), t: *Buf) void {
            if (t.len() > 0) {
                n.append(sys.A, .{ .kind = .text, .s = t.str() }) catch {};
                t.* = .{};
            }
        }
    }.f;
    while (i < s.len) {
        const c = s[i];
        if (r.o.passthrough) |pt| if (pt.inline_.len > 0) {
            var hit = false;
            for (pt.inline_) |d| if (v.startsWith(s[i..], d[0])) {
                hit = true;
            };
            if (hit) if (findPass(s[0..], i, pt.inline_)) |sg| if (sg.start == i) {
                flush(&nodes, &txt);
                txt.add(passNode(r, s[sg.start..sg.end], s[sg.inner_start..sg.inner_end], "inline"));
                i = sg.end;
                continue;
            };
        };
        switch (c) {
            '\\' => {
                if (i + 1 < s.len and s[i + 1] == '\n') {
                    txt.add("<br>\n");
                    i += 2;
                    while (i < s.len and s[i] == ' ') i += 1;
                } else if (i + 1 < s.len and isPunct(s[i + 1])) {
                    txt.add(v.escText(s[i + 1 .. i + 2]));
                    i += 2;
                } else {
                    txt.ch('\\');
                    i += 1;
                }
            },
            '`' => {
                var n: usize = 0;
                while (i + n < s.len and s[i + n] == '`') n += 1;
                var j = i + n;
                var found: ?usize = null;
                while (j < s.len) {
                    if (s[j] == '`') {
                        var m: usize = 0;
                        while (j + m < s.len and s[j + m] == '`') m += 1;
                        if (m == n) {
                            found = j;
                            break;
                        }
                        j += m;
                    } else j += 1;
                }
                if (found) |f| {
                    var code = v.replaceAll(s[i + n .. f], "\n", " ");
                    if (code.len >= 2 and code[0] == ' ' and code[code.len - 1] == ' ' and v.trimWs(code).len > 0) code = code[1 .. code.len - 1];
                    txt.print("<code>{s}</code>", .{v.escText(code)});
                    i = f + n;
                } else {
                    txt.add(s[i .. i + n]);
                    i += n;
                }
            },
            '<' => {
                // autolink or raw html
                if (v.indexOfPos(s, i, ">")) |e| {
                    const inner = s[i + 1 .. e];
                    const is_uri = blk: {
                        const col = v.indexOfChar(inner, ':') orelse break :blk false;
                        if (col < 2 or col > 32) break :blk false;
                        for (inner[0..col]) |x| if (!(std.ascii.isAlphanumeric(x) or x == '+' or x == '.' or x == '-')) break :blk false;
                        for (inner) |x| if (isWs(x) or x == '<') break :blk false;
                        break :blk true;
                    };
                    const is_mail = !is_uri and v.indexOfChar(inner, '@') != null and v.indexOfChar(inner, ' ') == null and v.indexOfChar(inner, '\n') == null and !v.startsWith(inner, "/") and v.indexOfChar(inner, '=') == null;
                    if (is_uri or is_mail) {
                        const href = if (is_mail) v.concat(&.{ "mailto:", inner }) else inner;
                        txt.add(linkHtml(r, href, "", v.escText(inner), inner));
                        i = e + 1;
                        continue;
                    }
                    if (rawHtmlEnd(s, i)) |he| {
                        if (r.o.unsafe) txt.add(s[i..he]) else txt.add("<!-- raw HTML omitted -->");
                        i = he;
                        continue;
                    }
                }
                if (r.o.typographer and i + 1 < s.len and s[i + 1] == '<') {
                    txt.add("&laquo;");
                    i += 2;
                } else {
                    txt.add("&lt;");
                    i += 1;
                }
            },
            '&' => {
                // entity passthrough
                var j = i + 1;
                while (j < s.len and j < i + 32 and (std.ascii.isAlphanumeric(s[j]) or s[j] == '#')) j += 1;
                if (j < s.len and s[j] == ';' and j > i + 1) {
                    const dec = v.htmlUnescape(s[i .. j + 1]);
                    if (v.eq(dec, s[i .. j + 1])) txt.add(s[i .. j + 1]) else txt.add(v.escText(dec));
                    i = j + 1;
                } else {
                    txt.add("&amp;");
                    i += 1;
                }
            },
            '>' => {
                if (r.o.typographer and i + 1 < s.len and s[i + 1] == '>') {
                    txt.add("&raquo;");
                    i += 2;
                } else {
                    txt.add("&gt;");
                    i += 1;
                }
            },
            '"' => {
                if (!(r.o.typographer and typoQuote(&txt, s, i, &r.qctr))) txt.add("&quot;");
                i += 1;
            },
            '\'' => {
                if (!(r.o.typographer and typoQuote(&txt, s, i, &r.qctr))) txt.add(if (r.o.typographer) "'" else "&#39;");
                i += 1;
            },
            '-' => {
                if (r.o.typographer and v.startsWith(s[i..], "---")) {
                    txt.add("&mdash;");
                    i += 3;
                } else if (r.o.typographer and v.startsWith(s[i..], "--")) {
                    txt.add("&ndash;");
                    i += 2;
                } else {
                    txt.ch('-');
                    i += 1;
                }
            },
            '.' => {
                if (r.o.typographer and v.startsWith(s[i..], "...")) {
                    txt.add("&hellip;");
                    i += 3;
                } else {
                    txt.ch('.');
                    i += 1;
                }
            },
            '\n' => {
                // hard break: two+ trailing spaces
                var t = txt.str();
                var sp: usize = 0;
                while (sp < t.len and t[t.len - 1 - sp] == ' ') sp += 1;
                txt.l.shrinkRetainingCapacity(t.len - sp);
                t = txt.str();
                if (sp >= 2 or r.o.hard_wraps) txt.add("<br>\n") else txt.ch('\n');
                i += 1;
                while (i < s.len and s[i] == ' ') i += 1;
            },
            '*', '_', '~' => {
                var n: usize = 0;
                while (i + n < s.len and s[i + n] == c) n += 1;
                if (c == '~' and n > 2) {
                    txt.add(s[i .. i + n]);
                    i += n;
                    continue;
                }
                const before: u8 = if (i > 0) s[i - 1] else ' ';
                const after: u8 = if (i + n < s.len) s[i + n] else ' ';
                const b_ws = isWs(before);
                const a_ws = isWs(after);
                const b_p = isPunct(before);
                const a_p = isPunct(after);
                const left = !a_ws and (!a_p or b_ws or b_p);
                const right = !b_ws and (!b_p or a_ws or a_p);
                var can_open = left;
                var can_close = right;
                if (c == '_') {
                    can_open = left and (!right or b_p);
                    can_close = right and (!left or a_p);
                }
                flush(&nodes, &txt);
                nodes.append(sys.A, .{ .kind = .delim, .s = s[i .. i + n], .ch = c, .count = n, .orig = n, .can_open = can_open, .can_close = can_close }) catch {};
                i += n;
            },
            '!' => {
                if (i + 1 < s.len and s[i + 1] == '[') {
                    flush(&nodes, &txt);
                    nodes.append(sys.A, .{ .kind = .open_image, .s = "![", .src_pos = i + 2 }) catch {};
                    i += 2;
                } else {
                    txt.ch('!');
                    i += 1;
                }
            },
            '[' => {
                // footnote reference
                if (i + 1 < s.len and s[i + 1] == '^') {
                    if (v.indexOfPos(s, i, "]")) |e| {
                        const label = s[i + 2 .. e];
                        var fi: ?usize = null;
                        for (r.foots.items, 0..) |f, k| if (v.eq(f.label, label)) {
                            fi = k;
                        };
                        if (fi) |k| {
                            const f = &r.foots.items[k];
                            if (f.num == 0) {
                                r.foot_order.append(sys.A, k) catch {};
                                f.num = r.foot_order.items.len;
                            }
                            f.refs += 1;
                            if (f.refs == 1) txt.print("<sup id=\"fnref:{d}\"><a href=\"#fn:{d}\" class=\"footnote-ref\" role=\"doc-noteref\">{d}</a></sup>", .{ f.num, f.num, f.num }) else txt.print("<sup id=\"fnref{d}:{d}\"><a href=\"#fn:{d}\" class=\"footnote-ref\" role=\"doc-noteref\">{d}</a></sup>", .{ f.refs - 1, f.num, f.num, f.num });
                            i = e + 1;
                            continue;
                        }
                    }
                }
                flush(&nodes, &txt);
                nodes.append(sys.A, .{ .kind = .open_link, .s = "[", .src_pos = i + 1 }) catch {};
                i += 1;
            },
            ']' => {
                flush(&nodes, &txt);
                // find the matching opener
                var oi: ?usize = null;
                var k = nodes.items.len;
                while (k > 0) : (k -= 1) {
                    const n = nodes.items[k - 1];
                    if ((n.kind == .open_link or n.kind == .open_image) and !n.removed) {
                        oi = k - 1;
                        break;
                    }
                }
                const o = oi orelse {
                    txt.ch(']');
                    i += 1;
                    continue;
                };
                const opener = nodes.items[o];
                if (!opener.active) {
                    nodes.items[o].removed = true;
                    nodes.items[o].kind = .text;
                    txt.ch(']');
                    i += 1;
                    continue;
                }
                const label_src = s[opener.src_pos..i];
                var dest: ?[]const u8 = null;
                var title: []const u8 = "";
                var end = i + 1;
                if (i + 1 < s.len and s[i + 1] == '(') {
                    if (inlineLinkTail(s, i + 1)) |t| {
                        dest = t.dest;
                        title = t.title;
                        end = t.end;
                    }
                }
                if (dest == null and i + 1 < s.len and s[i + 1] == '[') {
                    if (v.indexOfPos(s, i + 1, "]")) |e2| {
                        const lab = if (e2 == i + 2) label_src else s[i + 2 .. e2];
                        if (r.refs.get(normLabel(lab))) |rf| {
                            dest = rf.dest;
                            title = rf.title;
                            end = e2 + 1;
                        }
                    }
                }
                if (dest == null) {
                    if (r.refs.get(normLabel(label_src))) |rf| {
                        dest = rf.dest;
                        title = rf.title;
                    }
                }
                if (dest == null) {
                    nodes.items[o].removed = true;
                    nodes.items[o].kind = .text;
                    txt.ch(']');
                    i += 1;
                    continue;
                }
                // render the label contents
                const inner = emphasis(nodes.items[o + 1 ..]);
                nodes.shrinkRetainingCapacity(o);
                if (opener.kind == .open_image) {
                    const alt = v.htmlUnescape(v.stripTags(inner));
                    nodes.append(sys.A, .{ .kind = .text, .s = imageHtml(r, dest.?, title, alt, false) }) catch {};
                } else {
                    nodes.append(sys.A, .{ .kind = .text, .s = linkHtml(r, dest.?, title, inner, v.htmlUnescape(v.stripTags(inner))) }) catch {};
                    // links may not contain other links
                    for (nodes.items) |*n| if (n.kind == .open_link) {
                        n.active = false;
                    };
                }
                i = end;
            },
            else => {
                // extended autolinks
                if (r.o.linkify and (c == 'h' or c == 'w') and (i == 0 or isWs(s[i - 1]) or s[i - 1] == '(' or s[i - 1] == '*' or s[i - 1] == '_')) {
                    const is_http = v.startsWith(s[i..], "http://") or v.startsWith(s[i..], "https://");
                    const is_www = v.startsWith(s[i..], "www.");
                    if (is_http or is_www) {
                        const e = autolinkEnd(s, i);
                        const url = s[i..e];
                        if (url.len > 8 or (is_www and url.len > 5)) {
                            var in_open_link = false;
                            for (nodes.items) |n| if (n.kind == .open_link and n.active and !n.removed) {
                                in_open_link = true;
                            };
                            if (!in_open_link) {
                                const href = if (is_www) v.concat(&.{ "https://", url }) else url;
                                txt.add(linkHtml(r, href, "", v.escText(url), url));
                                i = e;
                                continue;
                            }
                        }
                    }
                }
                txt.ch(c);
                i += 1;
            },
        }
    }
    flush(&nodes, &txt);
    return emphasis(nodes.items);
}

fn rawHtmlEnd(s: []const u8, i: usize) ?usize {
    if (v.startsWith(s[i..], "<!--")) {
        const e = v.indexOfPos(s, i + 4, "-->") orelse return null;
        return e + 3;
    }
    if (i + 1 >= s.len) return null;
    var j = i + 1;
    if (s[j] == '/') j += 1;
    if (j >= s.len or !std.ascii.isAlphabetic(s[j])) return null;
    while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '-')) j += 1;
    // attributes
    var q: u8 = 0;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == '>') {
            return j + 1;
        } else if (c == '<') return null;
    }
    return null;
}

fn linkHtml(r: *R, dest: []const u8, title: []const u8, text: []const u8, plain: []const u8) []const u8 {
    if (r.o.hooks) |h| if (h.link) |f| if (f(h.ctx, dest, title, text, plain)) |res| return res;
    if (title.len > 0) return v.fmt("<a href=\"{s}\" title=\"{s}\">{s}</a>", .{ escUrl(dest), escAttr(title), text });
    return v.fmt("<a href=\"{s}\">{s}</a>", .{ escUrl(dest), text });
}

fn imageHtml(r: *R, dest: []const u8, title: []const u8, alt: []const u8, is_block: bool) []const u8 {
    if (r.o.hooks) |h| if (h.image) |f| if (f(h.ctx, dest, title, alt, is_block)) |res| return res;
    if (title.len > 0) return v.fmt("<img src=\"{s}\" alt=\"{s}\" title=\"{s}\">", .{ escUrl(dest), escAttr(alt), escAttr(title) });
    return v.fmt("<img src=\"{s}\" alt=\"{s}\">", .{ escUrl(dest), escAttr(alt) });
}

/// CommonMark "process emphasis" over a node slice; returns concatenated HTML.
fn emphasis(nodes: []INode) []const u8 {
    // prefix/suffix html to wrap around ranges
    const n = nodes.len;
    const pre = sys.A.alloc(Buf, n) catch return "";
    const post = sys.A.alloc(Buf, n) catch return "";
    for (pre) |*p| p.* = .{};
    for (post) |*p| p.* = .{};
    var ci: usize = 0;
    while (ci < n) : (ci += 1) {
        const closer = &nodes[ci];
        if (closer.kind != .delim or !closer.can_close or closer.count == 0) continue;
        while (closer.count > 0) {
            // look back for an opener
            var found: ?usize = null;
            var k = ci;
            while (k > 0) : (k -= 1) {
                const op = &nodes[k - 1];
                if (op.kind != .delim or op.ch != closer.ch or !op.can_open or op.count == 0) continue;
                if (closer.ch == '~') {
                    if (op.count != closer.count) continue;
                } else if ((op.can_close or closer.can_open) and (op.orig + closer.orig) % 3 == 0 and !(op.orig % 3 == 0 and closer.orig % 3 == 0)) continue;
                found = k - 1;
                break;
            }
            const oi = found orelse break;
            const op = &nodes[oi];
            var use: usize = if (op.count >= 2 and closer.count >= 2) 2 else 1;
            var tag: []const u8 = if (use == 2) "strong" else "em";
            if (closer.ch == '~') {
                use = closer.count;
                tag = "del";
            }
            op.count -= use;
            closer.count -= use;
            // opener tag goes after the opener's remaining delimiters, closer tag before the closer's remaining
            const open_tag = v.fmt("<{s}>", .{tag});
            const close_tag = v.fmt("</{s}>", .{tag});
            // post[oi] accumulates opening tags (inner-most last); pre[ci] accumulates closing tags (inner-most first)
            const old = post[oi].str();
            post[oi] = .{};
            post[oi].add(open_tag);
            post[oi].add(old);
            pre[ci].add(close_tag);
            // delimiters strictly between opener and closer are deactivated
            var m = oi + 1;
            while (m < ci) : (m += 1) if (nodes[m].kind == .delim) {
                nodes[m].can_open = false;
                nodes[m].can_close = false;
            };
        }
    }
    var b: Buf = .{};
    for (nodes, 0..) |nd, idx| {
        switch (nd.kind) {
            .text => {
                b.add(nd.s);
            },
            .delim => {
                b.add(pre[idx].str());
                var k: usize = 0;
                while (k < nd.count) : (k += 1) b.ch(nd.ch);
                b.add(post[idx].str());
            },
            .open_link, .open_image => b.add(nd.s),
        }
    }
    return b.str();
}

// Hugo's tableofcontents.Fragments tree and tocBuilder, ported for identical output.
const TocNode = struct { id: []const u8 = "", title: []const u8 = "", children: std.ArrayList(*TocNode) = .empty };

fn tocNew() *TocNode {
    const n = sys.A.create(TocNode) catch unreachable;
    n.* = .{};
    return n;
}

const TocWriter = struct {
    b: Buf = .{},
    start: i32,
    stop: i32,
    tag: []const u8,

    fn indent(w: *TocWriter, n: i32) void {
        var k: i32 = 0;
        while (k < n) : (k += 1) w.b.add("  ");
    }
    fn headings(w: *TocWriter, level: i32, ind: i32, hs: []*TocNode) void {
        if (level < w.start) {
            for (hs) |h| w.headings(level + 1, ind, h.children.items);
            return;
        }
        if (w.stop != -1 and level > w.stop) return;
        const has = hs.len > 0;
        if (has) {
            w.b.add("\n");
            w.indent(ind + 1);
            w.b.print("<{s}>\n", .{w.tag});
        }
        for (hs) |h| w.heading(level + 1, ind + 2, h);
        if (has) {
            w.indent(ind + 1);
            w.b.print("</{s}>", .{w.tag});
            w.b.add("\n");
            w.indent(ind);
        }
    }
    fn heading(w: *TocWriter, level: i32, ind: i32, h: *TocNode) void {
        w.indent(ind);
        w.b.add("<li>");
        if (h.id.len > 0 or h.title.len > 0) {
            w.b.add("<a href=\"#");
            for (h.id) |c| switch (c) {
                '<' => w.b.add("&lt;"),
                '>' => w.b.add("&gt;"),
                '&' => w.b.add("&amp;"),
                '\'' => w.b.add("&#39;"),
                '"' => w.b.add("&#34;"),
                else => w.b.ch(c),
            };
            w.b.add("\">");
            w.b.add(h.title);
            w.b.add("</a>");
        }
        w.headings(level, ind, h.children.items);
        w.b.add("</li>\n");
    }
};

/// Builds Hugo's nested <nav id="TableOfContents"> list.
pub fn toc(headings: []const Heading, start: i32, end: i32, ordered: bool) []const u8 {
    var rows: std.ArrayList(*TocNode) = .empty;
    var row: i64 = -1;
    for (headings) |h| {
        if (h.level == 1 or row == -1) row += 1;
        const n = tocNew();
        n.id = h.id;
        n.title = h.html;
        const r: usize = @intCast(row);
        while (rows.items.len <= r) rows.append(sys.A, tocNew()) catch {};
        const level: usize = h.level - 1;
        if (level == 0) {
            rows.items[r] = n;
            continue;
        }
        var cur = rows.items[r];
        var i: usize = 1;
        while (i < level) : (i += 1) {
            if (cur.children.items.len == 0) cur.children.append(sys.A, tocNew()) catch {};
            cur = cur.children.items[cur.children.items.len - 1];
        }
        cur.children.append(sys.A, n) catch {};
    }
    var w = TocWriter{ .start = start, .stop = end, .tag = if (ordered) "ol" else "ul" };
    w.b.add("<nav id=\"TableOfContents\">");
    w.headings(1, 0, rows.items);
    w.b.add("</nav>");
    return w.b.str();
}
