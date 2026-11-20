// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! AVIF support.
//!
//! Dimensions are read natively from the HEIF container (ispe / irot of the
//! primary item). Pixel decoding and encoding use an external tool, the same
//! way ZSSG uses Dart Sass or esbuild: the first one found of
//!   avifdec / avifenc (libavif), magick / convert (ImageMagick 7/6),
//!   vips, ffmpeg.
const std = @import("std");
const v = @import("value.zig");
const sys = @import("sys.zig");
const image = @import("image.zig");

pub fn isAvif(c: []const u8) bool {
    if (c.len < 12 or !v.eq(c[4..8], "ftyp")) return false;
    const n = @min(be32(c[0..4]), c.len);
    var i: usize = 8;
    while (i + 4 <= n) : (i += 4) {
        if (i == 12) continue; // minor version
        if (v.eq(c[i .. i + 4], "avif") or v.eq(c[i .. i + 4], "avis")) return true;
    }
    return false;
}

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
fn be16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}

const Box = struct { typ: []const u8, body: []const u8 };

const BoxIter = struct {
    s: []const u8,
    i: usize = 0,
    fn next(it: *BoxIter) ?Box {
        if (it.i + 8 > it.s.len) return null;
        var size: u64 = be32(it.s[it.i .. it.i + 4]);
        const typ = it.s[it.i + 4 .. it.i + 8];
        var hdr: usize = 8;
        if (size == 1) {
            if (it.i + 16 > it.s.len) return null;
            size = std.mem.readInt(u64, it.s[it.i + 8 ..][0..8], .big);
            hdr = 16;
        } else if (size == 0) size = it.s.len - it.i;
        if (size < hdr or it.i + size > it.s.len) return null;
        const b: Box = .{ .typ = typ, .body = it.s[it.i + hdr .. it.i + @as(usize, @intCast(size))] };
        it.i += @intCast(size);
        return b;
    }
};

fn child(s: []const u8, typ: []const u8) ?[]const u8 {
    var it: BoxIter = .{ .s = s };
    while (it.next()) |b| if (v.eq(b.typ, typ)) return b.body;
    return null;
}

pub const Dims = struct { w: u32, h: u32, depth: u8 = 8 };

/// Width and height of the primary image as displayed (after irot).
pub fn dims(c: []const u8) ?Dims {
    const meta = child(c, "meta") orelse return null;
    if (meta.len < 4) return null;
    const mb = meta[4..]; // full box
    var primary: u32 = 1;
    if (child(mb, "pitm")) |p| {
        if (p.len >= 6) primary = if (p[0] == 0) be16(p[4..6]) else if (p.len >= 8) be32(p[4..8]) else 1;
    }
    const iprp = child(mb, "iprp") orelse return null;
    const ipco = child(iprp, "ipco") orelse return null;
    // property boxes, 1-based
    var props: std.ArrayList(Box) = .empty;
    var it: BoxIter = .{ .s = ipco };
    while (it.next()) |b| props.append(sys.A, b) catch return null;
    var assoc: std.ArrayList(u32) = .empty;
    if (child(iprp, "ipma")) |ip| {
        if (ip.len >= 8) {
            const ver = ip[0];
            const flags = ip[3];
            const cnt = be32(ip[4..8]);
            var i: usize = 8;
            var k: u32 = 0;
            while (k < cnt) : (k += 1) {
                var id: u32 = 0;
                if (ver < 1) {
                    if (i + 2 > ip.len) break;
                    id = be16(ip[i .. i + 2]);
                    i += 2;
                } else {
                    if (i + 4 > ip.len) break;
                    id = be32(ip[i .. i + 4]);
                    i += 4;
                }
                if (i >= ip.len) break;
                const n = ip[i];
                i += 1;
                var j: u32 = 0;
                while (j < n) : (j += 1) {
                    var idx: u32 = 0;
                    if (flags & 1 != 0) {
                        if (i + 2 > ip.len) break;
                        idx = be16(ip[i .. i + 2]) & 0x7fff;
                        i += 2;
                    } else {
                        if (i >= ip.len) break;
                        idx = ip[i] & 0x7f;
                        i += 1;
                    }
                    if (id == primary) assoc.append(sys.A, idx) catch {};
                }
            }
        }
    }
    var w: u32 = 0;
    var h: u32 = 0;
    var rot: u8 = 0;
    var depth: u8 = 8;
    const use_all = assoc.items.len == 0;
    for (props.items, 1..) |b, idx| {
        if (!use_all and std.mem.indexOfScalar(u32, assoc.items, @intCast(idx)) == null) continue;
        if (v.eq(b.typ, "ispe") and b.body.len >= 12 and (w == 0 or !use_all)) {
            w = be32(b.body[4..8]);
            h = be32(b.body[8..12]);
        } else if (v.eq(b.typ, "irot") and b.body.len >= 1) {
            rot = b.body[0] & 3;
        } else if (v.eq(b.typ, "pixi") and b.body.len >= 6) depth = b.body[5];
    }
    if (w == 0) return null;
    if (rot == 1 or rot == 3) return .{ .w = h, .h = w, .depth = depth };
    return .{ .w = w, .h = h, .depth = depth };
}

pub threadlocal var err_msg: []const u8 = "";

fn tmpName(ext: []const u8) []const u8 {
    return v.pathJoin(&.{ sys.tmpDir(), v.fmt("zssg-avif-{d}{s}", .{ sys.pid(), ext }) });
}

/// Tools found missing on the PATH (bit per tool), so they are not retried.
var missing: std.atomic.Value(u32) = .init(0);

const Tool = enum(u5) { avifdec, python, magick, convert, vips, ffmpeg, avifenc, magick_enc, vips_enc, python_enc, ffmpeg_enc, convert_enc };

/// Runs a tool; null when it is missing or fails (missing tools are remembered).
fn runTool(t: Tool, argv: []const []const u8, out: []const u8) ?[]const u8 {
    const bit = @as(u32, 1) << @intFromEnum(t);
    if (missing.load(.monotonic) & bit != 0) return null;
    const r = sys.runCode(argv) orelse {
        _ = missing.fetchOr(bit, .monotonic);
        return null;
    };
    if (r.code != 0) {
        err_msg = r.stderr;
        // python without Pillow/AVIF support, ImageMagick without an AVIF delegate…
        if (r.code == 127 or std.mem.indexOf(u8, r.stderr, "No module named") != null or std.mem.indexOf(u8, r.stderr, "no decode delegate") != null or std.mem.indexOf(u8, r.stderr, "no encode delegate") != null) _ = missing.fetchOr(bit, .monotonic);
        return null;
    }
    const bytes = sys.readFile(out) orelse return null;
    if (bytes.len == 0) return null;
    return bytes;
}

/// Decodes AVIF to an RGBA image via an external tool (raw RGBA where the
/// tool can write it, which avoids a PNG round trip).
pub fn decode(c: []const u8) anyerror!image.Image {
    if (comptime @import("build_options").avif) {
        const ac = @import("avif_c.zig");
        const d = ac.decode(sys.A, c) orelse {
            image.err_msg = v.fmt("AVIF: {s}", .{ac.errMsg()});
            return error.ImageError;
        };
        const ci = d.img;
        var img: image.Image = .{ .w = ci.width, .h = ci.height, .px = d.pixels };
        img.kind = .nrgba;
        img.hdr_avif = ci.depth > 8;
        if (ci.rgb_depth == 16) {
            // 16-bit RGBA, native byte order (Go's NRGBA64 after Hugo's byte swap)
            const n = @as(usize, ci.width) * ci.height * 4;
            const p16 = try sys.A.alloc(u16, n);
            for (p16, 0..) |*e, i| e.* = std.mem.readInt(u16, d.pixels[i * 2 ..][0..2], .little);
            const p8 = try sys.A.alloc(u8, n);
            for (p8, p16) |*o, x| o.* = @intCast(x >> 8);
            img.px = p8;
            img.px16 = p16;
            img.avif = .{ .depth = ci.depth, .cp = ci.color_primaries, .tc = ci.transfer, .mc = ci.matrix, .max_cll = ci.max_cll, .max_pall = ci.max_pall };
        }
        return img;
    }
    const in = tmpName(".avif");
    try sys.writeFile(in, c);
    defer sys.removeTree(in);
    const d = dims(c);
    const raw = tmpName(".rgba");
    defer sys.removeTree(raw);
    const png = tmpName(".png");
    defer sys.removeTree(png);
    const Cmd = struct { t: Tool, argv: []const []const u8, raw: bool };
    const cmds = [_]Cmd{
        .{ .t = .avifdec, .argv = &.{ "avifdec", "--png-compress", "0", "-d", "8", in, png }, .raw = false },
        .{ .t = .python, .argv = &.{ "python3", "-I", "-c", "import sys\nfrom PIL import Image\nopen(sys.argv[2],'wb').write(Image.open(sys.argv[1]).convert('RGBA').tobytes())", in, raw }, .raw = true },
        .{ .t = .magick, .argv = &.{ "magick", in, "-depth", "8", v.concat(&.{ "RGBA:", raw }) }, .raw = true },
        .{ .t = .vips, .argv = &.{ "vips", "copy", in, v.concat(&.{ png, "[compression=0]" }) }, .raw = false },
        .{ .t = .convert, .argv = &.{ "convert", in, "-depth", "8", v.concat(&.{ "RGBA:", raw }) }, .raw = true },
        .{ .t = .ffmpeg, .argv = &.{ "ffmpeg", "-v", "error", "-y", "-i", in, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", raw }, .raw = true },
    };
    for (cmds) |cmd| {
        if (cmd.raw and d == null) continue;
        const bytes = runTool(cmd.t, cmd.argv, if (cmd.raw) raw else png) orelse continue;
        var img: image.Image = undefined;
        if (cmd.raw) {
            if (bytes.len != @as(usize, d.?.w) * d.?.h * 4) continue;
            img = .{ .w = d.?.w, .h = d.?.h, .px = @constCast(bytes) };
        } else {
            img = image.decodePng(bytes) catch continue;
            img.palette = null;
        }
        img.kind = .nrgba;
        // Hugo wraps >8-bit AVIF in an image type that its smart crop mutates
        if (d) |dd| img.hdr_avif = dd.depth > 8;
        return img;
    }
    image.err_msg = "decoding AVIF needs one of avifdec, Python Pillow, ImageMagick, vips or ffmpeg on the PATH";
    return error.ImageError;
}

pub const EncodeOpts = struct { quality: i64 = 60, lossless: bool = false, yuv444: bool = false, speed: i32 = 10 };

/// Encodes an image as AVIF like Hugo: 8-bit RGBA, 16-bit RGBA at the source
/// depth with its colour properties, or 4:0:0 for grayscale.
pub fn encode(img: *const image.Image, o: EncodeOpts) ?[]const u8 {
    if (comptime @import("build_options").avif) {
        const ac = @import("avif_c.zig");
        var eo: ac.EncodeOpts = .{ .quality = @floatFromInt(o.quality), .lossless = o.lossless, .yuv444 = o.yuv444, .speed = o.speed };
        if (img.kind == .gray and img.px16 == null) {
            const g = sys.A.alloc(u8, @as(usize, img.w) * img.h) catch return null;
            for (g, 0..) |*e, i| e.* = img.px[i * 4];
            return ac.encodeGray(sys.A, g, img.w, img.h, img.w, eo);
        }
        if (img.px16) |p16| {
            const b = sys.A.alloc(u8, p16.len * 2) catch return null;
            for (p16, 0..) |x, i| std.mem.writeInt(u16, b[i * 2 ..][0..2], x, .little);
            eo.depth = if (img.avif.depth > 8) img.avif.depth else 10;
            eo.cp = img.avif.cp;
            eo.tc = img.avif.tc;
            eo.mc = img.avif.mc;
            eo.max_cll = img.avif.max_cll;
            eo.max_pall = img.avif.max_pall;
            return ac.encodeRgba(sys.A, b, img.w, img.h, img.w * 8, eo);
        }
        return ac.encodeRgba(sys.A, img.px, img.w, img.h, img.w * 4, eo);
    }
    return encodeTool(img, o.quality);
}

/// Encodes an image as AVIF via an external tool (PNG is the hand-off format).
fn encodeTool(img: *const image.Image, quality: i64) ?[]const u8 {
    const in = tmpName(".png");
    sys.writeFile(in, image.encodePng(img)) catch return null;
    defer sys.removeTree(in);
    const out = tmpName(".avif");
    defer sys.removeTree(out);
    const q = v.fmt("{d}", .{quality});
    // ffmpeg's crf scale (0..63) from a 0..100 quality
    const crf = v.fmt("{d}", .{@max(0, @min(63, @divTrunc((100 - quality) * 63, 100)))});
    const alpha = !img.opaque_();
    const ff_alpha: []const []const u8 = &.{ "ffmpeg", "-v", "error", "-y", "-i", in, "-filter_complex", "[0:v]format=yuva444p,split[m][a];[a]alphaextract[al]", "-map", "[m]", "-map", "[al]", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", crf, out };
    const ff_plain: []const []const u8 = &.{ "ffmpeg", "-v", "error", "-y", "-i", in, "-c:v", "libaom-av1", "-still-picture", "1", "-crf", crf, "-pix_fmt", "yuv420p", out };
    const Cmd = struct { t: Tool, argv: []const []const u8 };
    const cmds = [_]Cmd{
        .{ .t = .avifenc, .argv = &.{ "avifenc", "-q", q, "-s", "6", in, out } },
        .{ .t = .python_enc, .argv = &.{ "python3", "-I", "-c", "import sys\nfrom PIL import Image\nImage.open(sys.argv[1]).save(sys.argv[2], quality=int(sys.argv[3]))", in, out, q } },
        .{ .t = .magick_enc, .argv = &.{ "magick", in, "-quality", q, out } },
        .{ .t = .vips_enc, .argv = &.{ "vips", "copy", in, v.concat(&.{ out, "[Q=", q, "]" }) } },
        .{ .t = .ffmpeg_enc, .argv = if (alpha) ff_alpha else ff_plain },
        .{ .t = .convert_enc, .argv = &.{ "convert", in, "-quality", q, out } },
    };
    for (cmds) |cmd| {
        if (runTool(cmd.t, cmd.argv, out)) |b| if (isAvif(b)) return b;
    }
    return null;
}
