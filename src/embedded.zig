// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Templates that ship inside the binary. These are Hugo's own embedded
//! templates (Apache-2.0, see src/embedded/README.md) so output matches Hugo.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const tmpl = @import("tmpl.zig");

var cache: std.StringHashMapUnmanaged(*tmpl.Template) = .empty;

fn get(name: []const u8, src: []const u8) ?*tmpl.Template {
    if (cache.get(name)) |t| return t;
    const t = tmpl.parse(v.concat(&.{ "_embedded/", name }), src) catch {
        sys.eprint("internal error: embedded template {s}: {s}\n", .{ name, tmpl.err_msg });
        return null;
    };
    cache.put(sys.A, name, t) catch {};
    return t;
}

pub const rss = @embedFile("embedded/rss.xml");
pub const sitemap = @embedFile("embedded/sitemap.xml");
pub const alias = @embedFile("embedded/alias.html");
pub const robots = @embedFile("embedded/robots.txt");
pub const sitemapindex = @embedFile("embedded/sitemapindex.xml");

const partials = [_][2][]const u8{
    .{ "opengraph.html", @embedFile("embedded/_partials/opengraph.html") },
    .{ "twitter_cards.html", @embedFile("embedded/_partials/twitter_cards.html") },
    .{ "schema.html", @embedFile("embedded/_partials/schema.html") },
    .{ "google_analytics.html", @embedFile("embedded/_partials/google_analytics.html") },
    .{ "disqus.html", @embedFile("embedded/_partials/disqus.html") },
    .{ "pagination.html", @embedFile("embedded/_partials/pagination.html") },
    .{ "_funcs/get-page-images.html", @embedFile("embedded/_partials/_funcs/get-page-images.html") },
};

const shortcodes = [_][2][]const u8{
    .{ "figure", @embedFile("embedded/_shortcodes/figure.html") },
    .{ "youtube", @embedFile("embedded/_shortcodes/youtube.html") },
    .{ "vimeo", @embedFile("embedded/_shortcodes/vimeo.html") },
    .{ "details", @embedFile("embedded/_shortcodes/details.html") },
    .{ "param", @embedFile("embedded/_shortcodes/param.html") },
    .{ "gist", @embedFile("embedded/_shortcodes/gist.html") },
    .{ "comment", @embedFile("embedded/_shortcodes/comment.html") },
};

pub fn partial(name: []const u8) ?*tmpl.Template {
    for (partials) |e| if (v.eq(e[0], name)) return get(v.concat(&.{ "_partials/", name }), e[1]);
    return null;
}

pub fn shortcode(name: []const u8) ?*tmpl.Template {
    for (shortcodes) |e| if (v.eq(e[0], name)) return get(v.concat(&.{ "_shortcodes/", name, ".html" }), e[1]);
    return null;
}

pub fn template(name: []const u8, src: []const u8) ?*tmpl.Template {
    return get(name, src);
}
