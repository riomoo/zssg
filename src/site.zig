// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Site model: configuration, theme components, content loading, taxonomies,
//! menus, layout lookup and the build pipeline.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const data = @import("data.zig");
const tm = @import("time.zig");
const tmpl = @import("tmpl.zig");
const objs = @import("objs.zig");
const funcs = @import("funcs.zig");
const embedded = @import("embedded.zig");
const Value = v.Value;
const Map = v.Map;

pub const version = "0.3.0";
pub const hugo_compat = "0.170.0";

pub const Kind = enum { home, page, section, taxonomy, term };

pub const OutputFormat = struct {
    name: []const u8,
    media: []const u8,
    base: []const u8 = "index",
    suffix: []const u8,
    is_html: bool = false,
    is_plain: bool = false,
    rel: []const u8 = "alternate",
    path: []const u8 = "",
    permalinkable: bool = false,
};

pub const Resource = struct {
    name: []const u8,
    title: []const u8,
    src_path: ?[]const u8 = null,
    content: ?[]const u8 = null,
    target: []const u8, // site-relative publish path, leading slash
    media: []const u8,
    params: *Map,
    /// original path relative to the bundle (before front matter renames)
    path: []const u8 = "",
    /// pending image job (imgops.Job) producing `content`
    job: ?*anyopaque = null,
    integrity: []const u8 = "",
    published: bool = false,
    width: i64 = -1,
    height: i64 = -1,
    data: ?*Map = null,
};

pub const Pager = struct {
    page: *Page,
    items: []Value,
    number: usize,
    total: usize,
    size: usize,
    all: usize,
    siblings: []*Pager = &.{},
};

pub const Page = struct {
    kind: Kind = .page,
    site: *Site = undefined,
    title: []const u8 = "",
    fm: *Map,
    params: *Map,
    raw: []const u8 = "",
    is_md: bool = true,
    /// external markup handled by a helper program ("asciidocext", "pandoc", "rst", "org"); "" otherwise
    ext_markup: []const u8 = "",
    path: []const u8 = "/", // logical path
    file: ?[]const u8 = null, // path relative to content dir
    file_abs: []const u8 = "",
    bundle: enum { none, leaf, branch } = .none,
    section: []const u8 = "",
    url: []const u8 = "/", // site-relative url of the primary output
    date: v.Time = tm.zero,
    lastmod: v.Time = tm.zero,
    publish: v.Time = tm.zero,
    expiry: v.Time = tm.zero,
    dates_zero: bool = false,
    weight: i64 = 0,
    draft: bool = false,
    parent: ?*Page = null,
    children: std.ArrayList(*Page) = .empty,
    resources: std.ArrayList(*Resource) = .empty,
    // taxonomy / term
    tax: ?*Taxonomy = null,
    term: ?*Term = null,
    // rendering caches
    rendered: bool = false,
    rendering: bool = false,
    content: []const u8 = "",
    summary: []const u8 = "",
    truncated: bool = false,
    toc: []const u8 = "",
    headings: []const @import("markdown.zig").Heading = &.{},
    plain: ?[]const u8 = null,
    shortcodes: std.ArrayList([]const u8) = .empty,
    scratch: *Map,
    store: *Map,
    outputs: []const *const OutputFormat = &.{},
    pagers: []*Pager = &.{},
    cur_pager: usize = 0,
    render: bool = true,
    publish_res: bool = true,
    list: bool = true,
    is_404: bool = false,
    menus_val: ?Value = null,
    next_in_section: ?*Page = null,
    prev_in_section: ?*Page = null,
    next: ?*Page = null,
    prev: ?*Page = null,

    pub fn val(p: *Page) Value {
        return .{ .obj = .{ .kind = .page, .ptr = p } };
    }
    pub fn isNode(p: *const Page) bool {
        return p.kind != .page;
    }
    pub fn param(p: *const Page, k: []const u8) ?[]const u8 {
        return p.fm.str(k);
    }
};

pub const Term = struct {
    name: []const u8, // display name as first written
    key: []const u8, // url key
    pages: std.ArrayList(*Page) = .empty,
    page: ?*Page = null,
    tax: *Taxonomy,
};

pub const Taxonomy = struct {
    singular: []const u8,
    plural: []const u8,
    terms: std.StringArrayHashMapUnmanaged(*Term) = .empty,
    page: ?*Page = null,
};

pub const Options = struct {
    root: []const u8 = ".",
    dest: ?[]const u8 = null,
    drafts: bool = false,
    future: bool = false,
    expired: bool = false,
    env: []const u8 = "production",
    base_url: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    quiet: bool = false,
    clean: bool = false,
    minify: bool = false,
    server: bool = false,
    port: u16 = 0,
    env_set: bool = false,
};

pub const Site = struct {
    /// Language.Locale (falls back to the language code)
    pub fn locale(s: *const Site) []const u8 {
        return s.lang_map.str("locale") orelse s.lang;
    }
    p404: ?*Page = null,
    opt: Options,
    cfg: *Map,
    params: *Map,
    title: []const u8 = "",
    base_url: []const u8 = "/", // as configured, with trailing slash
    base_path: []const u8 = "", // path component without trailing slash ("" or "/blog")
    lang: []const u8 = "en",
    default_lang: []const u8 = "en",
    /// all configured (enabled) language codes
    langs: [][]const u8 = &.{},
    /// URL prefix for this language ("" or "/fr")
    lang_prefix: []const u8 = "",
    /// true when this language has its own contentDir
    lang_dirs: bool = false,
    lang_map: *Map,
    components: [][]const u8 = &.{}, // project root first, then themes
    layouts: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    tmpl_cache: std.StringHashMapUnmanaged(*tmpl.Template) = .empty,
    pages: std.ArrayList(*Page) = .empty,
    regular: std.ArrayList(*Page) = .empty,
    by_path: std.StringHashMapUnmanaged(*Page) = .empty,
    home: *Page = undefined,
    taxonomies: std.StringArrayHashMapUnmanaged(*Taxonomy) = .empty,
    menus: *Map,
    data: *Map,
    i18n: *Map,
    formats: std.StringArrayHashMapUnmanaged(*const OutputFormat) = .empty,
    dest: []const u8 = "public",
    content_dir: []const u8 = "content",
    now: v.Time = .{},
    store: *Map,
    written: std.StringHashMapUnmanaged(void) = .empty,
    res_cache: std.StringHashMapUnmanaged(*Resource) = .empty,
    partial_cache: std.StringHashMapUnmanaged(Value) = .empty,
    warned: std.StringHashMapUnmanaged(void) = .empty,
    cur_format: *const OutputFormat = &builtin_formats[0],
    n_pages: usize = 0,
    n_static: usize = 0,
    n_aliases: usize = 0,
    n_resources: usize = 0,
    n_paginator: usize = 0,
    errors: usize = 0,
    main_sections: ?Value = null,
    summary_length: i64 = 70,
    disabled: std.StringHashMapUnmanaged(void) = .empty,
    unsafe_html: bool = false,

    pub fn val(s: *Site) Value {
        return .{ .obj = .{ .kind = .site, .ptr = s } };
    }
};

pub var S: *Site = undefined;
/// One Site per language; the default content language comes first.
pub var all: std.ArrayList(*Site) = .empty;

pub const builtin_formats = [_]OutputFormat{
    .{ .name = "html", .media = "text/html", .suffix = "html", .is_html = true, .rel = "canonical", .permalinkable = true },
    .{ .name = "rss", .media = "application/rss+xml", .suffix = "xml" },
    .{ .name = "json", .media = "application/json", .suffix = "json", .is_plain = true },
    .{ .name = "amp", .media = "text/html", .suffix = "html", .is_html = true, .rel = "amphtml", .path = "amp", .permalinkable = true },
    .{ .name = "csv", .media = "text/csv", .suffix = "csv", .is_plain = true },
    .{ .name = "calendar", .media = "text/calendar", .suffix = "ics", .is_plain = true },
    .{ .name = "markdown", .media = "text/markdown", .suffix = "md", .is_plain = true },
    .{ .name = "txt", .media = "text/plain", .suffix = "txt", .is_plain = true },
    .{ .name = "webappmanifest", .media = "application/manifest+json", .base = "manifest", .suffix = "webmanifest", .is_plain = true, .rel = "manifest" },
    .{ .name = "atom", .media = "application/atom+xml", .suffix = "atom" },
    .{ .name = "sitemap", .media = "application/xml", .base = "sitemap", .suffix = "xml" },
    .{ .name = "robots", .media = "text/plain", .base = "robots", .suffix = "txt", .is_plain = true },
};

/// warnings and errors can come from image worker threads
var msg_lock: sys.Mutex = .init;

pub fn warn(comptime f: []const u8, args: anytype) void {
    const msg = v.fmt(f, args);
    if (sys.worker_msgs) |l| {
        l.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, msg) catch return) catch {};
        return;
    }
    sys.lock(&msg_lock);
    defer sys.unlock(&msg_lock);
    if (S.warned.contains(msg)) return;
    S.warned.put(sys.main_A, sys.main_A.dupe(u8, msg) catch msg, {}) catch {};
    if (!S.opt.quiet) sys.eprint("WARN  {s}\n", .{msg});
}

pub fn errorf(comptime f: []const u8, args: anytype) void {
    const msg = v.fmt(f, args);
    sys.lock(&msg_lock);
    defer sys.unlock(&msg_lock);
    S.errors += 1;
    sys.eprint("ERROR {s}\n", .{msg});
}

pub var fatal_msg: []const u8 = "";
pub fn fatal(comptime f: []const u8, args: anytype) anyerror {
    fatal_msg = v.fmt(f, args);
    return error.Fatal;
}

fn abs(parts: []const []const u8) []const u8 {
    return v.pathJoin(parts);
}

// ------------------------------------------------------------------ config

const cfg_names = [_][]const u8{ "hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json", "config.toml", "config.yaml", "config.yml", "config.json" };

fn loadCfgFile(path: []const u8) anyerror!?*Map {
    const src = sys.readFile(path) orelse return null;
    const val = data.parseByExt(v.pathExt(path), src) catch return fatal("failed to parse config {s}: {s}", .{ path, data.err_msg });
    if (val == .map) return val.map;
    return v.newMap();
}

/// Overlay `src` onto `dst` (src wins, maps merged recursively).
fn overlay(dst: *Map, src: *const Map) void {
    for (src.m.keys(), src.m.values()) |k, val| {
        if (dst.getCI(k)) |ex| {
            if (ex == .map and val == .map) {
                overlay(ex.map, val.map);
                continue;
            }
        }
        dst.putCI(k, val);
    }
}

fn loadCfgDir(dir: []const u8, into: *Map) anyerror!void {
    for (sys.listDir(dir)) |e| {
        if (e.is_dir) continue;
        const ext = v.pathExt(e.name);
        if (!(v.eq(ext, ".toml") or v.eq(ext, ".yaml") or v.eq(ext, ".yml") or v.eq(ext, ".json"))) continue;
        const m = (try loadCfgFile(abs(&.{ dir, e.name }))) orelse continue;
        const stem = v.pathStem(e.name);
        if (v.eq(stem, "hugo") or v.eq(stem, "config")) {
            overlay(into, m);
        } else {
            // params.toml, menus.en.toml, languages.toml ...
            var it = std.mem.splitScalar(u8, stem, '.');
            const key = it.next().?;
            const lang = it.next();
            var target = into;
            if (lang) |lg| {
                const langs = into.map("languages") orelse blk: {
                    const n = v.newMap();
                    into.put("languages", v.M(n));
                    break :blk n;
                };
                target = langs.map(lg) orelse blk: {
                    const n = v.newMap();
                    langs.put(lg, v.M(n));
                    break :blk n;
                };
            }
            const k = if (v.eq(key, "menu")) "menus" else key;
            if (target.map(k)) |ex| overlay(ex, m) else target.putCI(k, v.M(m));
        }
    }
}

fn loadComponentCfg(root: []const u8, env: []const u8) anyerror!*Map {
    const cfg = v.newMap();
    for (cfg_names) |n| {
        if (try loadCfgFile(abs(&.{ root, n }))) |m| {
            overlay(cfg, m);
            break;
        }
    }
    try loadCfgDir(abs(&.{ root, "config", "_default" }), cfg);
    try loadCfgDir(abs(&.{ root, "config", env }), cfg);
    return cfg;
}

fn themeNames(cfg: *Map) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (cfg.getCI("theme")) |t| switch (t) {
        .str => |s| out.append(sys.A, s) catch {},
        .list => |l| for (l.items.items) |x| if (v.rawStr(x)) |s| out.append(sys.A, s) catch {},
        else => {},
    };
    if (cfg.map("module")) |m| if (m.list("imports")) |imps| for (imps.items.items) |imp| if (imp == .map) {
        if (imp.map.str("path")) |p| {
            if (imp.map.boolean("disable", false)) continue;
            const ver = imp.map.str("version") orelse "";
            out.append(sys.A, if (ver.len > 0) v.concat(&.{ p, "@", ver }) else p) catch {};
        }
    };
    return out.items;
}

fn resolveTheme(root: []const u8, themes_dir: []const u8, name_in: []const u8) ?[]const u8 {
    const name = if (v.indexOfChar(name_in, '@')) |i| name_in[0..i] else name_in;
    const cands = [_][]const u8{
        abs(&.{ root, themes_dir, name }),
        abs(&.{ root, "_vendor", name }),
        abs(&.{ root, themes_dir, v.pathBase(name) }),
        name,
    };
    for (cands) |c| if (sys.kindOf(c) == .dir) return c;
    return resolveGoModule(root, name_in);
}

var module_dirs: std.StringHashMapUnmanaged(?[]const u8) = .empty;

/// Hugo Modules: modules are Go modules, resolved (and downloaded) with the Go
/// toolchain like Hugo does. With a go.mod in the project the module is added
/// with `go get` when missing; without one it is fetched into the module cache.
fn resolveGoModule(root: []const u8, path_in: []const u8) ?[]const u8 {
    var path = path_in;
    var mod_ver: []const u8 = "";
    if (v.indexOfChar(path, '@')) |i| {
        mod_ver = path[i + 1 ..];
        path = path[0..i];
    }
    const first = if (v.indexOfChar(path, '/')) |i| path[0..i] else return null;
    if (v.indexOfChar(first, '.') == null) return null;
    if (module_dirs.get(path_in)) |d| return d;
    const script =
        \\cd "$1" || exit 1; export GOFLAGS="${GOFLAGS:+$GOFLAGS }-modcacherw"
        \\command -v go >/dev/null 2>&1 || exit 127
        \\if [ -f go.mod ]; then
        \\  go list -m -json "$2" 2>/dev/null || { go get "$2${3:+@$3}" >&2 && go list -m -json "$2"; }
        \\else
        \\  go mod download -json "$2@${3:-latest}"
        \\fi
    ;
    if (!S.opt.quiet) sys.eprint("INFO  downloading module {s} ...\n", .{path_in});
    const r = sys.runCode(&.{ "sh", "-c", script, "sh", root, path, mod_ver }) orelse return null;
    var dir: ?[]const u8 = null;
    if (r.code == 127) {
        warn("module \"{s}\" not found locally and the Go toolchain is not installed (Hugo Modules need Go: https://go.dev/dl/)", .{path_in});
    } else if (r.code != 0) {
        var msg = v.trimWs(r.stderr);
        if (v.indexOf(r.stdout, "\"Error\": \"")) |i| {
            const st = i + 10;
            if (v.indexOfPos(r.stdout, st, "\"\n")) |e| msg = r.stdout[st..e];
        }
        warn("failed to download module \"{s}\": {s}", .{ path_in, msg });
    } else if (v.indexOf(r.stdout, "\"Dir\":")) |i| {
        const q1 = v.indexOfPos(r.stdout, i + 6, "\"") orelse r.stdout.len;
        if (q1 < r.stdout.len) if (v.indexOfPos(r.stdout, q1 + 1, "\"")) |q2| {
            const d = r.stdout[q1 + 1 .. q2];
            if (sys.kindOf(d) == .dir) dir = d;
        };
    }
    module_dirs.put(sys.A, path_in, dir) catch {};
    return dir;
}

fn langWeightLess(_: void, a: *Site, b: *Site) bool {
    const wa = a.lang_map.int("weight", 0);
    const wb = b.lang_map.int("weight", 0);
    if (wa != wb) {
        if (wa == 0) return false;
        if (wb == 0) return true;
        return wa < wb;
    }
    return std.mem.order(u8, a.lang, b.lang) == .lt;
}

/// Load the project: one Site per configured language.
pub fn load(opt: Options) anyerror!void {
    all = .empty;
    git_files = null;
    git_loaded = false;
    date_chains = null;
    try loadLang(opt, null);
    const first = S;
    try all.append(sys.A, first);
    for (first.langs) |code| {
        if (v.eq(code, first.lang)) continue;
        try loadLang(opt, code);
        try all.append(sys.A, S);
    }
    std.mem.sort(*Site, all.items, {}, langWeightLess);
    S = first;
}

pub fn isMultilingual() bool {
    return all.items.len > 1;
}

fn loadLang(opt: Options, lang_in: ?[]const u8) anyerror!void {
    const s = try sys.A.create(Site);
    s.* = .{ .opt = opt, .cfg = v.newMap(), .params = v.newMap(), .lang_map = v.newMap(), .menus = v.newMap(), .data = v.newMap(), .i18n = v.newMap(), .store = v.newMap() };
    S = s;
    s.now = .{ .sec = sys.nowSeconds() };
    const root = opt.root;
    var has_cfg = false;
    for (cfg_names) |n| if (sys.exists(abs(&.{ root, n }))) {
        has_cfg = true;
    };
    if (!has_cfg and sys.kindOf(abs(&.{ root, "config", "_default" })) != .dir) return fatal("Unable to locate config file or config directory in {s}. Perhaps you need to create a new project.\nRun `zssg new site <name>` to scaffold one.", .{root});
    s.cfg = try loadComponentCfg(root, opt.env);
    if (opt.theme) |t| s.cfg.putCI("theme", v.S(t));
    if (opt.base_url) |b| s.cfg.putCI("baseURL", v.S(b));
    if (!git_loaded and s.cfg.boolean("enableGitInfo", false)) {
        git_loaded = true;
        try loadGitInfo();
    }

    // theme components (project first, then themes in order; themes may pull in further themes)
    var comps: std.ArrayList([]const u8) = .empty;
    try comps.append(sys.A, root);
    const themes_dir = s.cfg.str("themesDir") orelse "themes";
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.appendSlice(sys.A, themeNames(s.cfg));
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const name = queue.items[qi];
        const dir = resolveTheme(root, themes_dir, name) orelse return fatal("theme \"{s}\" not found (looked in {s}/{s})", .{ name, root, themes_dir });
        var dup = false;
        for (comps.items) |c| if (v.eq(c, dir)) {
            dup = true;
        };
        if (dup) continue;
        try comps.append(sys.A, dir);
        const tcfg = try loadComponentCfg(dir, opt.env);
        try queue.appendSlice(sys.A, themeNames(tcfg));
        // theme config supplies defaults for params, menus, taxonomies, outputs, markup ...
        const mergeable = [_][]const u8{ "params", "menus", "menu", "taxonomies", "outputs", "outputFormats", "mediaTypes", "markup", "permalinks", "imaging", "related", "privacy", "security", "sitemap", "minify", "pagination", "services" };
        for (mergeable) |k| {
            const tv = tcfg.getCI(k) orelse continue;
            if (s.cfg.getCI(k)) |ex| {
                if (ex == .map and tv == .map) data.mergeDefaults(ex.map, tv.map);
            } else s.cfg.putCI(k, tv);
        }
    }
    s.components = comps.items;

    // language overlay (single language build: the default content language)
    s.default_lang = s.cfg.str("defaultContentLanguage") orelse "en";
    s.lang = lang_in orelse s.default_lang;
    {
        var codes: std.ArrayList([]const u8) = .empty;
        if (s.cfg.map("languages")) |langs| for (langs.m.keys(), langs.m.values()) |code, lv| {
            if (lv == .map and lv.map.boolean("disabled", false)) continue;
            var off = false;
            if (s.cfg.list("disableLanguages")) |dl| for (dl.items.items) |d| if (v.eqi(v.toStr(d), code)) {
                off = true;
            };
            if (!off) try codes.append(sys.A, code);
        };
        if (codes.items.len == 0) try codes.append(sys.A, s.default_lang);
        var has_default = false;
        for (codes.items) |c| if (v.eq(c, s.default_lang)) {
            has_default = true;
        };
        if (!has_default and lang_in == null) s.lang = codes.items[0];
        s.langs = codes.items;
        if (codes.items.len > 1 and (!v.eq(s.lang, s.default_lang) or s.cfg.boolean("defaultContentLanguageInSubdir", false))) s.lang_prefix = v.concat(&.{ "/", s.lang });
    }
    if (s.cfg.map("languages")) |langs| {
        if (langs.map(s.lang)) |lm| {
            s.lang_map = lm;
            s.lang_dirs = lm.str("contentDir") != null;
            for (lm.m.keys(), lm.m.values()) |k, val| {
                if (v.eqi(k, "params") and val == .map) {
                    const p = s.cfg.map("params") orelse blk: {
                        const n = v.newMap();
                        s.cfg.put("params", v.M(n));
                        break :blk n;
                    };
                    overlay(p, val.map);
                } else if ((v.eqi(k, "menus") or v.eqi(k, "menu")) and val == .map) {
                    s.cfg.putCI("menus", val);
                    s.cfg.remove("menu");
                } else if (!v.eqi(k, "weight") and !v.eqi(k, "languageName") and !v.eqi(k, "contentDir")) {
                    s.cfg.putCI(k, val);
                } else if (v.eqi(k, "contentDir")) s.cfg.putCI(k, val);
            }
        }
    }

    s.title = s.cfg.str("title") orelse "";
    var bu = s.cfg.str("baseURL") orelse "/";
    if (bu.len == 0) bu = "/";
    if (!v.endsWith(bu, "/")) bu = v.concat(&.{ bu, "/" });
    if (opt.port != 0 and opt.base_url == null) bu = v.fmt("http://localhost:{d}{s}/", .{ opt.port, basePathOf(bu) });
    s.base_url = bu;
    s.base_path = basePathOf(bu);
    s.content_dir = s.cfg.str("contentDir") orelse "content";
    s.dest = opt.dest orelse abs(&.{ root, s.cfg.str("publishDir") orelse "public" });
    if (s.cfg.map("params")) |p| s.params = data.lowerKeys(v.M(p)).map;
    s.summary_length = s.cfg.int("summaryLength", 70);
    if (s.cfg.list("disableKinds")) |dk| for (dk.items.items) |k| if (v.rawStr(k)) |ks| try s.disabled.put(sys.A, v.lower(ks), {});
    if (s.cfg.map("markup")) |mk| {
        if (mk.map("goldmark")) |g| if (g.map("renderer")) |r| {
            s.unsafe_html = r.boolean("unsafe", false);
        };
        @import("highlight.zig").configure(mk.map("highlight"), s.cfg);
    }

    // output formats
    for (&builtin_formats) |*f| try s.formats.put(sys.A, f.name, f);
    if (s.cfg.map("outputFormats")) |ofs| for (ofs.m.keys(), ofs.m.values()) |name, fv| if (fv == .map) {
        const fm = fv.map;
        const f = try sys.A.create(OutputFormat);
        const lname = v.lower(name);
        const base: OutputFormat = if (s.formats.get(lname)) |ex| ex.* else .{ .name = lname, .media = "text/plain", .suffix = "txt" };
        f.* = base;
        f.name = lname;
        if (fm.str("mediaType")) |mt| {
            f.media = mt;
            f.suffix = suffixForMedia(mt);
            f.is_html = v.eq(mt, "text/html");
        }
        if (fm.str("baseName")) |b| f.base = b;
        if (fm.str("path")) |p| f.path = p;
        if (fm.str("rel")) |r| f.rel = r;
        f.is_plain = fm.boolean("isPlainText", f.is_plain);
        f.is_html = fm.boolean("isHTML", f.is_html);
        f.permalinkable = fm.boolean("permalinkable", f.permalinkable);
        try s.formats.put(sys.A, lname, f);
    };

    try collectLayouts();
    try loadData();
    try loadI18n();
    try loadContent();
    try assemble();
}

fn suffixForMedia(mt: []const u8) []const u8 {
    if (S.cfg.map("mediaTypes")) |mts| if (mts.map(mt)) |m| if (m.list("suffixes")) |sl| if (sl.items.items.len > 0) {
        if (v.rawStr(sl.items.items[0])) |x| return x;
    };
    const table = [_][2][]const u8{ .{ "text/html", "html" }, .{ "application/json", "json" }, .{ "application/rss+xml", "xml" }, .{ "application/xml", "xml" }, .{ "text/xml", "xml" }, .{ "application/atom+xml", "xml" }, .{ "text/plain", "txt" }, .{ "text/csv", "csv" }, .{ "text/css", "css" }, .{ "text/javascript", "js" }, .{ "application/javascript", "js" }, .{ "text/calendar", "ics" }, .{ "text/markdown", "md" }, .{ "application/manifest+json", "webmanifest" }, .{ "application/feed+json", "json" } };
    for (table) |t| if (v.eq(t[0], mt)) return t[1];
    if (v.indexOfChar(mt, '+')) |p| return mt[p + 1 ..];
    if (v.indexOfChar(mt, '/')) |p| return mt[p + 1 ..];
    return "txt";
}

fn basePathOf(bu: []const u8) []const u8 {
    var rest = bu;
    if (v.indexOf(bu, "://")) |i| {
        rest = bu[i + 3 ..];
        rest = if (v.indexOfChar(rest, '/')) |sl| rest[sl..] else "/";
    } else if (v.startsWith(bu, "//")) {
        rest = bu[2..];
        rest = if (v.indexOfChar(rest, '/')) |sl| rest[sl..] else "/";
    }
    return std.mem.trimEnd(u8, rest, "/");
}

// ------------------------------------------------------------------ component file system

/// First existing file `rel` across components (project wins over themes).
pub fn findFile(sub: []const u8, rel: []const u8) ?[]const u8 {
    for (S.components) |c| {
        const p = abs(&.{ c, sub, rel });
        if (sys.kindOf(p) == .file) return p;
    }
    return null;
}

fn collectLayouts() anyerror!void {
    const dir = S.cfg.str("layoutDir") orelse "layouts";
    for (S.components) |c| {
        const base = abs(&.{ c, dir });
        for (sys.walk(base)) |rel| {
            if (!S.layouts.contains(rel)) try S.layouts.put(sys.A, rel, abs(&.{ base, rel }));
        }
    }
    // parse everything up front (like Hugo) so that inline {{ define }}s are known and errors surface early
    for (S.layouts.keys()) |rel| {
        const ext = v.lower(v.pathExt(rel));
        const text_like = [_][]const u8{ ".html", ".xml", ".json", ".txt", ".md", ".css", ".js", ".csv", ".ics", ".webmanifest", ".atom", ".rss", ".svg" };
        var ok = false;
        for (text_like) |t| if (v.eq(t, ext)) {
            ok = true;
        };
        if (ok) _ = try getTemplate(rel);
    }
}

pub fn getTemplate(rel: []const u8) anyerror!?*tmpl.Template {
    if (S.tmpl_cache.get(rel)) |t| return t;
    const path = S.layouts.get(rel) orelse return null;
    const src = sys.readFile(path) orelse return null;
    const t = tmpl.parse(rel, src) catch |e| {
        if (e == error.TemplateError) return fatal("parse of template failed: {s}", .{tmpl.err_msg});
        return e;
    };
    try S.tmpl_cache.put(sys.A, rel, t);
    for (t.defs.keys(), t.defs.values()) |k, d| funcs.registerDefine(k, d);
    return t;
}

fn loadDataDir(dir: []const u8, into: *Map) void {
    for (sys.listDir(dir)) |e| {
        const p = abs(&.{ dir, e.name });
        if (e.is_dir) {
            const sub = into.map(e.name) orelse blk: {
                const n = v.newMap();
                into.put(e.name, v.M(n));
                break :blk n;
            };
            loadDataDir(p, sub);
            continue;
        }
        const ext = v.pathExt(e.name);
        const src = sys.readFile(p) orelse continue;
        const val = data.parseByExt(ext, src) catch {
            if (v.eq(ext, ".toml") or v.eq(ext, ".yaml") or v.eq(ext, ".yml") or v.eq(ext, ".json")) warn("failed to parse data file {s}: {s}", .{ p, data.err_msg });
            continue;
        };
        const key = v.pathStem(e.name);
        if (into.get(key) == null) into.put(key, val);
    }
}

fn loadData() anyerror!void {
    for (S.components) |c| loadDataDir(abs(&.{ c, S.cfg.str("dataDir") orelse "data" }), S.data);
}

fn loadI18n() anyerror!void {
    // later components provide fallbacks; project overrides theme
    for (S.components) |c| {
        const dir = abs(&.{ c, "i18n" });
        for (sys.listDir(dir)) |e| {
            if (e.is_dir) continue;
            const stem = v.pathStem(e.name);
            const src = sys.readFile(abs(&.{ dir, e.name })) orelse continue;
            const val = data.parseByExt(v.pathExt(e.name), src) catch continue;
            const lm = S.i18n.map(v.lower(stem)) orelse blk: {
                const n = v.newMap();
                S.i18n.put(v.lower(stem), v.M(n));
                break :blk n;
            };
            switch (val) {
                .map => |m| for (m.m.keys(), m.m.values()) |k, x| {
                    if (lm.get(k) == null) lm.put(k, x);
                },
                .list => |l| for (l.items.items) |it| if (it == .map) {
                    const id = it.map.str("id") orelse continue;
                    if (lm.get(id) == null) lm.put(id, it.map.get("translation") orelse .nil);
                },
                else => {},
            }
        }
    }
}

// ------------------------------------------------------------------ content

pub fn urlize(s: []const u8) []const u8 {
    var b: v.Buf = .{};
    var i: usize = 0;
    const lower = !S.cfg.boolean("disablePathToLower", false);
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            if (std.ascii.isAlphanumeric(c)) {
                b.ch(if (lower) std.ascii.toLower(c) else c);
            } else if (c == ' ') {
                if (b.len() == 0 or b.str()[b.len() - 1] != '-') b.ch('-');
            } else if (c == '.' or c == '/' or c == '_' or c == '-' or c == '#' or c == '+' or c == '~' or c == '@' or c == '%') {
                if (c == '-' and b.len() > 0 and b.str()[b.len() - 1] == '-') {} else b.ch(c);
            }
            i += 1;
        } else {
            const n = @min(v.utf8Len(c), s.len - i);
            b.add(s[i .. i + n]);
            i += n;
        }
    }
    return std.mem.trim(u8, b.str(), "-");
}

fn isContentFile(name: []const u8) bool {
    const ext = v.lower(v.pathExt(name));
    return v.eq(ext, ".md") or v.eq(ext, ".markdown") or v.eq(ext, ".mdown") or v.eq(ext, ".html") or v.eq(ext, ".htm") or externalMarkupOf(ext).len > 0;
}

/// Content formats rendered by external helpers (Hugo's asciidocext, pandoc, rst, org).
pub fn externalMarkupOf(ext: []const u8) []const u8 {
    if (v.eq(ext, ".adoc") or v.eq(ext, ".asciidoc") or v.eq(ext, ".ad")) return "asciidocext";
    if (v.eq(ext, ".pandoc") or v.eq(ext, ".pdc")) return "pandoc";
    if (v.eq(ext, ".rst")) return "rst";
    if (v.eq(ext, ".org")) return "org";
    return "";
}

pub fn newPage() *Page {
    const p = sys.A.create(Page) catch @panic("oom");
    p.* = .{ .fm = v.newMap(), .params = v.newMap(), .scratch = v.newMap(), .store = v.newMap(), .site = S };
    return p;
}

const FM = struct { map: *Map, body: []const u8 };

pub fn splitFrontMatter(src_in: []const u8, path: []const u8) anyerror!FM {
    var src = src_in;
    if (v.startsWith(src, "\xEF\xBB\xBF")) src = src[3..];
    const lead = std.mem.trimStart(u8, src, " \t\r\n");
    if (v.startsWith(lead, "---") or v.startsWith(lead, "+++")) {
        const delim = lead[0..3];
        const first_nl = v.indexOfChar(lead, '\n') orelse return .{ .map = v.newMap(), .body = src };
        if (v.trimWs(lead[0..first_nl]).len != 3) return .{ .map = v.newMap(), .body = src };
        var pos = first_nl + 1;
        while (pos <= lead.len) {
            const nl = v.indexOfPos(lead, pos, "\n") orelse lead.len;
            const line = std.mem.trimEnd(u8, lead[pos..nl], " \t\r");
            if (v.eq(line, delim)) {
                const fm_src = lead[first_nl + 1 .. pos];
                const body = if (nl < lead.len) lead[nl + 1 ..] else "";
                const val: Value = if (delim[0] == '+') v.M(data.parseToml(fm_src) catch return fatal("{s}: failed to parse TOML front matter: {s}", .{ path, data.err_msg })) else data.parseYaml(fm_src) catch return fatal("{s}: failed to parse YAML front matter: {s}", .{ path, data.err_msg });
                return .{ .map = if (val == .map) val.map else v.newMap(), .body = body };
            }
            if (nl >= lead.len) break;
            pos = nl + 1;
        }
        return fatal("{s}: unterminated front matter", .{path});
    }
    if (v.startsWith(lead, "{")) {
        // JSON front matter: find the matching brace
        var depth: i32 = 0;
        var q = false;
        var i: usize = 0;
        while (i < lead.len) : (i += 1) {
            const c = lead[i];
            if (q) {
                if (c == '\\') i += 1 else if (c == '"') q = false;
            } else if (c == '"') {
                q = true;
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    const val = data.parseJson(lead[0 .. i + 1]) catch return fatal("{s}: failed to parse JSON front matter", .{path});
                    return .{ .map = if (val == .map) val.map else v.newMap(), .body = std.mem.trimStart(u8, lead[i + 1 ..], "\r\n") };
                }
            }
        }
    }
    return .{ .map = v.newMap(), .body = src };
}

pub fn toTime(val: Value) ?v.Time {
    return switch (val) {
        .time => |t| t,
        .str => |s| tm.parse(s),
        .int => |i| v.Time{ .sec = i },
        else => null,
    };
}

fn humanizeName(s: []const u8) []const u8 {
    var r = v.replaceAll(v.replaceAll(s, "-", " "), "_", " ");
    if (S.cfg.boolean("pluralizeListTitles", true)) r = funcs.pluralStr(r);
    return funcs.titleCase(r);
}

// ---------------------------------------------------------------- front matter dates

const DateChains = struct { date: []const []const u8, lastmod: []const []const u8, publish: []const []const u8, expiry: []const []const u8 };
var date_chains: ?DateChains = null;

fn expandChain(cfg_val: ?Value, defaults: []const []const u8) []const []const u8 {
    var raw: std.ArrayList([]const u8) = .empty;
    if (cfg_val) |x| {
        switch (x) {
            .list => |l| for (l.items.items) |it| raw.append(sys.A, v.lower(v.toStr(it))) catch {},
            .str => |st| raw.append(sys.A, v.lower(st)) catch {},
            else => {},
        }
    } else raw.appendSlice(sys.A, defaults) catch {};
    var out: std.ArrayList([]const u8) = .empty;
    for (raw.items) |it| {
        const items: []const []const u8 = if (v.eq(it, ":default")) defaults else &.{it};
        for (items) |x| {
            const aliases: []const []const u8 = if (v.eq(x, "lastmod")) &.{"modified"} else if (v.eq(x, "publishdate")) &.{ "pubdate", "published" } else if (v.eq(x, "expirydate")) &.{"unpublishdate"} else &.{};
            for ([_][]const []const u8{ &.{x}, aliases }) |grp| for (grp) |y| {
                var dup = false;
                for (out.items) |o| if (v.eq(o, y)) {
                    dup = true;
                };
                if (!dup) out.append(sys.A, y) catch {};
            };
        }
    }
    return out.items;
}

fn dateChains() DateChains {
    if (date_chains) |c| return c;
    const fmc = S.cfg.map("frontmatter");
    const get = struct {
        fn f(m: ?*Map, k: []const u8) ?Value {
            return if (m) |mm| mm.getCI(k) else null;
        }
    }.f;
    date_chains = .{
        .date = expandChain(get(fmc, "date"), &.{ "date", "publishdate", "lastmod" }),
        .lastmod = expandChain(get(fmc, "lastmod"), &.{ ":git", "lastmod", "date", "publishdate" }),
        .publish = expandChain(get(fmc, "publishdate"), &.{ "publishdate", "date" }),
        .expiry = expandChain(get(fmc, "expirydate"), &.{"expirydate"}),
    };
    return date_chains.?;
}

/// Hugo's dateAndSlugFromBaseFilename.
fn dateFromFilename(p: *Page) ?struct { t: v.Time, slug: []const u8 } {
    const f = p.file orelse return null;
    var base = v.pathStem(f);
    if (v.eq(base, "index") or v.eq(base, "_index")) base = v.pathBase(v.pathDir(f));
    if (base.len < 10) return null;
    const delims = " -_";
    if (base.len >= 19) {
        const ts = std.mem.replaceOwned(u8, sys.A, base[11..19], "-", ":") catch "";
        if (tm.parse(v.concat(&.{ base[0..10], "T", ts }))) |t| return .{ .t = t, .slug = std.mem.trim(u8, base[19..], delims) };
    }
    if (tm.parse(base[0..10])) |t| return .{ .t = t, .slug = std.mem.trim(u8, base[10..], delims) };
    return null;
}

fn chainDate(p: *Page, chain: []const []const u8, param_key: []const u8) v.Time {
    for (chain) |id| {
        var t: ?v.Time = null;
        if (v.eq(id, ":filename")) {
            if (dateFromFilename(p)) |r| {
                t = r.t;
                if (p.fm.getCI("slug") == null and r.slug.len > 0) p.params.put("slug", v.S(r.slug));
            }
        } else if (v.eq(id, ":filemodtime")) {
            if (p.file_abs.len > 0) if (sys.stat(p.file_abs)) |st| {
                t = .{ .sec = st.mtime };
            };
        } else if (v.eq(id, ":git")) {
            if (gitInfoFor(p)) |g| t = g.author_date;
        } else if (p.fm.getCI(id)) |x| {
            if (!(x == .nil or (x == .str and x.str.len == 0))) t = toTime(x);
        }
        if (t) |tt| {
            if (p.params.get(param_key) == null) p.params.put(param_key, .{ .time = tt });
            return tt;
        }
    }
    return tm.zero;
}

fn applyDates(p: *Page) void {
    const c = dateChains();
    p.date = chainDate(p, c.date, "date");
    p.lastmod = chainDate(p, c.lastmod, "lastmod");
    p.publish = chainDate(p, c.publish, "publishdate");
    p.expiry = chainDate(p, c.expiry, "expirydate");
}

// ---------------------------------------------------------------- Git info (enableGitInfo)

pub const GitCommit = struct {
    hash: []const u8,
    abbrev: []const u8,
    subject: []const u8,
    author_name: []const u8,
    author_email: []const u8,
    author_date: v.Time,
    commit_date: v.Time,
    body: []const u8,
    parent: ?*GitCommit = null,
};

var git_files: ?std.StringHashMapUnmanaged(*GitCommit) = null;
var git_top: []const u8 = "";
var git_loaded = false;

fn parseGitDate(s: []const u8) v.Time {
    // "2006-01-02 15:04:05 -0700"
    if (s.len < 25) return tm.zero;
    const iso = v.concat(&.{ s[0..10], "T", s[11..19], s[20..23], ":", s[23..25] });
    return tm.parse(iso) orelse tm.zero;
}

/// Runs `git log` once (like github.com/bep/gitmap) and maps each file to its
/// most recent commit, with older commits chained through `parent`.
pub fn loadGitInfo() anyerror!void {
    const root = S.opt.root;
    const r1 = sys.run(&.{ "git", "-C", root, "rev-parse", "--show-cdup" }) orelse return fatal("failed to load Git data: git executable not found in $PATH", .{});
    if (!r1.ok) return fatal("failed to load Git data: {s}", .{std.mem.trim(u8, r1.stderr, " \n\r")});
    const cdup = std.mem.trim(u8, r1.stdout, " \n\r");
    git_top = sys.absPath(v.pathJoin(&.{ root, cdup }));
    const r2 = sys.run(&.{ "git", "-c", "diff.renames=0", "-c", "log.showSignature=0", "-C", root, "log", "--name-only", "--no-merges", "--format=format:%x1e%H%x1f%h%x1f%s%x1f%aN%x1f%aE%x1f%ai%x1f%ci%x1f%b%x1d" }) orelse return;
    if (!r2.ok) return fatal("failed to load Git data: {s}", .{std.mem.trim(u8, r2.stderr, " \n\r")});
    var files: std.StringHashMapUnmanaged(*GitCommit) = .empty;
    var tails: std.StringHashMapUnmanaged(*GitCommit) = .empty;
    const log = std.mem.trim(u8, r2.stdout, "\n\x1e'");
    var entries = std.mem.splitScalar(u8, log, 0x1e);
    while (entries.next()) |e| {
        var parts = std.mem.splitScalar(u8, e, 0x1d);
        const head = parts.first();
        const names = parts.next() orelse "";
        var items: [8][]const u8 = .{ "", "", "", "", "", "", "", "" };
        var it = std.mem.splitScalar(u8, head, 0x1f);
        var k: usize = 0;
        while (it.next()) |x| : (k += 1) {
            if (k < 8) items[k] = x;
        }
        if (k < 7) continue;
        var ns = std.mem.splitScalar(u8, names, '\n');
        while (ns.next()) |n0| {
            const n = std.mem.trim(u8, n0, " \t\r");
            if (n.len == 0) continue;
            const c = try sys.A.create(GitCommit);
            c.* = .{ .hash = items[0], .abbrev = items[1], .subject = items[2], .author_name = items[3], .author_email = items[4], .author_date = parseGitDate(items[5]), .commit_date = parseGitDate(items[6]), .body = std.mem.trim(u8, items[7], " \t\r\n") };
            if (files.get(n)) |root_info| {
                const anc = tails.get(n) orelse root_info;
                anc.parent = c;
                try tails.put(sys.A, n, c);
            } else try files.put(sys.A, n, c);
        }
    }
    git_files = files;
}

pub fn gitInfoFor(p: *Page) ?*GitCommit {
    const files = git_files orelse return null;
    if (p.file_abs.len == 0) return null;
    var name = sys.absPath(p.file_abs);
    if (v.startsWith(name, git_top)) name = name[git_top.len..];
    name = std.mem.trimStart(u8, name, "/");
    return files.get(name);
}

fn applyFrontMatter(p: *Page) void {
    const fm = p.fm;
    // params: every front matter key, lower-cased; nested `params` flattened on top
    p.params = data.lowerKeys(v.M(fm)).map;
    if (p.params.map("params")) |pp| {
        for (pp.m.keys(), pp.m.values()) |k, x| p.params.put(k, x);
    }
    if (fm.str("title")) |t| p.title = t;
    applyDates(p);
    p.weight = fm.int("weight", 0);
    p.draft = fm.boolean("draft", false);
    if (fm.boolean("headless", false)) {
        p.render = false;
        p.list = false;
    }
    if (fm.map("build") orelse fm.map("_build")) |b| {
        if (b.getCI("render")) |r| p.render = !(v.eq(v.toStr(r), "never") or v.eq(v.toStr(r), "false") or v.eq(v.toStr(r), "link"));
        if (b.getCI("publishResources") orelse b.getCI("publishresources")) |pr| p.publish_res = v.truth(pr);
        if (b.getCI("list")) |l| p.list = !(v.eq(v.toStr(l), "never") or v.eq(v.toStr(l), "false") or v.eq(v.toStr(l), "local"));
    }
}

fn applyCascade(p: *Page, casc: ?*Map) void {
    const c = casc orelse return;
    for (c.m.keys(), c.m.values()) |k, x| {
        if (v.eqi(k, "_target") or v.eqi(k, "target")) continue;
        if (v.eqi(k, "params") and x == .map) {
            for (x.map.m.keys(), x.map.m.values()) |pk, pv| {
                if (p.fm.getCI(pk) == null) p.fm.put(pk, pv);
            }
            continue;
        }
        if (p.fm.getCI(k) == null) p.fm.put(k, x);
    }
}

fn cascadeOf(p: *Page, inherited: ?*Map) ?*Map {
    const own_v = p.fm.getCI("cascade") orelse return inherited;
    var own: ?*Map = null;
    if (own_v == .map) own = own_v.map;
    if (own_v == .list) {
        // list form: merge entries without (or ignoring) targets
        const m = v.newMap();
        for (own_v.list.items.items) |e| if (e == .map) overlay(m, e.map);
        own = m;
    }
    const o = own orelse return inherited;
    const merged = v.newMap();
    if (inherited) |i| overlay(merged, i);
    overlay(merged, o);
    return merged;
}

fn readPage(rel: []const u8, abs_path: []const u8) anyerror!*Page {
    const src = sys.readFile(abs_path) orelse return fatal("cannot read {s}", .{abs_path});
    const fm = try splitFrontMatter(src, rel);
    const p = newPage();
    p.fm = fm.map;
    p.raw = fm.body;
    p.file = rel;
    p.file_abs = abs_path;
    const ext = v.lower(v.pathExt(rel));
    p.is_md = !(v.eq(ext, ".html") or v.eq(ext, ".htm"));
    p.ext_markup = externalMarkupOf(ext);
    if (fm.map.str("markup")) |mk| {
        const l = v.lower(mk);
        if (v.eq(l, "asciidoc") or v.eq(l, "adoc") or v.eq(l, "asciidocext")) p.ext_markup = "asciidocext" else if (v.eq(l, "pandoc") or v.eq(l, "pdc")) p.ext_markup = "pandoc" else if (v.eq(l, "rst")) p.ext_markup = "rst" else if (v.eq(l, "org")) p.ext_markup = "org" else if (v.eq(l, "html") or v.eq(l, "htm")) {
            p.ext_markup = "";
            p.is_md = false;
        } else if (v.eq(l, "markdown") or v.eq(l, "md") or v.eq(l, "goldmark")) {
            p.ext_markup = "";
            p.is_md = true;
        }
    }
    if (p.ext_markup.len > 0) p.is_md = false;
    return p;
}

fn addResources(p: *Page, dir_abs: []const u8, rel_prefix: []const u8, recursive: bool) void {
    for (sys.listDir(dir_abs)) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        const full = abs(&.{ dir_abs, e.name });
        const rel = if (rel_prefix.len == 0) e.name else abs(&.{ rel_prefix, e.name });
        if (e.is_dir) {
            if (recursive) addResources(p, full, rel, true);
            continue;
        }
        if (rel_prefix.len == 0 and (v.startsWith(e.name, "index.") or v.startsWith(e.name, "_index."))) continue;
        if (!recursive and isContentFile(e.name)) continue;
        const r = sys.A.create(Resource) catch continue;
        r.* = .{ .name = rel, .title = rel, .path = rel, .src_path = full, .target = "", .media = objs.mediaTypeOf(rel), .params = v.newMap() };
        p.resources.append(sys.A, r) catch {};
    }
}

const FileLang = struct { stem: []const u8, lang: []const u8 };

/// Splits "about.fr.md" into stem "about" and language "fr" (translation by file name).
fn fileLang(name: []const u8) FileLang {
    const stem = v.pathStem(name);
    if (S.lang_dirs) return .{ .stem = stem, .lang = S.lang };
    if (v.lastIndexOfChar(stem, '.')) |d| {
        for (S.langs) |l| if (v.eqi(stem[d + 1 ..], l)) return .{ .stem = stem[0..d], .lang = l };
    }
    return .{ .stem = stem, .lang = S.default_lang };
}

fn findIndex(entries: []sys.Entry, prefix: []const u8) ?[]const u8 {
    const want = prefix[0 .. prefix.len - 1];
    for (entries) |e| {
        if (e.is_dir or !isContentFile(e.name)) continue;
        const fl = fileLang(e.name);
        if (v.eq(fl.stem, want) and v.eq(fl.lang, S.lang)) return e.name;
    }
    return null;
}

fn hasAnyIndex(entries: []sys.Entry, want: []const u8) bool {
    for (entries) |e| {
        if (e.is_dir or !isContentFile(e.name)) continue;
        if (v.eq(fileLang(e.name).stem, want)) return true;
    }
    return false;
}

fn walkContent(dir_rel: []const u8, parent: *Page, casc_in: ?*Map, depth: usize, parent_dir: []const u8) anyerror!void {
    const dir_abs = abs(&.{ S.opt.root, S.content_dir, dir_rel });
    const entries = sys.listDir(dir_abs);
    var node = parent;
    var casc = casc_in;
    if (depth > 0) {
        // a directory below content/: section if top-level or it has _index
        const idx = findIndex(entries, "_index.");
        if (idx != null or depth == 1) {
            var sp: *Page = undefined;
            if (idx) |name| {
                sp = try readPage(abs(&.{ dir_rel, name }), abs(&.{ dir_abs, name }));
            } else {
                sp = newPage();
                sp.title = humanizeName(v.pathBase(dir_rel));
            }
            sp.kind = .section;
            sp.bundle = .branch;
            sp.path = v.concat(&.{ "/", urlize(dir_rel) });
            sp.parent = parent;
            applyCascade(sp, casc);
            casc = cascadeOf(sp, casc);
            applyFrontMatter(sp);
            if (idx != null) addResources(sp, dir_abs, "", false);
            try parent.children.append(sys.A, sp);
            try S.pages.append(sys.A, sp);
            node = sp;
        } else if (parent.bundle == .branch and parent.file != null) {
            // a plain folder inside a branch bundle: its files are resources of the bundle
            const prefix = if (parent_dir.len == 0) dir_rel else if (v.startsWith(dir_rel, parent_dir) and dir_rel.len > parent_dir.len) dir_rel[parent_dir.len + 1 ..] else dir_rel;
            addResources(parent, dir_abs, prefix, false);
        }
    } else {
        if (findIndex(entries, "_index.")) |name| {
            const hp = try readPage(name, abs(&.{ dir_abs, name }));
            const home = S.home;
            home.fm = hp.fm;
            home.raw = hp.raw;
            home.file = hp.file;
            home.file_abs = hp.file_abs;
            home.is_md = hp.is_md;
            home.ext_markup = hp.ext_markup;
            casc = cascadeOf(home, casc);
            applyFrontMatter(home);
            addResources(home, dir_abs, "", false);
        }
    }
    for (entries) |e| {
        const rel = if (dir_rel.len == 0) e.name else abs(&.{ dir_rel, e.name });
        if (e.name[0] == '.') continue;
        if (e.is_dir) {
            const sub_abs = abs(&.{ dir_abs, e.name });
            const sub_entries = sys.listDir(sub_abs);
            if (findIndex(sub_entries, "index.")) |name| {
                // leaf bundle
                const p = try readPage(abs(&.{ rel, name }), abs(&.{ sub_abs, name }));
                p.bundle = .leaf;
                p.path = v.concat(&.{ "/", urlize(rel) });
                p.parent = node;
                applyCascade(p, casc);
                applyFrontMatter(p);
                addResources(p, sub_abs, "", true);
                try node.children.append(sys.A, p);
                try S.pages.append(sys.A, p);
            } else if (hasAnyIndex(sub_entries, "index")) {
                // a leaf bundle that only exists in another language
            } else try walkContent(rel, node, casc, depth + 1, if (node == parent) parent_dir else dir_rel);
            continue;
        }
        if (!isContentFile(e.name)) continue;
        const fl = fileLang(e.name);
        if (v.eq(fl.stem, "_index") or v.eq(fl.stem, "index")) continue;
        if (!v.eq(fl.lang, S.lang)) continue;
        const p = try readPage(rel, abs(&.{ dir_abs, e.name }));
        p.path = v.concat(&.{ "/", urlize(abs(&.{ dir_rel, fl.stem })) });
        p.parent = node;
        applyCascade(p, casc);
        applyFrontMatter(p);
        try node.children.append(sys.A, p);
        try S.pages.append(sys.A, p);
    }
}

fn loadContent() anyerror!void {
    const home = newPage();
    home.kind = .home;
    home.bundle = .branch;
    home.path = "/";
    home.title = S.title;
    S.home = home;
    try S.pages.append(sys.A, home);
    try walkContent("", home, null, 0, "");
    for (S.pages.items) |p| applyResourceMeta(p);
    if (home.title.len == 0 and home.file == null) home.title = S.title;
    // an _index.md without a title gives the home page an empty title (Hugo)
    if (home.file != null and home.fm.getCI("title") == null) home.title = "";
}

fn resPathLess(_: void, a: *Resource, b: *Resource) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}
fn resNameLess(_: void, a: *Resource, b: *Resource) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn counterText(s: []const u8, n: usize) []const u8 {
    return std.mem.replaceOwned(u8, sys.A, s, ":counter", v.fmt("{d}", .{n})) catch s;
}

/// Front matter `resources` (name, title, params by glob on the file path) and
/// Hugo's resource order (by name).
fn applyResourceMeta(p: *Page) void {
    const rs = p.resources.items;
    if (rs.len == 0) return;
    std.sort.insertion(*Resource, rs, {}, resPathLess);
    const metas = p.fm.list("resources");
    if (metas) |ml| {
        var counters = std.StringHashMap(usize).init(sys.A);
        for (rs) |r| {
            var name_set = false;
            var title_set = false;
            var name_n: usize = 0;
            var title_n: usize = 0;
            for (ml.items.items, 0..) |mv, mi| {
                if (mv != .map) continue;
                const m = mv.map;
                const src = if (m.getCI("src")) |x| v.toStr(x) else continue;
                if (!objs.glob(src, r.path)) continue;
                if (!name_set) if (m.getCI("name")) |nv| {
                    var name = std.mem.trimStart(u8, v.toStr(nv), "/");
                    if (v.contains(name, ":counter")) {
                        if (name_n == 0) {
                            const key = v.fmt("name_{d}", .{mi});
                            name_n = (counters.get(key) orelse 0) + 1;
                            counters.put(key, name_n) catch {};
                        }
                        name = counterText(name, name_n);
                    }
                    r.name = name;
                    name_set = true;
                };
                if (!title_set) if (m.getCI("title")) |tv| {
                    var title = v.toStr(tv);
                    if (v.contains(title, ":counter")) {
                        if (title_n == 0) {
                            const key = v.fmt("title_{d}", .{mi});
                            title_n = (counters.get(key) orelse 0) + 1;
                            counters.put(key, title_n) catch {};
                        }
                        title = counterText(title, title_n);
                    }
                    r.title = title;
                    title_set = true;
                };
                if (m.getCI("params")) |pv| if (pv == .map) {
                    const np = v.newMap();
                    for (v.sortedKeys(r.params)) |k| np.put(k, r.params.get(k).?);
                    for (v.sortedKeys(pv.map)) |k| np.put(v.lower(k), pv.map.get(k).?);
                    r.params = np;
                };
            }
        }
    }
    std.sort.insertion(*Resource, rs, {}, resNameLess);
}

fn shouldBuild(p: *Page) bool {
    if (p.draft and !S.opt.drafts) return false;
    if (!S.opt.future and !p.publish.zero and p.publish.sec > S.now.sec) return false;
    if (!S.opt.expired and !p.expiry.zero and p.expiry.sec <= S.now.sec) return false;
    return true;
}

pub fn pageLess(_: void, a: *Page, b: *Page) bool {
    if (a.weight != b.weight) {
        if (a.weight == 0) return false;
        if (b.weight == 0) return true;
        return a.weight < b.weight;
    }
    if (a.date.sec != b.date.sec) return a.date.sec > b.date.sec;
    const at = objs.linkTitle(a);
    const bt = objs.linkTitle(b);
    const o = v.collate(at, bt);
    if (o != .eq and !v.eqi(at, bt)) return o == .lt;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn aggregateDates(p: *Page) void {
    for (p.children.items) |c| if (c.kind == .section) aggregateDates(c);
    if (!p.dates_zero) return;
    updateFromDesc(p, p);
}
fn updateFromDesc(p: *Page, n: *Page) void {
    for (n.children.items) |c| {
        if (c.date.sec > p.date.sec or (p.date.zero and !c.date.zero)) p.date = c.date;
        if (c.lastmod.sec > p.lastmod.sec or (p.lastmod.zero and !c.lastmod.zero)) p.lastmod = c.lastmod;
        if (!c.publish.zero and (p.publish.zero or c.publish.sec > p.publish.sec) and c.publish.sec < S.now.sec) p.publish = c.publish;
        if (c.kind == .section) updateFromDesc(p, c);
    }
}

/// The (cached) 404 page of site `s`.
pub fn page404(s: *Site) *Page {
    if (s.p404) |p| return p;
    const saved = S;
    S = s;
    defer S = saved;
    const p = newPage();
    p.title = "404 Page not found";
    p.is_404 = true;
    p.path = "/404";
    p.url = v.concat(&.{ s.lang_prefix, "/404.html" });
    p.parent = s.home;
    p.outputs = &.{&builtin_formats[0]};
    s.p404 = p;
    return p;
}

pub fn sortPages(list: []*Page) void {
    std.mem.sort(*Page, list, {}, pageLess);
}

fn sectionOf(p: *Page) []const u8 {
    if (p.kind == .home) return "";
    var it = std.mem.tokenizeScalar(u8, p.path, '/');
    const first = it.next() orelse return "";
    if (p.kind == .page and it.next() == null and p.bundle != .leaf) {
        // top-level regular page: content/about.md
        if (p.file) |f| if (v.indexOfChar(f, '/') == null) return "";
    }
    if (p.kind == .page and p.bundle == .leaf) {
        if (p.file) |f| {
            // content/about/index.md is a root-level page
            var n: usize = 0;
            for (f) |c| {
                if (c == '/') n += 1;
            }
            if (n <= 1) return "";
        }
    }
    return first;
}

fn expandPermalink(pattern: []const u8, p: *Page) []const u8 {
    var b: v.Buf = .{};
    var i: usize = 0;
    const c = tm.civil(p.date);
    const slug = p.param("slug") orelse urlize(p.title);
    const fname = if (p.file) |f| blk: {
        const stem = v.pathStem(f);
        break :blk if (v.eq(stem, "index") or v.eq(stem, "_index")) v.pathBase(v.pathDir(f)) else stem;
    } else "";
    while (i < pattern.len) {
        if (pattern[i] != ':') {
            b.ch(pattern[i]);
            i += 1;
            continue;
        }
        var e = i + 1;
        while (e < pattern.len and (std.ascii.isAlphanumeric(pattern[e]) or pattern[e] == '_')) e += 1;
        const tok = pattern[i + 1 .. e];
        // optional [n] / [n:m] slice for :sections
        var slice: []const u8 = "";
        if (e < pattern.len and pattern[e] == '[') {
            if (v.indexOfPos(pattern, e, "]")) |cl| {
                slice = pattern[e + 1 .. cl];
                e = cl + 1;
            }
        }
        if (v.eq(tok, "year")) b.print("{d}", .{c.year}) else if (v.eq(tok, "month")) b.print("{d:0>2}", .{c.month}) else if (v.eq(tok, "monthname")) b.add(tm.monthName(c.month)) else if (v.eq(tok, "day")) b.print("{d:0>2}", .{c.day}) else if (v.eq(tok, "weekday")) b.print("{d}", .{c.wday}) else if (v.eq(tok, "yearday")) b.print("{d}", .{c.yday}) else if (v.eq(tok, "title")) b.add(urlize(p.title)) else if (v.eq(tok, "slug")) b.add(urlize(slug)) else if (v.eq(tok, "slugorfilename") or v.eq(tok, "slugorcontentbasename")) b.add(urlize(p.param("slug") orelse fname)) else if (v.eq(tok, "filename") or v.eq(tok, "contentbasename")) b.add(urlize(fname)) else if (v.eq(tok, "section")) b.add(p.section) else if (v.eq(tok, "sections")) {
            var parts: std.ArrayList([]const u8) = .empty;
            var cur = if (p.kind == .page) p.parent else @as(?*Page, p);
            while (cur) |pp| : (cur = pp.parent) {
                if (pp.kind == .home) break;
                parts.insert(sys.A, 0, v.pathBase(pp.path)) catch {};
            }
            var items = parts.items;
            if (slice.len > 0) {
                if (v.indexOfChar(slice, ':')) |col| {
                    const lo = std.fmt.parseInt(usize, slice[0..col], 10) catch 0;
                    const hi = std.fmt.parseInt(usize, slice[col + 1 ..], 10) catch items.len;
                    items = items[@min(lo, items.len)..@min(hi, items.len)];
                } else if (std.fmt.parseInt(usize, slice, 10) catch null) |n| {
                    items = if (n < items.len) items[n .. n + 1] else items[0..0];
                }
            }
            b.add(std.mem.join(sys.A, "/", items) catch "");
        } else if (v.eq(tok, "unix")) b.print("{d}", .{p.date.sec}) else {
            b.ch(':');
            b.add(tok);
        }
        i = e;
    }
    return b.str();
}

fn normalizeUrl(u_in: []const u8) []const u8 {
    var u = u_in;
    if (!v.startsWith(u, "/")) u = v.concat(&.{ "/", u });
    while (v.contains(u, "//")) u = v.replaceAll(u, "//", "/");
    if (!v.endsWith(u, "/") and v.pathExt(u).len == 0) u = v.concat(&.{ u, "/" });
    return u;
}

fn computeUrl(p: *Page) void {
    computeUrlInner(p);
    if (S.lang_prefix.len > 0) p.url = v.concat(&.{ S.lang_prefix, p.url });
}

fn computeUrlInner(p: *Page) void {
    if (p.param("url")) |u| {
        p.url = normalizeUrl(u);
        return;
    }
    const perms = S.cfg.map("permalinks");
    const kind_name = @tagName(p.kind);
    if (perms) |pm| {
        var pat: ?[]const u8 = null;
        if (pm.map(kind_name)) |km| {
            const key = if (p.kind == .term or p.kind == .taxonomy) (if (p.tax) |t| t.plural else "") else p.section;
            pat = km.str(key);
        }
        if (pat == null and p.kind == .page) pat = pm.str(p.section);
        if (pat == null and p.kind == .term) if (p.tax) |t| {
            pat = pm.str(t.plural);
        };
        if (pat) |pt| {
            p.url = normalizeUrl(expandPermalink(pt, p));
            return;
        }
    }
    if (p.kind == .home) {
        p.url = "/";
        return;
    }
    var path = p.path;
    if (p.kind == .page) {
        if (p.param("slug")) |sl| path = v.concat(&.{ v.pathDir(p.path), if (v.eq(v.pathDir(p.path), "/")) "" else "/", urlize(sl) });
    }
    p.url = normalizeUrl(path);
}

fn defaultOutputs(kind: Kind) []const *const OutputFormat {
    var out: std.ArrayList(*const OutputFormat) = .empty;
    var names: []const []const u8 = if (kind == .page) &.{"html"} else &.{ "html", "rss" };
    if (S.cfg.map("outputs")) |om| if (om.list(@tagName(kind))) |l| {
        var ns: std.ArrayList([]const u8) = .empty;
        for (l.items.items) |x| if (v.rawStr(x)) |n| ns.append(sys.A, v.lower(n)) catch {};
        names = ns.items;
    };
    for (names) |n| {
        if (v.eq(n, "rss") and S.disabled.contains("rss")) continue;
        if (S.formats.get(n)) |f| out.append(sys.A, f) catch {} else warn("unknown output format \"{s}\"", .{n});
    }
    return out.items;
}

fn titleOfTerm(name: []const u8) []const u8 {
    if (S.cfg.boolean("capitalizeListTitles", true)) return funcs.titleCase(name);
    return name;
}

fn assemble() anyerror!void {
    // drop pages that should not be built
    var kept: std.ArrayList(*Page) = .empty;
    for (S.pages.items) |p| {
        if (p.kind == .page and !shouldBuild(p)) continue;
        if (p.kind == .section and p.file != null and !shouldBuild(p)) continue;
        try kept.append(sys.A, p);
    }
    S.pages = kept;
    for (S.pages.items) |p| {
        var ch: std.ArrayList(*Page) = .empty;
        for (p.children.items) |c| {
            var alive = false;
            for (S.pages.items) |q| if (q == c) {
                alive = true;
                break;
            };
            if (alive) try ch.append(sys.A, c);
        }
        p.children = ch;
    }
    for (S.pages.items) |p| p.section = sectionOf(p);

    // taxonomies
    var tax_cfg = S.cfg.map("taxonomies");
    if (tax_cfg == null and S.cfg.getCI("taxonomies") == null) {
        const d = v.newMap();
        d.put("category", v.S("categories"));
        d.put("tag", v.S("tags"));
        tax_cfg = d;
    }
    if (tax_cfg) |tc| {
        for (tc.m.keys(), tc.m.values()) |singular, pv| {
            const plural = v.rawStr(pv) orelse continue;
            const t = try sys.A.create(Taxonomy);
            t.* = .{ .singular = singular, .plural = plural };
            try S.taxonomies.put(sys.A, plural, t);
        }
    }
    const page_snapshot = try sys.A.dupe(*Page, S.pages.items);
    for (S.taxonomies.values()) |t| {
        const tpath = v.concat(&.{ "/", urlize(t.plural) });
        // existing content/<plural>/_index.md becomes the taxonomy page
        for (page_snapshot) |p| {
            if (p.kind == .section and v.eq(p.path, tpath)) {
                p.kind = .taxonomy;
                p.tax = t;
                t.page = p;
            } else if (p.kind == .section and v.startsWith(p.path, tpath) and p.path.len > tpath.len and p.path[tpath.len] == '/') {
                p.kind = .term;
                p.tax = t;
            }
        }
        for (page_snapshot) |p| {
            if (p.kind == .taxonomy or p.kind == .term) continue;
            const tv = p.fm.getCI(t.plural) orelse continue;
            var names: std.ArrayList([]const u8) = .empty;
            switch (tv) {
                .list => |l| for (l.items.items) |x| {
                    const sx = v.toStr(x);
                    if (sx.len > 0) try names.append(sys.A, sx);
                },
                .str => |sx| if (sx.len > 0) try names.append(sys.A, sx),
                else => {},
            }
            for (names.items) |name| {
                const key = urlize(name);
                if (key.len == 0) continue;
                const term = t.terms.get(key) orelse blk: {
                    const nt = try sys.A.create(Term);
                    nt.* = .{ .name = name, .key = key, .tax = t };
                    try t.terms.put(sys.A, key, nt);
                    break :blk nt;
                };
                var dupe = false;
                for (term.pages.items) |q| if (q == p) {
                    dupe = true;
                };
                if (!dupe) try term.pages.append(sys.A, p);
            }
        }
        if (t.page == null) {
            const tp = newPage();
            tp.kind = .taxonomy;
            tp.bundle = .branch;
            tp.path = tpath;
            tp.title = titleOfTerm(t.plural);
            tp.tax = t;
            tp.parent = S.home;
            t.page = tp;
            if (S.disabled.contains("taxonomy")) {
                tp.render = false;
                tp.list = false;
            }
            try S.pages.append(sys.A, tp);
        } else {
            // detach from home's section children
            removeChild(S.home, t.page.?);
        }
        t.page.?.section = t.plural;
        // term pages
        for (page_snapshot) |p| if (p.kind == .term and p.tax == t) {
            const key = v.pathBase(p.path);
            const term = t.terms.get(key) orelse blk: {
                const nt = try sys.A.create(Term);
                nt.* = .{ .name = if (p.title.len > 0) p.title else key, .key = key, .tax = t };
                try t.terms.put(sys.A, key, nt);
                break :blk nt;
            };
            term.page = p;
            p.term = term;
            p.section = t.plural;
            if (p.parent) |par| removeChild(par, p);
            p.parent = t.page;
        };
        if (!S.disabled.contains("term")) for (t.terms.values()) |term| {
            sortPages(term.pages.items);
            if (term.page == null) {
                const pp = newPage();
                pp.kind = .term;
                pp.bundle = .branch;
                pp.path = v.concat(&.{ tpath, "/", term.key });
                pp.title = titleOfTerm(term.name);
                pp.tax = t;
                pp.term = term;
                pp.parent = t.page;
                pp.section = t.plural;
                term.page = pp;
                try S.pages.append(sys.A, pp);
            }
            if (term.page.?.title.len == 0) term.page.?.title = titleOfTerm(term.name);
            // term page dates follow newest member
            const tp = term.page.?;
            for (term.pages.items) |m| {
                if (tp.date.zero or m.date.sec > tp.date.sec) tp.date = m.date;
                if (tp.publish.zero or m.publish.sec > tp.publish.sec) tp.publish = m.publish;
                if (tp.lastmod.zero or m.lastmod.sec > tp.lastmod.sec) tp.lastmod = m.lastmod;
            }
            if (t.page.?.date.zero or tp.date.sec > t.page.?.date.sec) {
                t.page.?.date = tp.date;
                t.page.?.publish = tp.publish;
            }
            if (t.page.?.lastmod.zero or tp.lastmod.sec > t.page.?.lastmod.sec) t.page.?.lastmod = tp.lastmod;
        };
        // sort terms alphabetically by key
        const Ctx = struct {
            keys: [][]const u8,
            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, c.keys[a], c.keys[b]) == .lt;
            }
        };
        t.terms.sort(Ctx{ .keys = t.terms.keys() });
    }

    // urls, outputs, sorting, indexes
    for (S.pages.items) |p| {
        computeUrl(p);
        p.outputs = defaultOutputs(p.kind);
        if (p.fm.list("outputs")) |l| {
            var outs: std.ArrayList(*const OutputFormat) = .empty;
            for (l.items.items) |x| if (v.rawStr(x)) |n| {
                if (S.formats.get(v.lower(n))) |f| try outs.append(sys.A, f);
            };
            p.outputs = outs.items;
        }
        try S.by_path.put(sys.A, p.path, p);
        if (p.kind == .page and p.list) try S.regular.append(sys.A, p);
    }
    // branch nodes whose own dates are all zero take the newest dates of their
    // descendants (Hugo's "dates" event bubbling in the page assembler)
    {
        var i = S.pages.items.len;
        while (i > 0) : (i -= 1) {
            const p = S.pages.items[i - 1];
            if (p.kind != .home and p.kind != .section) continue;
            p.dates_zero = p.date.zero and p.lastmod.zero and p.publish.zero and p.expiry.zero;
        }
        for (S.pages.items) |p| {
            if ((p.kind == .home or p.kind == .section) and p.parent == null) aggregateDates(p);
        }
    }
    for (S.pages.items) |p| sortPages(p.children.items);
    sortPages(S.regular.items);
    sortPages(S.pages.items);
    // prev/next (site-wide over regular pages; in-section over siblings)
    for (S.regular.items, 0..) |p, idx| {
        if (idx > 0) p.next = S.regular.items[idx - 1];
        if (idx + 1 < S.regular.items.len) p.prev = S.regular.items[idx + 1];
    }
    for (S.pages.items) |p| {
        var reg: std.ArrayList(*Page) = .empty;
        for (p.children.items) |c| if (c.kind == .page and c.list) try reg.append(sys.A, c);
        for (reg.items, 0..) |c, idx| {
            if (idx > 0) c.next_in_section = reg.items[idx - 1];
            if (idx + 1 < reg.items.len) c.prev_in_section = reg.items[idx + 1];
        }
    }
    try buildMenus();
}

fn removeChild(parent: *Page, child: *Page) void {
    for (parent.children.items, 0..) |c, idx| if (c == child) {
        _ = parent.children.orderedRemove(idx);
        return;
    };
}

// ------------------------------------------------------------------ menus

fn menuEntryLess(_: void, a: Value, b: Value) bool {
    const wa = a.map.int("Weight", 0);
    const wb = b.map.int("Weight", 0);
    if (wa != wb) {
        if (wa == 0) return false;
        if (wb == 0) return true;
        return wa < wb;
    }
    return std.ascii.orderIgnoreCase(a.map.str("Name") orelse "", b.map.str("Name") orelse "") == .lt;
}

fn newMenuEntry(menu: []const u8, src: ?*Map, page: ?*Page) *Map {
    const e = v.newMap();
    e.put("Menu", v.S(menu));
    var name: []const u8 = "";
    var url: []const u8 = "";
    var pg = page;
    if (src) |m| {
        name = m.str("name") orelse "";
        url = m.str("url") orelse "";
        if (m.str("pageRef")) |pr| {
            e.put("PageRef", v.S(pr));
            if (pg == null) pg = getPage(pr, null);
        }
        e.put("Weight", v.I(m.int("weight", 0)));
        e.put("Identifier", v.S(m.str("identifier") orelse ""));
        e.put("Parent", v.S(m.str("parent") orelse ""));
        e.put("Pre", v.H(m.str("pre") orelse ""));
        e.put("Post", v.H(m.str("post") orelse ""));
        e.put("Title", v.S(m.str("title") orelse ""));
        e.put("Params", if (m.map("params")) |pm| data.lowerKeys(v.M(pm)) else v.M(v.newMap()));
    } else {
        e.put("Weight", v.I(0));
        e.put("Identifier", v.S(""));
        e.put("Parent", v.S(""));
        e.put("Pre", v.H(""));
        e.put("Post", v.H(""));
        e.put("Title", v.S(""));
        e.put("Params", v.M(v.newMap()));
    }
    if (pg) |p| {
        e.put("Page", p.val());
        if (name.len == 0) name = objs.linkTitle(p);
        if (url.len == 0) url = v.concat(&.{ S.base_path, p.url });
        if (e.strOr("Title", "").len == 0) e.put("Title", v.S(objs.linkTitle(p)));
        if (e.int("Weight", 0) == 0 and src == null) e.put("Weight", v.I(p.weight));
    } else {
        e.put("Page", .nil);
        if (v.startsWith(url, "/") and !v.startsWith(url, "//")) url = v.concat(&.{ S.base_path, url });
    }
    e.put("Name", v.S(name));
    e.put("URL", v.S(url));
    if (e.strOr("Identifier", "").len == 0) e.put("KeyName", v.S(name)) else e.put("KeyName", v.S(e.str("Identifier").?));
    e.put("Children", v.L(v.newList()));
    e.put("HasChildren", v.B(false));
    e.put("__menu_entry", v.B(true));
    return e;
}

fn buildMenus() anyerror!void {
    var flat: std.StringArrayHashMapUnmanaged(*v.List) = .empty;
    const Add = struct {
        fn f(fl: *std.StringArrayHashMapUnmanaged(*v.List), menu: []const u8, e: *Map) void {
            const l = fl.get(menu) orelse blk: {
                const n = v.newList();
                fl.put(sys.A, menu, n) catch {};
                break :blk n;
            };
            v.push(l, v.M(e));
        }
    };
    if (S.cfg.map("menus") orelse S.cfg.map("menu")) |mm| {
        for (mm.m.keys(), mm.m.values()) |menu, entries| {
            if (entries != .list) continue;
            for (entries.list.items.items) |ev| if (ev == .map) Add.f(&flat, menu, newMenuEntry(menu, ev.map, null));
        }
    }
    for (S.pages.items) |p| {
        const mv = p.fm.getCI("menus") orelse p.fm.getCI("menu") orelse continue;
        switch (mv) {
            .str => |name| Add.f(&flat, name, newMenuEntry(name, null, p)),
            .list => |l| for (l.items.items) |x| if (v.rawStr(x)) |name| Add.f(&flat, name, newMenuEntry(name, null, p)),
            .map => |m| for (m.m.keys(), m.m.values()) |name, ev| {
                Add.f(&flat, name, newMenuEntry(name, if (ev == .map) ev.map else null, p));
            },
            else => {},
        }
    }
    if (S.cfg.str("sectionPagesMenu")) |menu| {
        for (S.home.children.items) |c| if (c.kind == .section) Add.f(&flat, menu, newMenuEntry(menu, null, c));
    }
    for (flat.keys(), flat.values()) |menu, entries| {
        const top = v.newList();
        for (entries.items.items) |ev| {
            const parent = ev.map.str("Parent") orelse "";
            if (parent.len == 0) {
                v.push(top, ev);
                continue;
            }
            var placed = false;
            for (entries.items.items) |pv| {
                if (pv.map == ev.map) continue;
                const id = pv.map.str("Identifier") orelse "";
                if (v.eq(if (id.len > 0) id else pv.map.str("Name") orelse "", parent)) {
                    v.push(pv.map.list("Children").?, ev);
                    pv.map.put("HasChildren", v.B(true));
                    placed = true;
                    break;
                }
            }
            if (!placed) v.push(top, ev);
        }
        std.mem.sort(Value, top.items.items, {}, menuEntryLess);
        for (entries.items.items) |ev| std.mem.sort(Value, ev.map.list("Children").?.items.items, {}, menuEntryLess);
        S.menus.put(menu, v.L(top));
    }
}

// ------------------------------------------------------------------ lookups

pub fn getPage(ref_in: []const u8, from: ?*Page) ?*Page {
    var ref = ref_in;
    if (v.indexOfChar(ref, '#')) |h| ref = ref[0..h];
    if (ref.len == 0) return from;
    // strip content extensions and index names
    for ([_][]const u8{ ".md", ".markdown", ".html" }) |ext| if (v.endsWith(ref, ext)) {
        ref = ref[0 .. ref.len - ext.len];
        break;
    };
    if (v.endsWith(ref, "/_index") or v.endsWith(ref, "/index")) ref = v.pathDir(ref);
    if (v.eq(ref, "_index") or v.eq(ref, "index")) ref = if (from) |f| (if (f.isNode() or f.bundle == .leaf) f.path else v.pathDir(f.path)) else "/";
    const lref = urlize(ref);
    if (v.startsWith(lref, "/")) {
        const cl = v.pathClean(lref);
        if (S.by_path.get(cl)) |p| return p;
    } else {
        if (from) |f| {
            const base = if (f.isNode() or f.bundle == .leaf) f.path else v.pathDir(f.path);
            const rel = v.pathClean(v.pathJoin(&.{ base, lref }));
            if (S.by_path.get(rel)) |p| return p;
            if (f.bundle == .leaf) {
                if (S.by_path.get(v.pathClean(v.pathJoin(&.{ v.pathDir(f.path), lref })))) |p| return p;
            }
        }
        if (S.by_path.get(v.pathClean(v.concat(&.{ "/", lref })))) |p| return p;
        // unique base-name match anywhere
        var hit: ?*Page = null;
        for (S.pages.items) |p| {
            if (v.endsWith(p.path, lref) and p.path.len > lref.len and p.path[p.path.len - lref.len - 1] == '/') {
                if (hit != null) return hit;
                hit = p;
            }
        }
        return hit;
    }
    return null;
}

// ------------------------------------------------------------------ layout lookup

fn tryNames(dir: []const u8, names: []const []const u8, f: *const OutputFormat) ?[]const u8 {
    for (names) |n| {
        if (n.len == 0) continue;
        const cands = [_][]const u8{
            v.fmt("{s}.{s}.{s}", .{ n, f.name, f.suffix }),
            v.fmt("{s}.{s}.{s}.{s}", .{ n, S.lang, f.name, f.suffix }),
            v.fmt("{s}.{s}", .{ n, f.suffix }),
        };
        for (cands, 0..) |c, ci| {
            // a bare "name.suffix" only applies to non-HTML formats when the suffix is unique to it
            if (ci == 2 and !f.is_html and (v.eq(f.suffix, "html"))) continue;
            const rel = if (dir.len == 0) c else v.concat(&.{ dir, "/", c });
            if (S.layouts.contains(rel)) return rel;
        }
    }
    return null;
}

fn layoutDirs(p: *Page) [][]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(d: *std.ArrayList([]const u8), s: []const u8) void {
            for (d.items) |x| if (v.eq(x, s)) return;
            d.append(sys.A, s) catch {};
        }
    }.f;
    if (p.param("type")) |t| add(&dirs, t);
    if (p.kind == .taxonomy or p.kind == .term) {
        if (p.tax) |t| {
            add(&dirs, t.plural);
            add(&dirs, t.singular);
        }
        add(&dirs, "taxonomy");
    }
    // page path directories, deepest first
    var path = if (p.kind == .page) v.pathDir(p.path) else p.path;
    while (path.len > 1) : (path = v.pathDir(path)) add(&dirs, path[1..]);
    if (p.section.len > 0) add(&dirs, p.section);
    add(&dirs, "");
    add(&dirs, "_default");
    return dirs.items;
}

pub fn findLayout(p: *Page, f: *const OutputFormat) ?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (p.param("layout")) |l| names.append(sys.A, l) catch {};
    const legacy_tax = S.layouts.contains("_default/terms.html") and S.layouts.contains("_default/taxonomy.html");
    const kind_names: []const []const u8 = switch (p.kind) {
        .page => &.{ "page", "single" },
        .home => &.{ "home", "index", "list" },
        .section => &.{ "section", "list" },
        // legacy themes ship _default/terms.html (taxonomy) next to _default/taxonomy.html (term)
        .taxonomy => if (legacy_tax) &.{ "terms", "taxonomy", "list" } else &.{ "taxonomy", "terms", "list" },
        .term => if (legacy_tax) &.{ "term", "taxonomy", "list" } else &.{ "term", "list" },
    };
    if (v.eq(f.name, "rss")) names.append(sys.A, "rss") catch {};
    names.appendSlice(sys.A, kind_names) catch {};
    names.append(sys.A, "all") catch {};
    for (layoutDirs(p)) |d| {
        if (v.eq(d, "taxonomy")) if (p.tax) |t| {
            // legacy: taxonomy/tag.html (term), taxonomy/tag.terms.html (taxonomy)
            const legacy = if (p.kind == .term) t.singular else v.concat(&.{ t.singular, ".terms" });
            if (tryNames(d, &.{legacy}, f)) |r| return r;
        };
        // home must not pick up a section's templates and vice versa via "list" in type dirs
        if (tryNames(d, names.items, f)) |r| return r;
    }
    return null;
}

pub fn findBaseof(p: *Page, f: *const OutputFormat) ?[]const u8 {
    const kind_names: []const []const u8 = switch (p.kind) {
        .page => &.{ "single-baseof", "baseof" },
        .home => &.{ "index-baseof", "list-baseof", "baseof" },
        else => &.{ "list-baseof", "baseof" },
    };
    for (layoutDirs(p)) |d| if (tryNames(d, kind_names, f)) |r| return r;
    return null;
}
