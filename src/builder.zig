// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Build pipeline: render every page in every output format and publish files.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const tmpl = @import("tmpl.zig");
const site = @import("site.zig");
const objs = @import("objs.zig");
const embedded = @import("embedded.zig");
const Value = v.Value;
const Page = site.Page;

fn destFor(url: []const u8) []const u8 {
    const rel = if (v.endsWith(url, "/")) v.concat(&.{ url, "index.html" }) else url;
    return v.pathJoin(&.{ site.S.dest, rel });
}

fn minifyOutput() bool {
    if (site.S.opt.minify) return true;
    if (site.S.cfg.map("minify")) |m| return m.boolean("minifyOutput", false);
    return false;
}

fn write(url: []const u8, content_in: []const u8) void {
    const d = destFor(url);
    var content = content_in;
    if (minifyOutput()) {
        const ext = v.lower(v.pathExt(d));
        const mt: []const u8 = if (v.eq(ext, ".html") or v.eq(ext, ".htm")) "text/html" else if (v.eq(ext, ".xml")) "text/xml" else if (v.eq(ext, ".json")) "application/json" else if (v.eq(ext, ".css")) "text/css" else if (v.eq(ext, ".js")) "text/javascript" else if (v.eq(ext, ".svg")) "image/svg+xml" else "";
        if (mt.len > 0) if (@import("min.zig").minifyByMime(mt, content)) |m| {
            content = m;
        };
    }
    site.S.written.put(sys.A, d, {}) catch {};
    if (std.mem.indexOf(u8, content, tmpl.deferred_prefix) != null) {
        pending.append(sys.A, .{ .dest = d, .content = content }) catch {};
        return;
    }
    sys.writeFile(d, content) catch |e| site.errorf("failed to write {s}: {s}", .{ d, @errorName(e) });
}

/// Outputs waiting for templates.Defer blocks.
var pending: std.ArrayList(struct { dest: []const u8, content: []const u8 }) = .empty;

fn flushDeferred() anyerror!void {
    for (pending.items) |pf| {
        var out: std.ArrayList(u8) = .empty;
        var rest = pf.content;
        while (std.mem.indexOf(u8, rest, tmpl.deferred_prefix)) |i| {
            try out.appendSlice(sys.A, rest[0..i]);
            const after = rest[i + tmpl.deferred_prefix.len ..];
            var j: usize = 0;
            while (j < after.len and after[j] >= '0' and after[j] <= '9') j += 1;
            if (j == 0 or !std.mem.startsWith(u8, after[j..], "__")) {
                try out.appendSlice(sys.A, tmpl.deferred_prefix);
                rest = after;
                continue;
            }
            const idx = std.fmt.parseInt(usize, after[0..j], 10) catch 0;
            if (idx < tmpl.deferred.items.len) {
                if (tmpl.runDeferred(idx)) |o| try out.appendSlice(sys.A, o) else |e| try reportErr(e, "deferred template");
            }
            rest = after[j + 2 ..];
        }
        try out.appendSlice(sys.A, rest);
        sys.writeFile(pf.dest, out.items) catch |e| site.errorf("failed to write {s}: {s}", .{ pf.dest, @errorName(e) });
    }
    pending.items.len = 0;
}

fn reportErr(e: anyerror, what: []const u8) anyerror!void {
    switch (e) {
        error.TemplateError => site.errorf("render of {s} failed: {s}", .{ what, tmpl.err_msg }),
        error.Fatal => site.errorf("{s}: {s}", .{ what, site.fatal_msg }),
        error.TmplBreak, error.TmplContinue => site.errorf("render of {s} failed: break/continue outside range", .{what}),
        else => return e,
    }
}

fn renderOne(p: *Page, f: *const site.OutputFormat, t: *tmpl.Template, base: ?*tmpl.Template) anyerror!?[]const u8 {
    site.S.cur_format = f;
    return tmpl.render(t, base, p.val(), p.val(), f.is_plain) catch |e| {
        try reportErr(e, v.fmt("\"{s}\" ({s})", .{ p.file orelse p.path, t.name }));
        return null;
    };
}

/// Hugo makes root-relative URLs absolute in RSS output.
fn absUrls(src: []const u8) []const u8 {
    const base = std.mem.trimEnd(u8, site.S.base_url, "/");
    const host_end = if (v.indexOf(base, "://")) |p| (v.indexOfPos(base, p + 3, "/") orelse base.len) else return src;
    const host = base[0..host_end];
    var out = src;
    for ([_][]const u8{ " src=\"/", " href=\"/", " src=&#34;/", " href=&#34;/", " srcset=\"/", " srcset=&#34;/" }) |pat| {
        if (!v.contains(out, pat)) continue;
        var b: v.Buf = .{};
        var i: usize = 0;
        while (v.indexOfPos(out, i, pat)) |pos| {
            const after = pos + pat.len;
            b.add(out[i .. after - 1]);
            if (!(after < out.len and out[after] == '/')) b.add(host);
            b.ch('/');
            i = after;
        }
        b.add(out[i..]);
        out = b.str();
    }
    return out;
}

/// Hugo injects a generator tag into the home page (all its pagers) when missing.
fn injectGenerator(p: *Page, f: *const site.OutputFormat, out: []const u8) []const u8 {
    if (p.kind == .home and f.is_html and !site.S.cfg.boolean("disableHugoGeneratorInject", false) and !v.contains(out, "<meta name=\"generator\"")) {
        if (v.indexOf(out, "</head>")) |h| return v.concat(&.{ out[0..h], "\t<meta name=\"generator\" content=\"ZSSG ", site.version, "\">\n", out[h..] });
    }
    return out;
}

fn renderPage(p: *Page, f: *const site.OutputFormat) anyerror!void {
    var t: ?*tmpl.Template = null;
    var base: ?*tmpl.Template = null;
    if (site.findLayout(p, f)) |rel| {
        t = try site.getTemplate(rel);
        if (t.?.only_defines) {
            if (site.findBaseof(p, f)) |brel| base = try site.getTemplate(brel);
        }
    } else if (v.eq(f.name, "rss")) {
        t = embedded.template("rss.xml", embedded.rss);
    }
    const tp = t orelse {
        if (f.is_html) site.warn("found no layout file for \"{s}\" for kind \"{s}\": You should create a template file which matches Hugo Layouts Lookup Rules for this combination.", .{ f.name, @tagName(p.kind) });
        return;
    };
    if (sys.getenv("ZSSG_DEBUG") != null) sys.eprint("DEBUG {s} [{s}] -> {s}{s}{s}\n", .{ p.path, f.name, tp.name, if (base != null) " + " else "", if (base) |b| b.name else "" });
    const url = objs.outUrl(p, f);
    var out = (try renderOne(p, f, tp, base)) orelse return;
    if (v.eq(f.name, "rss")) out = absUrls(out);
    out = injectGenerator(p, f, out);
    write(url, out);
    site.S.n_pages += 1;
    if (f.is_html and p.pagers.len > 0) {
        var n: usize = 1;
        while (n < p.pagers.len) : (n += 1) {
            p.cur_pager = n;
            const po = (try renderOne(p, f, tp, base)) orelse break;
            write(objs.pagerUrl(p.pagers[n]), injectGenerator(p, f, po));
        }
        p.cur_pager = 0;
        // /page/1/ redirects to the first page
        const first = v.fmt("{s}{s}/1/", .{ p.url, objs.pagerPath() });
        try writeAlias(first, p);
    }
}

fn writeAlias(alias_url: []const u8, p: *Page) anyerror!void {
    const t = embedded.template("alias.html", embedded.alias) orelse return;
    const out = tmpl.render(t, null, p.val(), p.val(), false) catch |e| return reportErr(e, "alias");
    write(alias_url, out);
}

fn copyStatic() void {
    const s = site.S;
    var dirs: std.ArrayList([]const u8) = .empty;
    if (s.cfg.getCI("staticDir")) |sd| switch (sd) {
        .str => |x| dirs.append(sys.A, x) catch {},
        .list => |l| for (l.items.items) |x| dirs.append(sys.A, v.toStr(x)) catch {},
        else => {},
    };
    if (dirs.items.len == 0) dirs.append(sys.A, "static") catch {};
    // themes first so that the project overrides them
    var i = s.components.len;
    while (i > 0) : (i -= 1) {
        for (dirs.items) |d| {
            const base = v.pathJoin(&.{ s.components[i - 1], d });
            for (sys.walk(base)) |rel| {
                const dest = v.pathJoin(&.{ s.dest, rel });
                sys.copyFile(v.pathJoin(&.{ base, rel }), dest) catch |e| {
                    site.errorf("failed to copy static file {s}: {s}", .{ rel, @errorName(e) });
                    continue;
                };
                if (!s.written.contains(dest)) s.n_static += 1;
                s.written.put(sys.A, dest, {}) catch {};
            }
        }
    }
}

pub fn build() anyerror!void {
    const first = site.all.items[0];
    site.S = first;
    tmpl.deferred.items.len = 0;
    pending.items.len = 0;
    if (first.opt.clean) sys.removeTree(first.dest);
    sys.mkdirAll(first.dest);
    copyStatic();
    for (site.all.items) |s| {
        site.S = s;
        try buildSite(s == first);
    }
    site.S = first;
    try flushDeferred();
    if (site.isMultilingual()) {
        // sitemap index pointing at each language's sitemap
        if (!first.disabled.contains("sitemap")) {
            const l = v.newList();
            for (site.all.items) |s| {
                const m = v.newMap();
                m.put("SitemapAbsURL", v.S(objs.absUrl(v.concat(&.{ "/", s.lang, "/sitemap.xml" }))));
                var t: v.Time = @import("time.zig").zero;
                for (s.pages.items) |p| if (!p.lastmod.zero and (t.zero or p.lastmod.sec > t.sec)) {
                    t = p.lastmod;
                };
                m.put("Lastmod", .{ .time = t });
                v.push(l, v.M(m));
            }
            if (embedded.template("sitemapindex.xml", embedded.sitemapindex)) |t| {
                if (tmpl.render(t, null, v.L(l), first.home.val(), false)) |out| {
                    write("/sitemap.xml", out);
                    first.n_pages += 1;
                } else |e| try reportErr(e, "sitemap index");
            }
        }
        // the default language is reachable both at / and /<lang>/ (one redirects to the other)
        for (site.all.items) |s| if (v.eq(s.lang, s.default_lang)) {
            site.S = s;
            try writeAlias(if (s.lang_prefix.len > 0) "/" else v.concat(&.{ "/", s.lang, "/" }), s.home);
        };
        site.S = first;
    }
    // queued image operations: wait, publish, report their errors
    @import("imgops.zig").joinAll();
}

fn buildSite(is_first: bool) anyerror!void {
    const s = site.S;

    // render in tree order (home first), like Hugo's page tree walk
    const order = try sys.A.dupe(*Page, s.pages.items);
    const ByPath = struct {
        fn less(_: void, a: *Page, b: *Page) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    };
    std.mem.sort(*Page, order, {}, ByPath.less);
    // Render all content first: render hooks may record cross-page state
    // (e.g. backlinks in .Store) that other pages' templates read.
    // Hugo renders content lazily; in practice the home page comes first and the rest
    // follows the default page order (themes commonly range over .Site.Pages early).
    const corder = try sys.A.dupe(*Page, s.pages.items);
    site.sortPages(corder);
    if (s.home.render and s.home.raw.len > 0) objs.renderContent(s.home) catch {};
    for (corder) |p| {
        if (!p.render or p.raw.len == 0 or p == s.home) continue;
        objs.renderContent(p) catch {};
    }
    for (order) |p| {
        if (!p.render) continue;
        for (p.outputs) |f| try renderPage(p, f);
    }

    // aliases
    for (s.pages.items) |p| {
        if (!p.render) continue;
        const al = p.fm.getCI("aliases") orelse continue;
        var list: std.ArrayList([]const u8) = .empty;
        switch (al) {
            .list => |l| for (l.items.items) |x| try list.append(sys.A, v.toStr(x)),
            .str => |x| try list.append(sys.A, x),
            else => {},
        }
        for (list.items) |a| {
            var u = if (v.startsWith(a, "/")) a else v.concat(&.{ v.pathDir(std.mem.trimEnd(u8, p.url, "/")), "/", a });
            if (!v.endsWith(u, "/") and v.pathExt(u).len == 0) u = v.concat(&.{ u, "/" });
            try writeAlias(v.concat(&.{ s.lang_prefix, site.urlize(u) }), p);
            s.n_aliases += 1;
        }
    }

    // page bundle resources
    for (s.pages.items) |p| {
        if (!p.publish_res or p.resources.items.len == 0) continue;
        const rl = try objs.pageField(null, p, "Resources", &.{});
        for (rl.list.items.items) |rv| if (objs.asRes(rv)) |r| objs.publish(r);
    }

    // sitemap
    if (!s.disabled.contains("sitemap")) {
        const ctx = v.newMap();
        var pages: std.ArrayList(*Page) = .empty;
        for (s.pages.items) |p| if (p.render) try pages.append(sys.A, p);
        ctx.put("Pages", objs.pagesVal(pages.items));
        ctx.put("Site", s.val());
        var t: ?*tmpl.Template = null;
        for ([_][]const u8{ "sitemap.xml", "_default/sitemap.xml" }) |n| {
            if (try site.getTemplate(n)) |x| {
                t = x;
                break;
            }
        }
        if (t == null) t = embedded.template("sitemap.xml", embedded.sitemap);
        if (t) |tp| {
            if (tmpl.render(tp, null, v.M(ctx), s.home.val(), false)) |out| {
                write(v.concat(&.{ if (site.isMultilingual()) v.concat(&.{ "/", s.lang }) else "", "/sitemap.xml" }), out);
                s.n_pages += 1;
            } else |e| try reportErr(e, "sitemap.xml");
        }
    }

    // robots.txt
    if (is_first and s.cfg.boolean("enableRobotsTXT", false)) {
        var out: []const u8 = embedded.robots;
        for ([_][]const u8{ "robots.txt", "_default/robots.txt" }) |n| {
            if (try site.getTemplate(n)) |t| {
                if (tmpl.render(t, null, s.home.val(), s.home.val(), true)) |o| {
                    out = o;
                } else |e| try reportErr(e, "robots.txt");
                break;
            }
        }
        write("/robots.txt", out);
        s.n_pages += 1;
    }

    // 404
    if (!s.disabled.contains("404")) {
        if (try site.getTemplate("404.html")) |t| {
            const p = site.page404(s);
            var base: ?*tmpl.Template = null;
            if (t.only_defines) if (site.findBaseof(p, &site.builtin_formats[0])) |b| {
                base = try site.getTemplate(b);
            };
            s.cur_format = &site.builtin_formats[0];
            if (tmpl.render(t, base, p.val(), p.val(), false)) |out| {
                write(p.url, out);
                s.n_pages += 1;
            } else |e| try reportErr(e, "404.html");
        }
    }
}
