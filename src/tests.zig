// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
//! Unit tests for the self-contained parts of ZSSG. Run with `zig build test`.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const data = @import("data.zig");
const tm = @import("time.zig");
const regex = @import("regex.zig");
const md = @import("markdown.zig");
const tmpl = @import("tmpl.zig");
const hl = @import("highlight.zig");

var arena: std.heap.ArenaAllocator = undefined;
var ready = false;

fn setup() void {
    if (ready) return;
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    sys.A = arena.allocator();
    v.timeToStr = &tm.toString;
    ready = true;
}

fn expectStr(want: []const u8, got: []const u8) !void {
    try std.testing.expectEqualStrings(want, got);
}

fn render(src: []const u8, dot: v.Value) ![]const u8 {
    const t = try tmpl.parse("test", src);
    return tmpl.render(t, null, dot, .nil, false);
}

test "toml" {
    setup();
    const m = try data.parseToml(
        \\title = "Site" # comment
        \\n = 1_000
        \\when = 2024-03-01T10:00:00+02:00
        \\[params]
        \\a.b = [1, 2,
        \\  3]
        \\[[menus.main]]
        \\name = 'Home'
        \\[[menus.main]]
        \\name = "About"
    );
    try expectStr("Site", m.str("title").?);
    try std.testing.expectEqual(@as(i64, 1000), m.int("n", 0));
    try std.testing.expect(m.get("when").? == .time);
    try std.testing.expectEqual(@as(usize, 3), m.map("params").?.map("a").?.list("b").?.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), m.map("menus").?.list("main").?.items.items.len);
}

test "yaml" {
    setup();
    const val = try data.parseYaml(
        \\title: "Hello: world"  # comment
        \\tags: [a, "b c"]
        \\draft: false
        \\desc: >-
        \\  folded
        \\  text
        \\menu:
        \\  main:
        \\    - name: Home
        \\      weight: 1
        \\list:
        \\- x
        \\- y
    );
    const m = val.map;
    try expectStr("Hello: world", m.str("title").?);
    try expectStr("b c", v.toStr(m.list("tags").?.items.items[1]));
    try std.testing.expect(!m.boolean("draft", true));
    try expectStr("folded text", m.str("desc").?);
    try std.testing.expectEqual(@as(i64, 1), m.map("menu").?.list("main").?.items.items[0].map.int("weight", 0));
    try std.testing.expectEqual(@as(usize, 2), m.list("list").?.items.items.len);
}

test "json and xml" {
    setup();
    const j = try data.parseJson("{\"a\": [1, 2.5, \"x\\u00e9\"], \"b\": {\"c\": null, \"d\": true}}");
    try expectStr("x\u{e9}", v.toStr(j.map.list("a").?.items.items[2]));
    var b: v.Buf = .{};
    data.toJson(&b, j, .{}, 0);
    try expectStr("{\"a\":[1,2.5,\"x\u{e9}\"],\"b\":{\"c\":null,\"d\":true}}", b.str());
    const x = try data.parseXml("<svg viewBox=\"0 0 1 1\"><path d=\"M0\"/><t>hi</t></svg>");
    try expectStr("0 0 1 1", x.map.str("-viewBox").?);
    try expectStr("M0", x.map.map("path").?.str("-d").?);
    try expectStr("hi", x.map.str("t").?);
}

test "time formatting" {
    setup();
    const t = tm.parse("2024-03-05T14:07:09+02:00").?;
    try expectStr("Tuesday, March 5, 2024", tm.format(t, "Monday, January 2, 2006"));
    try expectStr("05 Mar 24 2:07PM +0200", tm.format(t, "02 Jan 06 3:04PM -0700"));
    try expectStr("2024-03-05T14:07:09+02:00", tm.format(t, "2006-01-02T15:04:05Z07:00"));
    try std.testing.expectEqual(@as(u16, 65), tm.civil(t).yday);
}

test "regex" {
    setup();
    const re = try regex.compile("a(.)c");
    try expectStr("[b] [d]", regex.replaceAll(re, "abc adc", "[$1]", -1));
    const d = try regex.compile("\\d+");
    try std.testing.expectEqual(@as(usize, 3), regex.findAll(d, "a1 b22 c333", -1).len);
    try std.testing.expect(regex.isMatch(try regex.compile("(?i)^hello\\b"), "HELLO world"));
    try std.testing.expect(!regex.isMatch(try regex.compile("^[a-z]+$"), "abc1"));
    const lazy = try regex.compile("<.+?>");
    const m = regex.find(lazy, "<a><b>", 0).?;
    try std.testing.expectEqual(@as(usize, 3), m.end());
}

test "markdown" {
    setup();
    try expectStr("<p>Some <strong>bold</strong> and <em>em</em> with <code>code</code>.</p>\n", md.render("Some **bold** and _em_ with `code`.", .{}).html);
    try expectStr("<h2 id=\"hello-world\">Hello World</h2>\n", md.render("## Hello World", .{}).html);
    try expectStr("<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n", md.render("- a\n- b\n", .{}).html);
    try expectStr("<p><a href=\"https://x.y\" title=\"T\">l</a></p>\n", md.render("[l](https://x.y \"T\")", .{}).html);
    try expectStr("<p>&ldquo;q&rdquo; &ndash; it&rsquo;s&hellip;</p>\n", md.render("\"q\" -- it's...", .{}).html);
    try expectStr("<!-- raw HTML omitted -->\n", md.render("<div>x</div>\n", .{}).html);
    try expectStr("<div>x</div>\n", md.render("<div>x</div>\n", .{ .unsafe = true }).html);
}

test "templates" {
    setup();
    const m = v.newMap();
    m.put("Name", v.S("Zssg & <co>"));
    m.put("Items", v.listOf(&.{ v.I(1), v.I(2), v.I(3) }));
    try expectStr("Hi Zssg &amp; &lt;co&gt;!", try render("Hi {{ .Name }}!", v.M(m)));
    try expectStr("1,2,3,", try render("{{ range .Items }}{{ . }},{{ end }}", v.M(m)));
    try expectStr("6 ABC yes", try render("{{ add 1 2 3 }} {{ upper \"abc\" }} {{ if and .Name (gt (len .Items) 2) }}yes{{ else }}no{{ end }}", v.M(m)));
    try expectStr("x-y", try render("{{- $a := \"x\" -}} {{- with \"y\" }}{{ $a }}-{{ . }}{{ end -}}", v.M(m)));
    try expectStr("[in 7]", try render("{{ define \"t\" }}[in {{ . }}]{{ end }}{{ template \"t\" 7 }}", v.M(m)));
    // contextual escaping
    try expectStr("<a href=\"/a%20b?x=1&amp;y=2\" title=\"q&#34;\">", try render("<a href=\"{{ \"/a b?x=1&y=2\" }}\" title=\"{{ \"q\\\"\" }}\">", .nil));
    try expectStr("<a href=\"#ZgotmplZ\">", try render("<a href=\"{{ \"javascript:alert(1)\" }}\">", .nil));
    try expectStr("<script>var a = \"s\"; var b =  1 ;</script>", try render("<script>var a = {{ \"s\" }}; var b = {{ 1 }};</script>", .nil));
}

test "highlight" {
    setup();
    const out = hl.block("zig", "const x = 1;\n");
    try std.testing.expect(v.contains(out, "<span style=\"color:#66d9ef\">const</span>"));
    try std.testing.expect(v.contains(out, "<span style=\"color:#ae81ff\">1</span>"));
}
