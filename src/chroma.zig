// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Chroma (MIT, Copyright Alec Thomas).
// The original notices and licences are kept in NOTICE and licenses/.
//! A port of Chroma v2 (github.com/alecthomas/chroma, MIT), the syntax
//! highlighter Hugo uses: its XML lexer definitions and styles are embedded
//! verbatim and interpreted here with the same state-machine semantics, and the
//! HTML formatter reproduces Chroma's markup byte for byte.
const std = @import("std");
const sys = @import("sys.zig");
const re2 = @import("regex2.zig");
const data = @import("chroma_data.zig");

// ================================================================ token types

pub const TT = i32;
pub const Background: TT = -1;
pub const PreWrapper: TT = -2;
pub const Line: TT = -3;
pub const LineNumbers: TT = -4;
pub const LineNumbersTable: TT = -5;
pub const LineHighlight: TT = -6;
pub const LineTable: TT = -7;
pub const LineTableTD: TT = -8;
pub const LineLink: TT = -9;
pub const CodeLine: TT = -10;
pub const Error: TT = -11;
pub const Other: TT = -12;
pub const None: TT = -13;
pub const Ignore: TT = -14;
pub const Text: TT = 8000;

const TypeDef = struct { name: []const u8, tt: TT, class: ?[]const u8 };
const types = [_]TypeDef{
    .{ .name = "Background", .tt = -1, .class = "bg" },         .{ .name = "PreWrapper", .tt = -2, .class = "chroma" },
    .{ .name = "Line", .tt = -3, .class = "line" },             .{ .name = "LineNumbers", .tt = -4, .class = "ln" },
    .{ .name = "LineNumbersTable", .tt = -5, .class = "lnt" },  .{ .name = "LineHighlight", .tt = -6, .class = "hl" },
    .{ .name = "LineTable", .tt = -7, .class = "lntable" },     .{ .name = "LineTableTD", .tt = -8, .class = "lntd" },
    .{ .name = "LineLink", .tt = -9, .class = "lnlinks" },      .{ .name = "CodeLine", .tt = -10, .class = "cl" },
    .{ .name = "Error", .tt = -11, .class = "err" },            .{ .name = "Other", .tt = -12, .class = "x" },
    .{ .name = "None", .tt = -13, .class = null },              .{ .name = "Ignore", .tt = -14, .class = null },
    .{ .name = "Keyword", .tt = 1000, .class = "k" },           .{ .name = "KeywordConstant", .tt = 1001, .class = "kc" },
    .{ .name = "KeywordDeclaration", .tt = 1002, .class = "kd" }, .{ .name = "KeywordNamespace", .tt = 1003, .class = "kn" },
    .{ .name = "KeywordPseudo", .tt = 1004, .class = "kp" },    .{ .name = "KeywordReserved", .tt = 1005, .class = "kr" },
    .{ .name = "KeywordType", .tt = 1006, .class = "kt" },      .{ .name = "Name", .tt = 2000, .class = "n" },
    .{ .name = "NameAttribute", .tt = 2001, .class = "na" },    .{ .name = "NameClass", .tt = 2002, .class = "nc" },
    .{ .name = "NameConstant", .tt = 2003, .class = "no" },     .{ .name = "NameDecorator", .tt = 2004, .class = "nd" },
    .{ .name = "NameEntity", .tt = 2005, .class = "ni" },       .{ .name = "NameException", .tt = 2006, .class = "ne" },
    .{ .name = "NameKeyword", .tt = 2007, .class = null },      .{ .name = "NameLabel", .tt = 2008, .class = "nl" },
    .{ .name = "NameNamespace", .tt = 2009, .class = "nn" },    .{ .name = "NameOperator", .tt = 2010, .class = null },
    .{ .name = "NameOther", .tt = 2011, .class = "nx" },        .{ .name = "NamePseudo", .tt = 2012, .class = null },
    .{ .name = "NameProperty", .tt = 2013, .class = "py" },     .{ .name = "NameTag", .tt = 2014, .class = "nt" },
    .{ .name = "NameBuiltin", .tt = 2100, .class = "nb" },      .{ .name = "NameBuiltinPseudo", .tt = 2101, .class = "bp" },
    .{ .name = "NameVariable", .tt = 2200, .class = "nv" },     .{ .name = "NameVariableAnonymous", .tt = 2201, .class = null },
    .{ .name = "NameVariableClass", .tt = 2202, .class = "vc" }, .{ .name = "NameVariableGlobal", .tt = 2203, .class = "vg" },
    .{ .name = "NameVariableInstance", .tt = 2204, .class = "vi" }, .{ .name = "NameVariableMagic", .tt = 2205, .class = "vm" },
    .{ .name = "NameFunction", .tt = 2300, .class = "nf" },     .{ .name = "NameFunctionMagic", .tt = 2301, .class = "fm" },
    .{ .name = "Literal", .tt = 3000, .class = "l" },           .{ .name = "LiteralDate", .tt = 3001, .class = "ld" },
    .{ .name = "LiteralOther", .tt = 3002, .class = null },     .{ .name = "LiteralString", .tt = 3100, .class = "s" },
    .{ .name = "LiteralStringAffix", .tt = 3101, .class = "sa" }, .{ .name = "LiteralStringAtom", .tt = 3102, .class = null },
    .{ .name = "LiteralStringBacktick", .tt = 3103, .class = "sb" }, .{ .name = "LiteralStringBoolean", .tt = 3104, .class = null },
    .{ .name = "LiteralStringChar", .tt = 3105, .class = "sc" }, .{ .name = "LiteralStringDelimiter", .tt = 3106, .class = "dl" },
    .{ .name = "LiteralStringDoc", .tt = 3107, .class = "sd" }, .{ .name = "LiteralStringDouble", .tt = 3108, .class = "s2" },
    .{ .name = "LiteralStringEscape", .tt = 3109, .class = "se" }, .{ .name = "LiteralStringHeredoc", .tt = 3110, .class = "sh" },
    .{ .name = "LiteralStringInterpol", .tt = 3111, .class = "si" }, .{ .name = "LiteralStringName", .tt = 3112, .class = null },
    .{ .name = "LiteralStringOther", .tt = 3113, .class = "sx" }, .{ .name = "LiteralStringRegex", .tt = 3114, .class = "sr" },
    .{ .name = "LiteralStringSingle", .tt = 3115, .class = "s1" }, .{ .name = "LiteralStringSymbol", .tt = 3116, .class = "ss" },
    .{ .name = "LiteralNumber", .tt = 3200, .class = "m" },     .{ .name = "LiteralNumberBin", .tt = 3201, .class = "mb" },
    .{ .name = "LiteralNumberFloat", .tt = 3202, .class = "mf" }, .{ .name = "LiteralNumberHex", .tt = 3203, .class = "mh" },
    .{ .name = "LiteralNumberInteger", .tt = 3204, .class = "mi" }, .{ .name = "LiteralNumberIntegerLong", .tt = 3205, .class = "il" },
    .{ .name = "LiteralNumberOct", .tt = 3206, .class = "mo" }, .{ .name = "LiteralNumberByte", .tt = 3207, .class = null },
    .{ .name = "Operator", .tt = 4000, .class = "o" },          .{ .name = "OperatorWord", .tt = 4001, .class = "ow" },
    .{ .name = "OperatorReserved", .tt = 4002, .class = "or" }, .{ .name = "Punctuation", .tt = 5000, .class = "p" },
    .{ .name = "Comment", .tt = 6000, .class = "c" },           .{ .name = "CommentHashbang", .tt = 6001, .class = "ch" },
    .{ .name = "CommentMultiline", .tt = 6002, .class = "cm" }, .{ .name = "CommentSingle", .tt = 6003, .class = "c1" },
    .{ .name = "CommentSpecial", .tt = 6004, .class = "cs" },   .{ .name = "CommentPreproc", .tt = 6100, .class = "cp" },
    .{ .name = "CommentPreprocFile", .tt = 6101, .class = "cpf" }, .{ .name = "Generic", .tt = 7000, .class = "g" },
    .{ .name = "GenericDeleted", .tt = 7001, .class = "gd" },   .{ .name = "GenericEmph", .tt = 7002, .class = "ge" },
    .{ .name = "GenericError", .tt = 7003, .class = "gr" },     .{ .name = "GenericHeading", .tt = 7004, .class = "gh" },
    .{ .name = "GenericInserted", .tt = 7005, .class = "gi" },  .{ .name = "GenericOutput", .tt = 7006, .class = "go" },
    .{ .name = "GenericPrompt", .tt = 7007, .class = "gp" },    .{ .name = "GenericStrong", .tt = 7008, .class = "gs" },
    .{ .name = "GenericSubheading", .tt = 7009, .class = "gu" }, .{ .name = "GenericTraceback", .tt = 7010, .class = "gt" },
    .{ .name = "GenericUnderline", .tt = 7011, .class = "gl" }, .{ .name = "Text", .tt = 8000, .class = "" },
    .{ .name = "TextWhitespace", .tt = 8001, .class = "w" },    .{ .name = "TextSymbol", .tt = 8002, .class = null },
    .{ .name = "TextPunctuation", .tt = 8003, .class = null },
};

fn typeByName(name: []const u8) ?TT {
    for (types) |t| if (std.mem.eql(u8, t.name, name)) return t.tt;
    // aliases used by some definitions
    const aliases = .{
        .{ "Whitespace", 8001 },       .{ "String", 3100 },          .{ "StringDouble", 3108 }, .{ "StringSingle", 3115 },
        .{ "StringEscape", 3109 },     .{ "Number", 3200 },          .{ "Date", 3001 },         .{ "StringAffix", 3101 },
        .{ "StringBacktick", 3103 },   .{ "StringChar", 3105 },      .{ "StringDelimiter", 3106 }, .{ "StringDoc", 3107 },
        .{ "StringHeredoc", 3110 },    .{ "StringInterpol", 3111 },  .{ "StringOther", 3113 },  .{ "StringRegex", 3114 },
        .{ "StringSymbol", 3116 },     .{ "NumberBin", 3201 },       .{ "NumberFloat", 3202 },  .{ "NumberHex", 3203 },
        .{ "NumberInteger", 3204 },    .{ "NumberIntegerLong", 3205 }, .{ "NumberOct", 3206 },
    };
    inline for (aliases) |a| if (std.mem.eql(u8, a[0], name)) return a[1];
    return null;
}

fn isStandard(tt: TT) bool {
    for (types) |t| if (t.tt == tt) return t.class != null;
    return false;
}
fn stdClass(tt: TT) ?[]const u8 {
    for (types) |t| if (t.tt == tt) return t.class;
    return null;
}
fn parent(t: TT) TT {
    if (@rem(t, 100) != 0) return @divTrunc(t, 100) * 100;
    if (@rem(t, 1000) != 0) return @divTrunc(t, 1000) * 1000;
    return 0;
}
fn category(t: TT) TT {
    return @divTrunc(t, 1000) * 1000;
}
fn subCategory(t: TT) TT {
    return @divTrunc(t, 100) * 100;
}

pub const Token = struct { t: TT, s: []const u8 };

// ================================================================ XML

const Attr = struct { name: []const u8, value: []const u8 };
const El = struct {
    name: []const u8,
    attrs: []Attr = &.{},
    kids: []*El = &.{},
    text: []const u8 = "",

    fn attr(e: *const El, n: []const u8) ?[]const u8 {
        for (e.attrs) |a| if (std.mem.eql(u8, a.name, n)) return a.value;
        return null;
    }
    fn child(e: *const El, n: []const u8) ?*El {
        for (e.kids) |k| if (std.mem.eql(u8, k.name, n)) return k;
        return null;
    }
};

fn unescapeXml(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, s, i, ';')) |e| {
                const ent = s[i + 1 .. e];
                var cp: ?u21 = null;
                if (std.mem.eql(u8, ent, "lt")) cp = '<' else if (std.mem.eql(u8, ent, "gt")) cp = '>' else if (std.mem.eql(u8, ent, "amp")) cp = '&' else if (std.mem.eql(u8, ent, "quot")) cp = '"' else if (std.mem.eql(u8, ent, "apos")) cp = '\'' else if (ent.len > 1 and ent[0] == '#') {
                    cp = if (ent[1] == 'x') std.fmt.parseInt(u21, ent[2..], 16) catch null else std.fmt.parseInt(u21, ent[1..], 10) catch null;
                }
                if (cp) |c| {
                    var buf: [4]u8 = undefined;
                    const l = std.unicode.utf8Encode(c, &buf) catch 0;
                    out.appendSlice(sys.A, buf[0..l]) catch {};
                    i = e + 1;
                    continue;
                }
            }
        }
        out.append(sys.A, s[i]) catch {};
        i += 1;
    }
    return out.items;
}

const XmlParser = struct {
    s: []const u8,
    i: usize = 0,

    fn skipMisc(p: *XmlParser) void {
        while (p.i < p.s.len) {
            if (std.mem.startsWith(u8, p.s[p.i..], "<!--")) {
                p.i = if (std.mem.indexOfPos(u8, p.s, p.i, "-->")) |e| e + 3 else p.s.len;
            } else if (std.mem.startsWith(u8, p.s[p.i..], "<?")) {
                p.i = if (std.mem.indexOfPos(u8, p.s, p.i, "?>")) |e| e + 2 else p.s.len;
            } else if (std.ascii.isWhitespace(p.s[p.i])) {
                p.i += 1;
            } else break;
        }
    }

    fn element(p: *XmlParser) anyerror!*El {
        p.skipMisc();
        if (p.i >= p.s.len or p.s[p.i] != '<') return error.BadXml;
        p.i += 1;
        const ns = p.i;
        while (p.i < p.s.len and !std.ascii.isWhitespace(p.s[p.i]) and p.s[p.i] != '>' and p.s[p.i] != '/') p.i += 1;
        const el = try sys.A.create(El);
        el.* = .{ .name = p.s[ns..p.i] };
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
            if (p.i >= p.s.len) return error.BadXml;
            if (p.s[p.i] == '/') {
                p.i += 2;
                el.attrs = attrs.items;
                return el;
            }
            if (p.s[p.i] == '>') {
                p.i += 1;
                break;
            }
            const an = p.i;
            while (p.i < p.s.len and p.s[p.i] != '=' and !std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
            const name = p.s[an..p.i];
            while (p.i < p.s.len and p.s[p.i] != '"' and p.s[p.i] != '\'') p.i += 1;
            const q = p.s[p.i];
            const vs = p.i + 1;
            const ve = std.mem.indexOfScalarPos(u8, p.s, vs, q) orelse return error.BadXml;
            try attrs.append(sys.A, .{ .name = name, .value = unescapeXml(p.s[vs..ve]) });
            p.i = ve + 1;
        }
        el.attrs = attrs.items;
        var kids: std.ArrayList(*El) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (p.i < p.s.len) {
            if (std.mem.startsWith(u8, p.s[p.i..], "</")) {
                p.i = (std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse p.s.len) + 1;
                break;
            }
            if (std.mem.startsWith(u8, p.s[p.i..], "<!--")) {
                p.i = if (std.mem.indexOfPos(u8, p.s, p.i, "-->")) |e| e + 3 else p.s.len;
                continue;
            }
            if (std.mem.startsWith(u8, p.s[p.i..], "<![CDATA[")) {
                const e = std.mem.indexOfPos(u8, p.s, p.i, "]]>") orelse p.s.len;
                try text.appendSlice(sys.A, p.s[p.i + 9 .. e]);
                p.i = e + 3;
                continue;
            }
            if (p.s[p.i] == '<') {
                try kids.append(sys.A, try p.element());
                continue;
            }
            const ts = p.i;
            while (p.i < p.s.len and p.s[p.i] != '<') p.i += 1;
            try text.appendSlice(sys.A, unescapeXml(p.s[ts..p.i]));
        }
        el.kids = kids.items;
        el.text = std.mem.trim(u8, text.items, " \t\r\n");
        return el;
    }
};

fn parseXml(s: []const u8) !*El {
    var p = XmlParser{ .s = s };
    return p.element();
}

// ================================================================ lexers

const Emitter = union(enum) {
    none,
    token: TT,
    bygroups: []Emitter,
    using: struct { lexer: []const u8, remap_other: ?TT },
    usingself: []const u8,
    usingbygroup: struct { name_group: usize, code_group: usize, emitters: []Emitter },
};

const Mutator = union(enum) {
    none,
    push: []const []const u8, // empty = push current state
    pop: usize,
    include: []const u8,
    combined: []const []const u8,
    multi: []Mutator,
};

const Rule = struct {
    pattern: []const u8,
    emitter: Emitter = .none,
    mutator: Mutator = .none,
    re: ?*re2.Regex = null,
    bad: bool = false,
};

const Config = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    filenames: []const []const u8 = &.{},
    alias_filenames: []const []const u8 = &.{},
    mimes: []const []const u8 = &.{},
    priority: f32 = 0,
    case_insensitive: bool = false,
    dot_all: bool = false,
    not_multiline: bool = false,
    ensure_nl: bool = false,
};

pub const Lexer = struct {
    cfg: Config,
    src: []const u8 = "", // XML source
    states: ?std.StringHashMapUnmanaged([]Rule) = null,
    delegate: ?struct { root: []const u8, language: []const u8 } = null,
    rules_from: ?[]const u8 = null, // share rules with another lexer (by name)
    markdown: bool = false,
    remaps: []const Remap = &.{},
    renamed: ?[]const u8 = null, // keep this name when the XML config is (re)parsed
};

const Remap = struct { from: TT, to: TT, words: []const []const u8 };

var registry: ?[]*Lexer = null;

fn textOf(e: *const El, n: []const u8) ?[]const u8 {
    return if (e.child(n)) |c| c.text else null;
}

fn parseConfig(el: *const El) Config {
    var c = Config{ .name = textOf(el, "name") orelse "" };
    var al: std.ArrayList([]const u8) = .empty;
    var fl: std.ArrayList([]const u8) = .empty;
    var afl: std.ArrayList([]const u8) = .empty;
    var ml: std.ArrayList([]const u8) = .empty;
    for (el.kids) |k| {
        if (std.mem.eql(u8, k.name, "mime_type")) ml.append(sys.A, k.text) catch {};
        if (std.mem.eql(u8, k.name, "alias")) al.append(sys.A, k.text) catch {};
        if (std.mem.eql(u8, k.name, "filename")) fl.append(sys.A, k.text) catch {};
        if (std.mem.eql(u8, k.name, "alias_filename")) afl.append(sys.A, k.text) catch {};
        if (std.mem.eql(u8, k.name, "priority")) c.priority = std.fmt.parseFloat(f32, k.text) catch 0;
        if (std.mem.eql(u8, k.name, "case_insensitive")) c.case_insensitive = std.mem.eql(u8, k.text, "true");
        if (std.mem.eql(u8, k.name, "dot_all")) c.dot_all = std.mem.eql(u8, k.text, "true");
        if (std.mem.eql(u8, k.name, "not_multiline")) c.not_multiline = std.mem.eql(u8, k.text, "true");
        if (std.mem.eql(u8, k.name, "ensure_nl")) c.ensure_nl = std.mem.eql(u8, k.text, "true");
    }
    c.aliases = al.items;
    c.filenames = fl.items;
    c.alias_filenames = afl.items;
    c.mimes = ml.items;
    return c;
}

fn getRegistry() []*Lexer {
    if (registry) |r| return r;
    var list: std.ArrayList(*Lexer) = .empty;
    for (data.lexers) |src| {
        // parse only the <config> block for the registry
        const cs = std.mem.indexOf(u8, src, "<config") orelse continue;
        const ce = std.mem.indexOfPos(u8, src, cs, "</config>") orelse continue;
        const el = parseXml(src[cs .. ce + 9]) catch continue;
        const lx = sys.A.create(Lexer) catch continue;
        lx.* = .{ .cfg = parseConfig(el), .src = src };
        if (std.mem.eql(u8, lx.cfg.name, "markdown")) lx.markdown = true;
        list.append(sys.A, lx) catch {};
    }
    // Lexers Chroma defines in Go on top of the XML ones
    const gt = sys.A.create(Lexer) catch unreachable;
    gt.* = .{ .cfg = .{ .name = "Go Text Template", .aliases = &.{"go-text-template"} }, .rules_from = "Go Template" };
    list.append(sys.A, gt) catch {};
    const yj = sys.A.create(Lexer) catch unreachable;
    yj.* = .{ .cfg = .{ .name = "YAML+Jinja#lang", .dot_all = true }, .rules_from = "Django/Jinja" };
    list.append(sys.A, yj) catch {};
    const Spec = struct { name: []const u8, root: []const u8, lang: []const u8, aliases: []const []const u8 = &.{}, filenames: []const []const u8 = &.{}, mimes: []const []const u8 = &.{}, priority: f32 = 0 };
    const specs = [_]Spec{
        .{ .name = "Go HTML Template", .root = "HTML", .lang = "Go Template", .aliases = &.{"go-html-template"} },
        .{ .name = "ERB", .root = "HTML", .lang = "ERB#lang", .aliases = &.{ "erb", "html+erb", "html+ruby", "rhtml" }, .filenames = &.{ "*.erb", "*.html.erb", "*.xml.erb", "*.rhtml" }, .mimes = &.{"application/x-ruby-templating"} },
        .{ .name = "YAML+Jinja", .root = "YAML", .lang = "YAML+Jinja#lang", .aliases = &.{ "yaml+jinja", "salt", "sls", "ansible" }, .filenames = &.{"*.sls"}, .mimes = &.{ "text/x-yaml+jinja", "text/x-sls" } },
        .{ .name = "Svelte", .root = "HTML", .lang = "Svelte#lang" },
        .{ .name = "PHTML", .root = "HTML", .lang = "PHTML#lang" },
    };
    for (specs) |sp| {
        var cfg = Config{ .name = sp.name, .aliases = sp.aliases, .filenames = sp.filenames, .mimes = sp.mimes, .priority = sp.priority };
        // a delegate takes over the name of the XML lexer that provides its language rules
        if (std.mem.endsWith(u8, sp.lang, "#lang")) {
            const base = sp.lang[0 .. sp.lang.len - 5];
            for (list.items) |lx| if (std.mem.eql(u8, lx.cfg.name, base) and lx.rules_from == null) {
                if (sp.aliases.len == 0) {
                    cfg.aliases = lx.cfg.aliases;
                    cfg.filenames = lx.cfg.filenames;
                    cfg.mimes = lx.cfg.mimes;
                    cfg.priority = lx.cfg.priority;
                }
                lx.cfg.name = sp.lang;
                lx.cfg.aliases = &.{};
                lx.cfg.filenames = &.{};
                lx.cfg.alias_filenames = &.{};
                lx.renamed = sp.lang;
            };
        }
        const d = sys.A.create(Lexer) catch unreachable;
        d.* = .{ .cfg = cfg, .delegate = .{ .root = sp.root, .language = sp.lang } };
        list.append(sys.A, d) catch {};
    }
    std.mem.sort(*Lexer, list.items, {}, struct {
        fn lt(_: void, a: *Lexer, b: *Lexer) bool {
            return std.ascii.lessThanIgnoreCase(a.cfg.name, b.cfg.name);
        }
    }.lt);
    registry = list.items;
    return list.items;
}

fn byNameOrAlias(name: []const u8, ci: bool) ?*Lexer {
    for (getRegistry()) |lx| {
        if (ci) {
            if (std.ascii.eqlIgnoreCase(lx.cfg.name, name)) return lx;
        } else if (std.mem.eql(u8, lx.cfg.name, name)) return lx;
    }
    for (getRegistry()) |lx| for (lx.cfg.aliases) |a| {
        if (std.mem.eql(u8, a, name)) return lx;
    };
    return null;
}

fn globMatch(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pat.len) {
            const c = pat[p];
            if (c == '*') {
                star_p = p;
                star_i = i;
                p += 1;
                continue;
            }
            if (c == '?' and s[i] != '/') {
                p += 1;
                i += 1;
                continue;
            }
            if (c == '[') {
                if (std.mem.indexOfScalarPos(u8, pat, p + 1, ']')) |e| {
                    var set = pat[p + 1 .. e];
                    var neg = false;
                    if (set.len > 0 and (set[0] == '^' or set[0] == '!')) {
                        neg = true;
                        set = set[1..];
                    }
                    var hit = false;
                    var k: usize = 0;
                    while (k < set.len) : (k += 1) {
                        if (k + 2 < set.len and set[k + 1] == '-') {
                            if (s[i] >= set[k] and s[i] <= set[k + 2]) hit = true;
                            k += 2;
                        } else if (set[k] == s[i]) hit = true;
                    }
                    if (hit != neg) {
                        p = e + 1;
                        i += 1;
                        continue;
                    }
                }
            } else if (c == '\\' and p + 1 < pat.len) {
                if (pat[p + 1] == s[i]) {
                    p += 2;
                    i += 1;
                    continue;
                }
            } else if (c == s[i]) {
                p += 1;
                i += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            if (s[star_i] == '/') return false;
            p = sp + 1;
            star_i += 1;
            i = star_i;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn prio(l: *Lexer) f32 {
    return if (l.cfg.priority == 0) 1 else l.cfg.priority;
}

fn matchFilename(filename: []const u8) ?*Lexer {
    const base = if (std.mem.lastIndexOfScalar(u8, filename, '/')) |i| filename[i + 1 ..] else filename;
    const suffixes = [_][]const u8{ "", ".bak", ".old", ".orig", ".dist", ".in", ".gen", ".tmpl", ".tpl" };
    var best: ?*Lexer = null;
    for (getRegistry()) |lx| {
        var hit = false;
        for (lx.cfg.filenames) |g| {
            for (suffixes) |suf| {
                if (globMatch(sys.A.dupe(u8, std.mem.concat(sys.A, u8, &.{ g, suf }) catch g) catch g, base)) hit = true;
            }
        }
        if (hit and (best == null or prio(lx) > prio(best.?))) best = lx;
    }
    if (best) |b| return b;
    for (getRegistry()) |lx| {
        for (lx.cfg.alias_filenames) |g| if (globMatch(g, base)) {
            if (best == null or prio(lx) > prio(best.?)) best = lx;
        };
    }
    return best;
}

/// Chroma's lexers.Get: name, alias, lower-cased variants, then filename globs.
pub fn get(name: []const u8) ?*Lexer {
    if (name.len == 0) return null;
    if (byNameOrAlias(name, false)) |l| return l;
    const low = std.ascii.allocLowerString(sys.A, name) catch name;
    for (getRegistry()) |lx| if (std.ascii.eqlIgnoreCase(lx.cfg.name, low) and std.mem.eql(u8, low, std.ascii.allocLowerString(sys.A, lx.cfg.name) catch "")) return lx;
    if (byNameOrAlias(low, false)) |l| return l;
    const a = matchFilename(std.mem.concat(sys.A, u8, &.{ "filename.", name }) catch name);
    const b = matchFilename(name);
    if (a != null and b != null) return if (prio(b.?) > prio(a.?)) b else a;
    return a orelse b;
}

pub fn lexerName(l: *const Lexer) []const u8 {
    return l.cfg.name;
}

fn parseEmitter(el: *const El) Emitter {
    if (std.mem.eql(u8, el.name, "token")) {
        const t = el.attr("type") orelse return .none;
        return .{ .token = typeByName(t) orelse Error };
    }
    if (std.mem.eql(u8, el.name, "bygroups")) {
        const list = sys.A.alloc(Emitter, el.kids.len) catch return .none;
        for (el.kids, 0..) |k, i| list[i] = parseEmitter(k);
        return .{ .bygroups = list };
    }
    if (std.mem.eql(u8, el.name, "using")) {
        const ro = if (el.attr("remap_other")) |r| typeByName(r) else null;
        return .{ .using = .{ .lexer = el.attr("lexer") orelse "", .remap_other = ro } };
    }
    if (std.mem.eql(u8, el.name, "usingself")) return .{ .usingself = el.attr("state") orelse "root" };
    if (std.mem.eql(u8, el.name, "usingbygroup")) {
        var ems: []Emitter = &.{};
        if (el.child("emitters")) |e| {
            ems = sys.A.alloc(Emitter, e.kids.len) catch &.{};
            for (e.kids, 0..) |k, i| ems[i] = parseEmitter(k);
        }
        return .{ .usingbygroup = .{
            .name_group = std.fmt.parseInt(usize, textOf(el, "sublexer_name_group") orelse "0", 10) catch 0,
            .code_group = std.fmt.parseInt(usize, textOf(el, "code_group") orelse "0", 10) catch 0,
            .emitters = ems,
        } };
    }
    return .none;
}

fn allAttrs(el: *const El, n: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (el.attrs) |a| if (std.mem.eql(u8, a.name, n)) out.append(sys.A, a.value) catch {};
    return out.items;
}

fn parseMutator(el: *const El) ?Mutator {
    const n = el.name;
    if (std.mem.eql(u8, n, "push")) return .{ .push = allAttrs(el, "state") };
    if (std.mem.eql(u8, n, "pop")) return .{ .pop = std.fmt.parseInt(usize, el.attr("depth") orelse "1", 10) catch 1 };
    if (std.mem.eql(u8, n, "include")) return .{ .include = el.attr("state") orelse "" };
    if (std.mem.eql(u8, n, "combined")) return .{ .combined = allAttrs(el, "state") };
    if (std.mem.eql(u8, n, "mutators")) {
        var list: std.ArrayList(Mutator) = .empty;
        for (el.kids) |k| if (parseMutator(k)) |m| list.append(sys.A, m) catch {};
        return .{ .multi = list.items };
    }
    return null;
}

fn loadStates(lx: *Lexer) !*std.StringHashMapUnmanaged([]Rule) {
    if (lx.states != null) return &lx.states.?;
    if (lx.rules_from) |rf| {
        const other = byNameOrAlias(rf, false) orelse return error.NoLexer;
        lx.states = (try loadStates(other)).*;
        lx.cfg.case_insensitive = other.cfg.case_insensitive;
        lx.cfg.dot_all = other.cfg.dot_all;
        lx.cfg.not_multiline = other.cfg.not_multiline;
        lx.cfg.ensure_nl = other.cfg.ensure_nl;
        return &lx.states.?;
    }
    const root = try parseXml(lx.src);
    if (root.child("config")) |c| {
        const keep = lx.cfg;
        lx.cfg = parseConfig(c);
        if (lx.renamed) |rn| {
            lx.cfg.name = rn;
            lx.cfg.aliases = keep.aliases;
            lx.cfg.filenames = keep.filenames;
            lx.cfg.alias_filenames = keep.alias_filenames;
        }
    }
    if (root.child("remaps")) |rm| {
        var list: std.ArrayList(Remap) = .empty;
        for (rm.kids) |k| {
            var words: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, k.text, " \n\t");
            while (it.next()) |w| try words.append(sys.A, w);
            try list.append(sys.A, .{ .from = typeByName(k.attr("from") orelse "") orelse 0, .to = typeByName(k.attr("to") orelse "") orelse 0, .words = words.items });
        }
        lx.remaps = list.items;
    }
    var states: std.StringHashMapUnmanaged([]Rule) = .empty;
    const rules_el = root.child("rules") orelse return error.BadXml;
    for (rules_el.kids) |st| {
        if (!std.mem.eql(u8, st.name, "state")) continue;
        var rules: std.ArrayList(Rule) = .empty;
        for (st.kids) |r| {
            if (!std.mem.eql(u8, r.name, "rule")) continue;
            var rule = Rule{ .pattern = r.attr("pattern") orelse "" };
            for (r.kids) |k| {
                if (parseMutator(k)) |m| {
                    rule.mutator = m;
                } else rule.emitter = parseEmitter(k);
            }
            try rules.append(sys.A, rule);
        }
        try states.put(sys.A, st.attr("name") orelse "", rules.items);
    }
    // expand include and combined (Chroma does this when compiling)
    var changed = true;
    var guard: usize = 0;
    while (changed and guard < 10000) : (guard += 1) {
        changed = false;
        var it = states.iterator();
        outer: while (it.next()) |e| {
            for (e.value_ptr.*, 0..) |r, i| {
                switch (r.mutator) {
                    .include => |inc| {
                        const inc_rules = states.get(inc) orelse &.{};
                        var nl: std.ArrayList(Rule) = .empty;
                        try nl.appendSlice(sys.A, e.value_ptr.*[0..i]);
                        try nl.appendSlice(sys.A, inc_rules);
                        try nl.appendSlice(sys.A, e.value_ptr.*[i + 1 ..]);
                        e.value_ptr.* = nl.items;
                        changed = true;
                        break :outer;
                    },
                    .combined => |cs| {
                        const name = try std.mem.concat(sys.A, u8, &.{ "__combined_", try std.mem.join(sys.A, "__", cs) });
                        if (!states.contains(name)) {
                            var nl: std.ArrayList(Rule) = .empty;
                            for (cs) |s| try nl.appendSlice(sys.A, states.get(s) orelse &.{});
                            try states.put(sys.A, name, nl.items);
                        }
                        const list = try sys.A.dupe(Rule, states.get(e.key_ptr.*).?);
                        const names = try sys.A.alloc([]const u8, 1);
                        names[0] = name;
                        list[i].mutator = .{ .push = names };
                        try states.put(sys.A, e.key_ptr.*, list);
                        changed = true;
                        break :outer;
                    },
                    else => {},
                }
            }
        }
    }
    lx.states = states;
    return &lx.states.?;
}

fn compileRule(lx: *const Lexer, r: *Rule) ?*re2.Regex {
    if (r.re) |x| return x;
    if (r.bad) return null;
    var flags: std.ArrayList(u8) = .empty;
    if (!lx.cfg.not_multiline) flags.append(sys.A, 'm') catch {};
    if (lx.cfg.case_insensitive) flags.append(sys.A, 'i') catch {};
    if (lx.cfg.dot_all) flags.append(sys.A, 's') catch {};
    const pat = if (flags.items.len > 0)
        std.mem.concat(sys.A, u8, &.{ "(?", flags.items, ")(?:", r.pattern, ")" }) catch return null
    else
        std.mem.concat(sys.A, u8, &.{ "(?:", r.pattern, ")" }) catch return null;
    r.re = re2.compile(pat) catch {
        r.bad = true;
        if (sys.getenv("ZSSG_DEBUG_CHROMA") != null) std.debug.print("chroma: {s}: bad pattern: {s}\n", .{ lx.cfg.name, re2.err_msg });
        return null;
    };
    return r.re;
}

const Opts = struct { state: []const u8 = "root", nested: bool = false, ensure_lf: bool = true };

fn ensureLf(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    var out = sys.A.alloc(u8, s.len) catch return s;
    var j: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '\r') {
            if (i + 1 < s.len and s[i + 1] == '\n') continue;
            out[j] = '\n';
        } else out[j] = c;
        j += 1;
    }
    return out[0..j];
}

fn emit(out: *std.ArrayList(Token), lx: *Lexer, em: Emitter, groups: []const []const u8) anyerror!void {
    switch (em) {
        .none => {},
        .token => |t| if (t != Ignore) try out.append(sys.A, .{ .t = t, .s = groups[0] }),
        .bygroups => |list| {
            if (list.len != groups.len - 1) {
                try out.append(sys.A, .{ .t = Error, .s = groups[0] });
                return;
            }
            for (list, 0..) |e, i| try emit(out, lx, e, groups[i + 1 .. i + 2]);
        },
        .using => |u| {
            const sub = get(u.lexer) orelse return;
            const toks = try tokenise(sub, .{ .state = "root", .nested = true, .ensure_lf = false }, groups[0]);
            if (u.remap_other) |ro| {
                for (toks) |t| try out.append(sys.A, .{ .t = if (t.t == Other) ro else t.t, .s = t.s });
            } else try out.appendSlice(sys.A, toks);
        },
        .usingself => |st| {
            const toks = try tokenise(lx, .{ .state = st, .nested = true, .ensure_lf = false }, groups[0]);
            try out.appendSlice(sys.A, toks);
        },
        .usingbygroup => |u| {
            const sub = if (u.name_group < groups.len) get(groups[u.name_group]) else null;
            for (groups[1..], 0..) |g, i| {
                if (i == u.code_group - 1 and sub != null) {
                    try out.appendSlice(sys.A, try tokenise(sub.?, .{}, g));
                } else if (i < u.emitters.len) {
                    try emit(out, lx, u.emitters[i], &.{g});
                }
            }
        },
    }
}

fn mutate(m: Mutator, stack: *std.ArrayList([]const u8), cur: []const u8) void {
    switch (m) {
        .none, .include, .combined => {},
        .push => |states| {
            if (states.len == 0) {
                stack.append(sys.A, cur) catch {};
            } else for (states) |s| {
                if (std.mem.eql(u8, s, "#pop")) {
                    if (stack.items.len > 0) stack.items.len -= 1;
                } else stack.append(sys.A, s) catch {};
            }
        },
        .pop => |d| stack.items.len -= @min(d, stack.items.len),
        .multi => |list| for (list) |x| mutate(x, stack, cur),
    }
}

fn tokeniseRegex(lx: *Lexer, opts: Opts, text_in: []const u8) anyerror![]Token {
    const states = try loadStates(lx);
    var text = if (opts.ensure_lf) ensureLf(text_in) else text_in;
    var added = false;
    if (!opts.nested and lx.cfg.ensure_nl and !std.mem.endsWith(u8, text, "\n")) {
        text = try std.mem.concat(sys.A, u8, &.{ text, "\n" });
        added = true;
    }
    const end = if (added) text.len - 1 else text.len;
    var out: std.ArrayList(Token) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(sys.A, opts.state);
    var pos: usize = 0;
    var caps_buf: [1024]isize = undefined;
    var groups_buf: [512][]const u8 = undefined;
    while (pos < end and stack.items.len > 0) {
        const st = stack.items[stack.items.len - 1];
        const rules = states.get(st) orelse return error.UnknownState;
        var matched: ?*Rule = null;
        var mlen: usize = 0;
        var ngroups: usize = 0;
        for (rules) |*r| {
            const re = compileRule(lx, r) orelse continue;
            if (re.ncap > 512) continue;
            const ncap = re.ncap;
            const caps = caps_buf[0 .. 2 * @as(usize, re.ncap)];
            if (re2.matchAt(re, text, pos, caps)) |e| {
                matched = r;
                mlen = e - pos;
                ngroups = ncap;
                for (0..ncap) |g| {
                    const a = caps[2 * g];
                    const b = caps[2 * g + 1];
                    groups_buf[g] = if (a >= 0 and b >= a) text[@intCast(a)..@intCast(b)] else "";
                }
                break;
            }
        }
        const r = matched orelse {
            if (text[pos] == '\n' and !std.mem.eql(u8, st, opts.state)) {
                stack.items.len = 0;
                try stack.append(sys.A, opts.state);
                continue;
            }
            const l = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
            const n = @min(l, text.len - pos);
            try out.append(sys.A, .{ .t = Error, .s = text[pos .. pos + n] });
            pos += n;
            continue;
        };
        pos += mlen;
        mutate(r.mutator, &stack, st);
        const groups = try sys.A.dupe([]const u8, groups_buf[0..ngroups]);
        try emit(&out, lx, r.emitter, groups);
    }
    if (pos != text.len and stack.items.len == 0) try out.append(sys.A, .{ .t = Error, .s = text[pos..] });
    return out.items;
}

fn coalesce(toks: []const Token) []Token {
    var out: std.ArrayList(Token) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var cur_t: TT = 0;
    var have = false;
    for (toks) |t| {
        if (t.s.len == 0) continue;
        if (have and cur_t == t.t and cur.items.len < 8192) {
            cur.appendSlice(sys.A, t.s) catch {};
            continue;
        }
        if (have) out.append(sys.A, .{ .t = cur_t, .s = cur.items }) catch {};
        cur = .empty;
        cur.appendSlice(sys.A, t.s) catch {};
        cur_t = t.t;
        have = true;
    }
    if (have) out.append(sys.A, .{ .t = cur_t, .s = cur.items }) catch {};
    return out.items;
}

fn splitFrontmatter(text: []const u8) ?[2][]const u8 {
    if (!std.mem.startsWith(u8, text, "---\n") and !std.mem.startsWith(u8, text, "---\r\n")) return null;
    var pos = (std.mem.indexOfScalar(u8, text, '\n') orelse return null) + 1;
    while (pos < text.len) {
        const nx = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse break;
        const line = std.mem.trimEnd(u8, text[pos..nx], "\r");
        if (std.mem.eql(u8, line, "---")) return .{ text[0 .. nx + 1], text[nx + 1 ..] };
        pos = nx + 1;
    }
    return null;
}

pub fn tokenise(lx: *Lexer, opts: Opts, text: []const u8) anyerror![]Token {
    if (lx.delegate) |d| return tokeniseDelegate(lx, d.root, d.language, opts, text);
    if (std.mem.eql(u8, lx.cfg.name, "HTTP")) return tokeniseHttp(lx, opts, text);
    if (lx.states == null) _ = try loadStates(lx);
    if (lx.remaps.len > 0) {
        const toks = try tokeniseRegex(lx, opts, text);
        for (toks) |*t| {
            var i = lx.remaps.len;
            outer: while (i > 0) {
                i -= 1;
                const r = lx.remaps[i];
                if (r.from != t.t) continue;
                for (r.words) |w| if (std.mem.eql(u8, w, t.s)) {
                    t.t = r.to;
                    break :outer;
                };
            }
        }
        return toks;
    }
    if (lx.markdown) if (splitFrontmatter(text)) |parts| if (get("YAML")) |y| {
        var out: std.ArrayList(Token) = .empty;
        try out.appendSlice(sys.A, try tokeniseRegex(y, opts, parts[0]));
        try out.appendSlice(sys.A, try tokeniseRegex(lx, opts, parts[1]));
        return out.items;
    };
    return tokeniseRegex(lx, opts, text);
}

fn matchMime(mime: []const u8) ?*Lexer {
    var best: ?*Lexer = null;
    for (getRegistry()) |lx| for (lx.cfg.mimes) |m| if (std.mem.eql(u8, m, mime)) {
        if (best == null or prio(lx) > prio(best.?)) best = lx;
    };
    return best;
}

/// Chroma's httpBodyContentTypeLexer: the body is lexed by the lexer for the
/// Content-Type header.
fn tokeniseHttp(lx: *Lexer, opts: Opts, text: []const u8) anyerror![]Token {
    const toks = try tokeniseRegex(lx, opts, text);
    var out: std.ArrayList(Token) = .empty;
    var ctype: []const u8 = "";
    var is_ct = false;
    const Name: TT = 2000;
    const Literal: TT = 3000;
    const Generic: TT = 7000;
    for (toks) |t0| {
        var t = t0;
        if (t.t == Name and std.ascii.eqlIgnoreCase(t.s, "content-type")) {
            is_ct = true;
        } else if (t.t == Literal and is_ct) {
            is_ct = false;
            ctype = std.mem.trim(u8, t.s, " \t\r\n");
            if (std.mem.indexOfScalar(u8, ctype, ';')) |p| if (p > 0) {
                ctype = std.mem.trim(u8, ctype[0..p], " \t\r\n");
            };
        } else if (t.t == Generic and ctype.len > 0) {
            var sub = matchMime(ctype);
            if (sub == null and std.mem.indexOfScalar(u8, ctype, '+') != null) {
                const slash = std.mem.indexOfScalar(u8, ctype, '/') orelse 0;
                const plus = std.mem.lastIndexOfScalar(u8, ctype, '+').?;
                sub = matchMime(std.mem.concat(sys.A, u8, &.{ ctype[0 .. slash + 1], ctype[plus + 1 ..] }) catch ctype);
            }
            if (sub) |sl| {
                try out.appendSlice(sys.A, try tokenise(sl, .{}, t.s));
                continue;
            }
            t.t = Text;
        }
        try out.append(sys.A, t);
    }
    return out.items;
}

fn tokeniseDelegate(lx: *Lexer, root_name: []const u8, lang_name: []const u8, opts: Opts, text: []const u8) anyerror![]Token {
    _ = lx;
    const language = byNameOrAlias(lang_name, false) orelse return error.NoLexer;
    const root = byNameOrAlias(root_name, false) orelse return error.NoLexer;
    const toks = coalesce(try tokenise(language, opts, text));
    const Ins = struct { start: usize, end: usize = 0, toks: std.ArrayList(Token) = .empty };
    var others: std.ArrayList(u8) = .empty;
    var ins: std.ArrayList(*Ins) = .empty;
    var cur: ?*Ins = null;
    var offset: usize = 0;
    var last: ?Token = null;
    for (toks) |t| {
        if (t.t == Other) {
            if (last != null and cur != null and last.?.t != Other) cur.?.end = offset;
            try others.appendSlice(sys.A, t.s);
        } else {
            if (last == null or last.?.t == Other) {
                cur = try sys.A.create(Ins);
                cur.?.* = .{ .start = offset };
                try ins.append(sys.A, cur.?);
            }
            try cur.?.toks.append(sys.A, t);
        }
        last = t;
        offset += t.s.len;
    }
    if (ins.items.len == 0) return tokenise(root, opts, text);
    const rtoks = coalesce(try tokenise(root, opts, others.items));
    var out: std.ArrayList(Token) = .empty;
    offset = 0;
    var ti: usize = 0;
    var ii: usize = 0;
    var t: ?Token = if (rtoks.len > 0) rtoks[0] else null;
    if (t != null) ti = 1;
    var in: ?*Ins = ins.items[0];
    ii = 1;
    while (t != null or in != null) {
        if (t == null or (in != null and in.?.start < offset + t.?.s.len)) {
            var l: ?Token = null;
            if (t) |tk| {
                const off = in.?.start - offset;
                if (off == 0) {
                    l = null;
                } else if (off == tk.s.len) {
                    l = tk;
                    t = null;
                } else {
                    l = .{ .t = tk.t, .s = tk.s[0..off] };
                    t = .{ .t = tk.t, .s = tk.s[off..] };
                }
            }
            if (l) |x| {
                try out.append(sys.A, x);
                offset += x.s.len;
            }
            try out.appendSlice(sys.A, in.?.toks.items);
            offset += in.?.end -| in.?.start;
            if (t == null) {
                t = if (ti < rtoks.len) rtoks[ti] else null;
                ti += 1;
            }
            in = if (ii < ins.items.len) ins.items[ii] else null;
            ii += 1;
        } else {
            try out.append(sys.A, t.?);
            offset += t.?.s.len;
            t = if (ti < rtoks.len) rtoks[ti] else null;
            ti += 1;
        }
    }
    return out.items;
}

// ================================================================ styles

const Tri = enum(u2) { pass, yes, no };
const Entry = struct {
    colour: i32 = 0,
    bg: i32 = 0,
    border: i32 = 0,
    bold: Tri = .pass,
    italic: Tri = .pass,
    underline: Tri = .pass,
    noinherit: bool = false,

    fn isZero(e: Entry) bool {
        return e.colour == 0 and e.bg == 0 and e.border == 0 and e.bold == .pass and e.italic == .pass and e.underline == .pass and !e.noinherit;
    }
    fn inherit(s: Entry, ancestors: []const Entry) Entry {
        var out = s;
        var i = ancestors.len;
        while (i > 0) {
            i -= 1;
            const a = ancestors[i];
            if (out.noinherit) return out;
            if (out.colour == 0) out.colour = a.colour;
            if (out.bg == 0) out.bg = a.bg;
            if (out.border == 0) out.border = a.border;
            if (out.bold == .pass) out.bold = a.bold;
            if (out.italic == .pass) out.italic = a.italic;
            if (out.underline == .pass) out.underline = a.underline;
        }
        return out;
    }
    fn sub(s: Entry, e: Entry) Entry {
        var out = Entry{};
        if (e.colour != s.colour) out.colour = s.colour;
        if (e.bg != s.bg) out.bg = s.bg;
        if (e.bold != s.bold) out.bold = s.bold;
        if (e.italic != s.italic) out.italic = s.italic;
        if (e.underline != s.underline) out.underline = s.underline;
        if (e.border != s.border) out.border = s.border;
        return out;
    }
};

fn parseColour(s0: []const u8) i32 {
    var s = s0;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    var buf: [6]u8 = undefined;
    if (s.len == 3) {
        buf = .{ s[0], s[0], s[1], s[1], s[2], s[2] };
        s = &buf;
    }
    const n = std.fmt.parseInt(u32, s, 16) catch return 0;
    return @intCast(n + 1);
}

fn parseEntry(s: []const u8) Entry {
    var e = Entry{};
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "italic")) e.italic = .yes else if (std.mem.eql(u8, p, "noitalic")) e.italic = .no else if (std.mem.eql(u8, p, "bold")) e.bold = .yes else if (std.mem.eql(u8, p, "nobold")) e.bold = .no else if (std.mem.eql(u8, p, "underline")) e.underline = .yes else if (std.mem.eql(u8, p, "nounderline")) e.underline = .no else if (std.mem.eql(u8, p, "inherit")) e.noinherit = false else if (std.mem.eql(u8, p, "noinherit")) e.noinherit = true else if (std.mem.eql(u8, p, "bg:")) e.bg = 0 else if (std.mem.startsWith(u8, p, "bg:#")) e.bg = parseColour(p[3..]) else if (std.mem.startsWith(u8, p, "border:#")) e.border = parseColour(p[7..]) else if (std.mem.startsWith(u8, p, "#")) e.colour = parseColour(p);
    }
    return e;
}

pub const Style = struct {
    name: []const u8,
    entries: std.AutoHashMapUnmanaged(TT, Entry) = .empty,

    fn rawGet(s: *const Style, t: TT) Entry {
        var out = s.entries.get(t) orelse Entry{};
        if (out.isZero() and (t == LineHighlight or t == LineNumbers or t == LineNumbersTable)) out = s.synthesise(t);
        return out;
    }
    fn synthesise(s: *const Style, t: TT) Entry {
        const bg = s.rawGet(Background);
        if (t == LineHighlight) return .{ .bg = brightenOrDarken(bg.bg, 0.1) };
        return .{ .colour = brightenOrDarken(bg.colour, 0.5) };
    }
    pub fn get(s: *const Style, t: TT) Entry {
        return s.rawGet(t).inherit(&.{ s.rawGet(Background), s.rawGet(Text), s.rawGet(category(t)), s.rawGet(subCategory(t)) });
    }
};

fn red(c: i32) u8 {
    return @intCast(((c - 1) >> 16) & 0xff);
}
fn green(c: i32) u8 {
    return @intCast(((c - 1) >> 8) & 0xff);
}
fn blue(c: i32) u8 {
    return @intCast((c - 1) & 0xff);
}
fn brightness(c: i32) f64 {
    return (@as(f64, @floatFromInt(red(c))) + @as(f64, @floatFromInt(green(c))) + @as(f64, @floatFromInt(blue(c)))) / 255.0 / 3.0;
}
fn brighten(c: i32, factor0: f64) i32 {
    var r: f64 = @floatFromInt(red(c));
    var g: f64 = @floatFromInt(green(c));
    var b: f64 = @floatFromInt(blue(c));
    var factor = factor0;
    if (factor < 0) {
        factor += 1;
        r *= factor;
        g *= factor;
        b *= factor;
    } else {
        r = (255 - r) * factor + r;
        g = (255 - g) * factor + g;
        b = (255 - b) * factor + b;
    }
    const ri: i32 = @intFromFloat(r);
    const gi: i32 = @intFromFloat(g);
    const bi: i32 = @intFromFloat(b);
    return ((ri & 0xff) << 16 | (gi & 0xff) << 8 | (bi & 0xff)) + 1;
}
fn brightenOrDarken(c: i32, f: f64) i32 {
    if (brightness(c) < 0.5) return brighten(c, f);
    return brighten(c, -f);
}
fn colourStr(c: i32) []const u8 {
    return std.fmt.allocPrint(sys.A, "#{x:0>6}", .{@as(u32, @intCast(c - 1))}) catch "";
}

var style_cache: std.StringHashMapUnmanaged(*Style) = .empty;

pub fn styleNames() []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (data.styles) |src| {
        const el = parseXml(src) catch continue;
        out.append(sys.A, el.attr("name") orelse continue) catch {};
    }
    return out.items;
}

/// styles.Get: exact name, then case-insensitive; null if unknown.
pub fn getStyle(name: []const u8) ?*Style {
    if (style_cache.get(name)) |s| return s;
    for (data.styles) |src| {
        const ns = std.mem.indexOf(u8, src, "name=\"") orelse continue;
        const ne = std.mem.indexOfScalarPos(u8, src, ns + 6, '"') orelse continue;
        const sname = src[ns + 6 .. ne];
        if (!std.ascii.eqlIgnoreCase(sname, name)) continue;
        const el = parseXml(src) catch return null;
        const st = sys.A.create(Style) catch return null;
        st.* = .{ .name = sname };
        for (el.kids) |k| {
            const t = typeByName(k.attr("type") orelse continue) orelse continue;
            st.entries.put(sys.A, t, parseEntry(k.attr("style") orelse "")) catch {};
        }
        style_cache.put(sys.A, name, st) catch {};
        return st;
    }
    return null;
}

fn entryCss(e: Entry) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (e.colour != 0) parts.append(sys.A, std.mem.concat(sys.A, u8, &.{ "color: ", colourStr(e.colour) }) catch "") catch {};
    if (e.bg != 0) parts.append(sys.A, std.mem.concat(sys.A, u8, &.{ "background-color: ", colourStr(e.bg) }) catch "") catch {};
    if (e.bold == .yes) parts.append(sys.A, "font-weight: bold") catch {};
    if (e.italic == .yes) parts.append(sys.A, "font-style: italic") catch {};
    if (e.underline == .yes) parts.append(sys.A, "text-decoration: underline") catch {};
    return std.mem.join(sys.A, "; ", parts.items) catch "";
}

fn compressStyle(s: []const u8) []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |part| {
        var fields: std.ArrayList([]const u8) = .empty;
        var fi = std.mem.tokenizeAny(u8, part, " \t\n\r");
        while (fi.next()) |f| fields.append(sys.A, f) catch {};
        var p = std.mem.join(sys.A, " ", fields.items) catch part;
        if (std.mem.indexOf(u8, p, ": ")) |ix| p = std.mem.concat(sys.A, u8, &.{ p[0..ix], ":", p[ix + 2 ..] }) catch p;
        if (std.mem.indexOfScalar(u8, p, '#') != null and p.len >= 6) {
            const c = p[p.len - 6 ..];
            if (c[0] == c[1] and c[2] == c[3] and c[4] == c[5]) p = std.mem.concat(sys.A, u8, &.{ p[0 .. p.len - 6], c[0..1], c[2..3], c[4..5] }) catch p;
        }
        out.append(sys.A, p) catch {};
    }
    return std.mem.join(sys.A, ";", out.items) catch s;
}

// ================================================================ formatter

pub const FormatOpts = struct {
    classes: bool = false,
    tab_width: i64 = 8,
    line_numbers: bool = false,
    in_table: bool = false,
    linkable: bool = false,
    id_prefix: []const u8 = "",
    base_line: i64 = 1,
    hl_ranges: []const [2]i64 = &.{},
    inline_code: bool = false,
    prefix: []const u8 = "",
};

const CssMap = std.AutoHashMapUnmanaged(TT, []const u8);

fn styleToCss(st: *const Style, o: FormatOpts, compress: bool) CssMap {
    return styleToCssCustom(st, o, compress, null);
}

fn styleToCssCustom(st: *const Style, o: FormatOpts, compress: bool, custom: ?*const CssMap) CssMap {
    var classes: CssMap = .empty;
    const bg = st.get(Background);
    for (types) |td| {
        if (td.class == null) continue;
        const t = td.tt;
        var entry = st.get(t);
        if (t != Background) entry = entry.sub(bg);
        var extra: []const u8 = "";
        if (custom) |cm| {
            const cat = category(t);
            const sc = subCategory(t);
            if (t != cat) if (cm.get(cat)) |x| {
                extra = x;
            };
            if (cat != sc) if (cm.get(sc)) |x| {
                extra = std.mem.concat(sys.A, u8, &.{ extra, x }) catch extra;
            };
            if (cm.get(t)) |x| extra = std.mem.concat(sys.A, u8, &.{ extra, x }) catch extra;
        }
        if (entry.isZero() and extra.len == 0) continue;
        var css = entryCss(entry);
        if (css.len > 0 and extra.len > 0) css = std.mem.concat(sys.A, u8, &.{ css, ";" }) catch css;
        classes.put(sys.A, t, std.mem.concat(sys.A, u8, &.{ css, extra }) catch css) catch {};
    }
    const tws = if (o.tab_width != 0 and o.tab_width != 8) std.fmt.allocPrint(sys.A, "-moz-tab-size: {d}; -o-tab-size: {d}; tab-size: {d};", .{ o.tab_width, o.tab_width, o.tab_width }) catch "" else "";
    const bgc = std.mem.concat(sys.A, u8, &.{ classes.get(Background) orelse "", ";", tws }) catch "";
    classes.put(sys.A, Background, bgc) catch {};
    var pw = std.mem.concat(sys.A, u8, &.{ classes.get(PreWrapper) orelse "", bgc, " -webkit-text-size-adjust: none;" }) catch "";
    if (o.hl_ranges.len > 0) pw = std.mem.concat(sys.A, u8, &.{ pw, "display: grid;" }) catch pw;
    classes.put(sys.A, PreWrapper, pw) catch {};
    const lns = "white-space: pre; -webkit-user-select: none; user-select: none; margin-right: 0.4em; padding: 0 0.4em 0 0.4em;";
    const cat = struct {
        fn f(c: *CssMap, t: TT, pre: []const u8) void {
            c.put(sys.A, t, std.mem.concat(sys.A, u8, &.{ pre, c.get(t) orelse "" }) catch "") catch {};
        }
    }.f;
    cat(&classes, Line, "display: flex;");
    cat(&classes, LineNumbers, lns);
    cat(&classes, LineNumbersTable, lns);
    cat(&classes, LineTable, "border-spacing: 0; padding: 0; margin: 0; border: 0;");
    cat(&classes, LineTableTD, "vertical-align: top; padding: 0; margin: 0; border: 0;");
    cat(&classes, LineLink, "outline: none; text-decoration: none; color: inherit");
    if (compress) {
        var it = classes.iterator();
        while (it.next()) |e| e.value_ptr.* = compressStyle(e.value_ptr.*);
    }
    return classes;
}

fn classOf(o: FormatOpts, t0: TT) []const u8 {
    var t = t0;
    while (t != 0) {
        if (stdClass(t)) |c| {
            if (c.len > 0) return std.mem.concat(sys.A, u8, &.{ o.prefix, c }) catch c;
            return "";
        }
        t = parent(t);
    }
    if (stdClass(0)) |c| if (c.len > 0) return c;
    return "";
}

fn styleAttr(o: FormatOpts, css: *const CssMap, tt0: TT, extra: []const u8) []const u8 {
    if (o.classes) {
        const c = classOf(o, tt0);
        if (c.len == 0) return "";
        return std.fmt.allocPrint(sys.A, " class=\"{s}\"", .{c}) catch "";
    }
    var tt = tt0;
    if (!css.contains(tt)) {
        tt = subCategory(tt);
        if (!css.contains(tt)) {
            tt = category(tt);
            if (!css.contains(tt)) return "";
        }
    }
    const s = css.get(tt).?;
    if (extra.len > 0) return std.fmt.allocPrint(sys.A, " style=\"{s};{s}\"", .{ s, extra }) catch "";
    return std.fmt.allocPrint(sys.A, " style=\"{s}\"", .{s}) catch "";
}

pub fn escape(b: *std.ArrayList(u8), s: []const u8) void {
    for (s) |c| switch (c) {
        '<' => b.appendSlice(sys.A, "&lt;") catch {},
        '>' => b.appendSlice(sys.A, "&gt;") catch {},
        '&' => b.appendSlice(sys.A, "&amp;") catch {},
        '\'' => b.appendSlice(sys.A, "&#39;") catch {},
        '"' => b.appendSlice(sys.A, "&#34;") catch {},
        else => b.append(sys.A, c) catch {},
    };
}

fn splitLines(toks: []const Token) [][]Token {
    var out: std.ArrayList([]Token) = .empty;
    var line: std.ArrayList(Token) = .empty;
    for (toks) |t0| {
        var t = t0;
        while (std.mem.indexOfScalar(u8, t.s, '\n')) |nl| {
            line.append(sys.A, .{ .t = t.t, .s = t.s[0 .. nl + 1] }) catch {};
            out.append(sys.A, line.items) catch {};
            line = .empty;
            t.s = t.s[nl + 1 ..];
            if (t.s.len == 0) break;
        }
        if (t.s.len > 0) line.append(sys.A, t) catch {};
    }
    if (line.items.len > 0) out.append(sys.A, line.items) catch {};
    if (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last.len == 1 and last[0].s.len == 0) out.items.len -= 1;
    }
    return out.items;
}

fn shouldHighlight(o: FormatOpts, idx: *usize, line: i64) bool {
    while (idx.* < o.hl_ranges.len and line > o.hl_ranges[idx.*][1]) idx.* += 1;
    if (idx.* < o.hl_ranges.len) {
        const r = o.hl_ranges[idx.*];
        return line >= r[0] and line <= r[1];
    }
    return false;
}

pub const PreHooks = struct {
    ctx: *anyopaque,
    start: *const fn (ctx: *anyopaque, b: *std.ArrayList(u8), code: bool, style_attr: []const u8) void,
    end: *const fn (ctx: *anyopaque, b: *std.ArrayList(u8), code: bool) void,
};

fn digits(n: i64) usize {
    var buf: [24]u8 = undefined;
    const r = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return 1;
    return r.len;
}

fn lineTitle(b: *std.ArrayList(u8), o: FormatOpts, css: *const CssMap, nd: usize, line: i64) void {
    var buf: [32]u8 = undefined;
    const num: []const u8 = std.fmt.bufPrint(&buf, "{d}", .{line}) catch "0";
    var title: std.ArrayList(u8) = .empty;
    var k = num.len;
    while (k < nd) : (k += 1) title.append(sys.A, ' ') catch {};
    title.appendSlice(sys.A, num) catch {};
    if (!o.linkable) {
        b.appendSlice(sys.A, title.items) catch {};
        return;
    }
    b.print(sys.A, "<a{s} href=\"#{s}{d}\">{s}</a>", .{ styleAttr(o, css, LineLink, ""), o.id_prefix, line, title.items }) catch {};
}

fn lineId(b: *std.ArrayList(u8), o: FormatOpts, line: i64) void {
    if (!o.linkable) return;
    b.print(sys.A, " id=\"{s}{d}\"", .{ o.id_prefix, line }) catch {};
}

pub fn format(b: *std.ArrayList(u8), st: *const Style, toks: []const Token, o: FormatOpts, pre: PreHooks) void {
    const css_v = styleToCss(st, o, true);
    const css = &css_v;
    const wrap_table = o.line_numbers and o.in_table;
    const lines = splitLines(toks);
    const nd = digits(o.base_line + @as(i64, @intCast(lines.len)) - 1);
    var hidx: usize = 0;
    if (wrap_table) {
        b.print(sys.A, "<div{s}>\n", .{styleAttr(o, css, PreWrapper, "")}) catch {};
        b.print(sys.A, "<table{s}><tr>", .{styleAttr(o, css, LineTable, "")}) catch {};
        b.print(sys.A, "<td{s}>\n", .{styleAttr(o, css, LineTableTD, "")}) catch {};
        pre.start(pre.ctx, b, false, styleAttr(o, css, PreWrapper, ""));
        for (0..lines.len) |idx| {
            const line = o.base_line + @as(i64, @intCast(idx));
            const hl = shouldHighlight(o, &hidx, line);
            if (hl) b.print(sys.A, "<span{s}>", .{styleAttr(o, css, LineHighlight, "")}) catch {};
            b.print(sys.A, "<span{s}", .{styleAttr(o, css, LineNumbersTable, "")}) catch {};
            lineId(b, o, line);
            b.append(sys.A, '>') catch {};
            lineTitle(b, o, css, nd, line);
            b.appendSlice(sys.A, "\n</span>") catch {};
            if (hl) b.appendSlice(sys.A, "</span>") catch {};
        }
        pre.end(pre.ctx, b, false);
        b.appendSlice(sys.A, "</td>\n") catch {};
        b.print(sys.A, "<td{s}>\n", .{styleAttr(o, css, LineTableTD, "width:100%")}) catch {};
    }
    pre.start(pre.ctx, b, true, styleAttr(o, css, PreWrapper, ""));
    hidx = 0;
    for (lines, 0..) |ltoks, idx| {
        const line = o.base_line + @as(i64, @intCast(idx));
        const hl = shouldHighlight(o, &hidx, line);
        if (!o.inline_code) {
            b.appendSlice(sys.A, "<span") catch {};
            if (hl) {
                if (o.classes) {
                    b.print(sys.A, " class=\"{s} {s}\"", .{ classOf(o, Line), classOf(o, LineHighlight) }) catch {};
                } else b.print(sys.A, " style=\"{s} {s}\"", .{ css.get(Line) orelse "", css.get(LineHighlight) orelse "" }) catch {};
                b.append(sys.A, '>') catch {};
            } else b.print(sys.A, "{s}>", .{styleAttr(o, css, Line, "")}) catch {};
            if (o.line_numbers and !wrap_table) {
                b.print(sys.A, "<span{s}", .{styleAttr(o, css, LineNumbers, "")}) catch {};
                lineId(b, o, line);
                b.append(sys.A, '>') catch {};
                lineTitle(b, o, css, nd, line);
                b.appendSlice(sys.A, "</span>") catch {};
            }
            b.print(sys.A, "<span{s}>", .{styleAttr(o, css, CodeLine, "")}) catch {};
        }
        for (ltoks) |t| {
            const attr = styleAttr(o, css, t.t, "");
            if (attr.len > 0) {
                b.print(sys.A, "<span{s}>", .{attr}) catch {};
                escape(b, t.s);
                b.appendSlice(sys.A, "</span>") catch {};
            } else escape(b, t.s);
        }
        if (!o.inline_code) b.appendSlice(sys.A, "</span></span>") catch {};
    }
    pre.end(pre.ctx, b, true);
    if (wrap_table) b.appendSlice(sys.A, "</td></tr></table>\n</div>\n") catch {};
}

/// Chroma's html.Formatter.WriteCSS (used by `zssg gen chromastyles`).
pub fn writeCss(b: *std.ArrayList(u8), st: *const Style, o: FormatOpts) void {
    writeCssCustom(b, st, o, null, true);
}

var css_comments = true;

pub fn writeCssCustom(b: *std.ArrayList(u8), st: *const Style, o: FormatOpts, custom: ?*const CssMap, comments: bool) void {
    const css_v = styleToCssCustom(st, o, true, custom);
    const css = &css_v;
    const chroma_sel = std.mem.concat(sys.A, u8, &.{ ".", o.prefix, "chroma" }) catch "";
    const bg_sel = std.mem.concat(sys.A, u8, &.{ ".", o.prefix, "bg" }) catch "";
    const rule = struct {
        fn f(bb: *std.ArrayList(u8), comment: []const u8, sel: []const u8, styles: []const u8) void {
            if (styles.len == 0) return;
            if (css_comments and comment.len > 0) bb.print(sys.A, "/* {s} */ ", .{comment}) catch {};
            bb.print(sys.A, "{s} {{ {s} }}\n", .{ sel, styles }) catch {};
        }
    }.f;
    css_comments = comments;
    rule(b, "Background", bg_sel, css.get(Background) orelse "");
    rule(b, "PreWrapper", chroma_sel, css.get(PreWrapper) orelse "");
    if (o.line_numbers and o.in_table) rule(b, "LineTableTD", std.mem.concat(sys.A, u8, &.{ chroma_sel, " .", classOf(o, LineTableTD), ":last-child" }) catch "", "width: 100%;");
    if (o.line_numbers or o.in_table) {
        const tl = entryCss(st.get(LineHighlight));
        rule(b, "LineNumbers targeted by URL anchor", std.mem.concat(sys.A, u8, &.{ chroma_sel, " .", classOf(o, LineNumbers), ":target" }) catch "", tl);
        rule(b, "LineNumbersTable targeted by URL anchor", std.mem.concat(sys.A, u8, &.{ chroma_sel, " .", classOf(o, LineNumbersTable), ":target" }) catch "", tl);
    }
    var keys: std.ArrayList(TT) = .empty;
    var it = css.keyIterator();
    while (it.next()) |k| keys.append(sys.A, k.*) catch {};
    std.mem.sort(TT, keys.items, {}, std.sort.asc(TT));
    for (keys.items) |t| {
        if (t == Background or t == PreWrapper) continue;
        const c = classOf(o, t);
        if (c.len == 0) continue;
        var name: []const u8 = "";
        for (types) |td| if (td.tt == t) {
            name = td.name;
        };
        rule(b, name, std.mem.concat(sys.A, u8, &.{ chroma_sel, " .", c }) catch "", css.get(t).?);
    }
}

/// Tokenise `code` with the lexer and coalesce (what Hugo does before formatting).
/// Runs on a thread with a large stack: the backtracking matcher recurses
/// once per repetition, and some grammars match long tokens.
pub fn highlightTokens(lx: *Lexer, code: []const u8) ![]Token {
    const Job = struct {
        lx: *Lexer,
        code: []const u8,
        a: std.mem.Allocator,
        out: ?[]Token = null,
        fn run(j: *@This()) void {
            // the caller blocks until this thread is done: it can use its arena
            sys.A = j.a;
            j.out = coalesce(tokenise(j.lx, .{}, j.code) catch return);
        }
    };
    var job = Job{ .lx = lx, .code = code, .a = sys.A };
    const th = std.Thread.spawn(.{ .stack_size = 1 << 30 }, Job.run, .{&job}) catch {
        job.run();
        return job.out orelse error.TokeniseFailed;
    };
    th.join();
    return job.out orelse error.TokeniseFailed;
}

pub const CssMapT = CssMap;

fn hasType(st: *const Style, t: TT) bool {
    return !st.rawGet(t).isZero() or t == LineHighlight or t == LineNumbers or t == LineNumbersTable;
}

fn isLeaf(t: TT) bool {
    for (types) |o| {
        if (o.class == null or o.tt == t) continue;
        if (category(o.tt) == t or subCategory(o.tt) == t) return false;
    }
    return true;
}

pub const StylesCssOpts = struct {
    style: []const u8,
    mode: []const u8 = "",
    mode_selector: bool = false,
    class_dark: []const u8 = "dark",
    class_light: []const u8 = "light",
    highlight_style: []const u8 = "",
    ln_inline_style: []const u8 = "",
    ln_table_style: []const u8 = "",
    omit_comments: bool = false,
};

fn isDark(st: *const Style) bool {
    const bg = st.rawGet(Background).bg;
    return bg != 0 and brightness(bg) < 0.5;
}

/// Hugo's highlight.ChromaStylesCSS (`hugo gen chromastyles`).
pub fn chromaStylesCss(o: StylesCssOpts) ![]const u8 {
    const base = getStyle(o.style) orelse return error.InvalidStyle;
    const st = try sys.A.create(Style);
    st.* = .{ .name = base.name };
    var it = base.entries.iterator();
    while (it.next()) |e| try st.entries.put(sys.A, e.key_ptr.*, e.value_ptr.*);
    if (o.mode.len > 0) {
        const want_dark = std.mem.eql(u8, o.mode, "dark");
        if (isDark(st) != want_dark) return error.ModeMismatch;
    }
    if (o.highlight_style.len > 0) try st.entries.put(sys.A, LineHighlight, parseEntry(o.highlight_style));
    if (o.ln_inline_style.len > 0) try st.entries.put(sys.A, LineNumbers, parseEntry(o.ln_inline_style));
    if (o.ln_table_style.len > 0) try st.entries.put(sys.A, LineNumbersTable, parseEntry(o.ln_table_style));
    var custom: CssMap = .empty;
    const bg = st.get(Background);
    for (types) |td| {
        if (td.class == null or td.tt == Background) continue;
        if (!hasType(st, td.tt) or !isLeaf(td.tt)) continue;
        const entry = st.get(td.tt);
        if (!entry.sub(bg).isZero() or entry.colour == 0) continue;
        try custom.put(sys.A, td.tt, entryCss(.{ .colour = entry.colour }));
    }
    var b: std.ArrayList(u8) = .empty;
    writeCssCustom(&b, st, .{ .classes = true, .tab_width = 0 }, &custom, !o.omit_comments);
    var css: []const u8 = b.items;
    if (o.mode_selector) {
        const prefix = std.mem.concat(sys.A, u8, &.{ ".", if (isDark(st)) o.class_dark else o.class_light, " " }) catch "";
        css = try std.mem.replaceOwned(u8, sys.A, css, ".bg {", std.mem.concat(sys.A, u8, &.{ prefix, ".bg {" }) catch "");
        css = try std.mem.replaceOwned(u8, sys.A, css, ".chroma ", std.mem.concat(sys.A, u8, &.{ prefix, ".chroma " }) catch "");
    }
    return css;
}
