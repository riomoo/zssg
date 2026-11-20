// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors); gift (MIT, Copyright Grigory Dryapak); smartcrop (MIT, Copyright Christian Muehlhaeuser).
// The original notices and licences are kept in NOTICE and licenses/.
//! Hugo image processing for resources: Resize, Fit, Fill, Crop, Process, Filter.
//! Results are cached on disk under resources/_gen/images like Hugo does.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const image = @import("image.zig");
const webp = @import("webp.zig");
const site = @import("site.zig");
const objs = @import("objs.zig");
const tmpl = @import("tmpl.zig");
const Value = v.Value;
const Resource = site.Resource;
const Image = image.Image;

var decoded: std.AutoHashMapUnmanaged(*Resource, *Image) = .empty;

fn fail(comptime f: []const u8, args: anytype) anyerror {
    return tmpl.fail(f, args);
}

fn decodeRes(r: *Resource) anyerror!*Image {
    if (decoded.get(r)) |img| return img;
    const img = try sys.A.create(Image);
    img.* = image.decode(objs.resContent(r)) catch |e| {
        if (e == error.ImageError) return fail("image \"{s}\": {s}", .{ r.name, image.err_msg });
        return e;
    };
    try decoded.put(sys.A, r, img);
    return img;
}

const Anchor = enum { smart, center, topleft, top, topright, left, right, bottomleft, bottom, bottomright };

const Spec = struct {
    action: []const u8 = "",
    w: u32 = 0,
    h: u32 = 0,
    quality: i64 = 75,
    quality_set: bool = false,
    rotate: i64 = 0,
    filter: image.Filter = .box,
    anchor: Anchor = .smart,
    format: []const u8 = "", // "", "jpeg", "png", "webp", "gif"
    lossless: bool = false,
    lossless_set: bool = false,
    hint: []const u8 = "",
    speed: i32 = 10,
    bg: [3]u8 = .{ 255, 255, 255 },
    bg_set: bool = false,
};

/// Hugo's per-format encoding defaults (imaging.{jpeg,webp,avif}.* falling
/// back to imaging.*, then 75 for JPEG/WebP and 60 for AVIF, hint "photo",
/// compression "lossy", AVIF encoder speed 10).
fn resolveEncoding(s: *Spec, format: []const u8) void {
    const im = site.S.cfg.map("imaging");
    const fm: ?*v.Map = if (im) |m| (if (v.eq(format, "jpeg")) m.map("jpeg") else if (v.eq(format, "webp")) m.map("webp") else if (v.eq(format, "avif")) m.map("avif") else null) else null;
    if (!s.quality_set) {
        var q: i64 = 0;
        if (fm) |m| q = m.int("quality", 0);
        if (q == 0) if (im) |m| {
            q = m.int("quality", 0);
        };
        if (q == 0) q = if (v.eq(format, "avif")) 60 else 75;
        s.quality = q;
    }
    if (s.hint.len == 0) {
        if (fm) |m| if (m.str("hint")) |h| {
            s.hint = v.lower(h);
        };
        if (s.hint.len == 0) if (im) |m| if (m.str("hint")) |h| {
            s.hint = v.lower(h);
        };
        if (s.hint.len == 0) s.hint = "photo";
    }
    if (!s.lossless_set) {
        var c: []const u8 = "";
        if (fm) |m| c = m.str("compression") orelse "";
        if (c.len == 0) if (im) |m| {
            c = m.str("compression") orelse "";
        };
        s.lossless = v.eqi(c, "lossless");
    }
    if (v.eq(format, "avif")) if (fm) |m| {
        s.speed = @intCast(m.int("encoderSpeed", 10));
    };
}

fn parseHex(s_in: []const u8) ?[3]u8 {
    var s = s_in;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len == 3) {
        var out: [3]u8 = undefined;
        for (0..3) |i| {
            const d = std.fmt.parseInt(u8, s[i .. i + 1], 16) catch return null;
            out[i] = d * 17;
        }
        return out;
    }
    if (s.len < 6) return null;
    var out: [3]u8 = undefined;
    for (0..3) |i| out[i] = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch return null;
    return out;
}

fn anchorByName(n: []const u8) ?Anchor {
    return std.meta.stringToEnum(Anchor, n);
}

fn defaults() Spec {
    var s: Spec = .{};
    if (site.S.cfg.map("imaging")) |im| {
        if (im.str("resampleFilter")) |f| s.filter = image.filterByName(f) orelse .box;
        if (im.str("anchor")) |a| s.anchor = anchorByName(v.lower(a)) orelse .smart;
        if (im.str("bgColor")) |c| s.bg = parseHex(c) orelse s.bg;
    }
    return s;
}

fn parseSpec(action: []const u8, spec: []const u8) anyerror!Spec {
    var s = defaults();
    s.action = action;
    var it = std.mem.tokenizeAny(u8, spec, " \t\n");
    while (it.next()) |raw| {
        const part = v.lower(raw);
        if (v.eq(part, "resize") or v.eq(part, "fit") or v.eq(part, "fill") or v.eq(part, "crop")) {
            s.action = part;
        } else if (anchorByName(part)) |a| {
            s.anchor = a;
        } else if (image.filterByName(part)) |f| {
            s.filter = f;
        } else if (v.eq(part, "lossless")) {
            s.lossless = true;
            s.lossless_set = true;
        } else if (v.eq(part, "lossy")) {
            s.lossless = false;
            s.lossless_set = true;
        } else if (v.eq(part, "photo") or v.eq(part, "picture") or v.eq(part, "drawing") or v.eq(part, "icon") or v.eq(part, "text")) {
            s.hint = part;
        } else if (v.eq(part, "firstframeonly")) {
        } else if (v.eq(part, "jpg") or v.eq(part, "jpeg")) {
            s.format = "jpeg";
        } else if (v.eq(part, "png") or v.eq(part, "webp") or v.eq(part, "gif") or v.eq(part, "bmp") or v.eq(part, "tif") or v.eq(part, "tiff") or v.eq(part, "avif")) {
            s.format = part;
        } else if (part[0] == '#') {
            s.bg = parseHex(part) orelse return fail("invalid background colour \"{s}\"", .{part});
            s.bg_set = true;
        } else if (part[0] == 'q' and part.len > 1 and std.ascii.isDigit(part[1])) {
            s.quality = std.fmt.parseInt(i64, part[1..], 10) catch return fail("invalid quality \"{s}\"", .{part});
            if (s.quality < 1 or s.quality > 100) return fail("quality ranges from 1 to 100 inclusive", .{});
            s.quality_set = true;
        } else if (part[0] == 'r' and part.len > 1 and (std.ascii.isDigit(part[1]) or part[1] == '-')) {
            s.rotate = std.fmt.parseInt(i64, part[1..], 10) catch return fail("invalid rotation \"{s}\"", .{part});
        } else if (v.indexOfChar(part, 'x')) |xp| {
            if (xp > 0) s.w = std.fmt.parseInt(u32, part[0..xp], 10) catch return fail("invalid image dimensions \"{s}\"", .{part});
            if (xp + 1 < part.len) s.h = std.fmt.parseInt(u32, part[xp + 1 ..], 10) catch return fail("invalid image dimensions \"{s}\"", .{part});
        } else return fail("invalid image option \"{s}\"", .{part});
    }
    return s;
}

fn formatOf(r: *Resource) []const u8 {
    if (v.eq(r.media, "image/jpeg")) return "jpeg";
    if (v.eq(r.media, "image/png")) return "png";
    if (v.eq(r.media, "image/webp")) return "webp";
    if (v.eq(r.media, "image/gif")) return "gif";
    if (v.eq(r.media, "image/avif")) return "avif";
    return switch (image.sniff(objs.resContent(r))) {
        .png => "png",
        .jpeg => "jpeg",
        .webp => "webp",
        .gif => "gif",
        .avif => "avif",
        else => "",
    };
}

fn extOf(format: []const u8, orig_ext: []const u8) []const u8 {
    if (v.eq(format, "jpeg")) return if (v.eqi(orig_ext, ".jpeg")) ".jpeg" else ".jpg";
    return v.concat(&.{ ".", format });
}

fn encodeAs(img: *Image, format: []const u8, s: *const Spec) []const u8 {
    if (v.eq(format, "jpeg")) return image.encodeJpeg(img, s.quality, s.bg);
    if (v.eq(format, "webp")) return webp.encode(img, s.quality, s.lossless);
    if (v.eq(format, "avif")) {
        const hint444 = v.eq(s.hint, "drawing") or v.eq(s.hint, "icon") or v.eq(s.hint, "text");
        if (@import("avif.zig").encode(img, .{ .quality = s.quality, .lossless = s.lossless, .yuv444 = hint444, .speed = s.speed })) |b| return b;
        site.warn("AVIF encoding needs one of avifenc, Python Pillow, ImageMagick, vips or ffmpeg on the PATH; writing PNG data instead", .{});
    }
    return image.encodePng(img);
}

/// Offset of the crop window along one axis for an anchor.
fn anchorOffset(a: Anchor, free: u32, horizontal: bool) u32 {
    return switch (a) {
        .topleft => 0,
        .top => if (horizontal) free / 2 else 0,
        .topright => if (horizontal) free else 0,
        .left => if (horizontal) 0 else free / 2,
        .right => if (horizontal) free else free / 2,
        .bottomleft => if (horizontal) 0 else free,
        .bottom => if (horizontal) free / 2 else free,
        .bottomright => free,
        .center, .smart => free / 2,
    };
}

/// Smart crop: a port of github.com/muesli/smartcrop as Hugo drives it
/// (prescale to 400px, edge/skin/saturation maps, rule-of-thirds scoring).
/// Returns the crop rectangle {x0, y0, x1, y1} in source coordinates.
const Rect = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

fn chop(x: f64) f64 {
    return if (x < 0) @ceil(x) else @floor(x);
}
fn thirds(x_in: f64) f64 {
    const x = (@mod(x_in - (1.0 / 3.0) + 1.0, 2.0) * 0.5 - 0.5) * 16.0;
    return @max(1.0 - x * x, 0.0);
}
fn bnd(l: f64) f64 {
    return @min(@max(l, 0.0), 255);
}
fn importance(c: Rect, x: i64, y: i64) f64 {
    if (c.x0 > x or x >= c.x1 or c.y0 > y or y >= c.y1) return -0.5;
    const xf = @as(f64, @floatFromInt(x - c.x0)) / @as(f64, @floatFromInt(c.x1 - c.x0));
    const yf = @as(f64, @floatFromInt(y - c.y0)) / @as(f64, @floatFromInt(c.y1 - c.y0));
    const px = @abs(0.5 - xf) * 2.0;
    const py = @abs(0.5 - yf) * 2.0;
    const dx = @max(px - 1.0 + 0.4, 0.0);
    const dy = @max(py - 1.0 + 0.4, 0.0);
    const d = (dx * dx + dy * dy) * -20.0;
    var s = 1.41 - @sqrt(px * px + py * py);
    s += (@max(0.0, s + d + 0.5) * 1.2) * (thirds(px) + thirds(py));
    return s + d;
}
fn cie(p: [3]u8) f64 {
    return 0.5126 * @as(f64, @floatFromInt(p[2])) + 0.7152 * @as(f64, @floatFromInt(p[1])) + 0.0722 * @as(f64, @floatFromInt(p[0]));
}
fn satOf(p: [3]u8) f64 {
    const mx = @max(p[0], @max(p[1], p[2]));
    const mn = @min(p[0], @min(p[1], p[2]));
    if (mx == mn) return 0;
    const maximum = @as(f64, @floatFromInt(mx)) / 255.0;
    const minimum = @as(f64, @floatFromInt(mn)) / 255.0;
    const l = (maximum + minimum) / 2.0;
    const d = maximum - minimum;
    return if (l > 0.5) d / (2.0 - maximum - minimum) else d / (maximum + minimum);
}
fn skinCol(p: [3]u8) f64 {
    const r: f64 = @floatFromInt(p[0]);
    const g: f64 = @floatFromInt(p[1]);
    const b: f64 = @floatFromInt(p[2]);
    const mag = @sqrt(r * r + g * g + b * b);
    const rd = r / mag - 0.78;
    const gd = g / mag - 0.57;
    const bd = b / mag - 0.44;
    return 1.0 - @sqrt(rd * rd + gd * gd + bd * bd);
}

/// Hugo's smartCrop. For >8-bit AVIF sources Hugo's prescale step resizes the
/// decoded image in place (its AnimatedImage wrapper shares the frame slice),
/// so the crop is intersected with, and later applied to, the prescaled image;
/// `mutated` receives that image so the caller can reproduce it.
fn smartCrop(src: *const Image, width: u32, height: u32, filter: image.Filter) !Rect {
    return smartCropX(src, width, height, filter, null);
}
fn smartCropX(src: *const Image, width: u32, height: u32, filter: image.Filter, mutated: ?*?Image) !Rect {
    const sw: f64 = @floatFromInt(src.w);
    const sh: f64 = @floatFromInt(src.h);
    const full = Rect{ .x0 = 0, .y0 = 0, .x1 = src.w, .y1 = src.h };
    if (src.w == width and src.h == height) return full;
    const fw: f64 = @floatFromInt(width);
    const fh: f64 = @floatFromInt(height);
    const scale = @min(sw / fw, sh / fh);
    var pf: f64 = 1.0;
    const f = 400.0 / @min(sw, sh);
    if (f < 1.0) pf = f;
    // prescale (Hugo's imagingResizer: width given, height derived with ceil)
    const lw: u32 = @intFromFloat(sw * pf);
    const lh: u32 = @intFromFloat(@ceil(sh / (sw / @as(f64, @floatFromInt(lw)))));
    const low = if (lw == src.w and lh == src.h) src.* else try image.resize(src, lw, lh, filter);
    const crop_w = chop(fw * scale * pf);
    const crop_h = chop(fh * scale * pf);
    const real_min = @min(1.0, @max(1.0 / scale, 0.9));
    const w: usize = low.w;
    const h: usize = low.h;
    // analysis maps
    const cies = try sys.A.alloc(f64, w * h);
    for (0..w * h) |i| {
        // smartcrop works on premultiplied RGBA
        cies[i] = cie(premulAt(&low, i));
    }
    const o = try sys.A.alloc(u8, w * h * 3); // r=skin g=edge b=saturation
    for (0..h) |y| for (0..w) |x| {
        const i = y * w + x;
        var light: f64 = 0;
        if (!(x == 0 or x >= w - 1 or y == 0 or y >= h - 1)) {
            light = cies[i] * 4.0 - cies[i - w] - cies[i - 1] - cies[i + 1] - cies[i + w];
        }
        const pp = premulAt(&low, i);
        const lightness = cies[i] / 255.0;
        const skin = skinCol(pp);
        o[i * 3 + 1] = @intFromFloat(bnd(light));
        o[i * 3] = if (skin > 0.8 and lightness >= 0.2 and lightness <= 1.0) @intFromFloat(bnd((skin - 0.8) * (255.0 / (1.0 - 0.8)))) else 0;
        const sat = satOf(pp);
        o[i * 3 + 2] = if (sat > 0.4 and lightness >= 0.05 and lightness <= 0.9) @intFromFloat(bnd((sat - 0.4) * (255.0 / (1.0 - 0.4)))) else 0;
    };
    const min_dim = @min(@as(f64, @floatFromInt(w)), @as(f64, @floatFromInt(h)));
    const cw = if (crop_w != 0) crop_w else min_dim;
    const ch = if (crop_h != 0) crop_h else min_dim;
    var top = Rect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    var top_score: f64 = -1.0;
    var sc: f64 = 1.0;
    while (sc >= real_min) : (sc -= 0.1) {
        var y: i64 = 0;
        while (@as(f64, @floatFromInt(y)) + ch * sc <= @as(f64, @floatFromInt(h))) : (y += 8) {
            var x: i64 = 0;
            while (@as(f64, @floatFromInt(x)) + cw * sc <= @as(f64, @floatFromInt(w))) : (x += 8) {
                const c = Rect{ .x0 = x, .y0 = y, .x1 = x + @as(i64, @intFromFloat(cw * sc)), .y1 = y + @as(i64, @intFromFloat(ch * sc)) };
                var detail: f64 = 0;
                var skin: f64 = 0;
                var satv: f64 = 0;
                var yy: usize = 0;
                while (yy + 8 <= h) : (yy += 8) {
                    var xx: usize = 0;
                    while (xx + 8 <= w) : (xx += 8) {
                        const q = o[(yy * w + xx) * 3 ..][0..3];
                        const imp = importance(c, @intCast(xx), @intCast(yy));
                        const det = @as(f64, @floatFromInt(q[1])) / 255.0;
                        skin += @as(f64, @floatFromInt(q[0])) / 255.0 * (det + 0.01) * imp;
                        detail += det * imp;
                        satv += @as(f64, @floatFromInt(q[2])) / 255.0 * (det + 0.2) * imp;
                    }
                }
                const total = (detail * 0.2 + skin * 1.8 + satv * 0.3) / @as(f64, @floatFromInt(c.x1 - c.x0)) / @as(f64, @floatFromInt(c.y1 - c.y0));
                if (total > top_score) {
                    top = c;
                    top_score = total;
                }
            }
        }
    }
    var r = Rect{
        .x0 = @intFromFloat(chop(@as(f64, @floatFromInt(top.x0)) / pf)),
        .y0 = @intFromFloat(chop(@as(f64, @floatFromInt(top.y0)) / pf)),
        .x1 = @intFromFloat(chop(@as(f64, @floatFromInt(top.x1)) / pf)),
        .y1 = @intFromFloat(chop(@as(f64, @floatFromInt(top.y1)) / pf)),
    };
    // intersect with the image bounds
    var ib = full;
    if (src.hdr_avif and (low.w != src.w or low.h != src.h)) {
        if (mutated) |m| {
            m.* = low;
            m.*.?.hdr_avif = true;
            m.*.?.avif = src.avif;
        }
        ib = .{ .x0 = 0, .y0 = 0, .x1 = low.w, .y1 = low.h };
    }
    r.x0 = @max(r.x0, ib.x0);
    r.y0 = @max(r.y0, ib.y0);
    r.x1 = @min(r.x1, ib.x1);
    r.y1 = @min(r.y1, ib.y1);
    if (r.x1 <= r.x0 or r.y1 <= r.y0) return r;
    expandSide(&r.x0, &r.x1, 0, full.x1, width);
    expandSide(&r.y0, &r.y1, 0, full.y1, height);
    return r;
}

/// smartcrop's toRGBA: the 8-bit premultiplied colour (draw.Draw into image.RGBA)
fn premulAt(img: *const Image, i: usize) [3]u8 {
    if (img.px16) |p| {
        const a: u32 = p[i * 4 + 3];
        return .{ @intCast(((@as(u32, p[i * 4]) * a) / 0xffff) >> 8), @intCast(((@as(u32, p[i * 4 + 1]) * a) / 0xffff) >> 8), @intCast(((@as(u32, p[i * 4 + 2]) * a) / 0xffff) >> 8) };
    }
    return premul(img.px[i * 4 ..][0..4]);
}

fn premul(p: *const [4]u8) [3]u8 {
    if (p[3] == 255) return .{ p[0], p[1], p[2] };
    var o: [3]u8 = undefined;
    for (0..3) |c| o[c] = @intCast(((@as(u32, p[c]) * 0x101) * (@as(u32, p[3]) * 0x101) / 0xffff) >> 8);
    return o;
}

fn expandSide(mn: *i64, mx: *i64, bmin: i64, bmax: i64, size_u: u32) void {
    const size: i64 = size_u;
    if (size <= mx.* - mn.* or size > bmax - bmin) return;
    const expand = size - (mx.* - mn.*);
    mn.* -= @divTrunc(expand, 2);
    mx.* += expand - @divTrunc(expand, 2);
    if (mn.* < bmin) {
        mx.* += bmin - mn.*;
        mn.* = bmin;
    }
    if (mx.* > bmax) {
        mn.* -= mx.* - bmax;
        mx.* = bmax;
    }
}

/// Hugo's FiltersFromConfig + gift: a chain of filters drawn with gift's exact
/// pixel arithmetic (giftx.zig).
fn apply(src: *const Image, s: *const Spec) anyerror!Image {
    const gx = @import("giftx.zig");
    var ops: std.ArrayList(gx.Op) = .empty;
    var img = src.*;
    if (s.rotate != 0) {
        const turns = @mod(@divTrunc(s.rotate, 90), 4);
        if (@mod(s.rotate, 90) != 0) site.warn("image rotation by {d} degrees is not supported (only multiples of 90)", .{s.rotate});
        if (turns != 0) {
            try ops.append(sys.A, .{ .rotate = @intCast(turns) });
            // smart crop analyses the rotated image
            if (s.anchor == .smart) img = try image.rotate90(&img, @intCast(turns));
        }
    }
    var mutated: ?Image = null;
    const act = s.action;
    const ga: gx.Anchor = @enumFromInt(@intFromEnum(s.anchor));
    if (v.eq(act, "resize") or act.len == 0) {
        if (s.w == 0 and s.h == 0) {
            if (v.eq(act, "resize")) return fail("must provide Width or Height", .{});
        } else try ops.append(sys.A, .{ .resize = .{ .w = s.w, .h = s.h, .f = s.filter } });
    } else {
        if (s.w == 0 or s.h == 0) return fail("must provide Width and Height", .{});
        if (v.eq(act, "fit")) {
            try ops.append(sys.A, .{ .fit = .{ .w = s.w, .h = s.h, .f = s.filter } });
        } else if (v.eq(act, "fill")) {
            if (s.anchor == .smart) {
                const b = try smartCropX(&img, s.w, s.h, s.filter, &mutated);
                try ops.append(sys.A, .{ .crop = .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 } });
                try ops.append(sys.A, .{ .resize = .{ .w = s.w, .h = s.h, .f = s.filter } });
            } else try ops.append(sys.A, .{ .fill = .{ .w = s.w, .h = s.h, .f = s.filter, .a = ga } });
        } else if (v.eq(act, "crop")) {
            if (s.anchor == .smart) {
                const b = try smartCropX(&img, s.w, s.h, s.filter, &mutated);
                try ops.append(sys.A, .{ .crop = .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 } });
                try ops.append(sys.A, .{ .crop_to_size = .{ .w = s.w, .h = s.h, .a = .center } });
            } else try ops.append(sys.A, .{ .crop_to_size = .{ .w = s.w, .h = s.h, .a = ga } });
        } else return fail("unknown image action \"{s}\"", .{act});
    }
    if (ops.items.len == 0) {
        // no filters: the decoded source is encoded as is (Hugo's resolveSrc)
        var same = src.*;
        same.px = try sys.A.dupe(u8, src.px);
        return same;
    }
    var out = try gx.run(if (mutated) |*m| m else src, ops.items);
    out.palette = src.palette;
    out.avif = src.avif;
    out.hdr_avif = src.hdr_avif;
    return out;
}

fn cacheDir() []const u8 {
    return v.pathJoin(&.{ site.S.opt.root, site.S.cfg.str("resourceDir") orelse "resources", "_gen", "images" });
}

fn finish(r: *Resource, target: []const u8, format: []const u8, bytes: []const u8, w: i64, h: i64) *Resource {
    const n = objs.newResource(target, bytes, null);
    n.name = r.name;
    n.title = r.title;
    n.params = r.params;
    n.media = if (v.eq(format, "jpeg")) "image/jpeg" else v.concat(&.{ "image/", format });
    n.width = w;
    n.height = h;
    return n;
}

fn targetFor(r: *Resource, key: []const u8, format: []const u8) []const u8 {
    var target = r.target;
    if (target.len == 0) target = v.concat(&.{ "/", r.name });
    const ext = v.pathExt(target);
    const hash = std.hash.XxHash64.hash(0, v.concat(&.{ target, "|", key, "|", v.fmt("{d}", .{objs.resContent(r).len}) }));
    return v.fmt("{s}_hu_{x:0>16}{s}", .{ target[0 .. target.len - ext.len], hash, extOf(format, ext) });
}

fn pickFormat(r: *Resource, wanted: []const u8) []const u8 {
    var format = if (wanted.len > 0) wanted else formatOf(r);
    if (v.eq(format, "gif") or v.eq(format, "bmp") or v.eq(format, "tif") or v.eq(format, "tiff") or format.len == 0) {
        site.warn("image \"{s}\": encoding {s} is not supported; writing PNG instead", .{ r.name, if (format.len == 0) "this format" else format });
        format = "png";
    }
    return format;
}

/// Decode, transform and encode one image (any thread).
fn render(src: *const Image, s: *const Spec, format: []const u8) anyerror![]const u8 {
    var res = try apply(src, s);
    if (res.w == 0 or res.h == 0) return error.EmptyImage;
    if (v.eq(format, "jpeg")) image.flatten(&res, s.bg);
    return if (v.eq(format, "png") and src.palette != null and !s.bg_set)
        image.encodePngPaletted(res.w, res.h, image.ditherToPalette(&res, src.palette.?), src.palette.?)
    else
        encodeAs(&res, format, s);
}

/// Output size of an operation from the source size alone, when that is
/// certain without looking at the pixels (null: process synchronously).
fn predictDims(r: *Resource, s: *const Spec) ?[2]u32 {
    const gx = @import("giftx.zig");
    objs.imageDims(r);
    if (r.width <= 0 or r.height <= 0) return null;
    var sw: u32 = @intCast(r.width);
    var sh: u32 = @intCast(r.height);
    if (@mod(s.rotate, 90) != 0) return null;
    if (@mod(@mod(@divTrunc(s.rotate, 90), 4), 2) == 1) {
        const t = sw;
        sw = sh;
        sh = t;
    }
    const act = s.action;
    if (v.eq(act, "resize") or act.len == 0) {
        if (s.w == 0 and s.h == 0) return if (act.len == 0) .{ sw, sh } else null;
        return (gx.Op{ .resize = .{ .w = s.w, .h = s.h, .f = s.filter } }).bounds(sw, sh);
    }
    if (s.w == 0 or s.h == 0) return null;
    if (v.eq(act, "fit")) return (gx.Op{ .fit = .{ .w = s.w, .h = s.h, .f = s.filter } }).bounds(sw, sh);
    if (v.eq(act, "fill")) {
        // >8-bit AVIF smart crops depend on Hugo's in-place mutation: do them now
        if (s.anchor == .smart and v.eq(r.media, "image/avif")) {
            if (sys.readFilePrefix(r.src_path orelse return null, 128 * 1024)) |head| {
                if (@import("avif.zig").dims(head)) |d| if (d.depth > 8) return null;
            } else return null;
        }
        return .{ s.w, s.h };
    }
    if (v.eq(act, "crop") and s.anchor != .smart) {
        const ga: gx.Anchor = @enumFromInt(@intFromEnum(s.anchor));
        return (gx.Op{ .crop_to_size = .{ .w = s.w, .h = s.h, .a = ga } }).bounds(sw, sh);
    }
    return null;
}

// ---------------------------------------------------------------- worker pool
//
// Image operations are queued and run on worker threads while the templates
// keep rendering (like Hugo, which processes images concurrently). A queued
// result is a Resource whose `job` is set: its size is known up front, its
// bytes arrive when the job is done (objs.resContent waits), and publishing
// it is deferred to the job.

pub const Job = struct {
    src_bytes: ?[]const u8,
    src_path: ?[]const u8,
    src_name: []const u8,
    spec: Spec,
    format: []const u8,
    cache_path: []const u8,
    out: *Resource,
    action: []const u8,
    done: bool = false,
    bytes: []const u8 = "",
    err: ?[]const u8 = null,
    dests: std.ArrayList([]const u8) = .empty,
    warns: std.ArrayList([]const u8) = .empty,
};

var pool_lock: sys.Mutex = .init;
var pool_cond: sys.Condition = .init;
var queue: std.ArrayList(*Job) = .empty;
var queue_head: usize = 0;
var all_jobs: std.ArrayList(*Job) = .empty;
var workers: std.ArrayList(std.Thread) = .empty;
var stopping = false;
var n_workers: usize = 0;

fn workerCount() usize {
    if (sys.getenv("ZSSG_IMAGE_WORKERS")) |e| return std.fmt.parseInt(usize, e, 10) catch 1;
    return @max(1, @min(sys.cpuCount(), 16));
}

fn workerMain() void {
    while (true) {
        sys.lock(&pool_lock);
        while (queue_head >= queue.items.len and !stopping) sys.wait(&pool_cond, &pool_lock);
        if (queue_head >= queue.items.len) {
            sys.unlock(&pool_lock);
            return;
        }
        const job = queue.items[queue_head];
        queue_head += 1;
        sys.unlock(&pool_lock);
        runJob(job);
    }
}

fn runJob(job: *Job) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const saved = sys.A;
    sys.A = arena.allocator();
    defer sys.A = saved;
    sys.worker_msgs = &job.warns;
    defer sys.worker_msgs = null;
    var bytes: []const u8 = "";
    var err: ?[]const u8 = null;
    blk: {
        const src_bytes = job.src_bytes orelse (sys.readFile(job.src_path.?) orelse {
            err = v.fmt("failed to read image \"{s}\"", .{job.src_name});
            break :blk;
        });
        var img = image.decode(src_bytes) catch |e| {
            err = if (e == error.ImageError) v.fmt("image \"{s}\": {s}", .{ job.src_name, image.err_msg }) else v.fmt("image \"{s}\": {s}", .{ job.src_name, @errorName(e) });
            break :blk;
        };
        const out = render(&img, &job.spec, job.format) catch |e| {
            err = if (e == error.EmptyImage)
                v.fmt("failed to {s} image \"{s}\": {s}: invalid format: invalid image size: 0x0", .{ job.action, job.src_path orelse job.src_name, job.format })
            else if (e == error.TemplateError) v.fmt("image \"{s}\": {s}", .{ job.src_name, tmpl.err_msg }) else v.fmt("image \"{s}\": {s}", .{ job.src_name, @errorName(e) });
            break :blk;
        };
        bytes = std.heap.page_allocator.dupe(u8, out) catch "";
        sys.writeFile(job.cache_path, bytes) catch {};
    }
    const err_kept: ?[]const u8 = if (err) |e| (std.heap.page_allocator.dupe(u8, e) catch "image error") else null;
    sys.lock(&pool_lock);
    job.bytes = bytes;
    job.err = err_kept;
    job.done = true;
    const dests = job.dests.items;
    sys.unlock(&pool_lock);
    sys.broadcast(&pool_cond);
    // deferred publishing (dests is no longer appended to once done is set)
    if (err_kept == null) for (dests) |d| {
        sys.writeFile(d, bytes) catch |e| site.warn("failed to publish {s}: {s}", .{ d, @errorName(e) });
    };
}

fn enqueue(job: *Job) void {
    if (n_workers == 0) {
        n_workers = workerCount();
        for (0..n_workers) |_| {
            if (sys.spawn(workerMain, .{})) |t| workers.append(sys.main_A, t) catch {};
        }
        if (workers.items.len == 0) n_workers = 1;
    }
    if (workers.items.len == 0) {
        // no threads: run in place
        all_jobs.append(sys.main_A, job) catch {};
        runJob(job);
        return;
    }
    sys.lock(&pool_lock);
    queue.append(sys.main_A, job) catch {};
    all_jobs.append(sys.main_A, job) catch {};
    sys.unlock(&pool_lock);
    sys.broadcast(&pool_cond);
}

fn finishJob(r: *Resource, job: *Job) void {
    r.job = null;
    for (job.warns.items) |w| site.warn("{s}", .{w});
    job.warns.clearRetainingCapacity();
    if (job.err) |e| {
        site.errorf("{s}", .{e});
        job.err = null;
        r.content = "";
    } else r.content = job.bytes;
}

/// Blocks until the job producing `r` is done (main thread).
pub fn waitFor(r: *Resource) void {
    const job: *Job = @ptrCast(@alignCast(r.job orelse return));
    sys.lock(&pool_lock);
    while (!job.done) sys.wait(&pool_cond, &pool_lock);
    sys.unlock(&pool_lock);
    finishJob(r, job);
}

/// Publishes `r` to dest once its job is done; false if it is already done
/// (the caller then writes it).
pub fn writeWhenDone(r: *Resource, dest: []const u8) bool {
    const job: *Job = @ptrCast(@alignCast(r.job orelse return false));
    sys.lock(&pool_lock);
    defer sys.unlock(&pool_lock);
    if (job.done) return false;
    job.dests.append(sys.main_A, sys.main_A.dupe(u8, dest) catch dest) catch return false;
    return true;
}

/// Waits for every queued image and reports their errors (end of the build).
pub fn joinAll() void {
    if (workers.items.len > 0) {
        sys.lock(&pool_lock);
        stopping = true;
        sys.unlock(&pool_lock);
        sys.broadcast(&pool_cond);
        for (workers.items) |t| t.join();
        workers.clearRetainingCapacity();
        stopping = false;
        n_workers = 0;
    }
    for (all_jobs.items) |job| {
        if (job.out.job != null) finishJob(job.out, job);
    }
    all_jobs.clearRetainingCapacity();
    queue.clearRetainingCapacity();
    queue_head = 0;
}

/// Resize / Fit / Fill / Crop / Process.
pub fn process(r: *Resource, action: []const u8, spec_str: []const u8) anyerror!*Resource {
    var s = try parseSpec(action, spec_str);
    const format = pickFormat(r, s.format);
    resolveEncoding(&s, format);
    if (r.target.len == 0) r.target = v.concat(&.{ "/", r.name });
    const key = v.fmt("v3|{s}|{s}|{d}x{d}|q{d}|r{d}|{s}|{s}|{}|{x}{x}{x}|{s}|{d}", .{ s.action, format, s.w, s.h, s.quality, s.rotate, @tagName(s.filter), @tagName(s.anchor), s.lossless, s.bg[0], s.bg[1], s.bg[2], s.hint, s.speed });
    const target = targetFor(r, key, format);
    if (site.S.res_cache.get(target)) |hit| return hit;
    const cache_path = v.pathJoin(&.{ cacheDir(), target });
    var out: *Resource = undefined;
    if (sys.readFile(cache_path)) |bytes| {
        out = finish(r, target, format, bytes, -1, -1);
    } else if (r.job == null and @mod(s.rotate, 90) == 0 and predictDims(r, &s) != null) {
        const d = predictDims(r, &s).?;
        out = finish(r, target, format, "", d[0], d[1]);
        out.content = null;
        const job = try sys.main_A.create(Job);
        job.* = .{
            .src_bytes = r.content,
            .src_path = r.src_path,
            .src_name = r.name,
            .spec = s,
            .format = format,
            .cache_path = cache_path,
            .out = out,
            .action = if (s.action.len > 0) s.action else "process",
        };
        if (job.src_bytes == null and job.src_path == null) job.src_bytes = objs.resContent(r);
        out.job = job;
        enqueue(job);
    } else {
        const src = try decodeRes(r);
        const bytes = render(src, &s, format) catch |e| {
            if (e == error.EmptyImage) return fail("failed to {s} image \"{s}\": {s}: invalid format: invalid image size: 0x0", .{ if (s.action.len > 0) s.action else "process", r.src_path orelse r.name, format });
            return e;
        };
        sys.writeFile(cache_path, bytes) catch {};
        out = finish(r, target, format, bytes, -1, -1);
        objs.imageDims(out);
    }
    try site.S.res_cache.put(sys.A, target, out);
    return out;
}

// ---------------------------------------------------------------- filters

pub fn filterVal(name: []const u8, args: []const Value) Value {
    const m = v.newMap();
    m.put("__filter", v.S(name));
    m.put("args", v.listOf(args));
    return v.M(m);
}

fn isFilter(val: Value) bool {
    return val == .map and val.map.get("__filter") != null;
}

fn collect(out: *std.ArrayList(*v.Map), val: Value) void {
    if (isFilter(val)) {
        out.append(sys.A, val.map) catch {};
    } else if (val == .list) {
        for (val.list.items.items) |x| collect(out, x);
    }
}

fn argF(args: []const Value, i: usize, def: f32) f32 {
    if (i < args.len) if (v.toFloat(args[i])) |f| return @floatCast(f);
    return def;
}

fn optF(m: ?*v.Map, key: []const u8, def: f32) f32 {
    if (m) |mm| if (mm.getCI(key)) |x| if (v.toFloat(x)) |f| return @floatCast(f);
    return def;
}

/// Apply a list of images.* filters and return the new resource.
pub fn applyFilters(r: *Resource, filters_val: []const Value) anyerror!*Resource {
    var filters: std.ArrayList(*v.Map) = .empty;
    for (filters_val) |fv| collect(&filters, fv);
    if (filters.items.len == 0) return r;
    var key: v.Buf = .{};
    var s = defaults();
    var format = formatOf(r);
    for (filters.items) |f| {
        key.add(f.str("__filter").?);
        for (f.list("args").?.items.items) |a| {
            key.ch(':');
            if (objs.asRes(a)) |ar| key.add(ar.target) else {
                var jb: v.Buf = .{};
                @import("data.zig").toJson(&jb, a, .{}, 0);
                key.add(jb.str());
            }
        }
        key.ch('|');
        if (v.eq(f.str("__filter").?, "process")) {
            const ps = try parseSpec("", v.toStr(f.list("args").?.items.items[0]));
            if (ps.format.len > 0) format = ps.format;
            s.quality = ps.quality;
            s.quality_set = ps.quality_set;
            s.lossless = ps.lossless;
            s.lossless_set = ps.lossless_set;
            s.hint = ps.hint;
        }
    }
    format = pickFormat(r, format);
    resolveEncoding(&s, format);
    if (r.target.len == 0) r.target = v.concat(&.{ "/", r.name });
    const target = targetFor(r, key.str(), format);
    if (site.S.res_cache.get(target)) |hit| return hit;
    const cache_path = v.pathJoin(&.{ cacheDir(), target });
    var out: *Resource = undefined;
    if (sys.readFile(cache_path)) |bytes| {
        out = finish(r, target, format, bytes, -1, -1);
    } else {
        const src = try decodeRes(r);
        var img = try image.crop(src, 0, 0, src.w, src.h);
        img.orientation = src.orientation;
        for (filters.items) |f| {
            const name = f.str("__filter").?;
            const a = f.list("args").?.items.items;
            if (v.eq(name, "grayscale")) image.colorOp(&img, .grayscale, 0, 0, 0) else if (v.eq(name, "invert")) image.colorOp(&img, .invert, 0, 0, 0) else if (v.eq(name, "brightness")) image.colorOp(&img, .brightness, argF(a, 0, 0), 0, 0) else if (v.eq(name, "contrast")) image.colorOp(&img, .contrast, argF(a, 0, 0), 0, 0) else if (v.eq(name, "saturation")) image.colorOp(&img, .saturation, argF(a, 0, 0), 0, 0) else if (v.eq(name, "gamma")) image.colorOp(&img, .gamma, argF(a, 0, 1), 0, 0) else if (v.eq(name, "sepia")) image.colorOp(&img, .sepia, argF(a, 0, 100), 0, 0) else if (v.eq(name, "opacity")) image.colorOp(&img, .opacity, argF(a, 0, 1), 0, 0) else if (v.eq(name, "hue")) image.colorOp(&img, .hue, argF(a, 0, 0), 0, 0) else if (v.eq(name, "colorize")) image.colorOp(&img, .colorize, argF(a, 0, 0), argF(a, 1, 0), argF(a, 2, 0)) else if (v.eq(name, "sigmoid")) image.colorOp(&img, .sigmoid, argF(a, 0, 0.5), argF(a, 1, 0), 0) else if (v.eq(name, "colorbalance")) image.colorOp(&img, .colorbalance, argF(a, 0, 0), argF(a, 1, 0), argF(a, 2, 0)) else if (v.eq(name, "gaussianblur")) {
                img = try image.gaussianBlur(&img, argF(a, 0, 0));
            } else if (v.eq(name, "unsharpmask")) {
                img = try image.unsharp(&img, argF(a, 0, 1), argF(a, 1, 100), argF(a, 2, 0));
            } else if (v.eq(name, "pixelate")) {
                image.pixelate(&img, @intFromFloat(argF(a, 0, 1)));
            } else if (v.eq(name, "autoorient")) {
                img = try image.autoOrient(&img);
            } else if (v.eq(name, "overlay")) {
                if (a.len >= 1) if (objs.asRes(a[0])) |top_res| {
                    const top = try decodeRes(top_res);
                    image.overlay(&img, top, @intFromFloat(argF(a, 1, 0)), @intFromFloat(argF(a, 2, 0)));
                };
            } else if (v.eq(name, "padding")) {
                // CSS-like shorthand: 1-4 numbers, optional trailing colour
                var nums: [4]u32 = .{ 0, 0, 0, 0 };
                var n: usize = 0;
                var color: [4]u8 = .{ 255, 255, 255, 0 };
                for (a) |x| {
                    if (v.rawStr(x)) |cs| {
                        if (parseHex(cs)) |c3| color = .{ c3[0], c3[1], c3[2], 255 };
                    } else if (n < 4) {
                        nums[n] = @intCast(@max(v.toInt(x) orelse 0, 0));
                        n += 1;
                    }
                }
                const t = nums[0];
                const rt = if (n > 1) nums[1] else t;
                const bt = if (n > 2) nums[2] else t;
                const lt = if (n > 3) nums[3] else rt;
                img = try image.pad(&img, t, rt, bt, lt, color);
            } else if (v.eq(name, "process")) {
                const ps = try parseSpec("", v.toStr(a[0]));
                if (ps.action.len > 0 or ps.w != 0 or ps.h != 0 or ps.rotate != 0) img = try apply(&img, &ps);
            } else if (v.eq(name, "mask")) {
                if (a.len >= 1) if (objs.asRes(a[0])) |mask_res| {
                    const mask_src = try decodeRes(mask_res);
                    const mask = try image.resize(mask_src, img.w, img.h, .linear);
                    var i: usize = 0;
                    while (i < img.px.len) : (i += 4) {
                        const lum: u32 = (@as(u32, mask.px[i]) * 299 + @as(u32, mask.px[i + 1]) * 587 + @as(u32, mask.px[i + 2]) * 114) / 1000;
                        img.px[i + 3] = @intCast(@as(u32, img.px[i + 3]) * lum / 255);
                    }
                };
            } else site.warn("images.{s} is not implemented; the filter is skipped", .{name});
        }
        if (v.eq(format, "jpeg")) image.flatten(&img, s.bg);
        const bytes = encodeAs(&img, format, &s);
        sys.writeFile(cache_path, bytes) catch {};
        out = finish(r, target, format, bytes, img.w, img.h);
    }
    try site.S.res_cache.put(sys.A, target, out);
    return out;
}

pub fn colors(r: *Resource) Value {
    const img = decodeRes(r) catch return v.L(v.newList());
    return v.strList(image.dominantColors(img, 5));
}
